#!/usr/bin/env bash
# Isolated control-flow tests; fake GPU/vainfo/browser, no hardware claims.
set -euo pipefail
[[ $EUID != 0 ]] || { echo 'Run tests as a regular user (same contract as installer).' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
export HOME="$fixture/home" XDG_DATA_HOME="$fixture/data with spaces"
mkdir -p "$HOME" "$fixture/bin" "$fixture/driver"
printf 'fixture, not an ELF library\n' >"$fixture/driver/nvidia_drv_video.so"
export PATH="$fixture/bin:$PATH" WAYLAND_DISPLAY=fixture-wayland
export FIXTURE_LOG="$fixture/browser.log"
if ! command -v flock >/dev/null; then
  # Git Bash has no flock. These serial fixture tests do not test OS locking.
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/bin/flock"
fi
cat >"$fixture/bin/uname" <<'STUB'
#!/usr/bin/env bash
case $1 in -s) echo Linux ;; -r) echo fixture-kernel ;; *) exit 1 ;; esac
STUB
cat >"$fixture/bin/nvidia-smi" <<'STUB'
#!/usr/bin/env bash
[[ ${FIXTURE_GPU_FAIL:-0} != 1 ]] || exit 1
echo 'Fixture GPU, fixture-driver'
STUB
cat >"$fixture/bin/vainfo" <<'STUB'
#!/usr/bin/env bash
[[ ${LIBVA_DRIVER_NAME:-} == nvidia && ${NVD_BACKEND:-} == direct ]]
[[ -r $LIBVA_DRIVERS_PATH/nvidia_drv_video.so ]]
[[ ${FIXTURE_VA_FAIL:-0} != 1 ]] || exit 1
echo 'Fixture VAEntrypointVLD (not a hardware result)'
STUB
cat >"$fixture/bin/google-chrome-stable" <<'STUB'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then echo 'Fixture browser'; exit 0; fi
printf '%s\n' "$@" >"$FIXTURE_LOG"
printf '%s\n' "${LIBVA_DRIVERS_PATH:-}" "${MOZ_DISABLE_RDD_SANDBOX:-unset}" >>"$FIXTURE_LOG"
STUB
cp "$fixture/bin/google-chrome-stable" "$fixture/bin/firefox"
chmod +x "$fixture/bin/"*
setup() { bash "$repo/setup.sh" "$@"; }
expect_fail() {
  if "$@" >"$fixture/expected-error" 2>&1; then echo "Expected failure: $*" >&2; exit 1; fi
}
pass() { printf 'PASS %s\n' "$1"; }
prefix=$XDG_DATA_HOME/deb-browser-nvidia
desktop=$XDG_DATA_HOME/applications

setup --help >"$fixture/help"
expect_fail setup --unknown
expect_fail setup --browser
expect_fail setup --browser invalid
expect_fail setup --check --rollback
pass 'argument validation'

setup --dry-run --driver-dir "$fixture/driver" >"$fixture/plan"
[[ ! -e $prefix ]]
expect_fail setup --browser firefox --driver-dir "$fixture/driver"
[[ ! -e $prefix ]]
pass 'dry run and explicit Firefox sandbox consent leave no installation'

export FIXTURE_GPU_FAIL=1
expect_fail setup --driver-dir "$fixture/driver"
unset FIXTURE_GPU_FAIL
[[ ! -e $prefix ]]
pass 'GPU failure stops before writes'

setup --driver-dir "$fixture/driver" >"$fixture/install"
first=$(readlink "$prefix/current")
[[ -f $prefix/current/lib/nvidia_drv_video.so ]]
[[ -f $desktop/deb-browser-nvidia-chrome.desktop ]]
grep -q 'Exec=".*data with spaces.*" %U' "$desktop/deb-browser-nvidia-chrome.desktop"
export CHROME_NV_RENDER_NODE="$fixture/render-node"
touch "$CHROME_NV_RENDER_NODE"
"$prefix/current/bin/chrome-nvidia" 'https://example.invalid/path?q=hello world'
grep -qx -- '--ozone-platform=wayland' "$FIXTURE_LOG"
grep -qx 'https://example.invalid/path?q=hello world' "$FIXTURE_LOG"
setup --check >"$fixture/check"
pass 'Chrome install, paths with spaces, argument forwarding, check'

export FIXTURE_VA_FAIL=1
expect_fail setup --driver-dir "$fixture/driver"
unset FIXTURE_VA_FAIL
[[ $(readlink "$prefix/current") == "$first" ]]
pass 'VA-API failure keeps existing entry active'

setup --driver-dir "$fixture/driver" >"$fixture/reinstall"
[[ $(readlink "$prefix/current") != "$first" ]]
setup --rollback >"$fixture/rollback"
[[ $(readlink "$prefix/current") == "$first" ]]
pass 'repeat install and previous-version rollback'

setup --browser firefox --allow-unsandboxed-rdd --driver-dir "$fixture/driver" >"$fixture/firefox-install"
[[ ! -e $desktop/deb-browser-nvidia-chrome.desktop ]]
[[ -f $desktop/deb-browser-nvidia-firefox.desktop ]]
[[ -f $prefix/firefox-profile/user.js ]]
"$prefix/current/bin/firefox-nvidia" 'https://example.invalid/video'
grep -qx -- '--no-remote' "$FIXTURE_LOG"
grep -qx "$prefix/firefox-profile" "$FIXTURE_LOG"
grep -qx '1' "$FIXTURE_LOG"
printf '// user edit\n' >>"$prefix/firefox-profile/user.js"
setup --browser both --allow-unsandboxed-rdd --driver-dir "$fixture/driver" >"$fixture/both-install"
grep -qx '// user edit' "$prefix/firefox-profile/user.js"
setup --rollback >"$fixture/both-rollback"
[[ ! -e $desktop/deb-browser-nvidia-chrome.desktop && -f $desktop/deb-browser-nvidia-firefox.desktop ]]
pass 'Firefox profile/consent, both browsers, changed-selection rollback'

printf '# user edit\n' >>"$desktop/deb-browser-nvidia-firefox.desktop"
setup --browser firefox --allow-unsandboxed-rdd --driver-dir "$fixture/driver" >"$fixture/firefox-reinstall"
printf '# new edit\n' >>"$desktop/deb-browser-nvidia-firefox.desktop"
expect_fail setup --rollback
grep -qx '# new edit' "$desktop/deb-browser-nvidia-firefox.desktop"
pass 'rollback refuses to overwrite later desktop edits'

export XDG_DATA_HOME="$fixture/fresh"
setup --driver-dir "$fixture/driver" >"$fixture/fresh-install"
setup --rollback >"$fixture/fresh-rollback"
[[ ! -e $XDG_DATA_HOME/deb-browser-nvidia/current ]]
[[ ! -e $XDG_DATA_HOME/applications/deb-browser-nvidia-chrome.desktop ]]
pass 'first-install rollback disables own entries, preserves artifacts'

export XDG_DATA_HOME="$fixture/collision"
mkdir -p "$XDG_DATA_HOME/applications"
printf 'unrelated entry\n' >"$XDG_DATA_HOME/applications/deb-browser-nvidia-chrome.desktop"
expect_fail setup --driver-dir "$fixture/driver"
grep -qx 'unrelated entry' "$XDG_DATA_HOME/applications/deb-browser-nvidia-chrome.desktop"
pass 'unmanaged desktop collision preserved'
printf 'Fixtures retained at %s\n' "$fixture"
