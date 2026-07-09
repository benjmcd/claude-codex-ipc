#!/usr/bin/env node
// Read-only probe for the Codex Desktop IPC named pipe.
//
// This script intentionally supports only non-mutating methods. It is a
// research tool for transport/framing discovery, not the production handoff
// client. The Desktop pipe is an IPC router; raw app-server JSON is available
// only as an explicit compatibility probe.

import net from "node:net";

const DEFAULT_PIPE = "\\\\.\\pipe\\codex-ipc";
const DEFAULT_TIMEOUT_MS = 2000;
const DEFAULT_LIMIT = 10;
const DEFAULT_PROTOCOL = "ipc-router";
const DEFAULT_FRAMING = "uint32le";
const READ_ONLY_METHODS = new Set([
  "initialize",
  "thread/list",
  "thread/loaded/list",
  "thread/read",
]);

const REQUEST_TO_METHOD = new Map([
  ["initialize", "initialize"],
  ["thread-list", "thread/list"],
  ["thread-loaded-list", "thread/loaded/list"],
  ["thread-read", "thread/read"],
]);

function usage() {
  return `Usage:
  node scripts/codex_ipc_probe.mjs [options]

Options:
  --dry-run                         Print requests and framed byte counts only.
  --allow-live-ipc-read             Connect to the IPC pipe and wait for router responses.
  --pipe <path>                     Named pipe path. Default: ${DEFAULT_PIPE}
  --timeout-ms <n>                  Per-attempt timeout. Default: ${DEFAULT_TIMEOUT_MS}
  --protocol <ipc-router|app-server-json>
                                    Request envelope to send. Default: ${DEFAULT_PROTOCOL}.
  --framing <uint32le|content-length|newline|raw|all>
                                    Wire framing to try. Default: ${DEFAULT_FRAMING}.
  --client-type <text>              ipc-router initialize client type. Default: external-probe.
  --jsonrpc                         Include "jsonrpc":"2.0" in request envelopes.
  --experimental-api                Set initialize capabilities.experimentalApi=true.
  --sequence <csv>                  Requests to send. Default: initialize.
                                    Allowed: initialize,thread-list,thread-loaded-list,thread-read.
  --thread <uuid>                   Required when sequence includes thread-read.
  --limit <n>                       Limit for thread-list/thread-loaded-list. Default: ${DEFAULT_LIMIT}
  --cwd <path>                      Optional cwd filter for thread-list.
  --help                            Show this help.

Exit code:
  0 only when a JSON response is received and parsed.
  1 on connect failure, close without response, timeout, or unparsable response.`;
}

function parseArgs(argv) {
  const opts = {
    dryRun: true,
    allowLiveIpcRead: false,
    pipePath: DEFAULT_PIPE,
    timeoutMs: DEFAULT_TIMEOUT_MS,
    protocol: DEFAULT_PROTOCOL,
    framing: DEFAULT_FRAMING,
    clientType: "external-probe",
    includeJsonRpc: false,
    experimentalApi: false,
    sequence: ["initialize"],
    threadId: null,
    limit: DEFAULT_LIMIT,
    cwd: null,
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--dry-run":
        opts.dryRun = true;
        break;
      case "--allow-live-ipc-read":
        opts.allowLiveIpcRead = true;
        opts.dryRun = false;
        break;
      case "--pipe":
        opts.pipePath = takeValue(argv, ++index, arg);
        break;
      case "--timeout-ms":
        opts.timeoutMs = parsePositiveInt(takeValue(argv, ++index, arg), arg);
        break;
      case "--protocol":
        opts.protocol = takeValue(argv, ++index, arg);
        break;
      case "--framing":
        opts.framing = takeValue(argv, ++index, arg);
        break;
      case "--client-type":
        opts.clientType = takeValue(argv, ++index, arg);
        break;
      case "--jsonrpc":
        opts.includeJsonRpc = true;
        break;
      case "--experimental-api":
        opts.experimentalApi = true;
        break;
      case "--sequence":
        opts.sequence = takeValue(argv, ++index, arg)
          .split(",")
          .map((value) => value.trim())
          .filter(Boolean);
        break;
      case "--thread":
        opts.threadId = takeValue(argv, ++index, arg);
        break;
      case "--limit":
        opts.limit = parsePositiveInt(takeValue(argv, ++index, arg), arg);
        break;
      case "--cwd":
        opts.cwd = takeValue(argv, ++index, arg);
        break;
      case "--help":
      case "-h":
        opts.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!["ipc-router", "app-server-json"].includes(opts.protocol)) {
    throw new Error(`Unsupported --protocol value: ${opts.protocol}`);
  }

  if (!["uint32le", "content-length", "newline", "raw", "all"].includes(opts.framing)) {
    throw new Error(`Unsupported --framing value: ${opts.framing}`);
  }

  for (const requestName of opts.sequence) {
    if (!REQUEST_TO_METHOD.has(requestName)) {
      throw new Error(`Unsupported request in --sequence: ${requestName}`);
    }
  }

  if (opts.sequence.includes("thread-read") && !opts.threadId) {
    throw new Error("--thread is required when --sequence includes thread-read");
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

function buildRequests(opts) {
  if (opts.protocol === "ipc-router") {
    return buildIpcRouterRequests(opts);
  }
  return buildAppServerJsonRequests(opts);
}

function buildIpcRouterRequests(opts) {
  return opts.sequence.map((requestName, index) => {
    if (requestName !== "initialize") {
      throw new Error(
        `Refusing ipc-router ${requestName}: generic app-server methods are not exposed on the proven Desktop router path`,
      );
    }

    return {
      type: "request",
      requestId: String(index + 1),
      method: "initialize",
      params: {
        clientType: opts.clientType,
      },
    };
  });
}

function buildAppServerJsonRequests(opts) {
  return opts.sequence.map((requestName, index) => {
    const method = REQUEST_TO_METHOD.get(requestName);
    if (!READ_ONLY_METHODS.has(method)) {
      throw new Error(`Refusing non-read-only method: ${method}`);
    }

    const request = {
      id: String(index + 1),
      method,
      params: buildParams(requestName, opts),
    };
    if (opts.includeJsonRpc) {
      request.jsonrpc = "2.0";
    }
    return request;
  });
}

function buildParams(requestName, opts) {
  if (requestName === "initialize") {
    const capabilities = {};
    if (opts.experimentalApi) {
      capabilities.experimentalApi = true;
    }
    return {
      clientInfo: {
        name: "codex-ipc-probe",
        title: "Codex IPC Probe",
        version: "0.1.0",
      },
      capabilities: Object.keys(capabilities).length > 0 ? capabilities : null,
    };
  }

  if (requestName === "thread-list") {
    const params = {
      archived: false,
      limit: opts.limit,
      sortDirection: "desc",
      sortKey: "updated_at",
      useStateDbOnly: true,
    };
    if (opts.cwd) {
      params.cwd = opts.cwd;
    }
    return params;
  }

  if (requestName === "thread-loaded-list") {
    return { limit: opts.limit };
  }

  if (requestName === "thread-read") {
    return {
      threadId: opts.threadId,
      includeTurns: false,
    };
  }

  throw new Error(`No params builder for request: ${requestName}`);
}

function encodeRequest(request, framing) {
  const json = JSON.stringify(request);
  if (framing === "content-length") {
    return Buffer.from(
      `Content-Length: ${Buffer.byteLength(json, "utf8")}\r\n\r\n${json}`,
      "utf8",
    );
  }
  if (framing === "uint32le") {
    const body = Buffer.from(json, "utf8");
    const header = Buffer.alloc(4);
    header.writeUInt32LE(body.length, 0);
    return Buffer.concat([header, body]);
  }
  if (framing === "newline") {
    return Buffer.from(`${json}\n`, "utf8");
  }
  if (framing === "raw") {
    return Buffer.from(json, "utf8");
  }
  throw new Error(`Unsupported framing: ${framing}`);
}

function probePipe({ pipePath, timeoutMs, framing, requests }) {
  return new Promise((resolve) => {
    const chunks = [];
    let settled = false;
    const socket = net.createConnection(pipePath);

    function settle(result) {
      if (settled) {
        return;
      }
      settled = true;
      socket.destroy();
      resolve({
        ...result,
        raw: Buffer.concat(chunks),
      });
    }

    socket.setTimeout(timeoutMs);

    socket.on("connect", () => {
      for (const request of requests) {
        const payload = encodeRequest(request, framing);
        socket.write(payload);
      }
    });

    socket.on("data", (chunk) => {
      chunks.push(chunk);
      const parsed = parseResponses(Buffer.concat(chunks));
      if (parsed.length >= requests.length) {
        settle({ status: "response" });
      }
    });

    socket.on("timeout", () => {
      settle({ status: "timeout", error: `Timed out after ${timeoutMs}ms` });
    });

    socket.on("error", (error) => {
      settle({ status: "error", error: error.message });
    });

    socket.on("close", () => {
      if (chunks.length === 0) {
        settle({ status: "closed", error: "Socket closed without response bytes" });
        return;
      }
      settle({ status: "closed" });
    });
  });
}

function parseResponses(raw) {
  const parsers = [
    parseUint32LeResponses,
    parseContentLengthResponses,
    parseNdjsonResponses,
    parseSingleJsonResponse,
  ];

  for (const parser of parsers) {
    try {
      const parsed = parser(raw);
      if (parsed.length > 0) {
        return parsed;
      }
    } catch {
      // Try the next parser.
    }
  }

  return [];
}

function parseUint32LeResponses(raw) {
  const messages = [];
  let offset = 0;

  while (offset < raw.length) {
    if (raw.length - offset < 4) {
      throw new Error("Incomplete uint32le frame header");
    }

    const bodyLength = raw.readUInt32LE(offset);
    const bodyStart = offset + 4;
    const bodyEnd = bodyStart + bodyLength;
    if (bodyEnd > raw.length) {
      throw new Error("Incomplete uint32le frame body");
    }

    messages.push(JSON.parse(raw.subarray(bodyStart, bodyEnd).toString("utf8")));
    offset = bodyEnd;
  }

  return messages;
}

function parseContentLengthResponses(raw) {
  const messages = [];
  let offset = 0;

  while (offset < raw.length) {
    offset = skipAsciiWhitespace(raw, offset);
    if (offset >= raw.length) {
      break;
    }

    const headerEnd = findHeaderEnd(raw, offset);
    if (!headerEnd) {
      throw new Error("Missing Content-Length header terminator");
    }

    const header = raw.subarray(offset, headerEnd.index).toString("ascii");
    const match = header.match(/content-length:\s*(\d+)/i);
    if (!match) {
      throw new Error("Missing Content-Length header");
    }

    const bodyLength = Number.parseInt(match[1], 10);
    const bodyStart = headerEnd.index + headerEnd.length;
    const bodyEnd = bodyStart + bodyLength;
    if (bodyEnd > raw.length) {
      throw new Error("Incomplete Content-Length body");
    }

    messages.push(JSON.parse(raw.subarray(bodyStart, bodyEnd).toString("utf8")));
    offset = bodyEnd;
  }

  return messages;
}

function findHeaderEnd(raw, offset) {
  const crlf = raw.indexOf("\r\n\r\n", offset, "utf8");
  const lf = raw.indexOf("\n\n", offset, "utf8");
  if (crlf === -1 && lf === -1) {
    return null;
  }
  if (crlf !== -1 && (lf === -1 || crlf <= lf)) {
    return { index: crlf, length: 4 };
  }
  return { index: lf, length: 2 };
}

function skipAsciiWhitespace(raw, offset) {
  let next = offset;
  while (next < raw.length) {
    const byte = raw[next];
    if (byte !== 9 && byte !== 10 && byte !== 13 && byte !== 32) {
      break;
    }
    next += 1;
  }
  return next;
}

function parseNdjsonResponses(raw) {
  return raw
    .toString("utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function parseSingleJsonResponse(raw) {
  const text = raw.toString("utf8").trim();
  return text ? [JSON.parse(text)] : [];
}

function preview(raw) {
  const text = raw.toString("utf8");
  const truncated = text.length > 4000 ? `${text.slice(0, 4000)}...<truncated>` : text;
  return JSON.stringify(truncated);
}

function printRequests(requests) {
  for (const request of requests) {
    const id = request.id ?? request.requestId ?? "?";
    console.error(`[codex-ipc-probe] request ${id}: ${JSON.stringify(request)}`);
  }
}

function framingsFor(opts) {
  if (opts.framing !== "all") {
    return [opts.framing];
  }
  if (opts.protocol === "ipc-router") {
    return ["uint32le", "content-length", "newline", "raw"];
  }
  return ["content-length", "newline", "raw", "uint32le"];
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
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

  let requests;
  try {
    requests = buildRequests(opts);
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    process.exit(1);
  }
  printRequests(requests);

  const framings = framingsFor(opts);

  if (opts.dryRun) {
    const attempts = framings.map((framing) => ({
      framing,
      bytes: requests.map((request) => encodeRequest(request, framing).length),
    }));
    console.log(
      JSON.stringify(
        {
          ok: true,
          dryRun: true,
          pipePath: opts.pipePath,
          protocol: opts.protocol,
          attempts,
          methods: requests.map((request) => request.method),
        },
        null,
        2,
      ),
    );
    return;
  }

  const failures = [];
  for (const framing of framings) {
    console.error(`[codex-ipc-probe] connecting to ${opts.pipePath} (${framing})`);
    const result = await probePipe({
      pipePath: opts.pipePath,
      timeoutMs: opts.timeoutMs,
      framing,
      requests,
    });
    const parsed = parseResponses(result.raw);
    if (parsed.length > 0) {
      console.log(
        JSON.stringify(
          {
            ok: true,
            framing,
            status: result.status,
            responseCount: parsed.length,
            responses: parsed,
            rawBytes: result.raw.length,
          },
          null,
          2,
        ),
      );
      return;
    }

    failures.push({
      framing,
      status: result.status,
      error: result.error ?? "Response bytes were not valid JSON",
      rawBytes: result.raw.length,
      rawPreview: preview(result.raw),
    });
  }

  console.log(
    JSON.stringify(
      {
        ok: false,
        pipePath: opts.pipePath,
        protocol: opts.protocol,
        failures,
      },
      null,
      2,
    ),
  );
  process.exit(1);
}

await main();
