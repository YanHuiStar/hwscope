#!/bin/bash
# =============================================================================
# HwScope - JSON 报告生成器 gen_json
# report/gen/gen_json.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
gen_json() {
    local f="${OUT}/hwscope_report.json"
    # 内存插槽明细 JSON 数组（slot|size|mfr|sn|pn|nom|cur|rank|width——JSON 保留全字段，不受隐藏影响）
    local dimms_json=""
    if [ -n "$MEM_DIMMS" ]; then
        local dseq=0
        while IFS='|' read -r dslot dsize dmfr dsn dpn dnom dcur drank dwidth; do
            [ -z "$dslot" ] && continue
            dseq=$((dseq+1))
            dimms_json="${dimms_json}      {\"index\": \"${dseq}\", \"slot\": \"${dslot}\", \"size\": \"${dsize}\", \"manufacturer\": \"${dmfr}\", \"serial\": \"${dsn}\", \"part_number\": \"${dpn}\", \"nominal_speed\": \"${dnom}\", \"current_speed\": \"${dcur}\", \"rank\": \"${drank:-N/A}\", \"chip_width\": \"${dwidth:-}\"},"$'\n'
        done < <(printf '%s\n' "$MEM_DIMMS")
        dimms_json=$(printf '%s' "$dimms_json" | sed '$ s/,$//')
    fi
    # GPU 每卡明细 JSON 数组（idx|name|serial|mem|power|temp|util|pcie_cur|pcie_max）
    local gpu_details_json=""
    if [ -n "$GPU_DETAILS" ]; then
        # 每卡显存标注额定（如 B300: 268.6 GiB (额定288GB)）
        local gmem_spec=""
        [ -n "$GPU_MEM_SPEC" ] && gmem_spec=$(echo "$GPU_MEM_SPEC" | grep -oE "[0-9]+GB" | head -1)
        while IFS='|' read -r gidx gname gsn gmem gdraw gtemp gutil gpcie gmax gused glimit gvb; do
            [ -z "$gidx" ] && continue
            gpu_details_json="${gpu_details_json}      {\"index\": \"${gidx}\", \"name\": \"${gname}\", \"serial\": \"${gsn}\", \"memory\": \"${gmem}\", \"memory_used\": \"${gused:-N/A}\", \"memory_spec\": \"${gmem_spec}\", \"power\": \"${gdraw}\", \"power_limit\": \"${glimit:-N/A}\", \"temp\": \"${gtemp}\", \"utilization\": \"${gutil}\", \"pcie\": \"${gpcie}\", \"pcie_max\": \"${gmax}\", \"vbios\": \"${gvb:-N/A}\"},"$'\n'
        done < <(printf '%s\n' "$GPU_DETAILS")
        gpu_details_json=$(printf '%s' "$gpu_details_json" | sed '$ s/,$//')
    fi
    # 盘明细 JSON 数组（name|type|size|model|sn|fw|bdf|power_on）
    local disk_details_json=""
    if [ -n "$DISK_DETAILS" ]; then
        while IFS='|' read -r dname dtype dsize dmodel dsn dfw dbdf dpo dpc dspare dspec dhealth; do
            [ -z "$dname" ] && continue
            disk_details_json="${disk_details_json}      {\"name\": \"${dname}\", \"type\": \"${dtype}\", \"size\": \"${dsize}\", \"model\": \"${dmodel}\", \"serial\": \"${dsn}\", \"firmware\": \"${dfw}\", \"bdf\": \"${dbdf}\", \"power_on_h\": \"${dpo}\", \"power_cyc\": \"${dpc}\", \"spare\": \"${dspare}\", \"size_spec\": \"${dspec}\", \"health\": \"${dhealth}\"},"$'\n'
        done < <(printf '%s\n' "$DISK_DETAILS")
        disk_details_json=$(printf '%s' "$disk_details_json" | sed '$ s/,$//')
    fi
    # RAID 虚拟盘 JSON 数组（dev|raid_card|size|sn）
    local raid_vd_json=""
    if [ -n "$RAID_VD_DETAILS" ]; then
        while IFS='|' read -r rvdname rvdmodel rvdsize rvdsn; do
            [ -z "$rvdname" ] && continue
            raid_vd_json="${raid_vd_json}      {\"dev\": \"${rvdname}\", \"raid_card\": \"${rvdmodel}\", \"size\": \"${rvdsize}\", \"sn\": \"${rvdsn:-N/A}\"},"$'\n'
        done < <(printf '%s\n' "$RAID_VD_DETAILS")
        raid_vd_json=$(printf '%s' "$raid_vd_json" | sed '$ s/,$//')
    fi
    # PCIe 全量链路 JSON 数组（v1.44.0：bdf|设备|LnkCap|LnkSta|判定，表格化同步）
    local pcie_link_json=""
    if [ -n "$PCIE_LINK_TABLE" ]; then
        pcie_link_json=$(printf '%s\n' "$PCIE_LINK_TABLE" | awk -F'|' '
            $1 != "" {
                for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) }
                printf "      {\"bdf\": \"%s\", \"device\": \"%s\", \"lnk_cap\": \"%s\", \"lnk_sta\": \"%s\", \"verdict\": \"%s\"},\n", $1, $2, $3, $4, $5
            }' | sed '$ s/,$//')
    fi
    # 网卡明细 JSON 数组（dev|bdf|mac|sn|pn|fw|speed|width）
    local nic_details_json=""
    if [ -n "$NIC_DETAILS" ]; then
        # awk 一次生成（避免 while read 在本函数上下文的空读异常；与其他管道生成模式一致）
        nic_details_json=$(printf '%s' "$NIC_DETAILS" | awk -F'|' '
            $1 != "" {
                for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) }
                printf "      {\"dev\": \"%s\", \"bdf\": \"%s\", \"mac\": \"%s\", \"serial\": \"%s\", \"pn\": \"%s\", \"chip\": \"%s\", \"firmware\": \"%s\", \"pcie\": \"%s\", \"psid\": \"%s\", \"gpu_direct\": \"%s\", \"ports\": \"%s\"},\n", $1, $2, $3, $4, $5, $10, $6, $7, $8, $9, ($11 != "" ? $11 : "N/A"), ($12 != "" ? $12 : "N/A")
            }' | sed '$ s/,$//')
    elif [ -n "$NIC_FALLBACK_DETAILS" ]; then
        # 回退（旧采集无 nic_inventory）：ca|type|guid|state
        nic_details_json=$(printf '%s' "$NIC_FALLBACK_DETAILS" | awk -F'|' '
            $1 != "" {
                for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) }
                printf "      {\"dev\": \"%s\", \"ca_type\": \"%s\", \"guid\": \"%s\", \"state\": \"%s\", \"fallback\": \"ibstat\"},\n", $1, $2, $3, $4
            }' | sed '$ s/,$//')
    fi
    # NVSwitch JSON 数组
    local nvs_json=""
    if [ -n "$NVS_DETAILS" ]; then
        while IFS='|' read -r nidx nstat ntemp nports; do
            [ -z "$nidx" ] && continue
            nvs_json="${nvs_json}      {\"id\": \"${nidx}\", \"state\": \"${nstat}\", \"temp\": \"${ntemp}\", \"ports\": \"${nports}\"},"$'\n'
        done < <(printf '%s\n' "$NVS_DETAILS")
        nvs_json=$(printf '%s' "$nvs_json" | sed '$ s/,$//')
    fi
    # CPU 每 Socket 明细 JSON 数组
    local cpu_details_json=""
    if [ -n "$CPU_DETAILS" ]; then
        while IFS='|' read -r csocket cmodel ccores cthreads cmaxspd ccurspd cstep; do
            [ -z "$csocket" ] && continue
            cpu_details_json="${cpu_details_json}      {\"socket\": \"${csocket}\", \"model\": \"${cmodel}\", \"cores\": \"${ccores}\", \"threads\": \"${cthreads}\", \"max_speed\": \"${cmaxspd}\", \"cur_speed\": \"${ccurspd}\", \"stepping\": \"${cstep}\"},"$'\n'
        done < <(printf '%s\n' "$CPU_DETAILS")
        cpu_details_json=$(printf '%s' "$cpu_details_json" | sed '$ s/,$//')
    fi
    # SEL 最近事件 JSON 数组
    local sel_details_json=""
    if [ -n "$SEL_DETAILS" ]; then
        while IFS='|' read -r sid sdate stime stype sdesc; do
            [ -z "$sid" ] && continue
            sel_details_json="${sel_details_json}      {\"id\": \"${sid}\", \"date\": \"${sdate}\", \"time\": \"${stime}\", \"type\": \"${stype}\", \"description\": \"${sdesc}\"},"$'\n'
        done < <(printf '%s\n' "$SEL_DETAILS")
        sel_details_json=$(printf '%s' "$sel_details_json" | sed '$ s/,$//')
    fi
    # 风扇明细 JSON 数组
    local fan_details_json=""
    if [ -n "$FAN_DETAILS" ]; then
        while IFS='|' read -r fname frpm fstatus; do
            [ -z "$fname" ] && continue
            fan_details_json="${fan_details_json}      {\"name\": \"${fname}\", \"rpm\": \"${frpm}\", \"status\": \"${fstatus}\"},"$'\n'
        done < <(printf '%s\n' "$FAN_DETAILS")
        fan_details_json=$(printf '%s' "$fan_details_json" | sed '$ s/,$//')
    fi
    # 固件合规 JSON 数组（component|device|current|baseline|status|note）；未启用基线（全未知）→ 空数组
    local fw_details_json=""
    if [ "${FW_COMPLIANCE_ACTIVE:-0}" -eq 1 ] 2>/dev/null; then
        fw_details_json=$(printf '%s' "$FW_COMPLIANCE_DETAILS" | awk -F'|' '
            $1 != "" {
                for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) }
                printf "      {\"component\": \"%s\", \"device\": \"%s\", \"current\": \"%s\", \"baseline\": \"%s\", \"status\": \"%s\", \"note\": \"%s\"},\n", $1, $2, $3, $4, $5, $6
            }' | sed '$ s/,$//')
    fi
    # BMC 一致性 JSON 数组（item|os_side|bmc_side|result）
    local bmc_consistency_json=""
    if [ -n "$BMC_CONSISTENCY" ]; then
        bmc_consistency_json=$(printf '%s' "$BMC_CONSISTENCY" | awk -F'|' '
            $1 != "" {
                for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) }
                printf "      {\"item\": \"%s\", \"os_side\": \"%s\", \"bmc_side\": \"%s\", \"result\": \"%s\"},\n", $1, $2, $3, $4
            }' | sed '$ s/,$//')
    fi
    # 压测归档 JSON 数组（name|status|elapsed_s|detail_file）
    local test_details_json=""
    if [ -n "$TEST_DETAILS" ]; then
        test_details_json=$(printf '%s' "$TEST_DETAILS" | awk -F'|' '
            $1 != "" {
                for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) }
                printf "      {\"name\": \"%s\", \"status\": \"%s\", \"elapsed_s\": \"%s\", \"detail_file\": \"%s\"},\n", $1, $2, $3, $4
            }' | sed '$ s/,$//')
    fi
    # FLD 诊断 JSON（test|component|result|note 明细 + 按测试聚合）
    local fld_details_json="" fld_agg_json=""
    if [ -n "$FLD_DETAILS" ]; then
        fld_details_json=$(printf '%s' "$FLD_DETAILS" | awk -F'|' '
            $1 != "" {
                for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) }
                printf "      {\"test\": \"%s\", \"component\": \"%s\", \"result\": \"%s\", \"note\": \"%s\"},\n", $1, $2, $3, $4
            }' | sed '$ s/,$//')
        fld_agg_json=$(printf '%s\n' "$FLD_DETAILS" | awk -F'|' '
            { cnt[$1]++; if ($3 ~ /^OK/) ok[$1]++; else if ($4 ~ /skip/ || $3 ~ /skip/) sk[$1]++; else fail[$1]++ }
            END {
                for (v in cnt) {
                    st = "PASS"
                    if (fail[v] > 0) st = "FAIL"
                    else if (sk[v] > 0) st = "SKIPPED"
                    printf "      {\"test\": \"%s\", \"result\": \"%s\", \"components\": %d},\n", v, st, cnt[v]
                }
            }' | sort | sed '$ s/,$//')
    fi
    # 基线对比 JSON 数组（item|status|current|baseline）
    local baseline_compare_json=""
    if [ -n "$BASELINE_COMPARE" ]; then
        baseline_compare_json=$(printf '%s' "$BASELINE_COMPARE" | awk -F'|' '
            $1 != "" {
                for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) }
                printf "      {\"item\": \"%s\", \"status\": \"%s\", \"current\": \"%s\", \"baseline\": \"%s\"},\n", $1, $2, $3, $4
            }' | sed '$ s/,$//')
    fi
    cat > "$f" << EOF
{
  "hwscope": {
    "version": "${VERSION:-unknown}",
    "report_generator": "${REPORT_VERSION:-unknown}",
    "hostname": "${HOSTNAME:-unknown}",
    "platform": "${PLATFORM:-unknown}",
    "platform_label": "${PLATFORM_LABEL:-unknown}",
    "machine_class": "${MACHINE_CLASS:-unknown}",
    "machine_class_label": "${MACHINE_CLASS_LABEL:-}",
    "timestamp": "${TIMESTAMP:-unknown}"
  },
  "environment": {
    "os": "${OS_NAME:-N/A}",
    "kernel": "${KERNEL:-N/A}",
    "driver": "${GPU_DRIVER:-N/A}",
    "cuda": "${GPU_CUDA:-N/A}"
  },
  "timing": {
    "total": "${TIMING_TOTAL:-N/A}",
    "top_modules": "${TIMING_TOP:-N/A}"
  },
  "motherboard": {
    "manufacturer": "${MB_MANUFACTURER:-N/A}",
    "product": "${MB_PRODUCT:-N/A}",
    "serial": "${MB_SN:-N/A}",
    "board_serial": "${MB_BOARD_SN:-N/A}",
    "bios": "${BIOS_VERSION:-N/A}",
    "chassis_sn": "${CHASSIS_SN:-N/A}",
    "fabric_switch": "${FABRIC_SW:-}"
  },
  "pcie": {
    "pex_switches": "${PCIE_PEX_DETAILS:-}",
    "links_total": ${PCIE_LINKS_TOTAL:-0},
    "links_ok": ${PCIE_LINKS_OK:-1},
    "slow_count": ${PCIE_SLOW_COUNT:-0},
    "mgmt_chip_count": ${PCIE_MGMT_COUNT:-0},
    "slow_links": [
      $(if [ -n "${PCIE_SLOW_LINKS:-}" ]; then printf '%s\n' "${PCIE_SLOW_LINKS}" | awk '{printf "      \"%s\",\n", $0}' | sed '$ s/,$//'; fi)
    ],
    "link_details": [
      $(printf '%s' "${pcie_link_json:-}")
    ]
  },
  "cpu": {
    "model": "${CPU_MODEL:-N/A}",
    "cores": "${CPU_CORES:-N/A}",
    "cores_total": "${CPU_TOTAL_CORES:-N/A}",
    "sockets": "${CPU_SOCKETS:-N/A}",
    "stepping": "${CPU_STEPPING:-N/A}",
    "max_speed": "${CPU_MAX_SPEED:-N/A}",
    "current_speed": "${CPU_CUR_SPEED:-N/A}",
    "details": [
$(if [ -n "$CPU_DETAILS" ]; then
    echo "$CPU_DETAILS" | awk -F'|' '{for (i = 1; i <= NF; i++) { gsub(/\\/, "\\\\", $i); gsub(/"/, "\\\"", $i) } printf "      {\"index\": \"%d\", \"socket\": \"%s\", \"model\": \"%s\", \"cores\": \"%s\", \"threads\": \"%s\", \"max_speed\": \"%s\", \"cur_speed\": \"%s\", \"stepping\": \"%s\", \"serial\": \"%s\"},\n", NR, $1, $2, $3, $4, $5, $6, $7, $8}' | sed '$ s/,$//'
fi)
    ]
  },
  "memory": {
    "total": "${MEM_TOTAL_PHYS:-${MEM_TOTAL:-N/A}}/${MEM_TOTAL:-N/A} 可见",
    "type": "${MEM_TYPE:-N/A}",
    "speed": "${MEM_SPEED:-N/A}",
    "speed_note": "${MEM_SPEED_NOTE:-}",
    "slots": "${MEM_SLOTS:-N/A}",
    "populated": "${MEM_POPULATED:-0}",
    "dimms": [
${dimms_json}
    ]
  },
  "gpu": {
    "count": "${GPU_COUNT:-0}",
    "models": "${GPU_NAMES:-N/A}",
    "memory_total": "${GPU_MEM:-N/A}",
    "memory_spec": "${GPU_MEM_SPEC:-N/A}",
    "memory_spec_total": "${GPU_MEM_SPEC_TOTAL:-N/A}",
    "memory_spec_note": "${GPU_MEM_SPEC_NOTE:-}",
    "power_limit": "${GPU_POWER:-N/A}",
    "temp": "${GPU_TEMP:-N/A}",
    "ecc": "${GPU_ECC:-N/A}",
    "remapped_rows": "${GPU_REMAP:-N/A}",
    "ras": "${GPU_RAS:-N/A}",
    "vbios": "${GPU_VBIOS:-N/A}",
    "ascend_note": "${GPU_ASCEND_NOTE:-}",
    "xgmi": "${GPU_XGMI_SUMMARY:-}",
    "nvlink": "${NV_LINK_SUMMARY:-N/A}",
    "serials": "${GPU_SERIALS:-N/A}",
    "details": [
${gpu_details_json}
    ]
  },
  "storage": {
    "disk_count": "${STORAGE_COUNT:-0}",
    "total_capacity": "${STORAGE_TOTAL:-N/A}",
    "disk_models": "${STORAGE_MODELS:-N/A}",
    "system_disk_excluded": "${SYS_DISK:-N/A}",
    "disks": [
${disk_details_json}
    ],
    "raid_vds": [
${raid_vd_json}
    ]
  },
  "network": {
    "ib_devices": "${IB_COUNT:-0}",
    "ib_active": "${IB_ACTIVE:-0}",
    "ib_active_speed": "${IB_ACTIVE_SPEED:-N/A}",
    "ib_nominal_speed": "${IB_NOMINAL:-N/A}",
    "eth_link_up": "${ETH_LINK_UP:-0}",
    "cables": "${CABLE_SUMMARY:-N/A}",
    "cable_pairs": "${CABLE_PAIRS:-N/A}",
    "port_modes": "${LINKTYPE_SUMMARY:-N/A}",
    "nics": [
${nic_details_json}
    ],
    "usb_nics": [
$(if [ -n "$USB_NICS" ]; then
    ujson=""
    while IFS='|' read -r unnic unmac unpn unfw; do
        [ -z "$unnic" ] && continue
        ujson="${ujson}      {\"dev\": \"${unnic}\", \"mac\": \"${unmac}\", \"pn\": \"${unpn:-}\", \"firmware\": \"${unfw:-}\"},"$'\n'
    done < <(printf '%s\n' "$USB_NICS")
    printf '%s' "$ujson" | sed '$ s/,$//'
fi)
    ]
  },
  "bmc": {
    "fru": "${BMC_FRU:-N/A}",
    "firmware": "${BMC_FW:-N/A}",
    "ip": "${BMC_IP:-N/A}",
    "mac": "${BMC_MAC:-N/A}",
    "sel_total": "${SEL_TOTAL:-0}",
    "sel_critical": "${SEL_CRIT:-0}",
    "sel_details": [
$(if [ -n "$SEL_DETAILS" ]; then
    echo "$SEL_DETAILS" | while IFS='|' read -r sid sdate stime stype sdesc; do
        printf '      {"id": "%s", "date": "%s", "time": "%s", "type": "%s", "description": "%s"},\n' "$sid" "$sdate" "$stime" "$stype" "$sdesc"
    done | sed '$ s/,$//'
fi)
    ]
  },
  "fan": {
    "count": "${FAN_COUNT:-0}",
    "speed": "${FAN_SPEED:-N/A}",
    "redundancy": "${FAN_REDUNDANT:-N/A}",
    "redundancy_extra": "${FAN_EXTRA:-}",
    "details": [
$(if [ -n "$FAN_DETAILS" ]; then
    echo "$FAN_DETAILS" | while IFS='|' read -r fname fval fstatus; do
        printf '      {"name": "%s", "rpm": "%s", "status": "%s"},\n' "$fname" "$fval" "$fstatus"
    done | sed '$ s/,$//'
fi)
    ]
  },
  "psu": {
    "list": "$(printf '%s' "${PSU_DETAILS:-N/A}" | tr '\n' '; ' | sed 's/; $//')",
    "details": [
$(if [ -n "$PSU_DETAILS" ]; then
    pseq=0
    while IFS='|' read -r pdesc pmodel ppn psn pcap ppower; do
        [ -z "$pdesc" ] && continue
        pseq=$((pseq+1))
        printf '      {"index": "%s", "description": "%s", "model": "%s", "part_number": "%s", "serial": "%s", "capacity": "%s", "power_in": "%s"},' "$pseq" "$pdesc" "$pmodel" "$ppn" "$psn" "${pcap:-N/A}" "${ppower:-N/A}"
        echo ""
    done < <(printf '%s\n' "$PSU_DETAILS") | sed '$ s/,$//'
fi)
    ]
  },
  "psu_system": {
    "total_power": "${PSU_EXTRA:-}",
    "dcmi": "${PSU_DCMI:-}"
  },
  "raid": [
$(if [ -n "$RAID_DETAILS" ]; then
    echo "$RAID_DETAILS" | while IFS='|' read -r ridx rmodel rsn rfw rvd rvd_list; do
        [ -z "$ridx" ] && continue
        printf '    {"controller": "%s", "model": "%s", "serial": "%s", "firmware": "%s", "virtual_disks": "%s", "vd_list": "%s"},\n' "$ridx" "$rmodel" "$rsn" "$rfw" "$rvd" "$rvd_list"
    done | sed '$ s/,$//'
fi)
  ],
  "hba": [
$(if [ -n "$HBA_DETAILS" ]; then
    echo "$HBA_DETAILS" | while IFS='|' read -r hname htype hfw hsn hstat hsas hports; do
        [ -z "$hname" ] && continue
        printf '    {"controller": "%s", "model": "%s", "firmware": "%s", "serial": "%s", "status": "%s", "sas_address": "%s", "ports": "%s"},\n' "$hname" "$htype" "$hfw" "$hsn" "$hstat" "$hsas" "$hports"
    done | sed '$ s/,$//'
fi)
  ],
  "nvswitch": [
$(printf '%s' "$nvs_json")
  ],
  "health": {
    "gpu_pcie_degraded": "${GPU_DEGRADED:-OK}",
    "nvlink_status": "${NVLINK_HEALTH:-N/A}",
    "nvlink_crc_errors": "${NVLINK_CRC:+存在非零CRC错误}",
    "dcgm_diag": "${DCGM_SUMMARY:-N/A}",
    "sel_pcie_errors": "${SEL_PCIE_ERR:-0}",
    "cable_pairs": "${CABLE_PAIRS:-N/A}"
  },
  "firmware": {
    "summary": "${FW_SUMMARY:-N/A}",
    "items": [
${fw_details_json}
    ]
  },
  "power_ledger": {
    "current_power": "${PWR_CUR:-N/A}",
    "power_min": "${PWR_MIN:-N/A}",
    "power_max": "${PWR_MAX:-N/A}",
    "power_avg": "${PWR_AVG:-N/A}",
    "cumulative_energy": "${PWR_ENERGY:-N/A}",
    "energy_source": "${PWR_ENERGY_SRC:-N/A}",
    "note": "${PWR_NOTE:-}"
  },
  "bmc_consistency": {
    "items": [
${bmc_consistency_json}
    ]
  },
  "test_archive": {
    "dir": "${TEST_DIR_LABEL:-}",
    "items": [
${test_details_json}
    ]
  },
  "fld": {
    "dir": "${FLD_DIR_LABEL:-}",
    "summary": "${FLD_SUMMARY:-}",
    "result": "${FLD_RESULT:-}",
    "tests": [
${fld_agg_json}
    ],
    "details": [
${fld_details_json}
    ]
  },
  "baseline_compare": {
    "baseline_dir": "${BASELINE_DIR_LABEL:-}",
    "note": "${BASELINE_COMPARE_NOTE:-}",
    "items": [
${baseline_compare_json}
    ]
  }
}
EOF
    echo -e "${GREEN}[REPORT] JSON: ${f}${NC}"
}

# ─── 术语说明（交付报告末尾，解释报告内出现的专业词） ───
GLOSSARY_ENTRIES=(
    "IB|InfiniBand，高速互联网络（GPU/存储集群专用），速率代际 SDR→DDR→QDR→FDR→EDR→HDR→NDR→XDR 每代翻倍（10G→800G/单口）"
    "额定/实际速率|额定=网卡硬件支持的最大速率（固件声明，无需接线）；实际=当前链路协商速率（取决于对端交换机/线缆，未接为 Down）"
    "GPU直连|网卡与 GPU 处于同一 PCIe Switch（PIX），可做 GPU Direct RDMA 高速通信"
    "NVLink|NVIDIA GPU 间高速互联总线（B300 每卡 18 条，53.125 GB/s/条）"
    "NVSwitch|NVLink 交换芯片，连接多卡实现全互联（B300 集成于 GPU 模块内）"
    "DCGM|NVIDIA Data Center GPU Manager，GPU 诊断工具（dcgmi diag）"
    "SEL|System Event Log，BMC 记录的系统事件日志（含硬件告警）"
    "SXM|NVIDIA 数据中心 GPU 模块化形态（非 PCIe 插卡），如 B300 SXM6"
    "PSID|网卡产品 ID（Mellanox 卡标识，用于固件匹配）"
    "退役行(Remapped Rows)|GPU 显存中检测到故障后自动重映射隐藏的行，计数>0 提示显存健康问题"
    "2DPC|DIMM Per Channel=每内存通道插 2 条；满插时信号负载大，内存降速运行属平台规范正常现象"
)
