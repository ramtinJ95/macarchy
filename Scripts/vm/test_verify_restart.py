"""Pure unit tests for verify.py start/restart; no SSH, VM, host commands, or special files."""
import json
import os
import subprocess
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock

import lab
import verify

RUN = 'setup-0123456789ab'
TART = Path('/opt/unit/tart')
ARGV = [str(TART), 'run', RUN, '--no-clipboard', '--no-audio']
INPUTS = object()
EVIDENCE = ('verify-tart.json', 'verify-tart.log', 'ssh-shutdown.json')


def write_json(path, data):
    Path(path).write_text(json.dumps(data))


class RestartTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.outside = Path(temporary.name)
        self.dir = self.outside / 'clone'
        self.dir.mkdir()
        stack = ExitStack()
        self.addCleanup(stack.close)

        def patch(target, name, **kwargs):
            return stack.enter_context(mock.patch.object(target, name, **kwargs))
        patch(verify, 'test_clone', return_value=self.dir)
        self.require_stopped = patch(lab, 'require_stopped')
        patch(lab, 'binary', return_value=TART)
        patch(lab, 'lab_environment', return_value={'PATH': '/usr/bin'})
        patch(lab, 'write_json', side_effect=write_json)
        self.stop = patch(lab, 'stop_owned_process', return_value='terminated')
        patch(lab, 'audit_no_listener')
        self.vm_state = patch(verify, 'vm_state', return_value='running')
        self.owned = patch(verify, 'owned_tart', return_value=False)
        patch(verify, 'process_identity', return_value='/usr/bin/env ' + ' '.join(ARGV))
        self.process = mock.Mock(pid=4321, returncode=None)
        self.process.poll.return_value = None
        self.popen = patch(verify.subprocess, 'Popen', return_value=self.process)
        self.run = patch(verify.subprocess, 'run', side_effect=AssertionError('unexpected run'))
        patch(verify.time, 'sleep')

    def previous(self, changes=None, shutdown=True):
        record = {'tool': 'verify.py', 'run': RUN, 'pid': 999, 'argv': ARGV,
                  'identity': '/usr/bin/env ' + ' '.join(ARGV), 'log': 'verify-tart.log',
                  'status': 'running'}
        record.update(changes or {})
        (self.dir / 'verify-tart.json').write_text(json.dumps(record))
        (self.dir / 'verify-tart.log').write_bytes(b'old boot log\n')
        if shutdown:
            (self.dir / 'ssh-shutdown.json').write_bytes(json.dumps({'status': 'stopped'}).encode())

    def evidence(self):
        out = {}
        for name in EVIDENCE:
            path = self.dir / name
            out[name] = (('link', os.readlink(path)) if path.is_symlink()
                         else path.read_bytes() if path.exists() else None)
        out['history'] = sorted(p.name for p in self.dir.glob('boot-history-*'))
        out['logs'] = sorted(p.name for p in self.dir.glob('verify-tart-*.log'))
        return out

    def assertRefused(self):
        before = self.evidence()
        with self.assertRaises(verify.Blocked):
            verify.start(INPUTS, RUN, restart=True)
        self.assertEqual(self.evidence(), before)
        self.popen.assert_not_called()

    def test_restart_archives_exact_bytes_and_keeps_old_log(self):
        self.previous()
        before = self.evidence()
        record = verify.start(INPUTS, RUN, restart=True)
        history = self.dir / record['previous_boot']
        self.assertEqual(self.evidence()['history'], [history.name])
        for name in EVIDENCE:
            self.assertEqual((history / name).read_bytes(), before[name])
            self.assertFalse((history / name).is_symlink())
        manifest = json.loads((history / 'manifest.json').read_text())
        self.assertTrue(manifest['complete'])
        self.assertEqual(manifest['files'], sorted(EVIDENCE))
        self.assertFalse(os.path.lexists(self.dir / 'ssh-shutdown.json'))
        self.assertEqual((self.dir / 'verify-tart.log').read_bytes(), before['verify-tart.log'])
        self.assertRegex(record['log'], r'^verify-tart-[0-9a-f]{32}\.log$')
        self.assertTrue((self.dir / record['log']).is_file())
        saved = json.loads((self.dir / 'verify-tart.json').read_text())
        self.assertEqual((saved['status'], saved['pid'], saved['previous_boot']),
                         ('running', 4321, history.name))
        self.assertEqual(self.popen.call_args.args[0], ARGV)
        self.assertEqual(self.popen.call_args.kwargs['stdout'].name, str(self.dir / record['log']))
        self.stop.assert_not_called()

    def test_restart_then_shutdown_invokes_guest_shutdown_fresh(self):
        self.previous()
        verify.start(INPUTS, RUN, restart=True)
        states = iter(['running'])
        self.vm_state.side_effect = lambda *args, **kwargs: next(states, 'stopped')
        self.run.side_effect = None
        self.run.return_value = subprocess.CompletedProcess([], 0, '', '')
        verify.shutdown_vm(INPUTS, RUN, self.dir)
        calls = [' '.join(map(str, call.args[0] if call.args else call.kwargs['args']))
                 for call in self.run.call_args_list]
        self.assertTrue(any('guest.py' in c and 'shutdown' in c for c in calls), calls)

    def test_refuses_missing_record(self):
        self.assertRefused()

    def test_refuses_malformed_record(self):
        cases = [None, {'pid': 0}, {'pid': '999'}, {'identity': ' '},
                 {'identity': '/usr/bin/env tart run other'}, {'log': '../x.log'},
                 {'log': '.hidden.log'}, {'log': 'verify-tart.txt'}]
        for changes in cases:
            with self.subTest(changes=changes):
                self.previous(changes)
                if changes is None:
                    (self.dir / 'verify-tart.json').write_text('{not json')
                self.assertRefused()

    def test_refuses_foreign_owner(self):
        for changes in ({'tool': 'other'}, {'run': 'setup-other'}, {'argv': ARGV[:-1]}):
            with self.subTest(changes=changes):
                self.previous(changes)
                self.assertRefused()

    def test_refuses_live_previous_process(self):
        self.previous()
        self.owned.return_value = True
        self.assertRefused()

    def test_refuses_running_vm(self):
        self.previous()
        self.require_stopped.side_effect = verify.Blocked('VM is running')
        self.assertRefused()

    def test_refuses_symlinked_evidence(self):
        for name in EVIDENCE:
            with self.subTest(name=name):
                self.previous()
                target = self.outside / ('target-' + name)
                target.write_bytes((self.dir / name).read_bytes())
                (self.dir / name).unlink()
                (self.dir / name).symlink_to(target)
                self.assertRefused()
                (self.dir / name).unlink()

    def test_popen_failure_keeps_evidence_and_records_reason(self):
        self.previous()
        before = self.evidence()
        self.popen.side_effect = OSError('private detail')
        with self.assertRaises(OSError):
            verify.start(INPUTS, RUN, restart=True)
        after = self.evidence()
        for name in ('verify-tart.json', 'verify-tart.log'):
            self.assertEqual(after[name], before[name])
        [history] = after['history']
        self.assertEqual((self.dir / history / 'ssh-shutdown.json').read_bytes(),
                         before['ssh-shutdown.json'])
        failure = json.loads((self.dir / history / 'restart-failure.json').read_text())
        self.assertEqual(failure['reason'], 'OSError')
        self.assertEqual(after['logs'], [failure['log']])
        self.stop.assert_not_called()

    def test_default_start_refuses_second_boot(self):
        self.previous()
        before = self.evidence()
        with self.assertRaises(verify.Blocked):
            verify.start(INPUTS, RUN)
        self.assertEqual(self.evidence(), before)
        self.popen.assert_not_called()
        self.require_stopped.assert_not_called()

    def test_describe_omits_message(self):
        self.assertEqual(verify.describe(OSError('private detail')), 'OSError')

    def test_parser_accepts_restart(self):
        args = verify.build_parser().parse_args(['restart', '--run', RUN])
        self.assertEqual((args.operation, args.run), ('restart', RUN))


if __name__ == '__main__':
    unittest.main()
