#!/bin/bash
# =============================================================================
# HwScope - GPU 额定显存规格库 gpu_mem_candidates（60+ 型号，交叉验证防魔改/伪装）
# report/lib/gpu_spec.sh
# 拆分自原 tools/report.sh（v1.35.0 refactor，行为不变）；由 report/report.sh source 装配
# =============================================================================
    # 额定显存候选：型号 → 候选 GB 列表（| 分隔，多版本给列表交叉验证选近者）；空=未知型号
    # 供第一卡（汇总展示）与逐卡魔改检测（混插/伪装识别）复用
    gpu_mem_candidates() {
        case "$1" in
            # ── 精确/长型号优先（防通用模式误配：A2 勿配 A2000、T4 勿配 T400、L4 勿配 L40）──
            *"RTX PRO 6000"*)        echo "96" ;;          # Blackwell 96GB GDDR7
            *"RTX PRO 5000 72GB"*)   echo "72" ;;
            *"RTX PRO 5000"*)        echo "32" ;;
            *"RTX PRO 4500"*)        echo "24" ;;
            *"RTX PRO 4000"*)        echo "20" ;;
            *"RTX PRO 2000"*)        echo "16" ;;
            *"RTX 6000 Ada"*)        echo "48" ;;
            *"RTX 6000D"*)           echo "48" ;;
            *"RTX 8000"*)            echo "48" ;;          # Turing 48GB
            *"RTX 6000"*)            echo "24|48" ;;       # Turing 24GB / Ada 48GB 同名不同容量
            *"RTX 5000 Ada"*)        echo "32" ;;
            *"RTX 4500 Ada"*)        echo "24" ;;
            *"RTX 4000 SFF Ada"*)    echo "20" ;;
            *"RTX 4000 Ada"*)        echo "20" ;;
            *"RTX 2000"*)            echo "16" ;;          # 2000 Ada / 2000E Ada
            *"RTX A2000"*)           echo "6|12" ;;
            *A1000*)                 echo "4|8" ;;          # 桌面8G/移动4G；无 RTX 前缀也匹配（防落到 A100 误配触发魔改误报）
            *"RTX A400"*)            echo "4" ;;
            *"RTX A6000"*)           echo "48" ;;
            *"RTX A5000"*)           echo "24" ;;
            *"RTX A4000"*)           echo "16" ;;
            *T1000*)                 echo "4" ;;
            *T600*)                  echo "4" ;;
            *T400*)                  echo "2" ;;
            *A5000*)                 echo "24" ;;
            *A4000*)                 echo "16" ;;
            # ── 数据中心/加速卡（长型号先匹配：GH200 须在 H200 前、L20 须在 L2 前防子串误配）──
            *B300*|*GB300*)          echo "288" ;;
            *B200*|*GB200*)          echo "192" ;;
            *GH200*)                 echo "96" ;;
            *H200*)                  echo "141" ;;
            *H20*)                   echo "96" ;;
            *H100*|*H800*)           echo "80" ;;
            *AX800*|*A100*|*A800*)   echo "40|80" ;;
            *A30*|*A10*)             echo "24" ;;
            *A16*)                   echo "16" ;;
            *A40*|*L40S*|*L40*|*L20*) echo "48" ;;
            *L2*)                    echo "24" ;;
            *V100*)                  echo "16|32" ;;
            *P100*)                  echo "12|16" ;;
            *P40*)                   echo "24" ;;
            *P4*)                    echo "8" ;;
            *L4*)                    echo "24" ;;
            *T4*)                    echo "16" ;;
            # ── AMD Instinct（v1.46.1，ROCm 生态；GiB 口径与 NVIDIA 库一致）──
            *MI355X*)                echo "281" ;;
            *MI325X*)                echo "250" ;;
            *MI300X*)                echo "188" ;;
            *MI250X*)                echo "125" ;;
            *MI210*)                 echo "62" ;;
            *MI100*)                 echo "31" ;;
            *"Radeon PRO W7900"*)    echo "45" ;;
            *"Radeon PRO W6800"*)    echo "31" ;;
            # ── 消费/游戏卡（魔改重灾区）──
            *"RTX 4090"*)            echo "24" ;;
            *"RTX 4080"*)            echo "16" ;;
            *"RTX 4070"*)            echo "12" ;;
            *"RTX 4060"*)            echo "8|16" ;;
            *"RTX 3090"*)            echo "24" ;;
            *"RTX 3080 Ti"*)         echo "12" ;;
            *"RTX 3080"*)            echo "10|12" ;;
            *"RTX 3070"*)            echo "8" ;;
            *"RTX 3060"*)            echo "12" ;;
            *"RTX 2080 Ti"*)         echo "11" ;;
            *"RTX 2080"*)            echo "8" ;;
            *"GTX 1080 Ti"*)         echo "11" ;;
            *"GTX 1080"*)            echo "8" ;;
            *A2*)                    echo "16" ;;          # 放最后防误配 A2000/A1000/A400
            *)                       echo "" ;;
        esac
    }
