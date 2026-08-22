# HwScope 运维工具库（tools/）

> 服务器运维操作脚本。**部分脚本会修改系统配置，使用前请先阅读本节标注的 ⚠️ 写入类**。
> 所有脚本均支持 `-h` / `--help` 查看详细帮助；工具定位：运维机/服务器侧操作，不参与采集。
> 工具概览索引见 [docs/TOOLS.md](../docs/TOOLS.md)（本文件为详细说明）；Windows 配套工具见 [docs/WIN_TOOLS.md](../docs/WIN_TOOLS.md)。
> **报告体系已独立为 `report/` 模块**（v1.35.0）：报告生成/验收清单/在线预览/多机对比迁移至 `report/`（详见 [report/README](../report/README.md)）；`tools/` 下不再保留同名文件（v1.35.3 移除兼容 wrapper，统一 `report/` 路径）。

## 分类速查

| 类别 | 脚本 | 危险度 |
|------|------|--------|
| **诊断/只读** | nvlink_verify · firmware_check · sel_monitor · cable_map · sync_version · power_monitor · cleanup | 🟢 只读（cleanup 删除输出目录，yes 确认） |
| **写入操作** | bmc_tool · nic_tool · net_dhcp · dhcp_server · install_tool · install_ai · remote_batch · fw_baseline_import | 🔴 会改系统 |
| **远程采集** | remote_collect | 🟡 仅远程执行采集（只读）|
| **Agent 协作** | agent_sync · git_push | 🟢 只读（git_push 仅推送） |
| **报告体系** | → `report/` 模块（report.sh · batch_compare.sh · report_server.sh · md2html.awk） | 🟢 只读 |

---

## 🟢 诊断 / 只读类

> 报告生成（report.sh）、多机对比（batch_compare.sh）、在线预览（report_server.sh）位于 **`report/` 模块**（v1.35.3 起 `tools/` 下无同名文件），详见 [report/README](../report/README.md) 与 [docs/REPORT.md](../docs/REPORT.md)。

### `nvlink_verify.sh` — NVLink 完整性校验（实时）
- **用法**：`bash tools/nvlink_verify.sh`
- **功能**：实时解析 `nvidia-smi topo -m` 找非 NVLink 降级链路 + `nvidia-smi nvlink --status` CRC 错误/链路 down 检测，输出健康结论（与报告共用 lib/nvlink.sh 解析逻辑）
- **依赖**：nvidia-smi

### `firmware_check.sh` — 固件版本核对
- **用法**：`sudo bash tools/firmware_check.sh [--save-baseline] [--diff]`
- **功能**：GPU VBIOS / BMC FW / NIC FW（CX5-CX8）/ NVSwitch FW 一键汇总；`--save-baseline` 存基线（验收时用），`--diff` 对比基线差异
- **输出**：`logs/fw_check/`

### `sel_monitor.sh` — SEL 事件增量巡检
- **用法**：`sudo bash tools/sel_monitor.sh [--reset]`
- **功能**：记录 SEL 基线，后续运行只报告**新增**事件（按 ID 单调递增判定，比整行匹配可靠）；严重事件/PCIe 事件高亮分类
- **输出**：`logs/sel_monitor/`

### `cable_map.sh` — 线缆拓扑图（对线神器）
- **用法**：`sudo bash tools/cable_map.sh`
- **功能**：BDF↔mlx5↔netdev 映射 + EEPROM serial 配对（serial 相同=同一根线）；DAC 无 serial 时**确认后断口联动验证**（⚠️ 会逐个 down 端口再恢复，约 3-5s/口，Ctrl+C 自动恢复）
- **依赖**：mlxlink（MFT）

### `sync_version.sh` — 版本号同步
- **用法**：`bash tools/sync_version.sh`
- **功能**：从 `hwscope.sh` 的 `HWSCOPE_VERSION`（唯一权威源）同步头部注释 + README 徽章；自动备份回滚

---

## 🔴 写入操作类（⚠️ 会修改系统，均有确认提示）

| 脚本 | 用法 | 功能 | 修改内容 |
|------|------|------|---------|
| `bmc_tool.sh` | `sudo bash tools/bmc_tool.sh` | BMC 运维菜单：FRU/传感器/SEL 查看、SEL 清空、BMC 重启、改密码 | BMC（写入项有二次确认）|
| `nic_tool.sh` | `sudo bash tools/nic_tool.sh` | 网卡运维菜单：状态/光模块/固件查询、端口复位、MTU、**IB↔ETH 模式切换** | 网卡配置 |
| `net_dhcp.sh` | `sudo bash tools/net_dhcp.sh` | 一键配置网口 DHCP（Ubuntu netplan，自动识别插线网口、备份回滚） | /etc/netplan |
| `dhcp_server.sh` | `sudo bash tools/dhcp_server.sh` | DHCP 服务器（dnsmasq 封装）：安装/配置网段/启停/租约查询导出 | dnsmasq 配置 |
| `install_tool.sh` | `sudo bash tools/install_tool.sh` | 安装采集/压测/IB 诊断依赖（1-3 真装）、DCGM/MFT/推理指引（4-6）；**7-9 实验自动安装默认注释态**（真机验证后取消注释启用）| 系统软件包 |
| `install_ai.sh` | `sudo bash tools/install_ai.sh` | AI 推理环境安装（vLLM/SGLang/TRT-LLM/Ollama/llama.cpp） | Docker/系统 |
| `remote_batch.sh` | `bash tools/remote_batch.sh` | 多机批量 SSH 运维（命令/采集/回拉）| 远程主机 |
| `fw_baseline_import.sh` | `bash tools/fw_baseline_import.sh` | 固件基线自动导入（firmware_check 基线管理）| 基线文件 |

---

## 🟡 远程采集

### `remote_collect.sh` — SSH 远程采集
- **用法**：`bash tools/remote_collect.sh -H user@host [hwscope 参数...]`
- **功能**：从运维机 SSH 到目标机执行完整采集（tar 推送→执行→结果回拉→清理），无需登录服务器手动跑
- **凭据**：交互式密码默认（SSH ControlMaster 复用，输一次密码）；root 免 sudo，普通用户自动 `-t` 供 sudo 交互；SSH key 仅限可信内网。密码不落盘
- **输出**：本地 `output/remote_output/<机器ID>/`（对标本地 output/<SN> 结构）；归档包 → `logs/remote_logs/`

### `git_push.sh` — 一键推送更新（开发维护工具，AI agent 可用）
- **用法**：`bash tools/git_push.sh`（默认 fetch + 逐提交改动摘要审查，交互确认）；`-y` 跳过确认；`--no-fetch` 跳过前置 fetch；`--dry-run` 只审查；`-q/--quiet` 机器可读模式
- **功能**：默认先 fetch 检测其他 agent 是否已推送（防推旧）→ 展示每个待推提交的改动摘要 → **版本单调检查**（本地版本 < 远程版本拒绝推送，防凭记忆回退版本号，v1.37.2）→ 直连重试 3 次 → 自动探测本机代理（v2ray/xray/clash 进程动态端口，一次性走代理）→ 失败输出 `[AI-ACTION]` 指引
- **AI 接口**：末尾输出 `PUSH_STATUS=OK|FAIL|USER_ABORT|NOOP|DRY_RUN` 状态行；退出码 0=成功 1=失败 2=用户取消
- **依赖**：git + 可选代理（本机代理客户端，端口自动探测）；Windows 版启动器 `tools/win/git_push.bat`（双击可用）

### `agent_sync.sh` — 多机器/多 Agent 状态同步检查（v1.37.2）
- **用法**：`bash tools/agent_sync.sh`（开工检查：fetch + 远程/本地 HEAD、版本、未推送数、版本对比；自动刷新本地状态文件）；`--mark` 提交后标记未推送；`--clear` 推送成功后清空；`--help`
- **功能**：任何机器/会话**开工第一步**跑本脚本——以远程 origin/main 为真相同步认知（fetch），显示版本对比，防止凭记忆乱改版本号/乱推送；跨机器状态以远程为准，本地 `AGENT_STATE.md`（gitignore）仅协调单机多会话"进行中/未推送"
- **依赖**：git（排序用 sort -V）；协作规则见 AGENTS.md"多机器/多 Agent 协作规则"

### `cleanup.sh` — 清理采集输出
- **用法**：`bash tools/cleanup.sh`（输入 yes 确认）；`--force` 跳过确认
- **功能**：删除 `output/` 与 `logs/`（显示各目录大小/文件数后确认），不碰源码
- **依赖**：无（Windows 版 `tools/win/cleanup.bat`）

---

## 其他

- `md2html.awk` — Markdown→HTML 转换器（报告 HTML 件用，已迁至 `report/lib/md2html.awk`）：`awk -f report/lib/md2html.awk 报告.md > 报告.html`
- `fixcrlf.sh`（项目根）— Windows→Linux CRLF 换行修复：`bash fixcrlf.sh`
- Windows 配套工具见 `tools/win/`（PowerShell 运维工具，笔记本侧使用）
