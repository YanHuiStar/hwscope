#!/bin/bash
# =============================================================================
# 提交前敏感标识自检 — tools/agent/sn_check.sh
#
# 背景: 隐私红线要求"真实采集数据（机器 SN 等）不进 git"。实践反复证明只靠文字规矩
#       不够——本会话就两次发现真实 SN 进了提交正文/代码注释（一次我自己、一次协作
#       agent），且都已推送、需要重写历史才能清除。故把检查做成可执行的钩子。
#
# 用法:
#   bash tools/agent/sn_check.sh                 # 查暂存区 + 待推送提交（相对 origin/main）
#   bash tools/agent/sn_check.sh --staged        # 只查暂存区（pre-commit hook 调用）
#   bash tools/agent/sn_check.sh --commit-msg <文件>   # 查提交信息（commit-msg hook 调用）
#   bash tools/agent/sn_check.sh --all-history   # 扫全历史（发布/推送前体检）
#   bash tools/agent/sn_check.sh --install-hook  # 安装 git hooks（本地 .git/hooks，不进仓库）
#
# 退出码: 0=干净；1=发现疑似真实 SN（提交应被拦下）
#
# 判定模式（厂商前缀序列号 / 长数字序列号），并排除下列**非敏感**命名（它们与真实机器
# 标识长得像，但属于产品/系统标识，代码与文档中必须保留）:
#   NVD0000000072             网卡 PSID 值（同固件所有卡一致，等同部件号）
#   1951526575073             Mellanox 占位序列号（驱动对多卡返回相同值，需识别并置空）
#   C0000142                  Windows fork 失败错误码
#   206141652992              字节数（192GB 换算）
#   113-M3000100-102          VBIOS 版本号片段
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR" || exit 1

MODE="default"; MSGFILE=""
for a in "$@"; do
    case "$a" in
        --staged)      MODE="staged" ;;
        --commit-msg)  MODE="commitmsg"; MSGFILE="$2"; shift ;;
        --all-history) MODE="history" ;;
        --install-hook) MODE="install" ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
    shift 2>/dev/null || true
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# 疑似 SN 形态（宽匹配，随后用长度门限收敛）
PATTERN='\b[A-Z]{1,4}[0-9]{3,}[A-Z0-9]{0,8}\b|\b[0-9]{9,13}\b|\b([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}\b|\b[0-9a-fA-F]{12}\b'
# 非敏感排除：这些与真实 SN 长得像但属产品/系统标识，代码与文档必须保留
#   NVDxxxxxxx 网卡 PSID 值 | MCX… 网卡部件号 | MT/MLX… 芯片与型号 | SAS3xxx RAID 芯片
#   FAKE… 项目脱敏示例 | 1951526575073 Mellanox 占位序列号 | C0000142 Windows 错误码
#   206141652992 字节数 | 1000000000/1048576 换算常数 | 113-M300xxxx-xxx VBIOS 片段
#   版本号(x.y.z) | shields 徽章 | 日期戳
NOISE='NVD[0-9]{6,}|MCX[0-9A-Z-]+|MT[0-9]{4}|MLX[0-9]{6}|SAS[0-9]{4}|BR[0-9]{3}|GA[0-9]{3}|SC[0-9]{4}|MTFD[A-Z0-9]+|FAKE[A-Z]*[0-9]*|1951526575073|C0000142|206141652992|1000000000|1048576|113-M300[0-9]{4}-[0-9]+|[0-9]+\.[0-9]+\.[0-9]+|shields\.io|img\.shields|2026081[0-9]|2026091[0-9]|aa-bb-cc-dd-ee-ff|AABBCCDDEEFF|FFFFFFFFFFFF|000000000000|\b20[0-9]{12}\b|\bSN[0-9]{6,}\b'

# 长度门限收敛（关键设计）：产品型号普遍短（B300/A2000/MI300X/SC2163/GA100/C500 ≤6 字符），
# 真实机箱/部件 SN 普遍长（实测形态：4 字母+3 数字+4 字符 = 11；单字母+6 数字+混合 = 14；
# 2 字母+7 数字+5 字符 = 14；3 字母+数字+字母 = 14；13 位纯数字）。故：
#   字母数字混合 token 需 ≥10 字符；纯数字 token 需 9-13 位 —— 否则不算疑似 SN
sn_filter() {   # stdin=带行号文本，输出=含高置信 SN 的行
    awk '
        {
            line = $0; keep = ""
            while (match(line, /\<[A-Z]{1,4}[0-9]{3,}[A-Z0-9]{0,8}\>|\<[0-9]{9,13}\>|\<([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}\>|\<[0-9a-fA-F]{12}\>/)) {
                tok = substr(line, RSTART, RLENGTH)
                # MAC 形态直接算高置信（带分隔符或 12 位 hex）
                if (tok ~ /^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$/ || tok ~ /^[0-9a-fA-F]{12}$/) { keep = "yes"; break }
                if ((tok ~ /^[0-9]+$/ && length(tok) >= 9) || (tok ~ /[A-Z]/ && length(tok) >= 10)) { keep = "yes"; break }
                line = substr(line, RSTART + RLENGTH)
            }
            if (keep == "yes") print
        }'
}

scan_text() {   # $1=描述  stdin=待扫文本
    local desc="$1" hits
    hits=$(grep -nE "$PATTERN" 2>/dev/null | grep -vE "$NOISE" | sn_filter)
    if [ -n "$hits" ]; then
        echo -e "${RED}[SN-CHECK] ${desc} 命中疑似真实 SN:${NC}"
        echo "$hits" | head -12 | sed 's/^/    /'
        return 1
    fi
    return 0
}

RC=0
case "$MODE" in
    staged)
        # pre-commit：暂存区新增行 + 暂存的文件名
        if ! git diff --cached --unified=0 2>/dev/null | grep '^+' | sed 's/^+//' | scan_text "暂存改动"; then RC=1; fi
        if ! git diff --cached --name-only 2>/dev/null | scan_text "暂存文件名"; then RC=1; fi
        ;;
    commitmsg)
        [ -z "$MSGFILE" ] || [ ! -f "$MSGFILE" ] && exit 0
        # 提交信息：允许大写语义名（B300-sample-a 等），拦截真实 SN
        if ! scan_text "提交信息" < "$MSGFILE"; then RC=1; fi
        ;;
    history)
        echo "[INFO] 扫描全历史（内容 + 提交信息 + 文件名）..."
        if ! git log --all --format="%s%n%b" 2>/dev/null | scan_text "历史提交信息"; then RC=1; fi
        if ! git rev-list --all 2>/dev/null | while read -r c; do git grep -hE "$PATTERN" "$c" -- 2>/dev/null; done | grep -vE "$NOISE" | scan_text "历史文件内容"; then RC=1; fi
        if ! git log --all --name-only --pretty=format: 2>/dev/null | scan_text "历史文件名"; then RC=1; fi
        ;;
    default)
        echo "[INFO] 检查暂存区 + 待推送提交..."
        if ! git diff --cached --unified=0 2>/dev/null | grep '^+' | sed 's/^+//' | scan_text "暂存改动"; then RC=1; fi
        if git rev-parse --verify origin/main >/dev/null 2>&1; then
            if ! git log origin/main..HEAD --format="%s%n%b" 2>/dev/null | scan_text "待推送提交信息"; then RC=1; fi
        fi
        ;;
    install)
        mkdir -p .git/hooks
        cat > .git/hooks/pre-commit <<'HOOK'
#!/bin/sh
# 由 tools/agent/sn_check.sh --install-hook 生成（仅本地，不进仓库）
exec "$(git rev-parse --show-toplevel)/tools/agent/sn_check.sh" --staged
HOOK
        cat > .git/hooks/commit-msg <<'HOOK'
#!/bin/sh
# 由 tools/agent/sn_check.sh --install-hook 生成（仅本地，不进仓库）
exec "$(git rev-parse --show-toplevel)/tools/agent/sn_check.sh" --commit-msg "$1"
HOOK
        chmod +x .git/hooks/pre-commit .git/hooks/commit-msg
        echo -e "${GREEN}[OK]${NC} 已安装 .git/hooks/{pre-commit,commit-msg}（本地生效，不影响他人；"
        echo "     需要临时跳过: git commit --no-verify）"
        exit 0
        ;;
esac

if [ "$RC" -eq 0 ]; then
    echo -e "${GREEN}[OK]${NC} 未发现疑似真实 SN"
else
    echo ""
    echo -e "${YELLOW}处理建议:${NC}"
    echo "  1. 真实机器标识改用**语义名**（如 B300-sample-a / H200-sample），不要写进代码注释、"
    echo "     文档示例或提交信息；"
    echo "  2. 若命中项确属产品/系统标识（PSID、占位序列号、错误码、版本号），把它加入本脚本的"
    echo "     NOISE 排除表并说明原因；"
    echo "  3. 已提交内容需清除时: git filter-repo --replace-text / --message-callback，"
    echo "     再 force push（流程见 tools/agent/README.md 与 AGENTS.md 隐私红线段）。"
fi
exit $RC
