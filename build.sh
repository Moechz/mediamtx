#!/usr/bin/env bash
# ============================================================
# build.sh - 把 MediaMTX 打包成 TOS 7 应用中心规范的 deb 包
#            （WebUI External Open / 新标签页模式 + 内置状态控制台）
#
# 规范依据:
#   - 官方文档仓库 https://github.com/terramaster-tos/tos-app-pkg-tools
#     （08_Deb_Development.md / 04_Package_Specification.md / 16_Review_Standards.md）
#   - 本机知识库 ~/Documents/projects/TOS-DEB-PACKAGING-GUIDE.md（真机实测坑清单）
#
# V6（不得携带无审计来源的预编译二进制）路线（强可复现版，见坑 32/43）:
#   本仓库 .github/workflows/build-upstream.yml 从上游 tag 源码构建，
#   CGO_ENABLED=0 静态、无 UPX、`-trimpath` + 固定 Go 工具链，
#   同一 job 内独立构建两次并断言字节一致（bit-reproducible）；
#   产物（含 SHA256SUMS）发布到 Release build-v<上游版本>，此处双层校验。
#
# 产物（out/）:
#   mediamtx_<版本>_<arch>.deb        完整版本名 deb（本地 apt 安装/测试用）
#   mediamtx_<platform>.deb           Release 资产名 deb（上架上传用，版本由 Release tag 表达）
#   mediamtx_<platform>.deb.sha256    上架要求的校验文件
#
# 阶段: fetch → stage → verify → deb
# 本地开发：LOCAL_BIN=/path/to/mediamtx ./build.sh all   （跳过 fetch，仅供联调，不可送审）
# ============================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.env
. "$SCRIPT_DIR/config.env"

BUILD_DIR="$SCRIPT_DIR/build"
DL_DIR="$BUILD_DIR/downloads"
STAGE_DIR="$BUILD_DIR/pkgroot"
OUT_DIR="$SCRIPT_DIR/out"
ASSETS_DIR="$SCRIPT_DIR/assets"

VERSION_FULL="${MEDIAMTX_VERSION}-${PKG_RELEASE}"

# ---------------- 目标平台（TOS / NAS 侧） ----------------
case "$TARGET_ARCH" in
  amd64)
    GONAME="amd64"
    TOS_PLATFORM="x86_64"
    ELF_ARCH="x86-64"
    PINNED_SHA256="$SHA256_TARBALL_AMD64"
    ;;
  arm64)
    GONAME="arm64"
    TOS_PLATFORM="aarch64"
    ELF_ARCH="ARM aarch64"
    PINNED_SHA256="$SHA256_TARBALL_ARM64"
    ;;
  *)
    echo "错误: 未知 TARGET_ARCH=$TARGET_ARCH（支持 amd64 / arm64）" >&2
    exit 1
    ;;
esac

# 自建产物源（V6 可复现构建）：本仓库 CI 从上游 tag 源码构建并发布
BIN_SOURCE_BASE="https://github.com/Moechz/mediamtx/releases/download/build-v$MEDIAMTX_VERSION"
TGZ="mediamtx-linux-$GONAME.tar.gz"
CHECKSUMS="SHA256SUMS"
UPSTREAM_REPO="https://github.com/bluenviron/mediamtx"
TAG="v$MEDIAMTX_VERSION"
DEB_FILE="$OUT_DIR/${APP_ID}_${VERSION_FULL}_${TARGET_ARCH}.deb"
STORE_DEB="$OUT_DIR/${APP_ID}_${TOS_PLATFORM}.deb"       # Release 资产命名（无版本）

MAINTAINER_FULL="$MAINTAINER_NAME <$MAINTAINER_EMAIL>"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

fetch() { # fetch <url> <dest-file>（多次重试 + 断点续传）
  local url=$1 dest=$2 attempt=0
  if [ -s "$dest" ]; then
    log "已缓存: $(basename "$dest")"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  log "下载: $(basename "$dest")"
  while [ $attempt -lt 8 ]; do
    attempt=$((attempt + 1))
    if curl -4 -fL --retry 5 --retry-delay 3 --retry-all-errors \
         --connect-timeout 30 -C - -o "$dest.part" "$url"; then
      mv "$dest.part" "$dest"
      return 0
    fi
    rm -f "$dest.part"
    warn "下载失败(第 $attempt 次): $(basename "$dest")，10 秒后重试..."
    sleep 10
  done
  die "下载失败: $url"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

normalize_text() { # 规范要求：文本文件 LF 行尾 + UTF-8 无 BOM
  python3 - "$@" <<'PYEOF'
import sys
for p in sys.argv[1:]:
    with open(p, 'rb') as f:
        data = f.read()
    if data.startswith(b'\xef\xbb\xbf'):
        data = data[3:]
    data = data.replace(b'\r\n', b'\n').replace(b'\r', b'\n')
    with open(p, 'wb') as f:
        f.write(data)
PYEOF
}

# ============================================================
# 阶段: fetch
# ============================================================
stage_fetch() {
  if [ -n "${LOCAL_BIN:-}" ]; then
    [ -x "${LOCAL_BIN}" ] || die "LOCAL_BIN 不可执行: $LOCAL_BIN"
    log "LOCAL_BIN 模式：跳过下载，使用本地二进制 $LOCAL_BIN（仅供联调，产物不可送审）"
    return 0
  fi
  mkdir -p "$DL_DIR"

  # 1. 自建 tarball（CI 从上游 tag 源码可复现构建）
  fetch "$BIN_SOURCE_BASE/$TGZ" "$DL_DIR/$TGZ"
  # 2. 同批发布的 SHA256SUMS
  fetch "$BIN_SOURCE_BASE/$CHECKSUMS" "$DL_DIR/$CHECKSUMS"
  # 3. 上游 LICENSE（MIT）
  fetch "https://raw.githubusercontent.com/bluenviron/mediamtx/$TAG/LICENSE" "$DL_DIR/LICENSE"

  log "校验 sha256（对照 CI SHA256SUMS 与 config.env pin）..."
  local want_sum got_sum want_pin
  want_sum=$(grep -a "[ /]${TGZ}\$" "$DL_DIR/$CHECKSUMS" | tail -1 | awk '{print $1}')
  [ -n "$want_sum" ] || die "SHA256SUMS 中找不到 $TGZ"
  got_sum=$(sha256_of "$DL_DIR/$TGZ")
  [ "$got_sum" = "$want_sum" ] || die "sha256 与 CI SHA256SUMS 不符: $TGZ（want=$want_sum got=$got_sum）"
  log "  sha256 ok（CI SHA256SUMS 一致）"

  want_pin="$PINNED_SHA256"
  case "$want_pin" in
    __TODO_*) die "config.env 的 SHA256_TARBALL 尚未回填（CI 构建完成后从 SHA256SUMS 取值）" ;;
  esac
  [ "$got_sum" = "$want_pin" ] || die "sha256 与 config.env pin 不符（want=$want_pin got=$got_sum）"
  log "  sha256 ok（pin 一致）"
}

# ============================================================
# 阶段: stage —— 组装 deb 文件系统树（官方规范布局）
# ============================================================
stage_stage() {
  local APP="$STAGE_DIR/usr/local/$APP_ID"
  log "组装文件系统树: $STAGE_DIR（/usr/local/$APP_ID 规范布局）"
  rm -rf "$STAGE_DIR"
  mkdir -p "$APP/bin" "$APP/images/icons" "$APP/nginx" "$APP/init.d"
  mkdir -p "$STAGE_DIR/usr/share/doc/$APP_ID"

  # ---- 二进制 ----
  if [ -n "${LOCAL_BIN:-}" ]; then
    log "  + bin/mediamtx（LOCAL_BIN: $LOCAL_BIN）"
    cp "${LOCAL_BIN}" "$APP/bin/mediamtx"
  else
    [ -s "$DL_DIR/$TGZ" ] || die "缺少 $TGZ，请先运行: ./build.sh fetch"
    log "  + bin/mediamtx（上游 $MEDIAMTX_VERSION，自建可复现产物）"
    tar xzOf "$DL_DIR/$TGZ" mediamtx > "$APP/bin/mediamtx"
  fi
  chmod 0755 "$APP/bin/mediamtx"

  # ---- config.ini ----
  log "  + config.ini（External Open: open_path=true, path=/$APP_ID/）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@PUBLISHER@@|$PUBLISHER|g" \
      -e "s|@@PLATFORM@@|$TOS_PLATFORM|g" \
      "$ASSETS_DIR/config.ini.in" > "$APP/config.ini"

  # ---- 语言文件（23 语超集，覆盖官方两个 14 语口径）----
  log "  + $APP_ID.lang（23 语言）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@AUTH@@|$UPSTREAM_AUTHOR|g" \
      "$ASSETS_DIR/$APP_ID.lang" > "$APP/$APP_ID.lang"

  # ---- 图标 ----
  log "  + images/icons/$APP_ID.svg"
  cp "$ASSETS_DIR/images/icons/$APP_ID.svg" "$APP/images/icons/$APP_ID.svg"

  # ---- nginx 路由（app 目录 + /etc/nginx/conf.d 双落盘，postinst 校验自愈）----
  log "  + nginx/ + /etc/nginx/conf.d/（控制台静态页 + API/HLS 反代）"
  mkdir -p "$STAGE_DIR/etc/nginx/conf.d"
  cp "$ASSETS_DIR/nginx/$APP_ID.conf" "$APP/nginx/$APP_ID.conf"
  cp "$ASSETS_DIR/nginx/$APP_ID.conf" "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf"

  # ---- systemd 服务（init.d/ + /etc/systemd/system 双落盘）----
  log "  + init.d/ + /etc/systemd/system/"
  mkdir -p "$STAGE_DIR/etc/systemd/system"
  cp "$ASSETS_DIR/init.d/$APP_ID.service" "$APP/init.d/$APP_ID.service"
  cp "$ASSETS_DIR/init.d/$APP_ID.service" "$STAGE_DIR/etc/systemd/system/$APP_ID.service"

  # ---- webui.bz2（状态控制台；解压须含可打开的 .html）----
  log "  + webui.bz2（状态控制台）"
  local WEBUI_DIR="$BUILD_DIR/webui"
  rm -rf "$WEBUI_DIR"
  mkdir -p "$WEBUI_DIR"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@RTSP_PORT@@|$RTSP_PORT|g" \
      -e "s|@@RTMP_PORT@@|$RTMP_PORT|g" \
      -e "s|@@HLS_PORT@@|$HLS_PORT|g" \
      -e "s|@@WEBRTC_PORT@@|$WEBRTC_PORT|g" \
      -e "s|@@SRT_PORT@@|$SRT_PORT|g" \
      "$ASSETS_DIR/webui/index.html" > "$WEBUI_DIR/index.html"
  export COPYFILE_DISABLE=1
  find "$WEBUI_DIR" -name '._*' -delete 2>/dev/null || true
  python3 - "$WEBUI_DIR" "$APP/webui.bz2" <<'PYW'
import sys, tarfile
from pathlib import Path
src_dir, out = sys.argv[1], sys.argv[2]
with tarfile.open(out, "w:bz2") as tf:
    for p in sorted(Path(src_dir).iterdir()):
        ti = tf.gettarinfo(str(p), arcname=p.name)
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = "root"
        ti.mtime = 0
        if ti.isfile():
            with open(p, "rb") as f:
                tf.addfile(ti, f)
        else:
            tf.addfile(ti)
PYW

  # ---- 默认配置模板（首装复制到数据目录，替换随机发布密码；升级不覆盖）----
  log "  + mediamtx.yml.example（默认配置模板）"
  cp "$ASSETS_DIR/mediamtx.yml" "$APP/mediamtx.yml.example"

  # ---- systemd 环境文件模板（可选）----
  log "  + $APP_ID.env.example"
  cp "$ASSETS_DIR/$APP_ID.env" "$APP/$APP_ID.env.example"

  # ---- 隐私政策（审核 C3）----
  log "  + privacy-policy.html（双语）"
  cp "$ASSETS_DIR/privacy-policy.html" "$APP/privacy-policy.html"

  # ---- 溯源材料（坑 50：放应用目录，不放 /usr/share/doc）----
  log "  + PROVENANCE.md（V6 溯源与可复现配方）"
  cp "$ASSETS_DIR/PROVENANCE.md" "$APP/PROVENANCE.md"

  # ---- doc：copyright + changelog.Debian（白名单内，可幸存）----
  if [ -f "$DL_DIR/LICENSE" ]; then
    cp "$DL_DIR/LICENSE" "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"
  else
    { echo "MediaMTX - MIT License"; echo "Copyright (c) 2019 aler9"; echo "See $UPSTREAM_REPO"; } \
      > "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"
  fi
  {
    echo "$APP_ID ($VERSION_FULL) TOS7; urgency=medium"
    echo ""
    echo "  * 基于上游 MediaMTX $MEDIAMTX_VERSION 打包（MIT）"
    echo "  * 二进制由本仓库公开 CI 从上游 tag 源码 bit-reproducible 构建（无 UPX）"
    echo "  * WebUI External Open：/mediamtx/ 状态控制台，API 经网关反代"
    echo "  * 媒体端口 RTSP/RTMP/HLS/WebRTC/SRT；管理 API 仅回环"
    echo ""
    echo " -- $MAINTAINER_FULL  $(date -R 2>/dev/null || date '+%a, %d %b %Y %H:%M:%S %z')"
  } > "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian"

  log "  清洗行尾（LF）与 BOM"
  normalize_text \
    "$APP/config.ini" "$APP/$APP_ID.lang" \
    "$APP/nginx/$APP_ID.conf" "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf" \
    "$APP/init.d/"*.service "$STAGE_DIR/etc/systemd/system/"*.service \
    "$APP/"*.example "$ASSETS_DIR/mediamtx.yml" \
    "$APP/privacy-policy.html" \
    "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian" \
    "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"

  if command -v xattr >/dev/null 2>&1; then
    xattr -rc "$STAGE_DIR" >/dev/null 2>&1 || true
  fi
  find "$STAGE_DIR" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true

  # 权限规范化：构建机 umask 可能过严（027），会让 nginx/系统服务读不到文件；
  # 规范要求 nginx conf 为 0644。目录 0755 / 文件 0644 / 二进制 0755。
  find "$STAGE_DIR" -type d -exec chmod 0755 {} +
  find "$STAGE_DIR" -type f -exec chmod 0644 {} +
  chmod 0755 "$APP/bin/mediamtx"

  log "组装完成"
}

# ============================================================
# 阶段: verify
# ============================================================
stage_verify() {
  local APP="$STAGE_DIR/usr/local/$APP_ID"
  [ -d "$APP" ] || die "尚未组装，请先运行: ./build.sh stage"
  local fail=0

  log "校验规范关键路径..."
  local p
  for p in "$APP/config.ini" "$APP/$APP_ID.lang" \
           "$APP/images/icons/$APP_ID.svg" \
           "$APP/nginx/$APP_ID.conf" \
           "$APP/init.d/$APP_ID.service" \
           "$STAGE_DIR/etc/systemd/system/$APP_ID.service" \
           "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf" \
           "$APP/bin/mediamtx" "$APP/webui.bz2" \
           "$APP/$APP_ID.env.example" "$APP/mediamtx.yml.example" \
           "$APP/privacy-policy.html" "$APP/PROVENANCE.md" \
           "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"; do
    [ -e "$p" ] || { warn "缺失: ${p#$STAGE_DIR/}"; fail=1; }
  done

  log "校验 config.ini（JSON 合法性 / 互斥字段 / 版本一致性）..."
  python3 - "$APP/config.ini" "$VERSION_FULL" "$TOS_PLATFORM" "$APP_ID" "$APP_USER" <<'PYEOF' || fail=1
import json, sys
cfg_path, want_ver, want_plat, app_id, app_user = sys.argv[1:6]
cfg = json.load(open(cfg_path))
errs = []
if cfg.get("id") != app_id: errs.append(f"id != {app_id}")
if cfg.get("version") != want_ver: errs.append(f"version != {want_ver}")
if cfg.get("system_id") != app_id: errs.append("system_id 不一致")
if cfg.get("package") != app_id: errs.append("package 不一致")
if cfg.get("platform") != want_plat: errs.append(f"platform != {want_plat}")
if cfg.get("open_path") is not True: errs.append("open_path 必须为 true")
if "type" in cfg: errs.append("不得包含 type 字段（与 open_path 互斥）")
if cfg.get("path") != f"/{app_id}/": errs.append(f"path 必须为 /{app_id}/")
if cfg.get("user") != app_user: errs.append(f"user 应为 {app_user}")
if cfg.get("recommend") is not False: errs.append("recommend 提交时必须为 false")
if cfg.get("beta") is not False: errs.append("beta 提交时必须为 false")
if cfg.get("application_type") != "deb": errs.append("application_type 必须为 deb")
if len(cfg.get("category", [])) > 3: errs.append("category 最多 3 个")
for e in errs:
    print(f"    校验失败: {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF

  log "校验 .lang（23 语齐全 + 六节点非空 + 版本一致 + 无 beta 字样 + 无残留占位符）..."
  python3 - "$APP/$APP_ID.lang" "$VERSION_FULL" <<'PYEOF' || fail=1
import re, sys
path, want_ver = sys.argv[1], sys.argv[2]
required = ["zh-cn","zh-hk","en-us","fr-fr","de-de","it-it","es-es","hu-hu",
            "ja-jp","ko-kr","pl-pl","ru-ru","tr-tr","pt-pt",
            "ar-sa","cs-cz","he-il","id-id","nb-no","nl-nl","sv-se","th-th","vi-vn"]
text = open(path, encoding="utf-8").read()
errs = []
for t in required:
    if f"[{t}]" not in text:
        errs.append(f"缺语言节点 {t}")
for field in ("name","auth","version","descript","release_note","important"):
    n = len(re.findall(rf"^{field}\s*=", text, re.M))
    if n < len(required):
        errs.append(f"字段 {field} 仅 {n}/{len(required)} 个节点")
if f'version      = "{want_ver}"' not in text:
    errs.append(f"version != {want_ver}")
if "@@" in text:
    errs.append("存在未替换的 @@ 占位符")
if re.search(r"\bbeta\b", text, re.I):
    errs.append("lang 全文不得出现 beta 字样（V11）")
for e in errs:
    print(f"    校验失败: {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF

  log "校验 systemd 服务（禁 Restart/必配 StartLimit/禁 ExecStart 变量展开/非 root）..."
  local svc
  for svc in "$APP/init.d/"*.service "$STAGE_DIR/etc/systemd/system/"*.service; do
    grep -q '^\[Unit\]' "$svc" || { warn "非 systemd unit: $svc"; fail=1; }
    grep -Eq '^Restart' "$svc" && { warn "规范禁止配置 Restart: $svc"; fail=1; }
    grep -Eq '^ExecStart=.*\$' "$svc" && { warn "ExecStart 禁用变量展开（坑 1）: $svc"; fail=1; }
    grep -q '^StartLimitBurst=' "$svc" || { warn "缺少 StartLimitBurst: $svc"; fail=1; }
    grep -q '^StartLimitIntervalSec=' "$svc" || { warn "缺少 StartLimitIntervalSec: $svc"; fail=1; }
    grep -q "^User=$APP_USER" "$svc" || { warn "必须 User=$APP_USER: $svc"; fail=1; }
    grep -q '^NoNewPrivileges=true' "$svc" || { warn "缺少 NoNewPrivileges=true: $svc"; fail=1; }
  done
  local n_units
  n_units=$(find "$APP/init.d" -name '*.service' | wc -l | tr -d ' ')
  [ "$n_units" = "1" ] || { warn "init.d/ 必须只放一个主服务单元（坑 11，当前 $n_units 个）"; fail=1; }

  log "校验默认配置（回环 API/指标 + 发布需认证 + 媒体端口正确）..."
  local yml="$APP/mediamtx.yml.example"
  grep -q "^apiAddress: 127\.0\.0\.1:$API_PORT" "$yml" || { warn "apiAddress 必须回环"; fail=1; }
  grep -q "^metricsAddress: 127\.0\.0\.1:$METRICS_PORT" "$yml" || { warn "metricsAddress 必须回环"; fail=1; }
  grep -q "^rtspAddress: :$RTSP_PORT" "$yml" || { warn "rtspAddress 不符"; fail=1; }
  grep -q "^hlsAddress: :$HLS_PORT" "$yml" || { warn "hlsAddress 不符"; fail=1; }
  grep -q "action: publish" "$yml" || { warn "默认配置缺少发布权限规则"; fail=1; }
  grep -q "^rtspTransports: \[udp, tcp\]" "$yml" || { warn "默认配置 RTSP 传输应为 [udp, tcp]（兼容摄像头 UDP 推流）"; fail=1; }
  grep -q "^  all_others:" "$yml" || { warn "默认配置缺少 paths.all_others（任意路径按需创建）"; fail=1; }
  grep -q "__MTX_PUBLISH_PASSWORD__" "$yml" || { warn "默认配置缺少发布密码占位符"; fail=1; }
  # 发布权限必须带密码（不能是匿名 any 的 publish）
  python3 - "$yml" <<'PYEOF' || fail=1
import sys, re
text = open(sys.argv[1], encoding="utf-8").read()
# 找到 publisher 用户块，断言 pass 非空
m = re.search(r"- user:\s*publisher\s*\n(?:\s*#[^\n]*\n)*\s*pass:\s*(\S+)", text)
if not m or m.group(1) == "":
    print("    校验失败: publisher 用户必须设置非空密码", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PYEOF

  log "校验 nginx（静态控制台 + API/HLS 反代 + 无 server 块 + WebSocket + absolute_redirect）..."
  local ng="$APP/nginx/$APP_ID.conf"
  grep -vE '^\s*#' "$ng" | grep -q 'server *{' && { warn "nginx 配置不得包含 server 块"; fail=1; }
  grep -q "proxy_pass http://127.0.0.1:$API_PORT/;" "$ng" || { warn "nginx 缺 API 反代"; fail=1; }
  grep -q "proxy_pass http://127.0.0.1:$HLS_PORT/;" "$ng" || { warn "nginx 缺 HLS 反代"; fail=1; }
  grep -q 'absolute_redirect off;' "$ng" || { warn "nginx 缺 absolute_redirect off（坑 13）"; fail=1; }
  grep -q 'proxy_set_header Upgrade' "$ng" || { warn "nginx 缺 WebSocket 升级头"; fail=1; }
  grep -q "alias /usr/local/$APP_ID/" "$ng" || { warn "nginx 缺静态控制台 alias"; fail=1; }

  log "校验图标（SVG + viewBox + ≤50 元素 + 无 filter/use/namedview/metadata）..."
  python3 - "$APP/images/icons/$APP_ID.svg" <<'PYEOF' || fail=1
import sys, xml.etree.ElementTree as ET
p = sys.argv[1]
raw = open(p, "rb").read()
if len(raw) > 50*1024:
    print(f"    校验失败: 图标 {len(raw)} 字节 > 50KB", file=sys.stderr); sys.exit(1)
root = ET.fromstring(raw)
if "viewBox" not in root.attrib:
    print("    校验失败: 图标缺 viewBox", file=sys.stderr); sys.exit(1)
n = sum(1 for _ in root.iter())
if n > 50:
    print(f"    校验失败: 图标元素数 {n} > 50（坑 52）", file=sys.stderr); sys.exit(1)
for bad in ("filter", "use", "metadata", "namedview", "sodipodi"):
    if bad in raw.decode("utf-8", "ignore").lower():
        print(f"    校验失败: 图标含 {bad}", file=sys.stderr); sys.exit(1)
sys.exit(0)
PYEOF

  log "校验 webui.bz2（含 html / root:root / 无 ._ 污染）..."
  tar tjf "$APP/webui.bz2" | grep -q '\.html$' || { warn "webui.bz2 缺少 html"; fail=1; }
  tar tjf "$APP/webui.bz2" | grep -qE '(^|/)\._' && { warn "webui.bz2 含 AppleDouble ._ 垃圾"; fail=1; }
  python3 - "$APP/webui.bz2" <<'PYW2' || fail=1
import sys, tarfile
with tarfile.open(sys.argv[1], "r:bz2") as tf:
    bad = [m.name for m in tf.getmembers() if m.uid != 0 or m.gid != 0]
    if bad:
        print(f"S11: webui.bz2 存在非 root 属主条目: {bad}")
        sys.exit(1)
PYW2

  log "校验 ELF（架构 $ELF_ARCH / 静态链接 / 完整 section header，V6 防黑盒）..."
  local f elfinfo
  f="$APP/bin/mediamtx"
  elfinfo=$(file "$f")
  echo "$elfinfo" | grep -q "ELF.*$ELF_ARCH" || { warn "错误架构: $elfinfo"; fail=1; }
  echo "$elfinfo" | grep -q "statically linked" || { warn "非静态链接: $elfinfo"; fail=1; }
  echo "$elfinfo" | grep -q "no section header" && { warn "无 section header（UPX 加壳，V6 一票否决）"; fail=1; }
  # 版本串抽查（grep -a 直接扫二进制，避免依赖 strings 且不受 pipefail/SIGPIPE 影响）
  if grep -a -q "v$MEDIAMTX_VERSION" "$f"; then
    log "  ok 版本串含 v$MEDIAMTX_VERSION"
  else
    warn "二进制内未找到版本串 v$MEDIAMTX_VERSION"
    fail=1
  fi

  log "校验 macOS/Mach-O 污染（应为 0）..."
  local n_macho
  n_macho=$(find "$APP" -type f -exec file {} + 2>/dev/null | grep -c "Mach-O" || true)
  [ "$n_macho" -eq 0 ] || { warn "发现 $n_macho 个 Mach-O 文件"; fail=1; }

  # 零网络自查（坑 15 的审查员同款扫法；只查脚本，注释除外）
  log "校验包内脚本零在线安装（S8）..."
  local hit
  hit=$(grep -RInE 'pip install|apt(-get)? install|curl .*\| *(ba)?sh|wget .*\| *(ba)?sh|npm install|urlopen|urllib' \
        "$STAGE_DIR/usr/local/$APP_ID" 2>/dev/null | grep -v '^\s*#' || true)
  [ -z "$hit" ] || { warn "脚本中出现可疑在线安装/下载模式:"; echo "$hit" >&2; fail=1; }

  if [ "$fail" -eq 0 ]; then
    log "校验通过 ✅"
  else
    die "校验失败，请检查上方警告"
  fi
}

# ============================================================
# 阶段: deb
# ============================================================
stage_deb() {
  [ -d "$STAGE_DIR/usr/local/$APP_ID" ] || die "尚未组装，请先运行: ./build.sh stage"
  mkdir -p "$OUT_DIR"
  "$SCRIPT_DIR/makedeb.sh" "$STAGE_DIR" "$ASSETS_DIR" "$DEB_FILE" \
    "$VERSION_FULL" "$TARGET_ARCH" "$MAINTAINER_FULL"

  cp "$DEB_FILE" "$STORE_DEB"
  sha256_of "$STORE_DEB" | awk -v f="$(basename "$STORE_DEB")" '{print $1"  "f}' > "$STORE_DEB.sha256"
  log "完成: $DEB_FILE"
  log "上架资产: $STORE_DEB (+ .sha256；Release tag 须为 v$VERSION_FULL)"
}

stage_repro() {
  cat <<EOF
============================================================
MediaMTX for TOS — V6 可复现构建配方（bit-reproducible）
============================================================
上游仓库   : $UPSTREAM_REPO
上游 tag   : $TAG
上游 commit: 048255986f7e04b859b4c4efe651448ec785ecd4
Go 工具链  : go$GO_TOOLCHAIN_VERSION （https://go.dev/dl/go$GO_TOOLCHAIN_VERSION.linux-amd64.tar.gz）
CI 配方    : .github/workflows/build-upstream.yml （公开 Actions 日志）
构建命令（与上游 scripts/binaries.mk / release.yml 一致，另加可复现所需两项 flag）:
  git clone --branch $TAG $UPSTREAM_REPO && cd mediamtx
  go generate ./...                 # 下载 hls.js 与 rpicamera（均 sha256 pin 校验）
  CGO_ENABLED=0 GOOS=linux GOARCH=<amd64|arm64> GOFLAGS="-trimpath -buildvcs=false" go build -o mediamtx .
复现校验: 同一环境独立构建两次字节一致（CI 内已断言）
产物发布: $BIN_SOURCE_BASE/$TGZ
校验值   : 见 Release 的 SHA256SUMS 与 config.env 的 pin（两层独立互验）
============================================================
EOF
}

stage_info() {
  cat <<EOF
MediaMTX 版本  : $MEDIAMTX_VERSION (完整版本 $VERSION_FULL)
目标架构       : $TARGET_ARCH (TOS:$TOS_PLATFORM)
TOS app id     : $APP_ID（新标签页 /$APP_ID/）
媒体端口       : RTSP $RTSP_PORT / RTMP $RTMP_PORT / HLS $HLS_PORT / WebRTC $WEBRTC_PORT+$WEBRTC_UDP_PORT / SRT $SRT_PORT
管理端口(回环) : API $API_PORT / metrics $METRICS_PORT / playback $PLAYBACK_PORT
产物           : $DEB_FILE
上架资产       : $STORE_DEB + .sha256（Release tag: v$VERSION_FULL）
EOF
}

stage_clean()      { rm -rf "$STAGE_DIR" "$BUILD_DIR/webui"; log "已清理 stage（保留下载缓存）"; }
stage_distclean()  { rm -rf "$BUILD_DIR" "$OUT_DIR"; log "已清理全部构建产物与下载缓存"; }

STAGE=${1:-all}
case "$STAGE" in
  fetch)      stage_fetch ;;
  stage)      stage_stage ;;
  deb)        stage_deb ;;
  all)        stage_fetch; stage_stage; stage_verify; stage_deb ;;
  clean)      stage_clean ;;
  distclean)  stage_distclean ;;
  verify)     stage_verify ;;
  info)       stage_info ;;
  repro)      stage_repro ;;
  *)          die "未知阶段: $STAGE（可用: fetch stage deb verify clean distclean info repro）" ;;
esac
