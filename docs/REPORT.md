# 报告与验收体系

> [← 返回 README](../README.md) · 使用入口见 [QUICKSTART.md](QUICKSTART.md) / [USAGE.md](USAGE.md)
>
> 报告是 HwScope 的交付物本体，实现为独立模块 `report/`：入口 `report/report.sh`，目录划分与装配方式见 [report/README](../report/README.md)。报告只读解析采集日志，不重新采集，可对同一份采集目录反复生成。

## 1. 报告四件套

对采集目录生成以下四个文件（默认一次全出；`--json` / `--md` / `--txt` / `--both` 可限定格式，其中 `--md` 会同时生成 HTML）：

| 文件 | 内容 | 用途 |
|------|------|------|
| `hwscope_report.json` | 结构化数据，保留全部字段（不随展示裁剪） | 程序消费、批量对比、归档 |
| `hwscope_report.md` | 完整报告，含全部明细表与附录 | 归档、评审、变更记录 |
| `hwscope_report.txt` | 纯文本版，字段按标签对齐 | 终端查看、邮件正文 |
| `hwscope_report.html` | 卡片分区、状态着色、侧栏目录、打印友好，零外部依赖 | 浏览器交付、交接 |

验收清单（`hwscope_acceptance.{md,html}`）是**独立分支**，需另以 `--acceptance` 生成，详见 §7。

### 1.1 HTML 版式

- **响应式断点**：≥1201 px 侧栏（130 px）与正文并排；≤1200 px 侧栏收窄至 120 px；≤1024 px 侧栏转为**顶部横向吸附条**（导航不再消失），并相应加大锚点留白（130 px，避免目标标题被吸附条遮挡）；≤760 px 收紧内边距与表格字号。
- **表格适配**：≤5 列窄表在容器宽度内自动换行，序号列与状态列不换行；≥6 列宽表放入 `.tw` 容器，并在 ≤1400 px 断点启用**横向滚动**（列宽保持自然，不使用 `table{display:block}` 压缩布局）；宽屏下容器可容纳，不触发滚动。
- **侧栏目录**：由 `##` 章节自动生成，使用统一短名（最长 4 字），`PCIe 链路明细（附录）` 之前插入附录分隔；完整标题见悬停 `title`。已映射的短名包括：`链路`（PCIe 拓扑与链路）、`链路明细`（PCIe 链路明细（附录））、`板载`（板载与外部接口）、`电源`（电源 PSU）、`RAID`（RAID 控制器）、`交换域`（NVSwitch 域（Fabric））、`HBA 明细`（主机总线适配器明细（HBA））。验收清单的短名为 `硬件概览` / `验收信息` / `验收项目` / `验收结论`。
- **锚点跳转**：章节 `id` 挂在 `section` 上，配合 `scroll-margin-top`，跳转后卡片停在距视口顶部 16 px。
- **打印 / PDF 版式**：`@page` 设为 **A4**；打印时隐藏侧栏与「↑ 顶部」按钮，复位屏幕态的侧栏让位与窄屏补偿；卡片改用 `#a0aec0` 实线边框，表头深色底以 `print-color-adjust: exact` 强制输出，表格复位为 `display: table`，卡片与表格行防跨页断开。上述规则**仅作用于 Ctrl+P / 打印预览**，不影响屏幕显示，也不改动 MD/JSON/TXT 内容。
- **不提供 `--pdf` 自动生成**：HTML 转 PDF 受卡片防跨页约束，长报告分页不连贯，暂不实现；需要 PDF 时由浏览器打印生成。

## 2. 章节结构

Markdown 报告的章节顺序如下（`##` 级标题即 HTML 卡片与侧栏目录项）：

| 章节 | 主要内容 | 出现条件 |
|------|---------|---------|
| 环境 | 设备形态、OS、内核、驱动、CUDA、Compute Mode、ECC Mode、采集耗时 | 始终 |

> **判定依据**：设备形态由 `classify_machine` 综合 chassis 类型、内存 ECC、BMC 是否存在、加速卡数量与模组形态判定。模组形态（`_SXM` / `_OAM`）或加速卡 ≥4 张属强信号，先于 chassis 与 BMC 生效——因此采集环境缺 `ipmitool`、或 BIOS 把 Chassis Type 填成 `Other` 时，不会把 GPU 服务器降级判成工作站；证据不足时该行末会附「判定依据不足：…」，说明结论主要由哪条信号得出。
| 主板 | 制造商、型号、BIOS、SN、主板 SN、机箱 SN、PCIe Fabric Switch | 始终（Fabric Switch 仅无本地 GPU 时展示） |
| PCIe 拓扑与链路 | Fabric Switch 型号与端口数、链路统计、降速/降宽异常表 | 始终（无 `pcie_full` 数据时给 N/A 说明） |
| CPU | 型号、插槽数、核心数、Stepping、频率、频率策略、处理器明细 | 始终 |
| 内存 | 总量、插槽（已插/总数）、类型、速率、DIMM 明细 | 始终 |
| GPU | 数量、型号、显存总量、额定功耗、功耗上限、VBIOS、ECC/RAS、退役行、温度、NVLink、xGMI、XID | 有 GPU 数据或有 GPU PCI 存在性 |
| NVSwitch | 逐颗状态、温度、活动/总端口 | 有 NVSwitch 数据 |
| NVSwitch 域（Fabric） | Fabric Manager 域配置与状态；机头形态说明「平台固有」 | 有 Fabric Manager / NVSwitch 数据（AMD、昇腾等平台无此数据） |
| 存储 | 盘数、总容量、盘型号、系统盘、盘明细、RAID 虚拟盘明细 | 始终 |
| RAID 控制器 | 控制器、型号、SN、固件、虚拟盘；软 RAID 明细；降级说明 | 有 RAID 卡、软 RAID 或 VMD |
| 主机总线适配器明细（HBA） | 控制器、型号、固件、SN、状态、SAS 地址、端口 | 有 HBA 数据 |
| 网络 | 端口总览、协议分布、速率、计算网卡、SR-IOV、线缆、卡级与端口级明细 | 始终（明细随数据裁剪） |
| BMC | 型号、固件、Redfish 固件明细、IP（含来源）、MAC、SEL 事件与告警明细 | 始终 |
| 板载与外部接口 | VGA / USB 控制器 / 板载网口 / BMC 管理口、USB 已接设备 | 始终（表体随接口数据） |
| 风扇 | 数量、转速、温度、数据来源、冗余、风扇明细 | 始终（无数据时给采集说明） |
| 电源 PSU | PSU 明细、电源冗余、在位/槽位、功耗读数 | 始终 |
| 能耗台账 | 当前/最小/最大/平均功耗、累计能耗与来源 | 有功耗数据 |
| 固件合规 | 组件、设备、当前版本、推荐版本、状态、说明 | `conf/fw_required.txt` 已录基线 |
| 健康检查 | 见 §5 | 始终 |
| 压测归档 | 测试项、结果、耗时、详情文件 | 指定 `--test-dir` |
| FLD 诊断参考 | 见 §9 | 指定 `--fld-dir` |
| 基线对比 | 项、状态、当前、基线 | 指定 `--baseline` |
| PCIe 链路明细（附录） | 全量链路：BDF、设备、LnkCap、LnkSta、判定 | 有全量链路数据 |
| 术语说明 | 术语表、网卡 MT 编号对照 | 始终 |

字段顺序（近期调整，便于交付核对时按固定位置取值）：

- **环境**：`设备形态` 置首行，其后为 OS、内核、驱动。
- **主板**：`BIOS` 前置于 `SN`、`主板 SN`、`机箱 SN`。
- **CPU**：`插槽数` 紧随 `型号`。
- **内存**：`总量` → `插槽` → `类型` → `速率`。
- **GPU**：`数量` → `型号` → `显存总量` → `额定功耗` → `功耗上限`（仅检出时）→ `VBIOS` → `ECC`/`RAS` → `退役行` → `温度` → `NVLink` → `xGMI` → `XID`。

## 3. 明细表与字段口径

### 3.1 明细表清单

| 表 | 位置 | 口径要点 |
|----|------|---------|
| 内存模块明细（DIMM） | 内存 | 每槽一行（插槽、容量、厂商、SN、部件号、额定/当前速率、Rank、位宽）；空槽同样列出，容量列显示 `空槽` |
| 处理器明细（CPU） | CPU | 每颗一行；末列 `标识（DMI）` |
| 图形处理器明细（GPU） | GPU | 每卡一行；显存与功耗按「检测/额定」双值；含 BDF、设备 ID、VBIOS、Inforom |
| 存储盘明细 | 存储 | 每盘一行；寿命%、额定、健康为动态列 |
| RAID 虚拟盘明细（VD） | 存储 | 虚拟盘级（设备、RAID 卡、容量、SN/LUN） |
| 软 RAID 明细（mdadm） | RAID 控制器 | 设备、级别、状态、成员盘、阵列健康、容量、条带 |
| 网络适配器明细（卡级） | 网络 | 每张卡一行：型号、口数、BDF、芯片、固件、PSID、物理位置 |
| 网络适配器明细（NIC） | 网络 | 每端口一行：接口、BDF、端口序号、MAC、SN、型号、芯片、固件、PCIe(协商)、PSID、Link 状态、物理位置 |
| IB 链路质量（每 CA） | 网络 | 逐 CA 的 Raw Physical BER；只呈现数值，不设阈值、不进验收 |
| 端口模式（每端口） | 网络 | 由 `mlxconfig` 的 `LINK_TYPE_P1/P2` 逐口给出 ETH / IB / 未配置 |
| PSU 明细 | 电源 PSU | 描述、型号、部件号、序列号、额定容量、当前功耗 |
| 功耗读数 | 电源 PSU | 按口径分行：BMC 总功率、各 PSU 输入合计、DCMI 瞬时、DCMI 窗口、CPU RAPL；平台暴露时另有电源冗余行 |
| SEL 告警事件 | BMC | 最近 20 条告警级事件（日期、时间、类型、描述） |
| 散热风扇明细 | 风扇 | 风扇名、转速、状态 |
| HBA 明细 | 主机总线适配器 | 控制器、型号、固件、SN、状态、SAS 地址、端口 |

**动态列规则**：整列全为占位符时隐藏该列并附注说明（如位宽、寿命%、健康、Inforom、GPU 直连列）；JSON 始终保留全字段，不因展示裁剪而丢值。

### 3.2 关键口径

- **内存空槽**：明细列出空槽行并显示 `空槽`，用于回答「已插 24/32 槽，空的是哪几个槽」；数据层内部标记为 `EMPTY_SLOT`，统计端显式排除（否则会被当作一种容量而误报容量混插），JSON 字段仍为 `EMPTY_SLOT`。
- **CPU `标识（DMI）`**：取自 SMBIOS Type 4 的 `Serial Number`（`dmidecode -t processor`，由 BIOS 提供）。三层含义：① 该值跟随物理 CPU，可用于配件流转与换件核对；② 它不是厂商印在 CPU 上的序列号（Intel 服务器 CPU 不印 SN，唯一硬件号是 PPIN，且需 BIOS 开启），不可用于与原厂 SN 或跨品牌机器对账；③ 因此只作资产标识，机器身份仍以系统 SN / 主板 SN / 系统 UUID 为准。整列全为 `Not Specified` / `UNKNOWN` 时隐藏该列；JSON 字段名保持 `serial`。
- **GPU 显存与功耗**：按「检测/额定」双值展示（如 `140.4 GiB/141 GB`），检测值为采集时刻实际可见值，额定值取自规格库；差异来自 ECC 保留与厂商标称口径。
- **GPU 明细 PCIe 列**：列名恒为 `PCIe(协商)`，取值来自 `nvidia-smi -q` 的 `GPU Link Info`（`PCIe Generation` / `Link Width`）。SXM 模组上它同样是 PCIe 通路（模组到 host / NVSwitch 的 PCIe 链路），与 NVLink 无关；NVLink 带宽见 NVLink 章节与 `nvlink -s`。满速只显当前值，降速时追加 `(能力 …)`。
- **GPU 明细新增列**：`PCIe 地址(BDF)`（与 dmesg/XID 的 `PCI:0000:xx:00` 对号）、`设备 ID`（Vendor:Device，对应 BMC GPU 清单字段）、`Inforom`（Image Version，与 VBIOS 并列供固件一致性核对）。三者同步输出到 MD 表格、TXT 标签（`BDF:` / `ID:` / `Inforom:`）与 JSON（`bdf` / `pci_id` / `inforom`）。
  - BDF 规范化：采集端 `gpu_inventory.csv` 为 8 位域（`00000000:18:00.0`），报告端统一为 4 位域（`0000:18:00.0`），与 lspci/dmesg 一致。
  - 字段追加纪律：新增列一律追加在 `GPU_DETAILS` 行尾；中间插入会让按字段位置取值的 awk 整体错位。
  - 设备 ID 查表键统一小写（`lspci` 小写，`nvidia-smi` 可能大写）。
- **多厂商 GPU**：统一由 `gpu_inventory.csv`（18 列对齐 nvidia-smi schema）驱动，NVIDIA / AMD / 昇腾 / Intel / 国产卡同表渲染；显存魔改检测与验收 GPU PCIe 项跨厂商生效。NVIDIA 专属项（`Inforom` 列、NVSwitch 域章节、DCGM 行）在非 NVIDIA 平台整列或整段不输出。
- **设备形态**：报告头部按 chassis / ECC / BMC / GPU 信号自动分类（笔记本、一体机、台式机、工作站（消费版·服务器版）、传统服务器、NVIDIA / AMD / 其他 GPU 服务器、GB300 机架、GPU 机头），JSON 同步输出 `machine_class` 与 `machine_class_label`。
- **Compute Mode / ECC Mode 行**：取自 `dcgm/dcgmi_config.log`（`dcgmi config -g 0 --get`）表格行的 Current 列；出现 `Non-homogenous settings across group` 时追加说明「`-g 0` 为整个 GPU 组汇总，组内不一致时显示共识值」。旧采集（该文件为 `--list` 参数报错输出）显示「未取到（该机采集版本早于 v1.48.59，dcgmi config --list 语法错）」，不显示为 N/A；无 DCGM 数据（AMD 平台、未装 DCGM）则两行都不输出。
- **SXM 平台判定**（采集端，`lib/platform.sh`）：四路取或 —— `nvswitch` CLI、`lspci` 见 NVSwitch/SXM Bridge、`nv-fabricmanager` 进程且 `nvlink --status` 可用、`/dev/nvidia-nvswitchctl` 存在或 dmesg 出现 `Nvlink Core is being initialized`。第四路不依赖 NVLink 是否 up，避免 NVLink 域建不起来的机器被误判为 `PCIe` 而把模组故障伪装成平台形态。该修复只对新采集生效，归档数据沿用采集时写入的 `Platform` 值。

### 3.3 网卡 SN 与 PSID 来源

- **SN 取值链**：① sysfs `/sys/class/net/<dev>/device/serial` ② `lspci -vv` 的 `Serial Number` ③ `mstflint -d <dev> q`（MST 路径，新平台常不可用）④ **BMC FRU** ⑤ `ibstat` Node GUID。
  - 第 ④ 路读取 `bmc/ipmi_fru_all.log` 中 `PCIE_NIC*` FRU 块的 Part / Serial，属带外读取，不依赖 OS 驱动或 MST，是 CX8（sysfs 只给占位值、`mstflint` 报不支持）这类平台的最后一路来源。
  - 保守策略：仅当某个 PN 在 FRU 中恰好 1 条时才采用（多条无法确定对应哪张卡，宁可留白也不配错）；匹配用报告中的 PN（已去型号后缀）。
  - 该兜底须在 IB / 非 IB 分支之前完成，否则以太口（如 `enp112s0np0`）不会被覆盖。
- **PSID 取值**：`ethtool -i` 固件字符串括号值为权威来源（如 `40.46.5500 (NVD…)`），有值即覆盖；其次按 BDF 从 `nic_inventory` / `mlxfwmanager` 回查；旧采集由 `devlink`（`versions.fixed.fw.psid`）兜底。MST 路径在新平台及多口卡上常残缺，且存在 MST 设备与 BDF 误配读到其他卡 PSID 的风险。
- **Link 状态列**：IB 口取 `ibstat` State（多口状态不一致时聚合显示，如 `Active,Down`），以太口取 `ethtool` Link detected，全报告统一。
- **端口列与物理位置列**：端口列按 BDF 总线聚合显示「第 N 口/共 M 口」；物理位置由主板 SMBIOS 槽位表（Type 9）结合 PCIe 上游桥链上溯得到，`SXM<n>_GPU<m>` 为该网卡所在模组位（板级物理位置名，不是 nvidia-smi 逻辑编号），`SLOTn` / `LAN` / `M2_x` 为标准槽位名。

## 4. 网络段

网络段首部为概况表，逐行口径如下：

| 行 | 口径 | 数据源 |
|----|------|--------|
| 端口总览 | `N 口｜Up x / Down y`，有未插线缆时追加 `（未插线缆 z）`；按端口行统计，无端口级数据时回退为 `N 个 CA（无端口级数据）` | `NIC_DETAILS` 端口行 |
| 协议分布 | `N 口 IB · M 口 ETH · K 口其他`，并标注「按网卡固件统计，与上面接口数不同源」 | `mlxconfig` 的 `LINK_TYPE_P1/P2` |
| 速率 | `额定 <speed>`（卡能力，无需接线）+ `协商 <分布>`（IB 模式 Active 口的速率分布） | `mlxlink` 的 `Enabled Link Speed` 位图 / `ibstat` |
| IB 固件一致性 | 同型号 + 同 PSID 分组内固件版本多于 1 种时提示，措辞为「建议核对」，不进验收判定 | `nic_inventory.csv` |
| 计算网卡（GPU 直连） | `N 张 / M 口`，标注「与硬件概览同源口径」；无计算网卡时不显示本行 | `report/sections/65_nic_accounting.sh` |
| SR-IOV | `启用（N 张卡，最大 VF=k）` / `部分启用（…）` / `关闭（N 张卡，VF=0）` | `mlxconfig` 的 `SRIOV_EN` / `NUM_OF_VFS` |
| 模块信息 | 仅在 `mlxlink` 命令本身失败时出现的中性提示：`N 个设备中 M 个 mlxlink 读取失败（<dev>）——这几项无模块数据；未插线缆属常态，如本次要核对线缆请复采` | `mlxlink_*_module.log` 的 `-E-` 行或非零退出码 |
| 线缆类型 / 线缆配对 | 有数据才显示（DAC / Optical / 原始串；同一 EEPROM serial 视为同一根线两端） | `mlxlink_*_module.log` |
| 提示 / PSID | 有数据才显示：采集端 MST 未启动说明、PSID 缺失说明 | `network/mst_notice.log`、`nic_inventory.csv` |

要点说明：

- **协议分布与接口数不同源**：接口数来自端口行（每个协议口一行），协议分布来自网卡固件的 `LINK_TYPE` 配置；前者是操作系统可见端口，后者是固件声明的模式，两者计数不必相等，故在行内显式标注。
- **计算网卡与硬件概览同源**：归类统计集中在 `report/sections/65_nic_accounting.sh`，验收清单「硬件概览」与报告「网络」段共用同一结果，避免同一台机出现两个答案。判定顺序为 DPU（BlueField）→ GPU 直连（`nvidia-smi topo -m` 的 `PIX` / `PXB`，并限定 ConnectX-6/7/8、BlueField 卡型）→ 其余；无 topo 数据的平台（AMD / 昇腾）回退按 IB 协议口判定。数量单位为「张」（按物理卡计数，同卡多口只算一张），口数放括号内。
- **线缆缺失不作为缺陷**：出厂与验收通常不插光模块与线缆，因此「读不到模块」不告警；只有 `mlxlink` 命令失败（日志含 `-E-` 或 `exit code ≠ 0`）才提示，且为中性文案、不使用告警色。
- **IB 设备口径**：按 `ibdev2netdev` 映射到 `ibp*` / `ibs*` 接口的 CA 计数；以太模式 CA（如 CX5 双口以太）不计入 IB 设备数与 IB Link Down。IB 活动口与速率分布均只统计 `Link layer: InfiniBand` 且 `State: Active` 的端口，计数与速率同源。
- **额定与协商语义不同**：`额定` 取自 `mlxlink` 的 `Enabled Link Speed` 位图（卡能力，无需接线），`协商` 取自 `ibstat`（取决于对端与线缆）；额定 800G 的卡跑以太 100G 属配置选择，不是数据异常。

## 5. 健康检查段

健康检查表按检出情况逐行输出，避免满表 N/A：

| 行 | 判定与说明 | 出现条件 |
|----|-----------|---------|
| 内存 ECC | 取 EDAC 内存控制器计数：UE > 0 判 `❌`（需立即处理），CE > 0 判 `⚠️`（建议复查该内存条），全 0 显示 `✓ 无错误` | 平台暴露 EDAC 计数 |
| GPU PCIe 链路 | 有降速/降宽时列出；无 GPU 时按「未识别到 GPU 模组 / 机头 / 无 GPU」分别措辞 | 始终 |
| NVLink | 全互联正常 / 存在降级链路（含 CRC 非零标注） | 有 NVLink 数据 |
| DCGM 诊断 | 通过 / 配置项 Fail（软件类）/ 硬件 Fail；非 NVIDIA 平台不输出本行 | NVIDIA 平台 |
| GPU XID 错误 | 检出类别数与来源，明细见 GPU 段 | 检出时 |
| CPU MCE | 检出条数与来源；只认 `Machine Check` / `Hardware Error` / `MCA: ` 等真标志，排除内核启动与驱动初始化噪音 | 检出时 |
| 采集时机 | 开机不足 3 分钟且未发现 GPU 时提示 | 条件 |
| PCIe AER | 不可纠正 → `❌`，仅可纠正 → `⚠️`，附来源与主要 BDF | 检出时 |
| IB 链路误码 | 非零性能计数器；无 IB 口时不出现；日志存在但无计数器行时如实报「未取到端口计数器」 | 有 IB 口 |
| NVMe 介质错误 / 非正常掉电 / 命令兼容性 | 介质类与掉电类报 `⚠️`；纯命令类（Invalid Field）作提示，不算盘故障 | 检出时 |
| RAID 缓存电池 / 写缓存策略 | 电池异常时同看写缓存策略（WriteBack + 电池失效为掉电丢数据风险） | 有 RAID 卡数据 |
| 电源冗余 | 平台暴露冗余传感器时显示；未暴露则整行不出现 | 条件 |
| 风扇冗余 | 同上；`0x00` 视为「未定义」而非「有冗余」 | 条件 |
| SEL PCIe 错误 | 记录条数 + 时间跨度；若该批记录最新一天比 SEL 最新事件早 90 天以上，标注为历史记录、非当前链路故障 | 始终 |

## 6. GPU 额定显存规格库

内置 60 余款主流 NVIDIA 型号与 AMD Instinct（MI300X / MI325X / MI250X / MI355X 等）的额定容量映射，用检测值交叉验证（GB/GiB 双口径、3% 容差）自动匹配：

- 多版本型号（如 A100 40/80 GB）取最接近者。
- 检测值与额定值不符时输出 `⚠️ 疑似显存魔改或伪装`（PCIe 魔改卡识别；NVIDIA / AMD 统一走 `verify_gpu_mem`）。
- 无厂商 SMI 的降级场景（generic 适配器）检测显存为 N/A、不触发魔改判定，但型号已知时仍给出额定值（如「检测 N/A / 额定 1504 GB」），避免整列空白。
- 型号文本取自 lspci 厂商行括号内的短型号（如 `AMD Instinct MI300X`、`NVIDIA B200`），去掉 `[AMD/ATI]` 类噪音后匹配更稳定。
- AMD 平台固件版本按厂商语义表述为「固件版本」，不使用 VBIOS 字样（AMD 无 VBIOS 概念）。

## 7. 验收清单

### 7.1 生成方式

```bash
bash report/report.sh <采集目录> --acceptance     # 生成 hwscope_acceptance.{md,html}
```

`--acceptance` 与四件套是两个独立分支，批量重生成时须各调一次；只跑四件套时验收清单会停留在上一次的生成结果。`report.sh` 在不含 `--acceptance` 时会打印该提示，参考实现见 `tools/agent/regen_reports.sh`。

验收清单章节为 `硬件概览` / `验收信息` / `验收项目` / `结论`，对应侧栏短名 `硬件概览` / `验收信息` / `验收项目` / `验收结论`。

### 7.2 硬件概览（配置单）

由检测数据自动生成，可直接对照采购配置单核对，行序为：准系统（系统 SN / 机箱 SN / BIOS）、CPU、内存、GPU 模组、计算网卡、DPU、网卡&端口、存储、电源模块、风扇、系统管理（BMC 固件与管理地址）。

- **计算网卡**：按「GPU 直连」归类（`PIX` / `PXB` + 卡型过滤），判的是物理直连而非当前运行协议；DPU（BlueField 系列）单列一行，判定顺序 DPU → GPU 直连 → 其余。数量单位为「张」（按物理卡计数，同卡多口只算一张），口数放括号内，如 `3（单口×1 + 双口×1，共 3 口）`。
- **存储**：按「型号 + 接口类型 + 单盘额定容量」分组计数渲染，如 `型号（NVMe 3.84TB）×8（共 28672 GiB）`，多组以 ` + ` 连接。三条口径：① 型号串已含容量时括号内不重复；② RAID 卡伪盘（`MR9xxx` / `PERC` / `MegaRAID` / `Smart Array` / `Adaptec`）与 16 进制伪「额定」值不计入分组；③ 分组数与块设备数不一致时数量列注明 `N（其中物理盘 M）`。无明细时回退为「首个型号 + 总容量」；本机仅有 USB / 虚拟盘时显示「无本地数据盘」，与「未采集到」区分。
- **GPU 模组**：有卡给型号与数量；仅有 PCI 存在性时给检测数量；未识别到时写「未识别到（原因）」，单位与数量留空。
- **系统管理**：无 BMC 的平台不显示该行；有 BMC 时附管理地址与来源（DHCP / 静态），地址全 0 时写「管理地址未配置」。

### 7.3 验收信息

三行表格：验收口径（设备形态 + GPU 平台 + 平台固有 N/A 项数 + 实际判定项数）、生成时间、采集版本 / 报告版本。

### 7.4 验收项目与排序

默认判定项共 17 项，渲染行数随平台能力裁剪（被折叠为平台固有 N/A 的项不占序号，B300 样本渲染 14 行）；另有 6 项条件项仅在检出时追加，不改变无该问题机器的项数。

| 检查项 | 性质 | 判定要点 |
|--------|------|---------|
| GPU PCIe 链路完整 | 默认 | 任一卡降速/降宽即 FAIL；无 GPU 判 N/A；有 PCI 卡但无管理工具数据判 WARN |
| NVLink 互联 | 默认 | 存在降级链路 FAIL；无 NVLink 能力（消费级/无桥）判 N/A |
| DCGM 诊断 | 默认 | 通过 PASS；配置项 Fail 判 WARN；硬件 Fail 判 FAIL；消费级判 N/A |
| GPU VBIOS 版本一致 | 默认 | 混插固件判 WARN |
| 内存运行速率 | 默认 | 见 §8.1 |
| 磁盘寿命 | 默认 | < 90% WARN，< 50% FAIL；无 SMART 数据判 N/A 且计入数据不足 |
| SMART 健康状态 | 默认 | FAILED 判 FAIL；有警告判 WARN |
| 电源状态 | 默认 | `PS*_Status` 非 `0x1` 判 FAIL；无状态传感器时按 SMBIOS 在位数量兜底 |
| 整机温度正常 | 默认 | BMC 聚合值优先，其次 OS 侧 lm-sensors；无 BMC 判 N/A |
| SEL 事件 | 默认 | 未解除 Critical 判 FAIL（全部落在断电时刻的判 WARN）；已自愈判 WARN；PCIe 记录按可纠正/不可纠正分级 |
| 固件版本合规 | 默认 | 落后判 FAIL；格式无法比较判 WARN；未录基线判 N/A（不计入数据不足） |
| OS-BMC 口径一致 | 默认 | 仅 `--bmc-verify` 启用后判定；未启用判 N/A 且不计入数据不足 |
| PCIe 链路完整 | 默认 | 端点 LnkSta 低于 min(设备, 上游) 判降速并判 WARN；无链路数据判 N/A |
| CPU 配置一致 | 默认 | 多颗 CPU 型号/Stepping/核数不一致判 FAIL；单颗判 N/A |
| 内存容量一致 | 默认 | 容量混插判 WARN（空槽不参与统计） |
| 内存 ECC | 默认 | 有 ECC 纠错 PASS；无 ECC / 类型未知判 WARN |
| GPU ECC | 默认 | 见 §8.8；AMD 无 RAS 数据判平台固有 N/A |
| GPU 功耗上限 | 条件 | Current ≠ Default 时 WARN（见 §8.7） |
| 采集时机 | 条件 | 开机不足 3 分钟且未发现 GPU 时 WARN（见 §8.6） |
| PCIe AER 错误 | 条件 | 可纠正 WARN，不可纠正 FAIL |
| GPU XID 错误历史 | 条件 | 检出即 WARN（历史证据，留痕不否决） |
| CPU MCE | 条件 | 检出即 WARN |
| RAID 缓存电池 | 条件 | 电池异常 WARN（与写缓存策略同看） |

**渲染顺序按报告章节排列**（`report/gen/gen_acceptance.sh` 的 `_acc_rank()`），而非代码执行顺序。排序键如下，未命中的项排最后并保持插入顺序：

| 分组 | 排序键 | 项 |
|------|--------|----|
| ⓪ 数据可信度 | 10 | 采集时机 |
| ① 平台通路 | 20 / 21 | PCIe 链路完整；PCIe AER 错误 |
| ② 部件 | 30 / 31 | CPU 配置一致；CPU MCE |
| ② 部件 | 40 / 41 / 42 | 内存容量一致；内存运行速率；内存 ECC |
| ② 部件 | 50–56 | GPU VBIOS 版本一致；GPU 功耗上限；GPU ECC；GPU PCIe 链路完整；GPU XID 错误历史；NVLink 互联；DCGM 诊断 |
| ② 部件 | 60 / 61 / 62 | 磁盘寿命；SMART 健康状态；RAID 缓存电池 |
| ② 部件 | 70 / 80 | 电源状态；整机温度正常 |
| ③ 合规与一致性 | 90 / 91 | 固件版本合规；OS-BMC 口径一致 |
| ④ 平台事件汇总 | 95 | SEL 事件 |

说明文本处理：说明中的 `|` 统一替换为全角 `／`，避免撑破表格；WARN / FAIL 项的「——」断为两行（结论与解释/建议分行），PASS / N/A 不分行。

### 7.5 判定规则

| 结果 | 条件 |
|------|------|
| ✅ 合格 | 无 FAIL、无 WARN、无计入的 N/A |
| ❌ 不合格 | 任一 FAIL |
| ⚠️ 有条件通过 | 有 WARN，无 FAIL |
| ⚠️ 数据不足 | 无 FAIL / WARN，计入的 N/A ≥ 4 项 |
| ✅ 基本通过 | 无 FAIL / WARN，计入的 N/A 为 1–3 项 |

判定即上表优先级：FAIL > WARN > N/A 计数，三项统计互斥累加。

### 7.6 条件驱动 N/A 计数

N/A 是否计入「数据不足」按成因区分，不按同一标准一刀切。平台固有项与待启用项折叠为表尾汇总（不渲染行、不占序号）：

| 场景 | 是否计入 | 说明 |
|------|---------|------|
| 无 GPU（`absent`：开机时间正常且 PCI 无加速卡） | 不计 | 平台固有 |
| GPU 机头（模组单独采集） | 不计 | 平台形态 |
| **未识别到 GPU 模组（`unknown`）** | **计** | 采集过早或 PCI 有卡但管理工具无数据，无法判定，建议开机 ≥2 分钟后复采 |
| GPU 无 NVLink 能力（消费级 / 无桥 PCIe） | 不计 | 硬件形态 |
| AMD / 昇腾平台 NVLink、DCGM | 不计 | 平台无对应技术 |
| 无 topo 数据（旧采集）导致的 NVLink N/A | **计** | 数据缺失 |
| DCGM 未安装或已禁用（数据中心卡） | **计** | 数据缺失 |
| PCIe 链路无全量数据（旧采集无 `pcie_full`） | 不计 | 采集版本形态 |
| 无数据盘 | 不计 | 配置形态 |
| **有盘但无 SMART（寿命 / 健康）** | **计** | 真缺数据 |
| 单颗 CPU（无对称性可判） | 不计 | 配置形态 |
| 平台未暴露电源状态传感器 | 不计 | 平台固有 |
| 无 BMC（IPMI 日志为错误输出） | 不计 | 平台固有 |
| **启用 `--bmc-verify` 后采集失败 / 无对比数据** | **计** | 真缺数据 |
| 固件合规未录基线（`conf/fw_required.txt` 全注释） | 不计（且整段不显示） | 待启用项 |
| **已录基线但无固件数据** | **计** | 采集缺失 |
| 本机无可判定固件项（无 VBIOS / 未匹配基线） | 不计 | 平台固有 |
| OS-BMC 未启用 | 不计 | 待启用项 |
| GPU ECC：NVIDIA 未生成 `gpu_ecc_inventory.csv` | **计** | 采集缺失 |
| GPU ECC：AMD 未取到 RAS 数据 | 不计 | ROCm 工具链限制 |

表尾分别汇总「本平台固有/宽容 N/A」与「本机待启用/待配置 N/A」两组，后者不与前者混列：读者据此可分辨「这台机本来没有」与「这台机有条件但未开启或未录基线」。

### 7.7 输出片段示例

以下为格式示意（数值为示例，非某台机器结论）：

```
| # | 检查项 | 结果 | 说明 |
| 1 | PCIe 链路完整 | ✅ PASS | 128 条链路满速（无降速/降宽） |
| 2 | CPU 配置一致 | ✅ PASS | 2 颗 CPU 型号/Stepping/核数一致 |
| 3 | 内存容量一致 | ✅ PASS | 已插 24 条同容量（64 GB） |
| 4 | 内存运行速率 | ✅ PASS | 降速运行（现速 5200 MT/s，额定 6400 MT/s；已插 24/32 槽属 >1DPC 配置，降速为平台规范正常现象） |
| 5 | GPU VBIOS 版本一致 | ✅ PASS | 97.10.64.00.0C |
| 6 | GPU ECC | ✅ PASS | 本次与累计均无错误（volatile 0 / aggregate 0） |
| 7 | GPU PCIe 链路完整 | ✅ PASS | 全部 GPU 处于最高 PCIe 速率 |
| 8 | NVLink 互联 | ✅ PASS | 全互联无降级链路 |
| 9 | DCGM 诊断 | ⚠️ WARN | 配置项 Fail（Persistence Mode 未开启，非硬件故障） |
| 10 | SEL 事件 | ✅ PASS | 12 条 SEL，无 Critical/PCIe 错误（有历史事件） |

判定: 有条件通过（1 项 WARN，建议记录后交付）
```

交付时验收清单作为交接单使用；FAIL / WARN 项均附具体说明，可直接转发客户。

## 8. 专项判定口径

### 8.1 内存运行速率

**问题**：`MEM_NOM` 曾用 `extract "Speed:"` 只取第一条内存的额定速率。混插机型（同一厂商、三种部件号）实测 16 条内存分属 4800 MT/s 与 6400 MT/s 两档，控制器只能按最低档 4800 训练，由此得出的「额定 6400、现速 4800、≤1DPC 仍降速，建议核查 BIOS」结论是错的 —— 4800 就是该配置的最低额定，与 BIOS 无关。

```
2R 模块 × 7    额定 4800 MT/s
1R 模块 × 7    额定 6400 MT/s
2R 模块 × 2    额定 6400 MT/s
（同一厂商、三种不同部件号）
→ 控制器只能按最低档 4800 训练，16 条全部跑 4800（Configured Memory Speed 一致）
```

**修正**：

1. 额定改取整机**最低**额定（遍历在位内存的 `Speed:` 取最小值）。
2. 新增混插检测：部件号、额定档、Rank 三种维度去重计数，任一大于 1 即判定为混插。
3. 验收按交付口径分档，顺序不可颠倒：

| 优先级 | 情形 | 判定 | 文案口径 |
|--------|------|------|---------|
| ① | >1DPC（含插满）降速 | PASS | 属平台规范，与是否混插无关，优先于混插判定 |
| ② | 规格混插（额定速率或 Rank 不同） | WARN | 控制器只能按最低档训练，如实陈述，不写「建议统一型号」 |
| ③ | 仅料号不同（额定与 Rank 一致） | PASS | 不提示：市场批次完全统一不现实，规格一致即属良好 |
| ④ | 不混插 + ≤1DPC 仍降速 | WARN | 真问题，建议核查 BIOS |

**注**：JEDEC SPD 的 `Module Revision Code` 可区分修订批次，但 `dmidecode` 不输出该字段，因此只能表述为「N 种不同料号」，不得臆断为「仅修订版本差异」。

### 8.2 PCIe 降速判定基准

| 缩写 | 全称 | 含义 |
|------|------|------|
| `LnkCap` | Link Capabilities Register | 该链路支持的上限（最高速率 + 最大宽度） |
| `LnkSta` | Link Status Register | 该链路当前协商结果 |
| Upstream / Downstream Port | — | 位置概念（上行/下行端口），与上述两个属性是两个维度 |

端点的 `LnkCap` 报的是**芯片自身能力**，而 Root Port / Switch 端口的 `LnkCap` 才描述「它到下游设备这条链路」的上限。判定公式：

```
本链路可达上限 = min(设备 LnkCap, 上游父桥 LnkCap)     # 速率、宽度分别取 min
实际           = 设备 LnkSta
实际 == 上限 → 满速        实际 < 上限 → 降速 / 降宽
```

两种错误基准：

- **只用设备自身 `LnkCap`**：芯片能力强于端口时误报。HGX B200 板载 ConnectX-7 芯片 `Gen4 x2`、上游 root port 仅 `Gen3 x2`，实际 `Gen3 x2` 已跑满端口天花板，却被判「降速」并拉低验收结论。
- **只用上游 `LnkCap`**：反向误报。Gen4 卡插 Gen5 槽跑 Gen4 属正常，只比上游会把正常链路判成降速。

**兜底**：找不到父桥映射时退回「设备自身 `LnkCap`」基准，保持原有行为不劣化。

**判定范围**：只判 endpoint 设备（网卡 / GPU / RAID 卡）。bridge 端口降速属下游能力协商（x16 口接 x8 卡为正常），标注「协商（下游能力）」不计异常；管理芯片（ASPEED / Matrox / VGA）标注「管理芯片固有」；USB 主控、串行总线、音频、信号处理等非关键通路外设标注「外设固有」，单列计数，不计链路异常。

### 8.3 PCIe 链路解析：BDF 的两种格式

`lspci -vvv`（`pcie_full.log`）的 BDF 前缀有两种形式，解析须同时兼容：

| 格式 | 样例 | 出现场合 |
|------|------|---------|
| 两位域 | `00:1f.0`（bus:dev.func） | 单 PCI 域平台（多数） |
| 四位域 | `0000:00:1f.0`（domain:bus:dev.func） | 多 PCI 域平台，lspci 自动带域名 |

正确写法为「域名作可选前缀」：`^([0-9a-f]+:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]`。

两种错法都会**静默失效**（不报错，而是链路表恒空，报告写成「旧采集无 `pcie_full` 全量日志」，把解析失败伪装成采集失败）：

- 只认两位域（`^[0-9a-f]{2}:`）→ 多域平台整份解析不出；
- 要求三段（早期写法）→ 漏掉多数单域平台。

排查手法：报告出现「N/A（旧采集无 XXX）」时，先确认原始日志存在且非空，再核对解析正则。

### 8.4 物理位置反查：剔除占位 Bus Address

网卡「物理位置」列 = 设备 BDF → 沿 PCIe 桥链逐级上溯 → 命中 SMBIOS 槽位表（Type 9）的 Bus Address。

SMBIOS 中存在地址未填充的槽位记录时，BIOS 写 `0000:00:00.0`，剥掉域名后 bus 为 `00`，而 bus 00 是根总线（host bridge），任何设备上溯到顶都会经过它，于是所有上溯到根总线的设备都会误命中该槽位名。

修法：构建槽位映射时剔除占位地址 —— `0000:00:00.0`（未填充）、`ff:00.0`（占位），并对 bus `00` 再设一道保险；反查不到时如实留空（`—`），不猜槽位。判据：槽位记录的 Bus Address 若为 `xx:00.0` 形式或 bus 落在 `00` / `ff`，视为无效，不参与反查。

### 8.5 SEL 告警终态

`Asserted` / `Deasserted` 是同一事件的状态机两态，判定须**按事件键取最后一次出现的状态**：末次为 `Asserted` 才算未解除。仅判断「该键是否出现过 `Deasserted`」会漏判反复告警（`A→D→A→D→A` 这类序列只要曾解除过一次就会被当成已自愈）。

- 统计口径为唯一「传感器 | 事件」键数，`SEL_CRIT_UNRESOLVED` 与 `SEL_CRIT_RECOVERED` 互补，两者之和等于告警键数。
- **断电豁免**：统计时同时收集断电类事件（`Power Supply` / `Power Unit` 的 `AC lost` / `Power off-down`）的时间戳；未解除告警若全部落在这些时刻，判 WARN（掉电瞬间传感器读数触发，BMC 恢复后不补 `Deassert`）；只要存在与断电无关的未解除告警，仍判 FAIL。
- 部分 BMC 在传感器恢复后不补发 `Deassert`，这类「末次 Asserted 但硬件已恢复」的记录需结合当前传感器读数人工判读，报告如实呈现数字，不代为断言。

### 8.6 GPU 模组状态与采集时机

`GPU_COUNT=0` 是采集事实，不能直接推出「未装模组」。报告按三态决定措辞与验收计数：

| 状态 | 判据 | 报告措辞 | 验收 |
|------|------|---------|------|
| `present` | 有 GPU 数据 | 正常输出明细 | 正常判定 |
| `unknown` | 采集时 `/proc/uptime` < 3 分钟，或 PCI 有加速卡但管理工具无数据 | 「⚠️ 未识别到 GPU 模组：本次采集未枚举到任何加速卡（原因）」+ 复采建议 | GPU PCIe / NVLink / DCGM 判 N/A，**计入数据不足** |
| `absent` | 开机时间足够且 PCI 无加速卡 | 「⚠️ 未识别到 GPU 模组：本次采集 PCI 未枚举到任何加速卡（采集时系统已运行 N 分钟，不属采集过早）」 | 按平台固有折叠，不计 |

**文案纪律**：只陈述「未识别到」。不写「无模组 / 平台无 GPU」（替客户下结论），也不写「无法判定是否装有模组」（会被读成可能装着）。

**平台标签与模组状态分离**：`PLATFORM=x86_64_head` 只表达「无本地 GPU + 存在 PCIe Fabric 交换机」这一形态，不代表模组在位；模组是否识别到由 GPU 段的「状态」行单独说明。

**采集时机告警**：判据为 `/proc/uptime` < 180 秒（采集端 < 120 秒即打印 `[WARN]`）。呈现三处：GPU 段的「⚠️ 采集时机」行、健康检查的同名行、验收清单的条件项 `采集时机 → WARN`（仅在「开机 < 3 分钟且无 GPU」时出现，不改变正常机器的项数）。

### 8.7 GPU 功耗上限被改

`nvidia-smi -pl` 调整功耗上限后，功耗列仍显示「功耗(检测/额定)」，表面看不出上限被改。报告因此增加一行，仅在 `Current Power Limit ≠ Default Power Limit` 时出现，并按限值归组：

```
| ⚠️ 功耗上限 | 被改过：GPU0/1/4 → 800W（默认 1000W）；满载时这些卡只有相应比例的功耗预算（掉频、各卡算力不均）；若非刻意设置，执行 sudo nvidia-smi -pl 1000 恢复后复测 |
```

验收清单同步追加条件项 `GPU 功耗上限 → WARN`（仅检出时出现）。数据源为既有 `gpu/gpu_full.log` 的 `Current Power Limit` / `Default Power Limit`，旧采集同样生效，无需重采。另自 v1.54.25 起采集端补采裸 `nvidia-smi`（`gpu/gpu_smi.log`），提供现场最常看的 `Pwr:Usage/Cap`、显存占用、利用率一屏形态。

### 8.8 GPU ECC

数据源为 `gpu/gpu_ecc_inventory.csv`（`nvidia-smi --query-gpu=ecc.errors.*`，零新增采集）。判定分两个维度，不把四类计数混加：

- **性质**：`可纠正`（HBM 常态自愈，不卡交付）与 `不可纠正`（数据损坏，必须处理）。
- **时机**：`volatile`（本次驱动加载以来，正在发生的才算问题）与 `aggregate`（终身计数，含出厂老化测试，是 NVIDIA RMA/保修判定依据，Ampere 及以后不支持清零）。

| 条件 | 判定 |
|------|------|
| `volatile 不可纠正 > 0` | FAIL（需报修） |
| `volatile 可纠正 > 0` | WARN |
| `aggregate 不可纠正 > 0` 且 `volatile 不可纠正 = 0` | WARN（历史记录，建议跑一轮显存压力后复测 volatile 是否增长） |
| 全 0 | PASS |

混加会造成两种误导：分不清性质（可纠正与不可纠正同权）与分不清时机（历史累计被当作当前故障）。**`aggregate` 归零的含义**：该计数正常只增不减，同一台机器两次采集间归零说明换过卡或换过模组，此时旧记录不应作为当前状态依据，验收记录应留一句「模组已更换」的说明。

行重映射（`Remapped Rows`）与 Bank 余量在 `gpu_N_ecc.log` / `gpu_N_detail.log` 中可查，用于判断不可纠正错误是否已被硬件隔离（`Remapping Failure Occurred: No` 即正常）。

**AMD 口径**：AMD 不生成 `gpu_ecc_inventory.csv`，采集端把 RAS 计数写入 `gpu/gpu_amd_ras.log`（`rocm-smi --showrasinfo` / `amd-smi metric -e` / `rocm-smi --query-ecc` 三级兜底）。报告端有数据即真判（单比特→可纠正、双比特→不可纠正；AMD 无 volatile/aggregate 之分，统一映射到 volatile），取不到数据判「平台固有 N/A」不计数。

### 8.9 固件合规段

- **门禁** `FW_COMPLIANCE_ACTIVE`：`conf/fw_required.txt` 未录入基线（全注释）时整段不出现（MD/TXT 同口径）；录入基线后自动显示，含 合规 / 落后 / 较新 判定，无基线条目仅作记录。
- **位置**：`电源 PSU → 能耗台账 → 固件合规 → 健康检查 → PCIe 链路明细（附录） → 术语说明`。
- **数据可见性**：固件版本数据仍在 `firmware/fw_versions.log`、`firmware/fw_compliance.csv` 与报告 JSON（`firmware` 字段，未启用时 `items` 为空）中可查。「数据不可见」的诉求由采集与落盘满足，不等于要在正文显示。
- 报告端对旧采集的过滤：非 NVIDIA 平台丢弃 `NVSWITCH` 行（旧实现会把工具版本当固件版本），丢弃 USB 存储与 USB 网卡行。

### 8.10 PCIe AER 错误统计

只比对 `LnkCap` / `LnkSta` 会漏掉持续纠错但速率正常的链路。报告按 BDF 统计 AER：源取 `journalctl -k` 与 `dmesg` 中命中较多的一路，逐 BDF 计数并区分可纠正（`RxErr` / `BadTLP` / `BadDLLP` / `Timeout`）与不可纠正（`Fatal` / `Unsupported Request`）。

- 健康检查单独成行，不被「链路 PASS」掩盖；验收清单在检出时追加条件项。
- SEL 侧 PCIe 记录分三级：不可纠正 → FAIL；可纠正 → WARN；历史（该批记录最新一天比 SEL 最新事件早 90 天以上）→ WARN 并标注时间跨度。
- 排查提示：可纠正错误集中在某个下游端口时，通常指向该端口下的卡 / riser / 槽位；空闲状态仍持续报错时优先检查交换机端口层。
- AER 计数是内核已记录的历史，不随本次采集产生；判断是否与本次采集相关，看最早一条的时间戳是否早于采集开始时间。

### 8.11 机头与 Fabric 交换机文案（厂商中立）

| 位置 | 文案 |
|------|------|
| 平台行 / 设备形态 | `GPU 机头（PCIe Fabric 接模组，模组单独采集）` |
| 硬件概览 GPU 模组行 | `未识别到（…）`；有卡时给实际数量 |
| PCIe Fabric Switch | `PEX890xx（模组互联通道，NVIDIA HGX 或 AMD OAM 通用）` |

同一批 PEX89xxx 在 AMD OAM 整机上属于模组互联芯片，文案不得写死厂商，否则等于告诉 AMD 客户「这是 NVIDIA 机器」。

## 9. FLD 诊断参考（`--fld-dir`）

关联 NVIDIA DGX Field Diagnostic 日志目录（`logs-<TS>/`），报告新增「FLD 诊断参考」段：

- **概览**：诊断版本、基础版本、产品、SN、总耗时与最终结果（PASS / FAIL）。
- **测试矩阵**：逐测试项的 PASS / 跳过 / FAIL 与组件数（解析 `run.log` 的 `Testing <test> OK/SKIPPED` 进度行与 `MODS-... | test | ... | component | OK` 矩阵行，纯文本解析，零新依赖）。
- **非通过项明细**：FAIL / 跳过逐组件列出。
- 适用场景：HGX / Dell 交付中把厂商出厂诊断结果并入 HwScope 报告，与自有采集交叉引用。

```bash
bash report/report.sh <采集目录> --fld-dir /path/to/logs-20251026-145655
```

## 10. 归档

采集结束生成两个压缩包，共用同一 14 位时间戳：

```
logs/<SN>-<ARCHIVE_TS>.tar.gz               # 详细分级日志
logs/report/<SN>-<ARCHIVE_TS>-report.tar.gz # 报告四件套
logs/remote_logs/                           # 远程采集归档（独立）
```

## 11. 术语说明

报告末尾附术语表（IB、额定/实际速率、GPU 直连、NVLink、NVSwitch、DCGM、SEL、SXM、PSID、退役行、CE/UE、volatile/aggregate、标识（DMI）、2DPC），存在 Mellanox 网卡时另附 MT 编号与型号对照表；未确认的型号编号不猜，避免误标。

## 附录 A 近期变更要点

| 版本 | 变更 |
|------|------|
| v1.51.8–v1.51.10 | PCIe 降速基准改为 min(设备, 上游)；内存额定取整机最低并检测混插，验收按 DPC 与混插分档 |
| v1.52.9 | GPU 明细新增 BDF / 设备 ID / Inforom 列；SXM 判定补第四路（不依赖 NVLink 健康） |
| v1.52.12–v1.52.16 | 软 RAID 明细表；SEL 改按告警终态判定；温度接入 OS 侧兜底；GPU PCIe 列名固定为 `PCIe(协商)` |
| v1.52.20 | SEL 未解除告警的断电豁免 |
| v1.52.24–v1.52.25 | PSU 容量缺失按成因注明（JSON 与验收剥离说明部分） |
| v1.53.16–v1.53.18 | 硬件概览「存储」行改为按型号 + 接口 + 单盘容量分组计数 |
| v1.53.20 | PCIe 链路新增「外设固有」判定（USB 主控等不计异常） |
| v1.53.32 | HTML 改三档响应式断点，取消等比 `zoom`；宽表由容器横向滚动 |
| v1.53.34–v1.53.36 | 非 NVIDIA 平台不再误判机头；NVSwitch 域 / DCGM 行 / Inforom 列不输出；SEL PCIe 记录区分历史与当前 |
| v1.53.37 | 新增 PCIe AER 统计与验收条件项 |
| v1.53.38–v1.53.43 | 固件合规段恢复「未录基线不显示」门禁，位置固定在能耗台账之后 |
| v1.53.40 | 新增采集时机告警（开机 < 3 分钟且无 GPU），三处呈现 |
| v1.53.41–v1.53.42 | GPU 模组三态措辞定稿：只陈述「未识别到」 |
| v1.54.25 | 新增 GPU 功耗上限被改检测；补采裸 `nvidia-smi` |
| v1.54.26–v1.54.30 | 新增 SR-IOV、网卡协议模式展示；BMC 管理地址来源（DHCP / 静态）；电源冗余、风扇冗余进入健康检查 |
| v1.54.27 | 验收项按报告章节顺序排列；说明列支持结论/建议分行 |
| v1.54.28 | ≤5 列窄表自动换行，≥6 列宽表保留横向滚动 |
| v1.54.32 | 内存 ECC（EDAC）进入健康检查；网卡归类统计抽为 `65_nic_accounting.sh` 三端共用 |
| v1.54.33 | 内存空槽显示 `空槽`（JSON 仍为 `EMPTY_SLOT`） |
| v1.54.34 | 仅 WARN / FAIL 说明按「——」分行 |
| v1.54.35 | 模块信息改为仅在 `mlxlink` 命令失败时提示 |

## 附录 B 验证状态

- **NVIDIA / AMD**：已由真机样本回归（B200 / B300 / A100 / MI300X 等）。
- **昇腾 / Intel / 国产加速卡**：代码路径与工具探测已实现，尚无真机样本，型号识别与输出解析标注「待真机校准」；无工具时回落 lspci 通用兜底，加速卡不会从报告中丢失。
