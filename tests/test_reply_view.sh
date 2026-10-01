#!/usr/bin/env bash
# Hermetic verification harness for codex_ipc_replies.sh (the derived read-only reply view).
# Mirrors test_ipc.sh: mktemp sandbox, ok()/no() counters, exit $FAIL. Stubs find/sort where a
# fault must be injected. A read-only manifest check wraps EVERY viewer call.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Dual-layout probe: repo layout and installed-skill layout both supported byte-identically.
SCRIPT=""
for _cand in "$DIR/../skills/ipc/scripts/codex_ipc_replies.sh" "$DIR/../scripts/codex_ipc_replies.sh"; do
    [[ -f "$_cand" ]] && SCRIPT="$_cand" && break
done
[[ -n "$SCRIPT" ]] || { echo "FATAL: codex_ipc_replies.sh not found in repo or installed layout" >&2; exit 1; }
REAL_FIND="$(command -v find)"; REAL_SORT="$(command -v sort)"
TMP="$(mktemp -d)" && [[ -n "$TMP" && -d "$TMP" ]] \
    || { echo "FATAL: could not create reply-view temporary directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
IPCROOT="$TMP/ipcroot"
CODEX_IPC_SESSIONS_ROOT="$TMP/sessions"; export CODEX_IPC_SESSIONS_ROOT
U1="11111111-1111-4111-8111-111111111111"; U2="22222222-2222-4222-8222-222222222222"

PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
fatal(){ echo "FATAL: $*" >&2; exit 1; }

# The T23 wrapper seam performs Git probes. Strip inherited Git routing/tracing before any
# fixture process runs so an ambient GIT_TRACE* path cannot write outside this temporary root.
while IFS= read -r _git_var; do
  [[ "${_git_var^^}" == GIT_* ]] && unset "$_git_var"
done < <(compgen -e)
for _git_var in $(compgen -e); do
  [[ "${_git_var^^}" != GIT_* ]] || fatal "could not clear inherited Git variable $_git_var"
done
unset _git_var
export GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_ATTR_NOSYSTEM=1 GIT_PAGER=cat GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0

reset(){ rm -rf "$IPCROOT"; mkdir -p "$IPCROOT"; }
mkreply(){ local sid="$1" th="$2" disp="$3" mt="$4" body="$5"; mkdir -p "$IPCROOT/$sid/$th"; printf '%s' "$body" > "$IPCROOT/$sid/$th/$disp.reply.md"; touch -d "@$mt" "$IPCROOT/$sid/$th/$disp.reply.md"; }
mktask(){ local sid="$1" th="$2" disp="$3"; mkdir -p "$IPCROOT/$sid/$th"; printf 'task' > "$IPCROOT/$sid/$th/$disp.task.md"; }
manifest(){ "$REAL_FIND" "$IPCROOT" -printf '%p|%s|%T@\n' 2>/dev/null | "$REAL_SORT"; }
# run(cwd_env..., --) : sets OUT/RC. Wraps in a read-only manifest assertion.
run(){ local before after; before="$(manifest)"; OUT="$( env CODEX_IPC_ROOT="$IPCROOT" "$@" bash "$SCRIPT" "${RUNARGS[@]}" 2>&1 )"; RC=$?; after="$(manifest)"; [[ "$before" == "$after" ]] || no "READ-ONLY VIOLATION: manifest changed during run (${RUNARGS[*]})"; }

echo "== T1 no root =="
reset; rm -rf "$IPCROOT"; RUNARGS=(--session s1); run CLAUDE_CODE_SESSION_ID=s1
[[ $RC -eq 0 ]] && ! [[ -d "$IPCROOT" ]] && ok "no root -> exit 0, root not created" || no "no-root handling (rc=$RC, exists=$([[ -d $IPCROOT ]] && echo y))"

echo "== T2 absent session dir =="
reset; RUNARGS=(--session ghost); run CLAUDE_CODE_SESSION_ID=ghost
[[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "No dispatches recorded" && ok "absent session -> exit 0 + message" || no "absent-session (rc=$RC)"

echo "== T3 tasks-only =="
reset; mktask s3 filedrop d1; mktask s3 filedrop d2; RUNARGS=(); run CLAUDE_CODE_SESSION_ID=s3
[[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "Showing 2 of 2" \
  && [[ "$(printf '%s' "$OUT" | grep -c 'source=none | reason=unavailable')" -eq 2 ]] \
  && printf '%s' "$OUT" | grep -q "2 dispatch(es) awaiting primary" \
  && ok "tasks-only -> 2 visible unavailable fallbacks + 2 awaiting primary" || no "tasks-only (rc=$RC)"

echo "== T4 mtime beats filename order =="
reset
mkreply s4 filedrop "9000-1-aaa" 1000 "OLDEST-lexfirst"   # filename sorts first, mtime oldest
mkreply s4 filedrop "1000-1-zzz" 3000 "NEWEST-lexlast"     # filename sorts last, mtime newest
RUNARGS=(); run CLAUDE_CODE_SESSION_ID=s4
first_body="$(printf '%s' "$OUT" | grep -A1 '=== \[1\]' | tail -1)"
printf '%s' "$OUT" | grep -q "NEWEST-lexlast" && printf '%s' "$OUT" | grep -B2 'NEWEST-lexlast' | grep -q '\[1\]' && ok "newest-by-mtime shown first regardless of filename" || no "mtime ordering wrong"

echo "== T5 tie-break deterministic =="
reset; mkreply s5 filedrop "aaa" 2000 "A"; mkreply s5 filedrop "bbb" 2000 "B"
RUNARGS=(); run CLAUDE_CODE_SESSION_ID=s5; o1="$(printf '%s' "$OUT" | grep '^=== \[')"; run CLAUDE_CODE_SESSION_ID=s5; o2="$(printf '%s' "$OUT" | grep '^=== \[')"
[[ -n "$o1" && "$o1" == "$o2" ]] && ok "equal-mtime entry order is deterministic across runs" || no "tie-break non-deterministic"

echo "== T6 multi-thread consolidation =="
reset; mkreply s6 filedrop d1 1000 "FD"; mkreply s6 "$U1" d2 2000 "T1"; mkreply s6 "$U2" d3 3000 "T2"
RUNARGS=(); run CLAUDE_CODE_SESSION_ID=s6
printf '%s' "$OUT" | grep -q "FD" && printf '%s' "$OUT" | grep -q "T1" && printf '%s' "$OUT" | grep -q "T2" && printf '%s' "$OUT" | grep -q "pseudo-thread" && ok "all threads merged, filedrop labeled pseudo-thread" || no "multi-thread consolidation"

echo "== T7 -c filter + D4b absent-thread =="
reset; mkreply s7 "$U1" d1 1000 "ONE"; mkreply s7 "$U2" d2 2000 "TWO"
mkdir -p "$IPCROOT/s7/$U1/$U2"; printf 'NESTED-OTHER-THREAD' > "$IPCROOT/s7/$U1/$U2/nested.reply.md"
RUNARGS=(-c "$U1"); run CLAUDE_CODE_SESSION_ID=s7
printf '%s' "$OUT" | grep -q "ONE" && ! printf '%s' "$OUT" | grep -q "TWO" \
  && ! printf '%s' "$OUT" | grep -q "NESTED-OTHER-THREAD" \
  && ok "-c narrows to one exact thread depth" || no "-c filter/depth"
RUNARGS=(-c "$U2"); run CLAUDE_CODE_SESSION_ID=s7; printf '%s' "$OUT" | grep -q "TWO" && ! printf '%s' "$OUT" | grep -q "ONE" && ok "-c filedrop-vs-uuid isolation" || no "-c isolation"
RUNARGS=(-c not-a-uuid); run CLAUDE_CODE_SESSION_ID=s7; [[ $RC -eq 1 ]] && ok "-c bad token -> exit 1" || no "-c bad token (rc=$RC)"
RUNARGS=(-c "33333333-3333-4333-8333-333333333333"); run CLAUDE_CODE_SESSION_ID=s7; [[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "No thread" && ok "D4b: -c well-formed-but-absent -> exit 0 + message" || no "D4b (rc=$RC)"

echo "== T8 exclusion: temp sibling and directory; retained task remains visible =="
reset; mkreply s8 filedrop d1 2000 "REAL"
printf 'partial' > "$IPCROOT/s8/filedrop/d1.reply.md.AbC123"   # atomic_write temp sibling
mktask s8 filedrop d9
mkdir -p "$IPCROOT/s8/filedrop/dir.reply.md"                    # a DIRECTORY named *.reply.md (D3)
RUNARGS=(); run CLAUDE_CODE_SESSION_ID=s8
[[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "Showing 2 of 2" \
  && ! printf '%s' "$OUT" | grep -q "AbC123" && printf '%s' "$OUT" | grep -q "dispatch: d9 | source=none" \
  && ok "temp sibling + *.reply.md dir excluded; retained task surfaced" || no "exclusion (rc=$RC)"

echo "== T9 zero-byte reply =="
reset; mkreply s9 filedrop d1 2000 ""
RUNARGS=(); run CLAUDE_CODE_SESSION_ID=s9
printf '%s' "$OUT" | grep -q "empty — possibly mid-write" && ok "zero-byte -> mid-write/pending marker" || no "zero-byte marker"

echo "== T10 truncation =="
reset; mkreply s10 filedrop d1 2000 "$(head -c 4000 /dev/zero | tr '\0' 'x')"
RUNARGS=(--max-bytes 1024); run CLAUDE_CODE_SESSION_ID=s10
printf '%s' "$OUT" | grep -q "truncated at 1024 B of 4000 B" && ok "body truncated with full-path marker" || no "truncation"

echo "== T11 -n cap =="
reset; for i in $(seq 1 15); do mkreply s11 filedrop "d$i" "$((1000+i))" "body$i"; done
RUNARGS=(-n 5); run CLAUDE_CODE_SESSION_ID=s11
[[ "$(printf '%s' "$OUT" | grep -c '^=== \[')" -eq 5 ]] && printf '%s' "$OUT" | grep -q "Showing 5 of 15" && ok "-n 5 -> exactly 5 newest, banner '5 of 15'" || no "-n cap"
RUNARGS=(-n 0); run CLAUDE_CODE_SESSION_ID=s11; [[ $RC -eq 1 ]] && ok "-n 0 -> exit 1" || no "-n 0 (rc=$RC)"
RUNARGS=(-n x); run CLAUDE_CODE_SESSION_ID=s11; [[ $RC -eq 1 ]] && ok "-n x -> exit 1" || no "-n x (rc=$RC)"

echo "== T12 --since (valid + invalid fail-closed) =="
reset; mkreply s12 filedrop old 1000000000 "ANCIENT"; mkreply s12 filedrop new "$(date +%s)" "RECENT"
RUNARGS=(--since "1 hour ago"); run CLAUDE_CODE_SESSION_ID=s12
printf '%s' "$OUT" | grep -q "RECENT" && ! printf '%s' "$OUT" | grep -q "ANCIENT" && ok "T12a valid --since filters older" || no "T12a --since"
RUNARGS=(--since "not-a-real-date"); run CLAUDE_CODE_SESSION_ID=s12
[[ $RC -eq 1 ]] && ! printf '%s' "$OUT" | grep -q "Showing 0 of 0" && ok "T12b invalid --since -> exit 1, NOT '0 of 0' (fail-closed)" || no "T12b fail-closed (rc=$RC)"

echo "== T13 --paths-only =="
reset; mkreply s13 filedrop d1 2000 "BODY-SHOULD-NOT-APPEAR"
RUNARGS=(--paths-only); run CLAUDE_CODE_SESSION_ID=s13
! printf '%s' "$OUT" | grep -q "BODY-SHOULD-NOT-APPEAR" && printf '%s' "$OUT" | grep -q "d1" && ok "--paths-only omits bodies, lists metadata" || no "--paths-only"

echo "== T14 mid-scan prune (per-file guard) via sort stub =="
reset; mkreply s14 filedrop keep1 3000 "KEEP1"; mkreply s14 filedrop gone 2000 "GONE"; mkreply s14 filedrop keep2 1000 "KEEP2"
BIN14="$TMP/bin14"; mkdir -p "$BIN14"
cat > "$BIN14/sort" <<EOF
#!/usr/bin/env bash
rm -f "$IPCROOT/s14/filedrop/gone.reply.md"   # vanish one file after enumeration, before render
exec "$REAL_SORT" "\$@"
EOF
chmod +x "$BIN14/sort"
# direct invocation (no read-only manifest check: the sort stub deliberately deletes a file)
OUT="$( env CODEX_IPC_ROOT="$IPCROOT" CLAUDE_CODE_SESSION_ID=s14 PATH="$BIN14:$PATH" bash "$SCRIPT" 2>&1 )"; RC=$?
[[ $RC -eq 0 ]] && [[ "$(printf '%s' "$OUT" | grep -c 'pruned mid-scan')" -eq 1 ]] && printf '%s' "$OUT" | grep -q "KEEP1" && printf '%s' "$OUT" | grep -q "KEEP2" && ok "vanished file -> one 'pruned mid-scan', others render in full" || no "T14 mid-scan guard (rc=$RC)"

echo "== T15 enumeration hard failure -> exit non-zero, not '0 of 0' =="
reset; mkreply s15 filedrop d1 2000 "X"
BIN15="$TMP/bin15"; mkdir -p "$BIN15"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN15/find"; chmod +x "$BIN15/find"
RUNARGS=(); run CLAUDE_CODE_SESSION_ID=s15 PATH="$BIN15:$PATH"
[[ $RC -ne 0 ]] && ! printf '%s' "$OUT" | grep -q "Showing 0 of 0" && ok "hard find failure -> exit nonzero, never 'Showing 0 of 0'" || no "T15 fail-open (rc=$RC)"

echo "== T16 retry-once transient =="
reset; mkreply s16 filedrop d1 2000 "RETRIED"
BIN16="$TMP/bin16"; mkdir -p "$BIN16"
cat > "$BIN16/find" <<EOF
#!/usr/bin/env bash
if [[ ! -f "$TMP/find16.marker" ]]; then : > "$TMP/find16.marker"; exit 1; fi
exec "$REAL_FIND" "\$@"
EOF
chmod +x "$BIN16/find"; rm -f "$TMP/find16.marker"
RUNARGS=(); run CLAUDE_CODE_SESSION_ID=s16 PATH="$BIN16:$PATH"
[[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "RETRIED" && ok "transient find failure -> retry succeeds, exit 0" || no "T16 retry (rc=$RC)"

echo "== T17 session selection =="
reset; mkreply envS filedrop d1 2000 "ENVBODY"; mkreply flagS filedrop d1 2000 "FLAGBODY"; mkreply "nosid-1-2-abc" filedrop d1 5000 "NOSIDBODY"
RUNARGS=(); run CLAUDE_CODE_SESSION_ID=envS; printf '%s' "$OUT" | grep -q "ENVBODY" && ok "T17a env sid honored" || no "T17a"
RUNARGS=(--session flagS); run CLAUDE_CODE_SESSION_ID=envS; printf '%s' "$OUT" | grep -q "FLAGBODY" && ! printf '%s' "$OUT" | grep -q "ENVBODY" && ok "T17b --session overrides env" || no "T17b"
RUNARGS=(); OUT="$( CODEX_IPC_ROOT="$IPCROOT" env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$SCRIPT" 2>&1 )"; RC=$?
[[ $RC -eq 2 ]] && printf '%s' "$OUT" | grep -q "nosid-1-2-abc" && ! printf '%s' "$OUT" | grep -q "NOSIDBODY" && ok "T17c unresolvable -> exit 2, lists nosid dir, does NOT render it" || no "T17c (rc=$RC)"
RUNARGS=(--session "nosid-1-2-abc"); run CLAUDE_CODE_SESSION_ID=envS; printf '%s' "$OUT" | grep -q "NOSIDBODY" && ok "T17d explicit --session nosid renders exactly that dir" || no "T17d"

echo "== T18 traversal guard =="
reset; t18=0; for bad in "../other" "a/b" "." ".."; do RUNARGS=(--session "$bad"); run CLAUDE_CODE_SESSION_ID=x; [[ $RC -eq 1 ]] || { t18=1; echo "    (--session '$bad' gave rc=$RC)"; }; done
[[ $t18 -eq 0 ]] && ok "traversal/dot-name sessions all -> exit 1" || no "T18 some not rejected"
mkdir -p "$TMP/outside/filedrop"; printf 'ENV-TRAVERSAL-SENTINEL' > "$TMP/outside/filedrop/d1.reply.md"
RUNARGS=(); run CLAUDE_CODE_SESSION_ID="../outside"
[[ $RC -eq 1 ]] && ! printf '%s' "$OUT" | grep -q 'ENV-TRAVERSAL-SENTINEL' \
  && ok "environment-derived session traversal -> exit 1" || no "T18 environment traversal (rc=$RC)"

echo "== T19 malformed root (newline) =="
reset; RUNARGS=(--session s1); OUT="$( CODEX_IPC_ROOT="$IPCROOT"$'\n'"x" CLAUDE_CODE_SESSION_ID=s1 bash "$SCRIPT" --session s1 2>&1 )"; RC=$?
[[ $RC -eq 1 ]] && ok "newline in CODEX_IPC_ROOT -> exit 1" || no "T19 (rc=$RC)"

echo "== T20 apostrophe root =="
QR="$TMP/ob'rien/ipc"; mkdir -p "$QR/sQ/filedrop"; printf 'APOS' > "$QR/sQ/filedrop/d1.reply.md"
OUT="$( CODEX_IPC_ROOT="$QR" CLAUDE_CODE_SESSION_ID=sQ bash "$SCRIPT" 2>&1 )"; RC=$?
[[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q 'root: "' && ok "apostrophe root works, paths double-quoted" || no "T20 (rc=$RC)"

echo "== T21 no-dependency posture (PATH stripped of node/codex) =="
reset; mkreply s21 filedrop d1 2000 "NODEP"
RUNARGS=(); run CLAUDE_CODE_SESSION_ID=s21 PATH="/usr/bin:/bin"
[[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "NODEP" && ok "works with minimal PATH (no node/codex)" || no "T21 (rc=$RC)"

echo "== T22 control-byte-safe rendering, including no-Node path =="
reset; mkdir -p "$IPCROOT/s22/filedrop"
printf 'SAFE\tUTF8:\342\230\203\nNUL:\000 ESC:\033[31m CR:\r BS:\b C1:\302\205 BAD:\377' > "$IPCROOT/s22/filedrop/d1.reply.md"
RUNARGS=(); run CLAUDE_CODE_SESSION_ID=s22
if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -Fq 'SAFE' \
    && printf '%s' "$OUT" | grep -Fq 'UTF8:' \
    && printf '%s' "$OUT" | grep -Fq $'UTF8:\342\230\203' \
    && printf '%s' "$OUT" | grep -Fq '\x00' \
    && printf '%s' "$OUT" | grep -Fq '\x1B' \
    && printf '%s' "$OUT" | grep -Fq '\x0D' \
    && printf '%s' "$OUT" | grep -Fq '\x08' \
    && printf '%s' "$OUT" | grep -Fq '\u{0085}' \
    && printf '%s' "$OUT" | grep -Fq '\xFF'; then
  ok "reply body controls and invalid UTF-8 are visible and inert"
else no "T22 safe renderer output (rc=$RC)"; fi
RUNARGS=(); run CLAUDE_CODE_SESSION_ID=s22 PATH="/usr/bin:/bin"
[[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -Fq '\x1B' && printf '%s' "$OUT" | grep -Fq '\xFF' \
  && ok "safe primary rendering still works without Node" || no "T22 no-Node safe renderer (rc=$RC)"

echo "== T22b explicit and inspector-derived rollout page binding =="
reset
PAGE_DIR="$TMP/page22"; mkdir -p "$PAGE_DIR"
PAGE22="$PAGE_DIR/rollout-page-$U1.jsonl"
DISP22="9200000000-2-abcdef0123456789"
mktask s22b "$U1" "$DISP22"
mkreply s22b "$U1" "$DISP22" 2000 "PAGE-BOUND-PRIMARY"
node - "$PAGE22" "$U1" "$DISP22" <<'NODE'
const fs = require("node:fs");
const [target, threadId, dispatchId] = process.argv.slice(2);
const turnId = "33333333-3333-4333-8333-333333333333";
const records = [
  { type: "session_meta", payload: { id: threadId } },
  { type: "event_msg", payload: { type: "task_started", turn_id: turnId } },
  { type: "event_msg", payload: { type: "user_message", turn_id: turnId, message: `read C:/handoff/${dispatchId}.task.md and proceed` } },
  { type: "event_msg", payload: { type: "agent_message", turn_id: turnId, phase: "final_answer", message: "ordinary final" } },
  { type: "event_msg", payload: { type: "task_complete", turn_id: turnId, last_agent_message: "ordinary final" } },
];
fs.writeFileSync(target, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
NODE
RUNARGS=(-c "$U1" --rollout-path "$PAGE22"); run CLAUDE_CODE_SESSION_ID=s22b
[[ $RC -eq 0 && "$OUT" == *"PAGE-BOUND-PRIMARY"* \
  && "$OUT" != *"ROLLOUT-PATH:"* && "$OUT" != *"REPLY-SUPERSESSION-UNAVAILABLE"* ]] \
  && ok "explicit inspector page reaches primary supersession checks without warning" \
  || no "T22b explicit rollout page (rc=$RC)"

RUNARGS=(--rollout-path "$PAGE22"); run CLAUDE_CODE_SESSION_ID=s22b
[[ $RC -eq 1 && "$OUT" == *"requires -c with a Codex conversation UUID"* ]] \
  && ok "rollout page is refused for a session-wide view" || no "T22b session-wide page refusal"
RUNARGS=(-c filedrop --rollout-path "$PAGE22"); run CLAUDE_CODE_SESSION_ID=s22b
[[ $RC -eq 1 && "$OUT" == *"requires -c with a Codex conversation UUID"* ]] \
  && ok "rollout page is refused for filedrop" || no "T22b filedrop page refusal"
RUNARGS=(-c "$U1" --rollout-path "$PAGE22" --derive-rollout-path); run CLAUDE_CODE_SESSION_ID=s22b
[[ $RC -eq 1 && "$OUT" == *"mutually exclusive"* ]] \
  && ok "explicit and derived page modes are mutually exclusive" || no "T22b mutual exclusion"

VIEW22="$TMP/view22"; mkdir -p "$VIEW22"
cp "$SCRIPT" "$VIEW22/codex_ipc_replies.sh"
cp "$DIR/../skills/ipc/scripts/codex_ipc_safe_render.sh" "$VIEW22/codex_ipc_safe_render.sh"
cp "$DIR/../skills/ipc/scripts/codex_ipc_reply_harvest.mjs" "$VIEW22/codex_ipc_reply_harvest.mjs"
cp "$DIR/../skills/ipc/scripts/codex_ipc_rollout_reader.mjs" "$VIEW22/codex_ipc_rollout_reader.mjs"
INSPECT_COUNT="$TMP/inspect22.count"; INSPECT_ARGS="$TMP/inspect22.args"
cat > "$VIEW22/codex_ipc_session_inspect.mjs" <<'NODE'
import fs from "node:fs";
fs.appendFileSync(process.env.INSPECT_COUNT, "1\n");
fs.writeFileSync(process.env.INSPECT_ARGS, process.argv.slice(2).join("\t"));
if (process.env.INSPECT_MODE === "fail") {
  console.error("PRIVATE-INSPECTOR-PATH-C:/secret");
  process.exit(7);
}
const threadId = process.env.INSPECT_THREAD;
const page = process.env.DERIVED_PAGE;
process.stdout.write(JSON.stringify({
  ok: true,
  dbThread: {
    exists: true,
    readOnlyOpenOk: true,
    thread: { exists: true, id: threadId, rolloutPath: page },
  },
  rollout: {
    selection: { status: "found", authority: "db.rollout_path", path: page },
    primary: { parsedOk: true },
  },
}));
NODE
before="$(manifest)"
OUT="$(env CODEX_IPC_ROOT="$IPCROOT" CLAUDE_CODE_SESSION_ID=s22b \
  INSPECT_COUNT="$INSPECT_COUNT" INSPECT_ARGS="$INSPECT_ARGS" INSPECT_THREAD="$U1" \
  DERIVED_PAGE="$PAGE22" bash "$VIEW22/codex_ipc_replies.sh" -c "$U1" \
  --derive-rollout-path 2>&1)"; RC=$?
after="$(manifest)"; [[ "$before" == "$after" ]] || no "READ-ONLY VIOLATION: derived-page viewer changed IPC manifest"
[[ $RC -eq 0 && "$OUT" == *"PAGE-BOUND-PRIMARY"* \
  && "$OUT" != *"ROLLOUT-PATH:"* && "$OUT" != *"REPLY-SUPERSESSION-UNAVAILABLE"* \
  && "$(wc -l < "$INSPECT_COUNT" | tr -d ' ')" -eq 1 \
  && "$(cat "$INSPECT_ARGS")" == $'--thread\t'$U1$'\t--tail-events\t1\t--summary' ]] \
  && ok "derived mode calls the inspector once with the narrow summary contract" \
  || no "T22b inspector-derived page (rc=$RC)"

DISP22F="9200000001-2-abcdef0123456789"
PAGE22F="$PAGE_DIR/rollout-fallback-$U1.jsonl"
mktask s22c "$U1" "$DISP22F"
node - "$PAGE22F" "$U1" "$DISP22F" <<'NODE'
const fs = require("node:fs");
const [target, threadId, dispatchId] = process.argv.slice(2);
const turnId = "33333333-3333-4333-8333-333333333333";
const body = "DERIVED-FALLBACK-BODY";
const records = [
  { type: "session_meta", payload: { id: threadId } },
  { type: "event_msg", payload: { type: "task_started", turn_id: turnId } },
  { type: "event_msg", payload: { type: "user_message", turn_id: turnId, message: `read C:/handoff/${dispatchId}.task.md and proceed` } },
  { type: "event_msg", payload: { type: "agent_message", turn_id: turnId, phase: "final_answer", message: body } },
  { type: "event_msg", payload: { type: "task_complete", turn_id: turnId, last_agent_message: body } },
];
fs.writeFileSync(target, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
NODE
INSPECT_COUNT_F="$TMP/inspect22f.count"; INSPECT_ARGS_F="$TMP/inspect22f.args"
OUT="$(env CODEX_IPC_ROOT="$IPCROOT" CLAUDE_CODE_SESSION_ID=s22c \
  INSPECT_COUNT="$INSPECT_COUNT_F" INSPECT_ARGS="$INSPECT_ARGS_F" INSPECT_THREAD="$U1" \
  DERIVED_PAGE="$PAGE22F" bash "$VIEW22/codex_ipc_replies.sh" -c "$U1" \
  --derive-rollout-path 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" == *"source=rollout-fallback"* \
  && "$OUT" == *"DERIVED-FALLBACK-BODY"* \
  && "$OUT" != *"ROLLOUT-PATH:"* && "$OUT" != *"REPLY-SUPERSESSION-UNAVAILABLE"* \
  && "$(wc -l < "$INSPECT_COUNT_F" | tr -d ' ')" -eq 1 ]] \
  && ok "derived page reaches fallback when the primary reply is absent" \
  || no "T22b inspector-derived fallback (rc=$RC)"
OUT="$(env CODEX_IPC_ROOT="$IPCROOT" CLAUDE_CODE_SESSION_ID=s22b INSPECT_MODE=fail \
  INSPECT_COUNT="$INSPECT_COUNT" INSPECT_ARGS="$INSPECT_ARGS" INSPECT_THREAD="$U1" \
  DERIVED_PAGE="$PAGE22" bash "$VIEW22/codex_ipc_replies.sh" -c "$U1" \
  --derive-rollout-path 2>&1)"; RC=$?
[[ $RC -eq 1 \
  && "$OUT" == "ERROR: --derive-rollout-path could not obtain a trusted database-designated page." \
  && "$OUT" != *"PRIVATE-INSPECTOR-PATH"* ]] \
  && ok "inspector failure is fixed and suppresses private diagnostics" \
  || no "T22b inspector failure privacy (rc=$RC out=$OUT)"

echo "== T22c C7 diagnostics survive both viewer source branches =="
reset
PAGE22C="$PAGE_DIR/rollout-c7-$U1.jsonl"
DISP22C_PRIMARY="9200000002-2-abcdef0123456789"
DISP22C_MISSING="9200000003-2-abcdef0123456789"
mktask s22c7 "$U1" "$DISP22C_PRIMARY"
mkreply s22c7 "$U1" "$DISP22C_PRIMARY" 2000 "PRIMARY-C7-BODY"
mktask s22c7 "$U1" "$DISP22C_MISSING"
node - "$PAGE22C" "$U1" "$DISP22C_PRIMARY" "$DISP22C_MISSING" <<'NODE'
const fs = require("node:fs");
const [target, threadId, primaryDispatch, missingDispatch] = process.argv.slice(2);
const records = [
  { type: "session_meta", payload: { id: threadId } },
];
for (const [index, dispatchId] of [primaryDispatch, missingDispatch].entries()) {
  const turnId = index === 0
    ? "33333333-3333-4333-8333-333333333333"
    : "00000000-0000-4000-8000-00000000c0de";
  records.push(
    { type: "event_msg", payload: { type: "task_started", turn_id: turnId } },
    { type: "turn_context", payload: { turn_id: turnId, model: "" } },
    { type: "event_msg", payload: {
      type: "user_message",
      turn_id: turnId,
      message: `read C:/handoff/${dispatchId}.task.md and proceed`,
    } },
    { type: "event_msg", payload: {
      type: "task_complete",
      turn_id: turnId,
      last_agent_message: null,
      error: {
        message: index === 0 ? "primary synthetic failure" : "missing synthetic failure",
        codex_error_info: "PRIVATE-VIEWER-SIBLING",
      },
    } },
  );
}
fs.writeFileSync(target, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
NODE
before="$(manifest)"
RUNARGS=(-c "$U1" -n 2 --rollout-path "$PAGE22C"); run CLAUDE_CODE_SESSION_ID=s22c7
after="$(manifest)"; [[ "$before" == "$after" ]] \
  || no "READ-ONLY VIOLATION: C7 viewer changed IPC manifest"
TURN_ERROR_COUNT="$(printf '%s\n' "$OUT" | grep -c 'ROLLOUT_DIAGNOSTIC {"code":"turn-error"' || true)"
MODEL_STATE_COUNT="$(printf '%s\n' "$OUT" | grep -c 'ROLLOUT_DIAGNOSTIC {"code":"turn-model-state"' || true)"
if [[ $RC -eq 0 && "$OUT" == *"source=reply-file"* && "$OUT" == *"PRIMARY-C7-BODY"* \
      && "$OUT" == *"source=none | reason=unavailable"* \
      && "$OUT" == *"primary synthetic failure"* \
      && "$OUT" == *"missing synthetic failure"* \
      && "$TURN_ERROR_COUNT" -eq 2 && "$MODEL_STATE_COUNT" -eq 2 \
      && "$OUT" != *"PRIVATE-VIEWER-SIBLING"* ]]; then
  ok "viewer exposes named bounded turn-error/model facts for primary and absent replies"
else
  no "T22c C7 viewer diagnostics (rc=$RC errors=$TURN_ERROR_COUNT models=$MODEL_STATE_COUNT out=$OUT)"
fi

echo "== Static audit: no write/lock idioms =="
if grep -nE 'mkdir|mktemp|[^-]mv |[^_]rm |touch |-delete|flock|>>?[^&].*IPC_ROOT' "$SCRIPT" | grep -v '^\s*#' >/dev/null 2>&1; then
  no "static audit: found a write/lock idiom (review grep hits)"; grep -nE 'mkdir|mktemp|mv |rm |touch |-delete|flock' "$SCRIPT" | grep -v '^\s*#'
else ok "static audit: no mkdir/mktemp/mv/rm/touch/-delete/flock in the viewer"; fi
if grep -nE '^[[:space:]]*head -c .*"\$p"' "$SCRIPT" >/dev/null 2>&1; then
  no "static audit: raw reply body path still reaches stdout"
elif grep -q 'codex_ipc_safe_render.sh' "$SCRIPT"; then
  ok "static audit: reply body is gated by the shared renderer"
else
  no "static audit: shared renderer is not wired"
fi

echo "== T23 FINAL GATE: viewer/wrapper syntax + wrapper->viewer envelope seam =="
# T23 previously nested a FULL `bash test_ipc.sh` rerun here to prove the reply-view
# tooling had not regressed the transport wrapper. That whole-suite guarantee is already
# delivered by the release battery (run_release_gates.sh runs test_ipc.sh as its own
# gated suite), the viewer shares no code with the wrapper (codex_ipc_safe_render.sh is
# sourced by the viewer alone), and every viewer call above is proven read-only by the
# manifest wrap — while the nested rerun alone cost ~360s and pushed this suite over its
# own 600s per-suite cap on a loaded host. What the rerun never exercised is the one real
# interaction seam: that the wrapper's ACTUAL on-disk envelopes are consumable by the
# viewer (the mkreply/mktask fixtures above only imitate that layout). The rerun is
# therefore replaced by a narrow, bounded end-to-end check of exactly that seam: one real
# wrapper dispatch (node/codex/powershell stubbed, as in test_ipc.sh) into a fresh
# hermetic root, after which the viewer must (a) enumerate that envelope as
# awaiting-primary and (b) render a reply landed at the wrapper-advertised per-dispatch
# path. The read-only manifest discipline is kept for both seam viewer calls.
bash -n "$SCRIPT" && ok "bash -n codex_ipc_replies.sh clean" || no "syntax error in viewer"
WRAPPER=""
for _wcand in "$DIR/../skills/ipc/scripts/handoff_to_codex.sh" "$DIR/../scripts/handoff_to_codex.sh"; do
    [[ -f "$_wcand" ]] && WRAPPER="$_wcand" && break
done
if [[ -z "$WRAPPER" ]]; then
  no "T23 seam: handoff_to_codex.sh not found in repo or installed layout"
else
  bash -n "$WRAPPER" && ok "bash -n handoff_to_codex.sh clean" || no "syntax error in wrapper"
  SEAMROOT="$TMP/seamroot"; mkdir -p "$SEAMROOT" || fatal "could not create T23 seam root"
  BIN23="$TMP/bin23"; mkdir -p "$BIN23" || fatal "could not create T23 stub directory"
  for _stub in node powershell.exe codex; do
    printf '%s\n' '#!/usr/bin/env bash' \
      'printf "FATAL: unexpected T23 wrapper child: %s\\n" "${0##*/}" >&2' \
      'exit 97' > "$BIN23/$_stub" \
      || fatal "could not materialize T23 $_stub tripwire"
  done
  chmod +x "$BIN23"/* || fatal "could not make T23 tripwires executable"
  for _stub in node powershell.exe codex; do
    _resolved="$(PATH="$BIN23:$PATH" command -v "$_stub" 2>/dev/null)" \
      || fatal "T23 $_stub tripwire does not resolve"
    [[ "$_resolved" == "$BIN23/$_stub" ]] \
      || fatal "T23 $_stub resolved outside the harness: $_resolved"
  done
  unset _stub _resolved
  seam_manifest(){ "$REAL_FIND" "$SEAMROOT" -printf '%p|%s|%T@\n' 2>/dev/null | "$REAL_SORT"; }
  WOUT="$( cd "$TMP" && CODEX_IPC_ROOT="$SEAMROOT" CLAUDE_CODE_SESSION_ID=seam23 PATH="$BIN23:$PATH" bash "$WRAPPER" "seam probe task" 2>&1 )"; WRC=$?
  wtask="$("$REAL_FIND" "$SEAMROOT/seam23" -name '*.task.md' -type f 2>/dev/null | head -1)"
  [[ $WRC -eq 0 && -n "$wtask" ]] && ok "wrapper dispatch wrote a real keyed task envelope" || no "wrapper seam dispatch failed (rc=$WRC)"
  wreply="${wtask%.task.md}.reply.md"
  [[ -n "$wtask" ]] && grep -qF "$(basename "$wreply")" "$wtask" && ok "payload advertises the same-dispatch .reply.md path" || no "payload does not advertise the derived reply path"
  sm_b="$(seam_manifest)"; VOUT="$( env CODEX_IPC_ROOT="$SEAMROOT" CLAUDE_CODE_SESSION_ID=seam23 bash "$SCRIPT" 2>&1 )"; VRC=$?; sm_a="$(seam_manifest)"
  [[ "$sm_b" == "$sm_a" ]] || no "READ-ONLY VIOLATION: seam manifest changed during viewer run (pre-reply)"
  [[ $VRC -eq 0 ]] && printf '%s' "$VOUT" | grep -q "Showing 1 of 1" \
    && printf '%s' "$VOUT" | grep -q "source=none | reason=unavailable" \
    && printf '%s' "$VOUT" | grep -q "1 dispatch(es) awaiting primary" \
    && ok "viewer enumerates the wrapper-written envelope as awaiting primary" || no "viewer did not surface wrapper envelope (rc=$VRC)"
  [[ -n "$wtask" ]] && printf 'SEAM-REPLY-BODY-73' > "$wreply"
  sm_b="$(seam_manifest)"; VOUT="$( env CODEX_IPC_ROOT="$SEAMROOT" CLAUDE_CODE_SESSION_ID=seam23 bash "$SCRIPT" 2>&1 )"; VRC=$?; sm_a="$(seam_manifest)"
  [[ "$sm_b" == "$sm_a" ]] || no "READ-ONLY VIOLATION: seam manifest changed during viewer run (post-reply)"
  [[ $VRC -eq 0 ]] && printf '%s' "$VOUT" | grep -q "SEAM-REPLY-BODY-73" && ok "viewer renders the reply landed at the wrapper-advertised path" || no "viewer did not render seam reply (rc=$VRC)"
fi

echo "== T23b thread-bound manual envelope -> multi-page waiter/viewer fallback =="
if [[ -z "$WRAPPER" ]]; then
  no "T23b seam: wrapper unavailable"
else
  REAL_NODE23B="$(command -v node 2>/dev/null)" || REAL_NODE23B=""
  if [[ -z "$REAL_NODE23B" ]]; then
    no "T23b seam: real Node unavailable"
  else
    SEAM23B_ROOT="$TMP/seam23b-root"
    SEAM23B_PAGES="$TMP/seam23b-pages"
    SEAM23B_HOME="$TMP/seam23b-home"
    SEAM23B_WORK="$TMP/seam23b-work"
    BIN23B="$TMP/bin23b"
    mkdir -p "$SEAM23B_ROOT" "$SEAM23B_PAGES" "$SEAM23B_HOME" "$SEAM23B_WORK" "$BIN23B" \
      || fatal "could not create T23b isolated roots"
    PAGE23B_OLD="$SEAM23B_PAGES/rollout-old-$U1.jsonl"
    PAGE23B_CURRENT="$SEAM23B_PAGES/rollout-current-${U1}_${U2}.jsonl"
    "$REAL_NODE23B" - "$PAGE23B_OLD" "$PAGE23B_CURRENT" "$U1" <<'NODE'
const fs = require("node:fs");
const [oldPage, currentPage, threadId] = process.argv.slice(2);
const predecessor = `${JSON.stringify({ type: "session_meta", payload: { id: threadId } })}\n`;
const header = {
  type: "session_meta",
  payload: {
    id: threadId,
    session_id: threadId,
    history_mode: "paginated",
    history_base: {
      thread_id: threadId,
      end_byte_offset: Buffer.byteLength(predecessor, "utf8"),
    },
  },
};
fs.writeFileSync(oldPage, predecessor);
fs.writeFileSync(currentPage, `${JSON.stringify(header)}\n`);
NODE
    INSPECT23B_COUNT="$TMP/inspect23b.count"
    FORBIDDEN23B="$TMP/forbidden23b.log"
    cat > "$BIN23B/node" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *codex_ipc_session_inspect.mjs*)
    printf '1\n' >> "$INSPECT23B_COUNT"
    "$REAL_NODE23B" - "$PAGE23B_CURRENT" "$THREAD23B" <<'NODE'
const [page, threadId] = process.argv.slice(2);
process.stdout.write(JSON.stringify({
  ok: true,
  dbThread: {
    exists: true,
    readOnlyOpenOk: true,
    thread: {
      exists: true,
      id: threadId,
      archived: 0,
      model: "synthetic-model",
      threadSource: "user",
      rolloutPath: page,
    },
  },
  targetClassification: {
    kind: "root",
    parentThreadId: null,
    reasons: ["thread-source-root"],
    warnings: [],
  },
  rollout: {
    selection: { status: "found", authority: "db.rollout_path", path: page },
    primary: { parsedOk: true, path: page },
  },
}));
NODE
    ;;
  *codex_ipc_client.mjs*|*codex_ipc_rollout_observe.mjs*)
    printf 'forbidden-node %s\n' "$*" >> "$FORBIDDEN23B"
    exit 97
    ;;
  *) exec "$REAL_NODE23B" "$@";;
esac
EOF
    for _stub in powershell.exe codex; do
      cat > "$BIN23B/$_stub" <<'EOF'
#!/usr/bin/env bash
printf 'forbidden-child %s %s\n' "${0##*/}" "$*" >> "$FORBIDDEN23B"
exit 97
EOF
    done
    chmod +x "$BIN23B"/* || fatal "could not make T23b stubs executable"
    for _stub in node powershell.exe codex; do
      _resolved="$(PATH="$BIN23B:$PATH" command -v "$_stub" 2>/dev/null)" \
        || fatal "T23b $_stub stub does not resolve"
      [[ "$_resolved" == "$BIN23B/$_stub" ]] \
        || fatal "T23b $_stub resolved outside the harness: $_resolved"
    done
    unset _stub _resolved

    WOUT="$( cd "$SEAM23B_WORK" && env \
      -u CODEX_IPC_ROLLOUT_PATH -u NODE_OPTIONS -u NODE_PATH -u BASH_ENV -u ENV \
      HOME="$SEAM23B_HOME" USERPROFILE="$SEAM23B_HOME" \
      TMPDIR="$SEAM23B_HOME" TMP="$SEAM23B_HOME" TEMP="$SEAM23B_HOME" \
      CODEX_IPC_ROOT="$SEAM23B_ROOT" CODEX_IPC_RETENTION_DAYS=0 \
      CODEX_IPC_GIT_CONTEXT=bounded CODEX_IPC_INCLUDE_TRANSCRIPT=0 \
      CLAUDE_CODE_SESSION_ID=seam23b CODEX_IPC_SESSIONS_ROOT="$SEAM23B_PAGES" \
      REAL_NODE23B="$REAL_NODE23B" INSPECT23B_COUNT="$INSPECT23B_COUNT" \
      FORBIDDEN23B="$FORBIDDEN23B" PAGE23B_CURRENT="$PAGE23B_CURRENT" THREAD23B="$U1" \
      PATH="$BIN23B:$PATH" bash "$WRAPPER" --ipc "$U1" --deliver manual -- "C3 synthetic task" 2>&1 )"; WRC=$?
    mapfile -t TASKS23B < <("$REAL_FIND" "$SEAM23B_ROOT/seam23b/$U1" -maxdepth 1 -name '*.task.md' -type f 2>/dev/null | "$REAL_SORT")
    WAIT23B_COUNT="$(printf '%s\n' "$WOUT" | grep -c '^WAIT:' || true)"
    PICKUP23B_COUNT="$(printf '%s\n' "$WOUT" | grep -c '^    read ".*\.task\.md" and proceed$' || true)"
    if [[ $WRC -eq 0 && "${#TASKS23B[@]}" -eq 1 && "$WAIT23B_COUNT" -eq 1 && "$PICKUP23B_COUNT" -eq 1 \
          && "$WOUT" != *"RESULT:"* ]]; then
      ok "manual wrapper produced one real thread-bound envelope, pickup, and WAIT without RESULT"
      TASK23B="${TASKS23B[0]}"
      DISPATCH23B="$(basename "$TASK23B" .task.md)"
      REPLY23B="${TASK23B%.task.md}.reply.md"
      WAIT23B="$(printf '%s\n' "$WOUT" | grep '^WAIT:' | head -1)"
      PICKUP23B="$(printf '%s\n' "$WOUT" | grep '^    read ".*\.task\.md" and proceed$' | head -1)"
      if [[ "$WAIT23B" == *"--thread $U1"* && "$WAIT23B" == *"--dispatch $DISPATCH23B"* \
            && "$WAIT23B" == *"--reply-path"* && "$WAIT23B" == *"--rollout-path"* ]]; then
        ok "manual WAIT binds the actual thread, dispatch, reply, and designated page"
      else
        no "manual WAIT lost exact correlation (line=$WAIT23B)"
      fi

      "$REAL_NODE23B" - "$PAGE23B_CURRENT" "$PICKUP23B" <<'NODE'
const fs = require("node:fs");
const [page, pickup] = process.argv.slice(2);
const turnId = "33333333-3333-4333-8333-333333333333";
const body = "C3-SANDBOX-FALLBACK-BODY";
const records = [
  { type: "event_msg", payload: { type: "task_started", turn_id: turnId } },
  { type: "event_msg", payload: { type: "user_message", turn_id: turnId, message: pickup } },
  { type: "event_msg", payload: { type: "agent_message", turn_id: turnId, phase: "final_answer", message: body } },
  { type: "event_msg", payload: { type: "task_complete", turn_id: turnId, last_agent_message: body } },
];
fs.appendFileSync(page, `${records.map((item) => JSON.stringify(item)).join("\n")}\n`);
NODE
      HASH23B_BEFORE="$(sha256sum "$TASK23B" "$PAGE23B_OLD" "$PAGE23B_CURRENT")"
      WAIT23B_OUT="$TMP/wait23b.out"; WAIT23B_ERR="$TMP/wait23b.err"
      WAIT23B_CMD="${WAIT23B#WAIT: }"
      (
        export HOME="$SEAM23B_HOME" USERPROFILE="$SEAM23B_HOME"
        export TMPDIR="$SEAM23B_HOME" TMP="$SEAM23B_HOME" TEMP="$SEAM23B_HOME"
        export CODEX_IPC_ROOT="$SEAM23B_ROOT" CODEX_IPC_SESSIONS_ROOT="$SEAM23B_PAGES"
        export REAL_NODE23B INSPECT23B_COUNT FORBIDDEN23B PAGE23B_CURRENT
        export THREAD23B="$U1" PATH="$BIN23B:$PATH"
        eval "$WAIT23B_CMD --budget-ms 0"
      ) >"$WAIT23B_OUT" 2>"$WAIT23B_ERR"; WAIT23B_RC=$?
      printf 'done\n' > "$TMP/wait23b.expected"
      if [[ $WAIT23B_RC -eq 0 ]] && cmp -s "$TMP/wait23b.expected" "$WAIT23B_OUT" \
          && [[ "$(wc -l < "$WAIT23B_ERR" | tr -d ' ')" -eq 1 ]] \
          && grep -Fxq 'WAIT_DIAGNOSTIC {"code":"reply-source","source":"rollout-fallback"}' "$WAIT23B_ERR" \
          && ! grep -Fq 'C3-SANDBOX-FALLBACK-BODY' "$WAIT23B_OUT" "$WAIT23B_ERR"; then
        ok "real waiter certifies the absent-reply dispatch from the bound multi-page rollout"
      else
        no "real waiter failed multi-page fallback (rc=$WAIT23B_RC out=$(cat "$WAIT23B_OUT") err=$(cat "$WAIT23B_ERR"))"
      fi

      VOUT="$(env CODEX_IPC_ROOT="$SEAM23B_ROOT" CLAUDE_CODE_SESSION_ID=seam23b \
        CODEX_IPC_SESSIONS_ROOT="$SEAM23B_PAGES" REAL_NODE23B="$REAL_NODE23B" \
        INSPECT23B_COUNT="$INSPECT23B_COUNT" FORBIDDEN23B="$FORBIDDEN23B" \
        PAGE23B_CURRENT="$PAGE23B_CURRENT" THREAD23B="$U1" PATH="$BIN23B:$PATH" \
        bash "$SCRIPT" --session seam23b -c "$U1" --rollout-path "$PAGE23B_CURRENT" 2>&1)"; VRC=$?
      HASH23B_AFTER="$(sha256sum "$TASK23B" "$PAGE23B_OLD" "$PAGE23B_CURRENT")"
      if [[ $VRC -eq 0 && "$VOUT" == *"source=rollout-fallback"* \
            && "$VOUT" == *"C3-SANDBOX-FALLBACK-BODY"* ]]; then
        ok "real viewer renders the certified multi-page rollout fallback body"
      else
        no "real viewer failed multi-page fallback rendering (rc=$VRC out=$VOUT)"
      fi
      if [[ ! -e "$REPLY23B" && "$HASH23B_BEFORE" == "$HASH23B_AFTER" \
            && "$(wc -l < "$INSPECT23B_COUNT" | tr -d ' ')" -eq 1 \
            && ! -e "$FORBIDDEN23B" ]]; then
        ok "fallback path stays read-only, keeps reply absent, inspects once, and makes zero live contacts"
      else
        no "fallback seam mutated evidence, created a reply, re-inspected, or touched a live child"
      fi
    else
      no "T23b manual wrapper setup failed (rc=$WRC tasks=${#TASKS23B[@]} waits=$WAIT23B_COUNT pickups=$PICKUP23B_COUNT out=$WOUT)"
    fi
  fi
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL GREEN" || echo "FAILURES PRESENT"
exit $FAIL
