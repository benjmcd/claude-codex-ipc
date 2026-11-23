#!/usr/bin/env bash
# Hermetic tests for reasoning (thinking) visibility: the thread-activity/1 projection shared by the
# session inspector (rollout.primary.reasoning) and the reply viewer's reasoning section.
#
# The fixtures under tests/fixtures/reasoning are the shared thread-activity/1 set; the Observer
# CLI's `thinking` command tests against byte-identical copies (MANIFEST.sha256 proves the set).
# Every record is synthetic. Nothing here reads ~/.codex, opens a pipe, or writes outside $TMP.
#
# The unchanged-paths leg proves that reasoning cannot reach the waiter, harvester, completion
# certification, REPLY-SUPERSEDED detection or dispatch-marker binding: those files are unchanged
# against the pinned pre-feature ref, and their outputs on a rollout whose reasoning imitates a
# dispatch marker and a REPLY-SUPERSEDED line equal their outputs on the same rollout with every
# reasoning record removed.
set -uo pipefail

TDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$TDIR/../skills/ipc/scripts"
[[ -d "$SCRIPTS" ]] || SCRIPTS="$TDIR/../scripts"
REASONING="$SCRIPTS/codex_ipc_reasoning.mjs"
INSPECT="$SCRIPTS/codex_ipc_session_inspect.mjs"
WAIT="$SCRIPTS/codex_ipc_wait.mjs"
HARVEST="$SCRIPTS/codex_ipc_reply_harvest.mjs"
VIEWER="$SCRIPTS/codex_ipc_replies.sh"
FIX="$TDIR/fixtures/reasoning"
for f in "$REASONING" "$INSPECT" "$WAIT" "$HARVEST" "$VIEWER" "$FIX/expectations.json"; do
  [[ -f "$f" ]] || { echo "FATAL: missing $f" >&2; exit 1; }
done
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node is unavailable; reasoning suite not applicable"
  exit 0
fi
NODE_BIN="$(command -v node)"
while IFS= read -r _git_var; do
  [[ "${_git_var^^}" == GIT_* ]] && unset "$_git_var"
done < <(compgen -e)
REPO_ROOT="$(cd "$TDIR/.." && pwd)"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$REPO_ROOT"

TMP="$(mktemp -d)" && [[ -n "$TMP" && -d "$TMP" ]] || { echo "FATAL: no temp dir" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
export CODEX_IPC_SESSIONS_ROOT=""
unset CODEX_IPC_ROLLOUT_PATH CODEX_IPC_SQLITE_READER

BIG=100000000   # budgets lifted: the expectations are about selection, not about page size

echo "== 1. the fixture set is the shared one =="
if (cd "$FIX" && sha256sum -c MANIFEST.sha256 >/dev/null 2>&1); then
  ok "every fixture and expectations.json match MANIFEST.sha256"
else
  no "the fixture copy differs from MANIFEST.sha256"
fi

# One sessions root per fixture, so discovery is exact for both readers.
"$NODE_BIN" -e '
const fs = require("node:fs"); const path = require("node:path");
const [fix, tmp] = process.argv.slice(1);
const ex = JSON.parse(fs.readFileSync(path.join(fix, "expectations.json"), "utf8"));
for (const [key, f] of Object.entries(ex.fixtures)) {
  const dir = path.join(tmp, "roots", key);
  fs.mkdirSync(dir, { recursive: true });
  fs.copyFileSync(path.join(fix, f.file), path.join(dir, f.file));
}' "$FIX" "$TMP"

CHECKER="$TMP/check.mjs"
cat > "$CHECKER" <<'EOF'
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
const [fix, tmp, reasoning, inspect, big] = process.argv.slice(2);
const ex = JSON.parse(fs.readFileSync(path.join(fix, "expectations.json"), "utf8"));
const windowArgs = (w) => w.allTurns ? ["--all-turns"] : w.turn ? ["--turn", w.turn] : w.turns ? ["--turns", String(w.turns)] : [];
// The inspector exits 1 whenever ok is false (here: no state DB, or an unparseable line), yet it
// still prints the whole object; the reasoning field is read from stdout either way.
const run = (script, args) => JSON.parse(spawnSync(process.execPath, [script, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], maxBuffer: 1 << 28 }).stdout);
const failures = [];
let checked = 0;
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function check(label, p, c) {
  const w = p.window;
  const fail = (m) => failures.push(`${label}: ${m}`);
  if (w.status !== c.status) return fail(`status ${w.status} want ${c.status} (${w.reason || ""})`);
  if (c.reason && w.reason !== c.reason) fail(`reason ${w.reason} want ${c.reason}`);
  if (c.status !== "ok") { if (p.items.length) fail("an unavailable window listed items"); return; }
  if (!eq(w.turns.map((t) => t.turnId), c.turns)) fail(`turns ${JSON.stringify(w.turns.map((t) => t.turnId))}`);
  if (w.earlierTurns !== c.earlierTurns) fail(`earlierTurns ${w.earlierTurns} want ${c.earlierTurns}`);
  const listed = p.items.map((i) => i.source.itemId);
  if (!eq(listed, c.listed)) fail(`listed ${JSON.stringify(listed)} want ${JSON.stringify(c.listed)}`);
  if (p.omitted.encryptedOnly !== c.encryptedOnly) fail(`encryptedOnly ${p.omitted.encryptedOnly}`);
  if (p.omitted.empty !== c.empty) fail(`empty ${p.omitted.empty}`);
  for (const [id, st] of Object.entries(c.turnStatus || {})) {
    const t = w.turns.find((x) => x.turnId === id);
    if (!t || t.status !== st) fail(`turn ${id} status ${t?.status} want ${st}`);
  }
  for (const [id, facts] of Object.entries(c.items || {})) {
    const item = p.items.find((i) => i.source.itemId === id);
    if (!item) { fail(`item ${id} missing`); continue; }
    for (const k of ["originalChars", "truncated", "format", "turnStatus", "headline"]) {
      if (k in facts && item[k] !== facts[k]) fail(`${id}.${k}=${JSON.stringify(item[k])} want ${JSON.stringify(facts[k])}`);
    }
    if (facts.headlineOmitted && "headline" in item) fail(`${id} repeats its whole text as headline`);
    if (facts.records && !eq(item.source.records, facts.records)) fail(`${id}.records ${item.source.records}`);
    if (item.trust !== "untrusted") fail(`${id} not labelled untrusted`);
  }
  if (p.notice !== ex.fixtures && typeof p.notice !== "string") fail("no notice");
}
for (const [key, f] of Object.entries(ex.fixtures)) {
  const root = path.join(tmp, "roots", key);
  const file = path.join(root, f.file);
  for (const c of f.cases) {
    const common = [...windowArgs(c.window), "--reasoning-max-bytes", big];
    const cli = run(reasoning, ["--thread", f.thread, "--rollout-path", file, "--sessions-root", root, ...common]);
    check(`${key} ${JSON.stringify(c.window)} cli`, cli, c);
    const ins = run(inspect, ["--thread", f.thread, "--db", path.join(tmp, "no-db.sqlite"), "--sessions-root", root, ...common]);
    const r = ins.rollout?.primary?.reasoning;
    if (!r) failures.push(`${key}: inspector emitted no reasoning`);
    else {
      check(`${key} ${JSON.stringify(c.window)} inspector`, r, c);
      if (!eq(r, cli)) failures.push(`${key} ${JSON.stringify(c.window)}: inspector and CLI projections differ`);
    }
    checked += 1;
  }
}
if (failures.length) { console.error(failures.join("\n")); process.exit(1); }
console.log(checked);
EOF

echo "== 2. every expectation holds for the CLI and the inspector, and the two agree =="
if CASES="$("$NODE_BIN" "$CHECKER" "$FIX" "$TMP" "$REASONING" "$INSPECT" "$BIG" 2>"$TMP/check.err")"; then
  ok "$CASES fixture cases: window, turns, listed items, counts, formats, headlines; inspector == CLI"
else
  no "fixture expectations failed:"; sed 's/^/      /' "$TMP/check.err" | head -40
fi

fx(){ "$NODE_BIN" -e '
const ex = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).fixtures[process.argv[2]];
process.stdout.write(process.argv[3] === "thread" ? ex.thread : ex.file);' "$FIX/expectations.json" "$1" "$2"; }
cli(){ local key="$1"; shift; "$NODE_BIN" "$REASONING" --thread "$(fx "$key" thread)" \
  --rollout-path "$TMP/roots/$key/$(fx "$key" file)" --sessions-root "$TMP/roots/$key" "$@" 2>/dev/null; }

echo "== 3. windows: latest by default, --turns N exactly N, --all-turns all, alternatives refused =="
cli multi-turn > "$TMP/w1.json"; cli multi-turn --turns 3 > "$TMP/w3.json"; cli multi-turn --all-turns > "$TMP/wall.json"
if "$NODE_BIN" -e '
const fs = require("node:fs");
const [a, b, c] = process.argv.slice(1).map((p) => JSON.parse(fs.readFileSync(p, "utf8")));
if (a.window.turns.length !== 1 || a.window.earlierTurns !== 5 || !a.window.widen) throw new Error("latest");
if (b.window.turns.length !== 3 || b.window.earlierTurns !== 3) throw new Error("turns 3");
if (c.window.turns.length !== 6 || c.items.length !== 12 || c.window.totalTurns !== 6) throw new Error("all");
' "$TMP/w1.json" "$TMP/w3.json" "$TMP/wall.json" 2>"$TMP/w.err"; then
  ok "latest turn alone by default (earlierTurns 5, widen hint), three of six with --turns 3, all twelve items with --all-turns"
else
  no "window selection: $(cat "$TMP/w.err")"
fi
if ! cli multi-turn --turns 2 --all-turns >/dev/null; then
  ok "--turns and --all-turns together are a usage error"
else
  no "conflicting window flags were accepted"
fi

echo "== 4. modes: headline carries no text, none carries none, the inspector omits the field =="
cli claude-long --reasoning headline --reasoning-max-bytes "$BIG" > "$TMP/h.json"
cli claude-long --reasoning none > "$TMP/n.json"
"$NODE_BIN" "$INSPECT" --thread "$(fx claude-long thread)" --db "$TMP/no-db.sqlite" \
  --sessions-root "$TMP/roots/claude-long" --reasoning none > "$TMP/in.json" 2>/dev/null
if "$NODE_BIN" -e '
const fs = require("node:fs");
const [h, n, i] = process.argv.slice(1).map((p) => JSON.parse(fs.readFileSync(p, "utf8")));
if (h.items.length !== 3 || h.items.some((x) => "text" in x || typeof x.headline !== "string")) throw new Error("headline");
if (h.items.some((x) => x.headline.length > 200)) throw new Error("headline over 200");
if (n.items.length !== 0 || n.mode !== "none" || n.window.turns[0].reasoning.text !== 3) throw new Error("none");
if ("reasoning" in i.rollout.primary) throw new Error("inspector --reasoning none kept the field");
' "$TMP/h.json" "$TMP/n.json" "$TMP/in.json" 2>"$TMP/m.err"; then
  ok "headline mode: three headlines <= 200 chars, no text; none: counts only; inspector omits the field"
else
  no "modes: $(cat "$TMP/m.err")"
fi

echo "== 5. bounds: no item cap by default; a cap cuts head plus tail; the budget pages, never shortens =="
cli claude-long > "$TMP/b0.json"
if "$NODE_BIN" -e '
const p = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
const big = p.items.find((x) => x.source.itemId === "rs_c2");
if (!big || big.truncated || big.text.length !== 45000 || big.originalChars !== 45000) throw new Error("default cut the item");
if (p.budget.perItemChars !== null || p.budget.maxBytes !== 64000) throw new Error("defaults " + JSON.stringify(p.budget));
' "$TMP/b0.json" 2>"$TMP/b0.err"; then
  ok "by default the 45,000-character item comes back whole (perItemChars null, 64,000-byte safety limit)"
else
  no "default no-cap: $(cat "$TMP/b0.err")"
fi
cli claude-long --reasoning-max-item-chars 1000 --reasoning-max-bytes "$BIG" > "$TMP/b1.json"
if "$NODE_BIN" -e '
const p = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
const big = p.items.find((x) => x.source.itemId === "rs_c2");
if (!big.truncated || big.originalChars !== 45000 || big.text.length > 1000 || big.chars !== big.text.length) throw new Error("cap");
if (!/\[\.\.\. \d+ characters omitted \.\.\.\]/.test(big.text)) throw new Error("no marker");
if (!big.text.startsWith("Reading the whole handoff") || !big.text.endsWith(" end")) throw new Error("not head plus tail");
' "$TMP/b1.json" 2>"$TMP/b1.err"; then
  ok "a 45,000-character item cut to <= 1,000 characters: head, marker, tail; truncated and originalChars said"
else
  no "per-item cap: $(cat "$TMP/b1.err")"
fi
PAGES="$TMP/pages"; mkdir -p "$PAGES"; cursor=""; n=0
while :; do
  n=$((n+1)); args=(--reasoning-max-bytes 2000 --reasoning-max-item-chars 1000)
  [[ -n "$cursor" ]] && args+=(--reasoning-cursor "$cursor")
  cli claude-long "${args[@]}" > "$PAGES/$n.json"
  cursor="$("$NODE_BIN" -e 'const p=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(p.nextCursor||"")' "$PAGES/$n.json")"
  [[ -z "$cursor" || $n -ge 10 ]] && break
done
if "$NODE_BIN" -e '
const fs = require("node:fs"); const dir = process.argv[1];
const pages = fs.readdirSync(dir).sort((a, b) => parseInt(a) - parseInt(b)).map((f) => JSON.parse(fs.readFileSync(dir + "/" + f, "utf8")));
const ids = pages.flatMap((p) => p.items.map((i) => i.source.itemId));
if (ids.join() !== "rs_c3,rs_c2,rs_c1") throw new Error("pages gave " + ids.join());
for (const p of pages) {
  const bytes = Buffer.byteLength(JSON.stringify(p.items), "utf8");
  if (p.items.length === 0 || bytes > 2000) throw new Error("page of " + bytes + " B");
}
if (pages[0].omitted.overBudget < 1 || !pages[0].nextCursor.startsWith("before:")) throw new Error("first page");
' "$PAGES" 2>"$TMP/pg.err"; then
  ok "with a 1,000-character cap a 2,000-byte budget pages the three items once each, newest first"
else
  no "paging: $(cat "$TMP/pg.err")"
fi
cli claude-long --reasoning-max-bytes 3000 > "$TMP/bl1.json"
CUR="$("$NODE_BIN" -e 'process.stdout.write(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).nextCursor||"")' "$TMP/bl1.json")"
cli claude-long --reasoning-max-bytes 3000 --reasoning-cursor "$CUR" > "$TMP/bl2.json"
cli claude-long --reasoning-max-bytes 3000 --reasoning-cursor "$CUR" --format text > "$TMP/bl2.txt"
if "$NODE_BIN" -e '
const fs = require("node:fs");
const [a, b] = process.argv.slice(1, 3).map((f) => JSON.parse(fs.readFileSync(f, "utf8")));
if (a.items.map((i) => i.source.itemId).join() !== "rs_c3" || !a.nextCursor) throw new Error("page 1");
const blocked = b.budget.blockedBy;
if (b.items.length !== 0 || !blocked || blocked.itemId !== "rs_c2" || blocked.originalChars !== 45000) throw new Error("page 2 " + JSON.stringify(b.budget));
if (b.nextCursor !== null || b.omitted.overBudget !== 2 || !/raise --reasoning-max-bytes to at least \d+/.test(blocked.hint)) throw new Error("hint");
' "$TMP/bl1.json" "$TMP/bl2.json" 2>"$TMP/bl.err" && grep -q '^BUDGET: item rs_c2 .* it was not shortened' "$TMP/bl2.txt"; then
  ok "without a cap an item larger than the budget is never shortened: the page names it and how to get it"
else
  no "budget block: $(cat "$TMP/bl.err")"
fi

echo "== 6. encrypted content never leaves; delimiters cannot be forged =="
LEAK=0
for key in $("$NODE_BIN" -e 'process.stdout.write(Object.keys(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).fixtures).join(" "))' "$FIX/expectations.json"); do
  for mode in full headline none; do
    cli "$key" --reasoning "$mode" --all-turns > "$TMP/leak.json"
    cli "$key" --reasoning "$mode" --all-turns --format text > "$TMP/leak.txt"
    grep -q "gAAAAB" "$TMP/leak.json" "$TMP/leak.txt" && LEAK=1
  done
done
[[ $LEAK -eq 0 ]] && ok "no fixture, mode or format emits encrypted_content" || no "encrypted_content leaked"
cli injection --format text > "$TMP/inj.txt"
ENDS="$(grep -cx '<<<end untrusted-reasoning>>>' "$TMP/inj.txt")"
OPENS="$(grep -c '^<<<untrusted-reasoning ' "$TMP/inj.txt")"
if [[ "$ENDS" == 1 && "$OPENS" == 1 ]] && grep -q '^NOTICE: Recorded reasoning of another thread' "$TMP/inj.txt" \
   && ! grep -q '^<<<untrusted-reasoning item=forged' "$TMP/inj.txt"; then
  ok "the injected envelope lines are escaped: one real open, one real end, the notice first"
else
  no "delimiter forgery: opens=$OPENS ends=$ENDS"
fi

echo "== 7. compressed rollouts are a clean unavailable =="
ZST="$TMP/roots/zst"; mkdir -p "$ZST"; T0="0f0f00ff-0000-4000-8000-0000000000ff"
printf '\x28\xb5\x2f\xfd binary' > "$ZST/rollout-2026-11-21T00-00-00-$T0.jsonl.zst"
"$NODE_BIN" "$REASONING" --thread "$T0" --rollout-path "$ZST/rollout-2026-11-21T00-00-00-$T0.jsonl.zst" > "$TMP/zst.json" 2>/dev/null
if "$NODE_BIN" -e 'const p=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));
if (p.window.status!=="unavailable"||p.window.reason!=="compressed-rollout-unsupported"||p.items.length) process.exit(1)' "$TMP/zst.json"; then
  ok ".jsonl.zst reports unavailable/compressed-rollout-unsupported"
else
  no ".zst handling"
fi

echo "== 8. unchanged paths: waiter, harvester, reader and wrapper do not use the reasoning module =="
# These body, certification and binding files change for their own reasons, so a byte pin to a
# pre-feature commit goes stale with every later fix. The durable invariant is structural: none of
# them imports or names the reasoning module or any of its exports, which are read from the module
# itself so a new export is covered too. It needs no git history, so it also runs in an export.
UNCHANGED=(codex_ipc_wait.mjs codex_ipc_reply_harvest.mjs codex_ipc_rollout_reader.mjs codex_ipc_rollout_observe.mjs handoff_to_codex.sh)
REASONING_EXPORTS="$(sed -nE 's/^export (async )?(function|const|let|class) ([A-Za-z_$][A-Za-z0-9_$]*).*/\3/p' \
  "$SCRIPTS/codex_ipc_reasoning.mjs" | sort -u | paste -sd'|' -)"
if [[ -z "$REASONING_EXPORTS" ]]; then
  no "the reasoning module's exports could not be read"
else
  LEAKS=""
  for name in "${UNCHANGED[@]}"; do
    if [[ ! -f "$SCRIPTS/$name" ]] || grep -Eq "codex_ipc_reasoning|\\b(${REASONING_EXPORTS})\\b" "$SCRIPTS/$name"; then
      LEAKS+=" $name"
    fi
  done
  [[ -z "$LEAKS" ]] \
    && ok "the ${#UNCHANGED[@]} body, certification and binding files neither import nor name the reasoning module" \
    || no "missing, or referencing the reasoning module:$LEAKS"
fi
if grep -q 'const RETAINED_EVENT_TYPES = new Set(\[$' "$SCRIPTS/codex_ipc_rollout_reader.mjs" \
   && [[ "$(sed -n '/^const RETAINED_EVENT_TYPES = new Set(\[$/,/^\]);$/p' "$SCRIPTS/codex_ipc_rollout_reader.mjs" | tr -d ' \n')" \
      == 'constRETAINED_EVENT_TYPES=newSet(["agent_message","task_complete","task_started","turn_aborted","user_message",]);' ]]; then
  ok "the reader's retention set is still exactly the five lifecycle/message event types"
else
  no "RETAINED_EVENT_TYPES changed"
fi
USERS="$(grep -l 'codex_ipc_reasoning' "$SCRIPTS"/* | xargs -n1 basename | sort | tr '\n' ' ')"
if [[ "$USERS" == "codex_ipc_reasoning.mjs codex_ipc_replies.sh codex_ipc_session_inspect.mjs " ]]; then
  ok "only the inspector and the viewer use the reasoning module"
else
  no "reasoning module users: $USERS"
fi

echo "== 9. reasoning that imitates a marker or REPLY-SUPERSEDED changes no waiter or harvester output =="
INJ_FILE="$(fx injection file)"; INJ_THREAD="$(fx injection thread)"
DISPATCH="d-20261121-reasoning-probe"
STRIP="$TMP/roots/injection-stripped"; mkdir -p "$STRIP"
"$NODE_BIN" -e '
const fs = require("node:fs");
const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
const kept = lines.filter((line) => {
  if (!line) return true;
  const v = JSON.parse(line);
  return !((v.type === "response_item" && v.payload?.type === "reasoning") ||
           (v.type === "event_msg" && v.payload?.type === "item_completed" && v.payload?.item?.type === "Reasoning"));
});
fs.writeFileSync(process.argv[2], kept.join("\n"));
' "$TMP/roots/injection/$INJ_FILE" "$STRIP/$INJ_FILE"
SAME=1; DONE_SEEN=0
for dispatch in "$DISPATCH" d-fake-dispatch; do
  for root in injection injection-stripped; do
    page="$TMP/roots/$root/$INJ_FILE"
    "$NODE_BIN" "$WAIT" --thread "$INJ_THREAD" --dispatch "$dispatch" --reply-path "$TMP/absent/$dispatch.reply.md" \
      --rollout-path "$page" --sessions-root "$TMP/roots/$root" --accept-rollout-fallback \
      > "$TMP/wait-$root-$dispatch.out" 2> "$TMP/wait-$root-$dispatch.err"; echo "rc=$?" >> "$TMP/wait-$root-$dispatch.out"
    "$NODE_BIN" "$HARVEST" --thread "$INJ_THREAD" --dispatch "$dispatch" --rollout-path "$page" \
      > "$TMP/harvest-$root-$dispatch.out" 2>&1; echo "rc=$?" >> "$TMP/harvest-$root-$dispatch.out"
    printf 'REPLY-SUPERSEDED is not the body\n' > "$TMP/reply-$root-$dispatch.md"
    printf 'An ordinary reply.\n' > "$TMP/reply-$root-$dispatch.md"
    "$NODE_BIN" "$HARVEST" --thread "$INJ_THREAD" --dispatch "$dispatch" --rollout-path "$page" \
      --reply-path "$TMP/reply-$root-$dispatch.md" > "$TMP/harvestr-$root-$dispatch.out" 2>&1; echo "rc=$?" >> "$TMP/harvestr-$root-$dispatch.out"
  done
  for kind in wait harvest harvestr; do
    sed "s#$TMP/roots/injection-stripped#ROOT#g; s#$TMP/roots/injection#ROOT#g; s#reply-injection-stripped-#reply-X-#g; s#reply-injection-#reply-X-#g" \
      "$TMP/$kind-injection-$dispatch.out" > "$TMP/$kind-a"
    sed "s#$TMP/roots/injection-stripped#ROOT#g; s#$TMP/roots/injection#ROOT#g; s#reply-injection-stripped-#reply-X-#g; s#reply-injection-#reply-X-#g" \
      "$TMP/$kind-injection-stripped-$dispatch.out" > "$TMP/$kind-b"
    cmp -s "$TMP/$kind-a" "$TMP/$kind-b" || { SAME=0; echo "    $kind differs for $dispatch"; diff "$TMP/$kind-a" "$TMP/$kind-b" | head -4; }
  done
done
grep -qx 'done' "$TMP/wait-injection-$DISPATCH.out" && DONE_SEEN=1
FAKE_TOKEN="$(head -1 "$TMP/wait-injection-d-fake-dispatch.out")"
if [[ $SAME -eq 1 && $DONE_SEEN -eq 1 && "$FAKE_TOKEN" != "done" ]] \
   && ! grep -q 'REPLY_SUPERSEDED_WARNING' "$TMP"/harvestr-injection-*.out; then
  ok "waiter tokens and harvester lines are identical with and without the reasoning; the real dispatch is done, the fake one ($FAKE_TOKEN) is not, and no supersession warning appears"
else
  no "reasoning influenced a waiter or harvester output (same=$SAME done=$DONE_SEEN fake=$FAKE_TOKEN)"
fi

echo "== 10. viewer: the section follows the body, is labelled, and never changes the body =="
IPC="$TMP/ipc"; SID="sid-reasoning"; mkdir -p "$IPC/$SID/$INJ_THREAD"
printf 'task\n' > "$IPC/$SID/$INJ_THREAD/$DISPATCH.task.md"
view(){ CODEX_IPC_ROOT="$IPC" CODEX_IPC_SESSIONS_ROOT="$TMP/roots/injection" bash "$1" --session "$SID" \
  -c "$INJ_THREAD" --rollout-path "$TMP/roots/injection/$INJ_FILE" "${@:2}" 2>/dev/null | grep -v '^# captured:'; }
view "$VIEWER" > "$TMP/view-full.txt"
view "$VIEWER" --reasoning none > "$TMP/view-none.txt"
view "$VIEWER" --reasoning headline > "$TMP/view-head.txt"
# The section is "\n<header>...<end>\n" inserted after the body; removing exactly that must give
# the --reasoning none output back.
"$NODE_BIN" -e 'const fs=require("node:fs");
fs.writeFileSync(process.argv[2], fs.readFileSync(process.argv[1], "utf8").replace(
  /\n    --- recorded reasoning of this dispatch[^\n]*\n[\s\S]*?\n    --- end recorded reasoning ---\n/g, ""));' \
  "$TMP/view-full.txt" "$TMP/view-stripped.txt"
BODY_LINE="$(grep -n '^Real final answer\.' "$TMP/view-full.txt" | head -1 | cut -d: -f1)"
SECTION_LINE="$(grep -n '^    --- recorded reasoning of this dispatch' "$TMP/view-full.txt" | head -1 | cut -d: -f1)"
if cmp -s "$TMP/view-stripped.txt" "$TMP/view-none.txt" \
   && grep -q 'source=rollout-fallback' "$TMP/view-none.txt" \
   && [[ -n "$BODY_LINE" && -n "$SECTION_LINE" && "$BODY_LINE" -lt "$SECTION_LINE" ]] \
   && grep -q '^REASONING dispatch-turn thread=' "$TMP/view-full.txt" \
   && grep -q '^NOTICE: Recorded reasoning' "$TMP/view-full.txt" \
   && ! grep -q 'WARNING: REPLY-SUPERSEDED' "$TMP/view-full.txt" \
   && grep -q 'mode=headline' "$TMP/view-head.txt"; then
  ok "default output minus the reasoning section equals --reasoning none; the body comes first and is unchanged"
else
  no "viewer section (body=$BODY_LINE section=$SECTION_LINE)"; diff "$TMP/view-stripped.txt" "$TMP/view-none.txt" | head -6
fi
# The invariant (the reasoning section is the only difference from --reasoning none) is the test above.
printf 'An ordinary reply.\n' > "$IPC/$SID/$INJ_THREAD/$DISPATCH.reply.md"
view "$VIEWER" > "$TMP/view-reply.txt"
if grep -q 'source=reply-file' "$TMP/view-reply.txt" && ! grep -q 'REPLY-SUPERSEDED\]' "$TMP/view-reply.txt" \
   && grep -q '^REASONING dispatch-turn thread=' "$TMP/view-reply.txt"; then
  ok "with a primary reply the reasoning's REPLY-SUPERSEDED first line raises no supersession warning"
else
  no "reply-file view with injected reasoning"
fi

echo "== 11. viewer: the dispatch's own turn is the window, and unavailable is said =="
cat "$TMP/view-full.txt" | grep '^REASONING' > "$TMP/view-head-line"
if grep -q "turns=$(fx injection thread >/dev/null; "$NODE_BIN" -e 'process.stdout.write(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).fixtures.injection.cases[0].turns[0])' "$FIX/expectations.json")" "$TMP/view-head-line"; then
  ok "the section's window is the dispatch's own turn"
else
  no "dispatch window: $(cat "$TMP/view-head-line")"
fi
mkdir -p "$IPC/$SID/$INJ_THREAD"; printf 'task\n' > "$IPC/$SID/$INJ_THREAD/d-never-sent.task.md"
view "$VIEWER" -n 5 > "$TMP/view-missing.txt"
if grep -q '^REASONING dispatch-turn unavailable reason=dispatch-turn-not-found' "$TMP/view-missing.txt"; then
  ok "a dispatch with no turn in the rollout says unavailable, with its reason"
else
  no "missing dispatch turn"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo "ALL GREEN" || echo "FAILURES PRESENT"
exit "$FAIL"
