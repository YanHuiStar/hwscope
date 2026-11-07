#!/bin/bash
# =============================================================================
# HwScope - 报告解析辅助函数
# report/lib/report_common.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
extract() {
    local pattern="$1" file="$2"
    [ -f "$file" ] || { echo ""; return; }
    grep -iE "$pattern" "$file" 2>/dev/null | grep -v "^#" | head -1 | cut -d':' -f2- | sed 's/^ *//;s/ *$//' | head -c 200
}

# ─── 过滤日志：去除注释行（行首 #）和空行 ───
filter_log() {
    grep -v "^#" "$1" 2>/dev/null | grep -v "^$"
}

# ─── JSON 字符串转义（v1.49.19）───
# 背景：gen_json.sh 里存在两种拼装风格——awk 分支转义了 `\` 与 `"`，bash 数组与 heredoc 标量
#   没有 → 任一字段含引号/反斜杠（实测触发：nvidia-smi CSV 对含逗号的名称加引号后型号名带 `"`）
#   就产出**不可解析**的 JSON，而 JSON 是机器消费产物（batch_compare.sh 等直接读），
#   报错点还在解析侧、现场很难溯源。
# 只做 JSON 必需的两件事：反斜杠与双引号；顺带去掉会破坏"单行值"的 CR。
# 注意：**不去换行**——多行字段（如 PSU list）在调用点自行 tr 成单行，不在这里处理。
jesc() {
    # JSON 字符串转义：反斜杠 → 双反斜杠；双引号 → \"；制表符 → \t；
    #   换行 → 字面 \n（字段若含换行，直接写进 JSON 会让整份解析失败）；去掉 \r。
    #   顺序要点：先转义真实反斜杠，再引入 \n/\t 这类转义序列（否则会被二次转义）。
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g' -e 's/\t/\\t/g' -e 's/\r//g'
}

# ─── 清单加载：从 manifest.txt 读取模块输出文件名，回退到默认值 ───
# 用法: load_manifest <目录> <key> [默认文件名]
# 若 <目录>/manifest.txt 存在且含 <key>=<value>，设置 shell 变量 $key 为完整路径；
# 否则使用 <目录>/<默认文件名>（默认文件名 = key 本身）。
load_manifest() {
    local dir="$1" key="$2" default="${3:-$2}"
    local manifest="${dir}/manifest.txt"
    if [ -f "$manifest" ]; then
        local val
        val=$(grep "^${key}=" "$manifest" 2>/dev/null | tail -1 | cut -d'=' -f2-)
        if [ -n "$val" ]; then
            declare -g "${key}=${dir}/${val}"
            return
        fi
    fi
    declare -g "${key}=${dir}/${default}"
}

# ─── CSV 列名动态匹配 ───
# 用法: get_csv_col_index <csv_file> <column_name>
# 返回: 列索引（从 1 开始）；未找到返回**空**（v1.52.1 修复：原返回 "0"，
#   非空 → 调用方 `${col:-6}` 默认列兜底永不生效，且 col=0 时 awk 取 $0 整行输出 N/A）
get_csv_col_index() {
    local csv_file="$1" col_name="$2"
    [ ! -f "$csv_file" ] && return
    local header
    header=$(filter_log "$csv_file" | head -1)
    [ -z "$header" ] && return
    echo "$header" | awk -F',' -v target="$col_name" '{
        for(i=1; i<=NF; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
            if($i == target) {
                print i
                exit
            }
        }
        # 未命中：不输出（空返回，让调用方 ${col:-N} 兜底生效）
    }'
}

# ─── 收集基础信息 ───
SUMMARY="${OUT}/summary.txt"
HOSTNAME=$(extract "Hostname" "$SUMMARY")
VERSION=$(extract "Version" "$SUMMARY")
[ -z "$VERSION" ] && VERSION="N/A"   # 老版本采集数据无 Version 行
# 报告生成器版本（单一权威源 = hwscope.sh 的 HWSCOPE_VERSION，动态读取自动跟随升版本，
# 无需 sync_version 参与；与采集版本 VERSION 区分：采集版本=数据何时采集，生成器版本=报告用哪个工具版本生成）
REPORT_VERSION=$(grep '^HWSCOPE_VERSION=' "${SCRIPT_DIR}/hwscope.sh" 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -z "$REPORT_VERSION" ]; then
    # 防御：读取失败（hwscope.sh 缺失/HWSCOPE_VERSION 格式异常）如实提示，勿静默 unknown（v1.35.1）
    REPORT_VERSION="unknown"
    echo -e "${YELLOW}[WARN] 报告生成器版本读取失败（${SCRIPT_DIR}/hwscope.sh 缺失或 HWSCOPE_VERSION 格式异常），报告版本将显示 unknown${NC}" >&2
fi
PLATFORM=$(grep -m1 "^Platform" "$SUMMARY" 2>/dev/null | cut -d':' -f2- | awk '{print $1}')
# v1.52.9 报告端兜底：采集端旧版 SXM 判定三路都要求 NVLink/NVSwitch 可用，NVLink 故障机
#   （FM 起不来、链路全 inactive）会被写成 x86_64_PCIe，报告链路列随之显示「PCIe(协商)」，
#   把 SXM 模组故障伪装成「本来就是 PCIe 形态」，恰好掩盖故障。已归档数据无法重判采集，
#   此处按「dmesg 出现过 nvlink core 初始化」兜底改判 SXM —— 该行只有带 NVSwitch 的模组才有，
#   实测真 PCIe 机器无此行（不误伤），NVLink 故障的 SXM 机有此行（正是要修正的情况）。
case "$PLATFORM" in
    *_PCIe)
        if [ -f "${OUT}/os/dmesg_full.log" ] && \
           grep -qiE "nvidia-nvlink:[[:space:]]+Nvlink Core is being initialized" "${OUT}/os/dmesg_full.log" 2>/dev/null; then
            PLATFORM="${PLATFORM%_PCIe}_SXM"
        fi
        ;;
esac
# HGX 机头标记（x86_64_head 等：PCIe Fabric 接模组，无本地 GPU；报告与验收清单使用专门文案）
HEAD_NODE=0
# v1.53.7：展示层「后缀段首字母大写」——x86_64_head → x86_64_Head。
#   **用户口径：只改后面部分**（架构前缀 x86_64 / aarch64 保持原样，不动）。
#   **只改展示**，PLATFORM 原值保持小写不变（机器可读的稳定标识；
#   JSON 的 "platform" 字段仍为原值，只有 platform_label 走 DISPLAY）。
#   注意：架构名本身含下划线（x86_64 / aarch64），所以先剥前缀再处理后缀；
#   且 SXM/OAM/PCIe 是缩写/含大写，必须原样保留，不能套「首字母大写」。
# 展示值转换：抽取为函数，供「旧采集平台纠偏」后重新计算（v1.54.37）
platform_display_for() {
    local _p="$1" _pfx="" _sfx=""
    case "$_p" in
        x86_64_*)  _pfx="x86_64_";  _sfx="${_p#x86_64_}" ;;
        aarch64_*) _pfx="aarch64_"; _sfx="${_p#aarch64_}" ;;
        *)         _pfx="";         _sfx="$_p" ;;
    esac
    case "$_sfx" in
        head) _sfx="Head" ;;
        none) _sfx="None" ;;
        SXM|OAM|PCIe) : ;;   # 缩写/专有大小写，保持原样
        *) _sfx="$(printf '%s' "${_sfx:0:1}" | tr '[:lower:]' '[:upper:]')${_sfx:1}" ;;
    esac
    printf '%s' "${_pfx}${_sfx}"
}
# 依当前 PLATFORM 刷新展示串与标签（纠偏后需再调用一次）
platform_refresh_labels() {
    PLATFORM_DISPLAY="$(platform_display_for "${PLATFORM}")"
    PLATFORM_LABEL="$PLATFORM_DISPLAY"
    HEAD_NODE=0
    case "$PLATFORM" in
        # v1.53.40：**厂商中立**——PEX Fabric 底座既可能接 NVIDIA HGX 模组，也可能接 AMD OAM 模组
        #   （实测 8×MI300X 的 G7768 M6 底座：PEX890xx×40 + 无本地 GPU）。原文案硬写「HGX 机头」，
        #   对 AMD 模组机头是错的。厂商可判定时（GPU_PLATFORM=nvidia/amd…）由报告段追加说明。
        *_head) HEAD_NODE=1; PLATFORM_LABEL="${PLATFORM_DISPLAY}（GPU 机头：PCIe Fabric 接模组，模组单独采集）" ;;
        *_OAM)  PLATFORM_LABEL="${PLATFORM_DISPLAY}（AMD OAM 模组：xGMI/Infinity Fabric 互联，v1.48.0）" ;;
    esac
}
PLATFORM_CORRECTED=""       # 非空 = 平台标识按日志纠偏过（旧采集），报告会附注
platform_refresh_labels
TIMESTAMP=$(grep -m1 "^Timestamp" "$SUMMARY" 2>/dev/null | cut -d':' -f2- | sed 's/^ //')

# ─── 采集耗时（summary 耗时统计段） ───
TIMING_TOTAL=$(grep -m1 "^总时长" "$SUMMARY" 2>/dev/null | awk '{print $3}')

# ─── XID 处置建议（v1.54.52）──────────────────────────────────────────────
#   XID 是 NVIDIA 官方故障码，不同码的处置**完全不同**：149 属 NVLink/Fabric 侧事件，
#   更新固件即可；79/48 才是卡或显存硬件问题。原先一律输出"需确认对应卡是否异常"，
#   客户看不出该报修还是该升级固件（实测 8×A100 机器 XID 149 被读成"显卡有故障"）。
xid_advice() {
    # v1.56.6（代码审查低-2）：原先「首个命中就 return」，一台机同时有 149 + 79 时只会给
    #   79 的建议，149（Fabric 事件，升级固件即可）的处置信息直接丢失。改为**逐码拼装**：
    #   硬件类（48/63/79/13/31）置顶，其次 Fabric/已纠正类，多段用「；」分隔并去重。
    local codes="${1:-}" c out="" hw="" ot="" n=0 seen=" "
    for c in $(printf '%s' "$codes" | tr ',;/ ' '\n\n\n\n'); do
        case "$c" in
            ''|*[!0-9]*) continue ;;
        esac
        case " ${seen:- } " in *" ${c} "*) continue ;; esac   # 同码只出一次（自审修正：原写 [$c] 永不命中）
        case "$c" in
            48) hw="${hw:+$hw；}XID 48 = 双比特 ECC（不可纠正）→ 显存硬件故障，建议报修" ;;
            79) hw="${hw:+$hw；}XID 79 = GPU 掉出总线 → 先查供电/PCIe 连接/散热，复采仍现按硬件故障报修" ;;
            63) hw="${hw:+$hw；}XID 63 = 显存行重映射 → 观察计数是否继续增长，持续增长则报修" ;;
            13|31) hw="${hw:+$hw；}XID ${c} = 显存/指令非法访问 → 先排查应用越界与驱动版本" ;;
            149) ot="${ot:+$ot；}XID 149 = NVLink/NVSwitch Fabric 管理事件（Nonfatal，非卡故障）→ 升级 GPU/NVSwitch 固件与驱动后复采" ;;
            94|95) ot="${ot:+$ot；}XID ${c} = 已纠正的单比特 ECC → 不中断业务，观察频率" ;;
            *) ot="${ot:+$ot；}XID ${c} = 需对照 NVIDIA XID 官方说明逐条核对" ;;
        esac
        seen="${seen}${c} "
        n=$((n+1))
    done
    out="${hw}${hw:+${ot:+；}}${ot}"       # 硬件类置顶，其余随后（同码已去重）
    if [ -z "$out" ]; then
        printf '%s' "需确认对应卡是否异常（对照 NVIDIA XID 官方说明逐条核对），复采仍现则现场复核"
        return 0
    fi
    printf '%s' "$out"
}

# ─── XID 严重度分档（v1.55.1）─────────────────────────────────────────────
#   XID 149 属 NVLink/NVSwitch **Fabric 管理事件**（NETIR_MFDE_EVENT，Nonfatal），
#   实测测试全过、不涉及卡与显存——按 WARN 计会把合格机判成「有条件通过」。
#   分档：任一码属硬件类 → warn；全部属提示类（Fabric/已纠正） → info；未知码 → warn（保守，不错放）。
xid_level() {
    local codes="${1:-}" c lvl=""
    for c in $(printf '%s' "$codes" | tr ',;/ ' '\n\n\n\n'); do
        case "$c" in
            ''|*[!0-9]*) continue ;;
            # 已纠正类（不中断业务）：94/95 单比特已纠正、38 内存已纠正
            94|95|38) lvl="${lvl}i" ;;
            # Fabric / 管理事件类：149 NVSwitch/NVLink 管理事件、119 GSP 相关、120 显示上下文
            149|119|120) lvl="${lvl}i" ;;
            # 其余（48 双bit ECC、62 页退役、63 行重映射、74 NVLink 错、79 掉总线、13/31 非法访问…）
            *) lvl="${lvl}w" ;;
        esac
    done
    case "$lvl" in
        *w*) printf 'warn' ;;
        *i*) printf 'info' ;;
        *)    printf 'warn' ;;
    esac
}

# ─── CPU 支持的内存速率上限（v1.56.0）──────────────────────────────────────
#   目的：内存「额定 6400 跑 5600」可能不是故障，而是 CPU 内存控制器上限。
#   实测 Dell XE9680 + Xeon Platinum 8580（Emerald Rapids）：DIMM 额定 6400，
#   Configured 5600 —— Intel 官方 8580 内存规格就是 DDR5 @ 5600 MT/s(1DPC)，BIOS 调不上去，
#   旧判据按 DIMM 额定比 → 7 台同型号机全部误报「内存运行速率降速，建议核查 BIOS」。
#   表按厂商公开规格整理（Intel ARK / AMD 官方），**只收能确认的型号族**；
#   未命中返回空 → 回退旧判据（按 DIMM 额定比，从严判 WARN），**禁止按数字段猜代际**。
#   v1.56.6（代码审查中-1）：原实现用 `空格+6xxx → 4800` 一概而论，把 Emerald Rapids 的
#   Gold 65xx 也算成 4800 —— 而 ARK 上 Gold 6526Y 是 **DDR5-5200**（1DPC）。低估 400 MT/s 的方向
#   是**漏报**：DIMM 5600 却只跑 5200 的机器会被判「已到 CPU 上限，属正常」，把真降速洗白。
#   现按代际拆精确：65xx(EMR Gold)=5200 / 6[0-4]xx(SPR Gold)=4800，其余未命中即回退。
cpu_mem_limit() {
    local m="${1:-}" u
    # 自审修正：lscpu/dmidecode 里型号可能写成 "XEON-GOLD-6526Y"，原来只认空格分隔 →
    #   连接符形式全部落到"未收录"。此处把 - _ 归一为空格，多空格压成单空格，再匹配。
    u=$(printf '%s' "$m" | tr 'a-z' 'A-Z' | tr -- '-_' '  ' | tr -s ' ' | sed 's/^ *//; s/ *$//')
    case "$u" in
        # ── Intel 6 代至强（Granite Rapids，型号带 P 后缀）──
        *[[:space:]]6[0-9][0-9][0-9]"P"*)                              printf '6400'; return 0 ;;
        # ── Intel 6 代能效核（Sierra Forest，型号带 E 后缀）──
        *[[:space:]]6[0-9][0-9][0-9]"E"*)                              printf '5600'; return 0 ;;
        # ── Intel 5 代 Platinum（Emerald Rapids 85xx–89xx）→ DDR5-5600 ──
        *[[:space:]]8[5-9][0-9][0-9]*)                                 printf '5600'; return 0 ;;
        # ── Intel 5 代 Gold（Emerald Rapids 65xx）→ DDR5-**5200**（ARK: Gold 6526Y）──
        *[[:space:]]65[0-9][0-9]*)                                     printf '5200'; return 0 ;;
        # ── Intel 4 代 Platinum（Sapphire Rapids 80xx–84xx，含 84xx+）→ DDR5-4800 ──
        *[[:space:]]8[0-4][0-9][0-9]*)                                 printf '4800'; return 0 ;;
        # ── Intel 4 代 Gold（Sapphire Rapids 63xx/64xx）→ DDR5-4800 ──
        *[[:space:]]6[0-4][0-9][0-9]*)                                 printf '4800'; return 0 ;;
        # ── Intel 4 代 Gold 5xxx / Silver 4xxx / Bronze 3xxx → DDR5-4800 ──
        *[[:space:]]5[0-9][0-9][0-9]*)                                 printf '4800'; return 0 ;;
        *[[:space:]]4[0-9][0-9][0-9]*)                                 printf '4800'; return 0 ;;
        *[[:space:]]3[0-9][0-9][0-9]*)                                 printf '4800'; return 0 ;;
        # ── AMD EPYC 9005（Turin）──
        *EPYC*9[0-9][0-9]5*)                                           printf '6000'; return 0 ;;
        # ── AMD EPYC 9004（Genoa / Bergamo）──
        *EPYC*9[0-9][0-9]4*)                                           printf '4800'; return 0 ;;
        # ── AMD EPYC 7003/7002（Milan / Rome）──
        *EPYC*7[0-9][0-9]3*)                                           printf '3200'; return 0 ;;
        *EPYC*7[0-9][0-9]2*)                                           printf '3200'; return 0 ;;
    esac
    # 无厂商前缀的纯型号（如 lscpu 只给 "6526Y"）：按同一张表兜底匹配一次
    case "$u" in
        6[0-9][0-9][0-9]P) printf '6400'; return 0 ;;
        6[0-9][0-9][0-9]E) printf '5600'; return 0 ;;
        8[5-9][0-9][0-9]*)  printf '5600'; return 0 ;;
        65[0-9][0-9]*)      printf '5200'; return 0 ;;
        8[0-4][0-9][0-9]*)  printf '4800'; return 0 ;;
        6[0-4][0-9][0-9]*)  printf '4800'; return 0 ;;
        5[0-9][0-9][0-9]*)  printf '4800'; return 0 ;;
        4[0-9][0-9][0-9]*)  printf '4800'; return 0 ;;
        3[0-9][0-9][0-9]*)  printf '4800'; return 0 ;;
    esac
    # 未收录型号：返回空 → 调用方回退「按 DIMM 额定判」，宁可多报 WARN 也不猜
    printf ''
}
