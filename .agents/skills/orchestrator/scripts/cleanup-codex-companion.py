#!/usr/bin/env python3
"""Release a finished workspace's Codex Companion broker (Linux, stdlib only).

Dry-run unless --execute is supplied. Run from the parent orchestrator, after
collecting results and deciding that this worker will not be resumed in memory.
Tests: python3 test_cleanup_codex_companion.py, beside this file.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import time


TERMINAL = {'completed', 'failed', 'cancelled', 'canceled'}


class UnsafeToClean(Exception):
    pass


def workspace_root(path):
    # The companion's state key: realpath of the Git top level. A removed checkout (a merged
    # worktree) resolves non-strictly to the same path, and `git -C` on it fails, so it stays put.
    path = Path(path).expanduser().resolve()
    result = subprocess.run(['git', '-C', str(path), 'rev-parse', '--show-toplevel'],
                            capture_output=True, text=True, timeout=5)
    return Path(result.stdout.strip()).resolve() if result.returncode == 0 else path


def process_info(pid):
    directory = Path('/proc') / str(pid)
    try:
        stat = (directory / 'stat').read_text().rsplit(')', 1)[1].split()
        return {'pid':pid, 'ppid':int(stat[1]), 'start':stat[19], 'state':stat[0],
                'uid':directory.stat().st_uid,
                'name':(directory/'comm').read_text().strip(),
                'cmd':(directory/'cmdline').read_bytes().decode(errors='replace').split('\0')}
    except (FileNotFoundError, ProcessLookupError):
        return None


def alive(identity):
    current = process_info(identity['pid'])
    return current and current['start'] == identity['start'] and current['state'] != 'Z'


def client_count(endpoint):
    result = subprocess.run(['ss', '-xapH'], check=True, capture_output=True, text=True, timeout=5)
    return sum('ESTAB' in line and endpoint in line.split() for line in result.stdout.splitlines())


def saved_thread_ids(value):
    ids = set()
    if isinstance(value, dict):
        for key, item in value.items():
            if 'thread' in key.lower() and isinstance(item, str):
                ids.add(item)
            if isinstance(item, (dict, list)):
                ids.update(saved_thread_ids(item))
    elif isinstance(value, list):
        for item in value:
            ids.update(saved_thread_ids(item))
    return ids


def check_saved_jobs(directory, workspace):
    state = json.loads((directory/'state.json').read_text())
    jobs = state.get('jobs', [])
    if not isinstance(jobs, list) or not jobs:
        raise UnsafeToClean('no saved job records')
    ids = set()
    for job in jobs:
        if job.get('status') not in TERMINAL or job.get('pid'):
            raise UnsafeToClean('a recorded job is still running or pending')
        if Path(job.get('workspaceRoot', '')).resolve() != workspace:
            raise UnsafeToClean('job workspace does not match the requested checkout')
        job_id = job['id']
        if Path(job_id).name != job_id:
            raise UnsafeToClean('invalid job record filename')
        receipt = json.loads((directory/'jobs'/f'{job_id}.json').read_text())
        if receipt.get('status') not in TERMINAL or receipt.get('pid'):
            raise UnsafeToClean('a job receipt is still running or pending')
        if not any(receipt.get(key) is not None for key in ('result', 'rendered', 'errorMessage')):
            raise UnsafeToClean('a job has no saved result or failure')
        ids.update(saved_thread_ids(job))
        ids.update(saved_thread_ids(receipt))
    return ids


class RPC:
    def __init__(self, endpoint):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        try:
            self.sock.connect(endpoint)
        except BaseException:
            self.sock.close()
            raise
        self.reader = self.sock.makefile('r')
        self.sequence = 0

    def call(self, method, params=None):
        self.sequence += 1
        self.sock.sendall((json.dumps({'id':self.sequence, 'method':method, 'params':params or {}})+'\n').encode())
        while True:
            line = self.reader.readline()
            if not line:
                raise UnsafeToClean('broker disconnected during verification')
            response = json.loads(line)
            if response.get('id') == self.sequence:
                if 'error' in response:
                    raise UnsafeToClean('broker rejected inspection: '+str(response['error'].get('message')))
                return response['result']

    def close(self):
        self.reader.close()
        self.sock.close()


def spawning_thread(thread):
    # A sub-agent's thread names the thread that spawned it:
    # source {"subAgent": {"thread_spawn": {"parent_thread_id": …}}}. Any other shape names none.
    source = thread.get('source')
    agent = source.get('subAgent') if isinstance(source, dict) else None
    spawn = agent.get('thread_spawn') if isinstance(agent, dict) else None
    parent = spawn.get('parent_thread_id') if isinstance(spawn, dict) else None
    return parent if isinstance(parent, str) else None


def check_loaded_threads(threads, ids):
    # threads: each loaded thread's thread/read record by thread ID; ids: the saved jobs' thread IDs.
    parents = {}
    for thread_id, thread in threads.items():
        status = thread.get('status')
        if not isinstance(status, dict) or status.get('type') not in ('idle', 'systemError'):
            raise UnsafeToClean('a loaded thread is active')
        parents[thread_id] = spawning_thread(thread)
    for thread_id in threads:
        # A sub-agent's thread belongs to the saved job whose thread spawned it, at any depth.
        current, steps = thread_id, 0
        while current not in ids and parents.get(current) and steps <= len(threads):
            current, steps = parents[current], steps + 1
        if current not in ids:
            raise UnsafeToClean('a loaded thread has no matching saved job result')


def descendants(broker):
    rows = {}
    for directory in Path('/proc').iterdir():
        if not directory.name.isdigit():
            continue
        try:
            if directory.stat().st_uid != os.getuid():
                continue
        except (FileNotFoundError, ProcessLookupError):
            continue
        row = process_info(int(directory.name))
        if row:
            rows[row['pid']] = row
    result = []
    for row in rows.values():
        parent = row['pid']
        seen = set()
        while parent in rows and parent not in seen:
            if parent == broker['pid']:
                result.append(row)
                break
            seen.add(parent)
            parent = rows[parent]['ppid']
    return result


def wrapped_app_server(cmd):
    # `codex -c <value> … app-server`: the app server the skill's no-MCP wrapper starts. A cmdline
    # read from /proc ends with a NUL, so its list ends with one empty item.
    args = cmd[1:-1] if cmd[-1:] == [''] else cmd[1:]
    while len(args) >= 2 and args[0] == '-c':
        args = args[2:]
    return args == ['app-server']


def infrastructure(row, broker):
    cmd, name = row['cmd'], row['name']
    if row['pid'] == broker['pid'] or row['state'] == 'Z':
        return True
    if name == 'codex' and (cmd[1:2] in (['app-server'], ['sandbox']) or wrapped_app_server(cmd)):
        return True
    if name in ('codex-code-mode', 'node_repl', 'bwrap', 'codex-linux-san'):
        return True
    if name in ('npm exec mongod', 'npm exec @hypot'):
        return True
    if name in ('node-MainThread', 'MainThread'):
        return any('mongodb-mcp-server' in arg or 'mcp-server-tauri' in arg or
                   Path(arg).name in ('cua-repl.mjs', 'kernel.js', 'trusted-worker.js') for arg in cmd)
    return False


def clean(directory, workspace, execute):
    record = json.loads((directory/'broker.json').read_text())
    endpoint = record.get('endpoint', '')
    if not endpoint.startswith('unix:'):
        raise UnsafeToClean('unsupported broker endpoint')
    endpoint = endpoint.removeprefix('unix:')
    if not Path(endpoint).exists():
        return {'status':'not-running'}
    broker = process_info(int(record['pid']))
    if not broker or broker['uid'] != os.getuid():
        raise UnsafeToClean('broker identity is not visible or belongs to another user; run on the host')
    cmd = broker['cmd']
    if not any(Path(arg).name == 'app-server-broker.mjs' for arg in cmd) or 'serve' not in cmd:
        raise UnsafeToClean('PID is not a Companion broker')
    if '--endpoint' not in cmd or cmd[cmd.index('--endpoint')+1] != record['endpoint']:
        raise UnsafeToClean('broker endpoint changed')
    if '--cwd' not in cmd or workspace_root(cmd[cmd.index('--cwd')+1]) != workspace:
        raise UnsafeToClean('broker belongs to another workspace')
    if client_count(endpoint):
        raise UnsafeToClean('a downstream task client is connected')
    ids = check_saved_jobs(directory, workspace)
    rpc = RPC(endpoint)
    try:
        loaded, cursor = [], None
        while True:
            page = rpc.call('thread/loaded/list', {'cursor':cursor} if cursor else {})
            loaded.extend(page.get('data', []))
            cursor = page.get('nextCursor')
            if not cursor:
                break
        check_loaded_threads({thread_id: rpc.call('thread/read', {'threadId':thread_id, 'includeTurns':False})['thread']
                              for thread_id in loaded}, ids)
        tree = descendants(broker)
        unknown = sorted({row['name'] for row in tree if not infrastructure(row, broker)})
        if unknown:
            raise UnsafeToClean('other worker processes need review: '+', '.join(unknown))
        check_saved_jobs(directory, workspace)
        if client_count(endpoint) != 1 or not alive(broker):
            raise UnsafeToClean('a client connected or the broker changed during verification')
        if not execute:
            return {'status':'eligible', 'threads':len(loaded), 'processes':len(tree)}
        rpc.call('broker/shutdown')
    finally:
        rpc.close()
    deadline = time.monotonic()+10
    remaining = tree
    while time.monotonic() < deadline:
        remaining = [row for row in tree if alive(row)]
        if not remaining:
            return {'status':'stopped', 'threads':len(loaded), 'processes':len(tree)}
        time.sleep(0.1)
    return {'status':'incomplete', 'surviving_pids':[row['pid'] for row in remaining]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', required=True, help='Worker checkout to clean; never scans other workspaces')
    parser.add_argument('--execute', action='store_true', help='Shut down an eligible broker; default is dry-run')
    parser.add_argument('--state-root', action='append', type=Path, help='Override Companion state roots')
    args = parser.parse_args()
    workspace = workspace_root(args.workspace)
    roots = args.state_root or [Path.home()/'.claude/plugins/data/codex-openai-codex/state', Path('/tmp/codex-companion')]
    if not args.state_root and os.environ.get('CLAUDE_PLUGIN_DATA'):
        roots.insert(0, Path(os.environ['CLAUDE_PLUGIN_DATA'])/'state')
    digest = hashlib.sha256(str(workspace).encode()).hexdigest()[:16]
    records = {directory.resolve() for root in roots for directory in root.glob('*-'+digest)
               if (directory/'broker.json').is_file()}
    if not records:
        print(json.dumps({'status':'not-running', 'workspace':str(workspace)}))
        return 0
    exit_code = 0
    seen = set()
    for directory in sorted(records):
        try:
            record = json.loads((directory/'broker.json').read_text())
            key = (record.get('pid'), record.get('endpoint'))
            if key in seen:
                continue
            seen.add(key)
            result = clean(directory, workspace, args.execute)
            if result['status'] == 'incomplete':
                exit_code = 2
        except (UnsafeToClean, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            result = {'status':'skipped', 'reason':str(error)}
            exit_code = 2
        print(json.dumps({'workspace':str(workspace), **result}))
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
