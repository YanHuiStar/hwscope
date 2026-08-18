# HwScope 路线图（ROADMAP）

> **活文档**：条目完成或放弃即删除（移入归档段），剩余条目 = 当前待办方向。
> 规划时按价值排序，落地时遵循 AGENTS.md 版本规则（新模块/新数据维度 = 中版本，修复 = 补丁）。
> 贡献/讨论见 [GitHub Issues](https://github.com/YanHuiStar/hwscope/issues)。

---

## 优先级说明

| 级别 | 含义 | 判定标准 |
|------|------|---------|
| **P0** | 交付刚需 | 验收/交付场景直接使用，缺了要现场补 |
| **P1** | 提效增值 | 批量交付/巡检提效，非单机必需 |
| **P2** | 场景储备 | 特定场景才用，依赖外部工具或数据 |

条目格式：`优先级 · 依赖 · 验收标准`（落地前必须三要素齐全）。

---

## 采集层（modules/）

- [ ] **[P2] 固件基线自动导入** — 从厂商验收手册/Redfish 自动拉取推荐固件版本写入 `conf/fw_required.txt`，替代人工录入
  - 依赖：厂商文档结构化来源（PDF/表格）或 BMC Redfish 提供推荐版本
  - 验收标准：一条命令更新基线，diff 提示变化
  - 备注：`15_firmware` 已完成（v1.29.0），当前基线为人工维护

- [ ] **[P2] 能耗持续采样** — `tools/power_monitor.sh` 定时采样整机功耗（DCMI/Redfish），生成小时/日能耗曲线与核算报表
  - 依赖：`16_power` 模块（v1.29.0 已落单点快照）
  - 验收标准：后台常驻采样 N 小时，输出 CSV + 图表数据，报告可引用

## 报告层（tools/report.sh）

- [ ] **[P2] 报告在线预览** — `tools/report_server.sh` 本地 HTTP 服务浏览历次报告归档（logs/report/），按 SN/时间筛选
  - 依赖：Python3 http.server 或 lighttpd；`hwscope_report.html` 四件套已具备
  - 验收标准：浏览器打开归档列表，点开即见 HTML 报告

## 工具层（tools/）

- [ ] **[P2] SSH 批量运维 `tools/remote_batch.sh`** — 对 N 台机器执行同一命令/推送同一文件并收集输出
  - 依赖：SSH key（同 remote_collect.sh）；已有 Windows 侧 `ssh_batch.ps1` 对应
  - 验收标准：一行命令对列表内全部机器执行并回显各机结果
  - 备注：`remote_collect.sh` 单机远程采集已完成（v1.29.0）

- [ ] **[P2] DHCP 租约与 IP 台账联动** — `dhcp_server.sh` 租约导出 CSV，与采集报告（BMC IP/MAC）交叉核对上架清单
  - 依赖：`dhcp_server.sh`（v1.29.0 已落地）+ `tools/win/scan_ip.ps1` 定位结果
  - 验收标准：租约表 ↔ 采集 BMC IP 对照，差异高亮

---

## 已完成（归档）

- v1.30.0 — **报告基线对比 `--baseline <历史目录>`**（时序差异：BIOS/CPU/内存/GPU数/VBIOS/BMC固件 标量变化 + GPU/盘/网卡 SN 集合新增移除 + 固件版本逐项旧→新变化；JSON/MD/TXT/HTML 同步）；**验收清单扩至 13 项**（新增 固件版本合规：落后=FAIL、无基线判未知=N/A 不误报；OS-BMC 口径一致：不一致=FAIL、仅单侧数据=WARN、**无 BMC 机器判 N/A 不计入数据不足**——IPMI 日志全错误=平台无 BMC 属固有形态，无任何 IPMI 日志=工具缺失如实计入）
- v1.29.0 — **ROADMAP 全部原待办落地**：采集层新增 `15_firmware` 固件合规模块（对照 conf/fw_required.txt 判 合规/落后/未知，无基线判未知不 WARN）、`16_power` 能耗台账模块（Energy/kWh 累计读数 + DCMI/Redfish 功耗，单点快照核算）；报告层新增固件合规段、能耗台账段、BMC 数据一致性校验段（OS dmidecode/可见内存 vs BMC FRU/Redfish，零新采集，不一致 WARN 并排显示两边值）、压测归档 `--test-dir`（test_common.sh 写 manifest → report.sh 读 manifest 解耦）；新工具 `tools/batch_compare.sh` 多机横向对比（读各机 JSON，差异 ⚠️ 标注）、`tools/remote_collect.sh` SSH 远程采集（tar 暂存模式：流式 bash -s 无法满足多文件 source 结构，改为临时推送→执行→回拉→清理，密码不落盘）、`tools/dhcp_server.sh` dnsmasq 封装（安装/配置/启停/租约查询）
- v1.27.x — HGX 机头平台分类（x86_64_head：PCIe Gen5 Fabric Switch 检测）、机头报告专属文案（GPU/DCGM/验收 N/A 语义）、Fabric Switch 主板段展示、DCMI/整机功耗独立展示、MD 表格空行修复
- v1.28.x — GPU 每卡明细 VBIOS 列（去瞬时利用率）、nvidia-smi nvswitch 子命令采集与报告解析（无 CLI 平台兜底）、topo_nic cp 顺序修复、cable_map 中断恢复 trap；验收清单扩至 11 项（VBIOS 一致性/电源冗余/SMART 健康/温度汇总/IB 链路状态）、无 GPU 机头 N/A 不参与数据不足判定、RAID 虚拟盘独立表格、PSU type39 补 PN/容量、Fabric Switch 仅机头显示、动态列隐藏（全占位列隐藏）；JSON nics 空读修复（awk 管道）、ipmitool -E 环境密码、rm -rf 护栏、write_manifest --append、sync_version 同步头注释、MODULE_TIMEOUT 可配置；**HTML 报告第四产物**（md2html.awk 专业样式）、GPU 标称内存库+修改卡检测、验收清单 HTML+硬件配置概览、术语 标称→额定、时间戳统一 YYYYMMDDHHMMSS、RAID/HBA 检测修复、Linux mdadm 软 RAID 识别
- v1.26.x — HBA 直通卡章节、N/A 隐藏、MST/DCGM hostengine 自拉起、模块并行超时保护、ib_test.sh IB 打流、RAID 虚拟盘/HBA SAS 明细、PSU DCMI/PMBus 采集、USB NIC 分类、BlueField DPU 标签、NIC chip 列、dmidecode 补全（cache/TPM/type39）、盘标称容量自动提取、验收清单假阳性防护（SEL/磁盘/内存 N/A）、模块超时 WARN 补记
- v1.26.0 — **验收清单模式**：`report.sh --acceptance` 生成 8 项 PASS/FAIL/WARN 判定交接单
- v1.25.x — 报告术语表、GPU直连标记、规格 vs 实测区分、全量采集原则
- v1.24.0 — EDAC 内存错误采集、DIMM Rank/内存类型入报告
- v1.23.x — 9 张明细表、sync_version.sh 单点版本号、locale 兜底、真 SN 采集

---

*最近更新: 2026-08-18 · 版本: v1.30.0*
