#!/usr/bin/env python3
"""Border lag in recorded Tart window-motion videos (old 30 Hz vs event border).

Reads the exact middle scanline of an existing recording only: no capture, VM,
stdin, shell or installs. Thresholds fit this workload, not the product.
"""

import collections
import json
import math
import stat
import statistics
import subprocess
import tempfile
from pathlib import Path

FFPROBE, FFMPEG = '/opt/homebrew/bin/ffprobe', '/opt/homebrew/bin/ffmpeg'
TIMEOUT, MAX_FRAMES, SIZE = 120, 12000, (1440, 1040)
MIN_GREEN, MIN_ACCENT, MAX_ACCENT_GAP, MIN_STEP = 200, 2, 64, 2
MIN_MOVING, MIN_FPS, MIN_EXCURSION = 300, 40.0, 400
SIDES = ('left', 'right')
LIMITATIONS = [
    'one horizontal middle scanline: no corner, top/bottom or full-screen evidence',
    'lag is in capture pixels: no Retina/point proof and no source window geometry',
    'thresholds fit this recorded workload: not a universal border-quality verdict',
]


class AnalysisError(Exception):
    pass


def _green(r, g, b):
    return g >= 120 and g >= r * 1.5 and g >= b * 1.4


def _purple(r, g, b):
    # H.264 4:2:0 blends the thin stroke with the dark native frame: observed
    # static pixels include (134,108,162) and (24,0,52), not the source hex.
    # Keep purple chroma constraints; validate against the unbordered movie too.
    return r >= 20 and b >= 50 and r >= g + 15 and b >= r + 15 and b >= g + 35


def _runs(row, predicate, min_length):
    runs, start, width = [], None, len(row) // 3
    for x in range(width + 1):
        hit = x < width and predicate(row[3 * x], row[3 * x + 1], row[3 * x + 2])
        if hit and start is None:
            start = x
        elif not hit and start is not None:
            if x - start >= min_length:
                runs.append((start, x - 1))
            start = None
    return runs


def detect_row(row, min_green=MIN_GREEN):
    if len(row) % 3:
        raise AnalysisError('RGB row length is not a multiple of 3')
    out = dict(valid=False, reason=None, left=None, right=None, left_gap=None, right_gap=None)
    greens = _runs(row, _green, min_green)
    widest = max((b - a for a, b in greens), default=None)
    best = [run for run in greens if run[1] - run[0] == widest]
    if len(best) != 1:
        out['reason'] = 'green_tie' if best else 'no_green'
        return out
    left, right = best[0]
    accents = _runs(row, _purple, MIN_ACCENT)
    before = [b for a, b in accents if b < left and left - b - 1 <= MAX_ACCENT_GAP]
    after = [a for a, b in accents if a > right and a - right - 1 <= MAX_ACCENT_GAP]
    out.update(valid=True, left=left, right=right,
               left_gap=left - max(before) - 1 if before else None,
               right_gap=min(after) - right - 1 if after else None)
    return out


def _p95(values):
    ordered = sorted(values)
    return ordered[(95 * len(ordered) + 99) // 100 - 1]


def _edges(rows, valid, moving):
    first, last = (moving[0], moving[-1]) if moving else (len(rows), len(rows))
    static = [i for i in valid if i < first or i > last]
    out, failures, base = {'static_frames': len(static)}, [], {}
    for side in SIDES:
        gaps = [rows[i][side + '_gap'] for i in static if rows[i][side + '_gap'] is not None]
        base[side] = statistics.median(gaps) if gaps else None
        out[side + '_baseline_gap'], out[side + '_static_samples'] = base[side], len(gaps)
        if base[side] is None:
            failures.append(f'no static {side} baseline')
    lags, missing = [], collections.Counter()
    for row in (rows[i] for i in moving):
        for side in SIDES:
            gap = row[side + '_gap']
            row[side + '_lag'] = None if gap is None or base[side] is None else gap - base[side]
            missing[side] += row[side + '_lag'] is None
        present = [abs(row[s + '_lag']) for s in SIDES if row[s + '_lag'] is not None]
        if present:
            row['lag'] = max(present)
            lags.append(row['lag'])
        else:
            missing['both'] += 1
    n = len(moving)
    out.update(lag_samples=len(lags), lag_median=statistics.median(lags) if lags else None,
               lag_p95=_p95(lags) if lags else None, lag_worst=max(lags) if lags else None,
               missing_left=missing['left'], missing_right=missing['right'],
               missing_both=missing['both'],
               missing_left_fraction=missing['left'] / n if n else None,
               missing_right_fraction=missing['right'] / n if n else None)
    if not n:
        failures.append('no moving frames')
    if missing['both']:
        failures.append(f"{missing['both']} moving frames lack both edges")
    return dict(out, evidence_passed=not failures, failures=failures)


def summarize(rows, bordered=True):
    rows = [dict(row, moving=False, left_lag=None, right_lag=None, lag=None) for row in rows]
    times = [row['timestamp'] for row in rows]
    if not all(isinstance(t, (int, float)) and math.isfinite(t) for t in times):
        raise AnalysisError('non-finite frame timestamp')
    if any(b <= a for a, b in zip(times, times[1:])):
        raise AnalysisError('frame timestamps are not strictly increasing')
    valid = [i for i, row in enumerate(rows) if row['valid']]
    moving = [i for i in valid if i and rows[i - 1]['valid']
              and abs(rows[i]['left'] - rows[i - 1]['left']) >= MIN_STEP]
    for i in moving:
        rows[i]['moving'] = True
    fps = excursion = None
    if valid:
        lefts = [rows[i]['left'] for i in valid]
        excursion = max(lefts) - min(lefts)
    if moving and times[moving[-1]] > times[moving[0]]:
        span = [i for i in valid if moving[0] <= i <= moving[-1]]
        fps = (len(span) - 1) / (times[moving[-1]] - times[moving[0]])
    failures = []
    if len(moving) < MIN_MOVING:
        failures.append(f'{len(moving)} moving frames < {MIN_MOVING}')
    if fps is None or fps < MIN_FPS:
        failures.append(f'active fps {fps} < {MIN_FPS}')
    if excursion is None or excursion < MIN_EXCURSION:
        failures.append(f'horizontal excursion {excursion} < {MIN_EXCURSION}')
    reasons = collections.Counter(row['reason'] for row in rows if not row['valid'])
    return dict(frames=len(rows), valid_green_frames=len(valid), invalid_reasons=dict(reasons),
                moving_frames=len(moving), active_fps=fps, horizontal_excursion=excursion,
                sampling_passed=not failures, sampling_failures=failures,
                edges=_edges(rows, valid, moving) if bordered else None, rows=rows)


def _run(command):
    try:
        done = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                              timeout=TIMEOUT, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AnalysisError(f'{command[0]}: {error}') from None
    if done.returncode:
        detail = done.stderr.decode(errors='replace').strip()[-4000:]
        raise AnalysisError(f'{command[0]} exited {done.returncode}: {detail}')
    return done.stdout


def analyze(movie: Path, output: Path, bordered: bool = True) -> dict:
    movie, output = Path(movie), Path(output)
    if not stat.S_ISREG(movie.stat().st_mode):
        raise AnalysisError(f'{movie} is not a regular file')
    if output.is_symlink() or output.exists():
        raise AnalysisError(f'{output} already exists')
    probe = json.loads(_run([FFPROBE, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                             'stream=width,height:frame=best_effort_timestamp_time',
                             '-of', 'json', str(movie)]))
    try:
        width, height = probe['streams'][0]['width'], probe['streams'][0]['height']
        times = [float(frame['best_effort_timestamp_time']) for frame in probe['frames']]
    except (KeyError, IndexError, TypeError, ValueError) as error:
        raise AnalysisError(f'incomplete ffprobe output: {error!r}') from None
    if (width, height) != SIZE:
        raise AnalysisError(f'expected {SIZE[0]}x{SIZE[1]} recording, got {width}x{height}')
    if not 0 < len(times) <= MAX_FRAMES:
        raise AnalysisError(f'{len(times)} frames outside 1..{MAX_FRAMES}')
    stride = width * 3
    with tempfile.TemporaryDirectory(prefix='.border-motion-', dir=output.parent) as scratch:
        raw = Path(scratch) / 'middle-row.rgb'
        _run([FFMPEG, '-nostdin', '-v', 'error', '-n', '-i', str(movie), '-map', '0:v:0',
              '-fps_mode', 'passthrough', '-vf', 'format=rgb24,crop=iw:1:0:ih/2',
              '-frames:v', str(MAX_FRAMES + 1), '-f', 'rawvideo', '-pix_fmt', 'rgb24', str(raw)])
        size = raw.stat().st_size
        if size != stride * len(times):
            raise AnalysisError(f'decoded {size / stride:g} rows, ffprobe reported {len(times)}')
        with raw.open('rb') as handle:
            rows = [dict(timestamp=t, **detect_row(handle.read(stride))) for t in times]
    result = dict(movie=str(movie), width=width, height=height, scanline_y=height // 2,
                  bordered=bordered, limitations=LIMITATIONS, **summarize(rows, bordered))
    with output.open('x', encoding='utf-8') as handle:
        json.dump(result, handle, indent=1, allow_nan=False)
        handle.write('\n')
    return result
