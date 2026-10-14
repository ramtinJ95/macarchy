"""Host-side unit tests for the border workload controller; no subprocesses, fixtures or special files."""
import re
import tomllib
import unittest
from pathlib import Path
from unittest import mock

import border_workload as w
import verify
import verify_borders as b

WS = '202 WindowServer 1.5G- 1.0'
FRAME = {'x': 0, 'y': 25, 'width': 640, 'height': 480}


def top(blocks=8):
    lines = []
    for i in range(blocks):
        lines += [f'2026/10/14 08:00:0{i}', 'PID COMMAND MEM CPU',
                  f'101 borders 12M+ {99.0 if i == 0 else 2.0}', WS]
    return '\n'.join(lines) + '\n'


def status(frame=FRAME, key=False, active=False, minimized=False, fullscreen=False, check=None):
    return {'appActive': active, 'fullscreenCheck': check,
            'windows': [{'index': 0, 'frameCG': frame, 'key': key, 'minimized': minimized,
                         'closed': False, 'fullscreen': fullscreen}]}


class ParseTopTests(unittest.TestCase):
    def test_parses_eight_samples_and_summarizes(self):
        rows, stamps = w.parse_top(top(), [101, 202])
        self.assertEqual(stamps, [f'2026/10/14 08:00:0{i}' for i in range(8)])
        self.assertEqual(rows[101][0], {'sample': 0, 'command': 'borders', 'bytes': 12 << 20, 'cpu': 99.0})
        self.assertEqual(rows[202][7], {'sample': 7, 'command': 'WindowServer', 'bytes': 3 << 29, 'cpu': 1.0})
        s = w.summarize(rows[101])
        self.assertEqual(s['command'], 'borders')
        self.assertEqual(s['footprint_bytes'], {'min': 12 << 20, 'median': 12 << 20, 'max': 12 << 20})
        self.assertEqual(s['cpu_percent_excl_first'], {'min': 2.0, 'median': 2.0, 'max': 2.0})
        self.assertEqual(s['samples'], rows[101])

    def test_rejects_invalid_samples(self):
        valid = top()
        cases = {
            'seven samples': top(7),
            'inexact timestamp': valid.replace('2026/10/14 08:00:03', '2026-10-14 08:00:03'),
            'missing pid sample': valid.replace(WS, '', 1),
            'unknown unit': valid.replace('1.5G-', '1.5Q-', 1),
            'NaN cpu': valid.replace(WS, '202 WindowServer 1.5G- nan', 1),
            'non-numeric cpu': valid.replace(WS, '202 WindowServer 1.5G- busy', 1),
        }
        for name, text in cases.items():
            with self.subTest(name), self.assertRaises(verify.Failed):
                w.parse_top(text, [101, 202])


class WorkloadTests(unittest.TestCase):
    def test_satisfied_compares_prior_and_after_status(self):
        before = status()
        cases = [
            ('focus', status(key=True, active=True), True),
            ('focus', status(key=True), False),
            ('move', status(frame={**FRAME, 'x': 40}), True),
            ('move', status(), False),
            ('minimize', status(minimized=True), True),
            ('minimize', status(), False),
            ('fullscreen', status(fullscreen=True, check={'sequence': 3, 'expected': True, 'actual': True}), True),
            ('fullscreen', status(fullscreen=True, check={'sequence': 2, 'expected': True, 'actual': True}), False),
            ('fullscreen', status(check={'sequence': 3, 'expected': True, 'actual': False}), False),
        ]
        for action, after, want in cases:
            with self.subTest(action=action, want=want):
                self.assertIs(w.satisfied(action, 0, 3, before, after), want)

    def test_owned_tart_poll_tracks_ownership(self):
        t = w.OwnedTart({'pid': 42})
        self.assertEqual(t.pid, 42)
        for owned, want in ((True, None), (False, 1)):
            with self.subTest(owned=owned), mock.patch.object(verify, 'owned_tart', return_value=owned) as m:
                self.assertEqual(t.poll(), want)
                m.assert_called_once_with(t.record)

    def test_session_exit_preserves_primary_exception(self):
        def session():
            return w.Session(mock.sentinel.client, 'evidence', mock.sentinel.report, {}, 'run')

        cleanup = RuntimeError('cleanup failed')
        with mock.patch.object(w.Session, 'close', side_effect=cleanup) as close:
            with self.subTest('direct, no primary'):
                with self.assertRaises(RuntimeError) as cm:
                    session().__exit__(None, None, None)
                self.assertIs(cm.exception, cleanup)
            with self.subTest('direct, primary'):
                self.assertFalse(session().__exit__(ValueError, ValueError('primary'), None))
            with self.subTest('context, primary'):
                with self.assertRaises(ValueError) as cm:
                    with session():
                        raise ValueError('primary')
                self.assertEqual(str(cm.exception), 'primary')
            with self.subTest('context, no primary'):
                with self.assertRaises(RuntimeError) as cm:
                    with session():
                        pass
                self.assertIs(cm.exception, cleanup)
        self.assertEqual(close.call_count, 4)


class VerifyBordersTests(unittest.TestCase):
    def test_rect_accepts_flat_list_and_frame_dict(self):
        self.assertEqual(b._rect({'height': 4, 'width': 3, 'y': 2, 'x': 1}), [1, 2, 3, 4])
        self.assertEqual(b._rect([1, 2, 3, 4]), [1, 2, 3, 4])

    def test_profile_enables_only_zsh_shell(self):
        p = tomllib.loads(b.PROFILE)
        self.assertEqual(p['shell']['provider'], 'zsh')
        self.assertTrue(b.DISABLED)
        for name in b.DISABLED:
            with self.subTest(name):
                self.assertEqual(p[name]['provider'], 'disabled')
        self.assertTrue(p['tools'])
        self.assertTrue(all(x is False for x in p['tools'].values()), p['tools'])
        self.assertNotIn('presets', p)  # presets default to false in the product

    def test_window_control_records_one_window_without_prompting(self):
        src = Path(__file__).with_name('window-control.swift').read_text()
        self.assertEqual(len(re.findall(r'SCContentFilter\(\s*desktopIndependentWindow\s*:', src)), 1)
        self.assertNotIn('CGRequestScreenCaptureAccess', src)


if __name__ == '__main__':
    unittest.main()
