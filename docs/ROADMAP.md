# HwScope 路线图（ROADMAP）

> [← 返回 README](../README.md)
>
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

- [ ] **[P2] 能耗曲线入报告** — `power_monitor.sh` 采样 CSV 结果经 `report.sh` 新参数（如 `--power-csv`）并入报告"能耗台账"段，展示小时/日聚合与核算
  - 依赖：`power_monitor.sh`（v1.31.0 已产出 CSV/聚合）+ report.sh 解析
  - 验收标准：一份报告同时含单点快照与持续采样曲线数据

## 报告层（tools/report.sh）

- [ ] **[P2] 报告图表化（HTML）** — md2html.awk 输出 HTML 内嵌轻量图表（SVG 能耗曲线/内存占比/温度趋势），零 JS 依赖
  - 依赖：现 HTML 报告四件套 + power_monitor CSV
  - 验收标准：无外部依赖双击打开即有可视化

- [ ] **[P2] 数据入库（SQLite）** — `tools/hwdb.sh` 将各机 hwscope_report.json 关键字段导入 SQLite，支持按 SN/型号/批次查询与导出
  - 依赖：sqlite3（多数发行版自带）
  - 验收标准：批量导入 N 机，一条 SQL 查出批次全部 GPU 型号/固件版本

## 工具层（tools/）

- [ ] **[P2] 批量采集联动** — `remote_batch.sh` + `remote_collect.sh` 组合：一行命令对 N 台机器远程采集并逐个回拉，自动 `batch_compare.sh` 汇总
  - 依赖：remote_batch（v1.31.0）+ remote_collect（v1.29.0）+ batch_compare（v1.29.0）
  - 验收标准：`bash tools/remote_collect.sh -H h1 ... && batch_compare.sh output/SN1 output/SN2 output/SN3` 一键出对比表

- [ ] **[P2] CI 语法检查** — GitHub Actions 流水线：push 后对全部 .sh 跑 `bash -n` + shellcheck（若装），防 CRLF/语法回归
  - 依赖：GitHub Actions（仓库已托管）
  - 验收标准：每次 push 自动检查，失败即红

---

## 已完成（归档）

> 按版本倒序排列；同一主版本的多轮迭代合并为一条。

- v1.34.x — **Windows 原生远程采集**（tools/win/remote_collect.ps1/.bat）+ 多轮修复；`cleanup.sh/.ps1` 清理工具；**ShellCheck 全量清理**（SC2045/SC2155 等 55 处，0 错误）；**文档大重构**（README 501→70 行精简，详细文档拆分至 docs/：QUICKSTART/USAGE/REPORT/ARCHITECTURE/TOOLS/WIN_TOOLS/ROADMAP）；Linux remote_collect 拉取定位修复
- v1.33.x — OS-BMC 一致性校验默认关闭（v1.33.0：`--bmc-verify` 显式开启，禁用时验收项 N/A 不计入数据不足，独立 hwscope_bmc_verify.md 报告）；时间戳统一连写复核 10 处 + README 示例同步（v1.33.1）；report_server 强制 `--bind 127.0.0.1` 防报告无鉴权暴露局域网 + 16_power 未知能量单位不猜测（Joules 变体 3.6Mx 误差）、remote_collect 回拉按目录名、power_monitor 间隔校验（v1.33.2）；**全量审查修复批次**（v1.33.3：NO_MODULE 导出、--modules/--skip/--output 参数校验、rm-rf 护栏、herestring 残留 8 处、08_storage && 链、RAID vd_count 行锚定、PSU 六字段重建、16_power 单位顺序/十六进制守卫、MEM_SLOTS 锚定、disk 寿命 N/A 不假 PASS、GPU 功耗/温度数值守卫、9× local-in-subshell、dhcp_server shift2/port0/原子写、net_dhcp 退出码回滚、SEL 翻转检测、nvlink_verify 不假绿、cable_map 确认+恢复 trap、install 确认+退出码、perftest 客户端 IP、测试加固）；perftest `-S` 误判回退（实为 --sl 服务等级）+ smartctl Transport protocol 值判定（v1.33.4）；awk 数值守卫先 trim 前导空格（nvidia-smi CSV ` 700.00 W` 全拒回归修复，v1.33.5）；验收 N/A 计数规则细化 + IB 线缆配对条件驱动（有链接无数据=采集缺口计入，未插线=平台形态不计）
- v1.32.0 — **全工具与测试脚本统一 `-h/--help`**（common.sh 内置 show_script_help，net_dhcp/sync_version/test_all 独立实现），新增 `tools/README.md` + `test/README.md` 文档（含写操作警告），README 链接同步
- v1.31.0 — **ROADMAP 剩余 5 项 P2 全部落地**：`tools/fw_baseline_import.sh` 固件基线自动导入（基准机采集目录/表格 → conf/fw_required.txt，--diff 预览/--apply 写入+自动 .bak）；`tools/power_monitor.sh` 能耗持续采样（后台 DCMI/Redfish → CSV，stop 输出小时/日聚合 + 梯形积分 kWh 核算，补 16_power 单点快照缺口）；`tools/report_server.sh` 报告在线预览（解包 logs/report/ → web/ 缓存 + 索引页 + python3 http.server，零新依赖）；`tools/remote_batch.sh` SSH 批量运维（-H 多机 + -c 命令/--push 推送，逐机 .out 落盘 + summary）；`tools/dhcp_server.sh` 扩展 `leases-export <csv>` 租约导出 + `reconcile <目录...>` 租约↔采集报告 BMC IP/MAC 交叉核对（上架清单差异表，`--lease-file` 自定义租约路径）
- v1.30.0 — **报告基线对比 `--baseline <历史目录>`**（时序差异：BIOS/CPU/内存/GPU数/VBIOS/BMC固件 标量变化 + GPU/盘/网卡 SN 集合新增移除 + 固件版本逐项旧→新变化；JSON/MD/TXT/HTML 同步）；**验收清单扩至 13 项**（新增 固件版本合规：落后=FAIL、无基线判未知=N/A 不误报；OS-BMC 口径一致：不一致=FAIL、仅单侧数据=WARN、**无 BMC 机器判 N/A 不计入数据不足**——IPMI 日志全错误=平台无 BMC 属固有形态，无任何 IPMI 日志=工具缺失如实计入）
- v1.29.0 — **ROADMAP 全部原待办落地**：采集层新增 `15_firmware` 固件合规模块（对照 conf/fw_required.txt 判 合规/落后/未知，无基线判未知不 WARN）、`16_power` 能耗台账模块（Energy/kWh 累计读数 + DCMI/Redfish 功耗，单点快照核算）；报告层新增固件合规段、能耗台账段、BMC 数据一致性校验段（OS dmidecode/可见内存 vs BMC FRU/Redfish，零新采集，不一致 WARN 并排显示两边值）、压测归档 `--test-dir`（test_common.sh 写 manifest → report.sh 读 manifest 解耦）；新工具 `tools/batch_compare.sh` 多机横向对比（读各机 JSON，差异 ⚠️ 标注）、`tools/remote_collect.sh` SSH 远程采集（tar 暂存模式：流式 bash -s 无法满足多文件 source 结构，改为临时推送→执行→回拉→清理，密码不落盘）、`tools/dhcp_server.sh` dnsmasq 封装（安装/配置/启停/租约查询）
- v1.28.x — GPU 每卡明细 VBIOS 列（去瞬时利用率）、nvidia-smi nvswitch 子命令采集与报告解析（无 CLI 平台兜底）、topo_nic cp 顺序修复、cable_map 中断恢复 trap；验收清单扩至 11 项（VBIOS 一致性/电源冗余/SMART 健康/温度汇总/IB 链路状态）、无 GPU 机头 N/A 不参与数据不足判定、RAID 虚拟盘独立表格、PSU type39 补 PN/容量、Fabric Switch 仅机头显示、动态列隐藏（全占位列隐藏）；JSON nics 空读修复（awk 管道）、ipmitool -E 环境密码、rm -rf 护栏、write_manifest --append、sync_version 同步头注释、MODULE_TIMEOUT 可配置；**HTML 报告第四产物**（md2html.awk 专业样式）、GPU 标称内存库+修改卡检测、验收清单 HTML+硬件配置概览、术语 标称→额定、时间戳统一 YYYYMMDDHHMMSS、RAID/HBA 检测修复、Linux mdadm 软 RAID 识别
- v1.27.x — HGX 机头平台分类（x86_64_head：PCIe Gen5 Fabric Switch 检测）、机头报告专属文案（GPU/DCGM/验收 N/A 语义）、Fabric Switch 主板段展示、DCMI/整机功耗独立展示、MD 表格空行修复
- v1.26.x — **验收清单模式**（v1.26.0：`report.sh --acceptance` 生成 8 项 PASS/FAIL/WARN 判定交接单）；HBA 直通卡章节、N/A 隐藏、MST/DCGM hostengine 自拉起、模块并行超时保护、ib_test.sh IB 打流、RAID 虚拟盘/HBA SAS 明细、PSU DCMI/PMBus 采集、USB NIC 分类、BlueField DPU 标签、NIC chip 列、dmidecode 补全（cache/TPM/type39）、盘标称容量自动提取、验收清单假阳性防护（SEL/磁盘/内存 N/A）、模块超时 WARN 补记
- v1.25.x — 报告术语表、GPU直连标记、规格 vs 实测区分、全量采集原则
- v1.24.0 — EDAC 内存错误采集、DIMM Rank/内存类型入报告
- v1.23.x — 9 张明细表、sync_version.sh 单点版本号、locale 兜底、真 SN 采集

---

*最近更新: 2026-08-22 · 版本: v1.34.29*
