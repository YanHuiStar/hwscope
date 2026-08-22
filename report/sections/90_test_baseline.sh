#!/bin/bash
# =============================================================================
# HwScope - 变量解析：压测归档 + 报告基线对比
# report/sections/90_test_baseline.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
# ─── 压测归档（--test-dir；test/test_common.sh 写 manifest.txt 解耦） ───
TEST_DETAILS=""; TEST_DIR_LABEL=""
if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
    TEST_DIR_LABEL="$TEST_DIR"
    _tsum=""
    [ -f "${TEST_DIR}/manifest.txt" ] && _tsum=$(grep '^summary=' "${TEST_DIR}/manifest.txt" | tail -1 | cut -d= -f2-)
    [ -z "$_tsum" ] && _tsum=$(basename "$(ls "${TEST_DIR}"/*.log 2>/dev/null | head -1)")
    _tsum="${TEST_DIR}/${_tsum}"
    if [ -f "$_tsum" ]; then
        # test_record 行格式: [HH:MM:SS] <name>: <状态> (<Ns>) — 详情: <file>
        TEST_DETAILS=$(grep -E "^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]" "$_tsum" 2>/dev/null \
            | grep -vE "测试开始|测试结束" \
            | sed -E 's/^\[[0-9:]+\] //; s/ \(([0-9]+)s\) — 详情: (.*)$/|\1|\2/; s/: /|/')
    fi
fi

# ─── FLD 诊断日志（--fld-dir；NVIDIA DGX Field Diagnostic 日志目录 logs-<TS>/，v1.37.0） ───
# 数据源: run.log（进度行 "Testing <test> OK/SKIPPED [耗时]" + 矩阵行 "MODS-... | test | ... | component | OK"）
# summary.csv 列5 含逗号（"GPU, PCIE, Nvlink, I2C"）无法可靠逗号解析，仅作兜底；unified_summary.json 兜底 finalResult
FLD_SUMMARY=""; FLD_RESULT=""; FLD_DETAILS=""; FLD_DIR_LABEL=""
if [ -n "$FLD_DIR" ] && [ -d "$FLD_DIR" ]; then
    FLD_DIR_LABEL="$FLD_DIR"
    _fld_run="${FLD_DIR}/run.log"
    # ── run.log 头信息 ──
    _fld_ver=$(grep -m1 '^Version' "$_fld_run" 2>/dev/null | awk '{print $2}')
    _fld_base=$(grep -m1 '^Base diag' "$_fld_run" 2>/dev/null | awk '{print $3}')
    _fld_prod=$(grep -m1 '^Product' "$_fld_run" 2>/dev/null | sed 's/^Product[[:space:]]*//')
    _fld_sn=$(grep -m1 '^Serial Number' "$_fld_run" 2>/dev/null | awk '{print $3}')
    _fld_total=$(grep -m1 '^End time' "$_fld_run" 2>/dev/null | grep -oE '\[ [0-9:]+s elapsed \]' | head -1)
    FLD_RESULT=$(grep -m1 '^Final Result:' "$_fld_run" 2>/dev/null | awk '{print $3}')
    if [ -z "$FLD_RESULT" ] && [ -f "${FLD_DIR}/unified_summary.json" ]; then
        FLD_RESULT=$(grep -oE '"finalResult": *"[A-Za-z]+"' "${FLD_DIR}/unified_summary.json" 2>/dev/null | head -1 | sed 's/.*"\([A-Za-z]*\)"$/\1/')
    fi
    # ── 组件级明细：run.log 矩阵行（MODS-/DGX- 前缀，| 分隔无歧义） ──
    if [ -f "$_fld_run" ]; then
        FLD_DETAILS=$(grep -E '^(MODS-[0-9]+|DGX-[0-9]+) +\|' "$_fld_run" 2>/dev/null | awk -F'|' '{
            vid=$2; gsub(/^ +| +$/,"",vid)
            comp=$5; gsub(/^ +| +$/,"",comp)
            cid=$6; gsub(/^ +| +$/,"",cid)
            res=$7; gsub(/^ +| +$/,"",res)
            if (vid != "") printf "%s|%s%s|%s|\n", vid, comp, (cid!=""?" "cid:""), res
        }')
        # 兜底：矩阵行为空（部分版本无矩阵输出）→ 进度行 "Testing <test> OK/SKIPPED [耗时]" 作测试级结果
        if [ -z "$FLD_DETAILS" ]; then
            FLD_DETAILS=$(grep -E '^Testing ' "$_fld_run" 2>/dev/null | sed -E 's/^Testing ([^ ]+) +(OK|SKIPPED|FAIL|ERROR|PASS).*/|\1||\2|/' | grep -E '^\|[^|]+\|\|')
        fi
    fi
    # ── 概览行（缺字段容忍，全缺 = 目录非 FLD 日志） ──
    if [ -n "$_fld_ver" ] || [ -n "$FLD_DETAILS" ]; then
        FLD_SUMMARY="诊断 ${_fld_ver:-N/A}${_fld_base:+（base ${_fld_base}）}· ${_fld_prod:-N/A} · SN ${_fld_sn:-N/A}${_fld_total:+ · 耗时 ${_fld_total}}"
    fi
fi

# ─── 报告基线对比（--baseline <历史采集目录>；读两侧数据，输出时序差异） ───
BASELINE_COMPARE=""; BASELINE_DIR_LABEL=""; BASELINE_COMPARE_NOTE=""
if [ -n "$BASELINE_DIR" ]; then
    BL_JSON="${BASELINE_DIR}/hwscope_report.json"
    if [ ! -f "$BL_JSON" ]; then
        echo -e "${YELLOW}[WARN] 基线目录缺少 hwscope_report.json: ${BASELINE_DIR}，跳过基线对比${NC}"
    else
        BASELINE_DIR_LABEL="$BASELINE_DIR"
        # JSON 块内字段提取（依赖 report.sh 固定缩进格式；零新依赖）
        # 注意：单行 JSON 对象含多个键值对（如 details 数组行），必须用 index() 定位
        # 目标键后取其后值；贪心 sub(/.*: *"/) 会误取行内最后一个键的值（v1.30.0 踩坑）
        bl_get() {   # $1=块 $2=键 → 标量值
            awk -v blk="$1" -v key="$2" '
                $0 ~ "^  \"" blk "\": \\{" { inblk=1; next }
                inblk && /^  \},?$/ { exit }
                inblk && (idx = index($0, "\"" key "\":")) {
                    rest = substr($0, idx + length(key) + 3)
                    if (rest ~ /^[[:space:]]*"/) { sub(/^[[:space:]]*"/, "", rest); sub(/".*/, "", rest) }
                    else { sub(/^[[:space:]]*/, "", rest); sub(/,.*/, "", rest) }
                    gsub(/^ +| +$/, "", rest)
                    if (rest != "") { print rest; exit }
                }
            ' "$BL_JSON" 2>/dev/null
        }
        bl_list() {  # $1=块 $2=键 → 块内数组对象中该键的全部取值（逐行）
            awk -v blk="$1" -v key="$2" '
                $0 ~ "^  \"" blk "\": \\{" { inblk=1; next }
                inblk && /^  \},?$/ { exit }
                inblk && (idx = index($0, "\"" key "\":")) {
                    rest = substr($0, idx + length(key) + 3)
                    sub(/^[[:space:]]*"/, "", rest); sub(/".*/, "", rest)
                    gsub(/^ +| +$/, "", rest)
                    if (rest != "" && rest != "N/A") print rest
                }
            ' "$BL_JSON" 2>/dev/null
        }
        # 集合差异行：$1=项名 $2=当前列表 $3=基线列表 → 输出 新增/移除/一致 行
        set_diff_rows() {
            local item="$1" cur="$2" base="$3" c b added removed
            c=$(printf '%s\n' $cur | grep -v "^$" | grep -v '^—$' | sort -u)
            b=$(printf '%s\n' $base | grep -v "^$" | grep -v '^—$' | sort -u)
            [ -z "$c" ] && [ -z "$b" ] && return
            if [ -z "$c" ]; then BASELINE_COMPARE="${BASELINE_COMPARE}${item}|移除|—|$(echo "$b" | tr '\n' ',' | sed 's/,$//')"$'\n'; return; fi
            if [ -z "$b" ]; then BASELINE_COMPARE="${BASELINE_COMPARE}${item}|新增|$(echo "$c" | tr '\n' ',' | sed 's/,$//')|—"$'\n'; return; fi
            added=$(comm -23 <(echo "$c") <(echo "$b") | tr '\n' ',' | sed 's/,$//')
            removed=$(comm -13 <(echo "$c") <(echo "$b") | tr '\n' ',' | sed 's/,$//')
            [ -n "$added" ] && BASELINE_COMPARE="${BASELINE_COMPARE}${item}|新增|${added}|—"$'\n'
            [ -n "$removed" ] && BASELINE_COMPARE="${BASELINE_COMPARE}${item}|移除|—|${removed}"$'\n'
            [ -z "$added" ] && [ -z "$removed" ] && BASELINE_COMPARE="${BASELINE_COMPARE}${item}|一致|—|—"$'\n'
        }
        # 标量对比行：$1=项名 $2=当前值 $3=基线值（数值口径先归一：取 "/" 前部分）
        bl_cmp() {
            local item="$1" cur_v="${2:-—}" base_v="${3:-—}"
            [ -z "$cur_v" ] && cur_v="—"; [ -z "$base_v" ] && base_v="—"
            cur_v="${cur_v%%/*}"; base_v="${base_v%%/*}"
            [ "$cur_v" = "—" ] && [ "$base_v" = "—" ] && return
            local st="一致"; [ "$cur_v" != "$base_v" ] && st="变化"
            BASELINE_COMPARE="${BASELINE_COMPARE}${item}|${st}|${cur_v}|${base_v}"$'\n'
        }
        # ── 标量对比 ──
        bl_cmp "BIOS" "${BIOS_VERSION:-}" "$(bl_get motherboard bios)"
        bl_cmp "CPU 型号" "${CPU_MODEL:-}" "$(bl_get cpu model)"
        bl_cmp "内存总量" "${MEM_TOTAL_PHYS:-${MEM_TOTAL:-}}" "$(bl_get memory total)"
        bl_cmp "内存插槽(已插)" "${MEM_POPULATED:-}" "$(bl_get memory populated)"
        bl_cmp "GPU 数量" "${GPU_COUNT:-}" "$(bl_get gpu count)"
        bl_cmp "GPU VBIOS" "${GPU_VBIOS:-}" "$(bl_get gpu vbios)"
        bl_cmp "BMC 固件" "${BMC_FW:-}" "$(bl_get bmc firmware)"
        # ── 集合对比（SN 级：新增/移除即部件变更） ──
        _cur_gpu_sn=$(echo "${GPU_SERIALS:-}" | tr ',' '\n')
        set_diff_rows "GPU 序列号" "$_cur_gpu_sn" "$(bl_list gpu serial)"
        _cur_disk_sn=$(echo "$DISK_DETAILS" | awk -F'|' '$1!=""{print $5}')
        set_diff_rows "磁盘序列号" "$_cur_disk_sn" "$(bl_list storage serial)"
        _cur_nic_sn=$(echo "$NIC_DETAILS" | awk -F'|' '$1!=""{print $4}')
        set_diff_rows "网卡序列号" "$_cur_nic_sn" "$(bl_list network serial)"
        # ── 固件版本逐项对比（component|device → version） ──
        declare -A _fw_cur _fw_base
        if [ -n "$FW_COMPLIANCE_DETAILS" ]; then
            while IFS='|' read -r _fc _fd _fcur _fbase _fst _fnote; do
                [ -z "$_fc" ] && continue
                _fw_cur["${_fc}|${_fd}"]="$_fcur"
            done < <(printf '%s\n' "$FW_COMPLIANCE_DETAILS")
        fi
        while IFS= read -r _fl; do
            _fc=$(echo "$_fl" | sed -n 's/.*"component": "\([^"]*\)".*/\1/p')
            _fd=$(echo "$_fl" | sed -n 's/.*"device": "\([^"]*\)".*/\1/p')
            _fv=$(echo "$_fl" | sed -n 's/.*"current": "\([^"]*\)".*/\1/p')
            [ -n "$_fc" ] && [ -n "$_fd" ] && [ -n "$_fv" ] && _fw_base["${_fc}|${_fd}"]="$_fv"
        done < <(grep -E '^\s*\{\s*"component"' "$BL_JSON")
        # 合并 key 列表（注意：key 含空格，必须逐行 read，禁止 for 循环单词拆分）
        while IFS= read -r _k; do
            [ -z "$_k" ] && continue
            _cv="${_fw_cur[$_k]:-}"; _bv="${_fw_base[$_k]:-}"
            # 显示名去除 key 内分隔符（组件|设备 → "组件 设备"），避免破坏 | 分隔行
            _kdisp="${_k//|/ }"
            if [ -z "$_cv" ]; then BASELINE_COMPARE="${BASELINE_COMPARE}固件 ${_kdisp}|移除|—|${_bv}"$'\n'
            elif [ -z "$_bv" ]; then BASELINE_COMPARE="${BASELINE_COMPARE}固件 ${_kdisp}|新增|${_cv}|—"$'\n'
            elif [ "$_cv" != "$_bv" ]; then BASELINE_COMPARE="${BASELINE_COMPARE}固件 ${_kdisp}|变化|${_cv}|${_bv}"$'\n'
            fi
        done < <(printf '%s\n' "${!_fw_cur[@]}" "${!_fw_base[@]}" | sort -u)
        BASELINE_COMPARE=$(printf '%b' "$BASELINE_COMPARE")
        if [ -n "$BASELINE_COMPARE" ]; then
            _bl_chg=$(printf '%s\n' "$BASELINE_COMPARE" | grep -vc "|一致|")
            BASELINE_COMPARE_NOTE="与 ${BASELINE_DIR_LABEL} 对比：共 $(printf '%s\n' "$BASELINE_COMPARE" | grep -c .) 项，${_bl_chg} 项有变化（新增/移除/版本变化）"
        fi
    fi
fi
