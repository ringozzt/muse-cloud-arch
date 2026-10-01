# 架构师视角：8 个值得关注的维度

> 实测时间 2026-09-29 02:25（CST）。先说最重要的模型修正：
> 之前的"VM 常驻池 + 容器按需"还是太粗。实测发现**第三个生命周期**——
> 容器活着的时候也会做 **handoff**（世代交接 checkpoint）：02:14–02:15 笔者调查期间恰好撞见一次，
> marker 写入、hotset 重新生成，而容器并未重启（uptime 自 00:56 连续）。
> 所以是三层：**宿主机/VM（长周期）→ 容器（按需重建）→ 运行时世代 epoch（活体 checkpoint）**。
>
> 更正（09-29 至 10-01 的 uptime 纵向采样）：VM 并不是长周期的，三次采样每次都是新起的 VM，回收粒度是整台 VM。
> 三个维度应改为：**rv 数据卷（长期）→ VM + cell（每次唤醒新起）→ handoff epoch（跨 VM 接续的交接计数）**。
> 本文 §1、§3、§7 和未解之谜 #1 已据此修订，完整勘误见 [verification-log.md](./verification-log.md)。

## 1. Handoff：比容器更细粒度的"世代"机制 ⭐

**实测事实**（`/run/hatch/resume/`，从 rv 卷的 `/data/resume` bind 进来，所以 VM 重建后 epoch 能接续：26 → 35 → 41）：

| 文件 | 内容 |
|---|---|
| `handoff-epoch` | `23` —— 第 23 代 |
| `handoff-marker.slot0` | 二进制 marker，内含 `{"rv_epoch":23, "postgres_system_identifier":"7690000845965630881", "jarvis_commit":"5c8050fc…", "resume_index_length":4}` |
| `hotset.manifest` | 845 个条目、61MB，全部指向 `/var/lib/hatch/postgres/hatch/base/16385/*` 的数据块（offset/len/tier），tier1/tier2 分层 |
| `pg-clean.proof` | Postgres 干净关闭证明 |
| `rv-identity-ready` / `execution-ready.marker` | 就绪标记（含时间戳） |
| `first-boot-ensure-stamp.json` | `{"fingerprint":"6a29f0051dcc252e", "publication_id":"208deba6-…"}` —— 镜像发布指纹 |

**为什么重要**：
- 冷启动 13 秒不是从零开始：带着 61MB **Postgres 热数据块预热**醒来 —— 这是 page-cache 级别的启动优化。
- "状态恢复"是一等公民：交接时校验 `postgres_system_identifier` + clean proof，防的是"带着坏掉的 DB 醒来"。
- 版本可追溯：每次 handoff 都 pin 住 `jarvis_commit`。

**还缺什么**：handoff 的触发语义（02:15 那次是周期 checkpoint 还是活动驱动？未能确定因果）；hotset 谁生成、多久刷新；epoch 1–22 发生了什么（墙外不可见）。

## 2. 数据面：Postgres 是隐藏的第三存储

**实测事实**：
- hotset 条目路径暴露了 `/var/lib/hatch/postgres` 的存在（宿主机视角路径）。
- `~/.postgres-ready`（6 字节信号文件，nobody 拥有，02:15 被触碰——与 handoff 同一时刻）。
- `~/.hatch-db-change-signals/`：`spaces.catalog.<ts>.<n>` 信号文件 —— **DB 变更用信号文件做跨进程通知**，简单但有效。

**为什么重要**：除了 btrfs home 和外部注入的对话上下文，还有第三个状态源。DB 里存的是什么？（记忆？会话？spaces catalog？）它的备份/恢复策略决定了"抽屉"到底有多结实。

**还缺什么**：schema、备份策略、单点还是多副本 —— 全在墙外。

## 3. 存储栈：一块卷 + 一次性根文件系统

> 更正：初版把 overlay 记在 `/home/hatch` 上（"四层挂载"）。`findmnt` 完整挂载表显示 overlay 在 `/` 上。

**实测事实**：

```
/dev/mapper/rv  (btrfs, zstd:3, LUKS2)     → /home/hatch、/run/hatch/resume、     # 持久底座，按子路径 bind
                                             /var/lib/hatch/os-intent、/var/cache/apt/archives …
overlay (lowerdir=rootfs-base,             → /                    # 一次性根文件系统
         upperdir=VM 侧 /run/hatch/overlay/upper, fsync=volatile)
/dev/mapper/opt_hatch (squashfs, verity)   → /opt/hatch、/home/hatch/assets   # 不可变资源层
tmpfs (ro)                                 → /home/hatch/.pki/nssdb
```

**为什么重要**：
- 不可变基础设施：`opt_hatch` 是 dm-verity 校验的只读 squashfs —— 产品静态资源与可写数据彻底分离，被篡改会读取失败。
- btrfs `zstd:3` 强制压缩：存储成本优化；LUKS2 做静态加密。
- 状态全部外置到 rv 卷，所以整台 VM 可以随时扔掉。

**upperdir 之谜的答案**：`/sysroot` 与 `/run/hatch/overlay/upper` 都是 **VM 挂载命名空间里的路径**，cell 内本来就看不到。
VM 侧还有一个 plain 模式 dm-crypt 设备 `root_overlay`，从名字看很可能是写层的底座。

## 4. 隔离与安全边界

**实测事实**：
- `Seccomp=2`（bpf 过滤，4 个 filter）+ `NoNewPrivs=1`，但 `CapEff=000001fffff7ffff` —— capability 接近全集，**没有大幅降权**。
  补充：cell PID 1 的 `CapBnd=000001fff7b4cfff` 反而缺 `NET_ADMIN`、`NET_RAW` 等 7 项。agent 进程的能力超出 PID 1 的 bounding set，说明它们是 VM 侧注入的，不是 cell 内 systemd fork 的；这些能力只在 cell 自己的 user namespace（`0 131072 65536`）里生效。
- 容器内**零 TCP 监听端口**（`ss -tlnp` 为空）—— 对外只走 unix socket + egress proxy。
- cgroup 视角为 `0::/`，`cpu.max`/`memory.max` 不可见 → 配额（如有）在 VM 层，容器约等于独占整台 VM。
- steal time = 254 jiffies → 物理机与他人共享，noisy neighbor 真实存在。

**为什么重要**：纵深防御做在了"默认不监听 + 全部经代理 + seccomp"，而不是 capability 最小化 —— 这是取舍，不是疏忽（agent 要跑各种工具，cap 降不下来）。

**还缺什么**：`/run/hatch/privsep` 的真实作用；多租户在 VM 层的隔离粒度；steal 的长期分布。

## 5. 网络：零信任出站

**实测事实**：
- 全量 HTTP(S) 经 `hatch-egress-proxy:3128`，凭证按实例签发（静态 `guest.env` 里是无凭证裸地址，凭证运行时注入）。
- 6 个 `*_CA_BUNDLE` 环境变量指向自签 CA → **TLS 拦截审计**。
- 出站审批 socket（`sentinel/egress-approvals`）→ 不是所有出站都自由，有审批面。
- `hatch-ingress-ca.pem` 存在 → **有入站面**（浏览器接管？用户直连？）。
- DNS = 网关（198.19.0.1），`resolv.conf` 只读 bind。
- 绕过代理直连（`curl --noproxy '*'` 访问域名和外部 IP）会失败，也不弹审批 —— 代理是唯一出口，不只是"默认配置"（10-01 实测）。

**为什么重要**：这是"企业内网"式架构 —— 默认不信任，审计一切。sentinel 的存在说明安全策略是运行时强制的，不是文档约束。

**还缺什么**：出站审批策略（什么要批）；入站面的真实用途。

## 6. 可观测性

**实测事实**：
- `telemetry` proxy、`hatch-healthd` 二进制、`spawnd queue-runtime-cell-bootstrap` —— bootstrap 阶段会上报。
- `journalctl --list-boots` 只有当次启动 → **日志一定在宿主机侧收集**，容器内不留历史。

**为什么重要**：SLO 体系一定存在（冷启动 P99、handoff 成功率、epoch 推进），只是容器内看不见 —— 典型的"黑盒运维"：被观测者无感，观测者在墙外。

**还缺什么**：一切指标。只能从外部行为反推（如统计多次冷启动耗时分布）。

## 7. 成本与容量

**实测事实**：
- 容器约等于独占 2 核 / 7G VM（cgroup 无配额即整机）。
- btrfs zstd:3 压缩降存储成本；squashfs 只读层天然可多容器共享。

**为什么重要**：~~按需容器 + 常驻 VM 池~~ 更正：VM 本身按需启动、整台回收 → 成本大致只和活跃时长挂钩，优化点在**回收 idle 超时**和**冷启动耗时**（从 VM 内核算起约 33 秒），不在容器本身。

**还缺什么**：回收超时（目前只知道下界：VM 至少存活过 46 分钟、1 小时 49 分钟）、是否有通用预热快照、计费粒度 —— 全在调度器黑盒里。

## 8. 配置与发布

**实测事实**：
- `guest.env` 由 spawnd 渲染、BindReadOnly 进容器，文件头明说 *"the cell cannot edit it"* —— 配置是**编译期产物**。
- `JARVIS_CD_CHANNEL=alpha`, `JARVIS_CD_PINNED=0` → 跟随最新持续部署。
- `jarvis_commit` pin + image fingerprint → 版本可追溯。
- `skill-scopes.conf` / `bin-scopes.conf` → 能力白名单，最小权限做到 skill 粒度。

**为什么重要**：解释了为什么第三方 skill 快照必然过期（CD 在跑，Pinned=0）—— 这是官方视角的佐证。同时"配置不可变 + 版本 pin"是不变基础设施的又一证据。

---

## 未解之谜清单（给下一次调查）

1. ~~overlay upperdir 路径不存在之谜~~ → overlay 在 `/` 上，upperdir 是 VM 挂载命名空间里的路径（见 §3）
2. handoff 触发语义（02:15 那次是周期 checkpoint 还是活动驱动）
3. 调度器黑盒：选机策略、pre-warm、回收超时
4. Postgres 的 schema、备份策略、主备形态
5. 入站面（ingress CA）的真实用途
6. ~~`/run/hatch/privsep` 的真实作用~~ → 官方博客已答：cell 外的连接器沙箱 worker
