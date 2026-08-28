# 报告与验收体系

> [← 返回 README](../README.md) · 使用入口见 [QUICKSTART.md](QUICKSTART.md) / [USAGE.md](USAGE.md)
> 报告为独立 `report/` 模块（v1.35.0）：入口 `report/report.sh`，结构见 [report/README](../report/README.md)。

## 报告四件套

采集完成自动生成 `hwscope_report.{json,md,txt,html}`：

| 文件 | 用途 |
|------|------|
| `hwscope_report.json` | 结构化数据（程序消费，全字段稳定） |
| `hwscope_report.md` | 详细报告（Markdown，含全部明细表） |
| `hwscope_report.txt` | 纯文本版（终端/邮件） |
| `hwscope_report.html` | 浏览器交付版（卡片分区/状态着色/打印友好，零依赖） |

### 明细表

- 内存每槽（含 Rank 与位宽）/ GPU 每卡（含 VBIOS）/ CPU 每颗 / 存储每盘 / 网络每端口 / PSU / SEL 事件 / 风扇 / RAID（虚拟盘级）/ HBA
- GPU 显存/功耗按"检测/额定"双值（如 `140.4 GiB/141GB`）
- **动态列隐藏**：整列全为占位符时隐藏并附注说明；JSON 始终保留全字段
- **PCIe 链路明细（v1.44.0+）**：正文 = 统计摘要（满速/降速降宽/bridge 协商/管理芯片）+ ⚠️ 异常链路表；报告末尾附录 = 全量链路表（BDF/设备/LnkCap/LnkSta/判定）。判定三态：endpoint（网卡/GPU/RAID 卡）降速降宽=⚠️ 异常；bridge 端口降速=协商（下游能力，不计异常——x16 口接 x8 卡属正常协商，真问题体现在端点自身判定）；ASPEED/Matrox 管理芯片固有低速=标注不计
- **PSU 多数据源（v1.44.0+）**：明细按 IPMI FRU → 传感器占位 → SMBIOS Type 39（dmidecode）三级回退生成；Supermicro 等无单电源 FRU/功率传感器的平台由 Type 39 补全型号/SN/额定容量并附平台说明，PS<N> Status 传感器佐证在位状态
- **NIC 端口列（v1.44.0+）**：按 BDF 总线聚合显示同卡第 N 口/共 M 口（如 CX5 双口卡 `1/2`、`2/2`）；SXM 平台 GPU 明细链路列显示为 NVLink(协商)

### GPU 额定显存规格库

内置 60+ 主流 NVIDIA 型号 + AMD Instinct（MI300X/MI325X/MI250X/MI355X 等，v1.46.x）额定容量映射，**检测值交叉验证**（GB/GiB 双口径 3% 容差）自动匹配正确容量：
- 多版本型号（如 A100 40|80）自动选近者
- **检测与额定不符 → `⚠️ 疑似显存魔改或伪装`**（PCIe 魔改卡识别；NVIDIA/AMD 统一 verify_gpu_mem 检测）
- **AMD 平台**：04 模块走 ROCm（rocm-smi/amd-smi + rocminfo）采集，报告按厂商解析；验收 NVLink/DCGM 判 N/A（AMD 无 NVLink/DCGM，ROCm 诊断走 rocminfo + amd-smi ras）
- **多厂商适配器（v1.47.0）**：昇腾（npu-smi + HCCS 拓扑/health 日志）/ Intel（xpu-smi）/ 国产（cnmon·bmt-smi·mthreads-gmi·mx-smi·ix-smi）全量日志落盘 + 统一 `gpu_inventory.csv`（lspci 层，PCIe 链路判定可用）；厂商 SMI 解析标注【待真机校准】；无工具自动 lspci 兜底，卡不丢失

## 验收清单（Acceptance Checklist）

`bash report/report.sh <目录> --acceptance` 生成 `hwscope_acceptance.{md,html}`：

- **硬件概览（配置单）**：自动生成自检测数据（准系统/CPU/内存/GPU模组/计算网卡/网卡&端口/存储/电源模块/系统管理），可对照采购配置单核对
- **15 项判定**：GPU PCIe / NVLink / DCGM / VBIOS / 内存速率 / IB 线缆 / 磁盘寿命 / SMART / 电源冗余 / 温度 / SEL / 风扇冗余（v1.36.0）/ 固件合规 / OS-BMC 一致性 / PCIe 链路完整（v1.41.0）
- **多厂商 GPU（v1.46.x）**：NVIDIA 平台 NVLink/DCGM/VBIOS 正常判定；**AMD 平台 NVLink/DCGM 判 N/A**（无 NVLink/DCGM，xGMI 互联 + ROCm 诊断 rocminfo/amd-smi ras；**v1.48.0 起 OAM 模组识别 → x86_64_OAM 平台标记 + xGMI 拓扑采集/摘要**，链路健康判定待真机校准）；**昇腾平台 NVLink/DCGM 判 N/A**（无 NVLink/DCGM，HCCS 互联 + npu-smi 诊断；v1.46.7 起 lspci "Processing accelerators" 类目可识别）；GPU PCIe 项 AMD 按 lspci 链路判定 / PCIe 链路完整（v1.41.0）。**昇腾/Intel/国产等任意已识别加速卡**（v1.47.0 适配器框架）统一 CSV 走 lspci 层 → "GPU PCIe 链路完整"验收项按 LnkCap/LnkSta 全厂商可判（降速 FAIL / 满速 PASS）

> **PCIe 链路完整判定口径（v1.44.2+）**：只判 endpoint 设备（网卡/GPU/RAID 卡）——bridge 端口（PCIe switch/根端口）的 LnkSta 反映下游设备能力，不判异常；真链路问题（线缆/接触/插槽）会体现在端点自身 LnkCap vs LnkSta 判定中。
> **IB 设备口径（v1.44.0+）**：按 ibdev2netdev 映射到 ibp*/ibs* 接口的 CA 计数——以太模式 CA（如 CX5 双口以太）不计入 IB 设备数与 IB Link Down。

### 样例（HGX B300 实际输出）

```
| 1 | GPU PCIe 链路完整 | ✅ PASS | 全部 GPU 处于最高 PCIe 速率 |
| 2 | NVLink 互联 | ✅ PASS | 全互联无降级链路 |
| 3 | DCGM 诊断 | ⚠️ WARN | 配置项 Fail (Persistence Mode 未开启, 非硬件故障) |
| 4 | GPU VBIOS 版本一致 | ✅ PASS | 97.10.64.00.0C |
| 5 | 内存运行速率 | ✅ PASS | ⚠️ 降速运行（额定 6400 MT/s）（插满 32/32 槽 2DPC，降速属平台规范正常现象）|
| 13 | OS-BMC 口径一致 | — N/A | 校验未启用（--bmc-verify 开启后执行，独立核验报告）|

判定: 有条件通过（1 项 WARN，建议记录后交付）
```

> 交付时作为交接单；FAIL/WARN 项附具体说明，可直接转发客户。

### 判定规则

| 结果 | 条件 |
|------|------|
| ✅ 合格 | 全部通过（无 FAIL/WARN/N/A） |
| ❌ 不合格 | 任一 FAIL |
| ⚠️ 有条件通过 | 有 WARN（无 FAIL） |
| ⚠️ 数据不足 | N/A 计数 ≥ 4（无 FAIL/WARN） |
| ✅ 基本通过 | 无 FAIL/WARN，N/A 计数 1-3 |

### 条件驱动 N/A 计数（非一刀切）

按"当时条件"判定 N/A 是否计入数据不足：

| N/A 场景 | 计数？ |
|----------|--------|
| 无 GPU（机头） | 不计（平台固有） |
| 无 IB 卡 / IB 链路未接线（交付通常不接） | 不计（场景固有） |
| **已接线（链路 Active）但无线缆数据** | **计（采集缺失）** |
| 无数据盘 | 不计（配置形态） |
| **有盘但无 SMART** | **计（真缺数据）** |
| 固件版本合规 | 无基线（fw_required.txt 未录入，**默认不对比**；录入后自动启用） | 不计 |
| **有基线但无固件数据** | **计（采集缺失）** |
| OS-BMC 未启用 / 无 BMC | 不计 |
| **启用后采集失败** | **计（真缺数据）** |

## FLD 诊断参考（--fld-dir，v1.37.0）

关联 NVIDIA DGX Field Diagnostic 日志目录（`logs-<TS>/`），报告新增"FLD 诊断参考"段：

- **概览**：诊断版本/基础版本/产品/SN/总耗时 + 最终结果（PASS/FAIL）
- **测试矩阵**：逐测试项 PASS/跳过/FAIL + 组件数（解析 run.log 的 `Testing <test> OK/SKIPPED` 进度行 + `MODS-... | test | ... | component | OK` 矩阵行，纯文本解析零新依赖）
- **非通过项明细**：FAIL/跳过逐组件列出
- 适用：HGX/Dell 交付场景的 FLD 出厂诊断结果直接并入 HwScope 报告，与自有采集交叉引用

```bash
bash report/report.sh <采集目录> --fld-dir /path/to/logs-20251026-145655
```

## 归档

双压缩包（同一 14 位时间戳）：

```
logs/<SN>-<ARCHIVE_TS>.tar.gz              # 详细分级日志
logs/report/<SN>-<ARCHIVE_TS>-report.tar.gz # 报告四件套
logs/remote_logs/                          # 远程采集归档（独立）
```

## 术语表

报告末尾附 IB 速率 / GPU 直连 / DCGM / SXM 等术语解释。
