// Explicit optional reader; unset retains node:sqlite. No failure fallback.
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

export const READER_ENV = 'CODEX_IPC_SQLITE_READER';
const helper = fileURLToPath(new URL('./codex_ipc_db_read.py', import.meta.url));
const keys = ['schemaVersion', 'executable', 'executableSha256', 'pythonVersion',
  'sqliteVersion', 'sqliteSourceId', 'extensionSha256', 'librarySha256'];
const hash = bytes => createHash('sha256').update(bytes).digest('hex').toUpperCase();
export const pythonReaderSelected = () => Object.hasOwn(process.env, READER_ENV);
const STREAM_LIMIT = 64 * 1024 * 1024;
const HELPER_ERROR_BYTES = 16 * 1024;
const STDERR_TAIL_BYTES = 2048;

function admission() {
  const value = JSON.parse(process.env[READER_ENV]);
  if (!value || Array.isArray(value) || Object.keys(value).sort().join() !== [...keys].sort().join() ||
      value.schemaVersion !== 1 || typeof value.executable !== 'string' || !path.isAbsolute(value.executable) ||
      !keys.filter(k => k.endsWith('Sha256')).every(k => typeof value[k] === 'string' && /^[A-F0-9]{64}$/.test(value[k])) ||
      !['pythonVersion', 'sqliteVersion', 'sqliteSourceId'].every(k => typeof value[k] === 'string' && value[k].length > 0)) {
    throw new Error('Invalid explicit Python SQLite reader admission');
  }
  if (hash(readFileSync(value.executable)) !== value.executableSha256) {
    throw new Error('Selected Python executable identity changed');
  }
  return value;
}

// Raw stdout can hold the complete or partial private row population, so
// failures report stream identities, native status and only the small helper
// error. A capture is partial whenever the child errored, overflowed or was
// signalled; otherwise it is the complete child stream.
function readerFailure(reason, child) {
  const capture = child.error || child.signal ? 'partial' : 'complete';
  const stream = value => {
    const bytes = value ?? Buffer.alloc(0);
    return {capture, bytes: bytes.length, sha256: hash(bytes)};
  };
  const detail = {
    status: child.status ?? null, signal: child.signal ?? null,
    error: child.error ? [child.error.code, child.error.message].filter(Boolean).join(': ') : null,
    stdout: stream(child.stdout), stderr: stream(child.stderr),
  };
  if (capture === 'complete' && child.status !== 0 && child.stdout.length <= HELPER_ERROR_BYTES) {
    try {
      const value = JSON.parse(child.stdout.toString('utf8'));
      if (value?.ok === false && typeof value.error === 'string' && typeof value.errorType === 'string') {
        detail.helper = {error: value.error.slice(0, 2000), errorType: value.errorType.slice(0, 200)};
      }
    } catch {
      // Not the helper's small error JSON; identities above remain.
    }
  }
  if (child.stderr?.length) {
    detail.stderrTail = child.stderr.subarray(-STDERR_TAIL_BYTES).toString('utf8');
  }
  return new Error(`Selected Python SQLite reader ${reason}: ${JSON.stringify(detail)}`);
}

export function readPythonDatabase(operation, parameters = {}) {
  if (!pythonReaderSelected()) return null;
  const identity = admission();
  const argv = ['-I', '-B', '-X', 'utf8', helper];
  const child = spawnSync(identity.executable, argv, {
    input: Buffer.from(JSON.stringify({operation, ...parameters, identity}), 'utf8'),
    windowsHide: true, timeout: 30000, maxBuffer: STREAM_LIMIT,
  });
  // Never parse or accept a partial stream (including ENOBUFS/timeout). A bound
  // failure is explicit; successful results are the complete child JSON.
  if (child.error || child.signal || child.status !== 0) {
    throw readerFailure('failed', child);
  }
  let value;
  try {
    value = JSON.parse(child.stdout.toString('utf8'));
  } catch {
    throw readerFailure('JSON is invalid', child);
  }
  if (child.stderr.length || !value?.ok || !value.identity ||
      Object.keys(value.identity).length !== keys.length || !keys.every(k => value.identity[k] === identity[k])) {
    throw readerFailure('output/identity is invalid', child);
  }
  return value;
}

export function checkPythonReader() {
  if (!pythonReaderSelected()) return null;
  try {
    const value = readPythonDatabase('identity');
    return {ok: true, status: 0, signal: null, stdout: JSON.stringify(value.identity), stderr: '', error: null};
  } catch (error) {
    return {ok: false, status: null, signal: null, stdout: '', stderr: '', error: error.message};
  }
}
