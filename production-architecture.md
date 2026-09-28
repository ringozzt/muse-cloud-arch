# 生产级架构：墙外的另一半

> 阅读指南：本文写的是从容器内**看不见**的那一半。严格区分三类陈述：
> - ✅ **实测痕迹**：容器内可见的证据（环境变量、脚本、挂载、socket 名）
> - 🔍 **强推断**：证据 + 工程常识下几乎唯一的解释
> - 💭 **设计推演**：生产级必须回答的问题，以及合理的答案（可能与真实实现有出入）
>
> 与之相对，`README.md` / `runtime-internals.md` / `architect-notes.md` 写的是墙内的一半（全部实测）。

## 1. 完整架构图

```
                          ┌─────────────────────────────────────────────┐
                          │               控制平面（墙外）               │
                          │  调度器 · 镜像构建/发布 · CA 签发 · spawnd 模版 │
                          └──────────────────────┬──────────────────────┘
                                                 │ 调度 / 编排指令
┌──────────┐   HTTPS/WSS    ┌─────────────────────▼──────────────────────┐
│   用户    │ ◄──────────► │  接入层：鉴权、会话路由、连接保持            │
└──────────┘                └─────────────────────┬──────────────────────┘
                                                │
        ┌───────────────────────────────────────▼───────────────────────────────────────┐
        │ 物理机池（AMD EPYC，多租户；steal time 证明 CPU 共享）                        │
        │  ┌──────────────────────────────────────────────────────────────────────┐   │
        │  │ Cloud Hypervisor VM（2核/7G，**常驻池**，非按需创建）                 │   │
        │  │                                                                      │   │
        │  │  ┌────────────────────────────────────────────────────────────┐   │   │
        │  │  │ systemd-nspawn 容器 htch-runtime（**按需**生灭）            │   │   │
        │  │  │  · systemd + hatch-ca-trust(oneshot)                        │   │   │
        │  │  │  · hatch daemon / hatch-execd（常驻进程）                   │   │   │
        │  │  │  · /home/hatch ← btrfs 独立子卷（持久）                     │   │   │
        │  │  │  · 出站全经 egress-proxy:3128（自签 CA）                     │   │   │
        │  │  │  · 推理经 /run/hatch/proxy/inference.sock（容器外）         │   │   │
        │  │  └────────────────────────────────────────────────────────────┘   │   │
        │  │                                                                      │   │
        │  │  宿主机侧：spawnd（编排）· Postgres（数据面）· veth 网关 198.19.0.1  │   │
        │  └──────────────────────────────────────────────────────────────────────┘   │
        └─────────────────────────────────────────────────────────────────────────────┘
        ┌─────────────────────────────────────────────────────────────────────────────┐
        │ 支撑平面：egress proxy 集群 · telemetry 收集 · sentinel 策略 · Postgres 备份 │
        │          镜像仓库 · 日志聚合 · 模型推理服务（容器外）                        │
        └─────────────────────────────────────────────────────────────────────────────┘
```

## 2. 各子系统详解

### 2.1 调度器（完全黑盒，💭 为主）

- ✅ 痕迹：`JARVIS_VM_COMPUTE_REGION=zas` / `JARVIS_VM_DATA_REGION=rcd`（计算与数据分区）；容器按需启动、空闲回收（实测）。
- 🔍 强推断：必然存在一个中心调度器，负责选物理机、维护 VM 池水位、决定容器回收时机。计算/数据分区说明调度是 region-aware 的。
- 💭 生产级要点：
  - **VM 池化**：VM 是常驻池（`rv-identity-ready` 时间戳晚于容器启动即证据），容器是池上按需分配 —— 池化把"分钟级 VM 启动"从关键路径上拿掉，冷启动只剩"秒级容器启动"。
  - **装箱策略**：2核/7G 是固定规格（T-shirt sizing），简化装箱；steal time 说明物理机超售，调度器要做 noisy-neighbor 感知（或至少不做保证）。
  - **回收策略**：idle 超时 + 压力抢占两档；`draining` 文件（pre-start.sh 里出现过）说明有优雅驱逐协议。
  - **区域分离**：计算（zas）与数据（rcd）分区，常见理由是延迟/合规/成本 trade-off，细节未知。

### 2.2 嵌套虚拟化：为什么是"套娃"

- ✅ 痕迹：DMI `cloud-hypervisor` + `systemd-detect-virt → systemd-nspawn`。
- 🔍 强推断：两层各司其职 ——
  - **KVM 层（Cloud Hypervisor）**：硬隔离边界。防的是容器逃逸影响整台物理机上的其他租户。Cloud Hypervisor 选型说明要的是"轻"，不是 VMware 式的重。
  - **nspawn 层**：速度。与宿主共享内核，省掉 guest OS 启动，秒级拉起；且能直接 bind 挂载宿主机资源（btrfs 卷、CA 锚点）。
- 💭 设计理由：一层给**安全**（租户隔离），一层给**速度**（按需启动）。单用 KVM 太慢，单用容器隔离不够 —— 这是经典的纵深取舍，不是过度设计。

### 2.3 spawnd：宿主机编排器

- ✅ 痕迹：`launch-daemon.sh` 调用 `/opt/hatch/bin/spawnd` 上报 bootstrap 阶段；`guest.env` 头注释 *"Managed by spawnd. Rendered KEY=VALUE"*；`runtime-cell-entry.sh` *"rendered by spawnd (RUNTIME_CELL_SCRIPTS)"*；`machine=htch-runtime`。
- 🔍 强推断：spawnd 是每台 VM/宿主机上的常驻编排 agent：渲染模板、管理 `machinectl` 生命周期、上报阶段、处理 pre-start/post-stop。
- 💭 生产级要点：这是"不可变基础设施"的执行者 —— 容器内的一切（环境变量、nspawn 配置、unit 文件）都是它渲染的产物，容器本身不可改配置。这是云原生最佳实践（与 Kubernetes 的 kubelet 角色类似）。

### 2.4 镜像构建与发布管线

- ✅ 痕迹：`jarvis_commit=5c8050fc…`（handoff marker 内）；`first-boot-ensure-stamp.json`（fingerprint + publication_id）；`JARVIS_CD_CHANNEL=alpha` / `JARVIS_CD_PINNED=0`；`/dev/mapper/opt_hatch` squashfs 只读层。
- 🔍 强推断：有一套 CI/CD 管线持续构建运行时镜像，`alpha` 通道 + `PINNED=0` = 跟随最新；每次构建有 commit 和指纹，handoff 时 pin 住，可追溯、可回滚。
- 💭 生产级要点：squashfs 只读层说明镜像分层是**内容寻址、不可变**的 —— 这正是第三方快照（如 win4r 仓库）必然过期的结构性原因，也是灰度发布的基础。

### 2.5 身份与证书平面

- ✅ 痕迹：`hatch-ca-trust.service` 从 `/run/hatch/cell-anchors/` 取 `hatch-egress-ca.pem` / `hatch-ingress-ca.pem`；代理 URL 里按实例签发的凭证（`hatch-runtime:<redacted>@hatch-egress-proxy:3128`）。
- 🔍 强推断：宿主机侧有一个 CA/身份服务：容器启动时签发实例身份、下发 CA 锚点、签发代理凭证。实例凭证大概率是短期的（启动时签发、销毁时作废）。
- 💭 生产级要点：这是零信任的基石 —— 没有长期密钥可以偷，每次启动都是新身份。`cell-anchors` 这个名字说明锚点是按"cell（容器）"作用域签发的。

### 2.6 网络平面

- ✅ 痕迹：全量出站经 `hatch-egress-proxy:3128`；6 个 `*_CA_BUNDLE` 指向自签 CA；出站审批 socket（sentinel）；`hatch-ingress-ca.pem`；网关 198.19.0.1 做 DNS；veth `ve-htch-runtime`。
- 🔍 强推断：
  - 出站：TLS 拦截式审计代理集群（3128 是 Squid 系默认端口）；sentinel 做策略审批（不是所有出站都自动放行）。
  - 入站：ingress CA 的存在说明有**入站面** —— 最可能用于"浏览器接管"（用户接管容器内浏览器）和实时连接。
- 💭 生产级要点：出站 MITM 代理是 DLP（防数据泄露）和合规审计的标准做法；审批面说明策略是**运行时强制**的。入站面的存在意味着网络策略是双向的，不是简单的 NAT 出访。

### 2.7 数据平面：btrfs + Postgres

- ✅ 痕迹：`/dev/mapper/rv` btrfs（`zstd:3` 压缩）；hotset 条目指向 `/var/lib/hatch/postgres`；`postgres_system_identifier`；`pg-clean.proof`；`~/.hatch-db-change-signals/`。
- 🔍 强推断：数据面至少两部分 —— btrfs 卷（用户文件，跨容器世代持久）+ Postgres（结构化运行时状态，跑在宿主机侧，handoff 时做一致性校验）。两者都在"墙外"供应、"墙内"使用。
- 💭 生产级要点：
  - btrfs 选型理由：子卷（天然按用户隔离）、快照（handoff/备份）、zstd 压缩（降成本）。
  - Postgres 存的应该是**高频、小粒度的运行时状态**（记忆索引、会话、spaces catalog），文件存**低频、大粒度**的用户数据 —— 经典的冷热分层。
  - `pg-clean.proof` 说明 handoff 有"干净关闭"协议，防的是带着半写事务醒来。

### 2.8 Handoff 编排与 Hotset 生成

- ✅ 痕迹：`/run/hatch/resume/` 全套（epoch、marker、hotset.manifest、proof）；hotset 845 条目/61MB/tier1+tier2；02:15 撞见的一次 handoff（容器未重启）。
- 🔍 强推断：宿主机侧有一个 warmer/handoff 编排器：定期或按需把 Postgres 热数据块读进 page cache、生成 manifest、推进 epoch。handoff 不一定伴随容器重建 —— 它是**独立的"世代"维度**。
- 💭 生产级要点：这是整个架构里最精妙的一笔 —— 把"冷启动"重新定义为"带着预热缓存的苏醒"。61MB 的预热清单说明有人实测过"哪些块值得预热"，是数据驱动的优化，不是拍脑袋。

### 2.9 推理平面（模型在容器外）

- ✅ 痕迹：`JARVIS_INFERENCE_PROXY_SOCK=/run/hatch/proxy/inference.sock`；容器只有 2 核/7G。
- 🔍 强推断：前沿模型不可能跑在 2 核容器里 —— 推理服务在墙外，容器内经 unix socket 代理调用。容器是**工具执行沙箱**，不是模型运行环境。
- 💭 设计理由：解耦的三赢 —— 模型可独立扩缩容、按调用计费、多代模型灰度都不影响沙箱；沙箱只关心"执行"，不关心"智能"。这也是"云端大脑 + 本地手"的物理形态。

### 2.10 可观测性

- ✅ 痕迹：telemetry proxy、hatch-healthd、`spawnd queue-runtime-cell-bootstrap` 阶段上报；容器内 journal 只保留当次启动。
- 🔍 强推断：日志/指标一定在宿主机侧收集（容器是无状态的，靠它自己留日志不靠谱）。bootstrap 阶段上报说明冷启动的每个阶段都在被计时。
- 💭 生产级要点：能画出的 SLO 至少有：冷启动 P50/P99、handoff 成功率、epoch 推进延迟、容器启动失败率。墙内看不见任何指标 —— 这是"黑盒运维"的典型特征，也是有意为之（被观测者不需要知道自己被观测）。

### 2.11 安全平面

- ✅ 痕迹：sentinel（审批 + http-api）、safety/security.sock、privsep 目录、rescue-signal.sock + hatch-rescue 二进制、seccomp-bpf + NoNewPrivs、零 TCP 监听。
- 🔍 强推断：sentinel 是策略执行点（出站审批只是其中之一）；privsep 是特权分离执行器（高风险操作降权执行）；rescue 是自救通道（daemon 挂了能拉起来）。
- 💭 设计理由：假设容器**一定会被攻破** —— 所以能力（cap）没降（agent 要干活），但把"危险动作"收到几个 choke point（代理、审批、privsep）里。这是"纵深防御"的现代版本：不追求铜墙铁壁，追求**每个危险动作都可审计、可拦截**。

## 3. 核心设计决策及其理由

| 决策 | 理由（💭） |
|---|---|
| 嵌套：KVM + nspawn | 一层给隔离（防逃逸影响整机），一层给速度（秒级按需）。单用任一层都不够 |
| 按需容器 + 持久 home | 成本 vs 体验：2核/7G 常驻 per user 太贵；home 解耦后"销毁"不再可怕 |
| 三态存储（btrfs 文件 + Postgres 状态 + 外部上下文） | 按访问模式分层：大粒度低频放文件、小粒度高频放 DB、会话放外部注入 |
| 全出站 MITM 代理 + 审批 | DLP 与合规；策略运行时强制，不靠自觉 |
| handoff + hotset 预热 | 把冷启动重新定义为"带缓存的苏醒"，13 秒是可接受的 UX 代价 |
| 不可变配置（spawnd 渲染 + commit pin） | 可复现、可回滚、可审计；容器内不可改配置 |
| 计算/数据分区（zas/rcd） | 延迟、合规、成本的 trade-off（细节未知） |
| 推理在容器外 | 模型与沙箱独立演进、独立计费、独立扩缩容 |

一句话总结设计哲学：**"一次性工位，长期雇员"** —— 把所有"重"的东西（身份、数据、模型、策略）都抽到墙外，
墙内只剩一个轻到可以随时重生的执行环境。重的集中管，轻的随便扔。

## 4. 生产级复刻需要什么（诚实评估）

如果 demo 是"形态"，生产级就是"形态 × 10 个子系统"。按难度排：

| 组件 | 难度 | 说明 |
|---|---|---|
| 调度器 + VM 池 | 高 | 装箱、超售、驱逐、region-aware；这是最难的部分 |
| 镜像构建/发布管线 | 中 | CI + 内容寻址分层 + 灰度；工程量大但模式成熟 |
| 身份/CA 签发 | 中 | 短期凭证、按 cell 作用域；有现成方案（SPIRE 等）可借鉴 |
| 出站代理 + 审批 | 中 | MITM 代理集群 + 策略引擎；Squid/Enovy 可改 |
| 数据平面（btrfs 供应 + Postgres HA） | 中 | 卷编排、备份、handoff 一致性协议 |
| handoff warmer | 中 | 需要先有生产流量数据才知道"哪些块值得预热" |
| 可观测性 | 低 | 日志聚合 + 指标 + SLO，模式成熟 |
| 推理平面 | 高 | 这是模型本身，不在复刻范围内；demo 接外部 API 是正确选择 |

## 5. 未知清单（墙外黑盒）

1. 调度器：选机算法、pre-warm 水位、回收 idle 超时、超售比
2. hotset 生成策略：触发条件、tier1/tier2 语义、刷新周期
3. Postgres：主备形态、备份策略、schema
4. 出站审批策略：什么要批、谁来批、延迟多少
5. 入站面真实用途（ingress CA）
6. 计算/数据分区的真实含义（zas/rcd）
7. sentinel 的完整策略面
