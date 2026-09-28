#!/bin/bash
# agent-loop.sh — 最小 agent（在容器内执行）
# 对标真实架构：hatch-execd 在容器内执行的命令 / hatch daemon 的工作单元
#
# 输入：/run/demo/inbox.txt（本轮用户消息，由 orchestrator 注入）
#       /run/demo/guest.env + guest.local.env（编排器渲染的环境，容器内只读）
# 状态：/home/demo/context.md（追加写 = 持久记忆；对标 btrfs home + 外部上下文）
#
# 注意：这是"智能"的最小占位。真实版做工具调用、模型推理、上下文管理；
# demo 版只做：读上下文 → 调 LLM（或 mock）→ 写回上下文。

set -euo pipefail

HOME_DIR=/home/demo
RUN_DIR=/run/demo
CTX="$HOME_DIR/context.md"

# 环境变量（对标：容器内读取宿主机渲染的 guest.env）
set -a
[ -f "$RUN_DIR/guest.env" ] && . "$RUN_DIR/guest.env"
[ -f "$RUN_DIR/guest.local.env" ] && . "$RUN_DIR/guest.local.env"
set +a

MSG="$(cat "$RUN_DIR/inbox.txt")"
TS="$(date '+%F %T')"
EPOCH="$(cat "$RUN_DIR/handoff-epoch" 2>/dev/null || echo 0)"
CTX_LINES="$(wc -l < "$CTX" 2>/dev/null || echo 0)"

if [ "${DEMO_MOCK:-1}" = "1" ]; then
  # mock 模式：零依赖，开箱即跑
  REPLY="（mock 模式）收到：「${MSG}」。epoch=${EPOCH}，context 已有 ${CTX_LINES} 行。配好 demo/.env（LLM_API_KEY）后可切换真实模型。"
else
  # 真实模式：OpenAI 兼容接口
  CONTEXT_TAIL="$(tail -40 "$CTX")"
  REQ="$(jq -n --arg m "$MSG" --arg c "$CONTEXT_TAIL" --arg model "${LLM_MODEL:-gpt-4o-mini}" \
    '{model: $model, messages: [
      {role: "system", content: ("你是 demo 复刻里的最小 agent。这是历史上下文：\n" + $c)},
      {role: "user", content: $m}
    ]}')"
  REPLY="$(curl -s -m 90 "${LLM_API_URL}" \
    -H "Authorization: Bearer ${LLM_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$REQ" | jq -r '.choices[0].message.content // "（API 调用失败，请检查 demo/.env）"')"
fi

# 追加写回上下文（对标：persist / 抽屉）
{
  echo "## [$TS] user: $MSG"
  echo "$REPLY"
  echo
} >> "$CTX"

# 回显给 orchestrator（经 systemd-run --pipe 传回宿主机）
printf '%s\n' "$REPLY"
