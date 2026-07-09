#!/usr/bin/env bash
# Hand off work from Claude Code to Codex.
#
# DEFAULT (file-drop, GUI-safe): write a self-contained handoff to a per-dispatch
# transport file, then you paste one line into your live Codex session (Desktop app
# or TUI) to pick it up.
#   ./scripts/handoff_to_codex.sh "task for Codex"
#
# Other modes:
#   ./scripts/handoff_to_codex.sh --ipc <conversationId> "task"  # inject into a live Desktop GUI thread
#   ./scripts/handoff_to_codex.sh --ipc <conversationId> \
#       [--foreground-policy defer|switch|restore-if-known] [--ack-foreground-switch] [--] "task"
#   ./scripts/handoff_to_codex.sh --open [session_id]   # open a session in the terminal TUI
#   ./scripts/handoff_to_codex.sh --app                 # open the workspace in the Codex desktop app
#   ./scripts/handoff_to_codex.sh --exec "task" [sid]   # HEADLESS exec (NOT visible in the GUI)
#
# The file-drop default is the recommended path: it appears in the Codex Desktop GUI (your own session
# reads the file) and has zero effect on any other running Codex session. Why --exec is not the default:
# `codex exec` writes only to the JSONL rollout files, while the Desktop app renders from a separate
# SQLite store, so exec handoffs never appear in the Desktop GUI -- use --exec only for fire-and-forget
# tasks where you read the reply file.
#
# TRANSPORT MODEL (2026-07-06 rebuild): the Claude->Codex transport ENVELOPE (the
# per-dispatch .task.md the wrapper writes, and the .reply.md Codex writes back) lives
# in a machine-local, repo-independent root, keyed per (Claude sessionId, conversationId,
# dispatchId):
#     ${CODEX_IPC_ROOT:-~/.claude/ipc}/<claudeSid>/<conversationId|filedrop>/<dispatchId>.task.md
#                                                                            /<dispatchId>.reply.md
# This makes any number of concurrent Claude sessions and Codex threads isolated by
# construction (no shared mutable file, no cross-talk, exact reply correlation via the
# dispatchId), and works regardless of which repo/CWD the session runs in. Task-CONTEXT
# artifacts (briefs, specs, bundles) still live inside the associated repo and are
# referenced from the payload by absolute path -- only the transport envelope moved.
#
# Optional env:
#   CODEX_IPC_ROOT=<dir>               override the transport root (default ~/.claude/ipc)
#   CODEX_IPC_RETENTION_DAYS=<n>       prune envelopes/replies older than n days on each run (default 7; 0 disables)
#   CODEX_IPC_INCLUDE_TRANSCRIPT=1     include the Claude transcript path in the handoff payload
#                                      (default: omitted; transcript paths expose full session context)
#   CODEX_SESSION_ID=<uuid>            target a specific session (positional arg overrides this)
#   CODEX_MODEL=<name>                 model pin for --exec (only passed when set; else Codex config default)
#   CODEX_REASONING_EFFORT=<level>     advisory note added to the handoff (file-drop) / pin (--exec);
#                                      only passed/added when set
#   CODEX_IPC_FOREGROUND_POLICY=<p>    --ipc foreground policy default: defer|switch|restore-if-known
#                                      (default defer; the --foreground-policy flag overrides)
#   CODEX_IPC_FOREGROUND_SWITCH_STANDING_APPROVAL=1
#                                      standing acknowledgement for switch policy (printed on
#                                      every send when active; prefer per-invocation
#                                      --ack-foreground-switch)
#   CODEX_IPC_POLL_DEADLINE_S=<n>      auto-load retry poll window (default 30; test knob)
#   CODEX_IPC_POLL_INTERVAL_S=<n>      auto-load retry poll interval (default 2; test knob)

set -euo pipefail

# --- Machine-local IPC transport root (repo/CWD-independent) ---
IPC_ROOT="${CODEX_IPC_ROOT:-${HOME}/.claude/ipc}"
# Reject a newline in the root (would corrupt the payload heredoc / pickup line).
# An apostrophe is legal in a Windows path (e.g. user "O'Brien"); the pickup instruction
# double-quotes the path and Windows forbids '"' in paths, so no escaping is needed.
case "$IPC_ROOT" in *$'\n'*) echo "ERROR: CODEX_IPC_ROOT must not contain a newline." >&2; exit 1;; esac

# --- Optional project root: used ONLY to enrich the payload with git context. ---
# Never required. The transport does not depend on being inside a git repository.
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

# Convert an MSYS path (/c/...) to Windows forward-slash form (C:/...) so Codex on
# Windows resolves it. cygpath -m is exact; the sed fallback covers stripped installs.
to_win() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1" | sed 's|^/\([a-zA-Z]\)/|\U\1:/|'; }

# High-entropy uniqueness that does NOT depend on $RANDOM reseeding -- makes the dispatch
# leaf and the no-session token collision-proof even under a same-PID/same-second reuse.
# 16 hex chars from /dev/urandom; falls back to concatenated $RANDOM if urandom is absent.
uniq_hex() { od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%s%s%s' "$RANDOM" "$RANDOM" "$RANDOM"; }

# Atomic, non-truncating write: temp file in the same dir, then rename. Never clobbers
# a shared file mid-read; a concurrent dispatch has its own unique filename anyway.
atomic_write() { local dest="$1" tmp; mkdir -p "$(dirname "$dest")"; tmp="$(mktemp "${dest}.XXXXXX")"; cat > "$tmp"; mv -f "$tmp" "$dest"; }

is_uuid() { [[ "${1:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }
need_codex() {
    command -v codex &>/dev/null || { echo "ERROR: 'codex' not found on PATH. Install the Codex CLI first." >&2; exit 1; }
}

# --- Parse mode and arguments ---
MODE="filedrop"
SESSION_ID="${CODEX_SESSION_ID:-}"
IPC_CID=""
TASK=""

# --- Foreground policy for live Desktop IPC (--ipc only; see SKILL.md) ---
# defer (default): never navigate the visible Codex app; switch: navigate it to the
# target with explicit acknowledgement; restore-if-known: fail-closed this milestone.
FOREGROUND_POLICY="${CODEX_IPC_FOREGROUND_POLICY:-defer}"
FOREGROUND_POLICY_SOURCE="${CODEX_IPC_FOREGROUND_POLICY:+env}"
FOREGROUND_POLICY_SOURCE="${FOREGROUND_POLICY_SOURCE:-default}"
ACK_FOREGROUND_SWITCH=0
ACK_SOURCE="none"
# Standing approval is deliberately loud: it is printed on every --ipc send below.
if [[ "${CODEX_IPC_FOREGROUND_SWITCH_STANDING_APPROVAL:-0}" == "1" ]]; then
    ACK_FOREGROUND_SWITCH=1
    ACK_SOURCE="standing-approval-env"
fi
TASK_AFTER_DASHDASH=0

# Reject a flag-looking token captured as the task (the real task was likely dropped).
# --allow-any-thread is a CLIENT flag the wrapper sets internally; it is NOT a wrapper arg.
guard_task() {
    if [[ "$TASK" == --* ]]; then
        echo "ERROR: the task looks like a flag ('$TASK') -- the real task was likely dropped." >&2
        echo "Note: --allow-any-thread is a CLIENT flag set internally by this wrapper; do NOT pass" >&2
        echo "it (or any flag) as a wrapper argument. Usage: $0 --ipc <conversationId> \"<task>\"" >&2
        exit 1
    fi
}

case "${1:-}" in
    --exec)
        MODE="exec"; shift
        if [[ -z "${1:-}" ]]; then
            echo "ERROR: --exec requires a task: $0 --exec \"task\" [session_id]" >&2
            exit 1
        fi
        TASK="${1}"; guard_task
        is_uuid "${2:-}" && SESSION_ID="${2}"
        ;;
    --ipc)
        MODE="ipc"; shift
        if ! is_uuid "${1:-}"; then
            echo "ERROR: --ipc requires a conversationId (UUID): $0 --ipc <conversationId> \"task\"" >&2
            echo "Find the id in the Codex Desktop thread, or via state inspection. Mechanism injects" >&2
            echo "straight into that live GUI thread; falls back to file-drop on any failure." >&2
            exit 1
        fi
        IPC_CID="${1}"; shift
        # Foreground-policy argument loop. Canonical grammar:
        #   --ipc <uuid> [--foreground-policy defer|switch|restore-if-known]
        #                [--ack-foreground-switch] [--] "<task>"
        # Legacy `--ipc <uuid> "<task>"` is preserved; the historical client-only
        # `--allow-any-thread` is absorbed as before; a bare `--` ends flag parsing so a
        # task may legitimately begin with a dash. Unknown flags fail closed.
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --allow-any-thread)
                    # Client flag set internally by this wrapper; absorbed, never forwarded.
                    shift;;
                --foreground-policy)
                    if [[ -z "${2:-}" ]]; then
                        echo "ERROR: --foreground-policy requires a value (defer|switch|restore-if-known)." >&2
                        exit 1
                    fi
                    FOREGROUND_POLICY="$2"; FOREGROUND_POLICY_SOURCE="flag"; shift 2;;
                --ack-foreground-switch)
                    ACK_FOREGROUND_SWITCH=1; ACK_SOURCE="flag"; shift;;
                --)
                    TASK_AFTER_DASHDASH=1; shift; break;;
                --*)
                    echo "ERROR: unknown --ipc flag '$1'." >&2
                    echo "Usage: $0 --ipc <conversationId> [--foreground-policy defer|switch|restore-if-known] [--ack-foreground-switch] [--] \"<task>\"" >&2
                    exit 1;;
                *)
                    break;;
            esac
        done
        if [[ -z "${1:-}" ]]; then
            echo "ERROR: --ipc requires a task: $0 --ipc <conversationId> [flags] [--] \"task\"" >&2
            exit 1
        fi
        TASK="${1}"; shift
        # After an explicit `--`, a dash-leading task is intentional; otherwise a
        # flag-shaped task means the real task was dropped (fail closed).
        [[ "$TASK_AFTER_DASHDASH" -eq 1 ]] || guard_task
        if [[ $# -gt 0 ]]; then
            echo "ERROR: unexpected trailing argument(s) after the task: $*" >&2
            echo "(The task must be the final argument; quote it as one string.)" >&2
            exit 1
        fi
        ;;
    --open)
        MODE="open"
        is_uuid "${2:-}" && SESSION_ID="${2}"
        ;;
    --app)
        MODE="app"
        ;;
    "")
        printf "ERROR: No task provided.\n\nUsage:\n  %s \"task for Codex\"               # file-drop handoff (recommended default)\n  %s --ipc <conversationId> \"task\"  # inject into a live Desktop GUI thread (opt-in)\n  %s --open [session_id]            # open session in TUI\n  %s --app                          # open Codex desktop app\n  %s --exec \"task\" [session_id]     # headless exec (not visible in GUI)\n" "$0" "$0" "$0" "$0" "$0" >&2
        exit 1
        ;;
    --*)
        echo "ERROR: Unknown flag '$1'." >&2
        exit 1
        ;;
    *)
        TASK="${1}"; guard_task
        is_uuid "${2:-}" && SESSION_ID="${2}"
        ;;
esac

# --- OPEN modes need PROJECT_ROOT; resolve a usable cwd (they are repo-oriented) ---
OPEN_ROOT="${PROJECT_ROOT:-$PWD}"

# --- OPEN IN DESKTOP APP ---
if [[ "$MODE" == "app" ]]; then
    need_codex
    echo "Opening Codex desktop app at ${OPEN_ROOT}..."
    codex app "${OPEN_ROOT}"
    exit 0
fi

# --- OPEN IN TUI ---
if [[ "$MODE" == "open" ]]; then
    need_codex
    echo "Opening Codex TUI${SESSION_ID:+ (session: ${SESSION_ID})}..."
    (
        cd "${OPEN_ROOT}"
        if [[ -n "$SESSION_ID" ]]; then
            codex resume "${SESSION_ID}"
        else
            codex resume --last
        fi
    )
    exit $?
fi

# --- Resolve Claude's own session id (channel key + optional transcript pointer) ---
# CLAUDE_CODE_SESSION_ID is injected by Claude Code. If absent, use an isolated
# per-invocation token so concurrent sessions never collide -- and deliberately do NOT
# guess another session's transcript (that was a cross-session cross-talk vector).
CLAUDE_SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
if [[ -n "$CLAUDE_SID" ]]; then
    SID_INJECTED=1
else
    SID_INJECTED=0
    CLAUDE_SID="nosid-$$-$(date +%s)-$(uniq_hex)"
fi

# --- Compute the keyed per-dispatch transport channel ---
CHANNEL_THREAD="${IPC_CID:-filedrop}"
DISPATCH_ID="$(date +%s)-$$-$(uniq_hex)"
CHANNEL_DIR="${IPC_ROOT}/${CLAUDE_SID}/${CHANNEL_THREAD}"
# Opportunistic bounded-retention sweep (principle-7: bound operational telemetry).
# Prune envelopes older than N days BEFORE creating this dispatch's dir, so the fresh
# (still-empty) channel dir is never swept. Envelopes carry repo/transcript pointers, so
# this bounds stale-disclosure, not just disk. Env-tunable via CODEX_IPC_RETENTION_DAYS; 0 disables.
RETENTION_DAYS="${CODEX_IPC_RETENTION_DAYS:-7}"
if [[ "$RETENTION_DAYS" =~ ^[0-9]+$ && "$RETENTION_DAYS" -gt 0 ]]; then
    find "$IPC_ROOT" -type f \( -name '*.task.md' -o -name '*.reply.md' \) -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
    find "$IPC_ROOT" -mindepth 1 -type d -empty -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
fi
mkdir -p "$CHANNEL_DIR"
OUTBOUND_MSYS="${CHANNEL_DIR}/${DISPATCH_ID}.task.md"   # Claude Code -> Codex (this dispatch)
INBOUND_MSYS="${CHANNEL_DIR}/${DISPATCH_ID}.reply.md"   # Codex -> Claude Code (this dispatch)
OUTBOUND="$(to_win "$OUTBOUND_MSYS")"
INBOUND="$(to_win "$INBOUND_MSYS")"

# --- Gather git context (payload enrichment only; all optional) ---
if [[ -n "$PROJECT_ROOT" ]]; then
    BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
    MAIN_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||' || echo "main")
    STAMP=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "unknown time")
    RECENT_COMMITS=$(git log --oneline "${MAIN_BRANCH}..HEAD" 2>/dev/null \
        || git log --oneline -8 2>/dev/null \
        || echo "(no git log available)")
    DIFF_STAT=$(git diff --stat "${MAIN_BRANCH}" 2>/dev/null \
        || git diff --stat HEAD 2>/dev/null \
        || echo "(no diff available)")
    UNCOMMITTED=$(git status --short 2>/dev/null || echo "")
else
    BRANCH="(not in a git repository)"; MAIN_BRANCH="main"
    STAMP=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "unknown time")
    RECENT_COMMITS="(no repository context)"; DIFF_STAT="(no repository context)"; UNCOMMITTED=""
fi
EFFORT_NOTE=""
[[ -n "${CODEX_REASONING_EFFORT:-}" ]] && EFFORT_NOTE="
## Suggested reasoning effort
${CODEX_REASONING_EFFORT}"

# --- Resolve Claude's own session transcript (OPT-IN orientation aid) ---
# Transcript paths expose the full local session context, so they are included only
# when CODEX_IPC_INCLUDE_TRANSCRIPT=1. Even then, resolve only the CURRENT session's
# transcript (session id actually injected); never guess another session's transcript.
TRANSCRIPT_NOTE="(transcript path omitted by default; re-run with CODEX_IPC_INCLUDE_TRANSCRIPT=1 to include it)"
if [[ "${CODEX_IPC_INCLUDE_TRANSCRIPT:-0}" == "1" ]]; then
    CLAUDE_TRANSCRIPT="${CLAUDE_TRANSCRIPT:-}"
    if [[ -z "$CLAUDE_TRANSCRIPT" && "$SID_INJECTED" -eq 1 && -n "$PROJECT_ROOT" ]]; then
        CLAUDE_PROJ_DIR="${HOME}/.claude/projects/$(printf '%s' "$PROJECT_ROOT" | tr ':/_' '---')"
        if [[ -f "${CLAUDE_PROJ_DIR}/${CLAUDE_SID}.jsonl" ]]; then
            CLAUDE_TRANSCRIPT="${CLAUDE_PROJ_DIR}/${CLAUDE_SID}.jsonl"
        fi
    fi
    if [[ -n "$CLAUDE_TRANSCRIPT" ]]; then
        TRANSCRIPT_NOTE="$(to_win "$CLAUDE_TRANSCRIPT")"
    else
        TRANSCRIPT_NOTE="(transcript path unavailable on this machine)"
    fi
fi

# --- Build handoff payload ---
WORKDIR="${PROJECT_ROOT:-$PWD}"
read -r -d '' PAYLOAD <<EOF || true
# Handoff from Claude Code -> Codex

Generated: ${STAMP} on branch \`${BRANCH}\` (dispatch ${DISPATCH_ID})

## How to use this file
You (Codex) have been handed follow-up work from a Claude Code session.
Read the **Task** below and complete it in the associated workspace at:
  ${WORKDIR}
When finished, write your reply/result to this per-dispatch reply file (create it):
  ${INBOUND}
Use that absolute path exactly. It is unique to this handoff, so your reply is
correlated to this task with no ambiguity even if other handoffs are in flight.

## Branch
${BRANCH}  (merge target: ${MAIN_BRANCH})

## Commits on this branch (not yet on ${MAIN_BRANCH})
${RECENT_COMMITS}

## Files changed vs ${MAIN_BRANCH}
${DIFF_STAT}${UNCOMMITTED:+

## Uncommitted changes
${UNCOMMITTED}}${EFFORT_NOTE}

## Task
${TASK}

## Claude session context (optional -- for deeper investigation)
Produced by Claude Code session: ${CLAUDE_SID}
Claude transcript pointer (only present when the sender opted in with
CODEX_IPC_INCLUDE_TRANSCRIPT=1; if it is a path, the JSONL is large -- grep or tail it for the
relevant part; it may include context unrelated to this task):
  ${TRANSCRIPT_NOTE}

When you reply in ${INBOUND}, include your Codex session/conversation id if it is available to
you. (If it is not exposed to you, that is fine: for --ipc handoffs Claude already knows it as the
conversationId, and can otherwise locate your rollout under ~/.codex/sessions/ by this handoff.)
EOF

# --- FILE-DROP (default) ---
if [[ "$MODE" == "filedrop" ]]; then
    printf '%s\n' "$PAYLOAD" | atomic_write "$OUTBOUND_MSYS"
    echo "[ Handoff written to ${OUTBOUND} ]"
    echo ""
    echo "Next step -- in your Codex session (Desktop app or TUI), paste:"
    echo ""
    echo "    read \"${OUTBOUND}\" and proceed"
    echo ""
    echo "When Codex finishes, it writes its reply to ${INBOUND} (Claude Code reads it)."
    exit 0
fi

# --- IPC INJECT (opt-in; delivers straight into a live Desktop GUI thread) ---
# Writes the file-drop first (so the fallback is always ready), then injects the
# pickup line into the live thread via the proven owner-gated router route.
# If no Desktop renderer owns the thread (router error "no-client-found"), the
# thread is auto-loaded via the app's own codex://threads/<id> deep link with
# automatic focus snapback (codex_ipc_autoload.ps1; foreground-aware: defers
# while the operator is actively in the Codex app), then the send is retried.
# Model/reasoning are renderer-controlled: this CANNOT change the thread's model
# or reasoning effort, nor any other session's. Falls back to file-drop on failure.
# Result taxonomy: gui-delivered | gui-unowned | failed-closed.
if [[ "$MODE" == "ipc" ]]; then
    printf '%s\n' "$PAYLOAD" | atomic_write "$OUTBOUND_MSYS"
    echo "[ Handoff written to ${OUTBOUND} ]"
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    fallback() {
        echo "" >&2
        echo "FALLBACK -- file-drop is ready. In your Codex session, paste:" >&2
        echo "    read \"${OUTBOUND}\" and proceed" >&2
    }
    # Active policy and acknowledgement source are printed on EVERY --ipc send so a
    # standing approval can never act silently.
    echo "POLICY: foreground=${FOREGROUND_POLICY} (source: ${FOREGROUND_POLICY_SOURCE}) ack=${ACK_SOURCE}"
    # Semantic policy validation AFTER the envelope write (file-drop-first invariant):
    # a valid UUID/task invocation always leaves a usable fallback behind.
    case "$FOREGROUND_POLICY" in
        defer|switch|restore-if-known) : ;;
        *)
            echo "RESULT: failed-closed -- reason=invalid-foreground-policy -- confirmation=not-attempted" >&2
            echo "('${FOREGROUND_POLICY}' is not one of: defer, switch, restore-if-known.)" >&2
            fallback
            exit 1;;
    esac
    if [[ "$FOREGROUND_POLICY" == "switch" && "$ACK_FOREGROUND_SWITCH" -ne 1 ]]; then
        echo "RESULT: failed-closed -- reason=foreground-switch-unacknowledged -- confirmation=not-attempted" >&2
        echo "(--foreground-policy switch requires --ack-foreground-switch or" >&2
        echo " CODEX_IPC_FOREGROUND_SWITCH_STANDING_APPROVAL=1; it visibly navigates the Codex app.)" >&2
        fallback
        exit 1
    fi
    if ! command -v node &>/dev/null; then
        echo "ERROR: node not found; --ipc needs Node." >&2
        echo "RESULT: failed-closed -- reason=node-unavailable -- confirmation=not-attempted" >&2
        fallback
        exit 1
    fi
    IPC_OUTPUT=""
    send_live() {
        IPC_OUTPUT=$(node "${SCRIPT_DIR}/codex_ipc_client.mjs" \
            --thread "${IPC_CID}" \
            --task "read \"${OUTBOUND}\" and proceed" \
            --allow-any-thread --send --ack-live-write --timeout-ms 9000 2>&1)
    }
    echo "Injecting pickup line into live Desktop thread ${IPC_CID} via IPC router..."
    if send_live; then
        echo "[ Delivered into live thread ${IPC_CID}. It should appear in your Codex Desktop GUI. ]"
        echo "RESULT: gui-delivered -- reason=renderer-owned -- confirmation=not-checked"
        echo "Codex's reply will be written to ${INBOUND} (Claude Code reads it)."
        exit 0
    fi
    if ! printf '%s' "$IPC_OUTPUT" | grep -q '"error": *"no-client-found"'; then
        # Router/pipe-level failure (app closed, timeout, protocol drift) -- not an
        # ownership condition, so auto-load would be pointless or misleading.
        echo "RESULT: failed-closed -- reason=router-pipe-failure -- confirmation=not-attempted" >&2
        printf '%s\n' "$IPC_OUTPUT" | sed -n '1,20p' >&2
        fallback
        exit 1
    fi
    # Guard the unowned path: never deep-link a target that does not exist or is archived.
    # Positive proof is required: exactly `"ok": true` and not archived may proceed.
    # Empty output, stderr-only output, malformed JSON, or schema drift (neither ok-marker
    # present) is ambiguity, and ambiguity is not permission to navigate — fail closed.
    INSPECT_OUTPUT=$(node "${SCRIPT_DIR}/codex_ipc_session_inspect.mjs" --thread "${IPC_CID}" --tail-events 1 2>&1) || true
    if printf '%s' "$INSPECT_OUTPUT" | grep -q '"ok": false'; then
        echo "RESULT: failed-closed -- reason=target-not-found -- confirmation=not-attempted" >&2
        echo "(Target thread not found in local Codex state; refusing to auto-load.)" >&2
        fallback
        exit 1
    elif printf '%s' "$INSPECT_OUTPUT" | grep -q '"ok": true'; then
        if printf '%s' "$INSPECT_OUTPUT" | grep -q '"archived": 1'; then
            echo "RESULT: failed-closed -- reason=target-archived -- confirmation=not-attempted" >&2
            echo "(Target thread is archived; unarchive it in the app first.)" >&2
            fallback
            exit 1
        fi
    else
        echo "RESULT: failed-closed -- reason=target-inspection-ambiguous -- confirmation=not-attempted" >&2
        echo "(Inspector output was empty, malformed, or schema-drifted; refusing to auto-load.)" >&2
        printf '%s\n' "$INSPECT_OUTPUT" | sed -n '1,10p' >&2
        fallback
        exit 1
    fi
    echo "Thread ${IPC_CID} is not loaded in Codex Desktop (no-client-found)."
    echo "Auto-loading via codex://threads/... (policy: ${FOREGROUND_POLICY})..."
    AUTOLOAD_PS1="${SCRIPT_DIR}/codex_ipc_autoload.ps1"
    AUTOLOAD_STATUS=0
    AUTOLOAD_OUTPUT=""
    if [[ -f "$AUTOLOAD_PS1" ]] && command -v powershell.exe &>/dev/null; then
        AUTOLOAD_WIN_PATH=$(cygpath -w "$AUTOLOAD_PS1" 2>/dev/null || printf '%s' "$AUTOLOAD_PS1")
        AUTOLOAD_ARGS=(-ConversationId "${IPC_CID}" -ForegroundPolicy "${FOREGROUND_POLICY}")
        [[ "$ACK_FOREGROUND_SWITCH" -eq 1 ]] && AUTOLOAD_ARGS+=(-AckForegroundSwitch)
        if AUTOLOAD_OUTPUT=$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$AUTOLOAD_WIN_PATH" "${AUTOLOAD_ARGS[@]}" 2>&1); then
            AUTOLOAD_STATUS=0
        else
            AUTOLOAD_STATUS=$?
        fi
    else
        AUTOLOAD_STATUS=3
    fi
    # Total status handling: every helper exit code has an explicit branch, and anything
    # unrecognized fails closed instead of falling through into the live-retry loop.
    case "$AUTOLOAD_STATUS" in
        0)  : ;;  # deep-link permitted/completed; proceed to the retry poll below
        1)  echo "WARNING: focus restore could not be verified after auto-load." >&2
            printf '%s\n' "$AUTOLOAD_OUTPUT" | sed -n '1,5p' >&2 ;;
        2)  if [[ "$FOREGROUND_POLICY" == "defer" ]]; then
                echo "RESULT: gui-unowned -- reason=codex-foreground-deferred -- confirmation=not-attempted" >&2
                echo "(You are actively working in Codex; deferred instead of switching your view. Rerun /ipc" >&2
                echo " when convenient, use --foreground-policy switch --ack-foreground-switch, or open" >&2
                echo " codex://threads/${IPC_CID} yourself.)" >&2
            else
                echo "RESULT: gui-unowned -- reason=foreground-unidentified -- confirmation=not-attempted" >&2
                echo "(The foreground app could not be identified as Codex; refusing to auto-switch.)" >&2
            fi
            fallback
            exit 1 ;;
        3)  echo "WARNING: autoload helper unavailable (missing codex_ipc_autoload.ps1 or powershell.exe); polling anyway." >&2 ;;
        4)  echo "RESULT: gui-unowned -- reason=foreground-restore-unproven -- confirmation=not-attempted" >&2
            echo "(restore-if-known is fail-closed until a read-only selected-thread authority is proven.)" >&2
            fallback
            exit 1 ;;
        5)  echo "RESULT: failed-closed -- reason=foreground-switch-unacknowledged -- confirmation=not-attempted" >&2
            fallback
            exit 1 ;;
        *)  echo "RESULT: failed-closed -- reason=autoload-unexpected-status -- confirmation=not-attempted" >&2
            echo "(Helper exit status ${AUTOLOAD_STATUS} is not part of the autoload contract.)" >&2
            printf '%s\n' "$AUTOLOAD_OUTPUT" | sed -n '1,5p' >&2
            fallback
            exit 1 ;;
    esac
    # Bounded retry poll. Timing knobs exist for hermetic tests only; defaults preserve
    # the historical 30s/2s behavior.
    POLL_DEADLINE_S="${CODEX_IPC_POLL_DEADLINE_S:-30}"
    POLL_INTERVAL_S="${CODEX_IPC_POLL_INTERVAL_S:-2}"
    [[ "$POLL_DEADLINE_S" =~ ^[0-9]+$ ]] || POLL_DEADLINE_S=30
    [[ "$POLL_INTERVAL_S" =~ ^[0-9]+$ ]] || POLL_INTERVAL_S=2
    DEADLINE=$((SECONDS + POLL_DEADLINE_S))
    while (( SECONDS < DEADLINE )); do
        sleep "$POLL_INTERVAL_S"
        if send_live; then
            DELIVER_REASON="auto-loaded"
            [[ "$FOREGROUND_POLICY" == "switch" ]] && DELIVER_REASON="foreground-switched"
            echo "[ Delivered into live thread ${IPC_CID}. It should appear in your Codex Desktop GUI. ]"
            echo "RESULT: gui-delivered -- reason=${DELIVER_REASON} -- confirmation=not-checked"
            echo "(Auto-load residue: the Codex window is now on this thread. Confirmation is not-checked:" >&2
            echo " bounded rollout observation is a planned follow-up; re-inspect if delivery certainty matters.)" >&2
            echo "Codex's reply will be written to ${INBOUND} (Claude Code reads it)."
            exit 0
        fi
    done
    echo "RESULT: gui-unowned -- reason=autoload-incomplete -- confirmation=not-attempted" >&2
    echo "(Auto-load did not complete within the ${POLL_DEADLINE_S}s poll window. Manual remediation:" >&2
    echo " open codex://threads/${IPC_CID} in the app, then rerun /ipc.)" >&2
    fallback
    exit 1
fi

# --- HEADLESS EXEC (opt-in; NOT visible in the Desktop GUI) ---
if [[ "$MODE" == "exec" ]]; then
    need_codex
    # Model/reasoning pins are OPT-IN: passed only when the caller sets CODEX_MODEL /
    # CODEX_REASONING_EFFORT. When unset, Codex's own configured defaults apply.
    REASONING_EFFORT="${CODEX_REASONING_EFFORT:-}"
    MODEL="${CODEX_MODEL:-}"
    PIN_ARGS=()
    [[ -n "$MODEL" ]] && PIN_ARGS+=(-m "$MODEL")
    [[ -n "$REASONING_EFFORT" ]] && PIN_ARGS+=(-c "model_reasoning_effort=${REASONING_EFFORT}")
    RESUME_ARGS=()
    if [[ -n "$SESSION_ID" ]]; then RESUME_ARGS=("$SESSION_ID"); else RESUME_ARGS=("--last"); fi

    echo "NOTE: --exec is headless. The result will NOT appear in the Codex Desktop GUI."
    echo "Sending to Codex (model: ${MODEL:-config default}, reasoning: ${REASONING_EFFORT:-config default}${SESSION_ID:+, session: ${SESSION_ID}})..."
    (
        cd "${WORKDIR}"
        # -m and -c are per-invocation pins: they do NOT modify ~/.codex/config.toml and have
        # NO effect on any other running Codex session. They are added only when set above.
        printf '%s\n' "$PAYLOAD" \
            | codex exec resume "${RESUME_ARGS[@]}" - \
                -o "$INBOUND" \
                ${PIN_ARGS[@]+"${PIN_ARGS[@]}"} \
                2>&1 \
            | grep -v "failed to load skill" \
            | grep -v "ERROR codex_core" \
            | grep -v "ERROR codex_memories" \
            | grep -v "^SUCCESS: The process with PID" \
            | grep -v "^tokens used" \
            | grep -v "^[0-9][0-9,]*$"
    )
    echo ""
    echo "[ Reply saved to ${INBOUND} ]"
    exit 0
fi
