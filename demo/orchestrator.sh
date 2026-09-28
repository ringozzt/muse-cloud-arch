#!/bin/bash
# orchestrator.sh — 最小复刻的"宿主机编排器"
# 对标真实架构：spawnd + pre-start.sh + launch-daemon.sh
# 职责：准备 rootfs → 起 nspawn 容器 → 等 ready → 注入消息 → 调 agent → 回显
#
# 用法：sudo ./orchestrator.sh "你的消息"
#   （省略消息时默认 "你好"；每次调用 = 伪代码里的 handle_user_message() 一次）

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root（machinectl / debootstrap）：sudo $0 ..." >&2
  exit 1
fi

MSG="${1:-你好}"
MACHINE=demo-runtime
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS=/var/lib/machines/demo-rootfs
HOME_DIR=/var/lib/demo/home
RUN_DIR=/var/lib/demo/run
NSPAWN_CONF=/etc/systemd/nspawn/demo-runtime.nspawn

# --- 1. 准备 rootfs（对标 ensure-rootfs.sh；真实版在宿主机 /var/lib/hatch-runtime/rootfs） ---
if [ ! -x "$ROOTFS/bin/bash" ]; then
  echo "[orchestrator] 准备 rootfs（首次较慢，约几分钟）…"
  if ! command -v debootstrap >/dev/null 2>&1; then
    echo "缺 debootstrap：apt install -y debootstrap，或手动把 Ubuntu rootfs 放到 $ROOTFS" >&2
    exit 1
  fi
  debootstrap --include=curl,ca-certificates,jq noble "$ROOTFS" http://archive.ubuntu.com/ubuntu/
fi

# --- 2. 安装 guest 文件（对标镜像构建层；真实版的 unit 随镜像自带） ---
install -Dm644 "$DEMO_DIR/guest/demo-ready.service" "$ROOTFS/etc/systemd/system/demo-ready.service"
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf ../demo-ready.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/demo-ready.service"

# --- 3. 渲染 nspawn 配置（bind 挂载：home 持久化 + run 共享 + guest 只读） ---
mkdir -p /etc/systemd/nspawn
sed "s|@DEMO_DIR@|$DEMO_DIR|g" "$DEMO_DIR/config/demo-runtime.nspawn" > "$NSPAWN_CONF"

# --- 4. 准备持久 home 与 run 目录（对标 btrfs 独立挂载；demo 用普通目录 + bind 简化） ---
mkdir -p "$HOME_DIR" "$RUN_DIR/checkpoints"
if [ ! -f "$HOME_DIR/context.md" ]; then
  printf '# demo agent 上下文\n\n> 每次对话追加，checkpoint 打包，容器销毁后依然存在。\n\n' > "$HOME_DIR/context.md"
fi

# --- 5. 渲染环境变量（对标 spawnd 渲染 guest.env；容器内只读） ---
cat "$DEMO_DIR/config/guest.env" > "$RUN_DIR/guest.env"
if [ -f "$DEMO_DIR/.env" ]; then
  cat "$DEMO_DIR/.env" > "$RUN_DIR/guest.local.env"
else
  rm -f "$RUN_DIR/guest.local.env"
fi

# --- 6. 冷启动或复用（对标 cold_start） ---
if machinectl show "$MACHINE" 2>/dev/null | grep -q 'State=running'; then
  echo "[orchestrator] warm 路径：复用运行中的容器"
else
  echo "[orchestrator] cold start：拉起容器 $MACHINE …"
  rm -f "$RUN_DIR/ready"
  machinectl start "$MACHINE"
  # 等 ready（对标 ExecStartPre 等待 runtime-cell.ready）
  for _ in $(seq 1 120); do
    [ -f "$RUN_DIR/ready" ] && break
    sleep 1
  done
  if [ ! -f "$RUN_DIR/ready" ]; then
    echo "容器启动超时，可 machinectl status $MACHINE 排查" >&2
    exit 1
  fi
  echo "[orchestrator] 容器就绪"
fi

# --- 7. 注入消息并执行 agent（对标 hatch-execd 在容器内执行命令） ---
printf '%s' "$MSG" > "$RUN_DIR/inbox.txt"
echo "[orchestrator] agent 执行中…"
systemd-run --machine="$MACHINE" --pipe --wait /bin/bash /guest/agent-loop.sh

# --- 8. 状态回显 ---
echo "── context.md 共 $(wc -l < "$HOME_DIR/context.md") 行；epoch $(cat "$RUN_DIR/handoff-epoch" 2>/dev/null || echo 0)"
