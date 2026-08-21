# HwScope 运维工具库（tools/）

> 服务器运维操作脚本。**部分脚本会修改系统配置，使用前请先阅读本节标注的 ⚠️ 写入类**。
> 所有脚本均支持 `-h` / `--help` 查看详细帮助；工具定位：运维机/服务器侧操作，不参与采集。
> 工具概览索引见 [docs/TOOLS.md](../docs/TOOLS.md)（本文件为详细说明）；Windows 配套工具见 [docs/WIN_TOOLS.md](../docs/WIN_TOOLS.md)。

## 分类速查

| 类别 | 脚本 | 危险度 |
|------|------|--------|
| **诊断/只读** | nvlink_verify · firmware_check · sel_monitor · cable_map · report · sync_version · batch_compare · power_monitor · report_server · cleanup | 🟢 只读（cleanup 删除输出目录，yes 确认） |
| **写入操作** | bmc_tool · nic_tool · net_dhcp · dhcp_server · install_tool · install_ai · remote_batch · fw_baseline_import | 🔴 会改系统 |
| **远程采集** | remote_collect | 🟡 仅远程执行采集（只读）|

---

## 🟢 诊断 / 只读类

### `report.sh` — 报告生成器（核心）
- **用法**：`bash tools/report.sh <output_dir> [--acceptance] [--baseline <历史目录>] [--test-dir <压测目录>]`
- **功能**：从采集日志生成 4 产物（`hwscope_report.{json,md,txt,html}`）+ 验收清单 `hwscope_acceptance.{md,html}`（13 项判定）；`--baseline` 与历史报告做时序差异对比
- **原则**：只读日志、不重新采集，可对同一份数据反复生成
- **依赖**：awk（HTML 转换）、无外部工具

### `nvlink_verify.sh` — NVLink 完整性校验（实时）
- **用法**：`bash tools/nvlink_verify.sh`
- **功能**：实时解析 `nvidia-smi topo -m` 找非 NVLink 降级链路 + `nvlink --status` CRC 错误/链路 down 检测，输出健康结论（与报告共用 lib/nvlink.sh 解析逻辑）
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
- **功能**：BDF↔mlx5↔netdev 映射 + EEPROM serial 配对（serial 相同=同一根线）；DAC 无 serial 时自动**断口联动验证**（⚠️ 会逐个 down 端口再恢复，约 3-5s/口，Ctrl+C 自动恢复）
- **依赖**：mlxlink（MFT）

### `batch_compare.sh` — 多机横向对比
- **用法**：`bash tools/batch_compare.sh <机器A报告目录> <机器B报告目录> ...`
- **功能**：读各机 `hwscope_report.json`，同字段对比（固件/内存速率/盘型号/GPU 配置），差异 ⚠️ 标注；批量交付一致性抽检

### `power_monitor.sh` — 连续功耗采样
- **用法**：`sudo bash tools/power_monitor.sh [采样秒数] [间隔秒]`
- **功能**：BMC 功耗连续采样（当前/最小/最大/平均）+ 累计 kWh 核算
- **依赖**：ipmitool（DCMI）/ Redfish

### `report_server.sh` — 报告 Web 预览
- **用法**：`bash tools/report_server.sh [端口]`，浏览器打开 `http://127.0.0.1:<端口>`
- **功能**：本地起 Web 服务浏览各机器报告（交付演示/内部共享）；**固定绑定 127.0.0.1**（防含 SN/MAC 的报告无鉴权暴露局域网）

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

### `cleanup.sh` — 清理采集输出
- **用法**：`bash tools/cleanup.sh`（输入 yes 确认）；`--force` 跳过确认
- **功能**：删除 `output/` 与 `logs/`（显示各目录大小/文件数后确认），不碰源码
- **依赖**：无（Windows 版 `tools/win/cleanup.bat`）

---

## 其他

- `md2html.awk` — Markdown→HTML 转换器（report.sh 内部调用）：`awk -f tools/md2html.awk 报告.md > 报告.html`
- `fixcrlf.sh`（项目根）— Windows→Linux CRLF 换行修复：`bash fixcrlf.sh`
- Windows 配套工具见 `tools/win/`（PowerShell 运维工具，笔记本侧使用）
