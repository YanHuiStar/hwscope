# HwScope 运维工具库（tools/）

> 服务器运维脚本集。**部分脚本会修改系统配置**，使用前请确认「危险度」标注与各脚本的二次确认项。
> 工具定位：运维机 / 服务器侧操作，不参与采集流程；采集由 `hwscope.sh` 与 `modules/` 完成。
>
> 索引与分类速查见 [docs/TOOLS.md](../docs/TOOLS.md)；Windows 侧工具见 [docs/WIN_TOOLS.md](../docs/WIN_TOOLS.md)；
> Agent 协作工具见 [tools/agent/README.md](agent/README.md)。

## 通用约定

| 约定 | 说明 |
|------|------|
| 帮助 | 各脚本支持 `-h` / `--help`（打印脚本头部注释块）。例外：`redfish_fw_list.sh` 由 `modules/12_bmc.sh` 内部调用，只接受两个位置参数 |
| 带值参数 | 缺参即报错退出（v1.49.21）。旧写法 `shift 2` 在只剩一个参数时是静默 no-op，`while` 永不前进，会卡死且零输出 |
| 危险度 | 🟢 只读 / 🟡 仅远程只读采集 / 🔴 修改系统配置。写入类均有二次确认提示 |
| 凭据 | 远程连接一律交互式输入密码；不使用 `sshpass` 等明文密码方式，密码不落盘、不进进程列表 |
| 报告体系 | 报告生成 / 验收清单 / 在线预览 / 多机对比自 v1.35.0 迁至 `report/` 模块，`tools/` 下不再保留同名文件（v1.35.3 移除兼容 wrapper），详见 [report/README](../report/README.md) |
| 时间戳 | 输出目录与归档包时间戳统一 `date '+%Y%m%d%H%M%S'`（14 位连写） |

## 分类速查

| 类别 | 脚本 | 危险度 |
|------|------|--------|
| 诊断 / 只读 | `nvlink_verify` · `firmware_check` · `sel_monitor` · `cable_map` · `sync_version` · `power_monitor` · `cleanup` · `redfish_fw_list` | 🟢 只读（`cleanup` 删除输出目录，需 yes 确认；`cable_map` 断口联动验证需确认） |
| 写入操作 | `bmc_tool` · `nic_tool` · `net_dhcp` · `dhcp_server` · `install_tool` · `install_ai` · `fw_baseline_import` · `sync_time` | 🔴 修改系统或设备配置 |
| 远程 | `remote_collect` · `remote_run` | 🟡 远程执行（采集 / 命令，本身只读） |
| Agent 协作 | `agent/agent_sync` · `agent/git_push` · `agent/report_regression` · `agent/regen_reports` · `agent/repo_realign` · `agent/sn_check` · `agent/bmc_pass_smoke` · `agent/lib_proxy` | 🟢 只读或仅操作 git / 报告（`git_push` 推送，`repo_realign --sync/--protect` 改动本地仓库） |
| 报告体系 | → `report/` 模块（`report.sh` · `batch_compare.sh` · `report_server.sh` · `md2html.awk`） | 🟢 只读 |

---

## 🟢 诊断 / 只读类

### `nvlink_verify.sh` — NVLink 完整性校验

```bash
bash tools/nvlink_verify.sh
```

| 检查项 | 判据 |
|--------|------|
| 拓扑 | 解析 `nvidia-smi topo -m`，标出非 NVLink 的降级链路 |
| 链路 | `nvidia-smi nvlink --status` 查 CRC 错误与链路 down |
| 结论 | 输出健康判断（解析逻辑在 `lib/nvlink.sh`，与 `report/report.sh` 共用） |

依赖：`nvidia-smi`。无参数。

### `firmware_check.sh` — 固件版本核对

```bash
sudo bash tools/firmware_check.sh                  # 采集当前版本
sudo bash tools/firmware_check.sh --save-baseline  # 存为验收基线
sudo bash tools/firmware_check.sh --diff           # 与基线对比
```

| 参数 | 说明 |
|------|------|
| `--save-baseline` | 将本次清单存为基线；已有基线时提示覆盖，并备份为 `fw_baseline.txt.bak-<时间戳>` |
| `--diff` | 与基线逐行对比，标出变化；无基线时提示先存基线 |

汇总项：GPU VBIOS / BMC FW / NIC FW（CX5–CX8）/ NVSwitch FW。
输出：`logs/fw_check/fw_now_<时间戳>.txt`，基线 `logs/fw_check/fw_baseline.txt`。依赖 root。

### `sel_monitor.sh` — SEL 事件增量巡检

```bash
sudo bash tools/sel_monitor.sh          # 只报新增事件
sudo bash tools/sel_monitor.sh --reset  # 重建基线（忽略历史）
```

按事件 ID 单调递增判定新增（较整行匹配可靠），严重事件与 PCIe 事件分类高亮。
v1.49.21 起严重事件计数排除 `Deasserted` 自愈行：旧匹配模式含 `assert`，是 `Deasserted` 的子串。
输出：`logs/sel_monitor/`（基线 `sel_baseline.txt`、`sel_last.txt`、本次报告 `sel_report_<时间戳>.txt`）。
依赖：`ipmitool`。

### `cable_map.sh` — 线缆拓扑

```bash
sudo bash tools/cable_map.sh
```

| 步骤 | 内容 |
|------|------|
| 1 | BDF ↔ mlx5 ↔ netdev 映射（以 sysfs 为权威） |
| 2 | 线缆配对：两端 EEPROM serial 相同即物理相连 |
| 3 | 输出物理连线表，无需拔线 |

无源铜缆（DAC）常读不出 serial，此时可选「断口联动验证」：逐个端口 down 再恢复，
依据对端是否联动判断连接关系；每口约 3–5 s，会中断生产 IB 网流量，必须显式确认，
中断时按原状态恢复（不会强行拉起运维主动禁用的端口）。依赖：`mlxlink`（MFT）。

### `power_monitor.sh` — 能耗持续采样

```bash
bash tools/power_monitor.sh start --interval 60 --duration 0
bash tools/power_monitor.sh status
bash tools/power_monitor.sh stop
```

| 参数 | 说明 |
|------|------|
| `start` / `stop` / `status` | 启动后台采样 / 停止并输出聚合 / 查看运行状态 |
| `--interval N` | 采样间隔秒数（默认 60，需正整数） |
| `--duration N` | 采样时长秒数（默认 0 = 持续，由 `stop` 结束） |
| `--output <dir>` | 输出目录（默认 `logs/power_monitor/`） |
| `--redfish` | 同时采集 Redfish `PowerConsumedWatts`（需 `conf` 中配置 BMC） |

取数路径：DCMI 优先，Redfish 兜底。产物：`power_samples.csv`（时间序列）、`power_aggregate.txt`
（小时 / 日聚合 + 梯形积分累计 kWh）、`power_monitor.pid`、`power_monitor.log`。

### `sync_version.sh` — 版本号同步

```bash
bash tools/sync_version.sh
```

以 `hwscope.sh` 的 `HWSCOPE_VERSION` 为唯一权威来源，同步至 `hwscope.sh` 头部注释与
`README.md` 的 Version 徽章（三处一致）；写入前自动备份。无参数。

### `cleanup.sh` — 清理采集输出

```bash
bash tools/cleanup.sh           # 显示体积后输入 yes 确认
bash tools/cleanup.sh --force   # 跳过确认
```

| 参数 | 说明 |
|------|------|
| `--force` | 跳过 yes 确认 |
| `-h` / `--help` | 显示帮助 |

删除 `output/` 与 `logs/`（先显示各自体积与文件数），不触碰源码。v1.50.5 起未知参数明确报错退出；
此前仅识别 `--force`，其余参数被静默忽略后仍进入清理流程。Windows 版：`tools/win/cleanup.ps1` / `.bat`。

---

## 🟡 远程类

### `remote_collect.sh` — SSH 远程采集

```bash
bash tools/remote_collect.sh -H root@<host>
bash tools/remote_collect.sh -H root@<host> --modules gpu,cpu -o ./out
bash tools/remote_collect.sh -H root@<host> --install 1,2
bash tools/remote_collect.sh -H root@<host> --bmc-ip <BMC-IP> --bmc-user <user>
```

| 参数 | 说明 |
|------|------|
| `-H user@host` | 目标机（必填） |
| `--no-sudo` | 目标机以当前用户直接执行（默认 `sudo bash hwscope.sh`；`root@` 自动免 sudo） |
| `-o <目录>` | 本地回拉目录（默认 `<项目>/output`） |
| `--install <1,2,...>` | 推送后先远端非交互安装依赖（`install_tool.sh -c <列表> -y`）再采集；安装失败则中止，不再采集 |
| `--bmc-ip <IP>` | 目标机 BMC 地址（透传 `hwscope.sh`；不给则不采带外） |
| `--bmc-user <user>` | BMC 用户名（默认 `admin`） |
| `--hgx-bmc-ip <IP>` | HGX 基板 BMC 地址 |
| `--hgx-bmc-user <user>` | HGX 基板 BMC 用户名 |
| `--interactive` | 保留兼容（默认已为交互式密码，无需该参数） |
| `-h` / `--help` | 帮助 |

其余参数原样透传远端 `hwscope.sh`（`--modules` / `--serial` / `--quiet` / `--skip` / `--no-module` 等）。

实现约束：

- **流程**：tar 推送项目（排除 `output` / `logs` / `.git`）→ 远端执行 → 结果回拉 → 清理远端。执行后远端零残留。
- **凭据**：交互式密码，SSH ControlMaster 复用（只输一次）；普通用户自动分配 `-t` 供 sudo 交互。
  不使用 `sshpass` 明文密码；SSH key 免密仅建议受信内网使用。
- **BMC 参数**（v1.53.45 新增，v1.54.3 修复）：`BMC_IP` / `BMC_USER` / `BMC_PASS` / `HGX_BMC_*` 由
  `hwscope.sh` 统一 export。模块在独立 bash 子进程执行且会 `source conf/hwscope.conf`，未 export 时
  被子进程重新置空，表现为「给了 `--bmc-ip` 却只采带内、日志无 `-H/-I lanplus`」。
- **BMC 密码通道**：root 目标机在本地提示输入，经 stdin 送远端 `read` 并 export（不落盘、不进命令行）；
  普通用户目标机由远端 `hwscope.sh` 自行提示（`-t` 已分配终端）。主机 BMC 与 HGX 基板 BMC 分别提示，
  只对实际给出的 IP 读取对应变量（v1.54.0：旧实现无条件 `read BMC_PASS`，仅给 `--hgx-bmc-ip` 时
  密码进入用不上的变量，HGX 带外静默失败）。
- **回拉**（v1.51.0）：解包到 `output/remote_output/`，逐机器**清空重建** `output/remote_output/<机器ID>/`，
  与本地采集的 `rm -rf` 语义一致。旧实现保留目录并检测残留，实测归档常被人工移走而落入「不删」分支，
  旧文件（本次未采的模块、已拔掉的外设日志）被报告端按文件名当本次数据读取，且从报告外观看不出来。
  历史留存由 `logs/remote_logs/` 的归档承担。
- **完成信息**（v1.53.6）：打印本次采集目录、报告与归档包的完整路径。v1.53.19 起按本轮实际写入的机器
  目录（`_REPLACED`）定位：原实现用 `find … hwscope_report.json | head -1`，多台并发采集时会印成另一台。
- **输出**：`output/remote_output/<机器ID>/`（对标本地 `output/<SN>/`）；归档包 `logs/remote_logs/<机器ID>-<时间戳>.tar.gz`。
- **Windows 版**：`tools/win/remote_collect.ps1` / `.bat`，参数等价（`-BmcIp` / `-BmcUser` / `-HgxBmcIp` / `-HgxBmcUser`）。

### `remote_run.sh` — 多机远程执行

```bash
bash tools/remote_run.sh -H "root@<h1> root@<h2>" -c 'nvidia-smi -L'
bash tools/remote_run.sh -H root@<h1> --push ./local.txt /tmp/local.txt
bash tools/remote_run.sh -H root@<h1> --script ./diag.sh --pull-logs /tmp/diag
```

| 参数 | 说明 |
|------|------|
| `-H host` | 目标机（可多次，或空格分隔列表） |
| `-c 'cmd'` | 远程执行命令（原样传给远端 shell） |
| `--push <本地> <远端>` | scp 推送文件到各机 |
| `--script <本地脚本>` | 推送并远程执行本地脚本（v1.43.0） |
| `--pull-logs <远端路径>` | 执行后把远端日志目录 / 文件拉回 `<outdir>/<host>_logs/`（tar over ssh）；逐机先清空再解包并校验归档可读性 |
| `-o <dir>` | 输出目录（默认 `./run_output`，已加入 `.gitignore`） |
| `--interactive` | 保留兼容（默认已为交互式密码） |
| `-h` / `--help` | 帮助 |

v1.43.0 由 `remote_batch.sh` 改名；凭据同 `remote_collect.sh`（交互式密码，不使用 `sshpass`）。

### `redfish_fw_list.sh` — Redfish 固件版本收集（v1.54.22）

```bash
bash tools/redfish_fw_list.sh <BMC_IP> <NETRC_FILE>
```

| 位置参数 | 说明 |
|----------|------|
| `<BMC_IP>` | 目标 BMC 地址 |
| `<NETRC_FILE>` | 密码经 netrc 文件传入（调用方以 `mktemp` 创建、权限 600）；命令行与 `ps` 中不出现密码 |

输出：每行 `名字=版本`（如 `BMC Firmware=0.18.3`、`System BIOS=1.13`），供报告 BMC 段「Redfish 固件明细」；
全部取不到则输出空，报告端据此隐藏该行。由 `modules/12_bmc.sh` 调用，同一次采集内完成，不额外开 BMC 连接。
**无 `-h`**：参数不足时打印用法并 `exit 1`。

分层取数原因：各厂 Redfish 暴露固件的路径不同 —— Dell / AMI 有 `/UpdateService/FirmwareInventory`
集合（可枚举 BIOS / BMC / CPLD / PSU）；**NVIDIA DGX 实测该集合 404**，版本在 `/Managers/*` 的
`FirmwareVersion`（完整号，较 `ipmitool mc info` 更全）与 `/Systems/*` 的 `BiosVersion`。脚本按
FirmwareInventory → Managers → Systems → Chassis.Power 依次尝试，能取到哪个就取哪个。

---

## 🔴 写入操作类（均有二次确认）

### `bmc_tool.sh` — BMC 运维菜单

```bash
sudo bash tools/bmc_tool.sh
```

| 序号 | 操作 | 类型 |
|------|------|------|
| 1 | 查看 FRU | 只读 |
| 2 | 查看传感器 | 只读 |
| 3 | 查看 SEL | 只读 |
| 4 | 清空 SEL | 写入 |
| 5 | 查看 BMC 信息 | 只读 |
| 6 | 重启 BMC（`mc reset cold`） | 写入 |
| 7 | 修改密码（User ID 2） | 写入 |
| 8 | 查看网络（`lan print`） | 只读 |

可逗号多选（如 `1,2,3`）。带内模式走本机 IPMI；设置 `BMC_IP` 后改走 `-I lanplus` 远程 BMC。
密码经环境变量 `IPMI_PASSWORD` 传给 `ipmitool`，不出现在命令行 / 日志。

密码来源：`conf/hwscope.conf` 的 `BMC_PASS` → 环境变量 `BMC_PASS` → 交互终端提示输入（不回显）。
**自 v1.54.38 起不再静默回退 `admin`**：本工具含写操作（清 SEL / 重启 BMC / 改密码），用默认口令
在已改密现场会触发账户锁定，未改密现场等于无确认使用默认凭据。非交互场景（无 tty）会打印告警并继续，
由操作者决定是否先 `export BMC_PASS=...`。 / `ps`。
输出：`output/bmc_tool_<时间戳>/`。

### `nic_tool.sh` — 网卡运维菜单

```bash
sudo bash tools/nic_tool.sh
```

| 序号 | 操作 | 类型 |
|------|------|------|
| 1 | 查看设备状态（`mlxlink`） | 只读 |
| 2 | 查看光模块信息（`mlxlink -m`） | 只读 |
| 3 | 查询固件版本（`mlxfwmanager --query`） | 只读 |
| 4 | 查看配置（`mlxconfig -d <dev> query`） | 只读 |
| 5 | 端口复位（`mlxlink -r`） | 写入 |
| 6 | 设置 MTU 9000 | 写入 |
| 7 | 切换端口模式（IB↔ETH） | 写入 |

v1.49.21 修正 `mlxconfig` 命令形式：原写作 `query -d <dev>`，选项 4 与模式切换实际未生效。
依赖：MFT（`mlxlink` / `mlxfwmanager`）。

### `net_dhcp.sh` — 网口 DHCP 配置

```bash
sudo bash tools/net_dhcp.sh            # 交互识别网口
sudo bash tools/net_dhcp.sh <接口名>    # 直接指定
```

自动识别物理网口（排除 `lo` / `docker` / `veth` / `br-` 等虚拟接口），优先选「已插线 + 板载」网口，
无法判定时列出候选供选择。写入独立文件 `99-hwscope-dhcp.yaml` 并 `netplan apply`；操作前备份全部
netplan 配置，`generate` 失败自动回滚。

### `dhcp_server.sh` — DHCP 服务器（dnsmasq 封装）

```bash
sudo bash tools/dhcp_server.sh install
sudo bash tools/dhcp_server.sh config --subnet 192.168.50 --start 100 --end 200
sudo bash tools/dhcp_server.sh start
sudo bash tools/dhcp_server.sh leases
sudo bash tools/dhcp_server.sh leases-export logs/leases.csv
sudo bash tools/dhcp_server.sh reconcile output/<SN1> output/<SN2>
```

| 动作 | 说明 |
|------|------|
| `install` | 安装 dnsmasq（apt / dnf / yum 自动识别） |
| `config` | 生成 `/etc/dnsmasq.d/hwscope-dhcp.conf`（原子写 + `.bak` 备份） |
| `start` / `stop` / `restart` | 服务控制（systemctl / service 自动识别） |
| `status` | 服务状态 + 当前配置 + 租约数 |
| `leases` | 租约表（到期时间 / MAC / IP / 主机名） |
| `leases-export [csv]` | 导出 CSV（默认 `logs/leases.csv`），供 `reconcile` 与采集台账联动 |
| `reconcile <采集目录...>` | 租约 ↔ 报告 BMC IP / MAC 交叉核对，输出匹配 / 未匹配 / 孤儿租约 |

| 选项 | 说明 |
|------|------|
| `--interface <网卡>` | 监听网卡（默认 `eth0`） |
| `--subnet <前三段>` | 网段（默认 `192.168.50`） |
| `--start` / `--end <末段>` | 地址池范围（默认 100–200） |
| `--gateway <末段>` | 网关末段（默认 1；0 = 不下发网关） |
| `--lease <时长>` | 租约时长（默认 `12h`） |
| `--lease-file <路径>` | 自定义租约文件（默认识别 Debian / RHEL 两处标准路径） |
| `--dry-run` | 仅打印将生成的配置，不落盘 |
| `-h` / `--help` | 帮助 |

### `fw_baseline_import.sh` — 固件基线导入

```bash
bash tools/fw_baseline_import.sh <基准机采集目录>            # 预览差异（默认）
bash tools/fw_baseline_import.sh <基准机采集目录> --apply    # 写入基线
bash tools/fw_baseline_import.sh --file baseline.tsv --diff
```

| 参数 | 说明 |
|------|------|
| `<基准机采集目录>` | 读取其 `firmware/fw_compliance.csv` |
| `--file <tsv>` | 改用表格文件（`组件\|型号模式\|版本\|备注`，`#` 为注释） |
| `--diff` | 仅显示将生成 / 变化的条目（默认） |
| `--apply` | 写入 `conf/fw_required.txt`，自动备份 `.bak` |
| `-h` / `--help` | 帮助 |

用途：批量交付时先采一台「标准机」（厂商验收通过），把其固件版本固化为基线，其余机器由
`modules/15_firmware.sh` 对照该基线判定合规 / 落后。

### `install_tool.sh` — 采集 / 压测依赖安装

```bash
sudo bash tools/install_tool.sh             # 交互菜单
sudo bash tools/install_tool.sh -c 1,2 -y   # 非交互（远程自动安装用）
```

| 参数 | 说明 |
|------|------|
| `-c <1,2,...>` | 直接指定安装项（逗号分隔，跳过菜单） |
| `-y` | 跳过每项确认（配合 `-c` 用于 `remote_collect --install`） |
| `-h` / `--help` | 帮助 |

| 序号 | 安装项 | 方式 |
|------|--------|------|
| 1 | 基础采集工具（dmidecode / pciutils / ipmitool / smartmontools / lm-sensors） | 包管理器 |
| 2 | 压测工具（stress-ng / sysbench / fio / iperf3 / mtr） | 包管理器 |
| 3 | IB 诊断（infiniband-diags / perftest / rdma-core） | 包管理器 |
| 4 | NVIDIA DCGM | 指引 |
| 5 | Mellanox MFT | 指引 |
| 6 | 推理引擎（Triton / TensorRT-LLM） | 指引 |
| 7 | DCGM 自动安装（实验） | 代码默认注释态 |
| 8 | MFT 自动安装（实验） | 代码默认注释态 |
| 9 | 厂商 RAID 工具（实验，storcli / sas3ircu） | 代码默认注释态 |

任一安装项失败即以非零退出（v1.49.21），使 `remote_collect --install` 的「安装失败则不采集」成立。
需 root。RHEL 系安装项 1–3 依赖 EPEL。

### `install_ai.sh` — AI 推理引擎安装

```bash
bash tools/install_ai.sh
```

交互菜单选择引擎：vLLM / SGLang / TensorRT-LLM / Ollama / llama.cpp。基于 `uv` 为每个引擎建立独立
虚拟环境（环境根目录默认 `/opt/Projects`，可交互修改），避免依赖冲突；TensorRT-LLM 走容器化指引。

### `sync_time.sh` — SSH 时间同步（OS / RTC / BMC）

```bash
bash tools/sync_time.sh root@<host>
bash tools/sync_time.sh --dry-run root@<host>
bash tools/sync_time.sh --no-bmc root@<host1> root@<host2>
```

| 参数 | 说明 |
|------|------|
| `-h` / `--help` | 显示帮助（v1.50.5 起先于主机名解析；此前 `-h` 会被当作目标机执行 `ssh -h`） |
| `--dry-run` | 只显示目标机三处当前值与偏差、探测工具可用性，不做修改 |
| `--bmc` | 强制同步 BMC 时间 |
| `--no-bmc` | 跳过 BMC（默认 `auto`：目标机有 `ipmitool` 与 `/dev/ipmi0` 才执行） |
| `<user@host> [...]` | 一至多台目标机 |

功能：以运维机时间为基准，同步目标机 **① OS 系统时间 ② RTC 硬件时钟 ③ BMC 时间（可选）**。
BMC 时间是 SEL 时间轴的依据（XID / ECC / PCIe / 电源事件均按其对齐）。

- **成败判据**（v1.53.0）：**只有 OS 系统时间决定成败**，RTC / BMC 失败各输出 `[WARN]`。旧实现在
  `date -s && hwclock -w` 上取合并退出码，而 Ubuntu 24.04 基础包不含 `hwclock`（在 `util-linux-extra`
  内），退出码 127 会把已成功的 OS 同步渲染为 `[ERROR] 同步失败`，运维据此反复重试且无效。
- **RTC 三级兜底**：`hwclock -w` → `python3` 直写 `/dev/rtc0`（`RTC_SET_TIME = 0x4024700a`，必须写 UTC，
  目标机通常为 `RTC in local TZ: no`）→ 均不可用则 `[WARN]`「重启后会丢」。
- **NTP 还原**：先记原值（`timedatectl show -p NTP --value`），设置后无条件还原。旧实现只停不还原，
  会把机器留在 NTP off。
- **BMC**：使用**目标机本地** `ipmitool`（带内，无需 BMC 凭据与网络）；`sel time set` 需 12 小时制
  AM/PM（ipmitool 1.8.19 不识别 24 小时制），失败回退 `raw 0x0a 0x49`（4 字节小端 epoch）。
- **实现要点**：epoch 秒传递（无时区歧义）；远程脚本经 base64 传参（`echo <b64> | base64 -d | bash`），
  参数中只有 base64 字符，不会被引号 / 括号破坏；交互式密码 + ControlMaster 复用。
- **依赖**：运维机 `ssh` / `date` / `base64`；目标机 `date` / `base64` +（可选）`timedatectl` /
  `hwclock` / `python3` / `ipmitool`。
- **Windows 对应**：`tools/win/sync_time.ps1` / `.bat`（同样支持 `-Help` / `--help` / `-h` 与无参数显示用法）。

---

## 开发 / Agent 协作

完整说明（回归基线机制、仓库对齐、SN 自检规则）见 [tools/agent/README.md](agent/README.md)。

| 脚本 | 用途 |
|------|------|
| `agent/agent_sync.sh` | 开工同步：fetch + 远程/本地 HEAD、版本、ahead/behind 对比 |
| `agent/git_push.sh` | 一键推送：逐提交摘要 + 版本单调检查 + 版本三处一致 + SN 兜底 + 代理兜底 |
| `agent/report_regression.sh` | 报告解析回归测试（改解析 / 渲染后必跑） |
| `agent/regen_reports.sh` | 批量重生成报告（agent 专用） |
| `agent/repo_realign.sh` | 仓库对齐（历史重写后修复分叉） |
| `agent/sn_check.sh` | 提交前 SN / MAC 自检 |
| `agent/bmc_pass_smoke.sh` | BMC 密码通道冒烟测试 |
| `agent/lib_proxy.sh` | 代理探测公共库 |

推送失败时按 AGENTS.md「推送失败处理纪律」执行：停止自动重试，上报用户并等待指令。

---

## 参数解析约定（v1.49.21）

- **带值参数缺参必须明确报错退出**。`shift 2` 在只剩一个参数时是静默 no-op，会使 `while` 永不前进，
  实测在 `install_tool.sh -c`、`regen_reports.sh --samples`、`report_regression.sh --samples`、
  `test/report.sh --channels/--speed`、`test_server_info.sh --append/--out` 处导致卡死且零输出。
  现统一为 `[ $# -ge 2 ] || { echo "[ERROR] … 需要参数" >&2; exit 1; }`。
- **`-h` / `--help` 作为首个参数也应可用**。`power_monitor.sh` / `dhcp_server.sh` 原先把 `-h` 当动作名
  （输出「未知动作: -h」后 `exit 1`），仅「动作 + `-h`」能出帮助；已修。

## 其他

- `md2html.awk` — Markdown→HTML 转换器（已迁至 `report/lib/md2html.awk`）：
  `awk -f report/lib/md2html.awk 报告.md > 报告.html`
- `fixcrlf.sh`（项目根）— Windows → Linux CRLF 换行修复：`bash fixcrlf.sh`
- Windows 配套工具见 `tools/win/`（PowerShell 运维工具，笔记本 / 运维机侧使用），说明见
  [docs/WIN_TOOLS.md](../docs/WIN_TOOLS.md)
