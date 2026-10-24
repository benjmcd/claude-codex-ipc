"""Fixed-operation read-only SQLite reader. JSON stdin/stdout; no SQL input.

--identity prints the reviewable runtime selection without opening a file DB.
Windows held existing handles prohibit missing-sidecar creation races. The
rollback path additionally excludes writers for its short read, since a mode
change could otherwise introduce unguarded WAL files. POSIX is not qualified.
"""
from contextlib import ExitStack, contextmanager
from pathlib import Path
import _sqlite3
import ctypes
from ctypes import wintypes
import hashlib
import json
import math
import os
import platform
import re
import sqlite3
import sys
import threading

COLUMNS = frozenset('id rollout_path created_at updated_at cwd title source model_provider '
    'model reasoning_effort sandbox_policy approval_mode tokens_used archived thread_source '
    'agent_nickname agent_role agent_path preview first_user_message created_at_ms updated_at_ms '
    'has_user_event git_sha git_branch cli_version memory_mode'.split())
UUID = re.compile(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$')
# A killed Node parent does not terminate this child on Windows; bound it here too.
DEADLINE_SECONDS = 30
ERROR_LOCK_VIOLATION = 33
# SQLite 3.45.1 os_win.c: WIN_SHM_BASE=(22+8)*4, DMS=BASE+8.
DMS_OFFSET = 128


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def identity():
    library_hash = None
    if os.name == 'nt':
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.GetModuleHandleW.argtypes = [wintypes.LPCWSTR]
        kernel.GetModuleHandleW.restype = wintypes.HMODULE
        kernel.GetModuleFileNameW.argtypes = [wintypes.HMODULE, wintypes.LPWSTR, wintypes.DWORD]
        kernel.GetModuleFileNameW.restype = wintypes.DWORD
        module = kernel.GetModuleHandleW('sqlite3.dll')
        buffer = ctypes.create_unicode_buffer(32768)
        count = kernel.GetModuleFileNameW(module, buffer, len(buffer)) if module else 0
        if not count or count == len(buffer):
            raise RuntimeError('Cannot identify the loaded SQLite library')
        library_hash = sha(buffer.value)
    with sqlite3.connect(':memory:') as db:
        source = db.execute('select sqlite_source_id()').fetchone()[0]
    return dict(schemaVersion=1, executable=str(Path(sys.executable).resolve()),
        executableSha256=sha(sys.executable), pythonVersion=platform.python_version(),
        sqliteVersion=sqlite3.sqlite_version, sqliteSourceId=source,
        extensionSha256=sha(_sqlite3.__file__), librarySha256=library_hash)


@contextmanager
def existing_handle(path, share=3):
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
        ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    # GENERIC_READ; OPEN_EXISTING; never DELETE sharing, CREATE or write access.
    handle = kernel.CreateFileW(str(path), 0x80000000, share, None, 3, 0x80, None)
    if handle == ctypes.c_void_p(-1).value:
        raise OSError(ctypes.get_last_error(), 'Required existing read-only file unavailable: ' + str(path))
    try:
        yield handle
    finally:
        kernel.CloseHandle(handle)


def header(path):
    with path.open('rb') as stream:
        value = stream.read(100)
    if len(value) != 100 or value[:16] != b'SQLite format 3\0' or value[18:20] not in (b'\1\1', b'\2\2'):
        raise ValueError('Required existing SQLite header is invalid')
    return value[18:20]


class Overlapped(ctypes.Structure):
    _fields_ = [('Internal', ctypes.c_size_t), ('InternalHigh', ctypes.c_size_t),
        ('Offset', wintypes.DWORD), ('OffsetHigh', wintypes.DWORD), ('hEvent', wintypes.HANDLE)]


def lock_api():
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    for name in ('LockFileEx', 'UnlockFileEx'):
        function = getattr(kernel, name)
        function.argtypes = [wintypes.HANDLE, wintypes.DWORD] + ([wintypes.DWORD] if name == 'LockFileEx' else []) + [
            wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(Overlapped)]
        function.restype = wintypes.BOOL
    return kernel


def dms_lock(handle, exclusive):
    # Nonblocking one-byte lock: True acquired, False held by another handle.
    # Any other failure is not evidence of an owner and refuses.
    flags = 0x1 | (0x2 if exclusive else 0)  # LOCKFILE_FAIL_IMMEDIATELY | EXCLUSIVE
    if lock_api().LockFileEx(handle, flags, 0, 1, 0, ctypes.byref(Overlapped(Offset=DMS_OFFSET))):
        return True
    error = ctypes.get_last_error()
    if error == ERROR_LOCK_VIOLATION:
        return False
    raise OSError(error, 'Unexpected WAL index lock failure')


def dms_unlock(handle):
    if not lock_api().UnlockFileEx(handle, 0, 1, 0, ctypes.byref(Overlapped(Offset=DMS_OFFSET))):
        raise OSError(ctypes.get_last_error(), 'Existing WAL index lock could not be released')


@contextmanager
def existing_index_lock(handle):
    # Every live SQLite connection holds a shared DMS lock. If an exclusive
    # probe succeeds, nobody owns the on-disk index: ordinary SQLite would
    # truncate and recover it, and readonly_shm would rebuild it in heap
    # memory. Either is recovery, so refuse. (SQLite's own read-only open makes
    # the same momentary exclusive probe.) Otherwise hold a shared DMS lock
    # while SQLite attaches, so it validates the owned index header itself and
    # returns READONLY_RECOVERY for an invalid one. Locks only; no index write.
    if dms_lock(handle, exclusive=True):
        dms_unlock(handle)
        raise ValueError('Existing WAL index has no live owner; SQLite recovery would be required')
    if not dms_lock(handle, exclusive=False):
        raise OSError(ERROR_LOCK_VIOLATION, 'Existing WAL index lock is unavailable')
    try:
        yield
    except BaseException:
        try:
            dms_unlock(handle)
        except OSError:
            pass  # Closing the held handle releases it; keep the original failure.
        raise
    dms_unlock(handle)


@contextmanager
def guarded_database(raw):
    if os.name != 'nt':
        raise RuntimeError('Explicit Python SQLite file access is currently qualified for Windows only')
    if not isinstance(raw, str) or not Path(raw).is_absolute():
        raise ValueError('database must be an absolute existing file path')
    path = Path(raw).resolve(strict=True)
    with ExitStack() as held:
        held.enter_context(existing_handle(path))
        mode = header(path)
        if mode == b'\2\2':
            for suffix in ('-wal', '-shm'):
                sidecar = Path(str(path) + suffix)
                handle = held.enter_context(existing_handle(sidecar))
                size = sidecar.stat().st_size
                if suffix == '-shm' and size < 32768:
                    raise ValueError('Existing WAL index requires initialization')
                if suffix == '-shm':
                    held.enter_context(existing_index_lock(handle))
                if suffix == '-wal' and size != 0 and size < 32:
                    raise ValueError('Existing WAL header is incomplete')
        else:
            # A second read handle allowing READ sharing only excludes existing
            # and new writers. Keep the first handle across this acquisition.
            held.enter_context(existing_handle(path, share=1))
            if any(Path(str(path) + suffix).exists() for suffix in ('-wal', '-shm', '-journal')):
                raise ValueError('Rollback database has unexpected journal state')
        if header(path) != mode:
            raise ValueError('Database journal mode changed during guard admission')
        # readonly_shm prevents index creation/recovery or reader-mark writes.
        uri = path.as_uri() + '?mode=ro&readonly_shm=1'
        db = sqlite3.connect(uri, uri=True, timeout=1)
        try:
            db.row_factory = sqlite3.Row
            db.execute('pragma query_only=on')
            db.execute('begin')
            observed = db.execute('pragma journal_mode').fetchone()[0]
            if observed != ('wal' if mode == b'\2\2' else 'delete'):
                raise ValueError('Database journal mode differs from held file header')
            yield db
        finally:
            db.close()


def rows(db, sql, parameters=()):
    return [dict(row) for row in db.execute(sql, parameters)]


def read(request):
    operation = request.get('operation')
    if operation not in ('inspect', 'snapshot', 'locate'):
        raise ValueError('Unsupported fixed reader operation')
    allowed = {'operation', 'database', 'columns', 'identity'} | ({'threadId'} if operation == 'inspect' else set())
    if set(request) != allowed:
        raise ValueError('Unexpected or missing reader parameters')
    columns = request['columns']
    if not isinstance(columns, list) or not columns or any(not isinstance(c, str) or c not in COLUMNS for c in columns) or len(set(columns)) != len(columns):
        raise ValueError('Unsupported, empty or duplicate column selection')
    if operation == 'inspect' and (not isinstance(request['threadId'], str) or not UUID.fullmatch(request['threadId'])):
        raise ValueError('threadId must be a canonical UUID')
    with guarded_database(request['database']) as db:
        available = [r['name'] for r in db.execute('pragma table_info(threads)')]
        selected = columns if operation == 'snapshot' else [c for c in columns if c in available]
        if operation == 'inspect' and 'id' not in selected:
            raise ValueError('threads table does not expose an id column')
        selection = ', '.join('"' + c + '"' for c in selected)
        # With DQS disabled, absent snapshot columns must be SQL errors. Detect
        # explicitly rather than SQLite treating an unknown quoted name as text.
        if operation == 'snapshot' and any(c not in available for c in selected):
            raise ValueError('Snapshot threads schema is missing required columns')
        where = ' where id = ?' if operation == 'inspect' else (' order by id' if operation == 'snapshot' else '')
        result = dict(availableColumns=available,
            rows=rows(db, 'select ' + selection + ' from threads' + where,
                      (request['threadId'],) if operation == 'inspect' else ()))
        if operation == 'inspect':
            result.update(spawnTableExists=False, spawnColumns=[], spawnRows=[], spawnError=None)
            try:
                result['spawnTableExists'] = bool(db.execute("select name from sqlite_master where type='table' and name=?", ('thread_spawn_edges',)).fetchone())
                if result['spawnTableExists']:
                    result['spawnColumns'] = [r['name'] for r in db.execute('pragma table_info(thread_spawn_edges)')]
                    if {'parent_thread_id', 'child_thread_id'} <= set(result['spawnColumns']):
                        status = ', status' if 'status' in result['spawnColumns'] else ''
                        result['spawnRows'] = rows(db, 'select parent_thread_id as parentThreadId, child_thread_id as childThreadId' + status + ' from thread_spawn_edges where lower(child_thread_id)=?', (request['threadId'],))
            except sqlite3.Error as error:
                result['spawnError'] = str(error)
        if operation == 'snapshot':
            result.update(tableNames=[r['name'] for r in db.execute("select name from sqlite_master where type='table' order by name")],
                pageCount=db.execute('pragma page_count').fetchone()[0], pageSize=db.execute('pragma page_size').fetchone()[0],
                quickCheck=db.execute('pragma quick_check').fetchone()[0])
        return result


def representable(value):
    if value is None or isinstance(value, str):
        return
    if isinstance(value, int) and abs(value) <= 9007199254740991:
        return
    if isinstance(value, float) and math.isfinite(value):
        return
    if isinstance(value, dict):
        for item in value.values():
            representable(item)
        return
    if isinstance(value, list):
        for item in value:
            representable(item)
        return
    raise ValueError('Unsupported SQLite result type or unsafe/non-finite numeric value')


def main():
    observed = identity()
    if sys.argv[1:] == ['--identity']:
        return observed
    if sys.argv[1:]:
        raise ValueError('Only --identity or fixed JSON stdin is accepted')
    request = json.load(sys.stdin)
    if not isinstance(request, dict) or request.get('identity') != observed:
        raise ValueError('Explicit Python/SQLite runtime identity differs from admission')
    if os.name != 'nt' or observed['sqliteVersion'] != '3.45.1':
        raise RuntimeError('Explicit reader currently requires qualified Windows SQLite 3.45.1')
    if request.get('operation') == 'identity' and set(request) == {'operation', 'identity'}:
        return dict(ok=True, identity=observed, result=None)
    result = read(request)
    representable(result)
    return dict(ok=True, identity=observed, result=result)


if __name__ == '__main__':
    deadline = threading.Timer(DEADLINE_SECONDS, os._exit, args=(124,))
    deadline.daemon = True
    deadline.start()
    try:
        print(json.dumps(main(), ensure_ascii=True, allow_nan=False, separators=(',', ':')))
    except Exception as error:
        print(json.dumps(dict(ok=False, error=str(error), errorType=type(error).__name__)))
        sys.exit(1)
