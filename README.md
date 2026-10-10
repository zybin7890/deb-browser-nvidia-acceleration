# deb 浏览器的 NVIDIA 硬件视频加速

记录 Ubuntu 上 deb 安装的 Firefox 和 Chrome 使用 NVIDIA 硬件视频解码的配置、验证方法和已知边界。目标是让一次修复能被复现，并明确哪些结果已验证、哪些仍待确认。

这里公开的是修复方法和原创工具；各浏览器、NVIDIA 驱动与 VA-API 驱动仍遵循各自的许可证。

## 当前验证状态

记录日期：2026-10-10。以下结果来自同一测试环境，不代表所有版本或所有网站的视频都可硬解。

| 浏览器 | VA-API 驱动 | 编码格式 | 当前证据 | 状态 |
| --- | --- | --- | --- | --- |
| Chrome 155，deb | 0.0.14 | H.264 | 播放时报告 `VaapiVideoDecoder`，`platform=true` | 已观察到平台解码路径 |
| Chrome 155，deb | 0.0.14 | VP9 | 播放时报告 `VaapiVideoDecoder`，`platform=true` | 已观察到平台解码路径 |
| Chrome 155，deb | 0.0.14 | AV1 | 解码失败后回退到 `Dav1d` | 此测试使用软件解码 |
| Chrome 155，deb | 官方 0.0.18，浏览器专用构建 | H.264 / VP9 / AV1 | 三种样本均报告 `VaapiVideoDecoder`，`platform=true` | 三种格式均已验证平台解码 |
| Firefox 158，deb | 0.0.14，RDD 沙箱保留 | 已测试样本 | 能力信息报告 HWDEC，实际解码器初始化被拒绝 | 未确认实际硬解 |
| Firefox 158，deb | 官方 0.0.18，隔离测试且仅关闭 RDD 沙箱 | H.264 / VP9 / AV1 | 913 个实际 VA-API DMA-BUF 解码表面，三种样本正常播放 | 三种格式均已验证实际硬解 |
| 两种浏览器 | — | 视频编码 | 本项目尚未测试 | 待验证 |

环境基线：Ubuntu 26.04.1、NVIDIA 615-open 驱动、系统 `nvidia-vaapi-driver` 0.0.14。Chrome 的浏览器专用 0.0.18 驱动和启动器已安装，三种编码格式均通过测试；没有据此替换所有应用使用的系统 VA-API 驱动。

本次 Chrome 测试报告 GPU 进程 `sandboxed=false`，同时渲染进程的 seccomp 已启用。启动器没有添加禁用沙箱参数；这些事实不等于 GPU 沙箱已启用。解码结果与各进程的沙箱状态分别记录。

Firefox 的 0.0.18 结果来自隔离测试，并包含关闭 RDD 沙箱这一例外。用户明确接受该取舍后，Firefox 日常入口已安装，并保存回滚备份。已有浏览器进程需要正常退出再启动，才会采用新环境。

## 先分清三种加速

| 路径 | 典型任务 | 需要确认的证据 |
| --- | --- | --- |
| GPU 渲染 | 网页合成、WebGL、页面动画 | 渲染器和合成后端确实使用 NVIDIA GPU |
| 硬件视频解码 | 播放 H.264、VP9、AV1 视频 | 当前播放的解码器，以及对应 GPU 的解码活动 |
| 硬件视频编码 | WebRTC、录制、视频导出 | 当前编码器，以及对应 GPU 的编码活动 |

浏览器出现在 `nvidia-smi` 中、GPU 内存增加，或页面显示“Hardware accelerated”，都不能单独证明当前视频在硬解。`nvidia-vaapi-driver` 使用 NVDEC 提供 VA-API 解码；其上游明确说明它不提供视频编码。[上游说明](https://github.com/elFarto/nvidia-vaapi-driver#codec-support)

## 如何验证

1. 检查驱动及 VA-API 能力：`nvidia-smi`，然后运行 `LIBVA_DRIVER_NAME=nvidia NVD_BACKEND=direct vainfo`。这确认驱动加载和声明的编码格式，不等于浏览器已经使用它。
2. Firefox 查看 `about:support` 的图形与媒体信息；Chrome 查看 `chrome://gpu`，再在播放时检查 `chrome://media-internals` 中当前播放器的解码器。
3. 使用已知编码格式的测试视频逐项播放，记录解码器和平台解码标志；同时用 `nvidia-smi dmon -s u` 观察 `dec` 活动。将播放、暂停和关闭测试视频的变化对应起来。
4. 可用 [合成测试视频生成脚本](scripts/generate-test-media.sh) 准备 H.264、VP9、AV1 样本。对每个浏览器、编码格式分别记录结果。AV1 成功不自动证明 H.264 成功，反之亦然。

NVIDIA 的监控指标会因 GPU、驱动和采样方式而不同；`N/A` 或一次 0% 读数不足以否定硬解，需要结合浏览器的运行时证据。[NVIDIA SMI 文档](https://docs.nvidia.com/deploy/nvidia-smi/)

## 文档

- [诊断步骤与证据判读](docs/diagnosis.md)
- [Firefox 专项配置与验证](docs/firefox.md)，[显式选择的启动示例](scripts/firefox-nvidia.sh)，[脱敏验证摘要](examples/firefox-validation.json)。
- [Chrome 专项配置与验证](docs/chrome.md)，[启动器](scripts/chrome-nvidia.sh)，[脱敏验证摘要](examples/chrome-validation.json)。

配置应优先局限于浏览器自身的启动器与设置。专项文档会记录所需版本、修改项、验证方法和回滚方式；主文档不把未验证的参数组合当作通用解法。

## 发布和贡献

提交问题时请提供操作系统、浏览器、GPU、驱动、VA-API 驱动版本，以及视频编码格式和脱敏后的解码器摘要。使用公开测试视频或自己生成的样本，保留可复现的步骤。

仓库仅收录原创说明、配置示例和脚本。浏览器 profile、登录信息、个人播放地址、完整诊断日志与内存转储都不应提交。原创内容采用 [MIT 许可证](LICENSE)，第三方组件不因此改变许可证。
