# 多日补测记录与勘误（2026-09-28 → 10-01）

> 本仓库最早的几份文档（README / runtime-internals / architect-notes）写于 09-29 凌晨，只有一个实例的视角。
> 之后又做了几轮定向补测和跨天的纵向采样，部分早期结论被推翻或改写。本文集中记录：采样、补测结果、勘误、仍未知的问题。
> 所有数据都来自 cell 内部，由 Muse 在自己的环境里执行命令后回传；敏感值（实例 UUID、代理凭证、会话 ID）均已脱敏。

证据标记：✅ 实测（cell 内命令的直接输出）· 📘 官方（Meta 博客或官方架构图）· 🔍 推断（证据 + 工程常识，未直接验证）· ❓ 待确认

## 1. 样本

| 实例 | cell 启动 | 用途 |
|---|---|---|
| ① | 09-28 23:41 | 最初的 3 张架构分析截图（Muse 自述，无原始输出） |
| ② | 09-29 00:56 | 本仓库 README / runtime-internals / architect-notes 的采集对象 |
| ③ | 09-29 10:10 | 定向补测：uid_map、capability、btime/uptime、完整挂载表、socket 连接 |
| ④ | 09-30 08:24 | 纵向采样（一次性 cron 任务触发采集） |
| ⑤ | 10-01 13:10 | 纵向采样 + `/run` 设备号、device-mapper 类型、绕过代理直连、服务与区域线索 |

同一用户、prod 环境、一种 VM 规格（2 vCPU / 7.7 GiB）。

## 2. 生命周期：每次唤醒都是一台新起的 VM

### 判定方法

- `/proc/sys/kernel/random/boot_id` 在 cell 内被 nspawn 用一个 tmpfs 文件 overmount，**是 cell 级的值**，只能证明 cell 重建过，说明不了 VM 是否重启。✅
- `/proc/uptime` 与 `/proc/stat` btime 没有被覆盖，反映的是 VM 内核。uptime 第二个字段（全部 CPU 的累计空闲时间）不受命名空间虚拟化影响，实例 ③ 上为 5107 s ≈ 2 核 × 2770 s × 92%，与 uptime 吻合。✅
- btime 本身是「当前时间 − uptime」。VM 从快照恢复后挂钟被校准、uptime 接着快照走，btime 会跟着平移，所以**判据是 uptime 有多长，而不是 btime 变没变**：
  uptime ≈ cell 已运行时间 + 十几秒 → 新起的 VM；uptime 明显更长 → 常驻 VM 或快照延续。

### 纵向采样 ✅

| 实例 | VM 内核启动（btime，CST） | 采集时间 | uptime | PID 1 晚于内核 | handoff epoch | 本次会话触发 |
|---|---|---|---|---|---|---|
| ③ | 09-29 10:09:46 | 10:55:57 | 2770 s（46 min） | 14 s | 26 | 用户消息 |
| ④ | 09-30 08:24:14 | 10:13:04 | 6530 s（1.8 h） | 14–15 s ❓ | 35 | 一次性 cron 任务 |
| ⑤ | 10-01 13:09:44 | 13:51:47 | 2523 s（42 min） | 14–15 s | 41 | 用户消息 |

❓ 实例 ④ 的 PID 1 偏移：10-01 复核时记为 14–15 s，但 09-30 当天提交到 production-architecture.md §2.1 的记录是「约 74 秒」，需要用原始 `ps -o lstart= -p 1` 输出核对。

| 假设 | 预期 uptime | 判定 |
|---|---|---|
| H1：VM 常驻，只回收 cell | 以小时乃至天计 | ❌ 排除 |
| H2：恢复该用户上一次会话结束时的 VM 快照 | 上次会话时长 + 本次运行时间 | ❌ 排除 |
| H3a：全新冷启动 | ≈ cell 已运行时间 + 十几秒 | ✅ 相容 |
| H3b：从不含用户数据的通用预热快照恢复 | 同上 | ✅ 相容，与 H3a 无法区分 |

结论：三次采样都是新起的 VM，「每次唤醒都换一台 VM」可以作为工作假设，但样本只有三个。

### 其他观察

- 实例 ④ 的 VM 08:24 启动，比触发采集的 cron（10:13）早 1 h 49 min，所以不是这次 cron 唤醒的；**VM 被什么唤醒，cell 内看不出**。✅
- **空闲回收超时只有下界**：VM 至少存活 46 min（③）、1 h 49 min（④）。✅
- 10-01 的心跳任务每 30 分钟成功执行一次（09:58 → 13:28 共 8 次），但实例 ⑤ 的 VM 13:09:44 才启动，即 12:58 那次心跳后约 11 分钟内上一台 VM 已被回收。✅
  两种解释都说得通：定时任务不算「活跃」、不推迟回收；或者每次心跳都单独唤醒一台 VM、执行完重新开始空闲计时。🔍 需要每次心跳执行时记下 btime 才能区分。
- **handoff epoch 能跨 VM 接续**：26 → 35 → 41。epoch 文件所在的 `/run/hatch/resume` 是从 rv 卷 `/data/resume` bind 进来的，所以 VM 重建后自然还在，不需要「VM 外部恢复」的解释。✅
  epoch 记录的是交接次数，不是重启次数；每天一次采样拆不开「几次来自重建、几次来自运行中的 checkpoint」。

## 3. 冷启动时间线（实例 ③，以 VM 内核启动为 T+0）✅

| 时点 | 事件 | 证据 |
|---|---|---|
| T+0 s | VM 内核启动 | btime 10:09:46 |
| T+14 s | nspawn 拉起 cell | PID 1 启动于 10:10:00 |
| T+21 s | hotset 清单、写入 handoff-epoch | `hotset.manifest`、`handoff-epoch` mtime |
| T+24 s | Postgres 干净关闭证明 | `pg-clean.proof` |
| T+29–31 s | 身份就绪、handoff marker | `rv-identity-ready`、`handoff-marker.slot0` |
| T+33 s | 可以执行工具 | `execution-ready.marker` |
| T+38 s | 用户配置同步检查点 | `profile-sync-checkpoint-v2.json` |

截图里的「冷启动十几秒」只统计了 cell 内 journal，没有算上内核到 cell 的 14 秒和之后的状态恢复。如果 VM 是从通用预热快照恢复的，T+0 到 T+14 s 可能发生在制作快照时。

## 4. 存储 ✅

持久数据全部来自 `/dev/mapper/rv`（btrfs，`compress-force=zstd:3`，100 GB），按子路径 bind 到 cell：

| rv 卷内路径 | cell 内挂载点 | 读写 | 用途 |
|---|---|---|---|
| `/home/hatch` | `/home/hatch` | rw | 工作区、记忆文件、上传、skills |
| `/data/resume` | `/run/hatch/resume` | rw | handoff 世代、hotset 清单、恢复标记 |
| `/data/os-intent` | `/var/lib/hatch/os-intent` | rw | 🔍 用户对系统环境改动的账本；`ledger.jsonl` 自 09-27 创建以来一直 0 字节 |
| `/data/apt-archives` | `/var/cache/apt/archives` | rw | apt 包缓存 |
| `/data/catalog_search_media`、`/data/ticketmaster` | `/var/lib/hatch/…` | ro | 产品侧数据 |

- **`/` 是 overlay**：下层 VM 侧 `/var/lib/hatch-runtime/rootfs-base`（参数里写作 `lowerdir=/sysroot`），上层 VM 侧 `/run/hatch/overlay/upper`，`fsync=volatile`。两个路径都只在 VM 的挂载命名空间里，cell 内访问不到。✅
- **device-mapper 类型**（`/sys/block/dm-*/dm/uuid`）✅：
  - `rv` → `CRYPT-LUKS2`：LUKS2 加密卷，与官方架构图一致（📘 → ✅）。
  - `opt_hatch` → `CRYPT-VERITY`：dm-verity 校验的只读 squashfs，提供 `/opt/hatch`、`/home/hatch/assets` 等。
  - `root_overlay` → `CRYPT-PLAIN`：不带 LUKS 头的 plain 模式 dm-crypt，cell 内看不到挂在哪里。🔍 从名字看很可能是 overlay 写层的底座；plain 模式常配每次启动随机生成的密钥，加上 VM 每次新起，rootfs 写入应不跨实例保留——尚未直接验证。
- `/etc/hatch/credentials`、`/var/lib/hatch/postgres` 以 nspawn `--inaccessible` 屏蔽。✅
- 区域：`JARVIS_VM_COMPUTE_REGION=zas`、`JARVIS_VM_DATA_REGION=rcd`，计算区与数据区分开标注。✅ 两个代码各对应哪个机房，没有线索。

## 5. 隔离 ✅

- `uid_map` / `gid_map` = `0 131072 65536`：cell 内 root 映射为宿主上的非特权 uid。
- cell PID 1 `CapBnd=000001fff7b4cfff`：缺 `NET_ADMIN`、`NET_RAW`、`SYS_MODULE`、`SYS_RAWIO`、`SYS_PTRACE`、`SYS_BOOT`、`MKNOD`，与官方「无 `CAP_NET_ADMIN`」一致。
- hatch daemon、hatch-execd、工具 shell 的 `CapEff=000001fffff7ffff`，只缺 `SYS_PTRACE`。bounding set 只能继承缩小，这些进程的能力超出了 PID 1 的 bounding set，所以它们不是 cell 内 systemd fork 出来的，而是 VM 侧注入的（daemon PID 67 的 `ppid=0` 与此一致）。🔍 这些能力只对 cell 自己的 user namespace 生效。
- `Seccomp=2`（4 个 filter）、`NoNewPrivs=1`。
- cell 内 root 读 `/proc/67/{ns,root,fd,environ}` 被拒、`/proc/67/mountinfo` 可读：拦截来自内核 ptrace 访问检查的读取模式（`PTRACE_MODE_READ`），**不是** `kernel.yama.ptrace_scope=1`（yama 只管 ptrace attach）。

## 6. 网络 ✅

- `host0` 198.19.0.2/30 与 `fd8b:4f84:7d32:99::2/64`（ULA，cell ↔ 网关的内部地址，不是公网），网关 198.19.0.1 / `fd8b:4f84:7d32:99::1`。
- `hatch-egress-proxy` 解析为网关本身：出站代理在 VM 内、cell 外。
- **绕过代理会失败**：`curl --noproxy '*' -m 5` 访问 `https://example.com` 和 `https://1.1.1.1` 都返回 `000`（未建立连接），全程没有弹审批。与官方「userns + veth 边界 + eBPF 防绕过」相符（📘），具体拦截层 cell 内看不出。
- cell 内零 TCP 监听；`/opt/hatch/bin` 里有 `ingress-rev-proxy`。
- apt 更新时 `azure.archive.ubuntu.com` 可达、`mirror.cogentco.com` 全部失败。🔍 可能是代理按目标主机放行，也可能只是镜像本身不可用。

## 7. cell 与 VM 内服务的通信 ✅

- 环境变量声明 13 个 socket 路径，cell 文件系统里只能看到 `auth/authd.sock`、`sandbox-api/api.sock`、`telemetry/telemetry.sock`（外加 4 个 `sandbox/space-*.sock`）。
- 但 `/proc/net/unix` 里，Postgres、inference、stefi、cron-store、credit-watcher、safety、peerd、noded、exec、authd、whatsapp-keyd、telemetry 都有已建立的连接；sentinel 没有。**路径对工具进程隐藏，连接照常存在。**
- 内核语义（cell 内 `unshare -n` 对照实验确认）：服务端 accept 出来的 socket 记在**客户端**所在的网络命名空间里；带路径、`St=03` 的行是代理侧的 accepted 端，无路径的 `St=03` 是客户端。
- cell 内 `connect("/run/hatch/proxy/inference.sock")` → ENOENT；但推理期间连接持续新建和关闭（一次三步子 agent：9 → 16 对），是短连接，`sandbox/space-inference.sock` 上没有任何连接。
- 客户端 socket 在 cell 网络命名空间里创建，最可能的持有者是 VM 侧注入的 hatch daemon（PID 67）。它怎么连上一条工具 shell 看不到的路径：
  - ~~daemon 的 `/run` 是另一个 tmpfs~~：**已排除**，两边 `/run` 设备号都是 `0:75`。
  - 继承了指向 VM 侧 `/run/hatch/proxy` 的目录 fd；
  - VM 侧父进程代建连接后递 fd；
  - VM 侧进程只加入 cell 的网络命名空间直接连接。
  剩下三种都要看 PID 67 的 fd 表，cell 内读不到。
- stefi：skill 评测笔记里有「fix(stefi-proxy): route FlightAware to the passthrough proxy」，🔍 与出站路由有关的代理，完整职责未知。

## 8. 勘误：被推翻或改写的早期结论

| 早期说法 | 出处 | 更正 |
|---|---|---|
| VM 是常驻池，只有容器按需生灭 | architect-notes 开头 / §7，production-architecture §1 / §2.1 | 每次唤醒都是新起的 VM（§2），VM 整台按需启动、空闲回收 |
| `/home/hatch` 上叠了四层挂载 / 其上罩一层 overlay | README #7，runtime-internals §5，architect-notes §3 | overlay 在 `/` 上；`/home/hatch` 直接挂 rv 卷子路径（§4） |
| 用 boot_id 判断实例更替 | README #8 | boot_id 是 cell 级的；VM 层要看 uptime（§2） |
| 用 btime 变没变判断 VM 重建 | production-architecture §2.2 | btime 在快照恢复后会平移，判据改为 uptime 长度 |
| `/dev/mapper/rv` 的命名说明它是 LUKS 卷 | production-architecture §0 / §2.7 | device-mapper 命名本身不能说明加密；已由 dm uuid 实测确认 LUKS2 |
| yama（`ptrace_scope=1`）挡住了 PID 67 的 fd 表与 environ | production-architecture §2.13 | 挡住它的是 ptrace 访问检查的读取模式，yama 只管 attach |
| `/run/hatch/resume` 是宿主机 bind 进来的 tmpfs 内容 | architect-notes §1 | 来自 rv 卷 `/data/resume`，所以 epoch 能跨 VM 接续 |
| `fd8b:4f84:7d32:99::/64` 属于公网 | runtime-internals §7 | 是 cell ↔ 网关之间的 ULA 内部地址 |
| 冷启动约 13 秒 | README #5，pseudocode | cell 内 journal 窗口 13–19 秒；从 VM 内核算起约 33 秒才能执行工具（§3） |
| 推理客户端靠 dirfd 或代建 fd，二选一 | production-architecture §2.13 | 共四种候选，「daemon 有另一份 `/run`」已排除，其余三种 cell 内无法区分（§7） |

## 9. 仍未知

- peerd、credit-watcher、cron-store 的用途（cell 内找不到线索）；stefi 的完整职责。
- os-intent 重放：账本一直为空；10-01 尝试装包时 apt 找不到目标包，未能验证。可换一个 main 仓库里、尚未安装的小包重试。
- rootfs 写入是否跨实例保留：在 `/usr/local` 写标记文件，下次唤醒后检查；顺带确认 `root_overlay` 是否就是 overlay 写层的底座。
- VM 空闲多久被回收、被什么唤醒；冷启动还是从通用预热快照恢复。
- `zas` / `rcd` 对应哪个机房。
- 实例 ④ PID 1 偏移是 14–15 秒还是约 74 秒。
