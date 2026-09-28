# 运行时内部细节：目录、配置、环境变量、启动命令、数据卷

> 实测时间 2026-09-29 02:20（CST），对象为当前容器实例。
> 敏感值（代理凭证、实例 UUID、会话 ID）已脱敏，仅保留变量名与结构。

## 1. 操作系统

- 发行版：**Ubuntu 24.04.5 LTS**（`/etc/os-release`）
- 内核与容器共享（systemd-nspawn 非完整虚拟化），`hypervisor` CPU flag 置位
- 容器名（宿主机视角）：`htch-runtime`，veth 网卡：`ve-htch-runtime`

## 2. 文件结构

```
/
├── opt/hatch/                  # Hatch 产品包（随镜像提供）
│   ├── bin/                    # 70+ 可执行文件：hatch, hatch-execd, hatch daemon,
│   │                           # 各 skill 的 CLI（gmail 走 hatch_gws_cli …）
│   ├── skills/                 # 71 个 skill 定义（SKILL.md + 配套 manifest）
│   ├── runtime-cell/           # 容器启动脚本（见 §4）
│   └── assets/                 # blocklist、ideas 等静态资源
├── opt/hatch-image/bin/        # 镜像侧工具（bun、npm…），在 PATH 中
├── home/hatch/                # ← 持久化"抽屉"（见 §5 数据卷）
│   ├── AGENTS.md / SOUL.md / MEMORY.md / USER.md …  # Agent 自述与记忆文件
│   ├── config/                 # home.yaml、skills.yaml、工作区状态
│   ├── docs/                   # 产品文档（~/docs/*.md）
│   ├── memory/ / dreams/       # 长期记忆与关系图谱
│   ├── workspace/              # 工作区（含 skills、goals、projects）
│   └── uploads/                # 用户上传文件中转
└── run/hatch/                  # 运行时总线（tmpfs，随容器生灭）
    ├── cell-anchors/           # 宿主机下发的 CA 锚点（hatch-egress-ca.pem…）
    ├── egress-tls/             # ca-bundle.pem（见 §3）
    ├── runtime-cell/           # runtime-cell.ready 就绪标记等
    ├── auth/ privsep/ sandbox/ sandbox-api/ telemetry/ …  # 各子系统目录
    └── *.sock（见 §3）          # 进程间通信 socket 总线
```

## 3. 环境变量（已脱敏）

### 身份与路由

| 变量 | 值（脱敏） | 说明 |
|---|---|---|
| `JARVIS_HATCHLING_ID` | `<uuid>` | 本容器的长期身份，"人"的部分 |
| `JARVIS_FQDN` | `<hatchling-id>.metaaivm.com` | 本机域名 |
| `JARVIS_SESSION_ID` / `JARVIS_TOOL_CALL_ID` | `<uuid>` / `call_…` | 当前会话与工具调用 |
| `JARVIS_VM_COMPUTE_REGION` / `JARVIS_VM_DATA_REGION` | `zas` / `rcd` | 计算/数据区域 |
| `JARVIS_TIER` / `JARVIS_REQUEST_MODE` | `prod` / `production` | 生产环境 |
| `JARVIS_USER_TIMEZONE` / `TZ` | `Asia/Shanghai` | 跟着用户走的时区 |
| `JARVIS_PRESENTATION_LOCALE` | `zh-CN` | 回复语言 |

### 网络：所有出口走代理

```bash
HTTP_PROXY=http://hatch-runtime:<redacted>@hatch-egress-proxy:3128
HTTPS_PROXY=...   # 同上
ALL_PROXY=...     # 同上（含大小写两套）
NO_PROXY=localhost,127.0.0.1,::1,198.19.0.1,198.19.0.2,fd8b:4f84:7d32:99::1,…
```

- 网关 `198.19.0.1`、本机 `198.19.0.2/30`（与 `ensure-rootfs.sh` 中的写死网段一致，见 §4）
- 代理凭证是按实例签发的（`<redacted>` 部分每次不同），静态模板 `guest.env` 里只有无凭证的裸地址

### TLS：证书信任链

```bash
SSL_CERT_FILE=/run/hatch/egress-tls/ca-bundle.pem
CURL_CA_BUNDLE=…   AWS_CA_BUNDLE=…   GIT_SSL_CAINFO=…
NODE_EXTRA_CA_CERTS=…   REQUESTS_CA_BUNDLE=…
```

6 个变量指向同一份 CA bundle —— 这正是 `hatch-ca-trust.service` 的工作成果（见 §4）。

### 进程间总线：/run/hatch 下的 socket

| 变量 | socket | 用途 |
|---|---|---|
| `HATCH_API_SOCKET` | `/run/hatch/daemon/http-api.sock` | 主守护进程 HTTP API |
| `JARVIS_SENTINEL_HTTP_API_SOCKET` | `/run/hatch/sentinel/http-api.sock` | 哨兵/风控 |
| `JARVIS_INFERENCE_PROXY_SOCK` | `/run/hatch/proxy/inference.sock` | 模型推理代理 |
| `JARVIS_MEMORY_SOCK` | `/run/hatch/memory/memory.sock` | 记忆服务 |
| `JARVIS_SANDBOX_API_SOCK` | `/run/hatch/sandbox-api/api.sock` | 沙箱 API |
| `JARVIS_SECURITY_SOCK` | `/run/hatch/safety/security.sock` | 安全策略 |
| `JARVIS_RESCUE_SIGNAL_SOCK` | `/run/hatch/rescue/rescue-signal.sock` | 自救信号 |
| `JARVIS_TELEMETRY_PROXY_SOCK` | `/run/hatch/telemetry/telemetry.sock` | 遥测 |
| `JARVIS_EGRESS_APPROVAL_*` | `/run/hatch/sentinel/egress-approvals-*.sock` | 出站审批 |

### 其他

```bash
PATH=/opt/hatch/bin:/opt/hatch-image/bin:/usr/local/sbin:…:/opt/hatch/skills/*/scripts
HOME=/home/hatch   JARVIS_HOME=/home/hatch   JARVIS_BIN_DIR=/opt/hatch/bin
WGETRC=/opt/hatch/runtime-cell/etc/wgetrc
```

## 4. 启动命令

### 宿主机侧（容器外，看不见但留下了痕迹）

```
pre-start.sh  →  ensure-rootfs.sh  →  launch-daemon.sh  →  systemd-nspawn 启动 htch-runtime
```

- `pre-start.sh`：`machine=htch-runtime`，`veth=ve-htch-runtime`，准备 `/run/hatch/runtime-cell/runtime-cell.ready` 就绪标记
- `ensure-rootfs.sh`：rootfs 位于宿主机 `/var/lib/hatch-runtime/rootfs`；写死网段 `198.19.0.2/30`（本机）/`198.19.0.1`（网关）
- `launch-daemon.sh`：经 `spawnd` 上报 bootstrap 阶段，`resolve-rootfs-path.sh` 定位 rootfs 后拉起 nspawn

### 容器内 systemd 单元

**hatch-ca-trust.service**（Type=oneshot，启动时跑一次 —— 这就是"发身份证"）：

```ini
[Unit]
Description=Refresh guest CA trust from host-published hatch anchors
ConditionPathIsDirectory=/run/hatch/cell-anchors

[Service]
Type=oneshot
ExecStart=/usr/bin/mkdir -p /usr/local/share/ca-certificates
ExecStart=/usr/bin/ln -sfn /run/hatch/cell-anchors/hatch-egress-ca.pem /usr/local/share/ca-certificates/hatch-egress-ca.crt
ExecStart=/usr/bin/ln -sfn /run/hatch/cell-anchors/hatch-ingress-ca.pem /usr/local/share/ca-certificates/hatch-ingress-ca.crt
ExecStart=/usr/sbin/update-ca-certificates
```

**hatch-execd.service**（注意：当前为 `inactive dead`，原因见下）：

```ini
[Service]
Type=simple
ExecStartPre=/bin/sh -c 'test -f /opt/hatch/runtime-cell/runtime-cell.ready'
ExecStart=/opt/hatch/runtime-cell/run-execd.sh --socket /run/hatch/execd/execd.sock
WorkingDirectory=/home/hatch
Restart=always
```

> 发现：`ExecStart` 引用的 `/opt/hatch/runtime-cell/run-execd.sh` **在当前镜像中不存在** ——
> unit 文件是残留的旧版本。实际常驻的是 `ps` 可见的两个进程：
> `/opt/hatch/bin/hatch daemon` 与 `/opt/hatch/bin/hatch-execd --runtime-cell-leader=2061`，
> 由宿主机侧的 `control-execd.sh` 等脚本直接拉起，不经过这个 unit。

## 5. 数据卷

`/proc/mounts` 中与持久化相关的条目：

```
overlay /home/hatch overlay rw,relatime,
    lowerdir=/sysroot,upperdir=/run/hatch/overlay/upper,workdir=/run/hatch/overlay/work,…
/dev/mapper/rv /home/hatch btrfs rw,nosuid,nodev,noatime,
    compress-force=zstd:3,ssd,discard=async,space_cache=v2,subvol=/
```

解读 —— "抽屉"的两层结构：

1. **底层（btrfs）**：`/dev/mapper/rv` 上的子卷，`zstd:3` 强制压缩。机器销毁后数据仍在，这是"换机文件还在"的物理基础。
2. **上层（overlay）**：`lowerdir=/sysroot`（只读镜像层）+ `upperdir=/run/hatch/overlay/upper`（本容器写层）。容器内看到的 `/home/hatch` 是合并视图。

其余挂载均为常规容器标配（cgroup、/proc、/sys、tmpfs），无特殊。

## 6. 没有 Dockerfile

明确说明：**本架构不使用 Docker，没有 Dockerfile**。

- systemd-nspawn 不吃 Dockerfile，它要的是一份 **rootfs 目录**（这里是 Ubuntu 24.04.5 + Hatch 产品层），由宿主机上的 `ensure-rootfs.sh` / `resolve-rootfs-path.sh` 准备，位于宿主机 `/var/lib/hatch-runtime/rootfs`。
- 等价的"镜像构建"逻辑散在 `runtime-cell/*.sh` 脚本里（bootstrap rootfs、修 `/etc/hosts`、BindReadOnly 挂载静态配置），而不是一个声明式的 Dockerfile。
- 如果硬要类比：`rootfs 目录 == Docker image`，`machinectl start htch-runtime == docker run`，`--bind` 挂载 `== -v` 数据卷。

## 7. 网络拓扑（小结）

```
容器(198.19.0.2) --veth ve-htch-runtime--> 网关(198.19.0.1, 宿主机)
        │
        │  所有出站 HTTP(S)
        ▼
hatch-egress-proxy:3128（按实例凭证，TLS 经自签 CA）
        │
        ▼
   公网（含 IPv6 fd8b:4f84:7d32:99::/64 ULA 段）
```
