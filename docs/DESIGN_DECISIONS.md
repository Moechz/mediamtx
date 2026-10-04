# Design Decisions — MediaMTX for TOS 7

决策台账：记录不可回退 / 有取舍的决定、依据与反转过程。新决策追加编号，不删旧条目。

---

## D-001 打开方式：WebUI External Open + 自带状态控制台

**背景**：MediaMTX 无内置管理 UI（上游只有按路径的 WebRTC/HLS 播放页与 REST API），
TOS 应用子类型允许 “No UI Service”，也允许 External Open。

**决定**：采用 **External Open**（`open_path: true` + `path: "/mediamtx/"`，无 `type` 字段），
并随包提供一个**自研静态状态控制台**（`webui.bz2` → `/usr/local/mediamtx/index.html`），
经 TOS 网关暴露；控制台通过 `/mediamtx/api/` 调 MediaMTX 官方 API，列出活动路径并
跳转官方 HLS 播放页。

**理由**：
1. 本仓库已有 5+ deb 应用走 `/<appid>/` 路由并过审，链路成熟（打包指南坑 37：
   External Open 的 `path` 用路由而非 `http://${ip}:port`）。
2. 纯 "No UI Service" 会让商店用户看不到任何入口，API 也无从发现；
   控制台用最小代价（单文件、无外部资源、纯文本可审计）补齐可发现性。
3. 控制台不引入任何第三方前端依赖（避免 V6/供应链问题）。

**代价**：多了一个需维护的静态页；命名空间与 API 反代约定随之固定。

---

## D-002 端口模型：媒体面对 LAN，管理面仅回环

**决定**：
| 面 | 端口 | 绑定 |
|---|---|---|
| RTSP | 8554/TCP + 8000/UDP(RTP) + 8001/UDP(RTCP) | `0.0.0.0` |
| RTMP | 1935/TCP | `0.0.0.0` |
| HLS | 8888/TCP | `0.0.0.0` |
| WebRTC | 8889/TCP + 8189/UDP(ICE) | `0.0.0.0` |
| SRT | 8890/UDP | `0.0.0.0` |
| API | 9997/TCP | `127.0.0.1` |
| metrics | 9998/TCP | `127.0.0.1` |
| playback | 9996/TCP | `127.0.0.1`（默认关闭） |

**理由**：流媒体服务器的核心价值就是让摄像头/编码器推流、播放器拉流；把媒体端口
锁回环会让应用完全失去功能。管理面（可改配置、可看指标）不需要对外，收紧到回环后
经 TOS 网关（带 TOS 账号认证）访问，兼顾安全与可用。官方《Review Standards》只要求
“不占用系统保留端口、不暴露多余端口”，媒体端口均为功能必需。

**放弃的备选**：全部回环（应用变废）；媒体面也走网关（RTSP/RTMP/SRT/WebRTC ICE
无法经 HTTP 网关代理）。

---

## D-003 鉴权默认值：匿名读 + 认证写

**决定**：默认 `authInternalUsers`：
- `any`（空密码）：`read` + `playback`（浏览器 HLS/WebRTC、RTSP 拉流免密）
- `publisher`（随机密码，安装时生成）：`publish`
- `any` + `ips: [127.0.0.1, ::1]`：`api` + `metrics`（网关反代即来自回环）

密码只写 `/var/lib/mediamtx/publisher_password.txt`（root 0600），绝不进日志（F10）。

**理由**：`0.0.0.0` + 完全无认证是安全审核的高风险项（打包指南坑 38）。在“开箱即用”
与“不裸奔推流”之间取平衡：观看零门槛，推流需凭据。需要连观看也鉴权时，用户改
`mediamtx.yml` 即可（README / `mediamtx.lang` 已说明）。

**反转记录**：曾考虑完全沿用上游默认（匿名读+匿名写）以“贴近官方”，但平台安全规范
优先于上游默认（坑 44 教训）。

---

## D-004 配置放在数据目录并热加载

**决定**：`ExecStart=/usr/local/mediamtx/bin/mediamtx /var/lib/mediamtx/mediamtx.yml`，
`WorkingDirectory=/var/lib/mediamtx`。首装由 `mediamtx.yml.example` 生成，
`sed` 注入随机发布密码；升级只在文件不存在时生成，永不覆盖。

**理由**：配置属于用户数据（应随 `apt remove` 保留、`purge` 删除）；MediaMTX 原生
watch 配置文件并在修改后热加载，放在数据目录便于用户编辑；相对路径产物（录制、日志）
也落到数据目录，`ProtectSystem=strict` 下只放开 `/var/lib/mediamtx`。

---

## D-005 保留上游 `paths.all_others`（任意路径按需创建）

**背景**：MediaMTX 1.21 默认**不**自动创建未在 `paths:` 中声明的路径；首版精简配置
未写 `paths:`，导致 `path 'cam1' is not configured`（真机实测）。

**决定**：默认配置保留 `paths: { all_others: }`，即上游默认的“任意路径名按需自动创建”。

**理由**：NAS 用户期望“随便起个路径名就能推流”；逐条声明路径对中转底座场景过于繁琐。
需要严格白名单时用户可在 `paths` 下显式声明并删除 `all_others`。

---

## D-006 RTSP 传输：UDP + TCP（放弃 TCP-only）

**背景**：默认 `rtspTransports: [udp, multicast, tcp]` 会在启动时额外监听 8000/UDP、
8001/UDP。曾为压缩端口面改成 `[tcp]`，真机实测 **ffmpeg 默认 UDP 推流被 461
Unsupported Transport 拒绝**，而多数摄像头/NVR 默认也用 UDP。

**决定**：`rtspTransports: [udp, tcp]`（去掉组播，保留 UDP 单播与 TCP 交错）。

**理由**：8000/8001 是 RTSP 协议的标准 RTP/RTCP 端口，属功能必需；去掉组播已能减少
不必要的监听面。TCP-only 的功能回归不可接受。

---

## D-007 二进制：公开 CI 从上游源码 bit-reproducible 构建

**决定**：不使用上游预编译产物。`build-upstream.yml` 从上游 tag 源码、固定
Go 1.26.8、`CGO_ENABLED=0`、`-trimpath`、无 UPX 构建；**每个架构独立构建两次并断言
字节一致**，`SHA256SUMS` 随 `build-v*` Release 发布；`config.env` 再 pin 一次，
`fetch` 阶段双层校验。

**理由**：V6（不得携带无审计来源的预编译 ELF）的判据是“任何人可用公开源码+配方重建
位级一致产物”（坑 32）。MediaMTX 构建无时间戳注入（版本来自 git tag 的 `go generate`），
天然具备可复现性，因此直接走**强路线**（位级可复现），比 alist 的“哈希 pin + 公开 CI”
弱路线更稳。

**已实证**：本机用 go1.26.8 以两个独立 `GOCACHE` 构建，sha256 相同
（`ca0d9e52…f59cf`，见 assets/PROVENANCE.md）。

---

## D-008 语言文件：23 语超集

**决定**：`mediamtx.lang` 提供 23 个语言节点：官方真机口径 14 语（含 `hu-hu`）+
官方英文文档口径的补充语种（`ar-sa cs-cz he-il id-id nb-no nl-nl sv-se th-th vi-vn`）。
未翻译语种按规范填英文。

**理由**：两个“14 语”口径不一致（打包指南 §二），23 语超集同时覆盖。

---

## D-009 署名分工

**决定**：`config.ini.publisher = "Moechz"`（打包/发布者）；`mediamtx.lang` 的
`auth = "bluenviron"`（上游作者/组织）；`DEBIAN/control` 的 `Maintainer = Moechz`
（坑 49 表格）。

---

## D-010 默认关闭 MoQ / pprof / playback

**决定**：`moq: false`、`pprof: false`、`playback: false`。

**理由**：MoQ 会额外监听 8892(TCP+UDP)/8893(UDP) 且需要自签证书（会在应用目录写
`auto.key/auto.crt`）；pprof 是调试面；playback 需要远端录制源。三者按需由用户开启，
避免多余端口与运行时落盘。
