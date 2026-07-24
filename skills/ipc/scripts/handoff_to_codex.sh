#!/usr/bin/env bash
# Hand off work from Claude Code to Codex.
#
# DEFAULT (file-drop, GUI-safe): write a self-contained handoff to a per-dispatch
# transport file, then you paste one line into your live Codex session (Desktop app
# or TUI) to pick it up.
#   ./scripts/handoff_to_codex.sh "task for Codex"
#
# Live mode:
#   ./scripts/handoff_to_codex.sh --ipc <conversationId> "task"  # inject into a live Desktop GUI thread
#   ./scripts/handoff_to_codex.sh --ipc <conversationId> \
#       [--foreground-policy defer|switch|restore-if-known] [--ack-foreground-switch] [--] "task"
#
# The file-drop default is the recommended path: it appears in the Codex Desktop GUI (your own session
# reads the file) and has zero effect on any other running Codex session.
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
#   CODEX_IPC_RETENTION_DAYS=<n>       prune transport files older than n days on each run.
#                                      KEEP-ONLY BY DEFAULT: unset, empty and 0 all mean never
#                                      delete; pruning requires an explicit positive integer.
#                                      When enabled: aged *.reply.md files, and aged
#                                      *.task.md files whose same-dispatch *.reply.md exists, are
#                                      deleted. An UNREPLIED *.task.md is NEVER age-deleted: an
#                                      outstanding dispatch is kept until it is answered, and
#                                      pairing ambiguity errs toward retention.
#   CODEX_IPC_INCLUDE_TRANSCRIPT=1     include the Claude transcript path in the handoff payload
#                                      (default: omitted; transcript paths expose full session context)
#   CODEX_REASONING_EFFORT=<level>     advisory note added to the handoff when set
#   CODEX_IPC_FOREGROUND_POLICY=<p>    --ipc foreground policy default: defer|switch|restore-if-known
#                                      (default defer; the --foreground-policy flag overrides)
#   CODEX_IPC_FOREGROUND_SWITCH_STANDING_APPROVAL=1
#                                      standing acknowledgement for switch policy (printed on
#                                      every send when active; prefer per-invocation
#                                      --ack-foreground-switch)
#   CODEX_IPC_POLL_DEADLINE_S=<n>      auto-load retry poll window (default 30; test knob)
#   CODEX_IPC_POLL_INTERVAL_S=<n>      auto-load retry poll interval (default 2; test knob)
#   CODEX_IPC_OBSERVE_BUDGET_MS=<n>    post-acceptance rollout observation cap
#                                      (default 8000; provisional)
#   CODEX_IPC_OBSERVE_INTERVAL_MS=<n>  positive rollout observation interval override

set -euo pipefail

# v0.1.8 removes every Codex-CLI-backed mode. Reject these flags before transport-root
# resolution, project inspection, retention, envelope publication, or any child launch.
case "${1:-}" in
    --app)
        printf '%s\n' 'ERROR: --app was removed in v0.1.8 (No Codex CLI); use positional file-drop ("task") or --ipc <conversationId> "task".' >&2
        exit 64
        ;;
    --open)
        printf '%s\n' 'ERROR: --open was removed in v0.1.8 (No Codex CLI); use positional file-drop ("task") or --ipc <conversationId> "task".' >&2
        exit 64
        ;;
    --exec)
        printf '%s\n' 'ERROR: --exec was removed in v0.1.8 (No Codex CLI); use positional file-drop ("task") or --ipc <conversationId> "task".' >&2
        exit 64
        ;;
esac

# --- Machine-local IPC transport root (repo/CWD-independent) ---
IPC_ROOT="${CODEX_IPC_ROOT:-${HOME}/.claude/ipc}"
# Reject a newline in the root (would corrupt the payload heredoc / pickup line).
# An apostrophe is legal in a Windows path (e.g. user "O'Brien"); the pickup instruction
# double-quotes the path and Windows forbids '"' in paths, so no escaping is needed.
case "$IPC_ROOT" in *$'\n'*) echo "ERROR: CODEX_IPC_ROOT must not contain a newline." >&2; exit 1;; esac
IPC_ROOT_REAL="$(cd "$IPC_ROOT" 2>/dev/null && pwd -P || printf '%s' "$IPC_ROOT")"
HOME_REAL="$(cd "$HOME" 2>/dev/null && pwd -P || printf '%s' "$HOME")"
RETENTION_SWEEP_OK=1
case "$IPC_ROOT_REAL" in
    ""|/|"$HOME_REAL"|/[A-Za-z]|/[A-Za-z]/|[A-Za-z]:|[A-Za-z]:/|[A-Za-z]:\\)
        RETENTION_SWEEP_OK=0
        ;;
esac

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

# Create-once publication: temp file in the same dir, then a link that FAILS if the
# destination already exists. `mv -f` would silently clobber a pre-existing envelope;
# `ln` is the atomic create-once primitive on both NTFS and POSIX. A same-name
# collision is a hard error, never a silent overwrite -- an envelope that already
# exists may be in flight, and destroying it loses a dispatch.
atomic_write() {
    local dest="$1" tmp
    mkdir -p "$(dirname "$dest")"
    # If anything already occupies the exact destination path -- a regular file, a
    # directory, or a symlink -- refuse. This is what stops `ln` from creating a link
    # INSIDE a directory named dest (so no GNU-only `ln -T` is needed -- portable to
    # BSD/macOS `ln`), and it lets a genuine collision be reported as a collision rather
    # than conflated with the environmental link failure below.
    if [[ -e "$dest" || -L "$dest" ]]; then
        echo "ERROR: refusing to overwrite existing path \"${dest}\"." >&2
        echo "(Create-once publication: a same-name envelope already exists and may be in flight.)" >&2
        return 1
    fi
    tmp="$(mktemp "${dest}.XXXXXX")"
    cat > "$tmp"
    # Portable create-once link (no GNU-only flags). The pre-check above already rules
    # out a directory/symlink at dest, so a plain `ln` cannot descend into one.
    if ! ln "$tmp" "$dest" 2>/dev/null; then
        rm -f "$tmp"
        if [[ -e "$dest" || -L "$dest" ]]; then
            echo "ERROR: refusing to overwrite existing path \"${dest}\" (won a create race)." >&2
        else
            echo "ERROR: could not publish \"${dest}\" (link failed: permission, filesystem, or quota)." >&2
            echo "(This is an environmental failure, not a collision; nothing was published.)" >&2
        fi
        return 1
    fi
    # The link succeeded, so the destination is published. A failure to remove the
    # staging hard-link must NOT propagate as a publication failure -- the envelope
    # exists and a caller must not retry. Clean up best-effort and report success.
    rm -f "$tmp" 2>/dev/null || echo "WARNING: staging residue left at \"${tmp}\" (destination published OK)." >&2
    return 0
}

is_uuid() { [[ "${1:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }

# Test seam: allow a hermetic unit test to SOURCE the helper functions (atomic_write,
# to_win, uniq_hex, is_uuid) without running any dispatch. It is honored ONLY when the
# script is sourced (BASH_SOURCE[0] != $0) AND the value is exactly 1. An EXECUTED
# wrapper ignores it entirely, so an inherited _TEST_SOURCE_ONLY in the environment can
# never silently suppress a real dispatch (the previous guard exited 0 without
# dispatching on any inherited nonempty value, including "0" -- a silent-success footgun).
if [[ "${_TEST_SOURCE_ONLY:-}" == "1" && "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

# --- Parse mode and arguments ---
MODE="filedrop"
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
    "")
        printf "ERROR: No task provided.\n\nUsage:\n  %s \"task for Codex\"               # file-drop handoff (recommended default)\n  %s --ipc <conversationId> \"task\"  # inject into a live Desktop GUI thread (opt-in)\n" "$0" "$0" >&2
        exit 1
        ;;
    --*)
        echo "ERROR: Unknown flag '$1'." >&2
        exit 1
        ;;
    *)
        TASK="${1}"; guard_task
        ;;
esac

# --- Resolve Claude's own session id (channel key + optional transcript pointer) ---
# CLAUDE_CODE_SESSION_ID is injected by Claude Code. If absent, use an isolated
# per-invocation token so concurrent sessions never collide -- and deliberately do NOT
# guess another session's transcript (that was a cross-session cross-talk vector).
CLAUDE_SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
if [[ -n "$CLAUDE_SID" ]]; then
    # Containment: the session id becomes a path segment under the transport root, so it must be
    # exactly one safe segment. A separator, a dot segment, a drive letter, or a control byte
    # would place the envelope outside CODEX_IPC_ROOT. Fail closed rather than sanitize: a
    # rewritten id would silently split one session's channel in two.
    if [[ "$CLAUDE_SID" == *".."* ]] || [[ ! "$CLAUDE_SID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
        echo "ERROR: refusing unsafe session id: must be one path segment matching [A-Za-z0-9][A-Za-z0-9._-]{0,127} and contain no '..'." >&2
        exit 1
    fi
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
#
# UNREPLIED-TASK EXEMPTION (fail-safe): an aged *.task.md is deleted ONLY on positive
# proof that its same-dispatch *.reply.md sibling exists (the dispatch was answered).
# A task with no reply is an outstanding, never-answered dispatch -- age-deleting it is
# silent data loss, so it is retained regardless of age. Task deletion requires a
# positive pairing check, so any task whose pairing cannot be determined is kept, and a
# failed TASK deletion is reported to stderr rather than suppressed. Reply and empty-dir
# deletion failures remain suppressed as before -- their failure mode is retention, not
# loss -- so every branch of the sweep errs toward retention.
# Keep-only by default. Unset, empty, and exact `0` all mean "never delete" -- the
# transport is evidence, and silent age-based deletion of a reply nobody harvested is
# unrecoverable data loss. Pruning is strictly opt-in via an explicit positive integer.
RETENTION_DAYS="${CODEX_IPC_RETENTION_DAYS:-0}"
# Reject a non-canonical value LOUDLY, before any envelope creation, child launch, or
# sweep. Unset/empty/0 mean keep-only; a positive integer prunes. Anything else
# (negative, decimal, whitespace, junk) previously skipped the sweep silently and
# continued -- a caller who fat-fingered a retention value got neither the pruning
# they asked for nor any signal. Fail closed instead of guessing.
# Canonical form only: exactly `0`, or a positive integer with no leading zero. This
# rejects negatives, decimals, whitespace and junk -- AND leading-zero values like `08`,
# which pass a bare ^[0-9]+$ but then throw "value too great for base" in Bash's octal
# arithmetic, silently skipping the sweep while continuing to publish. Fail closed here,
# before any envelope creation or sweep.
if [[ ! "$RETENTION_DAYS" =~ ^(0|[1-9][0-9]*)$ ]]; then
    printf '%s\n' "ERROR: CODEX_IPC_RETENTION_DAYS=\"${CODEX_IPC_RETENTION_DAYS}\" is invalid; use unset, empty, 0 (keep-only), or a positive integer with no leading zero." >&2
    exit 64
fi
if (( 10#$RETENTION_DAYS > 0 )); then
    if [[ "$RETENTION_SWEEP_OK" -eq 1 ]]; then
        # Aged tasks first, deciding pairing BEFORE any reply is deleted below --
        # otherwise an aged pair's task would misread as unreplied and never sweep.
        while IFS= read -r -d '' AGED_TASK; do
            if [[ -f "${AGED_TASK%.task.md}.reply.md" ]]; then
                rm -f -- "$AGED_TASK" \
                    || echo "WARNING: retention sweep could not delete \"${AGED_TASK}\"." >&2
            fi
        done < <(find "$IPC_ROOT" -type f -name '*.task.md' -mtime +"$RETENTION_DAYS" -print0 2>/dev/null)
        # Aged replies are terminal artifacts: sweepable unconditionally, as before.
        find "$IPC_ROOT" -type f -name '*.reply.md' -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
        find "$IPC_ROOT" -mindepth 1 -type d -empty -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
    else
        echo "WARNING: refusing retention sweep for dangerous CODEX_IPC_ROOT \"${IPC_ROOT}\"." >&2
    fi
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

Reply-write policy (a denied write is EXPECTED, not an error): first self-verify your result, then
attempt to write the printed reply path exactly once. If that write is denied by a sandbox or
permission boundary, do NOT retry, debug, request escalation, or substitute another file. Instead,
state the denial in one line AND put the full substantive result (not just the denial) in your final
agent message, then complete the turn. A one-line denial with no result is a contract violation; the
dispatcher recovers a full final message only via the opt-in codex_ipc_wait.mjs
--accept-rollout-fallback path.

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
    # Safe fallback: ONLY for failures classified before any send was attempted
    # (confirmation=not-attempted). Pasting the pickup line is safe because nothing
    # can already be running.
    fallback() {
        echo "" >&2
        echo "FALLBACK -- file-drop is ready. In your Codex session, paste:" >&2
        echo "    read \"${OUTBOUND}\" and proceed" >&2
    }
    # Ambiguous terminal: a send was attempted and its outcome is UNKNOWN. The client
    # writes the follower frame before awaiting the response, so a timeout, closed
    # pipe, or protocol drift can each leave the task already admitted and running.
    # Emitting the pickup line here is what turns one dispatch into two, so it is
    # deliberately NOT printed. The envelope exists; a human must establish whether it
    # already ran before doing anything with it.
    fallback_ambiguous() {
        echo "" >&2
        echo "AMBIGUOUS -- a send was attempted and its outcome is UNKNOWN." >&2
        echo "The task may ALREADY be running in thread ${IPC_CID}." >&2
        echo "Do NOT resend. Inspect the thread first:" >&2
        echo "    node \"${SCRIPT_DIR}/codex_ipc_session_inspect.mjs\" --thread ${IPC_CID} --tail-events 5" >&2
        echo "The envelope is preserved at ${OUTBOUND} -- dispatch it only after" >&2
        echo "confirming the thread did not pick it up." >&2
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
    observe_rollout() {
        local observation=""
        if observation=$(node "${SCRIPT_DIR}/codex_ipc_rollout_observe.mjs" \
            --thread "${IPC_CID}" \
            --dispatch "${DISPATCH_ID}"); then
            case "$observation" in
                rollout-hit|rollout-pending|rollout-unavailable)
                    printf '%s\n' "$observation"
                    return 0
                    ;;
                *)
                    echo "WARNING: rollout observer returned empty or invalid output; using rollout-unavailable." >&2
                    ;;
            esac
        else
            echo "WARNING: rollout observer failed; using rollout-unavailable." >&2
        fi
        printf '%s\n' "rollout-unavailable"
    }
    # D3 wait hint: ONLY the two accepted live --ipc success branches print one POSIX-escaped,
    # runnable WAIT: line (exact thread/dispatch/--reply-path + the D2 flag and 30-minute budget)
    # BEFORE the single final RESULT: line. File-drop, exec, and every failure branch must not.
    print_wait_hint() {
        printf 'WAIT: node %q --thread %q --dispatch %q --reply-path %q --accept-rollout-fallback --budget-ms 1800000 --interval-ms 1000\n' \
            "${SCRIPT_DIR}/codex_ipc_wait.mjs" "$IPC_CID" "$DISPATCH_ID" "$INBOUND"
    }
    echo "Injecting pickup line into live Desktop thread ${IPC_CID} via IPC router..."
    if send_live; then
        CONFIRMATION=$(observe_rollout)
        echo "[ Delivered into live thread ${IPC_CID}. It should appear in your Codex Desktop GUI. ]"
        echo "Codex's reply will be written to ${INBOUND} (Claude Code reads it)."
        print_wait_hint
        echo "RESULT: gui-delivered -- reason=renderer-owned -- confirmation=${CONFIRMATION}"
        exit 0
    fi
    if ! printf '%s' "$IPC_OUTPUT" | grep -q '"error": *"no-client-found"'; then
        # Router/pipe-level failure (app closed, timeout, protocol drift). This is
        # POST-ATTEMPT: the follower frame is written before the response is awaited,
        # so the task may already be admitted. It is not an ownership condition, so
        # auto-load would be pointless or misleading -- and it is not `not-attempted`,
        # so the outcome is reported as UNKNOWN and no pickup line is emitted.
        echo "RESULT: failed-closed -- reason=router-pipe-failure -- confirmation=unknown" >&2
        printf '%s\n' "$IPC_OUTPUT" | sed -n '1,20p' >&2
        fallback_ambiguous
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
    POLL_DEADLINE_S="${CODEX_IPC_POLL_DEADLINE_S-30}"
    POLL_INTERVAL_S="${CODEX_IPC_POLL_INTERVAL_S-2}"
    if [[ ! "$POLL_DEADLINE_S" =~ ^[1-9][0-9]*$ ]]; then
        echo "WARNING: CODEX_IPC_POLL_DEADLINE_S=${POLL_DEADLINE_S} must be a positive integer; using default 30." >&2
        POLL_DEADLINE_S=30
    fi
    if [[ ! "$POLL_INTERVAL_S" =~ ^[1-9][0-9]*$ ]]; then
        echo "WARNING: CODEX_IPC_POLL_INTERVAL_S=${POLL_INTERVAL_S} must be a positive integer; using default 2." >&2
        POLL_INTERVAL_S=2
    fi
    DEADLINE=$((SECONDS + POLL_DEADLINE_S))
    while (( SECONDS < DEADLINE )); do
        sleep "$POLL_INTERVAL_S"
        if send_live; then
            DELIVER_REASON="auto-loaded"
            [[ "$FOREGROUND_POLICY" == "switch" ]] && DELIVER_REASON="foreground-switched"
            CONFIRMATION=$(observe_rollout)
            echo "[ Delivered into live thread ${IPC_CID}. It should appear in your Codex Desktop GUI. ]"
            echo "Codex's reply will be written to ${INBOUND} (Claude Code reads it)."
            echo "(Rollout confirmation reflects bounded pickup observation only; it does not confirm" >&2
            echo " completion or reply-file success.)" >&2
            print_wait_hint
            echo "RESULT: gui-delivered -- reason=${DELIVER_REASON} -- confirmation=${CONFIRMATION}"
            exit 0
        fi
        # Retry ONLY on the authoritative "thread not loaded" answer. Any other
        # failure (timeout, closed pipe, protocol drift) is post-attempt and may have
        # already admitted the task -- retrying it is the duplicate-execution defect
        # this release is named for. Terminate ambiguously instead of looping.
        if ! printf '%s' "$IPC_OUTPUT" | grep -q '"error": *"no-client-found"'; then
            echo "RESULT: failed-closed -- reason=retry-ambiguous-outcome -- confirmation=unknown" >&2
            printf '%s\n' "$IPC_OUTPUT" | sed -n '1,20p' >&2
            fallback_ambiguous
            exit 1
        fi
    done
    # Every iteration ended in an authoritative no-client-found, so nothing was ever
    # admitted and the pickup line is safe to emit.
    echo "RESULT: gui-unowned -- reason=autoload-incomplete -- confirmation=not-attempted" >&2
    echo "(Auto-load did not complete within the ${POLL_DEADLINE_S}s poll window. Manual remediation:" >&2
    echo " open codex://threads/${IPC_CID} in the app, then rerun /ipc.)" >&2
    fallback
    exit 1
fi

