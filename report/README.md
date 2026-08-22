# HwScope 报告模块（report/）

> 报告是 HwScope 的**交付物本体**（四件套 + 验收清单），v1.35.0 起独立为与 `modules/`（采集）、`tools/`（运维）平级的项目模块。
> 职责：**只读解析采集日志**（不重新采集），生成 JSON/MD/TXT/HTML 报告、14 项验收清单、时序基线对比、BMC 一致性核验、报告在线预览、多机横向对比。

## 目录结构

```
report/
├── report.sh                 # 薄入口：参数解析 + source 装配 + FORMAT 分发
├── lib/
│   ├── report_common.sh      # 解析辅助：extract / filter_log / load_manifest / get_csv_col_index
│   ├── gpu_spec.sh           # GPU 额定显存规格库 gpu_mem_candidates（60+ 型号，交叉验证防魔改/伪装）
│   └── md2html.awk           # 纯 awk Markdown→HTML 转换器（零依赖，内嵌 CSS）
├── sections/                 # 数据解析（变量填充；source 顺序 = 原 report.sh 行序，勿乱）
│   ├── 10_env_mb_cpu.sh      # 环境/OS + 主板 + CPU + 内存
│   ├── 20_gpu.sh             # GPU 主区（规格库调用/每卡明细/魔改检测/ECC/序列号）
│   ├── 30_storage_gpu_extra.sh  # 存储 + GPU 补全(REMAP/VBIOS/NVLink) + NVSwitch
│   ├── 40_network_bmc.sh     # 网络 IB/线缆 + BMC + SEL + 线缆配对
│   ├── 50_nvlink_dcgm.sh     # NVLink 状态 + DCGM + 健康文本 + LINKTYPE
│   ├── 60_nic_fan_temp.sh    # 网卡明细(mt_model/GPU直连/PSID) + 风扇 + 温度
│   ├── 70_psu_raid_hba.sh    # PSU + RAID + HBA
│   ├── 80_fw_power_bmc_verify.sh  # 固件合规 + 能耗 + BMC 存在性 + OS-BMC 一致性
│   └── 90_test_baseline.sh   # 压测归档 + 报告基线对比
├── gen/                      # 各生成器（函数完整独立，source 装配时定义）
│   ├── gen_common.sh         # 术语表 glossary_md/txt + 网卡 net_extra_txt/md
│   ├── gen_json.sh           # JSON 四件套之 JSON（含 GLOSSARY_ENTRIES 定义）
│   ├── gen_md.sh             # Markdown 报告
│   ├── gen_txt.sh            # TXT 报告
│   ├── gen_html.sh           # HTML 报告（md2html.awk 转换）
│   ├── gen_acceptance.sh     # 验收清单（14 项判定 + 硬件概览配置单）
│   └── gen_bmc_verify.sh     # BMC 一致性核验独立报告（--bmc-verify）
└── tools/
    ├── batch_compare.sh      # 多机横向对比（读各机 hwscope_report.json，差异 ⚠️ 标注）
    └── report_server.sh      # 报告在线预览（绑定 127.0.0.1，防 SN/MAC 泄露）
```

## 用法

```bash
# 报告主入口（采集完成自动调用；也可对任意采集目录手动重跑）
bash report/report.sh <output_dir>                     # 四件套 json/md/txt/html
bash report/report.sh <output_dir> --acceptance        # 验收清单 md/html（14 项判定）
bash report/report.sh <output_dir> --baseline <历史目录> # 时序差异对比
bash report/report.sh <output_dir> --test-dir <压测目录> # 关联压测归档
bash report/report.sh <output_dir> --fld-dir <FLD日志目录> # 关联 DGX FLD 诊断日志（logs-<TS>/；解析 run.log 生成"FLD 诊断参考"段：版本/产品/最终结果 + 测试×组件结果矩阵，v1.37.0）
bash report/report.sh <output_dir> --bmc-verify        # OS-BMC 一致性交叉核验
bash report/report.sh <output_dir> --json              # 仅 json（也可 --md/--txt/--both）

# 报告配套工具
bash report/tools/batch_compare.sh <目录1> <目录2> ...   # 多机横向对比（差异 ⚠️ 标注）
                                                          #   默认输出 logs/batch_compare/（gitignored）；
                                                          #   -o 自定义前缀/路径（v1.35.2）
bash report/tools/report_server.sh [--port 8080]         # 报告在线预览（绑定 127.0.0.1）
```

> **路径统一**：报告体系入口与配套工具一律用 `report/` 路径（v1.35.3 已移除 tools/ 下的兼容 wrapper，旧路径不再可用）。

## 设计说明

- **行为零变化重构**（v1.35.0）：原 `tools/report.sh`（3329 行单文件）按区段拆分为 lib/sections/gen，代码逐字节搬移（仅 md2html.awk 路径适配）；输出四件套与验收清单经样例数据回归验证一致
- **source 顺序敏感**：`sections/` 编号即原文件行序（GPU_DIR → GPU_CSV → gpu_mem_candidates → GPU_DETAILS 依赖链），新增 section 时保持顺序
- **报告只读**：不重新采集；日志缺失字段显示 N/A；可对同一份数据反复生成
- **详细报告体系**：见 [docs/REPORT.md](../docs/REPORT.md)（四件套/14 项判定/条件驱动 N/A/HTML 回归）
