"""Pure checks for opt-in borders motion verification; no guest, VM, recorder or files."""
import sys
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(next(p for p in (HERE, HERE.parent) if (p / 'verify.py').exists())))

import border_workload  # noqa: E402
import verify  # noqa: E402
import verify_borders  # noqa: E402

BASE = ['drive', '--run', 'setup-0123456789ab', '--session', 'verify-0123456789ab']
MOTION = {'sequence': 7, 'ticks': 840, 'moving_ticks': 720, 'elapsed_seconds': 14.1, 'requested_hz': 60}
FRAME = [0, 0, 10, 10]


def status(frame, motion=None):
    st = {'appActive': True, 'windows': [{'index': 0, 'frameCG': frame}]}
    if motion is not None:
        st['motionCheck'] = motion
    return st


def ok(motion, frame=FRAME):
    return border_workload.satisfied('motion', 0, 7, status(FRAME), status(frame, motion))


class BorderMotionTests(unittest.TestCase):
    def test_invalid_combinations_block_before_lab_initialize(self):
        other = next(j for j in sorted(verify.JOURNEYS) if j != 'borders')
        for extra in (['--journey', 'borders', '--border-motion'],
                      ['--journey', 'borders', '--border-count', '8', '--border-motion'],
                      ['--journey', 'borders', '--border-count', '24', '--border-motion'],
                      ['--journey', other, '--border-motion']):
            with self.subTest(extra=extra), \
                    mock.patch.object(verify.lab, 'initialize', side_effect=AssertionError):
                with self.assertRaises(verify.Blocked):
                    verify.main(BASE + extra)

    def test_valid_motion_reaches_drive_and_defaults_off(self):
        with mock.patch.object(verify.lab, 'initialize'), mock.patch.object(verify.lab, 'check_version'), \
                mock.patch.object(verify, 'drive', return_value={'status': 'failed'}) as drive:
            verify.main(BASE + ['--journey', 'borders', '--border-count', '1', '--border-motion'])
        self.assertIs(drive.call_args.args[-1], True)
        self.assertFalse(verify.build_parser().parse_args(BASE + ['--journey', 'borders']).border_motion)

    def test_motion_satisfied_is_strict(self):
        self.assertIn('motion', border_workload.ACTIONS)
        self.assertTrue(ok(MOTION))
        self.assertTrue(ok({**MOTION, 'elapsed_seconds': 17.5}))
        for change in ({'sequence': 6}, {'ticks': 839}, {'moving_ticks': 719}, {'requested_hz': 30},
                       {'elapsed_seconds': 13.4}, {'elapsed_seconds': 17.6}, {'elapsed_seconds': None}):
            with self.subTest(change=change):
                self.assertFalse(ok({**MOTION, **change}))
        self.assertFalse(ok(None))
        self.assertFalse(ok(MOTION, [1, 0, 10, 10]))

    def test_update_driver_requires_event_backed_refreshes(self):
        f, ev = verify_borders._update_driver, {'update_driver': 'window-server-events'}
        self.assertEqual(f({}, False), ({'update_driver': 'legacy-polling'}, True))
        self.assertTrue(f({**ev, 'geometry_refresh_count': 60, 'event_count': 60}, False)[1])
        self.assertTrue(f({**ev, 'geometry_refresh_count': 300, 'event_count': 400}, True)[1])
        for rep, motion in (({**ev, 'geometry_refresh_count': 59, 'event_count': 99}, False),
                            ({**ev, 'geometry_refresh_count': 299, 'event_count': 999}, True),
                            ({**ev, 'geometry_refresh_count': 80, 'event_count': 79}, False),
                            ({**ev, 'event_count': 99}, False),
                            ({'update_driver': 'watchdog', 'geometry_refresh_count': 900, 'event_count': 900}, False)):
            with self.subTest(rep=rep):
                self.assertFalse(f(rep, motion)[1])


if __name__ == '__main__':
    unittest.main()
