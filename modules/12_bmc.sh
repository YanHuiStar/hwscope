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
        # 本地 IPMI（BMC 通道限制 max_jobs=4）
        run_and_log_parallel 4 \
            "ipmitool mc info 2>&1" "${dir}/ipmi_mc.log" \
            "ipmitool sensor list 2>&1" "${dir}/ipmi_sensors.log" \
            "ipmitool sdr list 2>&1" "${dir}/ipmi_sdr.log" \
            "ipmitool sel list 2>&1" "${dir}/ipmi_sel.log" \
            "ipmitool sel elist 2>&1" "${dir}/ipmi_sel_elist.log" \
            "ipmitool chassis status 2>&1" "${dir}/ipmi_chassis.log" \
            "ipmitool chassis power status 2>&1" "${dir}/ipmi_power.log" \
            "ipmitool lan print 1 2>&1" "${dir}/ipmi_lan1.log" \
            "ipmitool lan print 2 2>&1" "${dir}/ipmi_lan2.log" \
            "ipmitool bmc guid 2>&1" "${dir}/ipmi_bmc_guid.log" \
            "ipmitool user list 2>&1" "${dir}/ipmi_users.log" \
            "ipmitool fru print 2>&1" "${dir}/ipmi_fru_all.log" \
            "echo '=== Product (整机) ==='; ipmitool fru print 2>/dev/null | grep -E 'Product Manufacturer|Product Name|Product Part Number|Product Serial|Product Asset' || true; echo ''; echo '=== Board (主板) ==='; ipmitool fru print 2>/dev/null | grep -E 'Board Mfg|Board Product|Board Serial|Board Part Number' || true; echo ''; echo '=== Chassis (机箱) ==='; ipmitool fru print 2>/dev/null | grep -E 'Chassis Serial|Chassis Part' || true" "${dir}/ipmi_fru_summary.log" \
            "ipmitool sensor list 2>/dev/null | grep -i temp" "${dir}/ipmi_sensors_temp.log" \
            "ipmitool sensor list 2>/dev/null | grep -i fan" "${dir}/ipmi_sensors_fan.log" \
            "ipmitool sensor list 2>/dev/null | grep -i volt" "${dir}/ipmi_sensors_volt.log" \
            "ipmitool sensor list 2>/dev/null | grep -iE 'power|watt'" "${dir}/ipmi_sensors_power.log"
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
        local bmc_timeout="timeout 8"
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
        local hgx_timeout="timeout 8"
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
        run_and_log_parallel 4 \
            "curl -sk --connect-timeout 5 --netrc-file '${NETRC_TMP}' https://${BMC_IP}/redfish/v1/Systems/System.Embedded.1 2>&1" "${dir}/redfish_system.log" \
            "curl -sk --connect-timeout 5 --netrc-file '${NETRC_TMP}' https://${BMC_IP}/redfish/v1/Managers 2>&1" "${dir}/redfish_managers.log" 
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
        "redfish_managers" "redfish_managers.log"

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_bmc "$1"
fi
