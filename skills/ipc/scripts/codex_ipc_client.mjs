#!/usr/bin/env node
// Experimental Codex Desktop IPC handoff client.
//
// Default behavior is dry-run only. Live writes are intentionally gated because
// the proven Desktop IPC route is owner-gated and starts a real turn.

import net from "node:net";
import { randomUUID } from "node:crypto";
import path from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_PIPE = "\\\\.\\pipe\\codex-ipc";
const DEFAULT_TIMEOUT_MS = 6000;
const DEFAULT_CLIENT_TYPE = "external-handoff";
const FOLLOWER_START_TURN_METHOD = "thread-follower-start-turn";
// Derived read-only from the installed Codex Desktop app.asar; see docs/COMPATIBILITY.md and
// tests/fixtures/codex_desktop_method_versions.json. The app matches this value EXACTLY, before
// ownership is evaluated. A frame-level `hostId` would raise the required value to 3 for every
// `thread-follower-*` method, so this client never sets one: the key must be absent, not null.
const FOLLOWER_START_TURN_VERSION = 2;
// Provenance label only. Nothing in the app branches on this value, and it is stripped wholesale
// for app-servers older than 0.150.0-alpha.10. This is the app's own literal for a tool delivering
// a message into an existing thread, which is what this client does; `composer` (the human
// composer's default) is the other observed literal and is one `--turn-trigger` away.
const DEFAULT_TURN_TRIGGER = "app_tool_send_message";
const TURN_TRIGGER_RE = /^[a-z][a-z0-9_]*$/;
// Optional operator-designated test thread. When set (a UUID of a thread the operator
// owns), --send may target it without --allow-any-thread. No default is shipped:
// there is deliberately no built-in authorized thread id.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const AUTHORIZED_TEST_THREAD_VALUE = process.env.CODEX_IPC_AUTHORIZED_TEST_THREAD || "";
const AUTHORIZED_TEST_THREAD_ID = UUID_RE.test(AUTHORIZED_TEST_THREAD_VALUE)
  ? AUTHORIZED_TEST_THREAD_VALUE.toLowerCase()
  : null;

function usage() {
  return `Usage:
  node scripts/codex_ipc_client.mjs --thread <conversation-id> --task <text> [options]

Dry-run examples:
  node scripts/codex_ipc_client.mjs --thread <conversation-id> --task "read path/to/task.md and proceed"
  node scripts/codex_ipc_client.mjs --thread <conversation-id> --task-file path/to/task.md

Options:
  --thread <uuid>                  Explicit target conversation/thread id. Required.
  --task <text>                    User text to inject as a new turn.
  --task-file <path>               Read user text from a UTF-8 file.
  --model <name>                   Optional model for the turn. NOT a per-turn override: the app
                                   rewrites the thread's stored model with it. Omit it unless the
                                   operator asked for that change.
  --effort <level>                 Optional reasoning effort for the turn. NOT a per-turn override:
                                   the app rewrites the thread's stored reasoning effort with it.
  --cwd <path>                     Optional cwd for the turn. Honored only when the conversation
                                   has no environment cwd of its own.
  --turn-trigger <name>            Provenance label sent with the turn. Default:
                                   ${DEFAULT_TURN_TRIGGER}
  --pipe <path>                    Named pipe path. Default: ${DEFAULT_PIPE}
  --timeout-ms <n>                 Live attempt timeout. Default: ${DEFAULT_TIMEOUT_MS}
  --client-type <text>             Router initialize client type. Default: ${DEFAULT_CLIENT_TYPE}
  --send                           Actually send the follower start-turn request.
  --ack-live-write                 Required with --send; acknowledges this starts a real turn.
  --allow-any-thread               Required with --send unless --thread equals the operator's
                                   CODEX_IPC_AUTHORIZED_TEST_THREAD (mechanism is thread-scoped).
  --help                           Show this help.

Safety:
  Dry-run is the default. --send requires --ack-live-write. --send additionally requires
  --allow-any-thread unless the target equals the optional operator-set
  CODEX_IPC_AUTHORIZED_TEST_THREAD environment variable (no default is shipped).
  The router forwards only to the owning renderer of the given conversationId (no broadcast).
  The app answers a follower start-turn within 5000ms or returns
  error "thread-follower-start-turn-timeout" while the turn may still start: treat that token as
  possibly-started and never resend.`;
}

function parseArgs(argv) {
  const opts = {
    threadId: null,
    task: null,
    taskFile: null,
    model: null,
    effort: null,
    cwd: null,
    turnTrigger: null,
    pipePath: DEFAULT_PIPE,
    timeoutMs: DEFAULT_TIMEOUT_MS,
    clientType: DEFAULT_CLIENT_TYPE,
    send: false,
    ackLiveWrite: false,
    allowAnyThread: false,
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--thread":
      case "--conversation-id":
        opts.threadId = takeValue(argv, ++index, arg);
        break;
      case "--task":
        opts.task = takeValue(argv, ++index, arg);
        break;
      case "--task-file":
        opts.taskFile = takeValue(argv, ++index, arg);
        break;
      case "--model":
        opts.model = takeValue(argv, ++index, arg);
        break;
      case "--effort":
        opts.effort = takeValue(argv, ++index, arg);
        break;
      case "--cwd":
        opts.cwd = takeValue(argv, ++index, arg);
        break;
      case "--turn-trigger":
        opts.turnTrigger = takeValue(argv, ++index, arg);
        break;
      case "--pipe":
        opts.pipePath = takeValue(argv, ++index, arg);
        break;
      case "--timeout-ms":
        opts.timeoutMs = parsePositiveInt(takeValue(argv, ++index, arg), arg);
        break;
      case "--client-type":
        opts.clientType = takeValue(argv, ++index, arg);
        break;
      case "--send":
        opts.send = true;
        break;
      case "--ack-live-write":
        opts.ackLiveWrite = true;
        break;
      case "--allow-any-thread":
        opts.allowAnyThread = true;
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

function takeValue(argv, index, flag) {
  const value = argv[index];
  if (!value || value.startsWith("--")) {
    throw new Error(`${flag} requires a value`);
  }
  return value;
}

function parsePositiveInt(value, flag) {
  if (!/^\d+$/.test(String(value))) {
    throw new Error(`${flag} must be a positive integer`);
  }
  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${flag} must be a positive integer`);
  }
  return parsed;
}

async function normalizeOptions(opts) {
  if (opts.help) {
    return opts;
  }

  if (!opts.threadId || !UUID_RE.test(opts.threadId)) {
    throw new Error("--thread must be an explicit UUID conversation/thread id");
  }
  opts.threadId = opts.threadId.toLowerCase();

  if (opts.task && opts.taskFile) {
    throw new Error("Use either --task or --task-file, not both");
  }

  if (opts.taskFile) {
    const { readFile } = await import("node:fs/promises");
    opts.task = await readFile(opts.taskFile, "utf8");
  }

  opts.task = opts.task?.trim();
  if (!opts.task) {
    throw new Error("--task or --task-file must provide non-empty text");
  }

  if (opts.turnTrigger !== null && !TURN_TRIGGER_RE.test(opts.turnTrigger)) {
    throw new Error("--turn-trigger must match /^[a-z][a-z0-9_]*$/");
  }

  if (opts.send) {
    if (!opts.ackLiveWrite) {
      throw new Error("--send requires --ack-live-write because this starts a real turn");
    }
    const isAuthorizedTestThread =
      AUTHORIZED_TEST_THREAD_ID && opts.threadId === AUTHORIZED_TEST_THREAD_ID;
    if (!isAuthorizedTestThread && !opts.allowAnyThread) {
      throw new Error(
        "--send requires --allow-any-thread for this conversationId. (Alternatively, set " +
          "CODEX_IPC_AUTHORIZED_TEST_THREAD to a test thread you own to exempt that one id.) " +
          "The mechanism is thread-scoped; the router forwards only to the owning renderer " +
          "of the given conversationId.",
      );
    }
  }

  return opts;
}

function buildInitializeRequest(opts) {
  return {
    type: "request",
    requestId: randomUUID(),
    method: "initialize",
    params: {
      clientType: opts.clientType,
    },
  };
}

function buildFollowerStartTurnRequest(opts, clientId) {
  // `turnStart.request`: threadId and input are the only REQUIRED fields, and threadId MUST equal
  // params.conversationId or the renderer throws "Turn request thread does not match the
  // conversation". The input item shape is the app's own plain user-message form.
  const request = {
    threadId: opts.threadId,
    turnTrigger: opts.turnTrigger || DEFAULT_TURN_TRIGGER,
    input: [
      {
        type: "text",
        text: opts.task,
        text_elements: [],
      },
    ],
  };

  // Optional operator opt-ins. Unlike the pre-repair payload these are now actually read, and
  // model/effort rewrite the target thread's stored settings, so they stay absent by default.
  if (opts.model) {
    request.model = opts.model;
  }
  if (opts.effort) {
    request.effort = opts.effort;
  }
  if (opts.cwd) {
    request.cwd = opts.cwd;
  }

  // No frame-level `hostId` key (absent, never null) and no `turnStart.context`: both are how the
  // app itself calls the local host, and either would reproduce the original rejection.
  return {
    type: "request",
    requestId: randomUUID(),
    sourceClientId: clientId,
    version: FOLLOWER_START_TURN_VERSION,
    method: FOLLOWER_START_TURN_METHOD,
    params: {
      conversationId: opts.threadId,
      turnStart: { request },
    },
  };
}

function encodeFrame(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  return Buffer.concat([header, body]);
}

function parseAvailableFrames(raw) {
  const messages = [];
  let offset = 0;

  while (offset < raw.length) {
    if (raw.length - offset < 4) {
      break;
    }
    const bodyLength = raw.readUInt32LE(offset);
    const bodyStart = offset + 4;
    const bodyEnd = bodyStart + bodyLength;
    if (bodyEnd > raw.length) {
      break;
    }
    messages.push(JSON.parse(raw.subarray(bodyStart, bodyEnd).toString("utf8")));
    offset = bodyEnd;
  }

  return messages;
}

function connectRouter(pipePath, timeoutMs) {
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
    socket.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

function sendAndWait(socket, message, timeoutMs) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    const requestId = message.requestId;
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error(`Timed out waiting for ${message.method} response after ${timeoutMs}ms`));
    }, timeoutMs);

    function cleanup() {
      clearTimeout(timer);
      socket.off("data", onData);
      socket.off("error", onError);
      socket.off("close", onClose);
    }

    function onError(error) {
      cleanup();
      reject(error);
    }

    function onClose() {
      cleanup();
      reject(new Error("Socket closed before response"));
    }

    function onData(chunk) {
      chunks.push(chunk);
      let frames;
      try {
        frames = parseAvailableFrames(Buffer.concat(chunks));
      } catch {
        return;
      }

      const response = frames.find((frame) => frame.type === "response" && frame.requestId === requestId);
      if (response) {
        cleanup();
        resolve(response);
      }
    }

    socket.on("data", onData);
    socket.on("error", onError);
    socket.on("close", onClose);
    socket.write(encodeFrame(message));
  });
}

function dryRunResponse(opts, initializeRequest, followerRequest) {
  return {
    ok: true,
    dryRun: true,
    pipePath: opts.pipePath,
    authorizedTestThreadId: AUTHORIZED_TEST_THREAD_ID,
    targetThreadId: opts.threadId,
    liveWriteWouldBeAllowedWithSend:
      opts.allowAnyThread ||
      Boolean(AUTHORIZED_TEST_THREAD_ID && opts.threadId === AUTHORIZED_TEST_THREAD_ID),
    warnings: [
      "Dry-run only: no pipe connection and no live write were attempted.",
      "This client issues no read-only owner query: the app's method table does carry a thread-owner-discovery method, but nothing here has ever exercised it, so real owner proof stays coupled to the first controlled follower write.",
      "thread-follower-start-turn starts a real model turn when sent.",
      "--model/--effort rewrite the target thread's stored model/reasoning settings; omit them " +
        "unless the operator asked for that change.",
      "The app answers a follower start-turn within 5000ms or returns error " +
        "'thread-follower-start-turn-timeout' while the turn may still start - treat that token " +
        "as possibly-started and never resend.",
    ],
    requests: [
      {
        name: "initialize",
        bytes: encodeFrame(initializeRequest).length,
        json: initializeRequest,
      },
      {
        name: FOLLOWER_START_TURN_METHOD,
        bytes: encodeFrame(followerRequest).length,
        json: followerRequest,
      },
    ],
  };
}

// Pure projection kept separate from named-pipe I/O so non-success responses retain the exact
// follower request occurrence and can be verified hermetically without opening a live pipe.
export function projectLiveResponse(
  opts,
  initializeRequest,
  initResponse,
  followerRequest,
  followerResponse,
) {
  return {
    ok: followerResponse.resultType === "success",
    pipePath: opts.pipePath,
    targetThreadId: opts.threadId,
    sentRequests: [
      {
        name: "initialize",
        bytes: encodeFrame(initializeRequest).length,
        json: initializeRequest,
      },
      {
        name: FOLLOWER_START_TURN_METHOD,
        bytes: encodeFrame(followerRequest).length,
        json: followerRequest,
      },
    ],
    initialize: initResponse,
    response: followerResponse,
  };
}

async function sendLive(opts, initializeRequest) {
  const socket = await connectRouter(opts.pipePath, opts.timeoutMs);
  try {
    const initResponse = await sendAndWait(socket, initializeRequest, opts.timeoutMs);
    if (initResponse.resultType !== "success" || !initResponse.result?.clientId) {
      throw new Error(`Router initialize failed: ${JSON.stringify(initResponse)}`);
    }

    const followerRequest = buildFollowerStartTurnRequest(opts, initResponse.result.clientId);
    const followerResponse = await sendAndWait(socket, followerRequest, opts.timeoutMs);
    return projectLiveResponse(
      opts,
      initializeRequest,
      initResponse,
      followerRequest,
      followerResponse,
    );
  } finally {
    socket.destroy();
  }
}

async function main() {
  let opts;
  try {
    opts = await normalizeOptions(parseArgs(process.argv.slice(2)));
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    console.error("");
    console.error(usage());
    process.exit(1);
  }

  if (opts.help) {
    console.log(usage());
    return;
  }

  const initializeRequest = buildInitializeRequest(opts);
  const dryRunFollowerRequest = buildFollowerStartTurnRequest(opts, "<client-id-from-initialize>");

  if (!opts.send) {
    console.log(JSON.stringify(dryRunResponse(opts, initializeRequest, dryRunFollowerRequest), null, 2));
    return;
  }

  const result = await sendLive(opts, initializeRequest);
  console.log(JSON.stringify(result, null, 2));
  if (!result.ok) {
    process.exit(1);
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  await main();
}
