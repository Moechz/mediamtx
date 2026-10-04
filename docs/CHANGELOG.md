# Changelog

本项目遵循“上游版本-打包迭代号”的版本口径（如 `1.21.1-1`）。
每次商店提交严格递增迭代号；Release tag = `v<完整版本>`。

## [1.21.1-1] — 首发

上游：MediaMTX `v1.21.1`（commit `048255986f7e04b859b4c4efe651448ec785ecd4`，MIT）

### 新增
- 首个 TOS 7 deb 包（WebUI External Open，路由 `/mediamtx/`）。
- 自带**状态控制台**（单文件静态页，无外部资源）：列出活动路径、跳转官方 HLS 播放页、
  经网关调用完整管理 API。
- 管理 API(9997)/metrics(9998)/playback(9996) 仅回环；媒体端口
  RTSP 8554/TCP+8000-8001/UDP、RTMP 1935、HLS 8888、WebRTC 8889+8189/UDP、SRT 8890/UDP
  对 LAN 开放。
- 默认鉴权：匿名读 + 认证写（安装时随机生成发布密码，root 0600 落盘）。
- 23 语言 `app.lang`、双语隐私政策、`PROVENANCE.md` 溯源材料。
- 加固 systemd 单元（非 root、空能力集、只读系统、可选 NNP 降级探测）。
- 公开 CI 从上游源码 **bit-reproducible** 构建（两次独立构建字节一致）+ `SHA256SUMS`
  双层 pin 校验。

### 说明
- 真机验证（TOS 7，systemd/dpkg，x86_64）：安装/启动/端口/网关路由/控制台/API/
  匿名推流拒绝/认证推流/HLS 播放/remove 保留/purge 全清 —— 全项通过。
- 已知取舍见 `docs/DESIGN_DECISIONS.md`（媒体端口开放、RTSP UDP+TCP、默认关闭
  MoQ/pprof/playback）。
