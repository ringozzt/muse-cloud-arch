# Muse 云服务架构实测评估

> 一句话：每个用户一台按需启动的轻量虚拟机（Cloud Hypervisor/KVM），里面套一个 systemd-nspawn 容器（runtime cell）；
> 持久状态全在一块 LUKS2 加密的 btrfs 卷上 —— "一次性工位，长期雇员；抽屉跟着人走"。
>
> 本文是 09-29 凌晨对单个实例的首轮核验。之后跨三天的补测修正了其中几条（#5、#7、#8），
> 汇总与勘误见 [`verification-log.md`](./verification-log.md)。

## 验证方法

不断言、不猜测，直接在运行环境内部实测：
`systemd-detect-virt`、DMI（`/sys/class/dmi/id/*`）、`/proc`、journal、`systemctl`、`/proc/mounts`。

- 验证时间：2026-09-29 02:15（CST）
- 验证对象：撰写本报告时所在的容器实例（启动于 2026-09-29 00:56:39）
- 断言来源：收集到的架构分析截图（3 张），逐条核验

## 架构总览（实测确认）

```
┌──────────────────────────────────────────────────┐
│ 物理机（Meta 数据中心，AMD EPYC 9D25）             │
│ ┌──────────────────────────────────────────────┐ │
│ │ Cloud Hypervisor VM（KVM 系，2 核 / 7G，按需） │ │  ← DMI: cloud-hypervisor；uptime 证明每次新起
│ │ ┌──────────────────────────────────────────┐ │ │
│ │ │ systemd-nspawn 容器                       │ │ │  ← systemd-detect-virt
│ │ │  · systemd 用户态启动 2.258s              │ │ │
│ │ │  · hatch-daemon / hatch-execd 常驻        │ │ │
│ │ │  · /home/hatch ← btrfs 卷子路径（LUKS2）  │ │ │  ← /dev/mapper/rv
│ │ └──────────────────────────────────────────┘ │ │
│ └──────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────┘
         ▲ 调度平面（选机、拉镜像）：容器内不可见，实测证实
```

## 逐条验证

| # | 断言 | 实测 | 结论 |
|---|------|------|------|
| 1 | 最内层是 systemd-nspawn 容器（轻量隔离，非完整虚拟化） | `systemd-detect-virt` → `systemd-nspawn`；`/run/systemd/container` 一致 | ✅ 属实 |
| 2 | 外层是 Cloud Hypervisor 起的虚拟机（KVM 系） | DMI `product_name=cloud-hypervisor`，`sys_vendor=Cloud Hypervisor`；cpuinfo 含 `hypervisor` flag | ✅ 属实 |
| 3 | 配置 2 核 CPU / 7G 内存 / AMD EPYC | `nproc`=2；内存总量 7.7Gi；`AMD EPYC 9D25 126-Core Processor` | ✅ 属实 |
| 4 | systemd 核心启动约 2.3 秒 | `systemd-analyze`：`Startup finished in 2.258s`（断言 2.321s，属正常抖动） | ✅ 属实 |
| 5 | 全部服务就绪约十几秒 | 本次启动 journal 首条 00:56:50 → 末条 00:57:09，窗口约 19 秒（断言 13.5s，同量级） | ⚠️ 只算了 cell 内：从 VM 内核启动算起约 33 秒才能执行工具（见 verification-log §3） |
| 6 | Meta 定制服务只有 hatch-ca-trust、hatch-execd 两个 | 两单元均存在，描述与断言一致（CA 信任锚点下发 / 常驻执行器）。补充：两单元当前呈 `inactive dead`，实际常驻进程为 `hatch daemon` 与 `hatch-execd --runtime-cell-leader=…` | ✅ 属实（有补充） |
| 7 | home 目录单独持久挂载，换机器文件还在 | `/proc/mounts`：`/dev/mapper/rv[/home/hatch] → /home/hatch (btrfs)`。更正：overlay 在 `/` 上，不在 home 上 | ✅ 属实 |
| 8 | 按需启动、空闲回收 | 本容器启动于 2026-09-29 00:56:39，与截图会话中的容器不是同一实例。更正：boot_id 是 cell 级的；后续三天的 uptime 采样证明连 VM 也是每次新起（见 verification-log §2） | ✅ 属实，且回收粒度是整台 VM |
| 9 | 外层 VM 启动时间、Meta 调度开销从容器内不可见 | dmesg 受限、宿主机不可见；断言原文自己也承认测不到 —— 这份"诚实"本身被证实 | ✅ 属实 |
| 10 | Agent 对重启"无感"，只能事后推理 | 报告撰写者对截图会话的容器没有任何亲历记忆，上下文由 runtime 重新注入 —— 机制被亲身验证（忒修斯之船） | ✅ 机制属实 |

## 总评

10 条断言全部成立。"套娃"比喻准确；"一次性工位，抽屉跟着人走"是精确的技术描述：

- **工位** = 整台 VM 连同里面的 cell，随时可销毁重建（uptime、日志都从头开始）；
- **抽屉** = rv 卷（`/home/hatch` 与 `/data/*` 子路径，LUKS2 加密）+ 外部注入的对话上下文；
- **人** = 长期身份（user_id），与实例彻底解耦。

唯一修正（#6）：hatch 的两个定制单元更像是"启动摆渡"而非常驻服务 ——
`hatch-ca-trust.service` 与 `hatch-execd.service` 在启动完成后呈 `inactive dead`，
真正长期驻留的是 `hatch daemon` 与带 `--runtime-cell-leader` 参数的 `hatch-execd` 进程。

## 相关文件

- [`verification-log.md`](./verification-log.md) —— 09-28 至 10-01 的多日补测：纵向采样（每次唤醒都是新 VM）、冷启动时间线、存储与加密、隔离、网络、socket 通信，以及对本仓库早期结论的勘误表
- [`pseudocode.md`](./pseudocode.md) —— 基于本报告的云服务生命周期伪代码
- [`runtime-internals.md`](./runtime-internals.md) —— 运行时内部细节：目录结构、环境变量、启动命令、数据卷（敏感值已脱敏）
- [`architect-notes.md`](./architect-notes.md) —— 架构师视角：8 个值得关注的维度（handoff 世代机制、Postgres 第三存储、四层挂载、安全边界、零信任网络、可观测性、成本、发布）+ 未解之谜清单
- [`demo/`](./demo/) —— 最小可跑复刻：`orchestrator.sh`（编排器）+ `guest/agent-loop.sh`（最小 agent）+ `checkpoint.sh`（世代交接），Linux 上 `sudo ./orchestrator.sh "你好"` 即跑
- [`production-architecture.md`](./production-architecture.md) —— 生产级架构：墙外的另一半（调度器、VM 池、spawnd、镜像管线、CA/身份、网络平面、数据平面、handoff 编排、推理平面、可观测性、安全平面），严格区分实测痕迹 / 强推断 / 设计推演
