#!/usr/bin/env python3
"""Offline tests for cleanup-codex-companion.py's loaded-thread check: python3 test_cleanup_codex_companion.py"""

import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True  # loading the helper by path would otherwise leave a __pycache__ here
spec = importlib.util.spec_from_file_location('cleanup', Path(__file__).with_name('cleanup-codex-companion.py'))
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)

IDLE = {'status': {'type': 'idle'}, 'source': 'vscode'}


def sub(parent, status='idle'):
    return {'status': {'type': status},
            'source': {'subAgent': {'thread_spawn': {'parent_thread_id': parent, 'depth': 1}}}}


class LoadedThreads(unittest.TestCase):
    def test_covered(self):
        cases = {
            'job alone': {'J': IDLE},
            'job and its sub-agent': {'J': IDLE, 'A': sub('J')},
            'sub-agent of a sub-agent': {'J': IDLE, 'A': sub('J'), 'B': sub('A')},
            'job ended in a system error': {'J': {'status': {'type': 'systemError'}}, 'A': sub('J')},
        }
        for name, threads in cases.items():
            with self.subTest(name):
                cleanup.check_loaded_threads(threads, {'J'})

    def test_refused(self):
        uncovered = 'a loaded thread has no matching saved job result'
        cases = {
            'sub-agent of an unknown thread': ({'J': IDLE, 'A': sub('X')}, uncovered),
            'cycle': ({'J': IDLE, 'A': sub('B'), 'B': sub('A')}, uncovered),
            'unrelated idle thread': ({'J': IDLE, 'U': IDLE}, uncovered),
            'sub-agent source of another shape': ({'J': IDLE, 'R': {'status': {'type': 'idle'}, 'source': {'subAgent': 'review'}}}, uncovered),
            'sub-agent still working': ({'J': IDLE, 'A': sub('J', 'active')}, 'a loaded thread is active'),
        }
        for name, (threads, reason) in cases.items():
            with self.subTest(name):
                with self.assertRaises(cleanup.UnsafeToClean) as raised:
                    cleanup.check_loaded_threads(threads, {'J'})
                self.assertEqual(str(raised.exception), reason)


if __name__ == '__main__':
    unittest.main()
