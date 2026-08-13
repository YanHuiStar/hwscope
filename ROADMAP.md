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

- v1.26.x — HBA 直通卡章节、N/A 隐藏、MST/DCGM hostengine 自拉起、模块并行超时保护、ib_test.sh IB 打流
- v1.26.0 — **验收清单模式**：`report.sh --acceptance` 生成 8 项 PASS/FAIL/WARN 判定交接单
- v1.25.x — 报告术语表、GPU直连标记、规格 vs 实测区分、全量采集原则
- v1.24.0 — EDAC 内存错误采集、DIMM Rank/内存类型入报告
- v1.23.x — 9 张明细表、sync_version.sh 单点版本号、locale 兜底、真 SN 采集

---

*最近更新: 2026-08-13 · 版本: v1.26.26*
