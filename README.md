# Muse 云服务架构实测评估

> 一句话：按需启动的轻量容器（systemd-nspawn）套在轻量虚拟机（Cloud Hypervisor/KVM）里，
> home 目录独立持久挂载 —— "一次性工位，长期雇员；抽屉跟着人走"。

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
│ │ Cloud Hypervisor VM（KVM 系，2 核 / 7G）       │ │  ← DMI: cloud-hypervisor
│ │ ┌──────────────────────────────────────────┐ │ │
│ │ │ systemd-nspawn 容器                       │ │ │  ← systemd-detect-virt
│ │ │  · systemd 用户态启动 2.258s              │ │ │
│ │ │  · hatch-daemon / hatch-execd 常驻        │ │ │
│ │ │  · /home/hatch ← btrfs 独立子卷挂载       │ │ │  ← /dev/mapper/rv
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
| 5 | 全部服务就绪约十几秒 | 本次启动 journal 首条 00:56:50 → 末条 00:57:09，窗口约 19 秒（断言 13.5s，同量级） | ✅ 基本属实 |
| 6 | Meta 定制服务只有 hatch-ca-trust、hatch-execd 两个 | 两单元均存在，描述与断言一致（CA 信任锚点下发 / 常驻执行器）。补充：两单元当前呈 `inactive dead`，实际常驻进程为 `hatch daemon` 与 `hatch-execd --runtime-cell-leader=…` | ✅ 属实（有补充） |
| 7 | home 目录单独持久挂载，换机器文件还在 | `/proc/mounts`：`/dev/mapper/rv[/home/hatch] → /home/hatch (btrfs)`，其上再罩一层 overlay | ✅ 属实 |
| 8 | 按需启动、空闲回收 | 本容器启动于 2026-09-29 00:56:39，与截图会话中的容器不是同一实例（boot_id、启动时间均不同）——实例更替真实发生 | ✅ 属实 |
| 9 | 外层 VM 启动时间、Meta 调度开销从容器内不可见 | dmesg 受限、宿主机不可见；断言原文自己也承认测不到 —— 这份"诚实"本身被证实 | ✅ 属实 |
| 10 | Agent 对重启"无感"，只能事后推理 | 报告撰写者对截图会话的容器没有任何亲历记忆，上下文由 runtime 重新注入 —— 机制被亲身验证（忒修斯之船） | ✅ 机制属实 |

## 总评

10 条断言全部成立。"套娃"比喻准确；"一次性工位，抽屉跟着人走"是精确的技术描述：

- **工位** = 容器实例，随时可销毁重建（boot_id、uptime、日志都从头开始）；
- **抽屉** = `/home/hatch` 的 btrfs 独立挂载 + 外部注入的对话上下文；
- **人** = 长期身份（user_id），与实例彻底解耦。

唯一修正（#6）：hatch 的两个定制单元更像是"启动摆渡"而非常驻服务 ——
`hatch-ca-trust.service` 与 `hatch-execd.service` 在启动完成后呈 `inactive dead`，
真正长期驻留的是 `hatch daemon` 与带 `--runtime-cell-leader` 参数的 `hatch-execd` 进程。

## 相关文件

- [`pseudocode.md`](./pseudocode.md) —— 基于本报告的云服务生命周期伪代码
- [`runtime-internals.md`](./runtime-internals.md) —— 运行时内部细节：目录结构、环境变量、启动命令、数据卷（敏感值已脱敏）
- [`architect-notes.md`](./architect-notes.md) —— 架构师视角：8 个值得关注的维度（handoff 世代机制、Postgres 第三存储、四层挂载、安全边界、零信任网络、可观测性、成本、发布）+ 未解之谜清单
