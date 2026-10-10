# Firefox 播放视频时的 Wayland DMA-BUF 导入崩溃

## 问题与对照测试

开启 NVIDIA 硬解后，仍可能发生以下错误：

```text
zwp_linux_buffer_params_v1: error 7: importing the supplied dmabufs failed
```

这个错误属于解码图像交给 Wayland 合成器显示的路径。驱动能解码，并不保证显示合成器能导入对应格式与 modifier。

本次用户资料含 `gfx.color_management.hdr=true`，Linux 默认为 false。独立空 profile 配置相同 HDR 开关，播放本机生成的 10-bit VP9 Profile 2 视频，复现了相同错误和浏览器退出。关闭 HDR 后，同一视频正常播放；H.264、AV1 回归也正常，三个样本共记录 918 个实际 VA-API DMABuf 解码表面。

另测元数据完整的 HEVC Main 10 / BT.2020 / PQ 样本：关闭 HDR 输出后，301 帧、0 丢帧，日志有 308 个 VA-API 解码表面。完整脱敏统计见 [验证 JSON](../examples/firefox-dmabuf-validation.json)。VP9 样本只有 10-bit 与 BT.2020 matrix，解析的 WebM 未保留 transfer/primaries，不能将它描述为已验证完整 HDR 元数据的样本。

## 本次调整

备份目标 profile 的 `user.js`，合并以下设置：

```javascript
user_pref("gfx.color_management.hdr", false);
user_pref("gfx.color_management.hdr.force_enabled", false);
```

恢复 Linux 默认 SDR 输出，避免本次触发的 HDR 视频表面直接合成路径。NVIDIA VA-API 解码与原生 Wayland 保留，RDD 沙箱取舍仍遵循 [Firefox 文档](firefox.md)。修改后需正常退出并重开浏览器。

代价是浏览器不再启用 HDR 输出；HDR 文件可按 SDR 路径显示。该对照验证只证明本次复现的崩溃被避开，不能保证所有网站、格式与 GPU 崩溃都解决。

旧 `gfx.webrender.compositor` 参数在新版 Wayland 路径已不再用于选择该功能，不应照搬旧教程。当前安装的 Firefox 158 使用 `gfx.color_management.hdr` 名称；更老版本的配置名称可能不同。[Mozilla 参数来源](https://github.com/mozilla-firefox/firefox/blob/main/modules/libpref/init/StaticPrefList.yaml)，[Wayland compositor 参数调整](https://bugzilla.mozilla.org/show_bug.cgi?id=1957568)。

Mozilla 曾记录并修复 KDE 的 HDR P010 modifier 导入问题；那个旧问题已在 Firefox 141 修复，不能把本次 Firefox 158 的复现直接判为同一个未修复 bug。另有新近 NVIDIA HDR/Vulkan 报告，但本次使用的是 VA-API，不能声称 Vulkan 是原因。[旧 KDE HDR 问题](https://bugzilla.mozilla.org/show_bug.cgi?id=1967366)，[NVIDIA HDR/Vulkan 报告](https://bugzilla.mozilla.org/show_bug.cgi?id=2076178)。

## 回滚与反馈

恢复 `user.js` 的备份并重开 Firefox即可撤销调整。若重新启用 HDR 后仍重现，请记录浏览器/驱动版本、codec、位深、色彩元数据及简短导入错误。不要上传完整 profile、浏览记录、内存转储或个人视频地址。
