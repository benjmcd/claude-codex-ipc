#!/usr/bin/env node
// RETIRED: negative owner-discovery probe for the Codex Desktop IPC router.
//
// This tool is deliberately inert. It answers no question, opens no pipe, and sends nothing.
// The file is kept so the required-file contracts in codex_ipc_contract_audit.mjs and
// codex_ipc_revalidate.mjs stay satisfied, and so anyone who reaches for the probe reads why it
// is gone instead of trusting what it used to print.
//
// WHAT IT USED TO DO
//   It sent one `thread-follower-start-turn` at protocol version 1 with a `params.turnStartParams`
//   payload against a fixed synthetic sentinel conversationId, then interpreted the reply:
//   a structured "client not found" was read as VIABLE (the follower route is reachable from an
//   external client) and anything else as BLOCKED.
//
// WHY IT WAS RETIRED
//   That inference does not hold, and on the current Desktop builds it cannot hold.
//   1. The router matches a per-method protocol version EXACTLY, and it does so during client
//      discovery - before ownership is ever evaluated. A version-1 `thread-follower-start-turn` is
//      answered `canHandle:false` by every candidate client, so the probe's own frame was refused
//      on the way in. `no-client-found` then says nothing about whether the route is reachable.
//   2. The router collapses at least nine distinct causes into that single `no-client-found`
//      token: no other client, every candidate refusing, a version mismatch, no registered
//      handler, a failed ownership predicate, a discovery timeout, and a client disconnecting
//      mid-request among them. A tool whose whole output is an interpretation of that token is
//      reporting a guess as a finding.
//   3. Its "safety" rested on the sentinel thread being unowned. That is a property of the host,
//      not of the tool: the same code aimed at an owned thread starts a real model turn. A
//      diagnostic should not be one argument away from a write.
//
// WHAT TO USE INSTEAD
//   - `codex_ipc_probe.mjs` - transport/framing check that sends only `initialize`.
//   - `codex_ipc_revalidate.mjs --allow-live-ipc-read` - the same initialize-only reachability
//     check, wrapped in the static/presence checks.
//   - `codex_ipc_session_inspect.mjs --thread <uuid>` - read-only thread state, no IPC at all.
//   - `docs/COMPATIBILITY.md` and `tests/fixtures/codex_desktop_method_versions.json` - the wire
//     contract itself, derived read-only from the installed Desktop bundle and asserted by
//     `tests/test_router_contract.sh`.
//   None of these can prove that an external client may drive a follower turn on a thread it does
//   not own. That question is answered by an authorized live attempt, not by a probe.

const RETIREMENT = {
  ok: false,
  retired: true,
  tool: "codex_ipc_owner_probe.mjs",
  reason:
    "The follower-route reachability inference this probe encoded is invalid: the router matches " +
    "the per-method protocol version exactly during discovery, before ownership is evaluated, and " +
    "it reports at least nine distinct causes as the single token no-client-found.",
  sends: null,
  useInstead: [
    "codex_ipc_probe.mjs (initialize only)",
    "codex_ipc_revalidate.mjs --allow-live-ipc-read (initialize only)",
    "codex_ipc_session_inspect.mjs --thread <uuid> (read-only, no IPC)",
    "docs/COMPATIBILITY.md + tests/fixtures/codex_desktop_method_versions.json (the wire contract)",
  ],
};

function usage() {
  return `Usage:
  node scripts/codex_ipc_owner_probe.mjs [--help]

RETIRED. This tool is inert: it opens no pipe and sends nothing, on any argument.

It used to send one version-1 thread-follower-start-turn against a synthetic sentinel thread and
read a "client not found" reply as proof that the follower route is reachable from an external
client. That inference is invalid. The router matches the per-method protocol version exactly
during client discovery, before ownership is evaluated, so the probe's own frame was refused on
the way in - and the router reports at least nine distinct causes as the same no-client-found
token. Its safety also depended on the sentinel thread being unowned, which is a property of the
host rather than of the tool.

Use instead:
  codex_ipc_probe.mjs                                 transport/framing, sends initialize only
  codex_ipc_revalidate.mjs --allow-live-ipc-read      same reachability check, with static checks
  codex_ipc_session_inspect.mjs --thread <uuid>       read-only thread state, no IPC
  docs/COMPATIBILITY.md                               the derived wire contract and its provenance`;
}

const argv = process.argv.slice(2);
if (argv.includes("--help") || argv.includes("-h")) {
  console.log(usage());
  process.exit(0);
}

console.error("ERROR: codex_ipc_owner_probe.mjs is retired and sends nothing.");
console.error("");
console.error(usage());
console.log(JSON.stringify(RETIREMENT, null, 2));
process.exit(2);
