# 诊断 NVIDIA 硬件视频解码

先验证系统能力，再检查浏览器实际播放的视频。每个步骤回答一个问题；前一步通过不代表后一步已经通过。

## 1. 确认正在测试的浏览器

记录完整浏览器版本、安装渠道和显示协议。deb、Snap、Flatpak 的驱动可见范围不同；两个 Firefox 渠道也可能使用不同可执行文件。

可以只读查询系统包：

```sh
dpkg-query -W 'firefox*' 'google-chrome*' 'nvidia-driver-*' nvidia-vaapi-driver
```

在浏览器自身的版本页面确认实际运行版本。Firefox 的 `about:support` 可确认窗口协议、图形与媒体信息；Chrome 的 `chrome://version` 与 `chrome://gpu` 可确认版本及图形后端。报告中保留必要的版本和后端名称，不复制个人 profile 路径或完整启动命令。

本次验证基线为 Ubuntu、deb Firefox 158、deb Chrome 155、NVIDIA 615-open、`nvidia-vaapi-driver` 0.0.14；各浏览器完整版本和测试结果由专项文档补充。

## 2. 确认 NVIDIA 驱动正常

```sh
nvidia-smi
```

确认 GPU 型号与驱动版本，并检查运行过程中是否出现明确的驱动错误。浏览器进程出现在 GPU 进程表中只能说明它使用了某项 GPU 功能，不能据此判断视频解码器。

## 3. 确认 VA-API 解码能力

```sh
LIBVA_DRIVER_NAME=nvidia NVD_BACKEND=direct vainfo
```

检查输出是否加载 NVIDIA VA-API 驱动，并记录需要测试的 profile，例如 H.264、VP9、AV1。解码能力通常对应 `VAEntrypointVLD`；只有名称相似的 codec 条目，不能说明所有位深、色度格式和 profile 都得到支持。

如果初始化失败，先检查 VA-API 驱动的安装和版本、NVIDIA 设备权限，以及测试命令使用的显示环境。不要通过复制另一台机器的共享库来混装驱动。`vainfo` 声明能力后仍需浏览器播放验证。

`nvidia-vaapi-driver` 将 VA-API 解码请求转换为 NVDEC。它与网页渲染路径、NVENC 编码路径是不同部分；上游只支持解码。[项目说明](https://github.com/elFarto/nvidia-vaapi-driver)

## 4. 检查浏览器的实际解码器

### Firefox

打开 `about:support`，记录图形后端、窗口协议、硬件视频解码支持情况及相关失败原因。随后播放已知格式的视频，确认 Firefox 实际启用硬件解码，并与 GPU 解码活动对应。

设置页面的“启用”状态和能力表只表示配置或能力，不能单独证明某个视频正在硬解。本次 Firefox 158 使用 0.0.14 且保留 RDD 沙箱时，能力信息报告 HWDEC，但实际解码器初始化被拒绝。使用 0.0.18 的隔离测试仅关闭 RDD 沙箱后，已观察到实际 VA-API DMA-BUF 解码；H.264、VP9、AV1 三种样本均正常播放并有实际 VA-API 解码表面证据。用户明确接受这一沙箱取舍后，正式启动器已安装；已有浏览器进程需重开才能采用配置。详见 [Firefox 专项文档](firefox.md)。

### Chrome

先看 `chrome://gpu` 中的图形和视频能力，再打开 `chrome://media-internals`，找到正在播放的测试视频对应的播放器，检查解码器名称与平台解码标志。字段名会随浏览器版本变化，应记录实际出现的字段。

本次 Chrome 155 使用系统 VA-API 驱动 0.0.14 的 H.264 与 VP9 测试已观察到 `VaapiVideoDecoder` 和 `platform=true`。AV1 在该驱动上失败并回退 `Dav1d`。官方 0.0.18 的浏览器专用构建已完成 H.264、VP9 和 AV1 回归，三种样本均显示 `VaapiVideoDecoder` 和 `platform=true`；对应启动器已安装。分别记录驱动版本，不能把一个版本、格式的成功扩展到其他组合。

同时检查各进程的沙箱状态。当前 Chrome 测试报告 GPU 进程 `sandboxed=false`，渲染进程的 seccomp 已启用。即使启动命令没有显式的禁用沙箱参数，也不能把它写成 GPU 沙箱已启用。这个状态需在专项文档独立说明。

若当前播放器显示软件解码器，应检查它实际请求的视频 codec/profile、浏览器版本、所用 VA-API 驱动和专项配置。网页可以动态选择编码格式；清晰度相同不代表 codec 相同。

## 5. 用播放过程验证 GPU 解码活动

播放公开测试样本时运行：

```sh
nvidia-smi dmon -s u
```

关注对应 GPU 的 `dec` 列；暂停或结束播放后观察变化。`sm`、显存和总 GPU 占用不能代替解码器指标。后台的视频或其他程序可能共用解码器，因此应结合当前播放器的证据判读。

短视频、低负载或采样时机可能导致读数为 0；部分 GPU/驱动也可能显示 `N/A`。不要仅凭一个读数下结论。需要观察一段播放时间，并同时保存人工整理的浏览器解码器摘要。[NVIDIA 指标说明](https://docs.nvidia.com/deploy/nvidia-smi/)

## 6. 记录可复现结果

每项测试分别填写下面的字段：

| 字段 | 内容 |
| --- | --- |
| 浏览器 | 完整版本、deb 安装来源 |
| 系统 | Ubuntu 版本、显示协议、显示缩放 |
| GPU 与驱动 | GPU 型号、NVIDIA 驱动版本、VA-API 驱动版本 |
| 视频 | 公开来源或生成方法、codec/profile、位深、分辨率、帧率 |
| 运行证据 | 实际解码器、平台解码标志、GPU 解码活动 |
| 结果 | 已验证、失败或证据不足 |
| 复现 | 必需的设置和启动参数，去除个人路径及令牌 |
| 回滚 | 还原被修改的设置和启动器 |

硬件编码需使用独立的录制、WebRTC 或导出测试，确认实际编码器和 `enc` 活动。播放测试通过不代表编码已加速。

公开仓库保留整理后的事实和配置示例，不保存浏览器 profile、完整 `media-internals` 导出、完整 `about:support` 导出或用户日志。这些内容可能包含个人路径、网页地址及账号信息。
