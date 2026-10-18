"""Closed release-archive/Cellar simulation. Never invokes Homebrew or installs on the host."""
import json
import shlex

import verify_borders as borders
import verify_lean as lean

q = shlex.quote
CELLAR = "/opt/homebrew/Cellar/macarchy"
BIN = "/opt/homebrew/bin"
PRODUCTS = ("macarchy", "macarchy-menu", "macarchy-focus-ring")


def link_guard(copy):
    return " && ".join(
        "test -L {link} && test \"$(readlink {link})\" = {target}".format(
            link=q(BIN + "/" + name), target=q(copy + "/bin/" + name))
        for name in PRODUCTS)


def owner_guard(owner):
    return ("test -d {root} && test ! -L {root} && test -f {marker} && test ! -L {marker}"
            " && test \"$(cat {marker})\" = {session}"
            " && test \"$(stat -f '%d:%i' {root})\" = {identity}").format(
                root=q(CELLAR), marker=q(CELLAR + "/.verify-owner"),
                session=q(owner["session"]), identity=q(owner["identity"]))


def assess_upgrade(before, after, first, second, plist_before, plist_after, root):
    arguments = plist_before.get("ProgramArguments", [])
    return (
        plist_before == plist_after and plist_before.get("Label") == lean.LABEL
        and arguments == [BIN + "/macarchy-focus-ring", "--managed", "--state-root", root]
        and before.get("executablePath") == first + "/bin/macarchy-focus-ring"
        and after.get("executablePath") == second + "/bin/macarchy-focus-ring"
        and (before.get("pid"), before.get("started")) != (after.get("pid"), after.get("started"))
        and all(before.get(key) == after.get(key) for key in ("generationID", "accent"))
    )


def prepare(sh, record, evidence, section):
    import verify as v
    source = record["guest"]["source"]
    work = source + "/" + evidence.name + "-package"
    # No existing keg or links may be adopted, including dangling symlinks.
    sh("package-targets-absent", " && ".join(
        [borders._absent(CELLAR), borders._absent(work)]
        + [borders._absent(BIN + "/" + name) for name in PRODUCTS]
        + ["test -d " + q(path) + " && test ! -L " + q(path)
           for path in ("/opt", "/opt/homebrew", "/opt/homebrew/Cellar", BIN)]), blocked=True)
    sh("package-work", "mkdir " + q(work))
    # Archive smoke uses git's resource inventory; this is the owned source snapshot,
    # not a checkout or index on the host, and never creates a commit.
    sh("package-inventory", "cd " + q(source) + " && git init -q && git add -- Themes Keybindings Desktop Environment")
    sh("package-release-build", "cd " + q(source) + " && env " + borders.DEV
       + " swift build -c release", timeout=600)
    version = sh("package-version", "cat " + q(source + "/VERSION.txt")).strip()
    revision = record["host_source"]["head"]
    package = "macarchy-" + version + "-arm64-apple-darwin"
    archive = work + "/dist/" + package + ".tar.gz"
    # Both smoke paths create adversarial fixtures only through TestSafety in this VM.
    environment = "env " + borders.DEV + " MACARCHY_TEST_VM=1 TMPDIR=/private/tmp/ "
    # The archive bundles ttfx, so the guest needs git, network and a Rust toolchain.
    sh("package-ttfx-build", "cd " + q(source) + " && Scripts/build-ttfx.sh "
       + q(work + "/ttfx"), timeout=900)
    sh("package-archive-validation", "cd " + q(source) + " && " + environment
       + "Scripts/build-release-archive.sh .build/release/macarchy " + q(work + "/ttfx")
       + " " + q(work + "/dist")
       + " " + q(revision) + " && " + environment + "Scripts/test-release-archive-validation.sh "
       + shlex.join([archive, archive + ".sha256", revision]), timeout=600)
    section.update(archive=archive, archive_sha256=sh(
        "package-sha256", "shasum -a 256 " + q(archive)).split()[0], revision=revision)
    sh("package-unpack", "mkdir " + q(work + "/unpacked")
       + " && tar -xzf " + q(archive) + " -C " + q(work + "/unpacked"))
    # mkdir is exclusive: establish the marker and inode before copying anything.
    sh("package-own-cellar", "mkdir " + q(CELLAR) + " && printf '%s\\n' "
       + q(record["session"]) + " > " + q(CELLAR + "/.verify-owner"))
    section["owner"] = {"session": record["session"], "identity": sh(
        "package-cellar-identity", "stat -f '%d:%i' " + q(CELLAR)).strip()}
    section["copies"] = [CELLAR + "/" + version + "_" + str(index) for index in (1, 2)]
    for index, copy in enumerate(section["copies"], 1):
        # Formula install is prefix.install 'bin', 'libexec', 'share'. No synthetic brew receipt.
        sh("package-copy-" + str(index), owner_guard(section["owner"]) + " && mkdir " + q(copy)
           + "".join(" && ditto " + q(work + "/unpacked/" + package + "/" + part) + " "
                     + q(copy + "/" + part) for part in ("bin", "libexec", "share")))
    first = section["copies"][0]
    sh("package-link", owner_guard(section["owner"]) + " && " + " && ".join(
        "ln -s " + q(first + "/bin/" + name) + " " + q(BIN + "/" + name) for name in PRODUCTS))
    result = json.loads(sh("package-installed-version", v.step_command(BIN + "/macarchy", ["version", "--json"])))
    if result.get("version") != version or result.get("revision") != revision \
            or result.get("installation") != "unmanaged":
        raise v.Failed("Packaged version identity mismatch (no Homebrew receipt is fabricated)")
    section["version"] = result


def upgrade(sh, cli, runtime, root, section):
    import verify as v
    first, second = section["copies"]
    plist_command = "plutil -convert json -o - " + q(lean.PLIST)
    before = runtime("package-before-upgrade")
    plist_before = json.loads(sh("package-plist-before", plist_command))
    sh("package-switch-links", owner_guard(section["owner"]) + " && " + link_guard(first)
       + " && " + " && ".join("ln -sfn " + q(second + "/bin/" + name) + " "
                                 + q(BIN + "/" + name) for name in PRODUCTS))
    cli("package-upgrade-apply", "environment", "apply", "--profile",
        root.rsplit("/", 1)[0] + "/profile.toml", "--state-root", root, "--json")
    after = runtime("package-after-upgrade")
    plist_after = json.loads(sh("package-plist-after", plist_command))
    if not assess_upgrade(before, after, first, second, plist_before, plist_after, root):
        raise v.Failed("Upgrade failed stable-plist/new-Cellar-executable/PID/palette assertions")
    section["upgrade"] = {"before": before, "after": after, "unchanged_plist": plist_after}


def cleanup(sh, section):
    if "owner" not in section:
        return
    # Refuse to remove executable files while any focus helper/job still exists.
    sh("package-cleanup-service-absent",
       "{ pgrep -u $(id -u) -x 'macarchy-focus.*'; rc=$?; test $rc -eq 1; }"
       + " && { launchctl print gui/$(id -u)/" + q(lean.LABEL)
       + "; rc=$?; test $rc -eq 113; } && " + borders._absent(lean.PLIST))
    checks, removals = [], []
    for name in PRODUCTS:
        link = BIN + "/" + name
        targets = [copy + "/bin/" + name for copy in section["copies"]]
        checks.append("{ " + borders._absent(link) + "; } || { test -L " + q(link)
                      + " && { " + " || ".join('test "$(readlink ' + q(link) + ')" = '
                                                + q(target) for target in targets) + "; }; }")
        removals.append("if test -L " + q(link) + "; then rm " + q(link) + "; fi")
    sh("package-cleanup", owner_guard(section["owner"]) + " && "
       + " && ".join("{ " + check + "; }" for check in checks) + " && { "
       + "; ".join(removals) + "; rm -rf " + q(CELLAR) + "; }")
    sh("package-cleanup-absent", " && ".join(
        [borders._absent(CELLAR)] + [borders._absent(BIN + "/" + name) for name in PRODUCTS]))
    section["cleanup"] = "removed owned links and Cellar copies"


def run_journey(client, record, evidence, report):
    sh = borders._runner(client, evidence, report)
    borders.require_console_user(client, evidence, report)
    section = report["package"] = {"scope": "guest-local archive; simulated Cellar/link upgrade, not brew install"}
    try:
        prepare(sh, record, evidence, section)
        return lean.run_journey(client, record, evidence, report, package=section)
    finally:
        cleanup(sh, section)
