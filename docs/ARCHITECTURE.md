# 架构与目录结构

> [← 返回 README](../README.md) · 依赖安装见 [DEPENDENCIES.md](DEPENDENCIES.md) · 工具清单见 [TOOLS.md](TOOLS.md)

## 采集流水线

```
hwscope.sh ─── 参数解析 / 平台检测（SXM → PCIe → head → none）
     │
     ├─ 并行执行 17 个采集模块（每模块独立进程、每命令一个日志）
     │      │  write_manifest 声明输出
     │      ▼
     │   output/<机器ID>/   （各模块子目录 + manifest.txt）
     │      │
     │      ▼
     ├─ summary.txt 汇总 → 归档 logs/<SN>-<TS>.tar.gz
     │
     ▼
report/report.sh（只读日志，不重新采集；报告体系独立模块，见 report/README）
     ├─ 读各模块 manifest 解耦定位日志
     ├─ hwscope_report.{json,md,txt,html}   报告四件套
     ├─ hwscope_acceptance.{md,html}        验收清单（14 项判定，另有 5 项条件追加）
     └─ --baseline / --test-dir / --fld-dir / --bmc-verify
```

**数据流**：采集（写日志）→ 报告（读日志）单向流动，模块零耦合、可单独重跑、可审计。

## 目录结构

```
hwscope/
├── hwscope.sh          # 主入口：参数解析、平台检测、并行执行、汇总、归档
├── fixcrlf.sh          # Windows→Linux CRLF 换行修复
├── lib/
│   ├── common.sh       # 公共函数：run_and_log / 并行执行 / IPMI 共享快照 / check_cmd / 模块调度
│   ├── platform.sh     # 平台检测：detect_machine_id / detect_platform / ipmi_preheat
│   └── nvlink.sh       # NVLink 拓扑解析库（纯解析）
├── modules/            # 17 个采集模块（01_motherboard … 16_power，99_os），每模块一物理组件
│   └── gpu/            # GPU 多厂商适配器层（v1.47.0）：lib.sh + adapter_nvidia/amd/ascend/intel/国产×5（识别 v1.52.0 接入，厂商串待真机核对）/generic
├── report/             # 报告模块（交付物本体）：report.sh 入口 + lib(解析辅助/显存规格库/md2html)
│                       #   + sections(数据解析×9) + gen(生成器×7) + tools(多机对比/在线预览)
├── conf/
│   ├── hwscope.conf    # 模块开关、BMC 凭据、输出目录配置
│   └── fw_required.txt # 固件推荐版本基线（15_firmware 判定用）
├── test/               # 硬件压测脚本（只测不改）
│   ├── test_all.sh     # 聚合入口（菜单 / --all）
│   ├── report.sh       # 压测报告生成器（test_report.md/html）
│   ├── test_server_info.sh  # 测试前服务器信息（各单脚本 test_init 后自动调用）
│   ├── lib/            # test_common.sh（日志目录 / test_init / test_record / test_finish）
│   └── cpu/ memory/ disk/ network/ ib/ nccl/ gpu/   # 各组件单脚本（可独立执行）
├── tools/              # 运维操作脚本（Linux/WSL 侧）
├── tools/agent/        # 开发协作工具（agent/开发者用）：git_push · agent_sync · report_regression
│                       #   · regen_reports · repo_realign · sn_check ＋ baseline/（语义名回归基线）
├── tools/win/          # Windows 配套工具（.ps1/.bat）
├── docs/               # 详细文档（本目录）
├── output/             # 采集结果（gitignored）
└── logs/               # 压缩归档（gitignored）
```

## 平台兼容

| 平台 | 识别方式 | 说明 |
|------|---------|------|
| x86_64_SXM | nvidia-smi + NVSwitch | HGX B200/B300 一体化主机 |
| x86_64_PCIe | nvidia-smi 无 NVSwitch | NVIDIA PCIe GPU 服务器 |
| x86_64_PCIe（AMD） | lspci 3D controller AMD + 无 nvidia-smi（v1.46.6） | AMD Instinct / ROCm GPU 服务器（GPU_PLATFORM=amd） |
| x86_64_OAM（AMD） | lspci 3D controller AMD + device ID 属 OAM 型号（MI250X/MI300X/MI325X，v1.48.0） | AMD Instinct OAM 模组（GPU_PLATFORM=amd，xGMI/Infinity Fabric 互联） |
| x86_64_PCIe（昇腾）**〔待真机验证〕** | lspci Processing accelerators Huawei/HiSilicon + 无 nvidia-smi（v1.46.7） | Atlas 昇腾加速服务器（GPU_PLATFORM=ascend） |
| x86_64_head | PEX89/PEX97 Switchtec + 无 GPU | HGX 机头（模组单独采集） |
| x86_64_none | 无 GPU 无 Switch | 传统服务器/虚拟机 |
| aarch64_SXM | ARM + GPU | 国产/ARM 平台 |

> GPU 平台（GPU_PLATFORM，v1.46.x）：nvidia / amd / ascend / intel / mixed / other / none——采集与报告按厂商分路径。
>
> **⚠️ 验证状态**：NVIDIA / AMD 已真机验证（多份真机样本回归）；**ascend（昇腾）/ intel / 国产适配层为「待真机验证」**——代码路径与工具探测已实现，但尚无真机样本回归，型号识别与输出解析可能与实际有偏差。（NVIDIA=DCGM/NVLink，AMD=ROCm/rocminfo，昇腾=HCCS/npu-smi）。识别类目：NVIDIA/AMD/Intel 独立卡=lspci "3D controller"，华为昇腾卡=lspci "Processing accelerators"（v1.46.7）。AMD OAM 模组标记（v1.48.0）：device ID 属 MI250X/MI300X/MI325X OAM 型号 → GPU_OAM=1 → PLATFORM=x86_64_OAM（ID 表待真机校准）。

机器 ID（目录命名）：SN → baseboard SN → UUID → 时间戳兜底（四层保证非空且路径安全）。

## 模块架构

### 关键模块职责

| 组件 | 职责 | 关键函数/入口 |
|------|------|--------------|
| `hwscope.sh` | 主入口：CLI 参数解析与模块名校验、MODULES 注册表（17 项）、构建输出目录（覆盖前补归档护栏）、并行/串行调度、summary.txt 汇总与归档 | `MODULES` 数组 · 并行/串行双分支 |
| `lib/common.sh` | 公共执行层：`run_and_log(_parallel)` 命令执行+日志落盘、WARN 计数（`.warn_count` 跨进程传递）、`check_cmd` 工具探测、IPMI 共享快照（mkdir 锁 + `.tmp` 原子发布）、manifest 写入 | `run_and_log` · `ipmi_snapshot` · `module_start/end` |
| `lib/platform.sh` | 平台检测：`detect_machine_id`（SN→baseboard SN→UUID→时间戳四层兜底）、`detect_platform`（SXM/PCIe/OAM/head/none）、`detect_gpu_vendors`（lspci 厂商识别，设 `GPU_PLATFORM`）、`ipmi_preheat` 预热；采集端执行命令，报告端可传日志只读复用 | `detect_gpu_vendors` · `classify_machine` |
| `lib/nvlink.sh` | NVLink 拓扑**纯解析**库（不执行命令）：解析 topo 矩阵与 nvlink status 文本，输出降级链路/CRC 非零/down 链路，设 `NVLINK_*` 全局变量；仅被 nvlink_verify.sh 与 report.sh 调用 | `nvlink_parse_crc` 等 |
| `modules/*.sh` | 17 个采集模块，每模块一物理组件、每命令一日志；`module_start/end` 成对调用，工具缺失 `check_cmd` 后 `[SKIP]`；单模块可独立执行调试 | `bash modules/<NN>_<id>.sh <out_dir>` |
| `modules/gpu/` | GPU 适配器框架：`lib.sh` 统一接口（CSV 列定义/合并/manifest）+ 10 个 `adapter_<vendor>.sh`；由 04_gpu.sh 按 `GPU_PLATFORM` source 分发，非独立模块 | `run_gpu_<vendor>` · `gpu_merge_inventory` |
| `report/` | 报告交付层：`sections/`（10→90 序号 source 的解析段，填全局变量，**顺序勿乱**）→ `gen/`（json/md/txt/html 生成器，md 经 `md2html.awk` 转 HTML）→ 验收清单（--acceptance）；只读日志不重新采集 | `report.sh` → sections → gen |

### 设计约定

- **采集/报告分离**：`modules/*.sh` 只生成数据；`report/report.sh` 只读生成报告（不重新采集）；采集与报告分属 `modules/`（数据）与 `report/`（交付物）两个平级模块
- **GPU 多厂商适配器层（v1.47.0）**：`modules/gpu/adapter_*.sh` 按 `GPU_PLATFORM` 分发（NVIDIA/AMD 已真机验证；**昇腾/Intel/国产待真机验证**；通用兜底），统一输出 `gpu_inventory.csv`（列与 nvidia-smi 18 列一致）→ 报告/魔改检测/验收跨厂商零改动消费；识别类目：独立卡=lspci "3D controller"，昇腾等加速卡="Processing accelerators"
  - ✅ **国产五家（寒武纪/壁仞/摩尔线程/沐曦/天数智芯）已接入（v1.52.0）**：`detect_gpu_vendors`（lib/platform.sh）厂商串 case + `gpu_vendor_to_platform`（modules/gpu/lib.sh）+ 04_gpu.sh mixed 分发三处映射补齐，单厂商与混插均走厂商适配器。**厂商串【待真机核对】**——lspci vendor name 以真机输出为准校准；未匹配时回落 generic lspci 兜底，行为不劣于改前
- **持久化内核日志（v1.48.90）**：99_os 采 `journalctl -k --since "7 days ago"`（限内核消息+时间窗+tail），落 `journal_kernel_hw.log` / `journal_xid.log` / `journal_mce.log`——dmesg 重启即丢，GPU XID / CPU MCE 这类历史故障证据只能靠 journal 回溯
- **IB 链路性能计数器（v1.48.90）**：07_network 采 `perfquery -x`，ibstat 看不见误码，只有计数器能反映链路真实质量（SymbolError/LinkDowned/RcvErrors 等）
- **NVMe 错误日志（v1.48.90）**：08_storage 逐盘 `nvme error-log`，SMART 只给健康度，错误日志才有每次错误的类型/时间戳/LBA
- **RAID 缓存电池（v1.48.90）**：09_raid 逐控制器 `storcli /cN/bbu show all` + `/cN/cv show all`，「WriteBack 写缓存 + 电池失效」是掉电丢数据风险，两者必须同看
- **dmidecode 全量（v1.48.88）**：01_motherboard 采裸 `dmidecode`（覆盖全部 type，含 27 Cooling Device/29 电流/26 电压/28 温度/11 OEM Strings/38 IPMI），各 type 专用文件保留
- **CPU 功耗 RAPL（v1.48.89）**：10_psu 两次采样 `energy_uj` 算 ΔE/Δt，可与 DCMI 交叉验证口径
- **每命令一个日志**：可审计、可单模块重跑
- 模块自动跳过：工具未装 / 平台无此硬件（如虚拟机无 BMC）时 `[SKIP]`，不影响整体
- 依赖按需降级：dmidecode/lspci 缺失时系统汇总仍可用

## 输出结构

```
output/<机器ID>/
├── bmc/ cpu/ gpu/ memory/ storage/ network/ ...   # 各模块日志
├── hwscope_report.{json,md,txt,html}              # 报告四件套
├── hwscope_acceptance.{md,html}                   # 验收清单（--acceptance 生成）
├── summary.txt                                    # 采集汇总
└── hwscope.log                                    # 采集日志

output/remote_output/<机器ID>/                     # 远程采集回拉（对标本地结构）
logs/
├── <SN>-<TS>.tar.gz                               # 日志归档包
├── report/<SN>-<TS>-report.tar.gz                 # 报告包
└── remote_logs/                                   # 远程采集归档
```

## 安全约定

- **BMC 密码禁止 `-P` 内嵌命令**（明文进日志），必须 `export IPMI_PASSWORD` 传递
- 采集只读无害：不写硬件、不改配置；DCGM 仅 Level 1
- **隐私红线**：真实采集数据（SN/MAC/BMC IP）禁止进入 git，`output/`、`logs/` 已 gitignore
- report_server 绑定 `127.0.0.1`（防报告无鉴权暴露局域网）
- 远程采集：交互式密码不落盘；SSH key 免密仅限受信内部网络
