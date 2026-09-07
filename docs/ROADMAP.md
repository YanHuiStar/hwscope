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

- [ ] **[P1] BMC 前置探测短路** — `lib/platform.sh` 新增 `detect_bmc`（采集启动时执行一次）：KCS 本地通道 + LAN（已配置时）+ Redfish（模块 12 基础）**三通道全明确失败才判 absent**（保守——BMC 忙/网络抖动/权限问题不得误判，丢数据比多花几秒严重）；无 BMC 平台模块 10 PSU / 11 风扇 / 12 BMC / 16 能耗整组 `[SKIP]` 并落盘 `00_bmc_absent.log` 标记（非静默跳过，报告端可区分"探测跳过"与"采集失败"）；报告端固有 N/A 判定路径不变（兼容旧采集目录）
  - 依赖：ipmi_preheat 已有预热基础 + Redfish（模块 12）；探测在全局做一次，禁每模块各测（重复超时）
  - 验收标准：无 BMC 机器（消费级/WSL）采集提速（IPMI 超时调用整组消除）+ 日志少落几十个错误文件；有 BMC 机器零行为变化；模拟 BMC 慢响应场景不误判
- [ ] **[P2] 能耗曲线入报告** — `power_monitor.sh` 采样 CSV 结果经 `report.sh` 新参数（如 `--power-csv`）并入报告"能耗台账"段，展示小时/日聚合与核算
  - 依赖：`power_monitor.sh`（v1.31.0 已产出 CSV/聚合）+ report.sh 解析
  - 验收标准：一份报告同时含单点快照与持续采样曲线数据

## 诊断层（diagnostic/，规划中）——HwScope 自有诊断系统（HDS）

> **定位**：主动健康诊断——介于只读采集（modules/，零负载）与性能压测（test/，重负载）之间。
> **核心原则（v1.48.45 立向）**：**自研为本，工具为用**——诊断项定义、执行逻辑、判定阈值、分级流程、报告输出全部是本项目自有的（跨厂商统一口径）；DCGM/FLD 仅作**设计参照**（学其分级/逐项/现场流程思想），**不包装、不调用** dcgmi diag/partnerdiag——NVIDIA 有 DCGM 才有诊断、AMD/国产卡没有就空，这正是要自研的原因（差异化：任何平台同一套诊断体系）。
> **架构仿 test/**：`diag_all.sh` 聚合入口（菜单/--all/分级参数）+ 单项脚本独立执行 + `diagnostic/lib/diag_common.sh` 公共库（分级确认/超时/统一 JSON）+ 落盘 `logs/diag/<SN>/`。
> **安全边界**：L0/L1 免确认（轻负载 ≤2 分钟/项，可无人值守）；**L2+ 执行前必须用户确认**（负载 10 分钟起，破坏 modules/ 只读约束的都放这层）。

### 分级与自研诊断项集（核心设计——项 = 检测方法 + 判定规则，全部本项目定义）

| 级 | 名称 | 负载/耗时 | 自研诊断项（草案——每项含"怎么测+怎么判"） |
|----|------|----------|-------------------------------------------|
| **L0** | 静态校验 | 只读/秒级 | 现有 18 项验收 = L0 雏形（采集数据判定，全部自研） |
| **L1** | 主动快检 | 轻负载 ≤2 分钟/项，免确认 | ① **GPU 算力冒烟**（短负载 10-30s：8 卡全有输出、无 error、**卡间离散 <X%**——单卡塌=坏卡早期信号）② **显存健康**（ECC/RAS 计数=0 + 检测=额定容差内）③ **互联完整性**（NVLink/xGMI 全互联边存在 + 无降速）④ **温度-负载响应**（负载前后温升 <X°C——异常温升=散热问题）⑤ **CPU 冒烟**（全核短负载：无错误、频率不塌）⑥ **内存快检**（60s 压力无错）⑦ **存储 IO 冒烟**（20s fio 无 IO 错）⑧ **网络状态**（IB Active + 重试计数不增长） |
| **L2** | 深度诊断 | 10-30 分钟，**需确认** | 满载算力达标（每卡 GFLOPs 达额定 %）/ 显存带宽（全卡）/ 内存长压 / 互联压力 / **温度平台期**（满载 10 分钟稳定 <X°C） |
| **L3** | 全面诊断 | 小时级，**需确认**（对标 FLD 出厂） | 长时烧机 + 全组件 + RCCL 集合通信 + **压力前后 ECC/RAS 对比**（压力后错误增长=隐患——FLD 哲学：静态 0 不够，负载后不变才健康） |

**含金量设计点（自研价值所在）**：
1. **压力前后 RAS/ECC 对比**——诊断核心洞察：负载前后错误计数不变才是健康（现验收只查静态）
2. **多卡离散度判定**——卡间算力/温度/功耗一致性（8 卡中 1 卡塌 = 早期故障，比绝对阈值更早发现）
3. **跨厂商统一口径**——NVIDIA/AMD/国产同一诊断项集与判定规则，适配器只换底层读数（同 GPU 采集 adapter 模式）
4. **阈值可配置**——`conf/diag.conf`（仿 fw_required.txt；温升/离散度/达标率基线按机型可调）
5. **现场闭环**——diag_result.json（统一 schema：项/结果/实测/阈值/耗时）→ 报告诊断段 + 验收"主动诊断"项联动——冒烟到出厂一张清单

### 实施阶段（自研路线）

- [ ] **[P0] 诊断框架** — `diagnostic/` 骨架：diag_all.sh（菜单/--all/--level N）+ diag_common.sh（L2+ 确认/超时/并行）+ conf/diag.conf + 统一 JSON schema + 报告"诊断段"（读 diag_result.json 渲染，跨厂商同表）
  - 依赖：无（纯框架）；验收标准：`bash diagnostic/diag_all.sh --level 1` 一条命令出诊断 JSON + 报告段
- [ ] **[P1] L1 GPU 诊断项（NVIDIA 首发）** — 8 项 L1 中 GPU 域：算力冒烟（开源短档 gpu-burn 10s——编排/判定/离散度计算自研）、显存健康（ECC 采集 + 规格自洽——自研判定）、互联（nvlink.sh 解析升华为诊断判定）、温度响应（自有监控探针读 smi 前后对比）
  - 验收标准：NVIDIA 机 L1 全项 PASS/FAIL 判定正确（含模拟 1 卡塌的 FAIL 检出）
- [ ] **[P1] L1 系统域诊断（CPU/内存/存储/网络）** — test/ 工具短档 + 自研判定阈值（CPU 频率不塌/内存零错/IO 无错/IB 重试不增长）
  - 验收标准：非 GPU 服务器/台式机也能跑 L1（诊断不绑 GPU）
- [ ] **[P1] AMD/国产对位** — adapter 换读数层：amd-smi/rocm-smi 取数（真机核对清单含此）；国产卡厂商工具读数——判定规则不变
  - 依赖：真机 AMD OAM（上系统核对清单待办）+ 国产卡样本；验收标准：AMD 平台 L1 同表渲染无厂商差异
- [ ] **[P2] L2/L3 深度档 + 验收联动** — 满载/长时档（确认机制）、压力前后 RAS 对比项、验收清单加"主动诊断 L1"项（跑了 L1 才有结论，未跑显示提示）
- [ ] **[P2] FLD 日志导入（保留独立）** — 现场第三方 FLD 已跑日志的解析导入（--fld-dir 已有解析器）——作为**外部参考输入**而非诊断本体
  - 验收标准：外部 FLD 结果可与 HDS 诊断同报告对照

## 报告层（report/ 模块；入口 report/report.sh）

- [ ] **[P2] 报告图表化（HTML）** — md2html.awk 输出 HTML 内嵌轻量图表（SVG 能耗曲线/内存占比/温度趋势），零 JS 依赖
  - 依赖：现 HTML 报告四件套 + power_monitor CSV
  - 验收标准：无外部依赖双击打开即有可视化

- [ ] **[P2] 数据入库（SQLite）** — `tools/hwdb.sh` 将各机 hwscope_report.json 关键字段导入 SQLite，支持按 SN/型号/批次查询与导出
  - 依赖：sqlite3（多数发行版自带）
  - 验收标准：批量导入 N 机，一条 SQL 查出批次全部 GPU 型号/固件版本

## 工具层（tools/）

- [ ] **[P2] 批量采集联动** — `remote_run.sh` + `remote_collect.sh` 组合：一行命令对 N 台机器远程采集并逐个回拉，自动 `batch_compare.sh` 汇总
  - 依赖：remote_run（v1.31.0，v1.43.0 改名）+ remote_collect（v1.29.0）+ batch_compare（v1.29.0）
  - 验收标准：`bash tools/remote_collect.sh -H h1 ... && batch_compare.sh output/SN1 output/SN2 output/SN3` 一键出对比表

- [ ] **[P2] CI 语法检查** — GitHub Actions 流水线：push 后对全部 .sh 跑 `bash -n` + shellcheck（若装），防 CRLF/语法回归
  - 依赖：GitHub Actions（仓库已托管）
  - 验收标准：每次 push 自动检查，失败即红

- [ ] **[P1] AMD/国产 GPU 显存规格库真机校准** — MI355X/MI325X 等新号与昇腾/寒武纪型号入 `gpu_spec.sh`，device ID 表（OAM 判定）真机样本核对
  - 依赖：真机样本（AMD OAM 服务器样本已入基线；国产卡待现场）
  - 验收标准：新机型采集后额定显存/魔改检测正确

- [ ] **[P1] GB300 机架级特征检测** — 液冷（GPU 温度异常低 + 无风扇传感器）+ NVLink 72 卡拓扑 → `server-gb300` 分类
  - 依赖：GB300 NVL72 真机样本
  - 验收标准：GB300 采集自动分类 server-gb300 且不误判

- [ ] **[P2] 消费级平台段隐藏统一策略** — 笔记本/台式机/一体机上无 BMC/IB/PEX 段的条件隐藏收拢为统一规则（现逐段各自条件化）
  - 依赖：消费级样本数据
  - 验收标准：消费级报告无"无 BMC"类 N/A 噪音段

- [ ] **[P2] 各厂商工具 check_cmd_flex 候选目录补充** — npu-smi（/usr/local/Ascend）、xpu-smi、cnmon 等候选目录真机验证后入 `check_cmd_flex` 调用
  - 依赖：昇腾/Intel/寒武纪真机
  - 验收标准：非标准安装目录工具自动探测成功（不依赖 bashrc）

---

## 已完成（归档）

> 按版本倒序排列；同一主版本的多轮迭代合并为一条。

- v1.48.x — **全 GPU 厂商生态 + 质量工程**：多厂商适配器框架（v1.47.0：adapter_nvidia/amd/ascend/intel/国产×5/generic，统一 18 列 CSV 报告端零改动）；AMD OAM 模组识别（v1.48.0：x86_64_OAM 平台 + device ID 判定 + xGMI 拓扑）；报告解析回归测试体系（v1.48.3：10 指标组 vs 基线，抓出 29 处表格错位/AMD 多卡失真；`tools/agent/report_regression.sh` + 6 份真实样本基线）；OFED 冲突 ROCm 环境（amd-smi/rocm-smi bashrc 环境自动补加载，v1.48.14）；check_cmd_flex 通用工具检测（PATH → 候选目录试跑 → bashrc，v1.48.16）；WSL 实测修复（并行子进程函数继承 + nvidia-smi 兜底，v1.48.17）；regen_reports.sh agent 批量报告重生成（v1.48.18）；CUDA 行非 NVIDIA 平台隐藏（v1.48.19）；平台分类修复（Processing accelerators [1200] 类目码）+ GPU 型号规范化（lspci [营销名]）+ generic 额定显存兜底（v1.48.15）
- v1.46.x — **多厂商 GPU 检测 + 函数化 + 设备形态**：厂商无关 GPU 检测（v1.46.0：AMD/Intel 卡不再误报无 GPU，无 GPU 段隐藏）；AMD/ROCm 全链路（v1.46.1：rocm-smi/amd-smi 采集 + JSON 解析 + MI 系列显存规格库 + 魔改检测 + 验收适配）；detect_gpu_vendors/verify_gpu_mem 函数化单一实现 + 设备形态分类（v1.46.2：chassis/ECC/BMC/GPU 信号 → 笔记本~GB300 10 类）
- v1.45.x — **测试报告生成器 + 目录语义 + 报告完善 + 推送纪律**：`test/report.sh` 压测报告生成器（v1.45.0：STREAM 理论峰值 = 通道×速率×8B，利用率判定）；磁盘测默认屏蔽系统盘（v1.45.1）；logs/test/<SN>/ 稳定累积 + 采集默认覆盖 --stamp（v1.45.5-6）；DIMM 位宽列（v1.45.13：部件号推断 x4/x8 + 动态隐藏）；NIC PCIe 通路设计注（v1.45.14）；网卡 Link 状态列（v1.45.15）；整机温度 OS 侧 lm-sensors 兜底（v1.45.16）；git_push 防死循环三层防线（v1.45.8-10：4s 预检 + 熔断冷却 + [PAUSE] 纪律）
- v1.44.x — **报告数据完善**：PSU dmidecode Type39 独立源（无 FRU 平台出 PSU 明细）；PCIe 全链路表（3 态判定 + 附录）；NIC 端口列（BDF 聚合）+ GPU 直连列动态隐藏；nvidia-persistenced 临时开关围绕 DCGM（v1.44.2）；PCIe 链路判定修正（bridge 端口不判异常，端点才判）
- v1.43.1 — **Windows 工具编码修复**（真机测试暴露）：remote_run.ps1 补 UTF-8 BOM（write 工具重写剥 BOM，PS5.1 按 ANSI 读中文致语法崩）、remote_run.bat 转 CRLF（LF 行尾 cmd 解析含中文批处理崩溃）；AGENTS.md 记录 ps1/bat 编辑陷阱（改后必须 PS5.1 校验 + 补 BOM + bat 转 CRLF）
- v1.43.0 — **远程执行工具改名 + 扩展**：`tools/remote_batch.sh` → **`tools/remote_run.sh`**（批量运维 → 远程执行）；新增 `--script <本地脚本>`（推送+执行，化解 --push/-c 互斥）与 `--pull-logs <远端路径>`（tar-over-ssh 回拉过程日志到 `<outdir>/<host>_logs/`，复用 remote_collect 回拉范式）；输出目录默认 `run_output/`；Windows 对应 `tools/win/ssh_batch.ps1/.bat` → `remote_run.ps1/.bat`（去掉 BatchMode=yes 对齐交互密码立场；--script/--pull-logs Windows 二期）；全仓引用同步
- v1.42.0 — **远程采集 --install 扩展**（远程冷启动一条龙）：`remote_collect.sh --install <1,2,...>` 推送后先远端非交互装依赖（`install_tool.sh -c <列表> -y` 新增非交互参数，跳过菜单/确认）再采集；普通用户时安装+采集合并一条 `-t` 命令（同 tty sudo 密码只输一次），安装失败 `&&` 短路中止；`-c` 非法项快速失败；Windows `remote_collect.ps1 -InstallItems`（v1.42.1）
- v1.41.0 — **PCIe 拓扑与链路检查**（交付验收新维度，超微 H200 机头客户核对场景）：06_pcie 采 `lspci -vvv` 全量 pcie_full.log；报告新增「PCIe 拓扑与链路」段（PEX Fabric Switch 型号×数量枚举 + LnkCap/LnkSta 满速/降速检测）；验收扩至 **15 项**（PCIe 链路完整：PASS/WARN，空闲 Gen1 x16 与 x0 未连接端口不算降速；旧采集无 pcie_full 判 N/A 不计数）；**实测教训**：pcie_speed_width.log 是 grep 行流（缺 LnkCap 设备致 cap/sta 错配、x0 未连接端口），配对不可靠不可用于降速判定——全量 pcie_full 按设备块解析才可靠
- v1.40.x — **工具目录重组**：agent 协作工具独立 `tools/agent/`（git_push.sh/.bat、agent_sync.sh——agent 流程调用）；Launch-DeepSeekHarness 属用户手动启动归 `tools/win/`；git_push 推送成功自动刷新 AGENT_STATE.md（agent_sync --clear 补版本/提交行刷新）
- v1.39.x — **git_push WSL 全链路支持**（v1.39.1-4：WSL 下自动用 Windows git.exe 走 Windows 网络栈 + interop 探测 Windows 侧 v2ray 端口；WSL 访问 /mnt 盘项目时自动转交 `tools/agent/git_push.bat` 在 Windows 侧执行，WSLENV 传参 + no-pause）；`gpu_burn_test.sh` 独立脚本 + test_all 菜单第 8 项 + gpu_test 直接工具参数（v1.39.0/3）；gpu_burn 目录修复 + test_record 退出码修复（v1.38.5 并入）
- v1.38.x — **测试日志自包含机器身份**（test_server_info.sh：test_init 后自动写入 === Server Info === 段——机器 ID/型号/CPU/内存/GPU/OS，对标厂商 FLD 日志）；git_push 网络策略演进（直连优先 3 次 6s 快速失败、代理预检 curl 验证节点真连通、代理仅兜底）
- v1.37.x — **多机器/多 Agent 协作规则立规**（v1.37.2：agent_sync.sh 开工 fetch 同步 + 版本回退警告 + AGENT_STATE.md 本地状态文件；git_push 版本单调硬检查——本地 < 远程拒绝推送；AGENTS.md 协作规则节）；FLD 诊断日志引用段 `--fld-dir`（v1.37.0）
- v1.36.x — **风扇冗余采集 + 验收第 14 项**（11_fan 三态：Fan Redundancy/FAN Cable/Fan PG，sdr 主采 + sensor 兜底；无风扇平台 N/A 不计数，与电源冗余同判定模式）；GPU 压测逐卡矩阵（bandwidthTest_gpu0..N）；**git_push.sh 一键推送工具诞生**（v1.36.1：直连重试 → 代理动态端口探测 → [AI-ACTION] 指引，v1.36.2-7 迭代：-y 跳过确认、timeout、bat 启动器纯 ASCII、tasklist 管道过滤、默认 fetch + 逐提交摘要 + PUSH_STATUS 状态行 + 退出码 0/1/2）
- v1.35.x — **报告模块独立**（v1.35.0 report/ 拆分：薄入口 report.sh + lib/sections/gen/tools；v1.35.3 删 tools/ 兼容 exec 包装统一 report/ 路径）
- v1.34.x — **Windows 原生远程采集**（tools/win/remote_collect.ps1/.bat）+ 多轮修复；`cleanup.sh/.ps1` 清理工具；**ShellCheck 全量清理**（SC2045/SC2155 等 55 处，0 错误）；**文档大重构**（README 501→70 行精简，详细文档拆分至 docs/）；Linux remote_collect 拉取定位修复；**文档与实现一致性修复批次**（v1.34.30-33：--no-module→--skip、test 菜单式无时长参数、install_tool/install_ai 交互菜单、report_server 绑定 127.0.0.1、依赖归属修正、README 徽标精简等）
- v1.33.x — OS-BMC 一致性校验默认关闭（v1.33.0：`--bmc-verify` 显式开启，禁用时验收项 N/A 不计入数据不足，独立 hwscope_bmc_verify.md 报告）；时间戳统一连写复核 10 处 + README 示例同步（v1.33.1）；report_server 强制 `--bind 127.0.0.1` 防报告无鉴权暴露局域网 + 16_power 未知能量单位不猜测（Joules 变体 3.6Mx 误差）、remote_collect 回拉按目录名、power_monitor 间隔校验（v1.33.2）；**全量审查修复批次**（v1.33.3：NO_MODULE 导出、--modules/--skip/--output 参数校验、rm-rf 护栏、herestring 残留 8 处、08_storage && 链、RAID vd_count 行锚定、PSU 六字段重建、16_power 单位顺序/十六进制守卫、MEM_SLOTS 锚定、disk 寿命 N/A 不假 PASS、GPU 功耗/温度数值守卫、9× local-in-subshell、dhcp_server shift2/port0/原子写、net_dhcp 退出码回滚、SEL 翻转检测、nvlink_verify 不假绿、cable_map 确认+恢复 trap、install 确认+退出码、perftest 客户端 IP、测试加固）；perftest `-S` 误判回退（实为 --sl 服务等级）+ smartctl Transport protocol 值判定（v1.33.4）；awk 数值守卫先 trim 前导空格（nvidia-smi CSV ` 700.00 W` 全拒回归修复，v1.33.5）；验收 N/A 计数规则细化 + IB 线缆配对条件驱动（有链接无数据=采集缺口计入，未插线=平台形态不计）
- v1.32.0 — **全工具与测试脚本统一 `-h/--help`**（common.sh 内置 show_script_help，net_dhcp/sync_version/test_all 独立实现），新增 `tools/README.md` + `test/README.md` 文档（含写操作警告），README 链接同步
- v1.31.0 — **ROADMAP 剩余 5 项 P2 全部落地**：`tools/fw_baseline_import.sh` 固件基线自动导入（基准机采集目录/表格 → conf/fw_required.txt，--diff 预览/--apply 写入+自动 .bak）；`tools/power_monitor.sh` 能耗持续采样（后台 DCMI/Redfish → CSV，stop 输出小时/日聚合 + 梯形积分 kWh 核算，补 16_power 单点快照缺口）；`tools/report_server.sh` 报告在线预览（解包 logs/report/ → web/ 缓存 + 索引页 + python3 http.server，零新依赖）；`tools/remote_run.sh` SSH 远程执行（v1.43.0 由 remote_batch.sh 改名；-H 多机 + -c 命令/--push 推送，逐机 .out 落盘 + summary）；`tools/dhcp_server.sh` 扩展 `leases-export <csv>` 租约导出 + `reconcile <目录...>` 租约↔采集报告 BMC IP/MAC 交叉核对（上架清单差异表，`--lease-file` 自定义租约路径）
- v1.30.0 — **报告基线对比 `--baseline <历史目录>`**（时序差异：BIOS/CPU/内存/GPU数/VBIOS/BMC固件 标量变化 + GPU/盘/网卡 SN 集合新增移除 + 固件版本逐项旧→新变化；JSON/MD/TXT/HTML 同步）；**验收清单扩至 13 项**（新增 固件版本合规：落后=FAIL、无基线判未知=N/A 不误报；OS-BMC 口径一致：不一致=FAIL、仅单侧数据=WARN、**无 BMC 机器判 N/A 不计入数据不足**——IPMI 日志全错误=平台无 BMC 属固有形态，无任何 IPMI 日志=工具缺失如实计入）
- v1.29.0 — **ROADMAP 全部原待办落地**：采集层新增 `15_firmware` 固件合规模块（对照 conf/fw_required.txt 判 合规/落后/未知，无基线判未知不 WARN）、`16_power` 能耗台账模块（Energy/kWh 累计读数 + DCMI/Redfish 功耗，单点快照核算）；报告层新增固件合规段、能耗台账段、BMC 数据一致性校验段（OS dmidecode/可见内存 vs BMC FRU/Redfish，零新采集，不一致 WARN 并排显示两边值）、压测归档 `--test-dir`（test_common.sh 写 manifest → report.sh 读 manifest 解耦）；新工具 `tools/batch_compare.sh` 多机横向对比（读各机 JSON，差异 ⚠️ 标注）、`tools/remote_collect.sh` SSH 远程采集（tar 暂存模式：流式 bash -s 无法满足多文件 source 结构，改为临时推送→执行→回拉→清理，密码不落盘）、`tools/dhcp_server.sh` dnsmasq 封装（安装/配置/启停/租约查询）
- v1.28.x — GPU 每卡明细 VBIOS 列（去瞬时利用率）、nvidia-smi nvswitch 子命令采集与报告解析（无 CLI 平台兜底）、topo_nic cp 顺序修复、cable_map 中断恢复 trap；验收清单扩至 11 项（VBIOS 一致性/电源冗余/SMART 健康/温度汇总/IB 链路状态）、无 GPU 机头 N/A 不参与数据不足判定、RAID 虚拟盘独立表格、PSU type39 补 PN/容量、Fabric Switch 仅机头显示、动态列隐藏（全占位列隐藏）；JSON nics 空读修复（awk 管道）、ipmitool -E 环境密码、rm -rf 护栏、write_manifest --append、sync_version 同步头注释、MODULE_TIMEOUT 可配置；**HTML 报告第四产物**（md2html.awk 专业样式）、GPU 标称内存库+修改卡检测、验收清单 HTML+硬件配置概览、术语 标称→额定、时间戳统一 YYYYMMDDHHMMSS、RAID/HBA 检测修复、Linux mdadm 软 RAID 识别
- v1.27.x — HGX 机头平台分类（x86_64_head：PCIe Gen5 Fabric Switch 检测）、机头报告专属文案（GPU/DCGM/验收 N/A 语义）、Fabric Switch 主板段展示、DCMI/整机功耗独立展示、MD 表格空行修复
- v1.26.x — **验收清单模式**（v1.26.0：`report.sh --acceptance` 生成 8 项 PASS/FAIL/WARN 判定交接单）；HBA 直通卡章节、N/A 隐藏、MST/DCGM hostengine 自拉起、模块并行超时保护、ib_test.sh IB 打流、RAID 虚拟盘/HBA SAS 明细、PSU DCMI/PMBus 采集、USB NIC 分类、BlueField DPU 标签、NIC chip 列、dmidecode 补全（cache/TPM/type39）、盘标称容量自动提取、验收清单假阳性防护（SEL/磁盘/内存 N/A）、模块超时 WARN 补记
- v1.25.x — 报告术语表、GPU直连标记、规格 vs 实测区分、全量采集原则
- v1.24.0 — EDAC 内存错误采集、DIMM Rank/内存类型入报告
- v1.23.x — 9 张明细表、sync_version.sh 单点版本号、locale 兜底、真 SN 采集

---

*最近更新: 2026-09-05 · 版本: v1.48.45*
