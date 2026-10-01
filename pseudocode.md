# Muse 云服务生命周期伪代码

> 建模对象：一条用户消息从发出到收到回复，云端发生的完整生命周期。
> 基于实测验证的架构：Cloud Hypervisor VM → systemd-nspawn 容器 → btrfs 持久化 home。
> 详见 [README.md](./README.md) 的逐条验证。

```python
# ============ 实体 ============
# User:      长期身份（user_id），唯一不变的东西
# Home:      /home/hatch，btrfs 独立子卷，可挂载到任意容器实例上
# Container: systemd-nspawn 容器实例，一次性，可随时销毁
# VM:        Cloud Hypervisor 轻量虚拟机，容器的宿主
# Runtime:   Meta 的调度与上下文管理平面（容器内不可见）

# ============ 主流程：一条消息的旅程 ============
def handle_user_message(user_id, message):
    session = sessions.get(user_id)

    # --- 1. 按需唤醒：没有活着的容器，就造一个 ---
    if session is None or not is_alive(session.container):
        container = cold_start(user_id)      # 从 VM 内核算起约 33 秒可执行工具（cell 内 journal 只占 13–19 秒）
        session = Session(user_id, container)
        sessions[user_id] = session
    # 注意：容器被回收后重建时，Agent 本人"无感"——
    # 它没有亲历重启，只是醒来时发现上下文都在（忒修斯之船）。

    # --- 2. 执行：跑工具、调模型、读写文件 ---
    response = run_agent(session.container, message)

    # --- 3. 持久化：抽屉跟着人走 ---
    persist(session)   # home 本就在 btrfs 上，无需搬运；只落盘上下文水位

    # --- 4. 预约回收：工位是一次性的 ---
    schedule_reclaim(session.container, idle_timeout=DEFAULT_IDLE_TIMEOUT)

    return response


# ============ 冷启动：十几秒苏醒 ============
def cold_start(user_id):
    # --- 2a. 调度（容器内不可见，实测证实） ---
    host = runtime.scheduler.pick_host()   # 选一台物理机（AMD EPYC）
    # 镜像拉取、配额检查……这部分在真实云系统里经常才是大头

    # --- 2b. 外层：轻量虚拟机（每次唤醒新起一台；uptime 采样证实，不是快照延续） ---
    vm = cloud_hypervisor.create_vm(cpus=2, memory="7G")  # DMI: cloud-hypervisor
    # 冷启动还是从不含用户数据的通用预热快照恢复，cell 内无法区分

    # --- 2c. 内层：容器（systemd-nspawn，与宿主共享内核，非完整虚拟化） ---
    container = systemd_nspawn.launch(image=RUNTIME_IMAGE, vm=vm)
    # systemd 用户态启动约 2.3s：`Startup finished in 2.258s`

    # --- 2d. 挂载抽屉：rv 卷（btrfs + LUKS2）按子路径 bind ---
    # 根文件系统是 overlay（只读 rootfs-base + 易失写层），不跨实例保留
    container.mount(src="/dev/mapper/rv[/home/hatch]", dst="/home/hatch")
    container.mount(src="/dev/mapper/rv[/data/resume]", dst="/run/hatch/resume")  # handoff epoch 由此跨 VM 接续

    # --- 2e. Meta 定制服务 ---
    # hatch-ca-trust：从宿主机下发证书锚点，刷新容器内 CA 信任（"发身份证"）
    # hatch-execd：   常驻执行器，开 socket 守着，runtime 的每条命令经它执行
    # hatch daemon：  长期驻留的主守护进程
    container.start_services(["hatch-ca-trust", "hatch-execd", "hatch-daemon"])
    # 全部服务就绪约十几秒（实测 journal 窗口约 19s）

    # --- 2f. 叫醒：把"人"的记忆交还给新工位 ---
    context = runtime.context_store.load(user_id)  # 对话历史、记忆文件
    container.inject(context)                      # 醒来即"记得"你

    return container


# ============ 回收：机器是临时的 ============
def schedule_reclaim(container, idle_timeout):
    # 空闲超时后触发；调度器也可能因资源压力提前触发
    def on_timeout():
        # 整台 VM 连同容器一起销毁（三天的 uptime 采样都是新 VM）。
        # 状态在 rv 卷上，早就持久了，无需抢救数据。
        container.vm.destroy()   # VM uptime 清零，cell 级 boot_id 作废，日志从头开始
        # 下一次用户消息到来时，cold_start() 再造一个全新的。
        # Agent 不会"记得"自己被回收过，只能事后看日志推理出来——
        # 就像你看手表发现自己睡着了，却不记得入睡那一刻。
    runtime.timer.after(idle_timeout, on_timeout)


# ============ 为什么是"套娃"而不是传统 VPS ============
# 传统 VPS：整台虚拟机常驻，又贵，启动以分钟计，机器 == 身份。
# 本架构：
#   VM 层（Cloud Hypervisor/KVM）——租户隔离，每用户一台，按需启动、整台回收
#   容器层（systemd-nspawn）      —— 与 VM 共享内核，在同一台 VM 里切出第二个安全域
#   身份层（user_id + 持久 home） —— 与实例彻底解耦
# 结果：用户感知到的是"永远在线的 Muse"，
#       实际是"不断重生的容器 + 永生的抽屉"。
```
