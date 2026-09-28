# demo/ — Muse 云架构的最小可跑复刻

一句话：用 `systemd-nspawn` + 几个 shell 脚本，把「按需容器 → 持久 home → 上下文注入 → 世代交接」这条主链跑起来。
每次 `./orchestrator.sh "消息"` = 伪代码里的 `handle_user_message()` 走一遍。

## 架构对照表

| 真实组件 | demo 复刻 | 说明 |
|---|---|---|
| Cloud Hypervisor VM | （折叠）直接用宿主机 | 单机演示，标注了折叠点 |
| systemd-nspawn 容器 `htch-runtime` | nspawn 容器 `demo-runtime`（Ubuntu 24.04 rootfs） | `machinectl` 管理 |
| spawnd + pre-start.sh + launch-daemon.sh | `orchestrator.sh` | 编排：rootfs → 起容器 → 等 ready → 注入消息 |
| `/dev/mapper/rv` btrfs 独立挂载 | `/var/lib/demo/home` bind 到 `/home/demo` | 持久化语义相同，实现简化 |
| hatch-ca-trust.service + runtime-cell.ready | `guest/demo-ready.service` → `/run/demo/ready` | oneshot + 就绪标记 |
| hatch-execd 在容器内执行命令 | `systemd-run --machine=demo-runtime /guest/agent-loop.sh` | 同样的"进容器执行"语义 |
| hatch daemon（智能本体） | `guest/agent-loop.sh`（最小占位） | 读上下文 → 调 LLM/mock → 写回 |
| guest.env（spawnd 渲染，只读） | `config/guest.env` → `/run/demo/guest.env`（只读） | 语义一致 |
| handoff（epoch + hotset + 销毁） | `checkpoint.sh`（epoch+1 → tar 快照 → 销毁容器） | tar 代替块级预热清单 |
| JARVIS_HATCHLING_ID 等身份变量 | `handoff-epoch` 文件 | 最小身份 |

## 前置要求

- 一台 **Linux** 机器（nspawn 依赖 systemd + Linux 内核；Mac 上用 UTM/Lima 起 Ubuntu 24.04 虚拟机，或云主机）
- root 权限、`systemd-container`（`machinectl`）、`debootstrap`（首次自动装 rootfs，可 `apt install -y debootstrap systemd-container`）
- 真实模型模式才需要：外网 + OpenAI 兼容 API key；**mock 模式零依赖，开箱即跑**

## 快速开始

```bash
cd demo
chmod +x orchestrator.sh checkpoint.sh

# 第 1 轮：冷启动（拉起容器，稍慢）
sudo ./orchestrator.sh "你好，我是 Te"

# 第 2 轮：warm 路径（复用容器，记得上下文）
sudo ./orchestrator.sh "我刚才叫什么？"

# 交接：epoch 1，快照打包，容器销毁
sudo ./checkpoint.sh
ls /var/lib/demo/run/checkpoints/

# 第 3 轮：再次冷启动 —— 但 context 和 epoch 都在，「抽屉跟着人走」
sudo ./orchestrator.sh "现在是第几代？"
```

## 真实模型模式（可选）

```bash
cp config/guest.env .env   # 注意：.env 别提交，里面有 key
# 编辑 .env：DEMO_MOCK=0，填 LLM_API_URL / LLM_API_KEY / LLM_MODEL
sudo ./orchestrator.sh "讲个关于容器的笑话"
```

## 做了哪些简化（诚实版）

1. **VM 层折叠**：真实是 Cloud Hypervisor 里再起 nspawn，demo 直接在宿主机起 nspawn。
2. **存储**：btrfs 子卷 + overlay 四层挂载 → 普通目录 bind。持久化语义一样，但没有快照/压缩/写时复制。
3. **handoff**：块级 hotset 预热清单 → `tar.gz` 整包快照。演示"交接"语义，不演示"启动加速"效果。
4. **智能本体**：真正的 agent（工具调用、多轮推理、记忆管理）→ 一次 curl/mock。`agent-loop.sh` 是故意留白的扩展点。
5. **安全件**：CA 下发、egress 代理、出站审批、sentinel、seccomp —— 全部省略，位置用注释标出来了。
6. **调度器**：`pick_host() → localhost`，接口保留在注释里。

## 文件说明

```
demo/
├── README.md                  # 本文件
├── orchestrator.sh            # 编排器（对标 spawnd + pre-start + launch-daemon）
├── checkpoint.sh              # 世代交接（对标 handoff）
├── config/
│   ├── guest.env              # 环境变量模板（对标 guest.env）
│   └── demo-runtime.nspawn    # nspawn 配置模板（@DEMO_DIR@ 渲染）
└── guest/                     # bind 只读进容器（对标"cell cannot edit"）
    ├── demo-ready.service     # oneshot 就绪单元（对标 hatch-ca-trust + ready）
    └── agent-loop.sh          # 最小 agent（对标 hatch-execd 执行的命令）
```

## 演示不了的东西

- hotset 预热的真实加速效果（demo 数据量下感知不到）
- 多租户调度、超售、noisy neighbor
- 安全纵深的有效性（只能演示"有这个位置"）
- 模型推理本身（demo 接的是外部 LLM API）
