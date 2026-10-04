#!/usr/bin/env bash
# ============================================================
# 真机 E2E：把 deb 装到 TOS 真机并逐项验收
#
# 用法:
#   TEST_TARGET=apple@<TOS-host-or-ip> ./test/install-and-verify.sh [deb路径]
#   TEST_TARGET 也可用 SSH 别名（需在 ~/.ssh/config 配好）。
#   默认取 out/ 下最新的 *_amd64.deb。
#
# 覆盖（对照知识库《打包指南》§五 真机验证清单）:
#   ① systemd active/enabled，运行用户非 root（坑 11/24）
#   ② 回环端口封闭性（API/metrics 仅 127.0.0.1）+ 媒体端口在听
#   ③ TOS 网关路由 /mediamtx/（跟随 8181→5443 的 301，坑 37）
#   ④ 状态控制台 200、管理 API 经网关可用
#   ⑤ 匿名推流被拒 / 认证推流成功 / HLS 经网关可播（cookieCheck 两步）
#   ⑥ 首装密码文件 root-0600、配置目录属主
#   ⑦ apt remove 保留数据、apt purge 全清（无残留文件/用户）
# ============================================================
set -euo pipefail

TARGET="${TEST_TARGET:-}"
[ -n "$TARGET" ] || { echo "请设置 TEST_TARGET（例如 TEST_TARGET=apple@nas ./test/install-and-verify.sh）" >&2; exit 1; }
SSH_OPTS=(-i "${SSH_KEY:-$HOME/.ssh/id_ed25519}" -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
DEB="${1:-$(ls -t "$SCRIPT_DIR"/out/mediamtx_*_amd64.deb 2>/dev/null | head -1)}"

[ -n "${DEB:-}" ] && [ -f "$DEB" ] || { echo "找不到 deb（用参数指定路径）" >&2; exit 1; }

SSH() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }
PASS=0; FAIL=0
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '\033[1;34m==\033[0m %s\n' "$*"; }

note "传输 deb: $(basename "$DEB") → $TARGET"
cat "$DEB" | SSH 'cat > /tmp/mediamtx-e2e.deb'

note "安装（覆盖安装，先移除旧包）"
SSH 'apt purge -y mediamtx >/dev/null 2>&1 || true; apt install -y /tmp/mediamtx-e2e.deb >/tmp/mtx-install.log 2>&1; echo "install rc=$?"'

note "① 服务状态与运行用户"
SSH 'systemctl is-active mediamtx' | grep -qx active && ok "service active" || bad "service not active"
SSH 'systemctl is-enabled mediamtx' | grep -qx enabled && ok "service enabled" || bad "service not enabled"
UID_MTX=$(SSH 'id -u mediamtx'); [ "$UID_MTX" != "0" ] && ok "非 root 运行用户 (uid=$UID_MTX)" || bad "运行用户是 root"

note "② 端口"
SSH "ss -tlnp | grep -q '127.0.0.1:9997'" && ok "API 仅回环 9997" || bad "API 未在回环 9997"
SSH "ss -tlnp | grep -q '127.0.0.1:9998'" && ok "metrics 仅回环 9998" || bad "metrics 未在回环"
for p in 8554 1935 8888 8889; do
  SSH "ss -tlnp | grep -q ':$p '" && ok "媒体端口 $p/TCP 在听" || bad "媒体端口 $p/TCP 缺失"
done
SSH "ss -ulnp | grep -q ':8189 '" && ok "WebRTC ICE 8189/UDP 在听" || bad "WebRTC ICE 缺失"
SSH "ss -ulnp | grep -q ':8890 '" && ok "SRT 8890/UDP 在听" || bad "SRT 缺失"
# API 不应在外部地址暴露
SSH "ss -tlnp | grep ':9997' | grep -qv '127.0.0.1:9997'" && bad "API 暴露在非回环地址" || ok "API 无外部监听"

note "③④ 网关路由与控制台"
SSH 'curl -sk -o /dev/null -w "%{http_code}" -m 8 https://127.0.0.1:5443/mediamtx/' | grep -qx 200 \
  && ok "控制台 /mediamtx/ 经网关 200" || bad "控制台未 200"
SSH 'curl -sk -m 8 https://127.0.0.1:5443/mediamtx/api/v3/info' | grep -q '"version"' \
  && ok "管理 API 经网关可用" || bad "管理 API 不可用"
SSH 'curl -sk -m 8 https://127.0.0.1:5443/mediamtx/privacy-policy.html' | grep -qi "privacy" \
  && ok "隐私政策可达（C3）" || bad "隐私政策不可达"

note "⑤ 认证与播放"
# 注意：远程脚本里绝不能有命令去读 stdin（否则会把脚本本身吃掉）；ffmpeg 一律 </dev/null。
SSH 'bash -s' <<'EOS' | tee /tmp/mtx-e2e-func.log
set +e
PASS=$(grep '^password:' /var/lib/mediamtx/publisher_password.txt | awk '{print $2}')
# 匿名推流必须被拒
if timeout 12 ffmpeg -hide_banner -loglevel error -re -f lavfi -i testsrc=size=320x240:rate=10 -t 2 -c:v libx264 -preset ultrafast -f rtsp rtsp://127.0.0.1:8554/e2e-anon </dev/null 2>&1 | grep -q '401'; then
  echo "ANON_REJECTED=1"
else
  echo "ANON_REJECTED=0"
fi
# 认证推流
nohup timeout 30 ffmpeg -hide_banner -loglevel warning -re -f lavfi -i testsrc=size=640x360:rate=15 -t 24 -c:v libx264 -preset ultrafast -g 30 -f rtsp "rtsp://publisher:$PASS@127.0.0.1:8554/e2e" </dev/null >/tmp/mtx-ff.log 2>&1 &
sleep 9
if curl -s -m 5 http://127.0.0.1:9997/v3/paths/list | grep -q '"e2e"'; then echo "PATH_OK=1"; else echo "PATH_OK=0"; fi
# HLS 两步（cookieCheck）
curl -sk -o /dev/null -m 8 "https://127.0.0.1:5443/mediamtx/hls/e2e/index.m3u8" >/dev/null
if curl -sk -m 8 "https://127.0.0.1:5443/mediamtx/hls/e2e/index.m3u8?cookieCheck=1" | grep -q '#EXTM3U'; then echo "HLS_OK=1"; else echo "HLS_OK=0"; fi
EOS
grep -q 'ANON_REJECTED=1' /tmp/mtx-e2e-func.log && ok "匿名推流被拒 (401)" || bad "匿名推流未被拒！"
grep -q 'PATH_OK=1'      /tmp/mtx-e2e-func.log && ok "认证推流成功，路径可见" || bad "认证推流失败"
grep -q 'HLS_OK=1'       /tmp/mtx-e2e-func.log && ok "HLS 经网关可播" || bad "HLS 播放失败"

note "⑥ 文件权限"
SSH 'test "$(stat -c %a /var/lib/mediamtx/publisher_password.txt)" = 600' \
  && ok "密码文件 0600" || bad "密码文件权限不是 0600"
SSH 'test "$(stat -c %u /var/lib/mediamtx/publisher_password.txt)" = 0' \
  && ok "密码文件属主 root (uid 0)" || bad "密码文件属主不是 uid 0"
SSH 'test "$(stat -c %a /usr/local/mediamtx/config.ini)" = 644' \
  && ok "config.ini 0644" || bad "config.ini 权限异常"

note "⑦ remove 保留数据 / purge 全清"
SSH 'apt remove -y mediamtx >/dev/null 2>&1; test -f /var/lib/mediamtx/mediamtx.yml' \
  && ok "apt remove 保留 /var/lib/mediamtx" || bad "remove 误删数据"
SSH 'apt purge -y mediamtx >/dev/null 2>&1; true'
SSH '[ ! -e /usr/local/mediamtx ] && [ ! -e /var/lib/mediamtx ] && [ ! -e /etc/systemd/system/mediamtx.service ] && [ ! -e /etc/nginx/conf.d/mediamtx.conf ] && ! id -u mediamtx >/dev/null 2>&1' \
  && ok "apt purge 无残留（目录/单元/nginx/用户）" || bad "purge 后有残留"

echo ""
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32mE2E 通过：%d 项\033[0m\n' "$PASS"
else
  printf '\033[1;31mE2E 失败：%d 通过 / %d 失败\033[0m\n' "$PASS" "$FAIL"
  exit 1
fi
