# Firefox：能力表与实际 NVIDIA 解码

## 本次结果

Firefox Developer Edition 158.0b5 deb、NVIDIA 615.71.09、原生 Wayland，官方 `nvidia-vaapi-driver` v0.0.18 独立安装目录。H.264、VP9、AV1 的 1080p30 合成视频各播放 10 秒，日志确认 VA-API 解码表面；正式启动入口的独立 AV1 复测也确认 Wayland 和 305 个实际 VA-API 解码表面（302 帧、1 丢帧）。帧统计见 [脱敏验证摘要](../examples/firefox-validation.json)。测试使用独立空 profile，未访问日常浏览记录；本机桌面以 root 运行，测试也在该会话，不能据此保证普通用户所有组合都已验证。

VP8、HEVC 在能力表中报告 HWDEC，但未做此次实际播放验证。音频格式通常由 CPU 解码；其硬解栏不支持不是 NVIDIA 视频硬解失败。该 VA-API 驱动不提供 NVENC 编码，视频硬编码栏也不会因此全部变为支持。

## 定位过程

1. `vainfo` 成功只证明 VA-API 声明能力。
2. Firefox 默认把 Linux NVIDIA 硬解列入阻止名单；测试启用 `media.hardware-video-decoding.force-enabled` 后，能力表显示 HWDEC。
3. 实际播放仍失败：保留 RDD 沙箱时，驱动明确记录 `Potential Firefox sandbox detected, failing to init`，随后 `vaInitialize failed`。所以“能力表支持”本身还不能作为完成依据。
4. 在独立测试进程按上游要求设置 `MOZ_DISABLE_RDD_SANDBOX=1` 并采用 v0.0.18，观察到 913 个 VA-API DMABuf 解码表面，H.264/VP9/AV1 均正常播放。
5. 启动环境原本含 `GDK_BACKEND=x11`。显式 `GDK_BACKEND=wayland` 和 `MOZ_ENABLE_WAYLAND=1` 后，`about:support` 的窗口协议确认为 Wayland。

## 安全取舍与日常启用

**`MOZ_DISABLE_RDD_SANDBOX=1` 关闭 RDD 媒体解码进程沙箱，会降低恶意媒体触发解码漏洞时的隔离保护。** 它不等于关闭全部浏览器沙箱；仍不应把这个改动说成没有安全影响。[驱动上游配置说明](https://github.com/elFarto/nvidia-vaapi-driver#firefox)

日常配置需要明确接受此取舍。本项目的启动示例默认拒绝执行，需显式设置 `FIREFOX_NVIDIA_ALLOW_UNSANDBOXED_RDD=1`。本机用户明确接受这一取舍后，已安装 Firefox 专用入口及配置，并保存回滚备份。已有浏览器进程需正常退出再启动，才会采用新环境。另一方案是保留 RDD 沙箱，使用 Intel 核显解码，需另行实测。

保存工作并正常退出 Firefox，在目标 profile 的 `user.js` 里备份后合并以下设置（不要覆盖整个现有文件）：

```javascript
user_pref("media.hardware-video-decoding.enabled", true);
user_pref("media.hardware-video-decoding.force-enabled", true);
user_pref("media.rdd-ffmpeg.enabled", true);
```

然后在普通桌面用户中使用示例：

```sh
FIREFOX_NVIDIA_ALLOW_UNSANDBOXED_RDD=1 \
FIREFOX_BINARY=firefox-devedition \
bash scripts/firefox-nvidia.sh
```

独立驱动安装方法见 [Chrome 文档](chrome.md)。环境变量仅作用于此次浏览器及子进程，不写全局 `/etc/environment`。NVIDIA PRIME 选择会在电池供电时也使用独显，可能增加耗电。

重新运行浏览器后，检查 `about:support` 的窗口协议与媒体能力，播放已知编码视频并查看 `MOZ_LOG=PlatformDecoderModule:5,Dmabuf:4` 日志中的实际 VA-API 解码表面。日志可能带播放地址，不要原样公开。

## 回滚

正常退出 Firefox；恢复 `user.js` 备份，恢复原启动入口，移除该入口中的 NVIDIA 与 RDD 环境变量。独立驱动目录可保留而不再引用，系统原有 VA-API 驱动不被本项目覆盖。
