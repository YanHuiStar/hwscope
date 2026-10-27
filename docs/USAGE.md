# 使用指南（Usage）

> [← 返回 README](../README.md) · 快速上手见 [QUICKSTART.md](QUICKSTART.md) · 报告与验收体系见 [REPORT.md](REPORT.md)

## 采集

### 命令行参数

| 参数 | 说明 |
|------|------|
| `--modules gpu,cpu` | 只采指定模块（逗号分隔，模块名见「模块总览」）|
| `--skip dcgm,nvsm` | 跳过指定模块 |
| `--serial` | 串行执行，按模块序号逐模块实时输出（低负载场景）|
| `--parallel` | 并行执行所有模块（默认行为，显式指定用于覆盖已有配置）|
| `--no-parallel` | 禁用模块内命令并行，降级为逐条执行（低负载场景）|
| `--module-timeout N` | 单模块超时秒数，默认 `600` |
| `--no-module` | 跳过光模块查询（仅影响 `07_network` 的光模块部分，约缩短 48 秒）|
| `--output <目录>` | 指定输出目录 |
| `--stamp` | 输出目录追加时间戳后缀，保留多版本 |
| `--force` | 兼容保留参数：v1.45.6 起默认即覆盖 |
| `--test-dir <目录>` | 关联压测目录（`logs/test/<SN>/`），报告生成「压测归档」章节 |
| `--sim [N]` | 模拟模式：每模块等待 N 秒（默认 5），用于流程演练 |
| `--bmc-ip <BMC-IP>` / `--bmc-user <用户名>` | BMC 地址与用户名（用户名默认 `admin`）|
| `--hgx-bmc-ip <BMC-IP>` / `--hgx-bmc-user <用户名>` | HGX 基板 BMC 地址与用户名 |
| `--bmc-auto` / `--no-bmc-auto` | 带内自动探测 BMC 地址的开关（默认开启）|
| `-q` / `--quiet` | 静默模式，仅输出异常 |
| `-h` / `--help`、`-v` / `--version` | 显示帮助、显示版本 |

### 常用示例

```bash
sudo bash hwscope.sh                          # 全量采集（默认并行）
sudo bash hwscope.sh --serial                 # 串行执行（低负载）
sudo bash hwscope.sh --quiet                  # 静默模式（不打印模块明细）
sudo bash hwscope.sh --no-parallel            # 禁模块内并行（低负载）
sudo bash hwscope.sh --module-timeout 120     # 单模块超时 120 秒
sudo bash hwscope.sh --modules gpu,cpu        # 只采部分模块
sudo bash hwscope.sh --skip gpu,fan           # 跳过指定模块
sudo bash hwscope.sh --output /data/collect   # 指定输出目录
bash modules/04_gpu.sh /path/output           # 单模块（调试）
```

输出结构：`output/<机器ID>/` 下按模块分目录（`bmc/`、`cpu/`、`gpu/` 等），每命令一个日志，各模块目录内的 `manifest.txt` 声明本模块产出文件，报告按 manifest 读取。

### 输出目录与重复采集

| 场景 | 行为 |
|------|------|
| 默认 | 输出到 `output/<机器ID>/`；重复采集**覆盖**同名目录——采集结果是当前状态快照，机器可能已换配件（v1.45.6）|
| 历史归档 | 每次采集结束自动归档到 `logs/<机器ID>-<时间戳>.tar.gz`，覆盖不丢历史数据 |
| 覆盖前校验 | 覆盖前校验归档完整性：存在未归档数据先补归档，补档失败则拒绝覆盖（v1.45.7）|
| `--stamp` | 输出到 `output/<机器ID>-<时间戳>/`，保留多版本（换配件前后对比）；默认 SN 目录与 `--output` 指定路径均已存在时同样生效（v1.45.7）|
| `--force` | 兼容保留参数，v1.45.6 起默认即覆盖 |

### 采集输出顺序与汇总表

17 个模块默认**同时并行启动**。模块日志谁先跑完谁先输出，屏幕上的段落顺序不按模块序号——NVSM 等秒级模块排在前面，BMC/PSU 等慢模块在后。这是刻意保留的实时反馈：慢机上可先看到快模块完成，不必等待全部结束。

正因输出顺序随各模块耗时变化、同一台机器两次采集也可能不同，v1.51.4 起在采集结束时追加一张**按模块序号（01→16→99）排列**的汇总表，顺序固定，可直接 diff：

```
════════════ 采集汇总（按模块序号，与上方输出顺序无关）════════════
  模块             状态          耗时 文件数
  01/motherboard   OK              1s     12
  02/cpu           OK              1s     12
  ...
  12/bmc           OK             60s     20
════════════════════════════════════════════════════════════════
```

顺序完全可控的写法是 `--serial`（串行、逐模块实时输出），代价是总耗时等于各模块耗时之和。TTY 下的进度动画依赖 stdout 为终端，写日志或接入管道时自动关闭；v1.51.4 修正了原先 `exec > >(tee ...)` 把 stdout 变成管道、导致该判断恒假而动画从未显示的问题。

### 模块总览（17 个，与 `modules/*.sh` 逐项对应）

| 编号 | 模块 | 采集内容 | 主要工具 | conf 开关 |
|------|------|----------|----------|-----------|
| 01 | motherboard | 主板 / BIOS / 机箱 | dmidecode | `MODULE_MB` |
| 02 | cpu | CPU 信息 | dmidecode + lscpu | `MODULE_CPU` |
| 03 | memory | 内存插槽 / 容量 / 速率 | dmidecode | `MODULE_MEMORY` |
| 04 | gpu | GPU 信息 | nvidia-smi / amd-smi·rocm-smi / npu-smi / xpu-smi / 国产 SMI（适配器框架，见下文）| `MODULE_GPU` |
| 05 | nvswitch | NVSwitch 信息 | nvswitch-audit + fabric-manager | `MODULE_NVSWITCH` |
| 06 | pcie | PCIe 拓扑 / 速率 | lspci | `MODULE_PCIE` |
| 07 | network | 网络 / IB / 光模块 | ibstat + mlxlink + ethtool + devlink（PSID / 固件）| `MODULE_NETWORK` |
| 08 | storage | 存储设备（SATA/SAS/NVMe/SMART）| lsblk + smartctl | `MODULE_STORAGE` |
| 09 | raid | RAID / HBA 卡信息 | storcli64 / sas3ircu | `MODULE_RAID` |
| 10 | psu | 电源（PSU）信息 | IPMI + sysfs | `MODULE_PSU` |
| 11 | fan | 风扇（FAN）信息 | IPMI + hwmon + sensors | `MODULE_FAN` |
| 12 | bmc | BMC / IPMI 信息 | ipmitool + Redfish | `MODULE_BMC` |
| 13 | nvsm | NVSM 综合（条件执行）| nvsm | `MODULE_NVSM` |
| 14 | dcgm | DCGM 诊断（条件执行）| dcgmi | `MODULE_DCGM` |
| 15 | firmware | 固件清单与合规（BIOS / BMC / GPU VBIOS / 微码 / 网卡 / 存储 / NVSwitch，厂商无关）| 对照 `conf/fw_required.txt` | `MODULE_FIRMWARE` |
| 16 | power | 能耗台账（累计能耗）| BMC 累计能耗 + DCMI/Redfish 快照 | `MODULE_POWER` |
| 99 | os | OS 基础信息 | — | `MODULE_OS` |

> 单模块调试：`bash modules/<NN>_<模块>.sh <输出目录>`；开关默认全开，在 `conf/hwscope.conf` 置 0 即关闭对应模块。

**GPU 多厂商适配器（v1.47.0）**：04 模块按 `GPU_PLATFORM` 分发到 `modules/gpu/adapter_<vendor>.sh`——NVIDIA（nvidia-smi，已真机验证）、AMD（amd-smi·rocm-smi）、昇腾（npu-smi）、Intel（xpu-smi）、寒武纪·壁仞·摩尔线程·沐曦·天数智芯（cnmon·bmt-smi·mthreads-gmi·mx-smi·ix-smi）。各适配器输出统一的 `gpu_inventory.csv`（列与 nvidia-smi 的 18 列一致），报告、显存魔改检测与 GPU PCIe 验收项跨厂商无需改动。厂商工具未安装时降级到 lspci 层兜底：PCIe 链路仍可判定，卡不丢失。工具依赖见 [DEPENDENCIES.md](DEPENDENCIES.md) §3.6。

> **国产五家适配器已接入（v1.52.0）**：`detect_gpu_vendors`（`lib/platform.sh`）已补充寒武纪 / 壁仞 / 摩尔线程 / 沐曦 / 天数智芯的 lspci 厂商串映射，单厂商与 mixed 混插均分发到对应适配器（`04_gpu.sh`）。**厂商串待真机核对**——各厂 lspci vendor name 以真机输出为准校准；未匹配时回落 generic lspci 兜底，行为不劣于改动前。

### 采集侧行为约定

| 场景 | 行为 |
|------|------|
| 非 NVIDIA 加速卡主机（AMD OAM / 昇腾 / 国产）| 不判为 GPU 机头——`nvidia-smi` 报 0 卡时补跑 lspci 多厂商探测，有加速卡即按 GPU 形态判定；仅 NVIDIA 适用的能力按平台跳过（`05_nvswitch`、`14_dcgm` 整模块跳过，`15_firmware`、`99_os` 跳过各自的 NVIDIA 分支），不计 WARN |
| AMD 平台工具探测 | `amd-smi` 与 `rocm-smi` 都先试 `--json` 再试 `-j`（旧版 amd-smi 只认 `-j`），确定后全程使用同一选项；所用工具与版本落盘 `gpu/gpu_amd_tool.log`（新版 amd-smi 的异构 JSON schema 另存 `gpu_amd_new_schema.log`，不覆盖 rocm-smi 结果）|
| 开机后立即采集 | `/proc/uptime` 小于 180 秒（即不足 3 分钟）时打印 `[WARN] 系统开机仅 N 秒（不足 3 分钟）——GPU/网卡可能尚未枚举完成`，**继续采集**；报告端同一判据给出「采集时机」提示，且不把「无 GPU」当结论（阈值 180 秒由采集端与报告端共用）|
| USB 网卡 / USB 设备 | 跳过 `ethtool -m` 与 `lspci -s`（无光模块、BDF 不是 PCI 地址）；USB 类设备在链路统计中单列「外设」|
| 假 WARN 豁免（v1.53.37）| `psu_present`（服务器 PSU 走 BMC，无 `/sys/class/power_supply`）、`ipmi_lan2`（BMC 只暴露 1 个 LAN 通道）、`ipmi_fru_all`（末段 FRU 读不到但其余 13 段正常）按**内容级**豁免，不计 WARN；BMC 整体不可达仍照常记 WARN |
| 功耗读数 | `16_power` 复用 `10_psu` 已取到的 `psu/ipmi_dcmi_power.log`，避免同一份报告出现两个不同的 DCMI 瞬时值；文件无效时才自行查询 |
| 带外 BMC（v1.53.45，v1.54.3 修复）| `--bmc-ip` / `--bmc-user` / `--hgx-bmc-ip` / `--hgx-bmc-user` 指定后，`12_bmc` 在带内（KCS）之外再执行一组 `ipmitool -E -H <BMC_IP> -U <user> -I lanplus`，结果落 `bmc/remote_bmc_*.log`。BMC 密码由 `hwscope.sh` 在采集前交互输入（`/dev/tty`；显式指定地址时取 `BMC_PASS_TIMEOUT`，默认 300 秒），不落盘、不进 `ps` 与日志；远程采集时由本地提示经 stdin 送远端 |
| BMC 地址自动探测（v1.54.5，v1.54.6 明确默认通道）| 未给 `--bmc-ip` 时用带内（KCS）读 `ipmitool lan print`：**默认通道 1**（IPMI 规范中第一个 LAN 通道，多数厂商的共享/专用口在此），通道 1 有有效地址即采用；仅当通道 1 为空（`0.0.0.0` / `169.254.x`）才继续按 2→11 查找，取第一个有效 IPv4，并打印命中的通道号（实测存在通道 1 为 `0.0.0.0`、通道 7 为 `169.254.x`、管理口在通道 8 的机型）；多通道均有地址时全部列出。探测不到则提示手输 IP（`BMC_IP_PROMPT_TIMEOUT`，默认 20 秒，超时自动跳过带外），无人值守场景不会卡住。`--no-bmc-auto` 关闭探测；自动探测场景的密码等待期为 `BMC_PASS_TIMEOUT_AUTO`（默认 20 秒），空输入表示明确跳过带外且不计 WARN |
| 父进程参数必须 export | 模块在独立 bash 子进程执行，只拿到位置参数（输出目录）。`hwscope.sh` 中解析出的参数若不 export 就不会进入子进程，而模块会 `source conf/hwscope.conf`（其中写 `BMC_IP="${BMC_IP:-}"` 一类），变量随即被置空。v1.54.3 的缺陷即属此类：给了 `--bmc-ip` 仍只采带内。新增「父进程解析、子进程使用」的变量时，须加入 `hwscope.sh` 的 export 组 |

### BMC 带外采集（IPMI / Redfish）

BMC 提供带内无法获取的信息：PSU 实时功率与在位、风扇转速、SEL 事件、整机功耗、BMC 固件版本——报告中的「电源状态」「整机温度」「能耗台账」「SEL」均依赖它。带外采集只在拿到地址并输入密码后启用：给出 `--bmc-ip` 直接使用指定地址，未给则由带内自动探测（v1.54.5 起；`--no-bmc-auto` 可完全关闭）。

```bash
sudo bash hwscope.sh --bmc-ip <BMC-IP>                        # 单个 BMC（用户名默认 admin）
sudo bash hwscope.sh --bmc-ip <BMC-IP> --bmc-user root        # 自定义用户名
sudo bash hwscope.sh --bmc-ip <BMC-IP> --hgx-bmc-ip <HGX-BMC-IP>   # HGX 双 BMC（整机 + 基板）
```

- **密码**：给出 `--bmc-ip` 后运行时提示输入（不回显），不落盘，不进 git、shell history 或 `ps`
- **也可写入 `conf/hwscope.conf`（`BMC_PASS`）**：便于脚本化，但属**明文落盘**，且远程采集会把 conf 一并推送到目标机
- **不要手工 `export BMC_PASS`**：会进入 shell history（`remote_collect` 内部通过 stdin 传递，不属于手工 export）
- **未给 `--bmc-ip`（v1.54.5 起行为变化）**：先由带内（KCS）自动探测地址（通道 1 优先，命中后打印通道号），探测到才提示输入密码；探测不到会提示手输 IP（20 秒超时）。**只采带内**用 `--no-bmc-auto`（不探测、不提示、不连 BMC）

**厂商默认账户参考**（`admin` 只是最可能值；认证失败先换大小写，再换厂商账户）：

| 平台 | 默认账户 | 说明 |
|------|---------|------|
| Supermicro / ASUS / 技嘉（AMI MegaRAC）| `admin` / `admin` | 与 hwscope 默认一致 |
| 英业达 Inventec（P9000G7 等）/ Quanta | **`ADMIN` / `ADMIN`** | 全大写，小写会认证失败（实测）|
| Dell iDRAC | `root` / `calvin` | 用户名不是 admin |
| HPE iLO | `Administrator` / 随机（贴标签）| 出厂随机 |
| 联想 XCC | `USERID` / `PASSW0RD`（数字 0）| 或 `admin` / `admin` |
| 超聚变 / 浪潮 | `admin` / `admin` 或 `Admin@9000` | 以随机标签为准 |

> `curl` 使用的 netrc 凭据文件（600 权限）自 v1.54.9 起优先生成在 `/dev/shm`（tmpfs，重启即清），以弥补 `kill -9` 或 OOM 时 trap 来不及删除的残留。

> 带外失败通常只显示 `Unable to establish IPMI v2 / RMCP+ session`，不区分网络不通与认证失败——先用 `ping` 或 `ipmitool -H <BMC-IP> mc info` 手工确认一次。
> 远程采集同样接受这四个参数，见 [TOOLS.md](TOOLS.md) 的 `remote_collect.sh` 一节。

## 报告生成

> 报告体系为独立的 `report/` 模块（v1.35.0）。主入口 `report/report.sh`（v1.35.3 起移除 `tools/` 兼容入口，统一新路径）。

```bash
bash report/report.sh <采集目录>                          # json/md/txt/html 四件套
bash report/report.sh <采集目录> --acceptance             # 验收清单 md/html
bash report/report.sh <采集目录> --baseline <历史目录>     # 时序差异对比
bash report/report.sh <采集目录> --test-dir <压测目录>     # 关联压测归档
bash report/report.sh <采集目录> --fld-dir <FLD日志目录>    # 关联 DGX FLD 诊断日志（logs-<TS>/，生成「FLD 诊断参考」段，v1.37.0）
bash report/report.sh <采集目录> --bmc-verify             # 开启 OS-BMC 一致性交叉核验
bash report/report.sh <采集目录> --json                   # 仅生成 json（也可 --md / --txt / --both）
```

报告**只读日志、不重新采集**，可反复生成；日志缺失的字段显示 N/A。四件套与验收清单为两个独立分支：`--acceptance` 只生成 `hwscope_acceptance.{md,html}`，需要更新 `hwscope_report.{json,md,txt,html}` 时另行调用一次（v1.48.91）。

验收清单的判定项最多 17 项（按平台能力裁剪，无数据项不渲染），平台固有 N/A 折叠到表尾汇总且不计入「数据不足」；GPU XID 错误历史、CPU MCE、RAID 缓存电池等 6 项仅在检出时追加，不改变默认项数。

## 远程采集与多机对比

### 远程采集（Linux / WSL）

```bash
bash tools/remote_collect.sh -H root@<target-IP>                 # 全量采集并回拉
bash tools/remote_collect.sh -H root@<target-IP> --modules gpu   # 只采部分
bash tools/remote_collect.sh -H user@<target-IP> --no-sudo       # 普通用户直接执行
bash tools/remote_collect.sh -H root@<target-IP> --install 1,2   # 先远端安装基础与压测依赖再采集（v1.42.0）
```

- 流程：tar 临时推送项目 → 远端执行 hwscope → 回拉 → 清理（远端零持久占用）
- 认证：默认交互式密码（不落盘）+ ControlMaster 复用（只需输入一次密码）；root 免 sudo，普通用户自动加 `-t` 供 sudo 交互
- `--install <1,2,...>`：远端先执行 `install_tool.sh -c <列表> -y` 非交互安装依赖，再采集（远程冷启动）；安装失败即中止
- 结果：`output/remote_output/<机器ID>/`；归档包进 `logs/remote_logs/`。v1.48.99 起回拉为「逐机器精准替换」（清空旧目录 + 归档校验 + 目录名护栏），避免旧文件残留被兜底逻辑误读

### 远程采集（Windows 运维机）

```powershell
tools\win\remote_collect.bat -H root@<target-IP>
tools\win\remote_collect.ps1 -H root@<target-IP> -Modules gpu,cpu -OutDir D:\hwout
tools\win\remote_collect.bat -H root@<target-IP> -InstallItems 1,2   # 先远端安装基础与压测依赖再采集（v1.42.1）
```

- **与 sh 版的差异**：root 或免 sudo 场景走单次认证模式（v1.48.63，一条 ssh 完成推送 → 采集 → 回拉，只需输入 1 次密码；普通用户加 sudo 仍为 3 次）；采集进度实时显示（远端输出经 stderr 透传）；host key 变更自动处理（v1.48.82：备份 known_hosts → 清旧记录 → 打印新旧指纹 → 自动重试一次）；无 ControlMaster（Windows OpenSSH 不支持）
- 依赖：Windows 自带的 OpenSSH 客户端与 tar（零新依赖）
- 认证：交互式密码，每步失败自动重试 3 次
- `-InstallItems <1,2,...>`：远端先执行 `install_tool.sh -c <列表> -y` 非交互安装依赖（安装与采集合并为一条 ssh 命令）

### 多机对比与批量运维

```bash
bash report/tools/batch_compare.sh <目录1> <目录2> ...   # 多机横向对比（差异 ⚠️ 标注；输出到 logs/batch_compare/，-o 自定义）
bash tools/remote_run.sh -H "root@<target-IP-1> root@<target-IP-2>" -c 'nvidia-smi -L'   # 多机执行命令（v1.43.0 由 remote_batch.sh 改名）
bash tools/remote_run.sh -H root@<target-IP> --script ./diag.sh --pull-logs /tmp/diag  # 推送执行脚本并回拉过程日志
```

## 运维工具

### 一键推送更新（开发维护）

```bash
bash tools/agent/git_push.sh            # 审查并推送（交互确认）
bash tools/agent/git_push.sh -y         # 跳过确认直接推送
bash tools/agent/git_push.sh --dry-run  # 只审查不推送
```

直连失败自动探测本机代理后重推；全部失败时输出 `[AI-ACTION]` 指引。Windows 双击 `tools/agent/git_push.bat`。

**WSL 提示（v1.39.1）**：WSL 下 git_push 自动改用 Windows 的 `git.exe`，并通过 interop 探测 Windows 侧代理端口（v2ray 等），无需手工配置代理；若输出「WSL NAT 不可达」类提示，说明 Windows 侧代理未连接，先启动代理客户端并点「连接」。

### 固件基线管理

```bash
bash tools/fw_baseline_import.sh <基准机采集目录> --diff   # 预览基线差异
bash tools/fw_baseline_import.sh <基准机采集目录> --apply  # 写入 conf/fw_required.txt
```

### 能耗持续采样

```bash
bash tools/power_monitor.sh start [--interval 60] [--duration 0]   # 后台采样（DCMI 优先 / Redfish 兜底）
bash tools/power_monitor.sh status                                  # 查看采样状态
bash tools/power_monitor.sh stop                                    # 停止并输出聚合与 kWh 核算
```

### 报告在线预览

```bash
bash report/tools/report_server.sh          # 解包 logs/report/ 到本地预览（绑定 127.0.0.1）
```

### 网卡 / 线缆 / BMC 运维

```bash
bash tools/nic_tool.sh               # 网卡信息与固件管理（Mellanox）
bash tools/cable_map.sh              # IB 线缆拓扑（自动发现物理连线）
bash tools/bmc_tool.sh               # BMC 凭据与密码管理
```

### 时间同步（运维机 → 目标机，SSH）

目标机时钟偏差会使采集报告的时间戳失去可信度（内网常无 NTP 可达）。以**运维机时间**为基准对时：

```bash
bash tools/sync_time.sh root@<target-IP>                        # 单台（默认 auto：有带内 IPMI 时一并校准 BMC）
bash tools/sync_time.sh root@<target-IP-1> root@<target-IP-2>   # 多台
bash tools/sync_time.sh --dry-run root@<target-IP>              # 只探测偏差与目标机工具，不做修改
bash tools/sync_time.sh --no-bmc root@<target-IP>               # 明确跳过 BMC
```

Windows 运维机（功能等价）：

```
tools\win\sync_time.bat root@<target-IP>[,root@<target-IP-2>,...] [-DryRun] [-Bmc:auto|yes|no]
tools\win\sync_time.bat -h          # 或 --help、不带参数 → 显示用法（v1.53.4）
```

- **同步三处**：① OS 系统时间 ② RTC 硬件时钟 ③ BMC 时间（`--bmc` 强制 / `--no-bmc` 跳过 / 默认 `auto`）
- **成败判据（v1.53.0 修正）**：只有 OS 系统时间决定成败；RTC 与 BMC 失败各自输出 `[WARN]`，不影响整体判定——此前目标机缺 `hwclock` 时会把「OS 已设置成功」误报为 `[ERROR]`，导致运维反复重试
- **RTC 三级兜底**：`hwclock -w` → `python3` 直写 `/dev/rtc0`（写 UTC）→ 两者都不可用则 `[WARN]`「重启后会丢」。注意 Ubuntu 24.04 不预装 `hwclock`（在 `util-linux-extra` 包内），第二级是常用路径
- **BMC 时间**：使用目标机本地 `ipmitool`（带内 `/dev/ipmi0`，无需 BMC 凭据与网络）。BMC 时间是 SEL 时间轴的依据（XID、ECC、PCIe、电源事件均按它对齐），不校准则 SEL 时间不可信；无带内 IPMI 的平台按固有形态 `[SKIP]`，不计 WARN
- **传递 epoch 秒**：一个绝对时刻，日期与时间同时对齐
- **不改时区**：目标机按自身时区显示，时刻与运维机一致（例：运维机 CST 10:00 → 目标机 UTC 显示 02:00，为同一时刻）
- **NTP 临时停用后还原原值**（v1.53.0：旧实现只停不还原，会把机器留在 NTP 关闭状态）
- **不追溯**：已采集数据的时间戳不会因此变正确，流程应为「先对时，再采集」

### DHCP（新上架服务器批量发 IP）

```bash
sudo bash tools/dhcp_server.sh install            # 安装 dnsmasq
sudo bash tools/dhcp_server.sh config             # 配置网段（默认 192.168.50.0/24，分配 .100-.200）
sudo bash tools/dhcp_server.sh start              # 启动 DHCP 服务（需先 config）
sudo bash tools/dhcp_server.sh leases-export <csv>  # 租约导出
sudo bash tools/dhcp_server.sh reconcile <目录...>  # 租约与采集台账交叉核对
```

### AI 推理引擎安装

```bash
bash tools/install_ai.sh          # 交互菜单选择引擎：vLLM / SGLang / TRT-LLM / Ollama / llama.cpp
```

## 硬件压测（只读，不修改硬件配置）

> **状态：占位**（未完成、未在真实硬件验证），测试项目尚未定稿，不应据此下验收结论。

> 聚合与实现解耦（v1.34.21）：`test_all.sh` 为纯聚合入口；单工具脚本在 `test/<组件>/` 子目录，可独立执行。

```bash
bash test/test_all.sh                    # 菜单式入口（选测或全测）
bash test/test_all.sh --all              # 全部单脚本顺序执行
bash test/cpu/cpu_stress_ng.sh 60        # 单脚本独立执行（CPU 满载 60 秒）
bash test/cpu/cpu_sysbench.sh            # CPU 基准
bash test/memory/mem_stress_ng.sh        # 内存压力
sudo bash test/disk/disk_fio.sh          # 磁盘 IOPS（交互选盘，需 sudo）
bash test/network/net_iperf3.sh          # 网络吞吐（提示输入服务端地址）
sudo bash test/ib/ib_perftest.sh         # IB 链路（自动配对打流，需 sudo）
bash test/gpu/gpu_bandwidth.sh           # GPU 带宽（bandwidthTest 逐卡 + P2P）
bash test/gpu/gpu_burn_test.sh 1800      # GPU 长时满载（gpu-burn -tc，默认 30 分钟）
bash test/nccl/nccl_test.sh              # NCCL 集合通信
```

单脚本支持 `[时长秒]` 参数与 `-h` / `--help`，结果落盘 `logs/test/<SN>/`。

**测试日志自包含机器身份（v1.38.0）**：各测试脚本在 `test_init` 后自动写入 `=== Server Info ===` 段（机器 ID / 型号 / CPU / 内存 / GPU / OS）到汇总日志与 `server_info.log`，单项测试也能确定所属机器（参考厂商 FLD 日志做法）。单独查看：

```bash
bash test/test_server_info.sh          # 打印服务器信息（独立执行）
bash test/test_server_info.sh --append <文件>   # 追加到指定日志
```

## 多机器 / 多 Agent 协作

仓库可能被多台机器、多个 Agent 会话（DeepSeek Harness、Hermes 等）先后修改与推送。规则：**一切状态以远程 `origin/main` 为准**。

```bash
bash tools/agent/agent_sync.sh              # 开工第一步：fetch + 远程/本地 HEAD 与版本对比 + 未推送状态
bash tools/agent/agent_sync.sh --mark       # 提交后：标记未推送（写入本地 AGENT_STATE.md，该文件 gitignore）
bash tools/agent/git_push.sh -y             # 推送（默认 fetch + 落后 rebase + 版本单调检查）
bash tools/agent/agent_sync.sh --clear      # 推送成功后：清空未推送标记
```

- **版本号只升不降**：升版本前先看 agent_sync 显示的远程版本，在远程版本基础上递增；git_push 会拦截「本地版本低于远程版本」的推送
- 协作规则全文见 [AGENTS.md](../AGENTS.md)「多机器 / 多 Agent 协作规则」

## 环境变量

- `HWSCOPE_IPMI_TIMEOUT`（默认 `90`，单位秒）：IPMI/BMC 命令超时的**中档**（`sel list`、`sel elist`、`fru print`）。超时按命令代价分三级（v1.49.9）：
  - `HWSCOPE_IPMI_TIMEOUT_FAST`（默认 `30`）：`chassis status`、`chassis power`、`lan print`、`bmc guid`、`user list`、`mc info` 等快命令
  - `HWSCOPE_IPMI_TIMEOUT`（默认 `90`）：`sel` / `fru` 类中档命令
  - `HWSCOPE_IPMI_TIMEOUT_SLOW`（默认 `240`）：`sdr list`、`sensor list`（逐条读 SDR 仓库，慢机上实测可达 230 秒以上）

  现场 BMC 响应慢（如部分机型 `ipmi_sensors`、`sdr`、`fan_*`、`psu_*` 全线超时）时可调大，例如 `HWSCOPE_IPMI_TIMEOUT=180 sudo -E bash hwscope.sh`。`sudo` 需用 `-E` 保留环境变量，或写成 `sudo HWSCOPE_IPMI_TIMEOUT=180 bash hwscope.sh`。
- `MODULE_TIMEOUT`：单模块整体超时（秒），也可用命令行参数 `--module-timeout` 指定（默认 `600`，对应 `hwscope.sh` 的 `MODULE_TIMEOUT_DEFAULT`）。
- `BMC_PASS_TIMEOUT`（默认 `300`）：显式给出 BMC 地址时，密码提示的等待秒数；超时按「未输入」处理。
- `BMC_PASS_TIMEOUT_AUTO`（默认 `20`）：自动探测到 BMC 地址时的密码等待秒数，空输入表示跳过带外且不记 WARN。
- `BMC_IP_PROMPT_TIMEOUT`（默认 `20`）：自动探测不到地址时，手工补录 IP 的等待秒数，超时则跳过带外。
- `MLXLINK_EXTRA`（默认 `0`，v1.52.23）：设为 `1` 时每个 mlx5 口额外采集眼图与 FEC 能力——`mlxlink -e`（Show Eye Opening Info）与 `mlxlink --show_fec`（Show FEC Capabilities），落盘 `mlxlink_<dev>_eye.log`、`mlxlink_<dev>_fec.log`。两者均属 mlxlink 的 Queries 只读查询组（NVIDIA MFT 文档确认，不影响硬件）。
  **默认关闭**：16 口机器上每口多 2 次调用（净增约 32 次），而眼图与 FEC 只在需要深挖链路质量时使用（IB 误码排查、FEC 模式与规格核对）。用法：`MLXLINK_EXTRA=1 sudo -E bash hwscope.sh --modules network`。
  另：`mlxlink --show_ber_monitor` 官方标注不支持 HCA（网卡），故未采集。
