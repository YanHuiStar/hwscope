# HwScope 路线图（ROADMAP）

> **活文档**：条目完成或放弃即删除，剩余条目 = 当前待办方向。
> 规划时按价值排序，落地时遵循 AGENTS.md 版本规则（新模块/新数据维度 = 中版本，修复 = 补丁）。
> 贡献/讨论见 [GitHub Issues](https://github.com/YanHuiStar/hwscope/issues)。

---

## 采集层（modules/）

- [ ] **固件合规模块 `15_firmware`** — 采集 GPU VBIOS / BMC FW / NIC FW / NVSwitch FW 版本，对照 `conf/fw_required.txt`（厂商推荐清单）逐项判 合规/落后/未知
  - 依赖：厂商验收手册推荐版本数据（需人工录入 fw_required.txt）
  - 复用：tools/firmware_check.sh 已有采集+基线逻辑，改造为采集模块
- [ ] **能耗台账 `16_power`** — BMC 功耗计累计读数（ipmitool sdr / Redfish Power），整机能耗核算
  - 场景：交付后供电核算、机房容量规划

## 报告层（tools/report.sh）

- [ ] **压测归档** — `--test-dir <path>` 指定压测目录（test/ 已落盘到 logs/test/<时间戳>/），报告新增"压测"章节（测试项/结果/耗时/详情文件）
  - 前置：test/test_common.sh 压测目录写 manifest.txt，report 读 manifest 解耦
- [ ] **健康评分** — 各维度加权打分（GPU 链路/NVLink/SMART/固件/SEL），总分 + 分级（优秀/合格/风险）
  - 扩展：基于现有 --acceptance 验收清单的判定逻辑
- [ ] **多机横向对比** — 同批次 N 台机器同字段对比表（固件版本/内存速率/盘型号），一眼看出批次差异
  - 场景：批量交付、批次一致性抽检

## 工具层（tools/）

- [ ] （暂无规划条目，欢迎提建议）

---

## 已完成（归档）

- v1.27.x — HGX 机头平台分类（x86_64_head：PCIe Gen5 Fabric Switch 检测）、机头报告专属文案（GPU/DCGM/验收 N/A 语义）、Fabric Switch 主板段展示、DCMI/整机功耗独立展示、MD 表格空行修复
- v1.28.x — GPU 每卡明细 VBIOS 列（去瞬时利用率）、nvidia-smi nvswitch 子命令采集与报告解析（无 CLI 平台兜底）、topo_nic cp 顺序修复、cable_map 中断恢复 trap；验收清单扩至 11 项（VBIOS 一致性/电源冗余/SMART 健康/温度汇总/IB 链路状态）、无 GPU 机头 N/A 不参与数据不足判定、RAID 虚拟盘独立表格、PSU type39 补 PN/容量、Fabric Switch 仅机头显示、动态列隐藏（全占位列隐藏）；JSON nics 空读修复（awk 管道）、ipmitool -E 环境密码、rm -rf 护栏、write_manifest --append、sync_version 同步头注释、MODULE_TIMEOUT 可配置
- v1.26.x — HBA 直通卡章节、N/A 隐藏、MST/DCGM hostengine 自拉起、模块并行超时保护、ib_test.sh IB 打流、RAID 虚拟盘/HBA SAS 明细、PSU DCMI/PMBus 采集、USB NIC 分类、BlueField DPU 标签、NIC chip 列、dmidecode 补全（cache/TPM/type39）、盘标称容量自动提取、验收清单假阳性防护（SEL/磁盘/内存 N/A）、模块超时 WARN 补记
- v1.26.0 — **验收清单模式**：`report.sh --acceptance` 生成 8 项 PASS/FAIL/WARN 判定交接单
- v1.25.x — 报告术语表、GPU直连标记、规格 vs 实测区分、全量采集原则
- v1.24.0 — EDAC 内存错误采集、DIMM Rank/内存类型入报告
- v1.23.x — 9 张明细表、sync_version.sh 单点版本号、locale 兜底、真 SN 采集

---

*最近更新: 2026-08-17 · 版本: v1.28.19*
