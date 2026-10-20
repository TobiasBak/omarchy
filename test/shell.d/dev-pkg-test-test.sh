#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export DEV_PKG_TEST_TMP="$test_tmp"

# Run the real helper with fake build/authorization commands. A PTY is attached
# only to stdin for terminal callers, so output can still be captured normally.
python3 - <<'PY'
import os
import pathlib
import pty
import subprocess

root = pathlib.Path(os.environ['ROOT'])
scratch = pathlib.Path(os.environ['DEV_PKG_TEST_TMP'])
stubs = scratch / 'bin'
checkout = scratch / 'source checkout'
recipes = scratch / 'recipes'
for directory in (stubs, checkout, recipes):
    directory.mkdir(parents=True, exist_ok=True)

originals = {}
for name in ('omarchy', 'omarchy-dev', 'omarchy-settings-dev'):
    recipe = recipes / name / 'PKGBUILD'
    recipe.parent.mkdir()
    body = (f'pkgname={name}\npkgver=4.0.5\npkgrel=1.1\n'
            "depends=('omarchy-settings=4.0.5')\n"
            'pkgver() {\n  printf "4.0.5\\n"\n}\n')
    recipe.write_text(body)
    originals[name] = body

(stubs / 'makepkg').write_text('''#!/bin/bash
printf 'makepkg|%s|%s|%s\\n' "$*" "$EUID" "$OMARCHY_SRC" >>"$DEV_PKG_CALL_LOG"
if [[ $1 == "--printsrcinfo" ]]; then
  awk -F= '$1 == "pkgname" || $1 == "pkgver" || $1 == "pkgrel" { printf "\\t%s = %s\\n", $1, $2 }' PKGBUILD
else
  cp PKGBUILD "$DEV_PKG_RECIPE_SNAPSHOT"
  if (( ${FAKE_BUILD_RC:-0} )); then exit "$FAKE_BUILD_RC"; fi
  : >"built package.pkg.tar.zst"
fi
''')
for command in ('sudo', 'pkexec'):
    (stubs / command).write_text(f'''#!/bin/bash
printf '{command}|%s|%s|%s\\n' "$*" "$EUID" "$#" >>"$DEV_PKG_CALL_LOG"
exit "${{FAKE_INSTALL_RC:-0}}"
''')
(stubs / 'git').write_text('#!/bin/bash\nprintf "testsha\\n"\n')
for path in stubs.iterdir():
    path.chmod(0o755)

log = scratch / 'calls'
snapshot = scratch / 'built-PKGBUILD'
home = scratch / 'home'
default_checkout = home / 'Work/omarchy/omarchy-installer'
default_checkout.mkdir(parents=True)
env = dict(os.environ, PATH=f'{stubs}:{os.environ["PATH"]}', HOME=str(home),
           OMARCHY_PKGBUILDS_DIR=str(recipes), DEV_PKG_CALL_LOG=str(log),
           DEV_PKG_RECIPE_SNAPSHOT=str(snapshot))
helper = root / 'bin/omarchy-dev-pkg-test'

def invoke(args, terminal=False, build_rc=0, install_rc=0):
    log.write_text('')
    case_env = dict(env, FAKE_BUILD_RC=str(build_rc), FAKE_INSTALL_RC=str(install_rc))
    master = slave = None
    try:
        if terminal:
            master, slave = pty.openpty()
        return subprocess.run(['bash', str(helper), *args],
                              stdin=slave if terminal else subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              env=case_env, text=True)
    finally:
        if master is not None:
            os.close(master)
            os.close(slave)

def run(terminal, keep_metadata=False, build_rc=0, install_rc=0, package='omarchy'):
    args = ['--keep-package-metadata'] if keep_metadata else []
    args += [package, str(checkout), '--cleanbuild']
    result = invoke(args, terminal, build_rc, install_rc)
    expected_rc = build_rc or install_rc
    assert result.returncode == expected_rc, (args, terminal, result.returncode, expected_rc, result.stdout)
    calls = [line.split('|') for line in log.read_text().splitlines()]
    if keep_metadata:
        assert calls.pop(0) == ['makepkg', '--printsrcinfo', str(os.geteuid()), str(checkout)], calls
        assert snapshot.read_text() == originals[package], 'conservative mode changed recipe metadata/body'
        for field in (f'pkgname = {package}', 'pkgver = 4.0.5', 'pkgrel = 1.1'):
            assert field in result.stdout, result.stdout
        assert 'dev.testsha' not in result.stdout, result.stdout
    else:
        expected = originals[package + '-dev'].replace('pkgver=4.0.5', 'pkgver=dev.testsha')
        expected = expected[:expected.index('pkgver()')]
        assert snapshot.read_text() == expected, 'default mapping/version rewrite changed'
        assert f'Building {package}-dev dev.testsha from' in result.stdout, result.stdout
    assert calls[0] == ['makepkg', '-s --skipchecksums --noconfirm --cleanbuild', str(os.geteuid()), str(checkout)], calls
    if build_rc:
        assert len(calls) == 1, calls
    else:
        expected_auth = 'sudo' if terminal else 'pkexec'
        assert len(calls) == 2 and calls[1][0] == expected_auth, calls
        assert calls[1][3] == ('4' if keep_metadata else '5'), 'package path split or arguments changed'
        prefix = '/usr/bin/pacman -U --noconfirm '
        if not keep_metadata:
            prefix += '--overwrite=* '
        assert calls[1][1].startswith(prefix), calls
        package_path = pathlib.Path(calls[1][1][len(prefix):])
        assert package_path.name == 'built package.pkg.tar.zst', calls
        assert not package_path.parent.exists(), 'build scratch was not cleaned up'
    for name, body in originals.items():
        assert (recipes / name / 'PKGBUILD').read_text() == body, 'source recipe mutated'

for terminal in (True, False):
    for keep_metadata in (False, True):
        run(terminal, keep_metadata)
        run(terminal, keep_metadata, install_rc=37)
        run(terminal, keep_metadata, install_rc=126)
        run(terminal, keep_metadata, build_rc=23)
run(False, package='omarchy-settings')
result = invoke([])
assert result.returncode == 0, result.stdout
calls = [line.split('|') for line in log.read_text().splitlines()]
assert [call[0] for call in calls] == ['makepkg', 'pkexec', 'makepkg', 'pkexec'], calls
assert all(call[3] == str(default_checkout) for call in calls if call[0] == 'makepkg'), calls
assert 'Building omarchy-settings-dev dev.testsha from' in result.stdout, result.stdout
assert 'Building omarchy-dev dev.testsha from' in result.stdout, result.stdout
assert all('--overwrite=*' in call[1] for call in calls if call[0] == 'pkexec'), calls
print('ok - default packages/stable-name mapping, dev version rewrite and overwrite-all remain unchanged')
print('ok - conservative mode preserves the complete stable recipe and reports native metadata without overwrite-all')
print('ok - both modes build as caller and select sudo or pkexec /usr/bin/pacman by terminal access')
print('ok - both modes propagate build/install failures without fallback and clean up owned scratch')

for args in (['--keep-package-metadata'], ['--keep-package-metadata', 'omarchy'],
             ['--keep-package-metadata', 'omarchy', ''],
             ['--keep-package-metadata', '', str(checkout)],
             ['--keep-package-metadata', 'omarchy', '--cleanbuild']):
    result = invoke(args)
    assert result.returncode == 1 and not log.read_text(), (args, result.stdout)
    assert 'requires an explicit package name and checkout' in result.stdout, result.stdout
result = invoke(['--help'])
assert result.returncode == 0 and not log.read_text(), result.stdout
assert '--keep-package-metadata <package-name> <path-to-checkout>' in result.stdout, result.stdout
assert 'must not switch the workstation' in result.stdout, result.stdout
print('ok - conservative mode requires explicit name/checkout and help discovers it without building')
PY
