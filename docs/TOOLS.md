# 配套工具（Linux / WSL）

> [← 返回 README](../README.md) · Windows 运维机工具见 [WIN_TOOLS.md](WIN_TOOLS.md) · 压测参数见 [USAGE.md](USAGE.md)
>
> 本文件是工具**索引**：逐脚本的参数、判据与实现要点见 [tools/README.md](../tools/README.md)、
> [test/README.md](../test/README.md)、[tools/agent/README.md](../tools/agent/README.md)。

## 统一约定

| 约定 | 说明 |
|------|------|
| 帮助入口 | 脚本支持 `-h` / `--help`（打印头部注释块）。唯一例外为 `tools/redfish_fw_list.sh`：由 `modules/12_bmc.sh` 内部调用，只接受两个位置参数，无帮助分支 |
| 带值参数 | 缺参时明确报错并 `exit 1`（`shift 2` 在只剩一个参数时是静默 no-op，会使 `while` 永不前进） |
| 远程凭据 | 一律交互式输入密码（SSH ControlMaster 或 askpass 复用）；**不使用 `sshpass` 等明文密码方式**，密码不落盘、不进命令行与进程列表 |
| 报告预览 | `report/tools/report_server.sh` 必须 `--bind 127.0.0.1`：报告含 SN / MAC，不得暴露至局域网 |
| 时间戳 | 文件名时间戳统一 `date '+%Y%m%d%H%M%S'`，14 位连写 |

## `test/` — 硬件压测

> ⚠️ **状态：占位。** 测试项目尚未定稿，未经真实硬件验证（参数取值、输出正确性、判定口径均未检验）。
> 本模块结果**不构成验收结论**；交付验收以厂商工具（DCGM / NCCL / FLD 等）为准。

架构（v1.34.21）：聚合与实现解耦 —— `test_all.sh` 为纯聚合入口（菜单 / `--all`），单工具脚本位于
`test/<组件>/` 且可独立执行，公共库为 `test/lib/test_common.sh`。

| 单脚本 | 测试内容 | 参数 | 说明 |
|--------|---------|------|------|
| `cpu/cpu_stress_ng.sh` | CPU 满载 | 时长秒（默认 30） | stress-ng 全核 |
| `cpu/cpu_sysbench.sh` | CPU 基准 | 时长秒（默认 30） | sysbench |
| `cpu/cpu_mprime.sh` | 散热验证 | 时长秒（默认 300） | 内部固定 `timeout 300`，时长参数不改变该上限 |
| `memory/mem_stress_ng.sh` | 内存压力 | 时长秒（默认 30） | `--vm-bytes 80%` |
| `memory/mem_memtester.sh` | 位翻转 | 时长秒（默认 60） | 取内存一半 × 2 轮；时长参数未参与实际命令 |
| `memory/mem_sysbench.sh` | 内存带宽 | 时长秒（默认 30） | sysbench |
| `disk/disk_fio.sh` | IOPS / 延迟 | 交互选盘 | v1.49.21 起未挂载盘直接 `[SKIP]`（旧实现静默回落 `/tmp`，等于测系统盘） |
| `disk/disk_hdparm.sh` | 缓存读 | 交互选盘 | hdparm |
| `disk/disk_dd.sh` | 顺序读 | 交互选盘 / `/dev/<dev>` | v1.49.21 起日志名带设备名（`disk_dd_<dev>.log`），多盘不互相覆盖 |
| `network/net_iperf3.sh` | TCP 吞吐 | 交互输入服务端地址 | 命令内固定 `-t 10 -P 4` |
| `network/net_mtr.sh` | 路径质量 | 时长秒（默认 10） | mtr |
| `ib/ib_perftest.sh` | IB 打流 | 自动配对 / 手动配对 | 按 EEPROM serial 相同配对端口 |
| `gpu/gpu_bandwidth.sh` | GPU 带宽 | 无 | bandwidthTest 逐卡 + P2P；v1.49.21 起补 `test_finish`（manifest 有 `summary=`） |
| `gpu/gpu_burn_test.sh` | GPU 长压测 | 时长秒（默认 1800） | gpu-burn `-tc`（张量核心） |
| `gpu/gpu_nvbandwidth.sh` | 带宽基准 | 无 | nvbandwidth |
| `gpu/gpu_partnerdiag.sh` | 出厂诊断 | 交互输入诊断参数 | partnerdiag（FLD 包） |
| `nccl/nccl_test.sh` | 集合通信 | 无 | nccl-tests |
| `test_server_info.sh` | 测试前机器信息（v1.38.0） | `--append <文件>` / `--out <目录>` | 机器 ID / 型号 / CPU / 内存 / GPU / OS 约 10 行只读；各单脚本 `test_init` 后自动调用 |
| `test/report.sh` | 压测报告生成器 | `<压测目录>` · `--channels N` · `--speed MT/s` · `-h` | 输出 `hwscope_test_report.{md,html}`（理论峰值 / 利用率 / 结论） |

```bash
bash test/test_all.sh                     # 分类菜单
bash test/test_all.sh --all               # 全部顺序执行
bash test/test_all.sh --all 60            # 全部执行，各测试项时长 60 s
bash test/cpu/cpu_stress_ng.sh 60         # 单脚本独立执行
bash test/report.sh logs/test/<SN>/       # 由压测日志生成报告
```

日志统一落盘 `logs/test/<SN>/`（由 `test/lib/test_common.sh` 负责），不写入采集目录。
压测报告头部署有「占位模块、不构成验收依据」声明。

## `report/` — 报告体系

> 报告体系自 v1.35.0 独立为 `report/` 模块，`tools/` 下不再保留同名文件（v1.35.3 移除兼容 wrapper）。
> 结构与判据见 [REPORT.md](REPORT.md)、[report/README](../report/README.md)。

| 脚本 | 用途 | 关键参数 / 输出 |
|------|------|----------------|
| `report/report.sh` | 报告生成：json / md / txt / html 四件套 | `--acceptance` 验收清单 · `--baseline <目录>` 基线对比 · `--test-dir <目录>` 关联压测 · `--fld-dir <目录>` FLD 诊断参考 · `--bmc-verify` OS-BMC 核验 · `--json` / `--md` / `--txt` / `--both` 单格式 |
| `report/tools/batch_compare.sh` | 多机横向对比（读各机 JSON，差异 ⚠️ 标注） | `--dirs "dir1 dir2"` · `-o <前缀>`；输出 `logs/batch_compare/` |
| `report/tools/report_server.sh` | 报告在线预览（解包 `logs/report/` 起本地 HTTP） | `--port` · `--open` · `--stop`；**绑定 127.0.0.1** |
| `report/lib/md2html.awk` | 纯 awk Markdown→HTML 转换（零依赖） | v1.53.12 起两遍扫描，生成左侧可跳转目录与回顶按钮；v1.53.13/14 起目录统一 4 字短名 |

## `tools/` — 采集与运维

### 诊断 / 只读

| 脚本 | 用途 | 关键参数 / 输出 |
|------|------|----------------|
| `nvlink_verify.sh` | NVLink 完整性校验 | 解析 `nvidia-smi topo -m` 找降级链路 + `nvlink --status` 查 CRC / down（与报告共用 `lib/nvlink.sh`） |
| `firmware_check.sh` | 固件版本核对（GPU VBIOS / BMC / NIC / NVSwitch） | `--save-baseline` 存基线 · `--diff` 对比；输出 `logs/fw_check/` |
| `sel_monitor.sh` | SEL 事件增量巡检 | `--reset` 重建基线；按事件 ID 单调递增判定新增；输出 `logs/sel_monitor/` |
| `cable_map.sh` | IB 线缆拓扑（BDF ↔ mlx5 ↔ netdev + serial 配对） | DAC 读不出 serial 时可选「断口联动验证」（逐个端口 down / up，约 3–5 s 每口，需确认） |
| `power_monitor.sh` | 能耗持续采样（DCMI 优先，Redfish 兜底） | `start` / `stop` / `status`；`--interval` `--duration` `--output` `--redfish`；CSV + 梯形积分 kWh |
| `sync_version.sh` | 版本号同步 | 以 `hwscope.sh` 的 `HWSCOPE_VERSION` 为唯一来源，同步头部注释与 `README.md` 徽章（三处一致） |
| `cleanup.sh` | 清理 `output/` 与 `logs/` | `--force` 跳过确认；v1.50.5 起 `-h` 可用、未知参数报错退出 |

### 远程 / 批量

| 脚本 | 用途 | 关键参数 / 输出 |
|------|------|----------------|
| `remote_collect.sh` | 远程采集：tar 推送 → 远端执行 → 结果回拉 | `-H user@host` · `--no-sudo` · `-o <目录>` · `--install <1,2,...>` · `--bmc-ip` / `--bmc-user` / `--hgx-bmc-ip` / `--hgx-bmc-user`；其余参数透传 `hwscope.sh` |
| `remote_run.sh` | 多机命令执行 / 推送文件 / 推送执行脚本 / 日志回拉 | `-H`（可多台） · `-c` · `--push <本地> <远端>` · `--script <本地脚本>` · `--pull-logs <远端路径>` · `-o`；v1.43.0 由 `remote_batch.sh` 改名 |
| `redfish_fw_list.sh` | Redfish 固件版本收集（v1.54.22） | `<BMC_IP> <NETRC_FILE>`；逐行输出 `名字=版本` |

`remote_collect.sh` 的实现约束：

- **凭据**：交互式密码，SSH ControlMaster 复用（一次输入）；root 目标机免 sudo，普通用户自动 `-t` 供 sudo 交互；不使用 `sshpass` 明文密码。
- **BMC 参数**（v1.53.45 新增，v1.54.3 修复）：父进程解析出的 `BMC_IP` / `BMC_USER` / `BMC_PASS` / `HGX_BMC_*` 必须在 `hwscope.sh` 中 export —— 模块在独立 bash 子进程执行且会 `source conf/hwscope.conf`，未 export 时被子进程重新置空，表现为「给了 `--bmc-ip` 却只采带内」。
- **BMC 密码通道**：root 目标机在本地提示输入后经 stdin 送远端 `read`（不落盘、不进命令行）；普通用户目标机由远端 `hwscope.sh` 自行提示（`-t` 已分配终端）。主机 BMC 与 HGX 基板 BMC 分别提示，仅按实际给出的 IP 读取对应变量。
- **回拉语义**（v1.51.0）：一律清空重建 `output/remote_output/<机器ID>/`，与本地采集的 `rm -rf` 语义对齐。原因：报告端「按文件名找数据」的前提是「目录内文件同属一次采集」，保留旧文件会把旧批次数据当本次数据渲染，且从报告外观无法察觉；历史留存由 `logs/remote_logs/` 归档承担。
- **完成信息**（v1.53.6）：打印本次采集目录、报告与归档包完整路径；v1.53.19 起按本轮实际写入的机器目录（`_REPLACED`）定位。原实现用 `find … hwscope_report.json | head -1` 取目录，多台并发采集时会印成另一台的 SN 与归档包。
- **Windows 版**：`tools/win/remote_collect.ps1` 参数同名（`-BmcIp` / `-BmcUser` / `-HgxBmcIp` / `-HgxBmcUser`），见 [WIN_TOOLS.md](WIN_TOOLS.md)。

`redfish_fw_list.sh` 分层取数：Dell / AMI 提供 `/UpdateService/FirmwareInventory` 集合（可枚举 BIOS / BMC / CPLD / PSU）；**NVIDIA DGX 该集合返回 404**，版本在 `/Managers/*` 的 `FirmwareVersion`（完整号，较 `ipmitool mc info` 更全）与 `/Systems/*` 的 `BiosVersion`。脚本按 FirmwareInventory → Managers → Systems → Chassis.Power 依次尝试，全部失败则输出空，报告端据此隐藏该行。

### 运维操作（含写操作，执行前二次确认）

| 脚本 | 用途 | 修改对象 |
|------|------|---------|
| `bmc_tool.sh` | BMC 菜单：FRU / 传感器 / SEL / BMC 信息 / 网络查看，SEL 清空、BMC 冷重启、修改密码 | BMC（写项二次确认） |
| `nic_tool.sh` | 网卡菜单：状态 / 光模块 / 固件 / 配置查看，端口复位、MTU、IB↔ETH 模式切换 | 网卡配置 |
| `net_dhcp.sh` | 一键配置网口 DHCP（Ubuntu 24.04 netplan，自动识别插线网口、备份回滚） | `/etc/netplan` |
| `dhcp_server.sh` | dnsmasq 封装：`install` / `config` / `start` / `stop` / `restart` / `status` / `leases` / `leases-export <csv>` / `reconcile <采集目录...>` | dnsmasq 配置 |
| `fw_baseline_import.sh` | 固件基线导入（基准机采集目录 → `conf/fw_required.txt`） | 基线文件 |
| `install_tool.sh` | 采集 / 压测 / IB 诊断依赖安装（1–3 真装，4–6 指引，7–9 实验项默认注释态） | 系统软件包 |
| `install_ai.sh` | AI 推理引擎安装：vLLM / SGLang / TRT-LLM / Ollama / llama.cpp | Docker / 系统 |
| `sync_time.sh` | SSH 时间同步（OS / RTC / BMC），基准为运维机时间 | 目标机时间 |

- `dhcp_server.sh` 选项：`--interface` `--subnet` `--start` `--end` `--gateway` `--lease` `--lease-file` `--dry-run`；`config --dry-run` 仅打印将生成的配置。
- `install_tool.sh` 非交互安装：`-c <1,2,...> -y`（`remote_collect --install` 使用）；任一安装项失败即以非零退出，使远程侧「安装失败则不采集」的短路成立（v1.49.21）。
- `sync_time.sh` 判据：**只有 OS 系统时间决定成败**，RTC / BMC 失败各输出 `[WARN]`（v1.53.0）。旧实现在 `date -s && hwclock -w` 上取合并退出码，而 Ubuntu 24.04 基础包不含 `hwclock`（在 `util-linux-extra` 内），退出码 127 会把已成功的 OS 同步渲染成失败。实现要点：RTC 三级兜底（`hwclock -w` → `python3` 直写 `/dev/rtc0`，写 UTC → `[WARN]`）；NTP 原值在设置后无条件还原；`--bmc` / `--no-bmc`（默认 `auto`：目标机有 `ipmitool` 与 `/dev/ipmi0` 才执行）；`--dry-run` 仅探测；远程脚本经 base64 传参。

### 开发 / Agent 协作

> 完整说明（回归基线机制、仓库对齐、SN 自检规则）见 [tools/agent/README.md](../tools/agent/README.md)；
> 开发环境的工具链限制见 [AGENT_ENV.md](AGENT_ENV.md)。

| 脚本 | 用途 | 关键参数 |
|------|------|---------|
| `tools/agent/agent_sync.sh` | 开工同步：fetch + 远程/本地 HEAD、版本、ahead/behind 对比；维护 `AGENT_STATE.md`（gitignore） | `--mark` 提交后标记 · `--clear` 推送后清空 · `-h` |
| `tools/agent/git_push.sh` | 一键推送：逐提交摘要审查 + 版本单调检查 + 直连重试 + 代理兜底 | `-y` / `--yes` · `--no-fetch` · `--dry-run` · `-q` / `--quiet`；状态行 `PUSH_STATUS=OK\|FAIL\|USER_ABORT\|NOOP\|DRY_RUN` |
| `tools/agent/report_regression.sh` | 报告解析回归（固定样本重跑报告并与基线比对） | `<采集目录>` · `--all` · `--samples SN1,SN2` · `--update` · `--keep` |
| `tools/agent/regen_reports.sh` | 批量重生成报告（agent 专用，样本自动发现） | `<目录...>` · `--samples` · `--regression` · `--update` · `--acceptance` |
| `tools/agent/repo_realign.sh` | 仓库对齐（历史重写后修复分叉） | `--sync` · `--protect [--auto]` · `--no-fetch` |
| `tools/agent/sn_check.sh` | 提交前 SN / MAC 自检（隐私红线兜底） | `--staged` · `--commit-msg <文件>` · `--install-hook` · `--all-history` · `--include-remotes` |
| `tools/agent/bmc_pass_smoke.sh` | BMC 密码通道冒烟测试（tty / 管道 / sudo 三种条件组合） | 无参数；需真 bash（Linux / WSL），git-bash 结论不可用 |
| `tools/agent/lib_proxy.sh` | 代理探测公共库（被 agent_sync / repo_realign / git_push 复用） | `source` 后调用 `detect_env` / `detect_proxy` / `git_net_run` |

推送前三条检查（`git_push.sh`，v1.51.5）：

1. **版本单调性**：本地 `HWSCOPE_VERSION` 小于远程 → 拒绝推送，防凭记忆回退版本号。
2. **版本三处一致**：`hwscope.sh` 变量 / 头部注释 / `README.md` 徽章不一致 → 拒绝推送，并提示运行 `tools/sync_version.sh`。
3. **SN 兜底**：推送前运行 `sn_check.sh` 扫暂存内容与提交信息（`SKIP_SN_CHECK=1` 可跳过）。

`agent_sync.sh` 与 `git_push.sh` 的 fetch / 预检经 `lib_proxy.sh` 的 `git_net_run`：直连失败自动探测本机代理端口（端口每次启动会变，故动态获取）并重试。fetch 失败时打印退出码并把远程值标注为「本地缓存，不代表真实状态」，不使用缓存值冒充「已同步」（v1.52.8）。
