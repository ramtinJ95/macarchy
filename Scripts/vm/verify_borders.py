# Borders journey preparation (first chunk): guest release builds, the canonical
# theme via the supported environment/theme CLI, and the pinned incumbent build.
# Called by verify.py's closed 'borders' journey; verify is imported lazily.
import base64
import functools
import hashlib
import json
import os
import pathlib
import re
import shlex
import time

q = shlex.quote
DEV = 'DEVELOPER_DIR=/Library/Developer/CommandLineTools'
GUEST_USER = 'omarchy'
ZSHRC = '/Users/omarchy/.zshrc'
THEME = 'catppuccin-mocha'
BUILD_TIMEOUT = 2400
RECORD_SECONDS = 20
INCUMBENT_URL = 'https://github.com/FelixKratz/JankyBorders.git'
INCUMBENT_COMMIT = 'a7297ca7d1933f3a30b12e8f10750e8d84eeee1e'  # tag 1.9.0
RECIPE = 'borders-prepare-v1'  # reuse guard for future reports; legacy reports lack it
PRODUCTS = ('macarchy', 'macarchy-focus-ring')
DISABLED = ('desktop', 'top_bar', 'focus_ring', 'terminal', 'prompt', 'history', 'editor')
PROFILE = '\n'.join(
    ['schema_version = 1', '', '[shell]', 'provider = "zsh"', '']
    + [line for name in DISABLED for line in ('[%s]' % name, 'provider = "disabled"', '')]
    + ['[tools]', 'bat = false', 'eza = false', 'btop = false', 'yazi = false', '',
       ]
)


def _v():
    import verify
    return verify


def _text(value):
    if isinstance(value, bytes):
        return value.decode('utf-8', 'replace')
    return '' if value is None else str(value)


def _section(report):
    return report.setdefault('borders', {})


def run(client, evidence, report, name, command, timeout=30, data=None, blocked=False):
    '''Run one guest command, preserve its log, raise Failed (or Blocked) on error.'''
    v = _v()
    evidence = pathlib.Path(evidence)
    log = evidence / ('%02d-%s.log' % (len(list(evidence.glob('*.log'))) + 1, name))
    started = time.monotonic()
    result, error = None, None
    try:
        result = client.command(command, check=False, data=data, timeout=timeout)
    except Exception as exc:  # timeout/transport: keep the log, then fail
        error = '%s: %s' % (type(exc).__name__, exc)
    seconds = round(time.monotonic() - started, 3)
    code = None if result is None else result.returncode
    out = '' if result is None else _text(result.stdout)
    err = '' if result is None else _text(result.stderr)
    lines = ['$ ' + command, 'exit: %s' % code, 'seconds: %s' % seconds,
             'error: %s' % error, '--- stdout', out, '--- stderr', err, '']
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as handle:
        handle.write('\n'.join(lines))
    _section(report).setdefault('commands', []).append(
        {'name': name, 'exit': code, 'seconds': seconds, 'log': log.name})
    if error is not None or code != 0:
        kind = v.Blocked if blocked or error is not None else v.Failed
        raise kind('%s failed (exit %s%s); see %s' % (name, code, ', ' + error if error else '', log))
    return out


def _runner(client, evidence, report):
    return functools.partial(run, client, evidence, report)


def _absent(path):
    return 'test ! -e %s && test ! -L %s' % (q(path), q(path))


def _regular(paths):
    return ' && '.join('test -f %s && test ! -L %s' % (q(p), q(p)) for p in paths)


def _build_products(sh, source, label):
    '''Release-build PRODUCTS in the guest source; returns its bin dir, pinned under source/.build.'''
    swift = 'cd %s && env %s swift build -c release' % (q(source), DEV)
    for product in PRODUCTS:
        sh(label + 'build-' + product, swift + ' --product ' + q(product), timeout=BUILD_TIMEOUT)
    lines = sh(label + 'bin-path', swift + ' --show-bin-path', timeout=BUILD_TIMEOUT,
               blocked=True).strip().splitlines()
    bin_dir = lines[-1].strip() if lines else ''
    if not bin_dir.startswith(source + '/.build/') or '..' in bin_dir.split('/'):
        raise _v().Blocked('%sbin-path: %r is outside %s/.build' % (label, bin_dir, source))
    return bin_dir


def cli(binary, *args):
    # Clean-environment invocation of the real CLI through verify's helper.
    return _v().step_command(binary, [str(arg) for arg in args])


def consumer_flags(scratch):
    c = scratch + '/consumers'
    return [
        '--kitty-config', c + '/kitty.conf',
        '--sketchy-bar-config', c + '/sketchybarrc',
        '--shell-config', ZSHRC,
        '--eza-config-dir', c + '/eza',
        '--bat-config-dir', c + '/bat',
        '--bat-cache-dir', c + '/bat-cache',
        '--btop-config-dir', c + '/btop',
        '--yazi-config-dir', c + '/yazi',
        '--atuin-config-dir', c + '/atuin',
        '--neovim-config-dir', c + '/nvim',
        '--starship-config', c + '/starship.toml',
        '--starship-behavior', c + '/starship-behavior.toml',
        '--pi-config-dir', scratch + '/home/.pi/agent',
        '--herdr-config', c + '/herdr.toml',
        '--tuicr-config-dir', c + '/tuicr',
        '--codex-config-dir', c + '/codex',
        '--spicetify-config-dir', c + '/spicetify',
    ]


def _blockers(payload, path='$'):
    found = []
    if isinstance(payload, dict):
        for key, value in payload.items():
            where, lowered = path + '.' + str(key), str(key).lower()
            if (lowered == 'blocked' or 'adopt' in lowered) and value:
                found.append(where)
            elif lowered in ('status', 'outcome') and isinstance(value, str) \
                    and ('block' in value.lower() or 'adopt' in value.lower()):
                found.append(where + '=' + value)
            found += _blockers(value, where)
    elif isinstance(payload, list):
        for index, value in enumerate(payload):
            found += _blockers(value, '%s[%d]' % (path, index))
    return found


def _checked_json(client, evidence, report, name, command):
    text = run(client, evidence, report, name, command, timeout=600)
    try:
        payload = json.loads(text)
    except ValueError as exc:
        raise _v().Failed('%s: output is not JSON: %s' % (name, exc))
    blockers = _blockers(payload)
    if blockers:
        raise _v().Failed('%s reports blocked/adoption state; no auto-approval: %s'
                          % (name, ', '.join(blockers)))
    return payload


def set_theme(client, evidence, report, context, theme=THEME):
    _checked_json(client, evidence, report, 'theme-set-' + theme, cli(
        context['binary'], 'theme', 'set', theme, '--themes-root', context['themes_root'],
        '--json', *context['flags']))
    current = context['state'] + '/current'
    run(client, evidence, report, 'theme-current-' + theme, 'test -L ' + q(current))
    _section(report)['theme'] = {'name': theme, 'current': current}


def require_console_user(client, evidence, report):
    # Call before launching any GUI process; prepare itself may run pre-login.
    owner = run(client, evidence, report, 'console-user',
                '/usr/bin/stat -f %Su /dev/console', blocked=True).strip()
    if owner != GUEST_USER:
        raise _v().Blocked('console owner is %r, expected %r' % (owner, GUEST_USER))


def _sha256(sh, name, paths):
    digests = {}
    for line in sh(name, 'shasum -a 256 ' + ' '.join(q(p) for p in paths)).splitlines():
        digest, _, path = line.partition('  ')
        digests[path] = digest
    missing = [p for p in paths if p not in digests]
    if missing:
        raise _v().Failed('%s: no digest for %s' % (name, ', '.join(missing)))
    return digests


def _context(source, scratch, bin_dir):
    # Shared by fresh prepare and verified reuse; 'work' holds per-run fixture/preview dirs.
    return {
        'source': source, 'scratch': scratch, 'work': scratch, 'state': scratch + '/state',
        'bin_dir': bin_dir, 'binary': bin_dir + '/macarchy', 'helper': bin_dir + '/macarchy-focus-ring',
        'fixture': scratch + '/border-fixture', 'profile': scratch + '/profile.toml',
        'themes_root': source + '/Themes', 'theme': THEME,
        'flags': ['--state-root', scratch + '/state'] + consumer_flags(scratch),
    }


def prepare(client, record, evidence, report):
    v = _v()
    source = str(record['guest']['source'])
    scratch = source + '/' + pathlib.Path(evidence).name
    section = _section(report)
    sh = _runner(client, evidence, report)

    sh('scratch-absent', _absent(scratch), blocked=True)
    sh('zshrc-absent', _absent(ZSHRC), blocked=True)
    sh('scratch-create', 'mkdir -m 0700 %s && mkdir -m 0700 %s %s'
       % (q(scratch), q(scratch + '/consumers'), q(scratch + '/home')))

    context = _context(source, scratch, _build_products(sh, source, ''))
    binary, helper, fixture = context['binary'], context['helper'], context['fixture']
    sh('build-border-fixture', '%s swiftc -O -parse-as-library %s -o %s' % (
        DEV, q(source + '/Scripts/vm/border-fixture.swift'), q(fixture)), timeout=BUILD_TIMEOUT)
    digests = _sha256(sh, 'artifact-sha256', (binary, helper, fixture))
    section['builds'] = {
        'macarchy': {'path': binary, 'configuration': 'release', 'sha256': digests[binary],
                     'version': sh('macarchy-version', cli(binary, 'version', '--json')).strip()},
        'macarchy-focus-ring': {'path': helper, 'configuration': 'release',
                                'sha256': digests[helper]},
        'border-fixture': {'path': fixture, 'sha256': digests[fixture]},
    }

    profile = context['profile']
    encoded = base64.b64encode(PROFILE.encode()).decode()
    sh('profile-write', 'umask 077 && set -C && printf %s ' + q(encoded)
       + ' | /usr/bin/base64 -D > ' + q(profile))
    section['recipe'] = RECIPE
    section['mutation_scope'] = {
        'shell_config': ZSHRC, 'scratch': scratch,
        'excluded_from_acceptance': ['aggregate setup', 'native consumers'],
    }
    _checked_json(client, evidence, report, 'environment-plan', cli(
        binary, 'environment', 'plan', '--profile', profile, '--state-root', context['state'], '--json'))
    _checked_json(client, evidence, report, 'environment-apply', cli(
        binary, 'environment', 'apply', '--profile', profile, '--json', *context['flags']))
    set_theme(client, evidence, report, context)

    incumbent = scratch + '/incumbent'
    git = '%s git -C %s ' % (DEV, q(incumbent))
    sh('incumbent-clone', '%s git clone --no-checkout %s %s'
       % (DEV, q(INCUMBENT_URL), q(incumbent)), timeout=600)
    sh('incumbent-checkout', git + 'checkout --detach ' + INCUMBENT_COMMIT, timeout=120)
    head = sh('incumbent-head', git + 'rev-parse HEAD').strip()
    if head != INCUMBENT_COMMIT:
        raise v.Failed('incumbent HEAD %s != %s' % (head, INCUMBENT_COMMIT))
    sh('incumbent-make', '%s make -C %s' % (DEV, q(incumbent)), timeout=BUILD_TIMEOUT)
    borders = incumbent + '/bin/borders'
    section['incumbent'] = {
        'commit': head, 'path': borders,
        'sha256': _sha256(sh, 'incumbent-sha256', (borders,))[borders],
        'version': sh('incumbent-version', q(borders) + ' --version').strip(),
    }
    context['incumbent'] = dict(section['incumbent'], dir=incumbent)
    return context


def _prior(record, evidence, source):
    '''Newest earlier drive-borders-NN report that fully prepared this session's guest source.'''
    evidence, rejected = pathlib.Path(evidence), {}
    names = sorted((p.name for p in evidence.parent.glob('drive-borders-[0-9][0-9]')
                    if p.name != evidence.name), reverse=True)
    for name in names:
        scratch = source + '/' + name
        try:
            raw = (evidence.parent / name / 'report.json').read_bytes()
            old = json.loads(raw)
            bs = old['borders']
            builds, inc, scope = bs['builds'], bs['incumbent'], bs['mutation_scope']
            ctx = _context(source, scratch, str(pathlib.PurePosixPath(builds['macarchy']['path']).parent))
            ok = {c['name'] for c in bs['commands'] if c['exit'] == 0}
            sha = [builds[k]['sha256'] for k in sorted(builds)] + [inc['sha256']]
            checks = {
                'cleanup_errors': not old.get('cleanup_errors'),
                'recipe': bs.get('recipe', RECIPE) == RECIPE,
                'session': old.get('session') == record['session'] and old.get('run') == record['run'],
                'snapshot': old.get('snapshot_sha256') == record['host_source']['snapshot_sha256'],
                'scratch': scope['scratch'] == scratch and scope['shell_config'] == ZSHRC,
                'builds': sorted(builds) == ['border-fixture', 'macarchy', 'macarchy-focus-ring']
                and ctx['bin_dir'].startswith(source + '/.build/')
                and [builds[k]['path'] for k in ('macarchy', 'macarchy-focus-ring', 'border-fixture')]
                == [ctx['binary'], ctx['helper'], ctx['fixture']]
                and builds['macarchy']['configuration'] == builds['macarchy-focus-ring']['configuration'] == 'release',
                'sha256': all(isinstance(d, str) and re.fullmatch('[0-9a-f]{64}', d) for d in sha),
                'incumbent': inc['commit'] == INCUMBENT_COMMIT and inc['path'] == scratch + '/incumbent/bin/borders',
                'commands': {'environment-apply', 'theme-set-' + THEME, 'incumbent-version'} <= ok,
            }
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
            rejected[name] = '%s: %s' % (type(exc).__name__, exc)
            continue
        failed = [k for k, passed in checks.items() if not passed]
        if not failed:
            return name, old, ctx, hashlib.sha256(raw).hexdigest(), rejected
        rejected[name] = failed
    return None, None, None, None, rejected


def preparation(client, record, evidence, report):
    '''Reuse the newest fully prepared earlier report after live guest checks; else prepare fresh.'''
    v, section = _v(), _section(report)
    source = str(record['guest']['source'])
    name, old, ctx, report_sha, rejected = _prior(record, evidence, source)
    section['preparation_rejected'] = rejected
    if name is None:
        return prepare(client, record, evidence, report)
    report['preparation_reused_from'] = name
    for key in ('builds', 'incumbent', 'mutation_scope'):
        section[key] = old['borders'][key]
    inc = section['incumbent']
    sh = _runner(client, evidence, report)

    v.require_session_directory(client, record['session'])
    paths = {'macarchy': ctx['binary'], 'macarchy-focus-ring': ctx['helper'],
             'border-fixture': ctx['fixture'], 'incumbent': inc['path']}
    sh('reuse-regular-files', _regular(paths.values()), blocked=True)
    digests = _sha256(sh, 'reuse-sha256', tuple(paths.values()))
    actual = {k: digests[p] for k, p in paths.items()}
    expected = dict({k: section['builds'][k]['sha256'] for k in paths if k != 'incumbent'},
                    incumbent=inc['sha256'])
    section['prep_source'] = {'report': name + '/report.json', 'report_sha256': report_sha, 'sha256': actual}
    if actual != expected:
        raise v.Failed('%s binaries changed since preparation: %s'
                       % (name, sorted(k for k in paths if actual[k] != expected[k])))
    # Exec only after digests match. Exit 0 is the gate; the JSON stays in its log for review.
    status = run(client, evidence, report, 'environment-status', cli(
        ctx['binary'], 'environment', 'status', '--profile', ctx['profile'],
        '--state-root', ctx['state'], '--json'), timeout=600)
    try:
        json.loads(status)
    except ValueError as exc:
        raise v.Failed('environment-status: output is not JSON: %s' % exc)
    ctx['work'] = ctx['scratch'] + '/' + pathlib.Path(evidence).name
    sh('reuse-work-absent', _absent(ctx['work']), blocked=True)
    set_theme(client, evidence, report, ctx)
    ctx['incumbent'] = dict(inc, dir=ctx['scratch'] + '/incumbent')
    return ctx


def build_candidate(client, ctx, evidence, report, run_id, name):
    '''Build release products in a ready same-run candidate session's guest source.

    Preparation keeps source, state, profile, flags, and incumbent; only the product
    binaries and theme sources move to the candidate snapshot.'''
    import guest
    v = _v()
    sh = _runner(client, evidence, report)

    candidate = v.session_ready(guest.run_directory(run_id), name)
    source = candidate['guest']['source']
    if source != v.guest_directory(name):
        raise v.Blocked('candidate source %r is not the %s guest directory' % (source, name))
    if candidate.get('run') != run_id or candidate.get('status') != 'ready':
        raise v.Blocked('candidate %s is not a ready session of %s' % (name, run_id))
    v.guest_identity(client, candidate)
    bin_dir = _build_products(sh, source, 'candidate-')
    paths = {p: bin_dir + '/' + p for p in PRODUCTS}
    sh('candidate-regular-files', _regular(paths.values()), blocked=True)
    digests = _sha256(sh, 'candidate-sha256', tuple(paths.values()))
    report['candidate_build'] = {
        'session': name, 'snapshot_sha256': candidate['host_source']['snapshot_sha256'],
        'source': source, 'configuration': 'swift build -c release', 'bin_dir': bin_dir,
        'products': {k: {'path': p, 'sha256': digests[p]} for k, p in paths.items()},
        'replaces': {'binary': ctx['binary'], 'helper': ctx['helper']},
        'provenance': ('candidate snapshot built in its own guest source; prepared source, '
                       'state, profile, flags, and incumbent are unchanged')}
    ctx.update(binary=paths['macarchy'], helper=paths['macarchy-focus-ring'],
               bin_dir=bin_dir, themes_root=source + '/Themes')
    # Re-apply the canonical theme with the candidate CLI against the prepared state.
    set_theme(client, evidence, report, ctx)


def build_current_fixture(client, ctx, evidence, report):
    '''Compile the current host fixture source in a new private guest dir.

    Product binaries come from candidate_build when present, otherwise the prepared snapshot;
    only the fixture is this harness version.'''
    import lab
    sh = _runner(client, evidence, report)

    raw = (lab.HERE / 'border-fixture.swift').read_bytes()
    work = ctx['work']
    harness = work + '/harness'
    src, out = harness + '/source.swift', harness + '/border-fixture'
    if work != ctx['scratch']:  # reused preparation: work was only asserted absent
        sh('harness-work-mkdir', _absent(work) + ' && mkdir -m 700 ' + q(work), blocked=True)
    sh('harness-mkdir', _absent(harness) + ' && mkdir -m 700 ' + q(harness), blocked=True)
    sh('harness-upload', 'umask 077 && base64 -D > %s' % q(src),
       data=base64.b64encode(raw).decode('ascii'))
    sh('harness-build', 'umask 077 && env %s swiftc -O -parse-as-library -o %s %s'
       % (DEV, q(out), q(src)), timeout=600)
    digests = _sha256(sh, 'harness-sha256', (src, out))
    source = hashlib.sha256(raw).hexdigest()
    if digests[src] != source:
        raise _v().Failed('harness-upload: guest source differs from host border-fixture.swift')
    report['fixture'] = {
        'source_sha256': source, 'binary_sha256': digests[out], 'configuration': 'swiftc -O',
        'path': out, 'source_path': src,
        'provenance': ('harness version compiled in-guest from current host source; product '
                       'binaries come from candidate_build when present, otherwise the prepared '
                       'snapshot; fixture source and binary hashes are recorded separately')}
    ctx['fixture'] = out


def _rect(f):
    return [f[k] for k in ('x', 'y', 'width', 'height')] if isinstance(f, dict) else list(f)


def _borders_case(v, w, s, n, renderer, key):
    checks, out, pv, h, last = [], {}, None, None, n - 1
    scratch = s.ctx['work'] + '/' + key
    motion = n == 1 and bool(s.ctx.get('border_motion'))

    def act(label, action, i=None, **kw):
        st = s.act(label, action, i, **kw)
        k = [x for x in st['windows'] if x['key'] and not (x['minimized'] or x['fullscreen'] or x['closed'])]
        if action in ('focus', 'move', 'resize', 'animate') and st['appActive'] and k:
            # Settled per-action states only, not animation frames. Helper frames are AppKit
            # coordinates; the outline grows the window 3 pt per side.
            x, y, wd, ht = _rect(k[0]['frameNS'])
            checks.append({'label': label, 'seq': st['actionSequence'], 'action': action,
                           'id': k[0]['id'], 'outline': [x - 3, y - 3, wd + 6, ht + 6]})
        return st

    ready = s.fixture(n, 'A', scratch + '/A')
    out['display'] = {k: ready[k] for k in ('backingScaleFactor', 'screenLogicalFrame', 'screenPixelDimensions')}
    if renderer != 'none':
        if renderer == 'borders':
            s.link_incumbent()
        pv = s.preview('preview-' + key, renderer, 90 if n == 8 or motion else 60,
                       w.BREW if renderer == 'borders' else s.ctx['helper'])
        h = out['helper_pid'] = pv['helper']
    for i in [*range(n), 0]:
        act('A', 'focus', i)
    time.sleep(2)
    s.sample('steady', h)
    s.capture('initial')
    if motion:
        s.record_start('motion', RECORD_SECONDS)
        time.sleep(1.5)
        mc = act('A', 'motion', 0, timeout=18)['motionCheck']
        out['motion'] = {k: mc[k] for k in ('sequence', 'ticks', 'moving_ticks', 'elapsed_seconds', 'requested_hz')}
        s.save('motion', out['motion'])
        s.capture('motion-end')
        s.record_finish()
        from border_motion_pixels import analyze
        pixels = analyze(s.ev / 'motion.mp4', s.ev / 'motion-pixels.json', renderer != 'none')
        out['video'] = {k: x for k, x in pixels.items() if k != 'rows'}
        if not pixels['sampling_passed']:
            raise v.Failed(f'{key}: motion video sampling insufficient: {pixels["sampling_failures"]}')
    elif n == 8:
        s.record_start('journey', RECORD_SECONDS)
        time.sleep(1.5)
        for a, i, shot in (('focus', last, 'focused'), ('move', last, 'move'), ('resize', last, 'resize'),
                           ('animate', last, None), ('focus', 0, None), ('minimize', 0, 'minimized'),
                           ('restore', 0, None), ('focus', 0, None)):
            act('A', a, i)
            if shot:
                s.capture(shot)
        s.record_finish()
        t = next(e['t'] for e in s.timeline if e['event'] == 'record-start')
        # Host-clock bound: only these acks can appear in the recorded video.
        end = t + RECORD_SECONDS
        acks = [e['sequence'] for e in s.timeline if e['event'] == 'ack' and e['label'] == 'A' and t <= e['t'] <= end]
        out['video'] = {'host_t': [t, end], 'acks_in_window': acks}
        s.fixture(1, 'B', scratch + '/B')
        out['crossapp_id'] = w.window(act('B', 'focus', 0), 0)['id']
        s.capture('crossapp')
        act('A', 'focus', 0)
        s.capture('back')
        s.stop('B')
        for shot in ('fullscreen', 'fullscreen-exit'):
            act('A', 'fullscreen', 0, timeout=12)
            time.sleep(2)
            s.capture(shot)
        for theme, shot in (('tokyo-night', 'theme'), ('catppuccin-mocha', 'restored')):
            s.theme(theme)
            time.sleep(1)
            s.capture(shot)
        if h and s.read(f'ps -o pid= -p {h}; test $? -le 1').split() != [str(h)]:
            raise v.Failed(f'{key}: helper {h} exited across theme changes')
    else:
        for a in ('move', 'resize', 'animate'):
            act('A', a, 0)
            s.capture(a)
    act('A', 'close', last)
    s.capture('closed')
    if pv and time.monotonic() > pv['end']:
        raise v.Failed(f'{key}: preview ended before the workload finished')
    s.stop('A')
    s.save('checkpoints', checks)
    if pv:
        s.finish_preview(pv)
    if renderer != 'lean':
        return out
    lines = [json.loads(x) for x in pv['stdout'].read_text().splitlines() if x.strip()]
    if len(lines) != 2:
        raise v.Failed(f'{key}: expected plan + helper report JSONL, got {len(lines)} lines')
    rep, need = lines[1], 2 if n == 8 else 1
    obs = rep['observations']
    seen = [(o['target_window_id'], _rect(o['frame'])) for o in obs if o['visible']]
    out.update(result=[rep['outcome'], rep['stop_reason'], rep.get('error'), rep['dropped_observations']],
               observations=len(obs), generations=len({o['generation_id'] for o in obs}),
               accents=sorted({o['accent'] for o in obs if o['accent']}),
               native_fullscreen=any(o['reason'] == 'native-fullscreen' for o in obs),
               missing=[c for c in checks if not any(i == c['id'] and all(
                   abs(a - b) <= 0.5 for a, b in zip(f, c['outline'])) for i, f in seen)])
    driver, driver_ok = _update_driver(rep, motion)
    out.update(driver)
    s.save('summary', out)
    if (not driver_ok or out['result'] != ['completed', 'duration', None, 0] or out['missing'] or out['generations'] < need
            or (n == 8 and not {'#cba6f7', '#7aa2f7'}.issubset(out['accents'])) or (n == 8 and not out['native_fullscreen'])):
        raise v.Failed(f'{key}: lean helper report misses journey expectations; see summary.json')
    return out


def _update_driver(rep, motion):
    """Event-driven reports need enough event-backed refreshes; reports without a driver are legacy polling."""
    drv = rep.get('update_driver')
    if drv is None:
        return {'update_driver': 'legacy-polling'}, True
    geo, events = rep.get('geometry_refresh_count'), rep.get('event_count')
    ok = (drv == 'window-server-events' and all(type(x) is int for x in (geo, events))
          and geo >= (300 if motion else 60) and events >= geo)
    return {'update_driver': drv, 'geometry_refresh_count': geo, 'event_count': events}, ok


def run_journey(client, record, evidence, report):
    import border_workload as w
    import lab
    v, ev, here = _v(), pathlib.Path(evidence), pathlib.Path(__file__).resolve().parent
    report['not_covered'] = ['physical Mac hardware/GPU (Tart guest only)', 'multiple displays',
                             'manual Spaces/other desktops (native fullscreen is asserted only in a completed journey)',
                             'real third-party apps (fixture windows only)']
    report['parity'] = 'fixture-only incumbent vs lean comparison, not full production parity'
    report['visual_review'] = ('pending: a pass proves memory, lifecycle/safety and fixture tracking only; '
                               'visual parity needs coordinator review of the PNG/MP4 evidence')
    # The guest source snapshot predates this host harness; it binds product/fixture binaries only.
    report['harness_sha256'] = {f: hashlib.sha256((here / f).read_bytes()).hexdigest() for f in (
        'verify.py', 'verify_borders.py', 'border_workload.py', 'window-control.swift',
        'border-fixture.swift', 'border_motion_pixels.py')}
    border_count, run_id = report.get('border_count'), record['run']
    if report.get('border_motion'):
        report['claim'] = 'Fixed 14 s 60 Hz fixture motion; 60 fps is requested capture, not measured. ' + report['claim']
    ctx = preparation(client, record, evidence, report)
    ctx['border_motion'] = bool(report.get('border_motion'))
    if report.get('candidate_session'):
        build_candidate(client, ctx, evidence, report, record['run'], report['candidate_session'])
    build_current_fixture(client, ctx, evidence, report)
    require_console_user(client, evidence, report)
    controller = lab.build_controller()
    counts = (border_count,) if border_count is not None else (1, 8, 24)
    report['counts'] = list(counts)
    if border_count is not None:
        report['claim'] = f'Partial {border_count}-window workload only; NOT a complete borders gate. ' + report['claim']
    cases = report['cases'] = {}
    for n in counts:
        for r in ('none', 'borders', 'lean'):
            key = f'{r}-{n}'
            (ev / key).mkdir()
            with w.Session(client, ev / key, report, ctx, run_id, controller) as s:
                s.host_setup()
                cases[key] = _borders_case(v, w, s, n, r, key)
    displays = [c['display'] for c in cases.values()]
    if any(d != displays[0] for d in displays):
        raise v.Failed('Display geometry/scale changed between comparison cases')
    if displays[0]['backingScaleFactor'] < 2:
        report['not_covered'].append('Retina/HiDPI: observed guest backing scale is 1')
    report['memory_accounting'] = ('top MEM is physical footprint, rounded by top; WindowServer is system-wide, '
        'noisy and may share accounting with client surfaces. Do not sum as uniquely attributable memory.')
    savings = report['savings'] = {}
    for n in counts:
        row = savings[str(n)] = {}
        for r in ('none', 'borders', 'lean'):
            h = str(cases[f'{r}-{n}'].get('helper_pid'))
            pids = json.loads((ev / f'{r}-{n}' / 'steady-sample.json').read_text())['pids']
            row[r] = {('helper_' if p == h else 'windowserver_') + m: x[f]['median'] for p, x in pids.items()
                      for m, f in (('footprint', 'footprint_bytes'), ('cpu', 'cpu_percent_excl_first'))}
        row['lean_footprint_pct_of_incumbent'] = round(
            100 * row['lean']['helper_footprint'] / row['borders']['helper_footprint'], 1)
    report['cpu'] = 'CPU medians (first top sample excluded) reported for transparency; not gated'
    if 24 not in counts:
        report['memory_gate'] = {'evaluated': False, 'reason': '24-window workload not selected'}
        return 'passed'
    lean, base = (savings['24'][r]['helper_footprint'] for r in ('lean', 'borders'))
    report['memory_gate'] = {'rule': 'lean 24-window helper footprint median <= 50% of pinned JankyBorders '
                                     '(qualification threshold chosen for this journey, not a universal guarantee)',
                             'percent': savings['24']['lean_footprint_pct_of_incumbent'], 'passed': 2 * lean <= base,
                             'evaluated': True}
    if 2 * lean > base:
        raise v.Failed(f'lean 24-window helper footprint {lean} B exceeds 50% of incumbent {base} B')
    return 'passed'
