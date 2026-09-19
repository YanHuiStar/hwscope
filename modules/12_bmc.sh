#!/bin/bash
# =============================================================================
# 模块: 12_bmc.sh — BMC/IPMI 信息采集
# 输出目录: <OUTPUT_DIR>/bmc/
# =============================================================================

MODULE_NAME="BMC"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

run_bmc() {
    local output_dir="$1"
    # 加载配置（如果存在）
    local conf_file="${SCRIPT_DIR}/../conf/hwscope.conf"
    [ -f "$conf_file" ] && source "$conf_file"

    local dir="${output_dir}/bmc"
    mkdir -p "$dir"

    module_start "$MODULE_NAME"

    # ─── 本地 IPMI（OS 内 /dev/ipmi0） ───
    if check_cmd ipmitool; then
        # v1.48.57：IPMI 命令统一加超时——BMC 慢/无响应时单命令无限挂起会拖垮整模块（曾致 PSU/FAN/BMC/Power 4 模块 300s 超时）
        # v1.49.9：分级超时 + 全项目共享 IPMI 快照（详见 lib/common.sh 的 ipmi_snapshot 说明）。
        #   ① 最贵的 sensor list / sdr list 走快照：全项目原共 7 次 sensor list + 3 次 sdr list，
        #      慢机单次 200s+ → 累计 1000s+，把 BMC 打满。现改为全局只跑一次、各模块派生。
        #   ② 其余命令按代价分三级超时：轻（chassis/guid/power/lan/mc）30s、
        #      中（sel/fru）90s、慢（sdr/sensor）240s。一刀切 30s 会把慢机的 sdr/sensor 全砍掉。
        local ipmi_fast="timeout ${IPMI_TIMEOUT_FAST:-30}"; check_cmd timeout || ipmi_fast=""
        local ipmi_to="timeout ${IPMI_TIMEOUT:-90}"; check_cmd timeout || ipmi_to=""
        # 并发 4 → 2：IPMI 走 KCS 单通道，多个 ipmitool 并发只在 BMC 侧排队，反而互相拖慢。
        run_and_log_parallel 2 \
            "${ipmi_fast} bash -c \"ipmitool mc info 2>&1\"" "${dir}/ipmi_mc.log" \
            "${ipmi_to} bash -c \"ipmitool sel list 2>&1\"" "${dir}/ipmi_sel.log" \
            "${ipmi_to} bash -c \"ipmitool sel elist 2>&1\"" "${dir}/ipmi_sel_elist.log" \
            "${ipmi_fast} bash -c \"ipmitool chassis status 2>&1\"" "${dir}/ipmi_chassis.log" \
            "${ipmi_fast} bash -c \"ipmitool chassis power status 2>&1\"" "${dir}/ipmi_power.log" \
            "${ipmi_fast} bash -c \"ipmitool lan print 1 2>&1\"" "${dir}/ipmi_lan1.log" \
            "${ipmi_fast} bash -c \"ipmitool lan print 2 2>&1\"" "${dir}/ipmi_lan2.log" \
            "for ch in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do echo \"=== Channel \$ch ===\"; ipmitool lan print \\\$ch 2>&1 | grep --line-buffered -E 'IP Address |MAC Address|IP Address Source' ; done" "${dir}/ipmi_lan_all.log" \
            "${ipmi_fast} bash -c \"ipmitool bmc guid 2>&1\"" "${dir}/ipmi_bmc_guid.log" \
            "${ipmi_fast} bash -c \"ipmitool user list 2>&1\"" "${dir}/ipmi_users.log" \
            "${ipmi_to} bash -c \"ipmitool fru print 2>&1\"" "${dir}/ipmi_fru_all.log" \
            "echo '=== Product (整机) ==='; ipmitool fru print 2>/dev/null | grep --line-buffered -E 'Product Manufacturer|Product Name|Product Part Number|Product Serial|Product Asset' || true; echo ''; echo '=== Board (主板) ==='; ipmitool fru print 2>/dev/null | grep --line-buffered -E 'Board Mfg|Board Product|Board Serial|Board Part Number' || true; echo ''; echo '=== Chassis (机箱) ==='; ipmitool fru print 2>/dev/null | grep --line-buffered -E 'Chassis Serial|Chassis Part' || true" "${dir}/ipmi_fru_summary.log"
        # 共享快照：sensor list / sdr list 各只跑一次（全项目共用），本模块先落盘两份主日志
        _ss=$(ipmi_snapshot sensors 2>/dev/null)
        [ -n "$_ss" ] && [ -f "$_ss" ] && cp "$_ss" "${dir}/ipmi_sensors.log" 2>/dev/null || : > "${dir}/ipmi_sensors.log"
        _sd=$(ipmi_snapshot sdr 2>/dev/null)
        [ -n "$_sd" ] && [ -f "$_sd" ] && cp "$_sd" "${dir}/ipmi_sdr.log" 2>/dev/null || : > "${dir}/ipmi_sdr.log"
        # v1.49.9：temp/fan/volt/power 四份**从快照派生**（原为各跑一次 sensor list，慢机上等于多拷打 BMC 4 次）
        for _kind in temp fan volt; do
            ipmi_snapshot_derive "$_ss" "${dir}/ipmi_sensors_${_kind}.log" "$_kind" 2>/dev/null || : > "${dir}/ipmi_sensors_${_kind}.log"
        done
        ipmi_snapshot_derive "$_ss" "${dir}/ipmi_sensors_power.log" 'power|watt' 2>/dev/null || : > "${dir}/ipmi_sensors_power.log"
        # ipmi_fru.log 与 ipmi_fru_all.log 内容相同（同一条命令），只跑一次后复制，省一次 2-5s 的 BMC 查询
        cp "${dir}/ipmi_fru_all.log" "${dir}/ipmi_fru.log" 2>/dev/null || true
    else
        echo -e "${YELLOW}[SKIP] ipmitool not found${NC}"
    fi

    # ─── 远程 BMC（通过配置 IP，加 8s 超时防卡死；密码经 IPMI_PASSWORD 环境变量传递，命令字符串不含密码，杜绝明文落盘） ───
    if [ -n "$BMC_IP" ] && check_cmd ipmitool; then
        echo -e "${BLUE}[BMC] Remote BMC: ${BMC_IP}${NC}"
        export IPMI_PASSWORD="${BMC_PASS}"
        # -E: 从 IPMI_PASSWORD 环境变量读密码（无 -E 会交互式等密码，被 timeout 杀掉）；timeout 缺失兜底（精简容器）
        local bmc_timeout="timeout ${IPMI_TIMEOUT:-30}"
        check_cmd timeout || bmc_timeout=""
        local ipmi_cmd="${bmc_timeout} ipmitool -E -H ${BMC_IP} -U ${BMC_USER} -I ${BMC_INTERFACE}"

        run_and_log_parallel 4 \
            "${ipmi_cmd} fru print" "${dir}/remote_bmc_fru.log" \
            "${ipmi_cmd} mc info" "${dir}/remote_bmc_mc.log" \
            "${ipmi_cmd} sensor list" "${dir}/remote_bmc_sensors.log" \
            "${ipmi_cmd} sel list" "${dir}/remote_bmc_sel.log" \
            "${ipmi_cmd} chassis status" "${dir}/remote_bmc_chassis.log" 
    else
        echo -e "${YELLOW}[SKIP] Remote BMC not configured (BMC_IP is empty)${NC}"
    fi

    # ─── HGX 基板 BMC（独立管理 GPU/NVSwitch，加 8s 超时防卡死；仅配置了 HGX_BMC_IP 时启用） ───
    if [ -n "$HGX_BMC_IP" ] && check_cmd ipmitool; then
        echo -e "${BLUE}[BMC] HGX Baseboard BMC: ${HGX_BMC_IP}${NC}"
        export IPMI_PASSWORD="${HGX_BMC_PASS}"
        local hgx_timeout="timeout ${IPMI_TIMEOUT:-30}"
        check_cmd timeout || hgx_timeout=""
        local hgx_cmd="${hgx_timeout} ipmitool -E -H ${HGX_BMC_IP} -U ${HGX_BMC_USER} -I ${BMC_INTERFACE}"

        run_and_log_parallel 4 \
            "${hgx_cmd} fru print 2>&1" "${dir}/hgx_bmc_fru.log" \
            "${hgx_cmd} sensor list 2>&1" "${dir}/hgx_bmc_sensors.log" \
            "${hgx_cmd} sdr list 2>&1" "${dir}/hgx_bmc_sdr.log" 
    else
        echo -e "${YELLOW}[SKIP] HGX Baseboard BMC not configured${NC}"
    fi

    # ─── Redfish 检查（如果装了 curl/jq；密码经 CURL_NETRC 临时文件传递，不落盘日志） ───
    if [ -n "$BMC_IP" ] && check_cmd curl; then
        echo -e "${BLUE}[BMC] Redfish API check: ${BMC_IP}${NC}"
        # 临时 netrc（权限 600，用完即删）：curl --netrc-file 读取，命令字符串不含密码
        # 中断/超时也清理（模块被 timeout 杀时 trap 兜底，防密码文件残留 /tmp）
        NETRC_TMP=$(mktemp)
        chmod 600 "$NETRC_TMP"
        trap 'rm -f "$NETRC_TMP"' EXIT INT TERM
        printf 'machine %s login %s password %s\n' "$BMC_IP" "$BMC_USER" "$BMC_PASS" > "$NETRC_TMP"
        # ─── FirmwareInventory（v1.48.46）：AMI BMC 固件完整版——ipmitool mc info 只给主次（1.01），
        # FirmwareInventory 给完整号（1.01.00）；BIOS/CPLD/PSU 成员 Version 空 = AMI 实现不填——如实采集不伪造
        run_and_log_parallel 4 \
            "curl -sk --connect-timeout 5 --netrc-file '${NETRC_TMP}' https://${BMC_IP}/redfish/v1/Systems/System.Embedded.1 2>&1" "${dir}/redfish_system.log" \
            "curl -sk --connect-timeout 5 --netrc-file '${NETRC_TMP}' https://${BMC_IP}/redfish/v1/Managers 2>&1" "${dir}/redfish_managers.log" \
            "for _m in BIOS BMCImage1 BMCImage2 CPLD PSU; do printf '%s|' \"\$_m\"; curl -sk --connect-timeout 5 --netrc-file '${NETRC_TMP}' https://${BMC_IP}/redfish/v1/UpdateService/FirmwareInventory/\$_m 2>&1 | grep -oE '\"Version\"[[:space:]]*:[[:space:]]*\"[^\"]*\"' | head -1 | cut -d'\"' -f4; done" "${dir}/redfish_fw_versions.log"
        rm -f "$NETRC_TMP"
        trap - EXIT INT TERM
    fi

write_manifest "${dir}/manifest.txt" \
        "ipmi_fru" "ipmi_fru.log" \
        "ipmi_mc" "ipmi_mc.log" \
        "ipmi_sensors" "ipmi_sensors.log" \
        "ipmi_sdr" "ipmi_sdr.log" \
        "ipmi_sel" "ipmi_sel.log" \
        "ipmi_sel_elist" "ipmi_sel_elist.log" \
        "ipmi_chassis" "ipmi_chassis.log" \
        "ipmi_power" "ipmi_power.log" \
        "ipmi_lan1" "ipmi_lan1.log" \
        "ipmi_lan2" "ipmi_lan2.log" \
        "ipmi_lan_all" "ipmi_lan_all.log" \
        "ipmi_bmc_guid" "ipmi_bmc_guid.log" \
        "ipmi_users" "ipmi_users.log" \
        "ipmi_fru_all" "ipmi_fru_all.log" \
        "ipmi_fru_summary" "ipmi_fru_summary.log" \
        "ipmi_sensors_temp" "ipmi_sensors_temp.log" \
        "ipmi_sensors_fan" "ipmi_sensors_fan.log" \
        "ipmi_sensors_volt" "ipmi_sensors_volt.log" \
        "ipmi_sensors_power" "ipmi_sensors_power.log" \
        "remote_bmc_fru" "remote_bmc_fru.log" \
        "remote_bmc_mc" "remote_bmc_mc.log" \
        "remote_bmc_sensors" "remote_bmc_sensors.log" \
        "remote_bmc_sel" "remote_bmc_sel.log" \
        "remote_bmc_chassis" "remote_bmc_chassis.log" \
        "hgx_bmc_fru" "hgx_bmc_fru.log" \
        "hgx_bmc_sensors" "hgx_bmc_sensors.log" \
        "hgx_bmc_sdr" "hgx_bmc_sdr.log" \
        "redfish_system" "redfish_system.log" \
        "redfish_managers" "redfish_managers.log" \
        "redfish_fw_versions" "redfish_fw_versions.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_bmc "$1"
fi
