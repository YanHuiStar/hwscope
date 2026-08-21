# 报告与验收体系

> [← 返回 README](../README.md) · 使用入口见 [QUICKSTART.md](QUICKSTART.md) / [USAGE.md](USAGE.md)

## 报告四件套

采集完成自动生成 `hwscope_report.{json,md,txt,html}`：

| 文件 | 用途 |
|------|------|
| `hwscope_report.json` | 结构化数据（程序消费，全字段稳定） |
| `hwscope_report.md` | 详细报告（Markdown，含全部明细表） |
| `hwscope_report.txt` | 纯文本版（终端/邮件） |
| `hwscope_report.html` | 浏览器交付版（卡片分区/状态着色/打印友好，零依赖） |

### 明细表

- 内存每槽 / GPU 每卡（含 VBIOS）/ CPU 每颗 / 存储每盘 / 网络每端口 / PSU / SEL 事件 / 风扇 / RAID（虚拟盘级）/ HBA
- GPU 显存/功耗按"检测/额定"双值（如 `140.4 GiB/141GB`）
- **动态列隐藏**：整列全为占位符时隐藏并附注说明；JSON 始终保留全字段

### GPU 额定显存规格库

内置 60+ 主流 NVIDIA 型号额定容量映射，**检测值交叉验证**（GB/GiB 双口径 3% 容差）自动匹配正确容量：
- 多版本型号（如 A100 40|80）自动选近者
- **检测与额定不符 → `⚠️ 疑似显存魔改或伪装`**（PCIe 魔改卡识别）

## 验收清单（Acceptance Checklist）

`bash tools/report.sh <目录> --acceptance` 生成 `hwscope_acceptance.{md,html}`：

- **硬件概览（配置单）**：自动生成自检测数据（准系统/CPU/内存/GPU模组/计算网卡/网卡&端口/存储/电源模块/系统管理），可对照采购配置单核对
- **13 项判定**：GPU PCIe / NVLink / DCGM / VBIOS / 内存速率 / IB 线缆 / 磁盘寿命 / SMART / 电源冗余 / 温度 / SEL / 固件合规 / OS-BMC 一致性

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
| 固件无基线（默认不对比） | 不计 |
| **有基线但无固件数据** | **计（采集缺失）** |
| OS-BMC 未启用 / 无 BMC | 不计 |
| **启用后采集失败** | **计（真缺数据）** |

## 归档

双压缩包（同一 14 位时间戳）：

```
logs/<SN>-<ARCHIVE_TS>.tar.gz              # 详细分级日志
logs/report/<SN>-<ARCHIVE_TS>-report.tar.gz # 报告四件套
logs/remote_logs/                          # 远程采集归档（独立）
```

## 术语表

报告末尾附 IB 速率 / GPU 直连 / DCGM / SXM 等术语解释。
