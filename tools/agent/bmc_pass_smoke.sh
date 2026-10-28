#!/bin/bash
# bmc_pass_smoke.sh — BMC 密码通道冒烟测试（v1.54.0）
#
# 为什么需要：BMC 密码的读取与转发是**环境敏感**逻辑 —— tty 有无、stdin 是否管道、
#   sudo 是否剥离环境变量，三种条件在不同机器上组合不同，同一份代码可能这台能跑那台卡死
#   （v1.53.45 就踩过：优先读 /dev/tty 在无交互终端时永久阻塞）。这类代码"验证过一次"
#   不等于"在别的机器也对"，故用本地 bash 仿真各分支，断言变量最终值。
#
# 用法： bash tools/agent/bmc_pass_smoke.sh
# 环境： Linux / WSL（需要真 bash。git-bash 的 /dev/tty 与管道语义不同，结论不可用）
# 前提： 项目完整副本；脚本会在 $(mktemp -d) 下生成临时输出，不碰真实采集目录
# 退出码： 0 全部通过 / 1 有失败项

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$ROOT" || { echo "[FAIL] 无法进入项目根目录"; exit 1; }

PASS=0; FAIL=0
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

ok()   { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

run_case() {   # run_case <名称> <stdin来源> <额外env> <给参数?> <期望:nowarn|warn|noprompt> <期望exitzero?>
    local name="$1" stdin_src="$2" extraenv="$3" args="$4" expect="$5"
    local out="${TMPD}/o_$(echo "$name" | tr -cd 'a-zA-Z0-9').log"
    local cmd="timeout 120 bash hwscope.sh ${args} --modules os --output ${TMPD}/out_$$ > '$out' 2>&1"
    if [ -n "$extraenv" ]; then
        # v1.54.38（审查 L4）：去掉 eval 的二次展开——本次 $cmd 由内部构造，但仍按"不做二次
        #   解释"处理：env 前缀单独拼、命令体交给 sh -c 执行一次
        env $extraenv sh -c "$cmd" < "$stdin_src"
    else
        sh -c "$cmd" < "$stdin_src"
    fi
    local rc=$?
    # 注意：不能写 `grep -c ... || echo 0` —— grep -c 无匹配时**已经输出 0**且 exit 1，
    #   || 再补一个 0 会得到 "0\n0"，后面 [ -eq ] 直接报 integer expression expected
    local warns; warns=$(grep -c '未输入' "$out" 2>/dev/null) || true; warns=${warns:-0}
    case "$expect" in
        nowarn)   [ "$warns" -eq 0 ] && ok "$name（无未输入警告）" || bad "$name（期望无警告，实际 $warns 条）" ;;
        warn)     [ "$warns" -ge 1 ] && ok "$name（按预期警告并继续）" || bad "$name（期望警告，实际 0 条）" ;;
        noprompt) [ "$warns" -eq 0 ] && ok "$name（未触发密码提示）" || bad "$name（不该提示却提示了）" ;;
    esac
    # 无论哪个分支都必须能跑完（不阻塞）——这是 v1.53.45 的事故点
    if [ "$rc" -eq 124 ]; then
        bad "$name（超时 124 = 阻塞，这正是要防的）"
    elif [ "$rc" -ne 0 ]; then
        bad "$name（退出码 $rc，非 0）"
    else
        ok "$name（退出码 0，未阻塞）"
    fi
}

echo "═══ hwscope.sh 密码读取分支 ═══"
printf 'pw123\n' > "${TMPD}/pw.txt"

# ① 管道喂密码（remote_collect 的传递路径）
run_case "管道喂密码" "${TMPD}/pw.txt" "" "--bmc-ip 10.0.0.1" nowarn
# ② stdin 为 /dev/null（无输入）→ 应警告一次后继续，不得阻塞
run_case "无输入降级" "/dev/null" "" "--bmc-ip 10.0.0.1" warn
# ③ 环境里已有密码（remote_collect 的 read+export 路径）→ 不应再提示
run_case "已有密码不重复提示" "/dev/null" "BMC_PASS=preset" "--bmc-ip 10.0.0.1" nowarn
# ④ 不给 --bmc-ip → 完全不涉及 BMC，行为与旧版一致
run_case "不给BMC参数" "/dev/null" "" "" noprompt

echo ""
echo "═══ remote_collect.sh 的密码变量构造（静态断言）═══"
RC=tools/remote_collect.sh
# P2-1：必须按「给了哪个 IP 就 read 哪个变量」构造，不能无条件 read BMC_PASS
if grep -q '_reads="${_reads}read -r BMC_PASS' "$RC" && \
   grep -q '_reads="${_reads}read -r HGX_BMC_PASS' "$RC"; then
    ok "P2-1 两个 BMC 变量分别按 IP 条件拼接"
else
    bad "P2-1 未找到按 IP 分别 read 的构造（旧实现会无条件 read BMC_PASS）"
fi
# P2-2：两个 BMC 必须分别提示
if grep -q 'HGX 基板 BMC 密码（' "$RC" && grep -q '主机 BMC 密码（' "$RC"; then
    ok "P2-2 两个 BMC 分别提示密码"
else
    bad "P2-2 未分别提示（旧实现共用一个密码）"
fi
# 密码不得用 printf "$var" 形式喂（% 与 \ 会被当格式符解析）——判「坏模式不存在」比正面匹配稳
if grep -qE 'printf +"\$\{?(_bmc_pw|_hgx_pw)' "$RC"; then
    bad "密码用 printf \"\$var\" 传递（密码里的 % 和 \\ 会被当格式符）"
else
    ok "密码不用 printf \"\$var\" 形式（格式符安全）"
fi

echo ""
echo "═══ 汇总：PASS=$PASS  FAIL=$FAIL ═══"
[ "$FAIL" -eq 0 ] && { echo "全部通过"; exit 0; } || { echo "有失败项"; exit 1; }
