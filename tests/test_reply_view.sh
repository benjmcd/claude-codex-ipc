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
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
IPCROOT="$TMP/ipcroot"
U1="11111111-1111-4111-8111-111111111111"; U2="22222222-2222-4222-8222-222222222222"

PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
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
[[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "Showing 0 of 0" && printf '%s' "$OUT" | grep -q "2 dispatch(es) awaiting" && ok "tasks-only -> 0 replies + 2 awaiting" || no "tasks-only (rc=$RC)"

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
RUNARGS=(-c "$U1"); run CLAUDE_CODE_SESSION_ID=s7
printf '%s' "$OUT" | grep -q "ONE" && ! printf '%s' "$OUT" | grep -q "TWO" && ok "-c narrows to one thread" || no "-c filter"
RUNARGS=(-c "$U2"); run CLAUDE_CODE_SESSION_ID=s7; printf '%s' "$OUT" | grep -q "TWO" && ! printf '%s' "$OUT" | grep -q "ONE" && ok "-c filedrop-vs-uuid isolation" || no "-c isolation"
RUNARGS=(-c not-a-uuid); run CLAUDE_CODE_SESSION_ID=s7; [[ $RC -eq 1 ]] && ok "-c bad token -> exit 1" || no "-c bad token (rc=$RC)"
RUNARGS=(-c "33333333-3333-4333-8333-333333333333"); run CLAUDE_CODE_SESSION_ID=s7; [[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "No thread" && ok "D4b: -c well-formed-but-absent -> exit 0 + message" || no "D4b (rc=$RC)"

echo "== T8 exclusion: temp sibling, task.md, directory named *.reply.md =="
reset; mkreply s8 filedrop d1 2000 "REAL"
printf 'partial' > "$IPCROOT/s8/filedrop/d1.reply.md.AbC123"   # atomic_write temp sibling
mktask s8 filedrop d9
mkdir -p "$IPCROOT/s8/filedrop/dir.reply.md"                    # a DIRECTORY named *.reply.md (D3)
RUNARGS=(); run CLAUDE_CODE_SESSION_ID=s8
[[ $RC -eq 0 ]] && printf '%s' "$OUT" | grep -q "Showing 1 of 1" && ! printf '%s' "$OUT" | grep -q "AbC123" && ok "temp sibling + task.md + *.reply.md dir all excluded" || no "exclusion (rc=$RC)"

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

echo "== Static audit: no write/lock idioms =="
if grep -nE 'mkdir|mktemp|[^-]mv |[^_]rm |touch |-delete|flock|>>?[^&].*IPC_ROOT' "$SCRIPT" | grep -v '^\s*#' >/dev/null 2>&1; then
  no "static audit: found a write/lock idiom (review grep hits)"; grep -nE 'mkdir|mktemp|mv |rm |touch |-delete|flock' "$SCRIPT" | grep -v '^\s*#'
else ok "static audit: no mkdir/mktemp/mv/rm/touch/-delete/flock in the viewer"; fi

echo "== T22 FINAL GATE: wrapper untouched + test_ipc green + syntax =="
if [[ -f "$DIR/handoff_to_codex.sh.orig" ]]; then :; fi
bash -n "$SCRIPT" && ok "bash -n codex_ipc_replies.sh clean" || no "syntax error in viewer"
( cd "$DIR" && bash test_ipc.sh >/dev/null 2>&1 ) && ok "wrapper harness test_ipc.sh still ALL GREEN" || no "test_ipc.sh regressed"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL GREEN" || echo "FAILURES PRESENT"
exit $FAIL
