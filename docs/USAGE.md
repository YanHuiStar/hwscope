# 使用指南（Usage）

> [← 返回 README](../README.md) · 快速上手见 [QUICKSTART.md](QUICKSTART.md) · 报告与验收体系见 [REPORT.md](REPORT.md)

## 采集

```bash
sudo bash hwscope.sh                          # 全量采集（双层并行）
sudo bash hwscope.sh --serial                 # 串行（低负载）
sudo bash hwscope.sh --force                  # 输出目录已存在时强制重采（否则报错退出）
sudo bash hwscope.sh --quiet                  # 静默模式（不打印模块明细）
sudo bash hwscope.sh --no-parallel            # 禁模块内并行（低负载）
sudo bash hwscope.sh --module-timeout 120     # 模块超时秒数（默认 300）
sudo bash hwscope.sh --modules gpu,cpu        # 只采部分模块
sudo bash hwscope.sh --skip gpu,fan           # 跳过指定模块
sudo bash hwscope.sh --output /data/collect   # 指定输出目录
bash modules/04_gpu.sh /path/output           # 单模块（调试）
```

输出结构：`output/<机器ID>/` 下按模块分目录（bmc/cpu/gpu/...），每命令一个日志 + 报告文件。

## 报告生成

> 报告体系为独立 `report/` 模块（v1.35.0）：主入口 `report/report.sh`；旧路径 `tools/report.sh` 为兼容 wrapper。

```bash
bash report/report.sh <采集目录>                          # json/md/txt/html 四件套
bash report/report.sh <采集目录> --acceptance             # 验收清单 md/html（13 项判定）
bash report/report.sh <采集目录> --baseline <历史目录>     # 时序差异对比
bash report/report.sh <采集目录> --test-dir <压测目录>     # 关联压测归档
bash report/report.sh <采集目录> --bmc-verify             # 开启 OS-BMC 一致性交叉核验
bash report/report.sh <采集目录> --json                   # 仅生成 json（也可 --md/--txt/--both）
```

报告**只读日志、不重新采集**，可反复生成；日志缺失字段显示 N/A。

## 远程采集与多机对比

### 远程采集（Linux/WSL）

```bash
bash tools/remote_collect.sh -H root@10.0.0.1                 # 全量采集并回拉
bash tools/remote_collect.sh -H root@10.0.0.1 --modules gpu   # 只采部分
bash tools/remote_collect.sh -H user@host --no-sudo           # 普通用户直接执行
```

- 流程：tar 临时推送项目 → 远端执行 hwscope → 回拉 → 清理（远端零持久占用）
- 认证：默认交互式密码（不落盘）+ ControlMaster 复用（输一次密码）；root 免 sudo，普通用户自动 `-t` 供 sudo 交互
- 结果：`output/remote_output/<机器ID>/`；归档包 → `logs/remote_logs/`

### 远程采集（Windows 运维机）

```powershell
tools\win\remote_collect.bat -H root@10.0.0.1
tools\win\remote_collect.ps1 -H root@10.0.0.1 -Modules gpu,cpu -OutDir D:\hwout
```

- 依赖：Windows 自带 OpenSSH 客户端 + tar（零新依赖）
- 认证：交互式密码，每步失败自动重试 3 次（Windows OpenSSH 不支持 ControlMaster，共 3 次密码输入）

### 多机对比 / 批量运维

```bash
bash report/tools/batch_compare.sh <目录1> <目录2> ...   # 多机横向对比（差异 ⚠️ 标注；输出 logs/batch_compare/，-o 自定义；旧路径 tools/batch_compare.sh 兼容）
bash tools/remote_batch.sh -H "root@10.0.0.1 root@10.0.0.2" -c 'nvidia-smi -L'  # 批量命令
```

## 运维工具

### 固件基线管理

```bash
bash tools/fw_baseline_import.sh <基准机采集目录> --diff   # 预览基线差异
bash tools/fw_baseline_import.sh <基准机采集目录> --apply  # 写入 conf/fw_required.txt
```

### 能耗持续采样

```bash
bash tools/power_monitor.sh start [--interval 60] [--duration 0]   # 后台采样（DCMI 优先/Redfish 兜底）
bash tools/power_monitor.sh status                                  # 查看采样状态
bash tools/power_monitor.sh stop                                    # 停止并输出聚合 + kWh 核算
```

### 报告在线预览

```bash
bash report/tools/report_server.sh          # 解包 logs/report/ → 本地预览（绑定 127.0.0.1；旧路径 tools/report_server.sh 兼容）
```

### 网卡 / 线缆 / BMC 运维

```bash
bash tools/nic_tool.sh               # 网卡信息/固件管理（Mellanox）
bash tools/cable_map.sh              # IB 线缆拓扑（自动发现物理连线）
bash tools/bmc_tool.sh               # BMC 凭据/密码管理
```

### DHCP（新上架服务器批量发 IP）

```bash
sudo bash tools/dhcp_server.sh install            # 安装 dnsmasq
sudo bash tools/dhcp_server.sh config             # 配置网段（默认 192.168.50.0/24 .100-.200）
sudo bash tools/dhcp_server.sh start              # 启动 DHCP 服务（需先 config）
sudo bash tools/dhcp_server.sh leases-export <csv>  # 租约导出
sudo bash tools/dhcp_server.sh reconcile <目录...>  # 租约 ↔ 采集台账交叉核对
```

### AI 推理引擎安装

```bash
bash tools/install_ai.sh          # 交互菜单选择引擎：vLLM / SGLang / TRT-LLM / Ollama / llama.cpp
```

## 硬件压测（只读，不修改硬件配置）

```bash
bash test/test_all.sh          # 菜单式入口（推荐，选测/全测）
bash test/cpu_test.sh          # CPU 稳定性（菜单选择 stress-ng/sysbench/mprime）
bash test/memory_test.sh       # 内存压力（stress-ng/memtester/sysbench）
sudo bash test/disk_test.sh    # 磁盘读写（fio/hdparm/dd，选盘后测试，需 sudo）
bash test/network_test.sh      # 网络吞吐（iperf3，运行时提示输入服务端地址）
sudo bash test/ib_test.sh      # IB 链路（perftest 自动配对打流，需 sudo）
bash test/gpu_test.sh          # GPU 压力（自动发现已装测试程序）
bash test/nccl_test.sh         # NCCL 集合通信
```

每个脚本进入后按菜单选择测试项；`-h`/`--help` 查看用法。结果落盘 `logs/test/<时间戳>/`。
