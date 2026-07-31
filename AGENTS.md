# AGENTS.md — HwScope 项目指南

HwScope (Hardware Scope) — 服务器硬件一键巡检采集系统。逐件、逐槽、逐端口采集物理组件信息，每命令一个日志。

## 项目概述

- Shell (bash) 编写的硬件巡检工具，Apache 2.0
- 支持 x86/ARM，SXM/PCIe/传统服务器自动识别
- 目标用户：AI 基础设施工程师（HGX B200/B300、GB300、IB 网络）
- 仓库: https://github.com/YanHuiStar/hwscope

## 目录结构

- `hwscope.sh` — 主入口：参数解析、平台检测、串行/并行执行、汇总、归档
- `lib/common.sh` — 公共函数：run_and_log / check_cmd / module_start / WARN 计数
- `modules/*.sh` — 15 个采集模块（01_motherboard … 99_os），每个一物理组件
- `conf/hwscope.conf` — 模块开关、BMC 凭据、输出目录配置
- `test/` — 硬件压测脚本（cpu/memory/disk/network），只测不改
- `tools/` — 运维操作脚本（BMC/网卡/安装），会修改系统
- `fixcrlf.sh` — Windows→Linux CRLF 换行符修复
- `output/` — 采集结果（gitignored），`logs/` — 压缩归档（gitignored）

## 常用命令

- 全量采集: `sudo bash hwscope.sh` / 并行: `sudo bash hwscope.sh --parallel`
- 只采部分: `sudo bash hwscope.sh --modules gpu,cpu`
- 跳光模块: `sudo bash hwscope.sh --no-module`
- 单模块: `bash modules/04_gpu.sh /path/output`
- CRLF 修复: `bash fixcrlf.sh`
- 语法检查: `bash -n <script.sh>`

## Git 提交规范

提交信息格式: `<type>: <摘要>`，摘要用英文，动词开头，一句话说清改动。

| type | 用途 | 示例 |
|------|------|------|
| `feat` | 新功能/新模块 | `feat: add memory_test.sh` |
| `fix` | Bug 修复 | `fix: platform detection fallback to lspci` |
| `docs` | 文档 | `docs: update README quick start` |
| `refactor` | 重构（行为不变） | `refactor: rename fix.sh to fixcrlf.sh` |
| `perf` | 性能优化 | `perf: skip module queries with --no-module` |
| `release` | 版本发布 | `release: v1.2.0 — add test/tools modules` |

规则：
- **改动完成立即 `git commit` 到本地**，不等待、不批量攒
- **不主动 `git push`** — 只有用户明确说"提交到远程/推送"才 push
- 版本升级与功能改动分开 commit（release 单独一条）
- CRLF 等纯换行修复：`refactor` 或并入同主题 commit

## 新增模块流程

1. 创建 `modules/<NN>_<name>.sh`，定义 `run_<name>()` 函数
2. 加入 `hwscope.sh` 的 MODULES 注册表 + MODULE_SWITCH 开关
3. `conf/hwscope.conf` 加对应开关变量
4. 所有采集命令必须走 `run_and_log "cmd" "path.log"`（自动记录命令+退出码）
5. 工具不存在用 `check_cmd` 检测后 `[SKIP]`，不中断
6. 版本号：主=输出不兼容，中=新模块/新功能，补=修复/文档

## 设计约束（勿违反）

- 只读无害：采集命令不写硬件、不改配置；DCGM 仅 Level 1 纯获取，无 GPU 压测负载
- 模块零耦合：每模块可独立执行，不依赖其他模块
- 不用 eval（已踩坑：awk 变量展开 bug，统一用 bash -c）
- locale 切换仅进程内，不修改系统环境
- 输出目录按 SN 命名，多机隔离；WARN 计数进 summary.txt

## 验证方式

- WSL 或真机运行 `sudo bash hwscope.sh`，检查 exit=0、日志生成
- 模块单独跑: `bash modules/04_gpu.sh /tmp/out`，对比日志完整性
- 平台检测验证: `bash hwscope.sh | grep Platform`，应为 xx_SXM/xx_PCIe/xx_none
- 变更后跑 `bash -n` 全量语法校验

## 常见陷阱

- **CRLF**: 从 Windows 拷贝后所有 .sh 会带 \r，bash 报 $'\r' 错误 → 先跑 fixcrlf.sh
- **grep exit=1** = 无匹配，不是错误（终端显示 [~]，不记 WARN）
- **locale**: 非 UTF-8 环境脚本自动尝试切换，日志头记录实际编码
- 并行模式模块输出走临时文件，完成后按注册表顺序拼接，勿直接写共享日志
