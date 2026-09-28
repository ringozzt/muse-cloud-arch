#!/bin/bash
# checkpoint.sh — 最小复刻的"世代交接"
# 对标真实架构：handoff（epoch 推进 + 状态快照 + 容器销毁）
#
# 用法：sudo ./checkpoint.sh
#   效果：epoch+1，打包 home 为快照，销毁容器。
#   下次 orchestrator.sh 会冷启动，但 home / context / epoch 都在。

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root：sudo $0" >&2
  exit 1
fi

MACHINE=demo-runtime
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR=/var/lib/demo/run
EPOCH_FILE="$RUN_DIR/handoff-epoch"
EPOCH=$(($(cat "$EPOCH_FILE" 2>/dev/null || echo 0) + 1))

# --- 1. 销毁容器（对标 container.destroy()；真实版由 idle 超时或调度器触发） ---
if machinectl show "$MACHINE" 2>/dev/null | grep -q 'State=running'; then
  echo "[checkpoint] 停止容器 $MACHINE …"
  machinectl poweroff "$MACHINE" 2>/dev/null || machinectl terminate "$MACHINE" 2>/dev/null || true
  for _ in $(seq 1 20); do
    machinectl show "$MACHINE" 2>/dev/null | grep -q 'State=running' || break
    sleep 1
  done
else
  echo "[checkpoint] 容器本就没在跑，直接做快照"
fi

# --- 2. 打包状态（对标 hotset/state snapshot；demo 用 tar 简化，真实版是块级预热清单） ---
mkdir -p "$RUN_DIR/checkpoints"
SNAP="$RUN_DIR/checkpoints/epoch-$EPOCH.tar.gz"
tar -czf "$SNAP" -C /var/lib/demo home

# --- 3. 写 marker（对标 handoff-marker.slot0；demo 用 JSON 明文，真实版是二进制） ---
TS=$(date -u +%FT%TZ)
echo "$EPOCH" > "$EPOCH_FILE"
cat > "$RUN_DIR/handoff-marker.json" <<EOF
{
  "epoch": $EPOCH,
  "ts": "$TS",
  "demo_commit": "$(git -C "$DEMO_DIR/.." rev-parse --short HEAD 2>/dev/null || echo nogit)",
  "snapshot": "checkpoints/epoch-$EPOCH.tar.gz",
  "snapshot_bytes": $(stat -c %s "$SNAP")
}
EOF
echo "$TS" > "$RUN_DIR/execution-ready.marker"

echo "[checkpoint] epoch=$EPOCH snapshot=$(du -h "$SNAP" | cut -f1)（$SNAP）"
echo "容器已销毁。下次 sudo ./orchestrator.sh 会冷启动，但 home、context、epoch 都在 —— 这就是「抽屉跟着人走」。"
