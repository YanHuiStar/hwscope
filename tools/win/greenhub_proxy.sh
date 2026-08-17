#!/bin/bash
# greenhub_proxy.sh — 动态获取 GreenHub(v2ray) 代理端口
# 背景：GreenHub 重启后监听端口随机漂移，config 端口可能滞后于实际监听，
#       直连失败时需先动态探测可用代理端口再走代理。
#
# 用法:
#   greenhub_proxy.sh          → 输出可用代理地址（http://127.0.0.1:<port>），无可用则退出 1
#   greenhub_proxy.sh -t       → 测试模式：打印每个候选端口的连通性
#
# 依赖: curl（连通性测试）、tasklist/netstat（Windows 进程/端口探测）、git-bash
# 平台: Windows + git-bash（项目 tools/win/ 配套运维脚本）

CFG="/c/Users/15707/AppData/Roaming/GreenHub/v2ray-config.json"
TEST_URL="https://github.com"
TEST_MODE=0
[ "$1" = "-t" ] && TEST_MODE=1

# ── 候选端口集合（去重）：config 端口 + v2ray 进程实际监听端口 ──
candidates=()

cfg_port=$(grep -oE '"port":[0-9]+' "$CFG" 2>/dev/null | head -1 | grep -oE '[0-9]+')
[ -n "$cfg_port" ] && candidates+=("$cfg_port")

v2ray_pid=$(tasklist //FO CSV 2>/dev/null | grep -i v2ray | head -1 | grep -oE '"[0-9]+"' | tr -d '"')
if [ -n "$v2ray_pid" ]; then
    while IFS= read -r line; do
        port=$(echo "$line" | grep -oE '127\.0\.0\.1:[0-9]+|0\.0\.0\.0:[0-9]+' | grep -oE '[0-9]+$')
        [ -n "$port" ] && candidates+=("$port")
    done < <(netstat -ano 2>/dev/null | grep -i LISTENING | grep "$v2ray_pid")
fi

# 去重排序
candidates=($(printf '%s\n' "${candidates[@]}" | sort -un))

[ "$TEST_MODE" -eq 1 ] && echo "候选端口: ${candidates[*]:-无}"

for port in "${candidates[@]}"; do
    if curl -sI --connect-timeout 3 -x "http://127.0.0.1:${port}" "$TEST_URL" 2>/dev/null | head -1 | grep -qi "HTTP"; then
        [ "$TEST_MODE" -eq 1 ] && echo "[OK] 127.0.0.1:${port} 可用"
        echo "http://127.0.0.1:${port}"
        exit 0
    else
        [ "$TEST_MODE" -eq 1 ] && echo "[--] 127.0.0.1:${port} 不可用"
    fi
done

[ "$TEST_MODE" -eq 1 ] && echo "结论: 无可用代理（GreenHub 未运行或直连可达）"
exit 1
