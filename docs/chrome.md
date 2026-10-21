# Chrome 的 NVIDIA 视频硬件解码

验证环境：Deb 安装的 Google Chrome **155.0.8059.39**、KDE Wayland、NVIDIA RTX 5070 Ti Laptop、NVIDIA **615.71.09**、libva 2.23、`nvidia-vaapi-driver` **v0.0.18**。测试使用隔离浏览器配置和本机生成的 1080p / 30 fps 视频，没有读取日常浏览记录。

## 修复原因

当前系统原有 `nvidia-vaapi-driver 0.0.14`。在本次 Chrome 测试中 H.264、VP9 可以硬解，但 AV1 的 `cuvidDecodePicture` 返回错误，播放器随即从 `VaapiVideoDecoder` 回退到 `Dav1dVideoDecoder`。只看 `chrome://gpu` 的“Video Decode”开关不足以发现这次回退。

官方 v0.0.18 的 README 已提供 Chromium 的单缓冲区导出支持说明。将这个版本构建到独立目录，并只在浏览器进程设置 `LIBVA_DRIVERS_PATH` 后，同一 AV1 视频改为硬件解码。系统原有 VA-API 库保持不变。

## 独立构建驱动

也可在仓库根目录运行 `bash setup.sh --browser chrome --install-deps`，自动构建到用户目录并创建独立菜单入口；选项和回滚见 [一键安装](../README.md#一键安装)。下面保留手动构建方法。

优先使用发行版已经验证支持 Chromium 的新版本。需要自己构建时，依赖名称以发行版为准；上游列出的 Debian/Ubuntu 依赖包括 Meson、GCC、pkg-config、libva、EGL、DRM、NV codec headers。VP9 还需要 GStreamer codecparsers 开发文件。

```bash
sudo apt install build-essential meson ninja-build pkg-config \
  libva-dev libegl-dev libdrm-dev libffmpeg-nvenc-dev \
  libgstreamer-plugins-bad1.0-dev

git clone --depth 1 --branch v0.0.18 \
  https://github.com/elFarto/nvidia-vaapi-driver.git
cd nvidia-vaapi-driver
git rev-parse HEAD
# 本次验证的版本：982ba1c2464b9cea5a4403df8f2c5a351ca21394
meson setup build --buildtype=release
# 确认输出含 gstreamer-codecparsers-1.0: YES，否则不会编入 VP9。
meson compile -C build
sudo install -D -m 755 build/nvidia_drv_video.so \
  /usr/local/lib/browser-nvidia-vaapi/nvidia_drv_video.so
```

新 Ubuntu 的 GStreamer 开发包可能还拆分到 `libgstreamer-plugins-extra1.0-dev`。缺少 `gst/codecparsers/gstvp9parser.h` 时检查这个包。不要直接覆盖 `/usr/lib/*/dri/nvidia_drv_video.so`，否则会影响其他应用和包管理。

本次本机修复采用下载、解压所需开发包到临时构建目录的方式，未把整套开发依赖安装到系统；以上命令是面向一般用户的可复现构建流程。

## 启动 Chrome

在普通桌面用户会话运行仓库中的 [启动脚本](../scripts/chrome-nvidia.sh)：

```bash
./scripts/chrome-nvidia.sh
```

脚本自动查找 NVIDIA 的 `/dev/dri/renderD*` 节点，使用 Wayland、ANGLE OpenGL、NVIDIA VA-API direct backend，并按进程设置驱动目录。可指定浏览器和独立驱动目录：

```bash
CHROME_BINARY=chromium \
CHROME_NV_VAAPI_DIR=/path/to/private-vaapi \
./scripts/chrome-nvidia.sh
```

脚本显式选择 NVIDIA，即使在电池供电时也会使用独显，耗电可能增加。它不调整桌面 GPU 或其他应用的环境。彻底退出已有浏览器后重新通过该脚本启动，已有进程不会采用新的启动环境。

Chrome 155 所用参数为 `--use-gl=angle --use-angle=gl`、`--render-node-override`、`VaapiOnNvidiaGPUs` 和 `VaapiIgnoreDriverChecks`。这不是给所有 Chromium 版本套用的通用参数表；旧版本应查对应版本源码。

## 实际验证

播放视频时查看 `chrome://media-internals`，确认 **最终**播放器属性：

- `kVideoDecoderName` 为 `VaapiVideoDecoder`。
- `kIsPlatformVideoDecoder` 为 `true`。
- 视频持续显示帧，没有随后切换为 `Dav1dVideoDecoder` / `VpxVideoDecoder` / `FFmpegVideoDecoder`。

本次 CDP 的 Media 事件直接记录了这些属性，另有 NVIDIA VA-API 日志确认初始化 direct backend 并创建硬件解码器。去掉路径、配置目录和会话 ID 的结果见 [验证 JSON](../examples/chrome-validation.json)。

| 格式 | 旧 0.0.14 | 独立 0.0.18 |
| --- | --- | --- |
| H.264 1080p30 | VaapiVideoDecoder | VaapiVideoDecoder，平台解码=true |
| VP9 1080p30 | VaapiVideoDecoder | VaapiVideoDecoder，平台解码=true |
| AV1 1080p30 | 硬解失败，回退 Dav1d | VaapiVideoDecoder，平台解码=true |

该结果证明测试的三个 8-bit 视频使用了硬件解码；没有测试 DRM、HDR、10-bit、HEVC 或全部视频网站。`chrome://gpu` 在这台机器上仍可能显示空的 codec 列表，最终播放器解码器和帧输出更能说明实际播放路径。

## 沙箱与限制

脚本不添加 `--no-sandbox`、`--disable-gpu-sandbox` 或 `--disable-gpu`。本次内容 renderer 进程具有 `Seccomp=2`、`NoNewPrivs=1`。但 Chrome 的 GPU 进程自报 `sandboxed=false`，其 `Seccomp=0`；仅添加 `--gpu-sandbox-start-early` 也未改变这一点。因此这里不能宣称 GPU 沙箱已启用，也不把硬件解码成功等同于完整沙箱验证。

同机 Intel 独立渲染测试在视频解码前发生 Wayland DMA-BUF modifier 导入失败，不代表 Intel VA-API 驱动没有解码能力。本方案采用已经验证的 NVIDIA 路径。

## 回滚

停止使用该脚本即可恢复普通浏览器启动方式。若创建了桌面快捷方式，恢复它原来的 `Exec`；独立目录无需改回系统库。浏览器设置和日常配置数据不需要删除。

## 上游资料

- [Chromium VA-API 文档](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/docs/gpu/vaapi.md)
- [Chromium VA-API wrapper 源码](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/media/gpu/vaapi/vaapi_wrapper.cc)
- [nvidia-vaapi-driver v0.0.18 README](https://github.com/elFarto/nvidia-vaapi-driver/blob/v0.0.18/README.md)
