"""Pure synthetic-row tests for border_motion_pixels; no media, tools or files."""

import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import border_motion_pixels as bmp  # noqa: E402

GREEN, PURPLE, BLACK = (0, 200, 0), (0xCB, 0xA6, 0xF7), (0, 0, 0)


def scanline(width, left, right, left_gap=None, right_gap=None, accent=3):
    pixels = [BLACK] * width
    pixels[left:right + 1] = [GREEN] * (right + 1 - left)
    if left_gap is not None:
        pixels[left - left_gap - accent:left - left_gap] = [PURPLE] * accent
    if right_gap is not None:
        start = right + 1 + right_gap
        pixels[start:start + accent] = [PURPLE] * accent
    return bytes(c for pixel in pixels for c in pixel)


def row(t, left, left_gap=4, right_gap=6):
    return dict(timestamp=t, valid=True, reason=None, left=left, right=left + 239,
                left_gap=left_gap, right_gap=right_gap)


def motion(gaps, fps=60.0, step=5):
    lefts = [100] * 3 + [100 + step * (i + 1) for i in range(len(gaps))]
    lefts += lefts[-1:] * 3
    gaps = [(4, 6)] * 3 + list(gaps) + [(4, 6)] * 3
    return [row(i / fps, x, *g) for i, (x, g) in enumerate(zip(lefts, gaps))]


class DetectRowTests(unittest.TestCase):
    def test_recorded_compressed_stroke_and_background_colors(self):
        for rgb in ((134, 108, 162), (24, 0, 52), (137, 114, 169), (84, 60, 116)):
            self.assertTrue(bmp._purple(*rgb), rgb)
        for rgb in ((101, 126, 148), (119, 116, 122), (26, 191, 78), (65, 84, 105)):
            self.assertFalse(bmp._purple(*rgb), rgb)

    def test_exact_edges_and_gaps(self):
        self.assertEqual(bmp.detect_row(scanline(400, 100, 339, 4, 6)),
                         dict(valid=True, reason=None, left=100, right=339, left_gap=4, right_gap=6))

    def test_far_accent_missing_and_ties_rejected(self):
        found = bmp.detect_row(scanline(500, 100, 339, None, 70))
        self.assertEqual((found['valid'], found['left_gap'], found['right_gap']), (True, None, None))
        self.assertEqual(bmp.detect_row(scanline(300, 10, 249) * 2)['reason'], 'green_tie')
        self.assertEqual(bmp.detect_row(bytes(900))['reason'], 'no_green')


class SummarizeTests(unittest.TestCase):
    def test_static_calibration_and_nearest_rank_p95(self):
        result = bmp.summarize(motion([(4 + k, 6) for k in range(20)]))
        edges = result['edges']
        self.assertEqual((edges['left_baseline_gap'], edges['right_baseline_gap']), (4, 6))
        self.assertEqual(edges['static_frames'], 6)
        self.assertEqual((edges['lag_median'], edges['lag_p95'], edges['lag_worst']), (9.5, 18, 19))
        self.assertTrue(edges['evidence_passed'])
        self.assertEqual(result['moving_frames'], 20)
        self.assertAlmostEqual(result['active_fps'], 60.0)
        self.assertFalse(result['sampling_passed'])

    def test_missing_edges_are_counted_not_zeroed(self):
        result = bmp.summarize(motion([(9, None), (None, None), (None, 8)]))
        edges = result['edges']
        self.assertEqual((edges['missing_left'], edges['missing_right'], edges['missing_both']), (2, 2, 1))
        self.assertEqual([r['lag'] for r in result['rows'] if r['moving']], [5, None, 2])
        self.assertEqual(edges['lag_samples'], 2)
        self.assertFalse(edges['evidence_passed'])

    def test_sampling_qualifies_and_sparse_fails(self):
        dense = bmp.summarize(motion([(5, 6)] * 310, step=2))
        self.assertTrue(dense['sampling_passed'], dense['sampling_failures'])
        sparse = bmp.summarize(motion([(5, 6)] * 310, fps=30.0, step=2))
        self.assertEqual(len(sparse['sampling_failures']), 1)
        self.assertIn('fps', sparse['sampling_failures'][0])

    def test_unbordered_reports_motion_without_edge_gate(self):
        result = bmp.summarize(motion([(None, None)] * 5), bordered=False)
        self.assertIsNone(result['edges'])
        self.assertEqual((result['moving_frames'], result['horizontal_excursion']), (5, 25))

    def test_rejects_bad_timestamps(self):
        for times in ([0.0, 0.0], [0.0, math.nan]):
            with self.assertRaises(bmp.AnalysisError):
                bmp.summarize([row(t, 100) for t in times])


if __name__ == '__main__':
    unittest.main()
