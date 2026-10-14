"""Host-side controller for the guest border workload; fixtures and renderers run only in the guest."""
import base64
import contextlib
import json
import math
import re
import shlex
import statistics
import subprocess
import time
from pathlib import Path

import lab
import verify_borders as b

v = b._v()
q = shlex.quote
BREW = '/opt/homebrew/bin/borders'
ACTIONS = {'focus', 'move', 'resize', 'minimize', 'restore', 'close', 'fullscreen', 'animate', 'motion', 'settle', 'stop'}
UNIT = {'B': 1, 'K': 1 << 10, 'M': 1 << 20, 'G': 1 << 30, 'T': 1 << 40}
MEM = re.compile(r'(\d+(?:\.\d+)?)([BKMGT]?)[+-]?')
STAMP = re.compile(r'\d{4}/\d\d/\d\d \d\d:\d\d:\d\d')


def parse_top(text, pids):
    # MEM is top's documented physical memory footprint.
    rows, stamps, sample = {p: [] for p in pids}, [], -1
    for line in text.splitlines():
        f = line.split()
        if STAMP.fullmatch(line.strip()):
            stamps.append(line.strip())
        elif f[:1] == ['PID']:
            sample += 1
        elif len(f) >= 4 and f[0].isdigit() and int(f[0]) in rows:
            m = MEM.fullmatch(f[-2])
            try:
                cpu = float(f[-1])
            except ValueError:
                cpu = math.nan
            if not m or not math.isfinite(cpu):
                raise v.Failed(f'top: unparsable row {line!r}')
            rows[int(f[0])].append({'sample': sample, 'command': ' '.join(f[1:-2]),
                                    'bytes': int(float(m[1]) * UNIT[m[2] or 'B']), 'cpu': cpu})
    if len(stamps) != 8:
        raise v.Failed(f'top: {len(stamps)} sample timestamps, need 8')
    for p, r in rows.items():
        if [x['sample'] for x in r] != list(range(8)):
            raise v.Failed(f'top: pid {p} samples {[x["sample"] for x in r]}, need 8')
    return rows, stamps


def stats(xs):
    return {'min': min(xs), 'median': statistics.median(xs), 'max': max(xs)}


def summarize(rows):
    return {'command': rows[0]['command'], 'footprint_bytes': stats([r['bytes'] for r in rows]),
            'cpu_percent_excl_first': stats([r['cpu'] for r in rows[1:]]), 'samples': rows}


def window(status, index):
    return next(w for w in status['windows'] if w['index'] == index)


def satisfied(action, index, seq, before, st):
    if action in ('settle', 'stop'):
        return True  # caller verified the ack; reap verifies stop's clean exit
    w, prev = window(st, index), window(before, index)
    if action == 'focus':
        return w['key'] is True and st['appActive'] is True
    if action in ('move', 'resize', 'animate'):
        return w['frameCG'] != prev['frameCG']
    if action == 'motion':
        # Timer ticks are requested pacing, not proof of delivered frame rate.
        mc = st.get('motionCheck') or {}
        elapsed = mc.get('elapsed_seconds')
        return (mc.get('sequence') == seq and mc.get('ticks') == 840 and mc.get('moving_ticks') == 720
                and mc.get('requested_hz') == 60 and isinstance(elapsed, (int, float))
                and 13.5 <= elapsed <= 17.5 and w['frameCG'] == prev['frameCG'])
    if action == 'fullscreen':
        fc = st['fullscreenCheck']
        return (fc['sequence'] == seq and fc['expected'] == (not prev['fullscreen'])
                and fc['actual'] == fc['expected'] == w['fullscreen'])
    return {'minimize': w['minimized'] is True, 'restore': w['minimized'] is False,
            'close': w['closed'] is True}[action]


class OwnedTart:
    """Run-record Tart identity for lab helpers; poll() reports exit once ownership no longer matches."""

    def __init__(self, record):
        self.record, self.pid = record, int(record['pid'])

    def poll(self):
        return None if v.owned_tart(self.record) else 1


class Session:
    def __init__(self, client, evidence, report, context, run_id):
        self.c, self.ev, self.report, self.ctx, self.run_id = client, Path(evidence), report, context, run_id
        self.t0, self.timeline, self.procs, self.fixtures = time.monotonic(), [], [], {}
        self.linked = self.rec = self.controller = self.tart = self.inputs = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        # close() reports cleanup errors; never let them mask the primary exception.
        try:
            self.close()
        except Exception:
            if exc_type is None:
                raise
        return False

    def mark(self, event, **data):
        self.timeline.append({'t': round(time.monotonic() - self.t0, 3), 'event': event, **data})

    def save(self, name, data):
        with open(self.ev / f'{name}.json', 'x') as f:  # per-case evidence never clobbers
            f.write(json.dumps(data, indent=2, sort_keys=True, default=str) + '\n')

    def sh(self, name, command, timeout=30):
        return b.run(self.c, self.ev, self.report, name, command, timeout=timeout)

    def read(self, command):
        # Unlogged poll; transport loss blocks the lab run.
        try:
            r = subprocess.run(self.c.argv + [command], env=self.c.env, stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=10)
        except subprocess.TimeoutExpired:
            raise v.Blocked(f'poll timed out: {command}')
        if r.returncode:
            raise v.Blocked(f'poll failed ({r.returncode}): {command}: {r.stderr.strip()}')
        return r.stdout

    def spawn(self, name, command, until=0):
        out, err = (open(self.ev / f'{name}.{s}', 'xb') for s in ('stdout', 'stderr'))
        p = subprocess.Popen(self.c.argv + [command], env=self.c.env,
                             stdin=subprocess.DEVNULL, stdout=out, stderr=err)
        self.procs.append({'name': name, 'proc': p, 'files': (out, err), 'until': time.monotonic() + until})
        self.mark('spawn', name=name)
        return p

    def reap(self, p, name, timeout):
        try:
            code = p.wait(timeout)
        except subprocess.TimeoutExpired:
            raise v.Blocked(f'{name}: still running after {timeout:.0f}s; shut down the VM')
        self.mark('exit', name=name, code=code)
        if code:
            raise v.Failed(f'{name}: exit {code}')

    def theme(self, theme='catppuccin-mocha'):
        b.set_theme(self.c, self.ev, self.report, self.ctx, theme=theme)
        self.mark('theme', theme=theme)

    def fixture(self, count, label, directory):
        if count not in (1, 8, 24) or label in self.fixtures:
            raise ValueError((count, label))
        d = q(directory)
        fx = self.fixtures[label] = {'dir': directory, 'seq': 0}
        fx['proc'] = self.spawn(f'fixture-{label}', f'mkdir -p "$(dirname {d})" && mkdir -m 0700 {d} && exec '
                                f'{q(self.ctx["fixture"])} --directory {d} --count {count} '
                                f'--seconds 600 --label {q(label)}')
        deadline = time.monotonic() + 8
        while not (st := self.status(label) or {}).get('ready'):
            if st.get('error'):
                raise v.Failed(f'fixture {label}: {st["error"]}: {st.get("reason")}')
            if fx['proc'].poll() is not None or time.monotonic() > deadline:
                raise v.Failed(f'fixture {label}: not ready within 8s')
            time.sleep(0.25)
        fx['last'] = st
        self.save(f'fixture-{label}-ready', st)
        self.mark('ready', label=label, pid=st.get('pid'))
        if label == 'A' and not any(x['name'] == 'keep-awake' for x in self.procs):
            pid = st.get('pid')
            if type(pid) is not int or pid <= 1:
                raise v.Failed(f'fixture A: bad pid {pid!r} for keep-awake lease')
            # Lease ends when fixture A exits or after 120 s; close() reaps this owned handle.
            self.spawn('keep-awake', f'/usr/bin/caffeinate -di -w {pid} -t 120', until=130)
        return st

    def status(self, label):
        p = q(self.fixtures[label]['dir'] + '/status.json')
        # Only absence means pending; read errors surface through read().
        return json.loads(self.read(f'if test ! -e {p}; then printf null; else cat {p}; fi'))

    def act(self, label, action, index=None, timeout=8):
        if action not in ACTIONS:
            raise ValueError(action)
        fx = self.fixtures[label]
        before = self.status(label)  # fresh: another fixture's activity may have changed it
        if not before or before.get('error'):
            raise v.Failed(f'{label} {action}: no clean status before acting: {before}')
        fx['seq'] = seq = fx['seq'] + 1
        msg = {'sequence': seq, 'action': action}
        if action not in ('settle', 'stop'):
            msg['index'] = index
        blob, d = base64.b64encode(json.dumps(msg).encode()).decode(), q(fx['dir'])
        self.sh(f'{label}-command-{seq:03d}', '/bin/bash -o pipefail -c ' + q(
                f'printf %s {blob} | base64 -D > {d}/command.next && mv {d}/command.next {d}/command.json'))
        self.mark('action', label=label, sequence=seq, action=action, index=index)
        deadline = time.monotonic() + timeout
        while (st := self.status(label) or {}).get('actionSequence') != seq:
            if st.get('error'):
                raise v.Failed(f'{label} {action}#{seq}: {st["error"]}: {st.get("reason")}')
            if fx['proc'].poll() is not None or time.monotonic() > deadline:
                raise v.Failed(f'{label} {action}#{seq}: no ack within {timeout}s')
            time.sleep(0.25)
        self.mark('ack', label=label, sequence=seq)
        self.save(f'{label}-status-{seq:03d}-{action}', st)
        if st.get('error') or not satisfied(action, index, seq, before, st):
            raise v.Failed(f'{label} {action}#{seq}: status does not satisfy the action predicate')
        fx['last'] = st
        return st

    def stop(self, label):
        self.act(label, 'stop')
        self.reap(self.fixtures.pop(label)['proc'], f'fixture-{label}', 10)

    def preview(self, name, renderer, seconds, helper_path):
        if not 40 <= seconds <= 120:
            raise ValueError(seconds)
        pf, cli = q(f'{self.ctx["work"]}/{name}.pid'), self.ctx['binary']
        argv = shlex.join([cli, 'desktop', 'borders', 'preview', '--renderer', renderer, '--state-root',
                           self.ctx['state'], '--seconds', str(seconds), '--json'])
        # Same env as b.cli, exec'd directly so the recorded pid is the CLI itself.
        p = self.spawn(name, f'cd /Users/omarchy && set -C && echo $$ > {pf} && '
                             f'exec /usr/bin/env -i {shlex.join(v.STEP_ENV)} {argv}', until=seconds + 15)
        end, deadline = time.monotonic() + seconds, time.monotonic() + 8
        # pgrep exit 1 means no children yet; transient preflight children are ignored.
        poll = (f'test -s {pf} || exit 0; p=$(cat {pf}); c=$(pgrep -P "$p" .); r=$?; echo "$p"; '
                f'test $r -le 1 || exit $r; test $r = 1 && exit 0; '
                f'ps -ww -o pid=,ppid=,comm= -p "$(echo "$c" | paste -sd , -)"; test $? -le 1')
        while True:
            out = self.read(poll).splitlines()
            rows = [x.split(None, 2) for x in out[1:]]
            kids = [int(x[0]) for x in rows if len(x) == 3 and x[1] == out[0] and x[2].rstrip() == helper_path]
            if len(kids) > 1:
                raise v.Failed(f'{name}: expected one renderer child, got {kids}')
            if kids:
                break
            if p.poll() is not None or time.monotonic() > deadline:
                raise v.Failed(f'{name}: no {helper_path} child within 8s')
            time.sleep(0.25)
        cli_pid, helper = int(out[0]), kids[0]
        ps = self.sh(f'{name}-ps', f'ps -ww -o comm= -p {cli_pid} && '
                                   f'ps -ww -o pid=,ppid=,command= -p {cli_pid},{helper}')
        if ps.splitlines()[0].strip() != cli:
            raise v.Failed(f'{name}: CLI identity {ps.splitlines()[0]!r} != {cli!r}')
        self.mark('preview', name=name, renderer=renderer, cli=cli_pid, helper=helper)
        return {'name': name, 'proc': p, 'cli': cli_pid, 'helper': helper, 'end': end,
                'stdout': self.ev / f'{name}.stdout'}

    def finish_preview(self, pv):
        self.reap(pv['proc'], pv['name'], max(0, pv['end'] - time.monotonic()) + 15)
        if self.read(f'ps -o pid= -p {pv["helper"]}; test $? -le 1').strip():
            raise v.Blocked(f'{pv["name"]}: helper {pv["helper"]} outlived preview; shut down the VM')
        self.mark('preview-done', name=pv['name'])

    def link_incumbent(self):
        pinned = self.ctx['incumbent']['path']
        self.sh('incumbent-link', f'test ! -e {BREW} && test ! -L {BREW} && ln -s {q(pinned)} {BREW}')
        self.linked = pinned
        self.save('incumbent-link', {'link': BREW, 'target': pinned, 'commit': self.ctx['incumbent']['commit']})
        self.mark('incumbent-link')

    def unlink_incumbent(self):
        if any(x['proc'].poll() is None for x in self.procs):
            raise v.Blocked('owned guest children alive; incumbent link left in place')
        self.sh('incumbent-unlink', f'test -L {BREW} && test "$(readlink {BREW})" = {q(self.linked)} && /bin/rm -- {BREW}')
        self.linked = None
        self.mark('incumbent-unlink')

    def sample(self, name, helper=None):
        ws = self.sh(f'{name}-windowserver', 'pgrep -x WindowServer').split()
        if len(ws) != 1:
            raise v.Failed(f'{name}: expected one WindowServer, got {ws}')
        pids = [int(ws[0])] + ([helper] if helper else [])
        start = time.monotonic() - self.t0
        raw = self.sh(f'{name}-top', '/usr/bin/top -l 8 -s 1 -stats pid,command,mem,cpu '
                      + ' '.join(f'-pid {p}' for p in pids), timeout=30)
        end = time.monotonic() - self.t0
        with open(self.ev / f'{name}-top.log', 'x') as f:
            f.write(f'# host_t_start={start:.3f} host_t_end={end:.3f}\n{raw}')
        rows, stamps = parse_top(raw, pids)
        self.save(f'{name}-sample', {'host_t_start': round(start, 3), 'host_t_end': round(end, 3), 'top_timestamps': stamps,
                                     'pids': {str(p): summarize(rows[p]) for p in pids}})
        self.mark('sample', name=name, pids=pids)

    def host_setup(self):
        record = json.loads((lab.STATE / 'runs' / self.run_id / 'verify-tart.json').read_text())
        if not v.owned_tart(record):
            raise v.Blocked(f'Tart pid {record.get("pid")} does not match its run record')
        self.inputs, self.tart = v.read_pins(), OwnedTart(record)
        self.controller = lab.build_controller()
        pre = lab.control(self.controller, 'preflight')
        self.save('host-preflight', pre)
        if missing := [k for k in ('accessibility', 'screen_recording') if pre.get(k) is not True]:
            raise v.Blocked(f'host controller lacks permission: {missing}')

    def capture(self, name):
        self.save(f'{name}-capture', lab.capture(self.controller, self.tart, self.inputs, self.run_id, self.ev / f'{name}.png'))
        self.mark('capture', name=name)

    def record_start(self, name, seconds=20, fps=30):
        if fps not in (30, 60):
            raise ValueError(f'{name}: unsupported recording fps {fps!r}; expected 30 or 60')
        mp4 = (self.ev / f'{name}.mp4').resolve()
        if self.rec or mp4.exists():
            raise v.Failed(f'{name}: recording already active or {mp4} exists')
        out, err = open(self.ev / f'{name}-record.stdout', 'wb'), open(self.ev / f'{name}-record.log', 'wb')
        argv = [str(self.controller), 'record60' if fps == 60 else 'record', str(self.tart.pid), str(lab.binary(self.inputs)),
                self.run_id, str(seconds), str(mp4)]
        self.rec = {'name': name, 'mp4': mp4, 'files': (out, err), 'end': time.monotonic() + seconds + 15,
                    'proc': subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=err)}
        self.mark('record-start', name=name, fps=fps)

    def record_finish(self):
        r, self.rec = self.rec, None
        try:
            code = r['proc'].wait(max(0, r['end'] - time.monotonic()))
        except subprocess.TimeoutExpired:
            r['proc'].terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                r['proc'].wait(5)
            raise v.Blocked(f'{r["name"]}: recorder exceeded its bound')
        finally:
            for f in r['files']:
                f.close()
        self.mark('record-done', name=r['name'], code=code)
        if code or not r['mp4'].is_file():
            raise v.Failed(f'{r["name"]}: recorder exit {code}')
        self.save(f'{r["name"]}-record', json.loads((self.ev / f'{r["name"]}-record.stdout').read_text()))

    def close(self):
        errors, live = [], []
        steps = ([self.record_finish] if self.rec else []) + [lambda l=l: self.stop(l) for l in list(self.fixtures)]
        for step in steps:
            try:
                step()
            except Exception as e:
                errors.append(e)
        for x in self.procs:
            try:
                x['proc'].wait(max(10, x['until'] - time.monotonic()))
            except subprocess.TimeoutExpired:
                # Ends only the local SSH handle; its guest children may survive.
                x['proc'].terminate()
                with contextlib.suppress(subprocess.TimeoutExpired):
                    x['proc'].wait(5)
                live.append(x['name'])
            for f in x['files']:
                f.close()
        if live:
            errors.append(v.Blocked(f'owned SSH children did not exit: {live}; guest children may survive, shut down the VM'))
        if self.linked and not errors:
            try:
                self.unlink_incumbent()
            except Exception as e:
                errors.append(e)
        if self.linked:
            errors.append(v.Blocked(f'incumbent link {BREW} -> {self.linked} left in place'))
        self.report.setdefault('cleanup_errors', []).extend(repr(e) for e in errors)
        self.save('timeline', self.timeline)
        if errors:
            raise errors[0]
