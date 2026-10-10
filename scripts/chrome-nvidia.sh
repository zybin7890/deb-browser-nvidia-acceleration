#!/usr/bin/env bash
# Process-local NVDEC/VA-API launcher for Chrome/Chromium on a Wayland session.
set -euo pipefail
if [[ ${EUID:-$(id -u)} == 0 ]]; then
  echo 'Run Chrome as a regular desktop user; its sandbox requires this.' >&2
  exit 1
fi
chrome_binary=${CHROME_BINARY:-google-chrome-stable}
vaapi_dir=${CHROME_NV_VAAPI_DIR:-/usr/local/lib/browser-nvidia-vaapi}
if [[ ! -r "$vaapi_dir/nvidia_drv_video.so" ]]; then
  echo "Missing private VA-API driver: $vaapi_dir/nvidia_drv_video.so" >&2
  exit 1
fi
render_node=${CHROME_NV_RENDER_NODE:-}
if [[ -z "$render_node" ]]; then
  for node in /sys/class/drm/renderD*; do
    if [[ -r "$node/device/vendor" && $(<"$node/device/vendor") == 0x10de ]]; then
      render_node=/dev/dri/${node##*/}
      break
    fi
  done
fi
if [[ -z "$render_node" || ! -r "$render_node" || ! -w "$render_node" ]]; then
  echo 'No accessible NVIDIA DRM render node; check device permissions.' >&2
  exit 1
fi
# Applies to this process and its children only. This explicitly selects NVIDIA,
# including on battery; it does not change the desktop or other app environments.
export LIBVA_DRIVER_NAME=nvidia
export LIBVA_DRIVERS_PATH="$vaapi_dir"
export NVD_BACKEND=direct
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __VK_LAYER_NV_optimus=NVIDIA_only
exec "$chrome_binary" \
  --ozone-platform=wayland \
  --enable-wayland-ime --wayland-text-input-version=3 \
  --use-gl=angle --use-angle=gl \
  --render-node-override="$render_node" \
  --enable-features=VaapiOnNvidiaGPUs,VaapiIgnoreDriverChecks \
  "$@"
