#!/usr/bin/env node
// Negative owner-discovery probe for the Codex Desktop IPC router.
//
// PURPOSE
//   Answer one question with near-zero risk: will the live Desktop IPC router
//   accept a `thread-follower-start-turn` from an EXTERNAL client at all?
//   The proven write route is owner-gated; static analysis could not confirm
//   whether an external (non-renderer) client is allowed to drive it.
//
// HOW IT IS SAFE
//   - The conversationId is ALWAYS a fixed synthetic sentinel UUID set in-process
//     (verifiably absent from the state DB; pre-checked with codex_ipc_snapshot.mjs).
//     No external/real thread id can be supplied. Because no renderer owns the
//     sentinel, owner-discovery must come back empty and NO turn can start on any
//     real thread or session.
//   - Dry-run by default. --send is required to open the pipe.
//   - Single connection, hard timeout, no files written.
//
// INTERPRETING THE RESULT
//   - Router returns a structured "owner/client not found" (or similar) ->
//     the follower route IS externally reachable; only the missing owner stopped
//     it. A real conversationId would very likely be forwarded. => VIABLE.
//   - Router rejects/ignores the request (error "unexpected", closes, or denies
//     the method for external clients) => follower route is NOT externally
//     reachable. => BLOCKED (file-drop stays the answer).

import net from "node:net";
import { randomUUID } from "node:crypto";

const DEFAULT_PIPE = "\\\\.\\pipe\\codex-ipc";
const DEFAULT_TIMEOUT_MS = 4000;
const FOLLOWER_METHOD = "thread-follower-start-turn";
const FOLLOWER_VERSION = 1;

function usage() {
  return `Usage:
  node scripts/codex_ipc_owner_probe.mjs            # dry-run (no connection)
  node scripts/codex_ipc_owner_probe.mjs --send     # one live negative probe

Options:
  --send                Open the pipe and send initialize + one follower-start-turn
                        against the fixed synthetic sentinel (absent) thread id.
  --timeout-ms <n>      Per-step timeout. Default: ${DEFAULT_TIMEOUT_MS}
  --pipe <path>         Named pipe path. Default: ${DEFAULT_PIPE}
  --client-type <text>  Router initialize clientType. Default: external-owner-probe
  --help                Show this help.

Safety: conversationId is ALWAYS the fixed synthetic sentinel UUID in this script,
pre-verifiable as absent from the state DB. No real thread can be targeted; no turn
can start on any real session. Read-only otherwise.`;
}

function parseArgs(argv) {
  const opts = {
    send: false,
    timeoutMs: DEFAULT_TIMEOUT_MS,
    pipePath: DEFAULT_PIPE,
    clientType: "external-owner-probe",
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "--send":
        opts.send = true;
        break;
      case "--timeout-ms": {
        const v = argv[++i];
        const n = Number.parseInt(v, 10);
        if (!Number.isSafeInteger(n) || n <= 0) throw new Error("--timeout-ms must be a positive integer");
        opts.timeoutMs = n;
        break;
      }
      case "--pipe":
        opts.pipePath = argv[++i];
        if (!opts.pipePath) throw new Error("--pipe requires a value");
        break;
      case "--client-type":
        opts.clientType = argv[++i];
        if (!opts.clientType) throw new Error("--client-type requires a value");
        break;
      case "--help":
      case "-h":
        opts.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return opts;
}

function encodeFrame(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  return Buffer.concat([header, body]);
}

function parseFrames(raw) {
  const messages = [];
  let offset = 0;
  while (offset + 4 <= raw.length) {
    const len = raw.readUInt32LE(offset);
    const start = offset + 4;
    const end = start + len;
    if (end > raw.length) break;
    messages.push(JSON.parse(raw.subarray(start, end).toString("utf8")));
    offset = end;
  }
  return messages;
}

function connect(pipePath, timeoutMs) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(pipePath);
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error(`Timed out connecting after ${timeoutMs}ms`));
    }, timeoutMs);
    socket.once("connect", () => {
      clearTimeout(timer);
      resolve(socket);
    });
    socket.once("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

function sendAndWait(socket, message, timeoutMs) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error(`Timed out waiting for ${message.method} after ${timeoutMs}ms`));
    }, timeoutMs);
    function cleanup() {
      clearTimeout(timer);
      socket.off("data", onData);
      socket.off("error", onError);
      socket.off("close", onClose);
    }
    function onError(err) {
      cleanup();
      reject(err);
    }
    function onClose() {
      cleanup();
      reject(new Error("Socket closed before response"));
    }
    function onData(chunk) {
      chunks.push(chunk);
      let frames;
      try {
        frames = parseFrames(Buffer.concat(chunks));
      } catch {
        return;
      }
      const hit = frames.find((f) => f.type === "response" && f.requestId === message.requestId);
      if (hit) {
        cleanup();
        resolve(hit);
      }
    }
    socket.on("data", onData);
    socket.on("error", onError);
    socket.on("close", onClose);
    socket.write(encodeFrame(message));
  });
}

function buildInitialize(clientType) {
  return { type: "request", requestId: randomUUID(), method: "initialize", params: { clientType } };
}

function buildNegativeFollower(sentinelId, clientId) {
  return {
    type: "request",
    requestId: randomUUID(),
    sourceClientId: clientId,
    version: FOLLOWER_VERSION,
    method: FOLLOWER_METHOD,
    params: {
      conversationId: sentinelId,
      turnStartParams: {
        input: [
          {
            type: "text",
            text: "[negative-owner-probe] sentinel thread; no owner expected; no-op",
            text_elements: [],
          },
        ],
      },
    },
  };
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`ERROR: ${err.message}\n`);
    console.error(usage());
    process.exit(1);
  }
  if (opts.help) {
    console.log(usage());
    return;
  }

  // Fixed, clearly-synthetic sentinel so its absence can be pre-verified with
  // codex_ipc_snapshot.mjs before any send. v4-shaped; not a real thread id.
  const sentinelId = "00000000-0000-4000-8000-00000000c0de";
  const initialize = buildInitialize(opts.clientType);
  const followerPreview = buildNegativeFollower(sentinelId, "<client-id-from-initialize>");

  if (!opts.send) {
    console.log(
      JSON.stringify(
        {
          ok: true,
          dryRun: true,
          pipePath: opts.pipePath,
          sentinelId,
          note: "Dry-run: no connection. sentinelId is the fixed synthetic sentinel and must be absent from the state DB before a live negative probe.",
          requests: [
            { name: "initialize", bytes: encodeFrame(initialize).length, json: initialize },
            { name: FOLLOWER_METHOD, bytes: encodeFrame(followerPreview).length, json: followerPreview },
          ],
        },
        null,
        2,
      ),
    );
    return;
  }

  const socket = await connect(opts.pipePath, opts.timeoutMs);
  try {
    const initResponse = await sendAndWait(socket, initialize, opts.timeoutMs);
    const clientId = initResponse?.result?.clientId ?? null;
    if (initResponse.resultType !== "success" || !clientId) {
      console.log(JSON.stringify({ ok: false, stage: "initialize", sentinelId, initResponse }, null, 2));
      process.exit(1);
    }
    const follower = buildNegativeFollower(sentinelId, clientId);
    let followerResponse;
    let followerError = null;
    try {
      followerResponse = await sendAndWait(socket, follower, opts.timeoutMs);
    } catch (err) {
      followerError = err.message;
    }
    console.log(
      JSON.stringify(
        {
          ok: true,
          stage: "follower-sent",
          sentinelId,
          clientId,
          sentFollower: follower,
          followerResponse: followerResponse ?? null,
          followerError,
          interpretation:
            "If followerResponse is a structured owner/client-not-found, the route is externally reachable (VIABLE). " +
            "If followerError/close or an 'unexpected'/denied response, the route is NOT externally reachable (BLOCKED).",
        },
        null,
        2,
      ),
    );
  } finally {
    socket.destroy();
  }
}

await main();
