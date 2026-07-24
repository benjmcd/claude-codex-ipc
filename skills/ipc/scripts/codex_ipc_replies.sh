#!/usr/bin/env bash
# Consolidated DERIVED, READ-ONLY view of Codex replies for the IPC skill.
#
# The primary source is the set of per-dispatch reply files under the keyed transport root:
#   ${CODEX_IPC_ROOT:-~/.claude/ipc}/<claudeSessionId>/<conversationId|filedrop>/<dispatchId>.reply.md
# A retained task with no readable primary may use a labeled rollout-derived fallback on stdout.
# This tool never writes/locks/prunes anything and never creates the root. It exists to
# restore the "skim all replies in one place" affordance without the old shared-file commingling bug —
# per-entry (session/thread/dispatch) attribution is what keeps this a view, not a re-commingling.
#
# Usage (Git Bash; flags only, no positionals):
#   codex_ipc_replies.sh [--session <sid>] [-c|--conversation <uuid|filedrop>] [-n <count>]
#                        [--max-bytes <n>] [--since <find -newermt spec>] [--paths-only]
#                        [--list-sessions] [-h|--help]
# Defaults: session = current Claude session (env); all thread dirs merged; -n 10; --max-bytes 4096.
# Exit codes: 0 = success incl. legitimately-empty states; 1 = usage/malformed/enumeration failure;
#             2 = session unresolvable (prints the same session listing --list-sessions prints at exit 0).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex_ipc_safe_render.sh
source "$SCRIPT_DIR/codex_ipc_safe_render.sh"
HARVESTER="$SCRIPT_DIR/codex_ipc_reply_harvest.mjs"

# --- Two one-liners kept in lockstep with handoff_to_codex.sh (do NOT source the wrapper: it parses
# --- argv, runs the reaper, and exits at top level). ---
# kept in lockstep with handoff_to_codex.sh to_win() (uniq_hex not needed here)
to_win() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1" | sed 's|^/\([a-zA-Z]\)/|\U\1:/|'; }
# kept in lockstep with handoff_to_codex.sh is_uuid()
is_uuid() { [[ "${1:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }
valid_session() { [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ && "$1" != "." && "$1" != ".." ]]; }

usage() {
    cat >&2 <<EOF
codex_ipc_replies.sh — consolidated read-only view of Codex replies (derived; never authoritative)
  [--session <sid>]           session dir to read (default: current Claude session from env)
  [-c|--conversation <id>]    narrow to one thread: a Codex conversationId (UUID) or 'filedrop'
  [-n <count>]                max replies to show, newest first (default 10)
  [--max-bytes <n>]           max body bytes per reply (default 4096)
  [--since <find -newermt>]   only replies newer than this spec (e.g. '1 hour ago', '2026-07-06')
  [--paths-only]              list paths/metadata, no bodies (safe when replies may be mid-write)
  [--list-sessions]           list known session dirs (newest reply first) and exit 0
  [-h|--help]                 this help
Note: the session listing printed on an unresolvable-session fallback (exit 2) is identical to what
--list-sessions prints (exit 0) — an explicit query vs a forced fallback.
EOF
}

# --- Transport root (byte-identical to the handoff_to_codex.sh IPC_ROOT resolution; never created here) ---
IPC_ROOT="${CODEX_IPC_ROOT:-${HOME}/.claude/ipc}"
case "$IPC_ROOT" in *$'\n'*) echo "ERROR: CODEX_IPC_ROOT must not contain a newline." >&2; exit 1;; esac
IPC_ROOT="${IPC_ROOT%/}"

# --- Parse flags (fail closed on anything unrecognized) ---
SESSION=""; CONV=""; N=10; MAX_BYTES=4096; SINCE=""; PATHS_ONLY=0; LIST_SESSIONS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --session) SESSION="${2:-}"; shift 2;;
        -c|--conversation) CONV="${2:-}"; shift 2;;
        -n) N="${2:-}"; shift 2;;
        --max-bytes) MAX_BYTES="${2:-}"; shift 2;;
        --since) SINCE="${2:-}"; shift 2;;
        --paths-only) PATHS_ONLY=1; shift;;
        --list-sessions) LIST_SESSIONS=1; shift;;
        -h|--help) usage; exit 0;;
        *) echo "ERROR: unrecognized argument '$1'." >&2; usage; exit 1;;
    esac
done

# --- Validate ---
[[ "$N" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: -n must be a positive integer." >&2; exit 1; }
[[ "$MAX_BYTES" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --max-bytes must be a positive integer." >&2; exit 1; }
if [[ -n "$SESSION" ]]; then
    # allowlist admits UUIDs and nosid-* verbatim; the dot-names '.'/'..' are traversal and rejected explicitly.
    if ! valid_session "$SESSION"; then
        echo "ERROR: invalid --session '$SESSION'." >&2; exit 1
    fi
fi
if [[ -n "$CONV" ]]; then
    # whitelist is complete: handoff_to_codex.sh sets CHANNEL_THREAD="${IPC_CID:-filedrop}" and --ipc
    # validates IPC_CID as a UUID, so no other thread-dir name can exist.
    if [[ "$CONV" != "filedrop" ]] && ! is_uuid "$CONV"; then
        echo "ERROR: -c must be a conversationId (UUID) or 'filedrop'." >&2; exit 1
    fi
fi

# --- Session directory listing (shared by --list-sessions and the exit-2 fallback) ---
list_sessions() {  # prints to the fd the caller redirects; capped at 20, newest reply first
    [[ -d "$IPC_ROOT" ]] || { echo "(no IPC root at \"$(to_win "$IPC_ROOT")\")"; return 0; }
    local d name newest cnt
    # For each session dir, newest reply mtime (0 if none) → sort desc → cap 20.
    for d in "$IPC_ROOT"/*/; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d")"
        newest="$(find "$d" -mindepth 2 -maxdepth 2 -type f -name '*.reply.md' -printf '%T@\n' 2>/dev/null | sort -nr | sed -n '1p')"
        cnt="$(find "$d" -mindepth 2 -maxdepth 2 -type f -name '*.reply.md' 2>/dev/null | wc -l | tr -d ' ')"
        printf '%s\t%s\t%s\n' "${newest:-0}" "$name" "$cnt"
    done | sort -t$'\t' -k1,1nr | sed -n '1,20p' | while IFS=$'\t' read -r m nm c; do
        if [[ "$m" == "0" ]]; then printf '  %-40s  %s replies\n' "$nm" "$c"
        else printf '  %-40s  %s replies (newest %s)\n' "$nm" "$c" "$(date -d "@$m" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$m")"; fi
    done
}

if [[ -d "$IPC_ROOT" ]]; then :; else
    echo "No IPC transport root at \"$(to_win "$IPC_ROOT")\" (nothing sent yet)." >&2
    exit 0
fi

if [[ "$LIST_SESSIONS" -eq 1 ]]; then
    echo "# Known IPC session dirs under \"$(to_win "$IPC_ROOT")\" (newest reply first):"
    list_sessions
    exit 0
fi

# --- Resolve session (mirrors the handoff_to_codex.sh CLAUDE_SID resolution; never guesses/mints a nosid token) ---
if [[ -z "$SESSION" ]]; then
    SESSION="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
fi
if [[ -n "$SESSION" ]] && ! valid_session "$SESSION"; then
    echo "ERROR: invalid resolved session identifier." >&2
    exit 1
fi
if [[ -z "$SESSION" ]]; then
    {
        echo "No session resolved (set --session, or CLAUDE_CODE_SESSION_ID). Known sessions:"
        list_sessions
        echo "(nosid-* dirs are per-invocation; inspect each explicitly with --session — never merged or guessed.)"
    } >&2
    exit 2
fi

SESSION_DIR="${IPC_ROOT}/${SESSION}"
if [[ ! -d "$SESSION_DIR" ]]; then
    echo "No dispatches recorded for session ${SESSION}." >&2
    exit 0
fi

# --- Scope (session-wide, or one thread under -c) ---
if [[ -n "$CONV" ]]; then
    SCOPE_DIR="${SESSION_DIR}/${CONV}"
    if [[ ! -d "$SCOPE_DIR" ]]; then
        echo "No thread ${CONV} under session ${SESSION}." >&2
        exit 0
    fi
else
    SCOPE_DIR="$SESSION_DIR"
fi

# --- --since pre-flight (mandatory before enumeration; makes the fail-closed contract real) ---
if [[ -n "$SINCE" ]]; then
    if ! find "$SCOPE_DIR" -maxdepth 0 -newermt "$SINCE" >/dev/null; then
        echo "ERROR: invalid --since spec '$SINCE' (see error above)." >&2
        exit 1
    fi
fi

# --- Enumeration (exit-status-propagating; retry-once on transient reaper race; hard-fail visibly) ---
# -type f under find's default -P (lstat) is LOAD-BEARING: it excludes directories and symlinks and
# never follows links out of the root. Never add -L/-follow. Suffix-anchored globs exclude temp siblings.
if [[ -n "$CONV" ]]; then SCOPE_DEPTH=(-mindepth 1 -maxdepth 1)
else SCOPE_DEPTH=(-mindepth 2 -maxdepth 2); fi
FIND_ARGS=("${SCOPE_DEPTH[@]}" -type f '(' -name '*.reply.md' -o -name '*.task.md' ')')
[[ -n "$SINCE" ]] && FIND_ARGS+=(-newermt "$SINCE")
enumerate() { find "$SCOPE_DIR" "${FIND_ARGS[@]}" -printf '%T@\t%p\n' 2>/dev/null; }
# `if var=$(...)` is load-bearing: under set -e a bare `raw=$(enumerate)` would EXIT on a transient
# failure before we could retry. The if-condition context suppresses set -e so retry-once works.
if raw="$(enumerate)"; then rc=0; else rc=$?; fi
if [[ $rc -ne 0 ]]; then
    if raw="$(enumerate)"; then rc=0; else rc=$?; fi   # retry once: a concurrent reaper deletion mid-scan is transient
fi
if [[ $rc -ne 0 ]]; then
    find "$SCOPE_DIR" "${FIND_ARGS[@]}" -printf '%T@\t%p\n' >/dev/null || true  # diagnostic: stderr visible
    echo "ERROR: could not enumerate dispatches under \"$(to_win "$SCOPE_DIR")\" (see error above)." >&2
    exit 1
fi

# --- Select one entry per dispatch (reply wins), then sort by mtime desc + path asc. ---
ENTRIES=()
if [[ -n "$raw" ]]; then
    declare -A ENTRY_MT=() ENTRY_PATH=() ENTRY_KIND=()
    while IFS=$'\t' read -r entry_mt entry_path; do
        [[ -n "$entry_path" ]] || continue
        entry_thread="$(basename "$(dirname "$entry_path")")"
        if [[ "$entry_thread" != "filedrop" ]] && ! is_uuid "$entry_thread"; then continue; fi
        if [[ "$entry_path" == *.reply.md ]]; then
            entry_kind="reply"; entry_dispatch="$(basename "$entry_path" .reply.md)"
        else
            entry_kind="task"; entry_dispatch="$(basename "$entry_path" .task.md)"
        fi
        entry_key="$(dirname "$entry_path")/$entry_dispatch"
        if [[ -z "${ENTRY_KIND[$entry_key]+x}" || "$entry_kind" == "reply" ]]; then
            ENTRY_MT[$entry_key]="$entry_mt"
            ENTRY_PATH[$entry_key]="$entry_path"
            ENTRY_KIND[$entry_key]="$entry_kind"
        fi
    done <<<"$raw"
    mapfile -t ENTRIES < <(
        for entry_key in "${!ENTRY_KIND[@]}"; do
            printf '%s\t%s\t%s\n' "${ENTRY_MT[$entry_key]}" "${ENTRY_KIND[$entry_key]}" "${ENTRY_PATH[$entry_key]}"
        done | sort -t$'\t' -k1,1nr -k3,3
    )
fi
TOTAL="${#ENTRIES[@]}"

# --- Banner (always, incl. empty states) ---
NOW="$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo 'unknown time')"
SHOWN=$(( TOTAL < N ? TOTAL : N ))
echo "# Codex replies — DERIVED READ-ONLY VIEW (point-in-time; never authoritative)"
echo "# captured: ${NOW}   session: ${SESSION}${CONV:+   thread: ${CONV}}"
echo "# root: \"$(to_win "$IPC_ROOT")\"   (reply files primary; rollouts are derived fallback)"
echo "# replies are kept by default (CODEX_IPC_RETENTION_DAYS is keep-only unless set to a positive integer);"
echo "# when pruning IS enabled, replies older than that many days are transport-pruned and not shown."
echo "# Showing ${SHOWN} of ${TOTAL} dispatches, newest first${SINCE:+   (--since '${SINCE}')}${CONV:+   (thread ${CONV})}"
echo ""

# --- Render ---
i=0
for entry in "${ENTRIES[@]}"; do
    (( i < N )) || break
    i=$(( i + 1 ))
    mt="${entry%%$'\t'*}"; entry_rest="${entry#*$'\t'}"
    kind="${entry_rest%%$'\t'*}"; p="${entry_rest#*$'\t'}"
    thread="$(basename "$(dirname "$p")")"
    if [[ "$kind" == "reply" ]]; then dispatch="$(basename "$p" .reply.md)"
    else dispatch="$(basename "$p" .task.md)"; fi
    dispatch_dir="$(dirname "$p")"
    reply_path="${dispatch_dir}/${dispatch}.reply.md"
    task_path="${dispatch_dir}/${dispatch}.task.md"
    tlabel="$thread"; [[ "$thread" == "filedrop" ]] && tlabel="filedrop (pseudo-thread, not a Codex conversationId)"
    when="$(date -d "@${mt%.*}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$mt")"
    # per-file guard: file may have been pruned/swapped between enumeration and read (TOCTOU/reaper)
    if [[ "$kind" == "reply" && ( ! -f "$reply_path" || -L "$reply_path" ) \
        && -f "$task_path" && ! -L "$task_path" ]]; then
        kind="task"; p="$task_path"
    fi
    if [[ ! -f "$p" || -L "$p" ]]; then
        echo "=== [$i] ${when} | thread: ${tlabel} | dispatch: ${dispatch}"
        echo "    (pruned mid-scan — re-run to refresh)"; echo ""
        continue
    fi
    reply_readable=0
    if [[ -f "$reply_path" && ! -L "$reply_path" ]] \
        && head -c 0 -- "$reply_path" >/dev/null 2>&1; then
        reply_readable=1; kind="reply"; p="$reply_path"
    fi
    bytes="$(stat -c %s "$p" 2>/dev/null || echo 0)"
    if [[ "$PATHS_ONLY" -eq 1 ]]; then
        if [[ "$kind" == "reply" ]]; then path_source="reply-file"; else path_source="task-envelope"; fi
        printf '%s\t%s\t%s\t%s\t%s\t"%s"\n' "$when" "$thread" "$dispatch" "$bytes" "$path_source" "$(to_win "$p")"
        continue
    fi
    reply_superseded=0
    if [[ "$reply_readable" -eq 1 ]] && command -v node >/dev/null 2>&1 \
        && [[ -f "$HARVESTER" && "$thread" != "filedrop" && -f "$task_path" && ! -L "$task_path" ]]; then
        harvest_output=""
        if harvest_output="$(node "$HARVESTER" --thread "$thread" --dispatch "$dispatch" \
            --reply-path "$reply_path" --max-bytes "$MAX_BYTES" 2>&1)"; then
            if printf '%s\n' "$harvest_output" \
                | grep -Eq $'^REPLY_SUPERSEDED_WARNING\t'; then
                reply_superseded=1
            fi
        fi
    fi
    if [[ "$reply_readable" -eq 0 ]]; then
        source_kind="none"; reason="unavailable"; source_bytes=0; returned_bytes=0
        duplicate_count=0; boundary_mode="-"; body_base64=""
        if command -v node >/dev/null 2>&1 && [[ -f "$HARVESTER" && "$thread" != "filedrop" \
            && -f "$task_path" && ! -L "$task_path" ]]; then
            if harvest_line="$(node "$HARVESTER" --thread "$thread" --dispatch "$dispatch" \
                --max-bytes "$MAX_BYTES")"; then
                if [[ "$harvest_line" != *$'\n'* ]]; then
                    IFS=$'\t' read -r source_kind reason source_bytes returned_bytes duplicate_count boundary_mode body_base64 <<<"$harvest_line"
                fi
            fi
        fi
        case "$source_kind" in
            rollout-fallback)
                [[ "$source_bytes" =~ ^[0-9]+$ ]] || source_bytes=0
                [[ "$returned_bytes" =~ ^[0-9]+$ ]] || returned_bytes=0
                [[ "$duplicate_count" =~ ^[0-9]+$ ]] || duplicate_count=0
                duplicate_note=""; (( duplicate_count > 1 )) && duplicate_note=" | duplicates=${duplicate_count}"
                echo "=== [$i] ${when} | thread: ${tlabel} | dispatch: ${dispatch} | source=rollout-fallback | ${source_bytes} B${duplicate_note}"
                echo "    retained task: \"$(to_win "$task_path")\""
                if [[ "$returned_bytes" -gt 0 ]]; then
                    if ! printf '%s' "$body_base64" | base64 --decode | codex_ipc_render_stream; then
                        echo ""
                        echo "    (rollout body could not be decoded safely; re-run to refresh)"
                    fi
                else
                    echo "    (empty rollout-derived final answer)"
                fi
                if [[ "$source_bytes" -gt "$returned_bytes" ]]; then
                    echo ""
                    echo "    [... truncated at ${returned_bytes} B of ${source_bytes} B - rollout-derived body]"
                fi
                ;;
            reply-file)
                echo "=== [$i] ${when} | thread: ${tlabel} | dispatch: ${dispatch} | source=reply-file"
                echo "    (primary became readable during scan; re-run to refresh metadata)"
                if ! codex_ipc_render_file "$reply_path" "$MAX_BYTES"; then
                    echo "    (became unreadable during render; re-run to refresh)"
                fi
                ;;
            *)
                case "$reason" in pending|unavailable|ambiguous|unparseable) :;; *) reason="unavailable";; esac
                echo "=== [$i] ${when} | thread: ${tlabel} | dispatch: ${dispatch} | source=none | reason=${reason}"
                if [[ -f "$task_path" && ! -L "$task_path" ]]; then
                    echo "    retained task: \"$(to_win "$task_path")\""
                else
                    echo "    (no retained task envelope; rollout fallback not consulted)"
                fi
                ;;
        esac
        echo ""
        continue
    fi
    echo "=== [$i] ${when} | thread: ${tlabel} | dispatch: ${dispatch} | source=reply-file | ${bytes} B"
    echo "    \"$(to_win "$p")\""
    if [[ "$reply_superseded" -eq 1 ]]; then
        echo "    [WARNING: REPLY-SUPERSEDED] Primary reply may be superseded; inspect the dispatch thread before relying on it."
    fi
    if [[ "$bytes" -eq 0 ]]; then
        echo "    (empty — possibly mid-write or pending; re-run to refresh)"
    else
        if ! codex_ipc_render_file "$p" "$MAX_BYTES"; then
            echo ""
            echo "    (became unreadable during render; re-run to refresh)"
            echo ""
            continue
        fi
        if [[ "$bytes" -gt "$MAX_BYTES" ]]; then
            echo ""
            echo "    [... truncated at ${MAX_BYTES} B of ${bytes} B — full reply: \"$(to_win "$p")\"]"
        fi
    fi
    echo ""
done

# --- Footer: pending dispatches (task.md without a sibling reply.md), scope-wide (not --since-filtered) ---
pending=0
while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    d="$(dirname "$t")"; base="$(basename "$t" .task.md)"
    [[ -f "${d}/${base}.reply.md" ]] || pending=$(( pending + 1 ))
done < <(find "$SCOPE_DIR" "${SCOPE_DEPTH[@]}" -type f -name '*.task.md' 2>/dev/null || true)
if [[ "$pending" -gt 0 ]]; then
    echo "# ${pending} dispatch(es) awaiting primary reply files (scope-wide; not --since-filtered)."
fi
exit 0
