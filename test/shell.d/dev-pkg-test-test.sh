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
recipe = recipes / 'omarchy-dev' / 'PKGBUILD'
for directory in (stubs, checkout, recipe.parent):
    directory.mkdir(parents=True, exist_ok=True)
recipe.write_text('pkgname=omarchy\npkgver=4.0.5\npkgrel=1\n')

(stubs / 'makepkg').write_text('''#!/bin/bash
printf 'makepkg|%s|%s|%s\\n' "$*" "$EUID" "$OMARCHY_SRC" >>"$DEV_PKG_CALL_LOG"
if (( ${FAKE_BUILD_RC:-0} )); then exit "$FAKE_BUILD_RC"; fi
: >"built package.pkg.tar.zst"
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
env = dict(os.environ, PATH=f'{stubs}:{os.environ["PATH"]}',
           OMARCHY_PKGBUILDS_DIR=str(recipes), DEV_PKG_CALL_LOG=str(log))
helper = root / 'bin/omarchy-dev-pkg-test'

def run(terminal, build_rc=0, install_rc=0):
    log.write_text('')
    case_env = dict(env, FAKE_BUILD_RC=str(build_rc), FAKE_INSTALL_RC=str(install_rc))
    master = slave = None
    try:
        if terminal:
            master, slave = pty.openpty()
        result = subprocess.run(['bash', str(helper), 'omarchy-dev', str(checkout), '--cleanbuild'],
                                stdin=slave if terminal else subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                env=case_env, text=True)
    finally:
        if master is not None:
            os.close(master)
            os.close(slave)
    expected_rc = build_rc or install_rc
    assert result.returncode == expected_rc, (terminal, result.returncode, expected_rc, result.stdout)
    calls = [line.split('|') for line in log.read_text().splitlines()]
    assert calls[0] == ['makepkg', '-s --skipchecksums --noconfirm --cleanbuild', str(os.geteuid()), str(checkout)], calls
    if build_rc:
        assert len(calls) == 1, calls
    else:
        expected_auth = 'sudo' if terminal else 'pkexec'
        assert len(calls) == 2 and calls[1][0] == expected_auth, calls
        assert calls[1][3] == '5', 'package path was split or arguments changed'
        prefix = '/usr/bin/pacman -U --noconfirm --overwrite=* '
        assert calls[1][1].startswith(prefix), calls
        package = pathlib.Path(calls[1][1][len(prefix):])
        assert package.name == 'built package.pkg.tar.zst', calls
        assert not package.parent.exists(), 'build scratch was not cleaned up'
    assert recipe.read_text() == 'pkgname=omarchy\npkgver=4.0.5\npkgrel=1\n', 'source recipe mutated'

for terminal in (True, False):
    run(terminal)
    run(terminal, install_rc=37)
    run(terminal, install_rc=126)
    run(terminal, build_rc=23)
print('ok - terminal builds stay unprivileged and install through sudo /usr/bin/pacman')
print('ok - nonterminal builds stay unprivileged and install through pkexec /usr/bin/pacman')
print('ok - build and install failures propagate without fallback and clean up owned scratch')
PY
