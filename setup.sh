#!/usr/bin/env bash
# Per-user installer. Never replaces the system VA-API driver or browser entry.
set -euo pipefail
umask 077
readonly DRIVER_COMMIT=982ba1c2464b9cea5a4403df8f2c5a351ca21394
readonly DRIVER_TAG=v0.0.18
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
prefix=${XDG_DATA_HOME:-$HOME/.local/share}/deb-browser-nvidia
applications=${XDG_DATA_HOME:-$HOME/.local/share}/applications
browser=auto
action=install
install_deps=0
allow_rdd=0
driver_dir=

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'HELP'
用法：bash setup.sh [选项]
  --browser auto|chrome|firefox|both  默认优先 Chrome，未找到时选择 Firefox
  --install-deps                    用 sudo apt-get 安装缺少的构建依赖
  --allow-unsandboxed-rdd            接受 Firefox 关闭 RDD 媒体沙箱的取舍
  --driver-dir PATH                 复用已有私有驱动，不下载或构建
  --check                           只检查环境及已安装驱动
  --dry-run                         显示安装计划，不下载、安装或写入
  --rollback                        恢复上次安装前的入口，保留驱动与备份
  --help                            显示帮助

普通用户在 Debian/Ubuntu 原生 Wayland 桌面运行；只支持本机 deb 浏览器。
安装生成独立菜单入口；Firefox 使用单独 profile，不修改日常 profile。
依赖安装之外的操作均无需 sudo；不会修改系统驱动、内核参数或默认浏览器。
HELP
}
while (($#)); do
  case $1 in
    --browser|--driver-dir)
      (($# >= 2)) || die "$1 缺少参数"
      case $1 in --browser) browser=$2 ;; --driver-dir) driver_dir=$2 ;; esac
      shift 2 ;;
    --install-deps) install_deps=1; shift ;;
    --allow-unsandboxed-rdd) allow_rdd=1; shift ;;
    --check|--dry-run|--rollback)
      [[ $action == install ]] || die '检查、预演、回滚只能选一个'
      action=${1#--}; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "未知选项：$1" ;;
  esac
done
case $browser in auto|chrome|firefox|both) ;; *) die '不支持的浏览器选项' ;; esac
[[ $(uname -s) == Linux ]] || die '请在目标 Linux 桌面运行；不支持 Windows/WSL'
[[ $EUID != 0 ]] || die '请使用普通桌面用户运行，不要 sudo bash setup.sh'
[[ $prefix == /* && $applications == /* ]] || die 'HOME / XDG_DATA_HOME 必须为绝对路径'
[[ $prefix != *$'\n'* && $prefix != *$'\r'* && $prefix != *$'\t'* && $prefix != *%* ]] || die '安装路径不支持控制字符或百分号'
command -v flock >/dev/null || die '缺少 flock（util-linux）'

desktop_path() { printf '%s/deb-browser-nvidia-%s.desktop' "$applications" "$1"; }
rollback() {
  [[ -f $prefix/.managed && -s $prefix/last-backup ]] || die '没有可回滚的安装'
  local backup name target expected actual
  backup=$(<"$prefix/last-backup")
  [[ $backup == "$prefix"/backups/* && -f $backup/ready ]] || die '回滚记录不完整'
  # Refuse to overwrite entries edited since installation.
  for name in chrome firefox; do
    target=$(desktop_path "$name")
    if [[ -f $backup/$name.removed ]]; then
      [[ ! -e $target && ! -L $target ]] || die "入口已重新创建：$target"
    fi
    if [[ -f $backup/$name.sha256 ]]; then
      [[ -f $target && ! -L $target ]] || die "菜单入口已变化：$target"
      expected=$(<"$backup/$name.sha256")
      actual=$(sha256sum -- "$target"); actual=${actual%% *}
      [[ $actual == "$expected" ]] || die "入口已被修改，请手动处理：$target"
    fi
  done
  for name in chrome firefox; do
    target=$(desktop_path "$name")
    if [[ -f $backup/$name.sha256 ]]; then
      mv -- "$target" "$backup/$name.disabled.desktop"
      if [[ -f $backup/$name.desktop ]]; then cp -p -- "$backup/$name.desktop" "$target"; fi
    elif [[ -f $backup/$name.removed ]]; then
      cp -p -- "$backup/$name.desktop" "$target"
    fi
  done
  if [[ -f $backup/current ]]; then
    ln -s -- "$(<"$backup/current")" "$prefix/current.rollback"
    mv -Tf -- "$prefix/current.rollback" "$prefix/current"
  elif [[ -L $prefix/current ]]; then
    mv -- "$prefix/current" "$backup/disabled-current"
  fi
  mv -- "$prefix/last-backup" "$backup/rolled-back"
  printf '已回滚入口；驱动、独立 Firefox profile 与备份保留在 %s\n' "$prefix"
}
if [[ $action == rollback ]]; then
  [[ -d $prefix ]] || die '尚未安装'
  exec 9>"$prefix/.lock"
  flock -n 9 || die '另一安装/回滚正在运行'
  rollback
  exit 0
fi

[[ -n ${WAYLAND_DISPLAY:-} ]] || die '未检测到 Wayland 桌面会话'
case $(uname -r) in *[Mm]icrosoft*|*[Ww][Ss][Ll]*) die 'WSL 无法代替原生 Linux 桌面验收' ;; esac
command -v nvidia-smi >/dev/null || die '找不到 nvidia-smi，请先安装并验证 NVIDIA 驱动'
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || die 'NVIDIA 驱动无法访问'
if [[ -r /sys/module/nvidia_drm/parameters/modeset ]]; then
  [[ $(</sys/module/nvidia_drm/parameters/modeset) == Y ]] || die 'nvidia_drm modeset 未启用；请按发行版文档配置后重启'
fi
find_browser() {
  local candidate resolved
  for candidate in "$@"; do
    [[ -n $candidate ]] || continue
    resolved=$(command -v -- "$candidate") || continue
    case $(readlink -f -- "$resolved") in /snap/*|/var/lib/flatpak/*) continue ;; esac
    # Ubuntu's /usr/bin/{firefox,chromium} can be a transitional Snap wrapper.
    if grep -Iq . "$resolved" && grep -Eq 'snap run|exec[[:space:]]+(/usr/bin/)?snap|/snap/bin/' "$resolved"; then continue; fi
    printf '%s\n' "$resolved"; return 0
  done
  return 1
}
chrome=$(find_browser "${CHROME_BINARY:-}" google-chrome-stable google-chrome chromium chromium-browser || true)
firefox=$(find_browser "${FIREFOX_BINARY:-}" firefox firefox-devedition || true)
if [[ $browser == auto ]]; then
  if [[ -n $chrome ]]; then browser=chrome; elif [[ -n $firefox ]]; then browser=firefox; else die '未找到本机 deb Chrome/Firefox'; fi
fi
names=()
case $browser in chrome|both) [[ -n $chrome ]] || die '未找到 deb Chrome/Chromium，可设置 CHROME_BINARY'; names+=(chrome) ;; esac
case $browser in firefox|both) [[ -n $firefox ]] || die '未找到 deb Firefox，可设置 FIREFOX_BINARY'; names+=(firefox) ;; esac
for name in "${names[@]}"; do
  binary=$chrome; [[ $name != firefox ]] || binary=$firefox
  "$binary" --version
done
printf '目标：%s；用户目录：%s；驱动：%s (%s)\n' "$browser" "$prefix" "$DRIVER_TAG" "$DRIVER_COMMIT"
if [[ $action == check ]]; then
  command -v vainfo >/dev/null || die '缺少 vainfo'
  check_dir=${driver_dir:-$prefix/current/lib}
  [[ -r $check_dir/nvidia_drv_video.so ]] || die "尚无私有驱动：$check_dir"
  LIBVA_DRIVER_NAME=nvidia LIBVA_DRIVERS_PATH="$check_dir" NVD_BACKEND=direct vainfo
  printf '环境/VA-API 检查通过。仍需浏览器播放确认实际硬解。\n'
  exit 0
fi
if [[ $browser != chrome && $allow_rdd != 1 ]]; then
  die 'Firefox 需要关闭 RDD 沙箱；阅读 docs/firefox.md 后显式传 --allow-unsandboxed-rdd'
fi
if [[ -n $driver_dir ]]; then
  [[ -r $driver_dir/nvidia_drv_video.so ]] || die '指定目录中没有可读的 nvidia_drv_video.so'
  driver_dir=$(cd -- "$driver_dir" && pwd)
fi
if [[ $action == dry-run ]]; then
  printf '计划：%s驱动 → 独立启动器 → 单独菜单入口 → VA-API 检查。\n' "${driver_dir:+复用已有}"
  [[ -n $driver_dir ]] || printf '从官方仓库下载固定提交并编译；强制检查 VP9 构建依赖。\n'
  printf '安装依赖：%s；Firefox RDD 取舍：%s；本次未写入。\n' "$install_deps" "$allow_rdd"
  exit 0
fi
for name in "${names[@]}"; do [[ -r $repo_dir/scripts/$name-nvidia.sh ]] || die '请运行完整仓库内的 setup.sh'; done
[[ ! -e $prefix || -f $prefix/.managed ]] || die "目录已存在且不属于此安装器：$prefix"
mkdir -p -- "$prefix"
exec 9>"$prefix/.lock"
flock -n 9 || die '另一安装/回滚正在运行'
touch -- "$prefix/.managed"
[[ ! -e $prefix/current || -L $prefix/current ]] || die 'current 不是安装器管理的符号链接'
for name in chrome firefox; do
  target=$(desktop_path "$name")
  [[ ! -L $target ]] || die "拒绝覆盖符号链接：$target"
  if [[ -e $target ]]; then grep -qx 'X-Deb-Browser-Nvidia=true' "$target" || die "拒绝覆盖非本项目入口：$target"; fi
done

if [[ -z $driver_dir ]]; then
  if ((install_deps)); then
    [[ -r /etc/os-release ]] || die '无法识别发行版'
    # shellcheck disable=SC1091
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in *debian*|*ubuntu*) ;; *) die '自动安装依赖仅支持 Debian/Ubuntu' ;; esac
    command -v sudo >/dev/null || die '缺少 sudo'
    sudo apt-get update
    deps=(git build-essential meson ninja-build pkg-config libva-dev libegl-dev libdrm-dev libffmpeg-nvenc-dev libgstreamer-plugins-bad1.0-dev vainfo)
    if apt-cache show libgstreamer-plugins-extra1.0-dev >/dev/null 2>&1; then deps+=(libgstreamer-plugins-extra1.0-dev); fi
    sudo apt-get install -y "${deps[@]}"
  fi
  for tool in git cc meson ninja pkg-config vainfo; do command -v "$tool" >/dev/null || die "缺少 $tool；可加 --install-deps"; done
  pkg-config --exists 'libva >= 1.8.0' egl 'libdrm >= 2.4.60' 'ffnvcodec >= 11.1.5.1' gstreamer-codecparsers-1.0 || die '构建依赖缺失（必须含 VP9 codecparsers）；可加 --install-deps'
fi
command -v vainfo >/dev/null || die '缺少 vainfo；请安装后再运行'
release=$(mktemp -d "$prefix/release.XXXXXXXX")
mkdir -p -- "$release/lib" "$release/bin"
if [[ -z $driver_dir ]]; then
  git clone --depth 1 --branch "$DRIVER_TAG" https://github.com/elFarto/nvidia-vaapi-driver.git "$release/source"
  [[ $(git -C "$release/source" rev-parse HEAD) == "$DRIVER_COMMIT" ]] || die '上游 tag 与锁定提交不一致，已停止'
  meson setup "$release/build" "$release/source" --buildtype=release --wrap-mode=nofallback
  meson compile -C "$release/build"
  driver_dir=$release/build
fi
install -m 755 -- "$driver_dir/nvidia_drv_video.so" "$release/lib/nvidia_drv_video.so"
# Fail before publishing entries if the driver cannot even initialize.
LIBVA_DRIVER_NAME=nvidia LIBVA_DRIVERS_PATH="$release/lib" NVD_BACKEND=direct vainfo
printf '%s\n' "$DRIVER_COMMIT" >"$release/upstream-commit"
if [[ -n ${driver_dir:-} && $driver_dir != "$release/build" ]]; then printf 'external driver; version not verified\n' >"$release/upstream-commit"; fi

for name in "${names[@]}"; do
  install -m 755 -- "$repo_dir/scripts/$name-nvidia.sh" "$release/bin/$name-launch.sh"
  binary=$chrome; [[ $name != firefox ]] || binary=$firefox
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'export %s_BINARY=%q\n' "${name^^}" "$binary"
    printf 'export %s_NV_VAAPI_DIR=%q\n' "${name^^}" "$release/lib"
    if [[ $name == firefox ]]; then
      printf 'export FIREFOX_NVIDIA_ALLOW_UNSANDBOXED_RDD=1\n'
      printf 'exec %q --no-remote --profile %q "$@"\n' "$release/bin/firefox-launch.sh" "$prefix/firefox-profile"
    else
      printf 'exec %q "$@"\n' "$release/bin/chrome-launch.sh"
    fi
  } >"$release/bin/$name-nvidia"
  chmod 755 "$release/bin/$name-nvidia"
done
if [[ $browser != chrome ]]; then
  mkdir -p -- "$prefix/firefox-profile"
  # This profile is project-owned. Daily Firefox profiles are never discovered/read.
  if [[ ! -e $prefix/firefox-profile/user.js ]]; then
    cat >"$prefix/firefox-profile/user.js" <<'PREFS'
user_pref("media.hardware-video-decoding.enabled", true);
user_pref("media.hardware-video-decoding.force-enabled", true);
user_pref("media.rdd-ffmpeg.enabled", true);
PREFS
  else
    printf '保留独立 profile 现有 user.js；请确认硬解设置仍已启用。\n'
  fi
fi

# Desktop Exec quoting has two layers (desktop value and Exec argument quoting).
desktop_quote() {
  local value=$1
  value=${value//\\/\\\\}; value=${value//\"/\\\"}; value=${value//\$/\\\$}; value=${value//\`/\\\`}
  value=${value//\\/\\\\}
  printf '"%s"' "$value"
}
mkdir -p -- "$applications" "$prefix/backups"
backup=$(mktemp -d "$prefix/backups/install.XXXXXXXX")
[[ ! -L $prefix/current ]] || readlink -- "$prefix/current" >"$backup/current"
for name in chrome firefox; do
  target=$(desktop_path "$name")
  [[ ! -f $target ]] || cp -p -- "$target" "$backup/$name.desktop"
done
touch -- "$backup/ready"
printf '%s\n' "$backup" >"$prefix/last-backup"
trap 'result=$?; if ((result)); then printf "安装中断，尝试恢复已发布入口。\n" >&2; (rollback) || printf "自动恢复未完成，请检查 %s\n" "$backup" >&2; fi' EXIT
ln -s -- "$release" "$prefix/current.new"
mv -Tf -- "$prefix/current.new" "$prefix/current"
for name in "${names[@]}"; do
  target=$(desktop_path "$name")
  {
    printf '[Desktop Entry]\nType=Application\nName=%s (NVIDIA VA-API)\n' "${name^}"
    printf 'Exec='; desktop_quote "$prefix/current/bin/$name-nvidia"; printf ' %%U\n'
    printf 'Icon=%s\nTerminal=false\nCategories=Network;WebBrowser;\nX-Deb-Browser-Nvidia=true\n' "$name"
  } >"$target"
  sum=$(sha256sum -- "$target"); printf '%s\n' "${sum%% *}" >"$backup/$name.sha256"
done
# A changed browser selection must not leave a stale/dangling previous menu entry.
for name in chrome firefox; do
  if [[ ! -f $release/bin/$name-nvidia && -f $backup/$name.desktop ]]; then
    mv -- "$(desktop_path "$name")" "$backup/$name.disabled.desktop"
    touch -- "$backup/$name.removed"
  fi
done
trap - EXIT
printf '\n配置已安装（尚未确认浏览器实际硬解）。请正常退出旧浏览器，再从新菜单入口启动。\n'
printf '启动器：%s/current/bin/\nFirefox 使用独立 profile；不会带入日常登录数据。\n' "$prefix"
printf '回滚：bash %q --rollback\n' "$repo_dir/setup.sh"
printf '验收：Chrome media-internals 的最终 VaapiVideoDecoder + platform=true；Firefox 实际 VA-API 表面日志；并对照 nvidia-smi dmon -s u。\n'
