#!/usr/bin/env bash
# Process-local launcher. Opt-in is required because NVIDIA VA-API needs an
# unsandboxed RDD process; the content sandbox is not disabled by this script.
set -euo pipefail
if [[ ${FIREFOX_NVIDIA_ALLOW_UNSANDBOXED_RDD:-0} != 1 ]]; then
  echo 'NVIDIA VA-API requires disabling the RDD media sandbox in this setup.' >&2
  echo 'Review docs/firefox.md; explicitly opt in with FIREFOX_NVIDIA_ALLOW_UNSANDBOXED_RDD=1.' >&2
  exit 2
fi
if [[ ${EUID:-$(id -u)} == 0 ]]; then
  echo 'Run your daily browser as a regular desktop user.' >&2
  exit 1
fi
firefox_binary=${FIREFOX_BINARY:-firefox}
command -v -- "$firefox_binary" >/dev/null || { echo "Browser not found: $firefox_binary" >&2; exit 1; }
[[ -n ${WAYLAND_DISPLAY:-} ]] || { echo 'Run this launcher in a native Wayland desktop session.' >&2; exit 1; }
user_vaapi_dir=${XDG_DATA_HOME:-$HOME/.local/share}/deb-browser-nvidia/current/lib
vaapi_dir=${FIREFOX_NV_VAAPI_DIR:-$user_vaapi_dir}
if [[ -z ${FIREFOX_NV_VAAPI_DIR:-} && ! -r $vaapi_dir/nvidia_drv_video.so ]]; then
  vaapi_dir=/usr/local/lib/browser-nvidia-vaapi
fi
[[ -r "$vaapi_dir/nvidia_drv_video.so" ]] || { echo 'Private VA-API driver is missing.' >&2; exit 1; }
export GDK_BACKEND=wayland MOZ_ENABLE_WAYLAND=1
export LIBVA_DRIVER_NAME=nvidia LIBVA_DRIVERS_PATH="$vaapi_dir" NVD_BACKEND=direct
export __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only
export MOZ_DISABLE_RDD_SANDBOX=1
exec "$firefox_binary" "$@"
