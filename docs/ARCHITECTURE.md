# 架构与目录结构

> [← 返回 README](../README.md) · 依赖安装见 [DEPENDENCIES.md](DEPENDENCIES.md) · 工具清单见 [TOOLS.md](TOOLS.md) · 报告体系见 [REPORT.md](REPORT.md)

## 1. 采集流水线

```
hwscope.sh ─ 参数解析 → 机器 ID → 平台检测（SXM / OAM / PCIe / head / none）
     │
     ├─ 并行执行 17 个采集模块（每模块独立进程、每命令一个日志）
     │      │  write_manifest 声明本次输出
     │      ▼
     │   output/<机器ID>/        各模块子目录 + manifest.txt
     │      │
     │      ▼
     ├─ summary.txt 汇总 → 归档 logs/<SN>-<TS>.tar.gz
     │
     ▼
report/report.sh（只读日志，不重新采集；独立模块，结构见 report/README）
     ├─ 按各模块 manifest 解耦定位日志
     ├─ hwscope_report.{json,md,txt,html}   报告四件套
     ├─ hwscope_acceptance.{md,html}        验收清单（独立分支，--acceptance 生成）
     └─ --baseline / --test-dir / --fld-dir / --bmc-verify
```

**数据流**：采集写日志 → 报告读日志，单向流动；模块之间零耦合，可单独重跑，全链路可审计。

## 2. 报告模块装配

`report/report.sh` 是薄入口：解析参数后按固定顺序 `source` 各部件并分发到生成器。装配顺序即依赖顺序，不可调整。

| 阶段 | 部件 | 职责 |
|------|------|------|
| 参数与分发 | `report/report.sh` | 解析 `[目录]` 与 `--json/--md/--txt/--both/--acceptance`、`--baseline`、`--test-dir`、`--fld-dir`、`--bmc-verify`；按格式调用生成器 |
| 解析辅助 | `lib/report_common.sh` | `extract` / `filter_log` / `jesc` / `load_manifest` / `get_csv_col_index` |
| 规格库 | `lib/gpu_spec.sh` | GPU 额定显存映射 `gpu_mem_candidates` 与魔改校验 `verify_gpu_mem` |
| 数据解析 | `sections/10…90`（10 个文件） | 填充全局变量；`65_nic_accounting.sh` 产出网卡归类结果，供验收概览与报告网络段共用 |
| 分类 | `lib/platform.sh` 的 `classify_machine` | 读日志信号（chassis / ECC / BMC / GPU）得到设备形态，零新采集 |
| 生成 | `gen/`（7 个文件） | `gen_common`（术语表/网络附加行）、`gen_json`、`gen_md`、`gen_txt`、`gen_html`、`gen_acceptance`、`gen_bmc_verify` |
| 格式转换 | `lib/md2html.awk` | 纯 awk 的 Markdown → HTML 转换，内嵌 CSS，零外部依赖 |

**source 顺序与依赖链**：

| 顺序 | 文件 | 依赖要点 |
|------|------|---------|
| 1 | `sections/10_env_mb_cpu.sh` | 定义 `GPU_DIR`、`PCIE_DIR`、`NET_DIR` 等目录变量，后续段共用 |
| 2 | `sections/20_gpu.sh` | 调用 `gpu_mem_candidates`，产出 `GPU_DETAILS`、`GPU_MODULE_STATE`、`GPU_PL_MISMATCH` |
| 3 | `sections/30_storage_gpu_extra.sh` | 存储明细、GPU 补全（REMAP / VBIOS / NVLink）、NVSwitch |
| 4 | `sections/40_network_bmc.sh` | IB / 线缆 / BMC / SEL；定义 `BMC_DIR`、`IB_*`、`SEL_*` |
| 5 | `sections/50_nvlink_dcgm.sh` | NVLink 状态、DCGM、`LINKTYPE_SUMMARY` |
| 6 | `sections/60_nic_fan_temp.sh` | `NIC_DETAILS`、`GPU_TOPO_AVAIL`、风扇、温度、端口总览 |
| 7 | `sections/65_nic_accounting.sh` | 依赖 `NIC_DETAILS` 与 `GPU_TOPO_AVAIL`，产出 `ACC_NIC_*` |
| 8 | `sections/70_psu_raid_hba.sh` | PSU（含容量成因后处理）、RAID、HBA |
| 9 | `sections/80_fw_power_bmc_verify.sh` | 固件合规门禁、能耗、BMC 存在性、OS-BMC 一致性 |
| 10 | `sections/90_test_baseline.sh` | 压测归档、报告基线对比 |

新增解析段时须同时注意：新变量若非 `local`，生成器才读得到（生成器在函数内拼装 heredoc，而 `local` 变量在函数外不可见）。

## 3. 目录结构

```
hwscope/
├── hwscope.sh          # 主入口：参数解析、机器 ID、平台检测、并行执行、汇总、归档
├── fixcrlf.sh          # Windows → Linux CRLF 换行修复
├── lib/
│   ├── common.sh       # 公共执行层：run_and_log / 并行执行 / IPMI 共享快照 / check_cmd / manifest / 模块调度
│   ├── platform.sh     # 平台检测：detect_machine_id / detect_platform / detect_gpu_vendors / classify_machine / ipmi_preheat
│   └── nvlink.sh       # NVLink 拓扑纯解析库（不执行命令）
├── modules/            # 17 个采集模块（01_motherboard … 16_power，99_os），每模块对应一个物理组件
│   └── gpu/            # GPU 多厂商适配器层：lib.sh + 10 个 adapter_<vendor>.sh
├── report/             # 报告模块（交付物本体）：report.sh + lib（解析辅助/规格库/md2html）
│                       #   + sections（数据解析 ×10）+ gen（生成器 ×7）+ tools（多机对比/在线预览）
├── conf/
│   ├── hwscope.conf    # 模块开关、BMC 凭据、输出目录配置
│   └── fw_required.txt # 固件推荐版本基线（15_firmware 判定用；全注释表示未启用）
├── test/               # 硬件压测脚本（占位：未完成/未验证；只测不改）
│   ├── test_all.sh     # 聚合入口（菜单 / --all）
│   ├── report.sh       # 压测报告生成器（test_report.md/html）
│   ├── test_server_info.sh  # 测试前服务器信息（各单脚本 test_init 后自动调用）
│   ├── lib/            # test_common.sh（日志目录 / test_init / test_record / test_finish）
│   └── cpu/ memory/ disk/ network/ ib/ nccl/ gpu/   # 各组件单脚本（可独立执行）
├── tools/              # 运维操作脚本（Linux / WSL 侧）
├── tools/agent/        # 开发协作工具：git_push · agent_sync · report_regression · regen_reports
│                       #   · repo_realign · sn_check ＋ baseline/（语义名回归基线）
├── tools/win/          # Windows 配套工具（.ps1 / .bat）
├── docs/               # 详细文档（本目录）
├── output/             # 采集结果（gitignored）
└── logs/               # 压缩归档（gitignored）
```

## 4. 平台识别

平台标识由 `uname -m` 与硬件信号组合而成，格式为 `<架构>_<形态>`（如 `x86_64_SXM`、`aarch64_SXM`）。

| 内部标识（`PLATFORM`） | 报告/验收展示值 | 识别方式 | 典型场景 |
|---|---|---|---|
| `<架构>_SXM` | `x86_64_SXM` | `nvidia-smi` 可用且 SXM 四路检测任一命中：`nvswitch` CLI 见 Switch Name；`lspci` 见 NVSwitch / SXM Bridge；`nv-fabricmanager` 进程且 `nvlink --status` 可用；`/dev/nvidia-nvswitchctl` 存在或 dmesg 见 `Nvlink Core is being initialized` | HGX B200 / B300 一体化主机 |
| `<架构>_OAM` | `x86_64_OAM` | `GPU_OAM=1`（AMD Instinct OAM 型号：MI250X / MI300X / MI325X 等） | AMD OAM 模组整机（xGMI / Infinity Fabric 互联） |
| `<架构>_PCIe` | `x86_64_PCIe` | 存在加速卡（NVIDIA 非 SXM / AMD / 昇腾 / Intel / 国产） | PCIe GPU 服务器、GPU 模组直通到主机的形态 |
| `<架构>_head` | `x86_64_Head` | GPU 数为 0 且 `lspci` 见 `PEX89` / `PEX97` / `Switchtec` | GPU 机头（模组经 PCIe Fabric 接入，单独采集） |
| `<架构>_none` | `x86_64_None` | 无 GPU、无 Fabric 交换机 | 传统服务器、虚拟机 |

> **命名约定**：内部标识用于机器消费，保持稳定写法——架构前缀 `x86_64` / `aarch64` 原样，形态后缀中缩写与专有名词（`SXM` / `OAM` / `PCIe`）保留厂商大小写，普通词小写（`head` / `none`）。
> 展示层按「后缀段首字母大写」输出（`head` → `Head`、`none` → `None`），即报告与验收清单中显示为 `x86_64_Head`、`x86_64_None`；JSON 同时给出两个字段：`platform`（原值）与 `platform_label`（展示值）。
> 旧版本采集的机器若标识与日志矛盾（例如有 Fabric 交换机却写成 `_none`），报告端会按 `pcie/lspci_all.log` 纠偏并标注「采集时版本较早，平台标识按 PCIe 日志重新判定」。

判定补充：

- **head 判据须叠加「无 GPU」**：SXM 一体化主机主板同样带 PEX89xxx，只按交换机判定会让整机漂移为机头。
- **装了 NVIDIA 软件栈但 0 张 N 卡的整机**：先用 `detect_gpu_vendors` 补跑 lspci 多厂商判定，有加速卡即按 GPU 形态（OAM / PCIe）判定，不判 head。
- **SXM 诊断独立性**：前三路检测都要求 NVLink / NVSwitch 可用，NVLink 域建不起来的机器会三路全不中；第四路（`/dev/nvidia-nvswitchctl` 或 dmesg）不依赖链路状态，避免把模组故障误判成 PCIe 平台形态。
- `PLATFORM` 只表达形态，不代表模组在位；模组是否识别到由报告 GPU 段的「未识别到 / 状态」行单独说明。

### 4.1 GPU 平台（`GPU_PLATFORM`）

`detect_gpu_vendors` 依据 lspci 类目与厂商串设置：独立卡为 `3D controller`，昇腾等加速卡为 `Processing accelerators`；`VGA compatible controller`（集显）不计入独立 GPU。

| 取值 | 含义 |
|------|------|
| `nvidia` | NVIDIA 独立卡 |
| `amd` | AMD Instinct（ROCm） |
| `ascend` | 华为昇腾（npu-smi / HCCS） |
| `intel` | Intel 数据中心 GPU（xpu-smi） |
| `cambricon` / `biren` / `moorethreads` / `metax` / `iluvatar` | 国产加速卡（cnmon / bmt-smi / mthreads-gmi / mx-smi / ix-smi） |
| `mixed` | 多厂商混插，按厂商分别走适配器 |
| `other` | 已识别到加速卡但厂商未归类，走 lspci 通用兜底 |
| `none` | 无独立加速卡 |

**验证状态**：NVIDIA 与 AMD 已由多份真机样本回归；**昇腾 / Intel / 国产加速卡为「待真机验证」**——代码路径与工具探测已实现，尚无真机样本，型号识别与输出解析可能与实际有偏差。国产五家的厂商串以真机 lspci 输出为准校准；未匹配时回落 generic 兜底，行为不劣于未接入时。

**机器 ID（目录命名）**：系统 SN → 主板 SN → 系统 UUID → 时间戳，四层兜底保证非空且路径安全。

## 5. 模块架构

### 5.1 关键模块职责

| 组件 | 职责 | 关键函数 / 入口 |
|------|------|----------------|
| `hwscope.sh` | 主入口：CLI 参数解析与模块名校验、`MODULES` 注册表（17 项）、构建输出目录（覆盖前补归档护栏与路径安全检查）、并行 / 串行调度、`summary.txt` 汇总与归档 | `MODULES` 数组 · 并行 / 串行双分支 |
| `lib/common.sh` | 公共执行层：`run_and_log(_parallel)` 命令执行与日志落盘、WARN 计数（`.warn_count` 跨进程传递）、`check_cmd` 工具探测、IPMI 共享快照（mkdir 锁 + `.tmp` 原子发布）、manifest 写入 | `run_and_log` · `ipmi_snapshot` · `module_start` / `module_end` |
| `lib/platform.sh` | 平台检测：`detect_machine_id`（四层兜底）、`detect_platform`（SXM / OAM / PCIe / head / none）、`detect_gpu_vendors`（lspci 厂商识别，设 `GPU_PLATFORM`）、`classify_machine`（设备形态）、`ipmi_preheat` 预热；采集端执行命令，报告端可传日志只读复用 | `detect_platform` · `detect_gpu_vendors` · `classify_machine` |
| `lib/nvlink.sh` | NVLink 拓扑**纯解析**库（不执行命令）：解析 topo 矩阵与 nvlink status 文本，输出降级链路 / CRC 非零 / down 链路，设 `NVLINK_*` 全局变量；由 `tools/nvlink_verify.sh` 与 `report/report.sh` 调用 | `nvlink_parse_topo` · `nvlink_parse_crc` · `nvlink_load_from_logs` |
| `modules/*.sh` | 17 个采集模块，每模块对应一个物理组件、每命令一个日志；`module_start` / `module_end` 成对调用，工具缺失时 `check_cmd` 后 `[SKIP]`；单模块可独立执行调试 | `bash modules/<NN>_<id>.sh <out_dir>` |
| `modules/gpu/` | GPU 适配器框架：`lib.sh` 统一接口（CSV 列定义 / 合并 / manifest）+ 10 个 `adapter_<vendor>.sh`；由 `04_gpu.sh` 按 `GPU_PLATFORM` 分发，非独立模块 | `run_gpu_<vendor>` · `gpu_merge_inventory` |
| `report/report.sh` | 报告装配入口：参数解析 → source lib + sections + gen → 按格式分发；只读日志不重新采集 | `report.sh` → sections → gen |

### 5.2 设计约定

- **采集与报告分离**：`modules/*.sh` 只生成数据，`report/report.sh` 只读取日志生成报告；二者是 `modules/`（数据）与 `report/`（交付物）两个平级模块。
- **每命令一个日志**：日志即证据，可审计、可单模块重跑；日志缺失时报告显示 N/A，不推断。
- **模块自动跳过**：工具未安装或平台无此硬件（如虚拟机无 BMC）时 `[SKIP]`，不影响整体采集。
- **依赖按需降级**：`dmidecode` / `lspci` 缺失时系统汇总仍可用；GPU 厂商工具缺失时回落 lspci 通用适配器，加速卡不从报告中丢失。
- **GPU 多厂商适配器层**：`modules/gpu/adapter_*.sh` 按 `GPU_PLATFORM` 分发，统一输出 `gpu_inventory.csv`（列与 nvidia-smi 18 列一致）→ 报告、魔改检测、验收跨厂商零改动消费。

### 5.3 报告侧数据采集约定

以下采集项为报告判定提供证据链，均只读、不修改系统状态：

| 采集项 | 模块 | 用途 |
|--------|------|------|
| `journalctl -k --since "7 days ago"`（限内核消息 + 时间窗 + tail） | 99_os | 持久化内核日志；dmesg 重启即丢，GPU XID / CPU MCE 等历史故障只能靠 journal 回溯 |
| `perfquery -C <CA> -x`（逐 CA 查询） | 07_network | IB 链路性能计数器（SymbolError / LinkDowned / RcvErrors 等）；ibstat 看不见误码。不带 `-C` 会落到 `(null):0` 端口并必然失败 |
| `mlxlink -d /dev/mst/*` | 07_network 先按 CA 别名采集；失败时用 `/sys/class/infiniband/<ca>/device` 取 BDF，映射到 `/dev/mst/<dev>` **重试一次**（实测 mlx5_5/6 跨厂商失败属别名解析问题），仍失败记入 `mlxlink_failures.log` |
| `nvme error-log` | 08_storage | 每盘错误类型、时间戳、LBA；SMART 只给健康度 |
| `storcli /cN/bbu show all` + `/cN/cv show all` | 09_raid | RAID 缓存电池与写缓存策略，二者必须同看 |
| 裸 `dmidecode`（覆盖全部 type） | 01_motherboard | 含 Type 27 冷却 / 28 温度 / 29 电流 / 26 电压 / 11 OEM Strings / 38 IPMI；各 type 专用文件保留 |
| `energy_uj` 两次采样 | 10_psu | CPU RAPL：ΔE/Δt，可与 DCMI 交叉验证口径 |
| 裸 `nvidia-smi` | 04_gpu | 现场最常看的 `Pwr:Usage/Cap`、显存占用、利用率一屏形态（与 `-q`、`query-gpu` 并存） |

## 6. 输出结构

```
output/<机器ID>/
├── bmc/ cpu/ gpu/ memory/ storage/ network/ ...   # 各模块日志 + manifest.txt
├── hwscope_report.{json,md,txt,html}              # 报告四件套
├── hwscope_acceptance.{md,html}                   # 验收清单（--acceptance 生成）
├── summary.txt                                    # 采集汇总（模块结果 / 耗时 / 版本）
└── hwscope.log                                    # 采集过程日志

output/remote_output/<机器ID>/                     # 远程采集回拉（对标本地结构）
logs/
├── <SN>-<TS>.tar.gz                               # 日志归档包
├── report/<SN>-<TS>-report.tar.gz                 # 报告包
└── remote_logs/                                   # 远程采集归档
```

## 7. 安全约定

- **BMC 密码禁止 `-P` 内嵌命令**（明文进日志），必须以 `export IPMI_PASSWORD` 传递。
- **采集只读无害**：不写硬件、不改配置；DCGM 仅运行 Level 1 诊断。
- **隐私红线**：真实采集数据（SN / MAC / BMC IP）禁止进入 git，`output/`、`logs/` 已 gitignore；文档与样例使用 `<SN>`、`<BMC-IP>` 占位。
- **报告预览服务**：`report/tools/report_server.sh` 绑定 `127.0.0.1`，避免无鉴权的报告暴露到局域网。
- **远程采集**：交互式密码不落盘；SSH 免密仅限受信内部网络。
