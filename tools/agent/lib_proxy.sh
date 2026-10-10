#!/bin/bash
# =============================================================================
# lib_proxy.sh — 代理动态探测 + 直连/代理兜底（agent 脚本共用）
# tools/agent/lib_proxy.sh
#
# 为什么需要它：
#   本机 GitHub 直连时好时抖，代理端口**每次启动都会变**（见过 31561/62102）。
#   原实现只有 git_push.sh 会动态探测端口，agent_sync.sh 完全没有 —— 于是
#   「同步」在直连失败时只能拿到本地缓存、报出假的 "ahead 0 · behind 0"；
#   repo_realign.sh 又另写了一套（还不防 pgrep 自匹配），三处逻辑分叉。
#   本库把判据收敛到一处，供三个脚本 source（对齐 AGENTS 第 8 条：
#   同一判据不得多条路径、改一处漏一处）。
#
# 用法:
#   source "$(dirname "$0")/lib_proxy.sh"
#   proxy="$(detect_proxy)"                 # → http://127.0.0.1:<port> 或空
#   git_net_run fetch origin main           # 先直连，失败自动走代理
#   echo "$GIT_NET_USED_PROXY"              # 上一条用了代理则记在这里（空=直连）
#
# 环境变量:
#   GIT_PROXY_URL  显式指定代理（跳过探测，便于排障/固化）
# =============================================================================

# 探测的进程名（Windows 与 Linux/WSL 通用）
PROXY_PROC_NAMES=("v2ray" "xray" "clash")

detect_env() {
    local os uname_out
    uname_out="$(uname -s 2>/dev/null)"
    case "$uname_out" in
        MINGW*|MSYS*|CYGWIN*) os="git-bash" ;;
        Linux)
            if grep -qi "microsoft" /proc/version 2>/dev/null; then os="wsl"
            else os="linux"; fi ;;
        *) os="unknown" ;;
    esac
    echo "$os"
}
ENV_NAME="${ENV_NAME:-$(detect_env)}"

# detect_proxy: 输出 http://127.0.0.1:<port>；探不到则输出空串（调用方须判空）
detect_proxy() {
    # 显式指定优先
    if [ -n "${GIT_PROXY_URL:-}" ]; then echo "$GIT_PROXY_URL"; return 0; fi

    local pid="" port=""
    # Windows（tasklist CSV + grep 过滤；MSYS 下 //FI 转义不生效——v1.36.3 教训）
    if [ "$ENV_NAME" = "git-bash" ]; then
        for p in "${PROXY_PROC_NAMES[@]}"; do
            pid="$(tasklist /FO CSV 2>/dev/null | grep -iE "\"${p}\.exe\"" | head -1 | cut -d'"' -f4)"
            [ -n "$pid" ] && [ "$pid" != "0" ] && break
        done
        if [ -n "$pid" ] && [ "$pid" != "0" ]; then
            port="$(netstat -ano 2>/dev/null | grep "LISTENING" | grep "127.0.0.1:" | grep "$pid" | head -1 | awk '{print $2}' | cut -d: -f2)"
        fi
    else
        # Linux/WSL
        # pgrep -f 自匹配陷阱：探测命令自身命令行含 "v2ray" 字符串会被匹配（v1.37.3 实测）
        # 用 [v]2ray 正则字符类技巧排除自身；WSL 内再尝试 Windows 侧 tasklist（interop）
        pid="$(pgrep -f "[v]2ray|[x]ray|[c]lash" 2>/dev/null | head -1)"
        if [ -z "$pid" ] && [ -x /mnt/c/Windows/System32/tasklist.exe ]; then
            for p in "${PROXY_PROC_NAMES[@]}"; do
                pid="$(/mnt/c/Windows/System32/tasklist.exe /FO CSV 2>/dev/null | grep -iE "\"${p}\.exe\"" | head -1 | cut -d'"' -f4)"
                [ -n "$pid" ] && [ "$pid" != "0" ] && break
            done
            if [ -n "$pid" ] && [ "$pid" != "0" ]; then
                port="$(/mnt/c/Windows/System32/netstat.exe -ano 2>/dev/null | grep "LISTENING" | grep "127.0.0.1:" | grep "$pid" | head -1 | awk '{print $2}' | cut -d: -f2)"
            fi
        fi
        if [ -n "$pid" ] && [ -z "$port" ]; then
            port="$(ss -tlnp 2>/dev/null | grep "127.0.0.1:" | grep "pid=$pid" | head -1 | awk '{print $4}' | cut -d: -f2)"
            [ -z "$port" ] && port="$(netstat -tlnp 2>/dev/null | grep "127.0.0.1:" | grep "$pid" | head -1 | awk '{print $4}' | cut -d: -f2)"
        fi
    fi
    if [ -n "$port" ] && [ "$port" != "0" ]; then
        echo "http://127.0.0.1:${port}"
    fi
    return 0
}

# git_net_run <git 子命令...>
#   先直连跑一次；失败则探测代理并重试一次。
#   成功输出 git 的 stdout+stderr；返回码为最后一次尝试的退出码。
#   副作用：GIT_NET_USED_PROXY 记录本次是否走了代理（供调用方打印提示）。
git_net_run() {
    local out rc proxy
    GIT_NET_USED_PROXY=""
    out="$(git "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$out"
        return 0
    fi
    proxy="$(detect_proxy)"
    if [ -n "$proxy" ]; then
        out="$(git -c http.proxy="$proxy" "$@" 2>&1)"; rc=$?
        if [ "$rc" -eq 0 ]; then
            GIT_NET_USED_PROXY="$proxy"
            printf '%s\n' "$out"
            return 0
        fi
    fi
    printf '%s\n' "$out"
    return "$rc"
}
