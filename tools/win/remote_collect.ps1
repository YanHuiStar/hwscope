# =============================================================================
# remote_collect.ps1 — Windows 原生远程采集（等价 tools/remote_collect.sh）
# 功能: 从 Windows 运维机 SSH 远程执行 HwScope 采集并回拉结果
#   1. tar 推送项目（排除 output/logs/.git）→ 2. 远端执行 hwscope.sh → 3. 结果回拉 → 4. 清理远端
# 依赖: Windows 自带 OpenSSH 客户端 (ssh/scp) + tar (bsdtar, Win10 1803+；v1.48.48 起显式
#       调用 System32 bsdtar——PATH 里的 Git for Windows GNU tar 会把 C:\ 盘符当远程主机致打包失败)——零新依赖
# 凭据（安全立场）: 默认交互式密码（每次登录输入，不落盘）——生产环境标准做法；
#   SSH key 免密仅建议受信内部网络使用（私钥泄露=所有配置了公钥的主机失守，风险扩散）。
# 用法:
#   powershell -ExecutionPolicy Bypass -File remote_collect.ps1 -H root@10.0.0.1
#   powershell -ExecutionPolicy Bypass -File remote_collect.ps1 -H root@10.0.0.1 -Modules gpu,cpu
#   powershell -ExecutionPolicy Bypass -File remote_collect.ps1 -H root@10.0.0.1 -OutDir D:\hwout
#   powershell -ExecutionPolicy Bypass -File remote_collect.ps1 -H root@10.0.0.1 -InstallItems 1,2   # 先远端装基础+压测依赖再采集（v1.42.1，等价 Linux --install）
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$H,          # SSH 目标 user@host
    [string]$Modules = "",                             # 可选: gpu,cpu 只采部分
    [string]$OutDir = "",                              # 本地回拉目录（默认脚本同级的 output\）
    [switch]$NoSudo = $false,                          # 远端以当前用户执行（默认 sudo）
    [string]$InstallItems = ""                         # 可选: 1,2 推送后先远端非交互装依赖（install_tool -c/-y）再采集
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# ─── 依赖检查（Windows 自带） ───
foreach ($cmd in @("ssh", "scp", "tar")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] 未找到 $cmd。Windows 安装 OpenSSH 客户端：设置 → 应用 → 可选功能 → OpenSSH 客户端" -ForegroundColor Red
        exit 1
    }
}

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent (Split-Path -Parent $ScriptRoot)   # tools\win → tools → 项目根（hwscope.sh 所在）
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $ProjectDir "output" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$TS = Get-Date -Format "yyyyMMddHHmmss"
$RemoteDir = "/tmp/hwscope_remote_$TS"
$RemoteOut = "$RemoteDir/remote_output"
# Windows OpenSSH 不支持 ControlMaster multiplexing（ControlPath=/tmp 无效会报 getsockname failed），
# 故合并 ssh 调用：推送一次、执行一次、回拉一次（共 3 次密码提示，每次认证失败自动重试最多 3 次）
$SSHOpts = "-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"
# v1.48.48：显式用 Windows 自带 bsdtar（System32，Win10 1803+）——PowerShell 的 `tar` 可能解析到
# Git for Windows 的 GNU tar，它把 "C:\..." 的盘符冒号当远程主机语法（报 "Cannot connect to C:
# resolve failed"）导致本地打包/解包静默失败；无自带 bsdtar 的老系统回退 PATH 的 tar
$TarExe = if (Test-Path "$env:SystemRoot\System32\tar.exe") { "$env:SystemRoot\System32\tar.exe" } else { "tar" }
# root 用户自动免 sudo（root 登录无需提权）；普通用户 + sudo 步骤需要 tty（-t）才能交互输 sudo 密码
$IsRoot = $H -like "root@*"
$Sudo = if ($NoSudo -or $IsRoot) { "" } else { "sudo" }
$TtyOpt = if ($Sudo) { " -t" } else { "" }

# SSH 认证重试（最多 3 次）：仅对认证/连接类失败重试（输出含 Permission denied/密码错误），其他错误直接返回
# 注意：ForEach-Object 累积捕获 + Out-Host 强制显示——`$out = @( ... | Tee-Object )` 赋值上下文截获管道，
#       Tee-Object -Variable 是覆盖非追加（多行只留最后一行）
# v1.48.48：native 命令（tar/ssh/scp）写 stderr 在 $ErrorActionPreference="Stop" 下会抛
# NativeCommandError 中断脚本（即使 exit code=0，如 tar 的 "file changed as we read it" 警告）。
# 统一包装：内层作用域设 Continue（与 native 调用同作用域，函数级赋值对脚本块不生效），成败只信退出码
function Invoke-Native {
    param([scriptblock]$Action)
    & { $ErrorActionPreference = "Continue"; & $Action 2>&1 } | Out-Host
    return $LASTEXITCODE
}

function Invoke-SSHRetry {
    param([string]$Desc, [scriptblock]$Action, [int]$MaxTries = 3, [string]$HostName = "")
    # v1.48.24：native 命令（scp/ssh）写 stderr 的 Warning（如 host key "Permanently added"）在
    # $ErrorActionPreference="Stop" 下会抛 NativeCommandError 中断脚本——即使 exit code=0。
    # 此处临时降级为 Continue，成败只信 $LASTEXITCODE（连接/认证失败 exit≠0 仍会被捕获重试）
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    # v1.48.82：改为「噪音白名单」——只压制 ssh/OpenSSH 客户端自身的提示，
    #   不再整类丢弃 stderr。v1.48.51 的 `-isnot [ErrorRecord]` 会把 stderr 全吞，
    #   而单次认证模式让 `bash hwscope.sh >&2` 走 stderr（避开 stdout 上的 tar 流），
    #   结果采集进度全部消失、只剩头尾几行（用户报"输出被吞"）。
    $NoisePat = 'Permanently added|REMOTE HOST IDENTIFICATION|Host key verification failed|Offending (RSA|ED25519|ECDSA) key|NativeCommandError|^\s*\+\s*(CategoryInfo|FullyQualifiedErrorId)|^\s*\+ '
    $keyHandled = $false
    for ($i = 1; $i -le $MaxTries; $i++) {
        $out = @()
        # v1.48.53 修复：v1.48.51 误用 `$raw = & $Action` 先整体捕获——PowerShell 会消费完 native
        # 全部输出才赋值，导致远端采集"全部完成才输出"（用户误判卡死）。必须保持管道流式：
        # native 输出逐行进入 ForEach-Object 即时显示（下同：勿再引入 `$x = & $cmd` 形式的捕获）
        & { $ErrorActionPreference = "Continue"; & $Action 2>&1 } | ForEach-Object {
            $line = "$_"
            $out += $line
            if ($_ -isnot [System.Management.Automation.ErrorRecord]) { $_ }        # stdout：原样显示
            else {
                # v1.48.83：stderr 必须输出 Exception.Message（真实文本），不能输出 "$_"
                #   ——ErrorRecord 字符串化对空消息返回类型名（System.Management.Automation.RemoteException），
                #   会把远端 stderr 的空行刷成这串字（用户报"空行排版没了"）；Message 为空时输出单空格占位，
                #   既不破坏管道流式又能保住原空行（空串会被 PowerShell 管道丢弃）
                if ($line -notmatch $NoisePat) {
                    $msg = $_.Exception.Message
                    if ([string]::IsNullOrEmpty($msg)) { ' ' } else { $msg }
                }
            }
        } | Out-Host
        $code = $LASTEXITCODE

        # ── 方案 A：主机密钥变更自动处理（v1.48.82，用户选定）──
        # 流动盘/重装场景下 host key 变化是常态。此处：备份 known_hosts → 删除该主机旧记录 →
        # 提示新旧指纹 → 自动重试一次。仅对「已知主机的 key 变化」放行，未知主机仍走 accept-new。
        $keyChanged = (($out -join "`n") -match "REMOTE HOST IDENTIFICATION HAS CHANGED")
        if ($keyChanged -and -not $keyHandled -and $HostName) {
            $keyHandled = $true
            $hkHost = ($HostName -replace '^[^@]+@', '')
            $kh = Join-Path $env:USERPROFILE ".ssh\known_hosts"
            Write-Host "[WARN] $hkHost 的主机密钥已变化（重装系统/换盘）——自动处理中..." -ForegroundColor Yellow
            if (Test-Path $kh) {
                $bak = "$kh.bak-$(Get-Date -Format 'yyyyMMddHHmmss')"
                Copy-Item $kh $bak -Force
                Write-Host "[INFO]   已备份 known_hosts → $(Split-Path $bak -Leaf)" -ForegroundColor Gray
            }
            # 记录变更前指纹（供事后核对是否被真实替换）
            $oldFp = & ssh-keygen -F $hkHost 2>$null | Where-Object { $_ -and $_ -notmatch '^#' }
            if ($oldFp) {
                $oldSum = ($oldFp | ssh-keygen -lf - 2>$null) -join ' / '
                Write-Host "[INFO]   旧指纹: $oldSum" -ForegroundColor DarkGray
            }
            & ssh-keygen -R $hkHost 2>&1 | Out-Null
            Write-Host "[INFO]   已清除旧记录，重新连接以接受新密钥（指纹如下，请核对是否为预期机器）" -ForegroundColor Gray
            $newFp = & ssh-keyscan -T 5 $hkHost 2>$null
            if ($newFp) {
                $newSum = ($newFp | ssh-keygen -lf - 2>$null) -join ' / '
                Write-Host "[INFO]   新指纹: $newSum" -ForegroundColor DarkGray
            }
            Write-Host "[INFO]   重试 $Desc ..." -ForegroundColor Yellow
            $i--          # 本次不计入重试次数
            continue
        }

        if ($code -eq 0) { $ErrorActionPreference = $oldEAP; return 0 }
        $authFail = (($out -join "`n") -match "Permission denied|password.*incorrect|Authentication failed")
        if (-not $authFail -or $i -ge $MaxTries) {
            $ErrorActionPreference = $oldEAP
            # v1.48.51：非认证类失败（或重试用尽）时给出 stderr 摘要——平时抑制避免 NativeCommandError 红块，
            # 真失败时保留可诊断性（认证失败重试中不打印，最终失败才提示）
            if ($code -ne 0 -and $out.Count -gt 0) {
                Write-Host "  [原因] $(($out | Where-Object { $_ } | Select-Object -First 2) -join ' / ')" -ForegroundColor DarkGray
            }
            return $code
        }
        Write-Host "[WARN] $Desc 认证失败（密码错误？），重试 $i/$MaxTries ..." -ForegroundColor Yellow
    }
    $ErrorActionPreference = $oldEAP
    return $code
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  HwScope 远程采集 → $H (Windows)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
    # ─── 1. 本地打包项目（PowerShell 直调 bsdtar；避免 cmd /c 管道引号地狱——cmd 会剥 ssh 命令引号并把 && 当本地分隔符） ───
    Write-Host "[INFO] 打包项目..." -ForegroundColor Yellow
    $pushFile = Join-Path $env:TEMP "hwscope_push_$TS.tgz"
    $hwArgs = ""
    if ($Modules) { $hwArgs = " --modules $Modules" }
    $rcTar = Invoke-Native { & $TarExe czf $pushFile -C $ProjectDir --exclude=output --exclude=logs --exclude=.git --exclude=*.tmp . }
    if ($rcTar -ne 0) { Write-Host "[ERROR] 本地打包失败" -ForegroundColor Red; exit 1 }

    # ─── 2~4. 推送 + 远端执行 + 回拉（v1.48.63：root/免 sudo 走单次认证模式；普通用户 + sudo 保留原三步） ───
    $pullFile = Join-Path $env:TEMP "hwscope_pull_$TS.tgz"
    $remoteOutDir = Join-Path $OutDir "remote_output"
    New-Item -ItemType Directory -Force -Path $remoteOutDir | Out-Null
    # v1.48.57：回拉前快照 remote_output 已有目录——本次导入的机器目录 = 新增目录（历史多机目录时不可全局搜 json，否则会取到旧机器）
    $dirsBefore = @(Get-ChildItem $remoteOutDir -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)

    if (-not $Sudo) {
        # ── 单次认证模式（v1.48.63）：一条 ssh 连接完成 推送 → 采集 → 回拉，全程只输 1 次密码 ──
        # 做法：本地 tar 经 stdin 送入（远端 `tar xzf -` 直接解包）；远端采集输出重定向到 stderr
        #       （本地仍逐行实时可见）；结果 tar 从 stdout 回来，由 cmd /c 重定向落盘（二进制安全，
        #       不经 PowerShell 管道）。对比原三步：不再有三次独立认证（原每步各带 ConnectTimeout=10，
        #       密码输得慢就容易超时），也没有步骤间的等待。
        # 限制：stdin 要承载数据，故不能加 -t —— 仅适用于 root/免 sudo 场景（普通用户 + sudo 需 tty
        #       交互输 sudo 密码，与 stdin 冲突 → 走下方原三步流程）。
        # 注意：远端脚本只用 ; 连接、不用 &&（cmd 会剥 ssh 命令引号并把 && 当本地分隔符）；
        #       双引号串内的 $? / $rc 必须用反引号转义，否则会被 PowerShell 本地展开。
        Write-Host "[INFO] 单次认证模式：一次 ssh 完成 推送 → 采集 → 回拉（只需输 1 次密码）..." -ForegroundColor Yellow
        $preCmd = ""
        if ($InstallItems) {
            $preCmd = "bash tools/install_tool.sh -c $InstallItems -y; rc=`$?; if [ `$rc -ne 0 ]; then rm -rf $RemoteDir; exit `$rc; fi; "
            Write-Host "[INFO]   远端先非交互安装依赖: install_tool -c $InstallItems -y" -ForegroundColor Gray
        }
        $rs = "cd /tmp; rm -rf $RemoteDir; mkdir -p $RemoteDir; tar xzf - -C $RemoteDir; cd $RemoteDir; ${preCmd}bash hwscope.sh$hwArgs >&2; rc=`$?; if [ `$rc -eq 0 ]; then tar czf - --warning=no-timestamp -C $RemoteDir/output . -C $RemoteDir logs; fi; rm -rf $RemoteDir; exit `$rc"
        $rc = Invoke-SSHRetry "远程采集" { & cmd /c ("ssh $SSHOpts -T $H `"$rs`" < `"$pushFile`" > `"$pullFile`"") } -HostName $H
        if ($rc -ne 0) {
            if ($InstallItems) { Write-Host "[ERROR] 远端安装/采集失败 (exit=$rc；安装失败请检查目标机包源可达性)" -ForegroundColor Red }
            else { Write-Host "[ERROR] 远程采集失败 (exit=$rc)" -ForegroundColor Red }
            exit $rc
        }
    } else {
        # ── 原三步模式：普通用户 + sudo（sudo 需 tty 交互输密码，无法与 stdin 传数据共存） ──
        Write-Host "[INFO] 三步模式（普通用户 + sudo 需 tty）：推送 → 执行 → 回拉（3 次密码）..." -ForegroundColor Yellow
        # 2. scp 推送（认证失败自动重试）
        $rc = Invoke-SSHRetry "scp 推送" { & scp $SSHOpts.Split(" ") $pushFile "${H}:${RemoteDir}.tgz" } -HostName $H
        if ($rc -ne 0) { Write-Host "[ERROR] 项目推送失败 (exit=$rc)" -ForegroundColor Red; exit 1 }

        # 3. ssh 解包 + 远端执行（不传 --output：hwscope.sh 默认输出 <远端>/output/<MACHINE_ID>/，对标本地 output/<SN> 结构）
        $installCmd = ""
        if ($InstallItems) {
            $installCmd = "$Sudo bash tools/install_tool.sh -c $InstallItems -y && "
        }
        Write-Host "[INFO] 远端执行: $Sudo bash hwscope.sh$hwArgs（默认输出 output/<MACHINE_ID>/）" -ForegroundColor Yellow
        $rc = Invoke-SSHRetry "远端执行" { & ssh ($SSHOpts + $TtyOpt).Split(" ") $H "mkdir -p $RemoteDir && tar xzf ${RemoteDir}.tgz -C $RemoteDir 2>/dev/null && rm -f ${RemoteDir}.tgz && cd $RemoteDir && $installCmd$Sudo bash hwscope.sh$hwArgs" } -HostName $H
        if ($rc -ne 0) {
            if ($InstallItems) { Write-Host "[ERROR] 远端安装/采集失败 (exit=$rc；安装失败请检查目标机包源网络可达性)" -ForegroundColor Red }
            else { Write-Host "[ERROR] 推送或远端采集失败 (exit=$rc)" -ForegroundColor Red }
            exit $rc
        }

        # 4. 回拉结果（-C 切换打包 output/<MACHINE_ID>/ 内容 + logs/）+ 顺带清理远端
        #    （cmd /c 仅做二进制重定向；远端命令用 ; 连接——cmd 不拆 ;，bash 正常解析）
        $rc = Invoke-SSHRetry "回拉" { & cmd /c ("ssh $SSHOpts$TtyOpt $H `"$Sudo tar czf - --warning=no-timestamp -C $RemoteDir/output . -C $RemoteDir logs 2>/dev/null; rm -rf $RemoteDir`" > `"$pullFile`"") }
        if ($rc -ne 0) { Write-Host "[ERROR] 结果回拉失败 (exit=$rc)" -ForegroundColor Red; exit 1 }
    }
    Remove-Item $pushFile -Force -ErrorAction SilentlyContinue

    # v1.48.99：改为**先解到暂存目录**再逐机器精准替换——原实现直接 `tar x -C remoteOutDir` 是纯覆盖式解包，
    #   只覆盖同名文件，**旧版本产生过、新版本不再产生的文件会永久残留**（如 nvswitch_smi_*.log）。
    #   后果：报告端的兜底路径（「fan/ 空就读 bmc/ipmi_sensors.log」等）**假设目录内文件同属一次采集**，
    #   在残留场景下会把旧批次文件当本次数据渲染。本地采集有 rm -rf 清目录故无此问题，
    #   缺口只在远程这一条路径（对标 sh 版 hwscope.sh v1.45.6/v1.45.10 的「清空 + 归档校验」）。
    $stage = Join-Path $env:TEMP "hwscope_stage_$TS"
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $rcUntar = Invoke-Native { & $TarExe xzf $pullFile -C $stage }
    if ($rcUntar -ne 0) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "[ERROR] 回拉数据损坏或为空（远端打包失败？）" -ForegroundColor Red; exit 1 }   # 第二道防线：远端 tar 失败时 pullFile 空/坏
    Remove-Item $pullFile -Force -ErrorAction SilentlyContinue

    $remoteLogsDirEarly = Join-Path $ProjectDir "logs/remote_logs"
    New-Item -ItemType Directory -Force -Path $remoteOutDir | Out-Null
    New-Item -ItemType Directory -Force -Path $remoteLogsDirEarly | Out-Null
    foreach ($sd in Get-ChildItem $stage -Directory -Force -ErrorAction SilentlyContinue) {
        $sn = $sd.Name
        # logs/ 不是机器目录，搬到固定位置交给下方原流程
        if ($sn -eq 'logs') {
            $lg = Join-Path $remoteOutDir "logs"
            New-Item -ItemType Directory -Force -Path $lg | Out-Null
            Copy-Item (Join-Path $sd.FullName '*') -Destination $lg -Recurse -Force -ErrorAction SilentlyContinue
            continue
        }
        # 护栏①：机器目录名只允许 [A-Za-z0-9_-]（防路径穿越/误删）  ②：过短名跳过
        if ($sn -notmatch '^[A-Za-z0-9_-]+$') { Write-Host "[WARN] 跳过非法的机器目录名: $sn" -ForegroundColor Yellow; continue }
        if ($sn.Length -lt 4) { Write-Host "[WARN] 跳过过短的机器目录名: $sn" -ForegroundColor Yellow; continue }
        $dst = Join-Path $remoteOutDir $sn
        $residCheck = $false
        if (Test-Path $dst) {
            # 覆盖前归档校验（对标 hwscope.sh v1.45.10）：有归档且归档不早于目录内容 → 可安全清空；
            # 否则保留旧目录改为增量覆盖，**绝不静默删除未归档数据**。
            # v1.49.10：归档被人工移走是常规操作，原先每次都打 WARN → 纯噪音，降级为 INFO；
            #   同时补一道真风险检查：增量覆盖会留下"本次没拉到"的旧文件，而报告端按文件名找数据，
            #   会读到过期内容。覆盖后用**文件清单差集**判定（不用时间戳——Copy-Item 保留原始
            #   时间戳，远端采集时间常早于本次回拉，用时间比会把本次文件误判为残留）。
            $arch = Get-ChildItem $remoteLogsDirEarly -Filter "$sn-*.tar.gz" -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $newerThanArch = if ($arch) {
                Get-ChildItem $dst -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -gt $arch.LastWriteTime } | Select-Object -First 1
            } else { $null }
            if ($arch -and -not $newerThanArch) {
                Remove-Item $dst -Recurse -Force
                Write-Host "[INFO] ${sn}: 已清空旧目录（历史留存于 $($arch.Name)）" -ForegroundColor Yellow
            } else {
                Write-Host "[INFO] ${sn}: 旧目录已存在、无归档可比对（归档常被人工移走）→ 增量覆盖，不删任何文件" -ForegroundColor Yellow
                $residCheck = $true
            }
        }
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item (Join-Path $sd.FullName '*') -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
        # v1.49.10：残留检测——本次没拉到的旧文件会留下，报告端可能读到过期数据。只列前 5 个 + 总数。
        if ($residCheck) {
            $rel = { param($p) $p.Substring($dst.Length).TrimStart('\', '/') }
            $pulled = New-Object System.Collections.Generic.HashSet[string]
            Get-ChildItem $sd.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                [void]$pulled.Add((& $rel $_.FullName))
            }
            $resid = Get-ChildItem $dst -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
                -not $pulled.Contains((& $rel $_.FullName))
            }
            if ($resid -and $resid.Count -gt 0) {
                Write-Host "[WARN] ${sn}: 有 $($resid.Count) 个旧文件本次未拉到，仍留在目录里（报告端可能读到过期数据）：" -ForegroundColor Yellow
                $resid | Select-Object -First 5 | ForEach-Object { Write-Host "        $((& $rel $_.FullName))" -ForegroundColor Yellow }
                if ($resid.Count -gt 5) { Write-Host "        …另有 $($resid.Count - 5) 个（完整列表见 $dst）" -ForegroundColor Yellow }
                Write-Host "        如需干净目录：删除 $dst 后重跑本次回拉" -ForegroundColor Yellow
            }
        }
    }
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

    # 归档包移到 logs\remote_logs\（与本地采集日志区分；远端 logs/ 解包到了 remote_output\logs）
    # 合并逻辑：report 子目录目标已存在时逐个移入（Move-Item 目录到非空目录会报错——重复跑场景）
    $outLogs = Join-Path $remoteOutDir "logs"
    if (Test-Path $outLogs) {
        $remoteLogsDir = Join-Path $ProjectDir "logs\remote_logs"
        New-Item -ItemType Directory -Force -Path $remoteLogsDir | Out-Null
        foreach ($item in Get-ChildItem $outLogs -Force) {
            $dest = Join-Path $remoteLogsDir $item.Name
            if ($item.PSIsContainer) {
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                Get-ChildItem $item.FullName -Force | Move-Item -Destination $dest -Force -ErrorAction SilentlyContinue
            } else {
                Move-Item $item.FullName -Destination $remoteLogsDir -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item $outLogs -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "[INFO] 已清理远端临时目录: $RemoteDir" -ForegroundColor Yellow

    # ─── 5. 完成信息（v1.48.57：以"回拉前后目录快照的差集"定位本次机器目录——勿全局搜 json：remote_output 下存有多台历史机器时会取到旧机器；覆盖同一台时取最新修改目录兜底） ───
    $dirsAfter = @(Get-ChildItem $remoteOutDir -Directory -ErrorAction SilentlyContinue)
    $newDirs = @($dirsAfter | Where-Object { $dirsBefore -notcontains $_.Name })
    $pulled = if ($newDirs.Count -gt 0) { $newDirs[0] } else { $dirsAfter | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
    if (-not $pulled) { $pulled = Get-ChildItem $remoteOutDir -Recurse -Depth 1 -Filter "hwscope_report.json" -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.Directory } }
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  远程采集完成" -ForegroundColor Green
    Write-Host "  采集目录: $($pulled.FullName)"
    $reports = Get-ChildItem $pulled.FullName -Filter "hwscope_report.*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    if ($reports) { Write-Host "  报告: $($reports -join ' ')" }
    Write-Host "========================================" -ForegroundColor Green
}
finally {
    # 远端清理已在执行/回拉命令内完成（rm -rf 随远端脚本执行）；此处无额外 ssh（避免再要密码）
    # v1.48.65：本地临时包改为无条件清理——原实现只在成功路径 Remove-Item，认证失败/中途 exit 时
    # 会把 hwscope_push_*.tgz / hwscope_pull_*.tgz 残留在 %TEMP%（实测多次失败后累积）
    if ($pushFile) { Remove-Item $pushFile -Force -ErrorAction SilentlyContinue }
    if ($pullFile) { Remove-Item $pullFile -Force -ErrorAction SilentlyContinue }
}
