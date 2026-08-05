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
        # 本地 IPMI 需要 ipmi 驱动加载
        run_and_log "ipmitool fru print 2>&1 | head -100" "${dir}/ipmi_fru.log"
        run_and_log "ipmitool mc info 2>&1" "${dir}/ipmi_mc.log"

        # 传感器
        run_and_log "ipmitool sensor list 2>&1" "${dir}/ipmi_sensors.log"
        run_and_log "ipmitool sdr list 2>&1" "${dir}/ipmi_sdr.log"

        # 系统事件日志
        run_and_log "ipmitool sel list 2>&1" "${dir}/ipmi_sel.log"
        run_and_log "ipmitool sel elist 2>&1" "${dir}/ipmi_sel_elist.log"

        # 机箱状态
        run_and_log "ipmitool chassis status 2>&1" "${dir}/ipmi_chassis.log"
        run_and_log "ipmitool chassis power status 2>&1" "${dir}/ipmi_power.log"

        # 网络配置
        run_and_log "ipmitool lan print 1 2>&1" "${dir}/ipmi_lan1.log"
        run_and_log "ipmitool lan print 2 2>&1" "${dir}/ipmi_lan2.log"

        # MAC / GUID
        run_and_log "ipmitool bmc guid 2>&1" "${dir}/ipmi_bmc_guid.log"

        # 用户列表
        run_and_log "ipmitool user list 2>&1" "${dir}/ipmi_users.log"

        # FRU 详细（全部字段）
        run_and_log "ipmitool fru print 2>&1" "${dir}/ipmi_fru_all.log"

        # 关键字段摘要
        run_and_log "echo '=== Product (整机) ===' && ipmitool fru print 2>/dev/null | grep -E 'Product Manufacturer|Product Name|Product Part Number|Product Serial|Product Asset' && echo '' && echo '=== Board (主板) ===' && ipmitool fru print 2>/dev/null | grep -E 'Board Mfg|Board Product|Board Serial|Board Part Number' && echo '' && echo '=== Chassis (机箱) ===' && ipmitool fru print 2>/dev/null | grep -E 'Chassis Serial|Chassis Part'" \
            "${dir}/ipmi_fru_summary.log"

        # 传感器分类提取
        run_and_log "ipmitool sensor list 2>/dev/null | grep -i temp" "${dir}/ipmi_sensors_temp.log"
        run_and_log "ipmitool sensor list 2>/dev/null | grep -i fan" "${dir}/ipmi_sensors_fan.log"
        run_and_log "ipmitool sensor list 2>/dev/null | grep -i volt" "${dir}/ipmi_sensors_volt.log"
        run_and_log "ipmitool sensor list 2>/dev/null | grep -iE 'power|watt'" "${dir}/ipmi_sensors_power.log"
    else
        echo -e "${YELLOW}[SKIP] ipmitool not found${NC}"
    fi

    # ─── 远程 BMC（通过配置 IP，加 8s 超时防卡死；密码经 IPMI_PASSWORD 环境变量传递，命令字符串不含密码，杜绝明文落盘） ───
    if [ -n "$BMC_IP" ] && check_cmd ipmitool; then
        echo -e "${BLUE}[BMC] Remote BMC: ${BMC_IP}${NC}"
        export IPMI_PASSWORD="${BMC_PASS}"
        local ipmi_cmd="timeout 8 ipmitool -H ${BMC_IP} -U ${BMC_USER} -I ${BMC_INTERFACE}"

        run_and_log "${ipmi_cmd} fru print" "${dir}/remote_bmc_fru.log"
        run_and_log "${ipmi_cmd} mc info" "${dir}/remote_bmc_mc.log"
        run_and_log "${ipmi_cmd} sensor list" "${dir}/remote_bmc_sensors.log"
        run_and_log "${ipmi_cmd} sel list" "${dir}/remote_bmc_sel.log"
        run_and_log "${ipmi_cmd} chassis status" "${dir}/remote_bmc_chassis.log"
    else
        echo -e "${YELLOW}[SKIP] Remote BMC not configured (BMC_IP is empty)${NC}"
    fi

    # ─── HGX 基板 BMC（独立管理 GPU/NVSwitch，加 8s 超时防卡死；仅配置了 HGX_BMC_IP 时启用） ───
    if [ -n "$HGX_BMC_IP" ] && check_cmd ipmitool; then
        echo -e "${BLUE}[BMC] HGX Baseboard BMC: ${HGX_BMC_IP}${NC}"
        export IPMI_PASSWORD="${HGX_BMC_PASS}"
        local hgx_cmd="timeout 8 ipmitool -H ${HGX_BMC_IP} -U ${HGX_BMC_USER} -I ${BMC_INTERFACE}"

        run_and_log "${hgx_cmd} fru print 2>&1" "${dir}/hgx_bmc_fru.log"
        run_and_log "${hgx_cmd} sensor list 2>&1" "${dir}/hgx_bmc_sensors.log"
        run_and_log "${hgx_cmd} sdr list 2>&1" "${dir}/hgx_bmc_sdr.log"
    else
        echo -e "${YELLOW}[SKIP] HGX Baseboard BMC not configured${NC}"
    fi

    # ─── Redfish 检查（如果装了 curl/jq；密码经 CURL_NETRC 临时文件传递，不落盘日志） ───
    if [ -n "$BMC_IP" ] && check_cmd curl; then
        echo -e "${BLUE}[BMC] Redfish API check: ${BMC_IP}${NC}"
        # 临时 netrc（权限 600，用完即删）：curl --netrc-file 读取，命令字符串不含密码
        NETRC_TMP=$(mktemp)
        chmod 600 "$NETRC_TMP"
        printf 'machine %s login %s password %s\n' "$BMC_IP" "$BMC_USER" "$BMC_PASS" > "$NETRC_TMP"
        run_and_log "curl -sk --connect-timeout 5 --netrc-file '${NETRC_TMP}' https://${BMC_IP}/redfish/v1/Systems/System.Embedded.1 2>&1 | head -100" \
            "${dir}/redfish_system.log"
        run_and_log "curl -sk --connect-timeout 5 --netrc-file '${NETRC_TMP}' https://${BMC_IP}/redfish/v1/Managers 2>&1 | head -100" \
            "${dir}/redfish_managers.log"
        rm -f "$NETRC_TMP"
    fi

    module_end "$MODULE_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <output_dir>"
        exit 1
    fi
    run_bmc "$1"
fi
