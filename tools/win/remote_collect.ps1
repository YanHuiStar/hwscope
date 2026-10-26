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
#   powershell -ExecutionPolicy Bypass -File remote_collect.ps1 -H root@10.0.0.1 -BmcIp 10.0.0.9   # 带外 BMC 采集（v1.54.4；BMC 密码另行提示）
#   powershell -ExecutionPolicy Bypass -File remote_collect.ps1 -H root@10.0.0.1 -BmcIp 10.0.0.9 -HgxBmcIp 10.0.0.10   # 主机 BMC + HGX 基板 BMC
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$H,          # SSH 目标 user@host
    [string]$Modules = "",                             # 可选: gpu,cpu 只采部分
    [string]$OutDir = "",                              # 本地回拉目录（默认脚本同级的 output\）
    [switch]$NoSudo = $false,                          # 远端以当前用户执行（默认 sudo）
    [string]$InstallItems = "",                        # 可选: 1,2 推送后先远端非交互装依赖（install_tool -c/-y）再采集
    # v1.54.4：带外 BMC（等价 Linux --bmc-ip / --bmc-user / --hgx-bmc-ip / --hgx-bmc-user）
    #   密码一律运行时交互输入（不落盘、不进命令行 / 进程列表 / 日志）
    [string]$BmcIp = "",
    [string]$BmcUser = "admin",
    [string]$HgxBmcIp = "",
    [string]$HgxBmcUser = "admin"
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

# ─── v1.54.16：SSH 密码只输一次（OpenSSH 原生 SSH_ASKPASS）───
#   以前三步模式要输 3 次密码（推送/执行/回拉），用户明确要求改成一次。
#   做法：开头问一次密码 → 写一个**不含密码的** askpass 脚本（只回显环境变量）→
#         后续 ssh/scp 由 OpenSSH 自己调用它取密码，全程不再打断。
#   密码只经进程环境变量传递：不落盘（askpass 文件里只有 %HWSCOPE_SSH_PW%）、不进命令行。
#   探测失败（老版本 OpenSSH 不支持 ASKPASS）时自动退回「每条命令各输一次」的老行为。
$AskPassFile = $null
$SshPwPlain  = $null
$UseAskPass  = $false
function Initialize-SshAskPass {
    $pw = $null
    # 自动化/测试可用环境变量预置（CI 场景）；交互场景一律走掩码提示
    if ($env:HWSCOPE_SSH_PASSWORD) { $pw = $env:HWSCOPE_SSH_PASSWORD }
    else {
        $sec = Read-Host -AsSecureString "SSH 密码（$H，只输这一次）"
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if ([string]::IsNullOrEmpty($pw)) { return $false }

    $script:AskPassFile = Join-Path $env:TEMP "hwscope_askpass_$TS.cmd"
    # 文件里只有变量名，没有密码本身
    Set-Content -Path $script:AskPassFile -Encoding ASCII -Value '@echo %HWSCOPE_SSH_PW%' -Force
    $env:HWSCOPE_SSH_PW     = $pw
    $env:SSH_ASKPASS        = $script:AskPassFile
    $env:SSH_ASKPASS_REQUIRE = 'force'
    $script:SshPwPlain = $pw

    # 探测：无 tty、不给交互机会时能否认证成功
    $probe = & cmd /c ("ssh -o BatchMode=no -o NumberOfPasswordPrompts=1 $SSHOpts $H `"true`" < NUL 2>&1")
    if ($LASTEXITCODE -eq 0) { return $true }
    # 失败则清掉环境，回到交互老路
    Remove-Item $script:AskPassFile -Force -ErrorAction SilentlyContinue
    Remove-Item Env:SSH_ASKPASS, Env:SSH_ASKPASS_REQUIRE, Env:HWSCOPE_SSH_PW -ErrorAction SilentlyContinue
    $script:AskPassFile = $null; $script:SshPwPlain = $null
    return $false
}
# v1.54.17：BMC 密码**先校验再开跑**。
#   现象：用户在交互提示里输错（或密码含不可见字符）时，整轮采集跑完 70 秒才发现
#   「5 条 remote_bmc_* 全 exit=1 / Unable to establish IPMI v2」——白等一轮。
#   做法：拿到密码后立刻发一条极短的 ssh（密码走 stdin、不进远端 argv）验证 BMC 认证，
#   失败就提示重输（最多 3 次），通过后才继续。
function Test-BmcPassword {
    param([string]$BmcIp, [string]$BmcUser, [string]$Password)
    if ([string]::IsNullOrEmpty($Password)) { return $false }
    $rc = 'read -r P || true; IPMI_PASSWORD="$P" timeout 25 ipmitool -E -H ' + $BmcIp + ' -U ' + $BmcUser + ' -I lanplus mc info >/dev/null 2>&1; echo rc=$?'
    $out = & { $ErrorActionPreference='Continue'; ($Password + "`n") | & ssh ($SSHOpts + $TtyOpt).Split(" ") $H $rc 2>&1 }
    return (($out -join "`n") -match 'rc=0')
}

function Clear-SshAskPass {
    if ($script:AskPassFile) { Remove-Item $script:AskPassFile -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:SSH_ASKPASS, Env:SSH_ASKPASS_REQUIRE, Env:HWSCOPE_SSH_PW -ErrorAction SilentlyContinue
    $script:AskPassFile = $null; $script:SshPwPlain = $null
}

# SSH 认证重试（最多 3 次）：仅对认证/连接类失败重试（输出含 Permission denied/密码错误），其他错误直接返回
# 注意：ForEach-Object 累积捕获 + Out-Host 强制显示——`$out = @( ... | Tee-Object )` 赋值上下文截获管道，
#       Tee-Object -Variable 是覆盖非追加（多行只留最后一行）
# v1.48.48：native 命令（tar/ssh/scp）写 stderr 在 $ErrorActionPreference="Stop" 下会抛
# NativeCommandError 中断脚本（即使 exit code=0，如 tar 的 "file changed as we read it" 警告）。
# 统一包装：内层作用域设 Continue（与 native 调用同作用域，函数级赋值对脚本块不生效），成败只信退出码
# v1.54.4：SecureString → 明文（用完由调用方置空）。BMC 密码全程只在内存里，不写临时文件。
function ConvertFrom-SecureStringPlain {
    param([System.Security.SecureString]$Sec)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

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
                    # v1.49.16 排版修复：ssh 的密码提示写 /dev/tty（不经管道、无换行），而
                    #   `Permission denied` 走 stderr 被本函数捕获后重放 —— 直接输出会接在提示
                    #   行尾部，成了 "root@x's password: Permission denied, please try again."
                    #   （用户实测报的排版）。认证类消息前先补一个换行：提示行结束、错误独立成行。
                    if ($msg -match 'Permission denied|Authentication failed|password|Host key verification') {
                        # 换行必须拼进同一输出项——Write-Host 与管道输出的交错顺序 PowerShell
                        #   不保证（mock 实测：补的空行没落到正确位置）
                        $msg = "`n$msg"
                    }
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
            # v1.49.16：连输 3 次多半不是手误——给出可操作排查方向
            if ($authFail -and $i -ge $MaxTries) {
                Write-Host "[FAIL] $Desc 连续 $MaxTries 次认证失败。" -ForegroundColor Red
                Write-Host "  可能原因：① 密码输错 ② 用户名不对（如应为 ubuntu 而非 root） ③ 远端仅允许密钥登录（PasswordAuthentication no）" -ForegroundColor Yellow
                Write-Host "  排查：先手工执行 'ssh $HostName' 确认可登录；常用目标建议配置免密（ssh-copy-id），本工具会自动复用密钥。" -ForegroundColor Gray
            }
            return $code
        }
        # v1.49.16：给出次数进度与剩余，避免用户盯着 Permission denied 不知还要输几次
        Write-Host "[认证失败 $i/$MaxTries] $Desc：密码错误或用户名不对（还剩 $($MaxTries - $i) 次）" -ForegroundColor Yellow
    }
    $ErrorActionPreference = $oldEAP
    return $code
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  HwScope 远程采集 → $H (Windows)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# v1.54.16：先问一次 SSH 密码，后续 ssh/scp 全靠 askpass 免交互（三步模式不再输 3 次）
$UseAskPass = Initialize-SshAskPass
if ($UseAskPass) {
    Write-Host "[INFO] SSH 密码已缓存（本次运行内所有 ssh/scp 复用，不再打断）" -ForegroundColor Gray
} else {
    Write-Host "[WARN] 未启用密码缓存（OpenSSH 不支持 SSH_ASKPASS 或密码为空）——按老行为逐条提示" -ForegroundColor Yellow
}

try {
    # ─── 1. 本地打包项目（PowerShell 直调 bsdtar；避免 cmd /c 管道引号地狱——cmd 会剥 ssh 命令引号并把 && 当本地分隔符） ───
    Write-Host "[INFO] 打包项目..." -ForegroundColor Yellow
    $pushFile = Join-Path $env:TEMP "hwscope_push_$TS.tgz"
    $hwArgs = ""
    if ($Modules) { $hwArgs = " --modules $Modules" }
    # v1.54.4：BMC 参数透传（与 Linux 版同形）。密码不在此处，运行时提示后经 stdin 送远端。
    if ($BmcIp)    { $hwArgs += " --bmc-ip $BmcIp --bmc-user $BmcUser" }
    if ($HgxBmcIp) { $hwArgs += " --hgx-bmc-ip $HgxBmcIp --hgx-bmc-user $HgxBmcUser" }
    # 需要本地喂 BMC 密码的条件：给了 BMC IP 且远端不需要 tty（root / -NoSudo）。
    #   单次认证模式把项目 tar 灌进 stdin，无法再用 stdin 送密码 → 此时改走三步模式。
    $NeedBmcPipe = ((($BmcIp) -or ($HgxBmcIp)) -and (-not $Sudo))
    if ($NeedBmcPipe) {
        Write-Host "[INFO] 检测到 BMC 参数：本次改用三步模式（单次认证模式的 stdin 被项目包占用，无法同时传 BMC 密码）" -ForegroundColor Gray
    }
    $rcTar = Invoke-Native { & $TarExe czf $pushFile -C $ProjectDir --exclude=output --exclude=logs --exclude=.git --exclude=*.tmp . }
    if ($rcTar -ne 0) { Write-Host "[ERROR] 本地打包失败" -ForegroundColor Red; exit 1 }

    # ─── 2~4. 推送 + 远端执行 + 回拉（v1.48.63：root/免 sudo 走单次认证模式；普通用户 + sudo 保留原三步） ───
    $pullFile = Join-Path $env:TEMP "hwscope_pull_$TS.tgz"
    $remoteOutDir = Join-Path $OutDir "remote_output"
    New-Item -ItemType Directory -Force -Path $remoteOutDir | Out-Null
    # v1.48.57：回拉前快照 remote_output 已有目录——本次导入的机器目录 = 新增目录（历史多机目录时不可全局搜 json，否则会取到旧机器）
    $dirsBefore = @(Get-ChildItem $remoteOutDir -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)

    if ((-not $Sudo) -and (-not $NeedBmcPipe)) {
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
        # v1.54.15：回拉 tar **必须只用一个 -C**（`-C DIR output logs`）。
        #   原写法 `-C $RemoteDir/output . -C $RemoteDir logs` 在 GNU tar 下报
        #   "-C ... has no effect / Exiting with failure status"（exit=2），**logs/ 根本没进包**
        #   （实测 291KB vs 607KB），而单次认证模式用 `exit $rc` 吞掉了这个错误码 → 静默丢日志包。
        $rs = "cd /tmp; rm -rf $RemoteDir; mkdir -p $RemoteDir; tar xzf - -C $RemoteDir; cd $RemoteDir; ${preCmd}bash hwscope.sh$hwArgs >&2; rc=`$?; if [ `$rc -eq 0 ]; then mkdir -p $RemoteDir/.pack; cp -a $RemoteDir/output/. $RemoteDir/.pack/ 2>/dev/null; cp -a $RemoteDir/logs $RemoteDir/.pack/logs 2>/dev/null; tar czf - --warning=no-timestamp -C $RemoteDir/.pack .; fi; rm -rf $RemoteDir; exit `$rc"
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
        $remoteRun = "mkdir -p $RemoteDir && tar xzf ${RemoteDir}.tgz -C $RemoteDir 2>/dev/null && rm -f ${RemoteDir}.tgz && cd $RemoteDir && $installCmd$Sudo bash hwscope.sh$hwArgs"
        if ($NeedBmcPipe) {
            # v1.54.4：BMC 密码通道（与 Linux 版同构）——密码只经 stdin 进远端 read，随后 export 给模块。
            #   远端命令用 ; 连接（cmd 不当分隔符），read 用 -r 防反斜杠被吃掉。
            $reads = ""; $pwLines = @()
            # v1.54.16：自动化/测试可用 $env:HWSCOPE_BMC_PASSWORD / HWSCOPE_HGX_BMC_PASSWORD 预置，
            #   交互场景仍走掩码提示（与 SSH 密码同一套约定；密码只经内存与 stdin，不落盘）
            if ($BmcIp) {
                $bmcPw = $null; $pwFromEnv = $false
                if ($env:HWSCOPE_BMC_PASSWORD) { $bmcPw = $env:HWSCOPE_BMC_PASSWORD; $pwFromEnv = $true }
                for ($try = 1; $try -le 3; $try++) {
                    if (-not $bmcPw) {
                        $sec = Read-Host -AsSecureString "主机 BMC 密码（$BmcIp）"
                        $bmcPw = ConvertFrom-SecureStringPlain $sec
                    }
                    Write-Host "[INFO] 校验 BMC 凭据（$BmcIp / $BmcUser）..." -ForegroundColor Gray
                    if (Test-BmcPassword -BmcIp $BmcIp -BmcUser $BmcUser -Password $bmcPw) {
                        Write-Host "[OK]   BMC 认证通过" -ForegroundColor Green
                        break
                    }
                    if ($pwFromEnv) {
                        # 自动化预置的密码失败就不要再问人（无人在场会卡住）——直接报错退出
                        Write-Host "[ERROR] HWSCOPE_BMC_PASSWORD 校验失败（$BmcIp / $BmcUser）：用户名或密码不对" -ForegroundColor Red
                        exit 1
                    }
                    Write-Host "[WARN] BMC 认证失败（用户名或密码不对）；请重输（第 $try/3 次）" -ForegroundColor Yellow
                    $bmcPw = $null
                }
                if (-not $bmcPw) {
                    Write-Host "[ERROR] BMC 密码 3 次校验均失败，中止（先用 ipmitool -H $BmcIp -U $BmcUser mc info 手工核对）" -ForegroundColor Red
                    exit 1
                }
                $pwLines += $bmcPw
                $reads += "read -r BMC_PASS || true; export BMC_PASS; "
            }
            if ($HgxBmcIp) {
                if ($env:HWSCOPE_HGX_BMC_PASSWORD) { $pwLines += $env:HWSCOPE_HGX_BMC_PASSWORD }
                else {
                    $sec = Read-Host -AsSecureString "HGX 基板 BMC 密码（$HgxBmcIp）"
                    $pwLines += (ConvertFrom-SecureStringPlain $sec)
                }
                $reads += "read -r HGX_BMC_PASS || true; export HGX_BMC_PASS; "
            }
            $bad = @($pwLines | Where-Object { $_ -match "[^\x20-\x7E]" })
            if ($bad.Count -gt 0) {
                Write-Host "[WARN] BMC 密码含非 ASCII 字符：Windows 版经管道可能出现编码问题，建议改用 WSL 的 tools/remote_collect.sh 跑一次" -ForegroundColor Yellow
            }
            # v1.54.15：采集完成后**在同一条 ssh 里**把结果打成远端包（tar 只用一个 -C），
            #   回拉改用 scp（与推送同一命令族，Windows 上已证明稳定），
            #   避免原来那条「ssh + cmd 重定向」的回拉调用（实测第 3 次 ssh 认证被接受但客户端立刻 255、
            #   远端命令根本没执行 → 远端临时目录残留、结果没拉回）。
            $remoteRun = "mkdir -p $RemoteDir; tar xzf ${RemoteDir}.tgz -C $RemoteDir 2>/dev/null; rm -f ${RemoteDir}.tgz; cd $RemoteDir; ${reads}$installCmd$Sudo bash hwscope.sh$hwArgs; rc=`$?; mkdir -p $RemoteDir/.pack; cp -a $RemoteDir/output/. $RemoteDir/.pack/ 2>/dev/null; cp -a $RemoteDir/logs $RemoteDir/.pack/logs 2>/dev/null; tar czf ${RemoteDir}.pull.tgz --warning=no-timestamp -C $RemoteDir/.pack .; rm -rf $RemoteDir/.pack; exit `$rc"
            $pwPayload = ($pwLines -join "`n") + "`n"
            Write-Host "[INFO] BMC 密码经 stdin 送入远端（不落盘、不进命令行）" -ForegroundColor Gray
            $rc = Invoke-SSHRetry "远端执行" { $pwPayload | & ssh ($SSHOpts + $TtyOpt).Split(" ") $H $remoteRun } -HostName $H
            $pwPayload = $null; $pwLines = @()
        } else {
            $remoteRun = "mkdir -p $RemoteDir && tar xzf ${RemoteDir}.tgz -C $RemoteDir 2>/dev/null && rm -f ${RemoteDir}.tgz && cd $RemoteDir && $installCmd$Sudo bash hwscope.sh$hwArgs; rc=`$?; mkdir -p $RemoteDir/.pack; cp -a $RemoteDir/output/. $RemoteDir/.pack/ 2>/dev/null; cp -a $RemoteDir/logs $RemoteDir/.pack/logs 2>/dev/null; tar czf ${RemoteDir}.pull.tgz --warning=no-timestamp -C $RemoteDir/.pack .; rm -rf $RemoteDir/.pack; exit `$rc"
            $rc = Invoke-SSHRetry "远端执行" { & ssh ($SSHOpts + $TtyOpt).Split(" ") $H $remoteRun } -HostName $H
        }
        if ($rc -ne 0) {
            if ($InstallItems) { Write-Host "[ERROR] 远端安装/采集失败 (exit=$rc；安装失败请检查目标机包源网络可达性)" -ForegroundColor Red }
            else { Write-Host "[ERROR] 推送或远端采集失败 (exit=$rc)" -ForegroundColor Red }
            exit $rc
        }

        # 4. 回拉结果（远端包在「远端执行」里已打好，这里用 scp 取回——与推送同一命令族）
        $rc = Invoke-SSHRetry "回拉" { & scp $SSHOpts.Split(" ") "${H}:${RemoteDir}.pull.tgz" $pullFile } -HostName $H
        if ($rc -ne 0) {
            Write-Host "[ERROR] 结果回拉失败 (exit=$rc)" -ForegroundColor Red
            Write-Host "        远端包: ${RemoteDir}.pull.tgz（可手工 scp 回来排查）" -ForegroundColor Gray
            exit 1
        }
        # 远端清理：**不再单独开一条 ssh**（那会变成第 4 次密码输入，且实测这条路最容易出问题）。
        #   远端临时目录与 pull 包留在 /tmp，由系统清理策略回收；如要立刻清，可手工：
        #     ssh <host> "rm -rf /tmp/hwscope_remote_*"
        Write-Host "[INFO] 远端临时目录保留（/tmp/hwscope_remote_*），由系统清理" -ForegroundColor Gray
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
    # v1.53.19：记录**本轮实际写入的机器目录**（SN），完成信息据此定位，不再靠前后快照差集猜
    $replacedSNs = @()
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
        $replacedSNs += $sn
        $dst = Join-Path $remoteOutDir $sn
        # v1.51.0：回拉一律**清空重建**（对齐 hwscope.sh 的 `rm -rf $OUTPUT_BASE` 覆盖语义）。
        #   原先「有归档才敢删、无归档就增量覆盖 + 残留检测」整体删除，原因：
        #     ① 归档被人工移走是常态 → 绝大多数回拉到不了"可安全清空"，全部落到"不删"分支；
        #     ② 报告端「按文件名找数据」的前提是「目录内文件同属一次采集」→ 残留的旧文件被当本次数据读，
        #        新采集数据被污染（本次未采的模块、已拔掉的外设日志等），报告给出错误结论且从外观看不出来；
        #     ③ 「保护旧数据」实无必要——历史留存由 logs/remote_logs/ 的归档承担（每次回拉都归档一份），
        #        output/remote_output/<SN>/ 只是回拉的落脚点，不是唯一副本；
        #     ④ 那套逻辑还带来过一次误报（两侧相对路径基准不一致 → 全部文件被判为残留）。
        #   结论：多余的复杂度换来了数据错乱风险，删掉。
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item (Join-Path $sd.FullName '*') -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
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

    # ─── 5. 完成信息（v1.53.19：以**本轮实际写入的机器目录** $replacedSNs 定位。原实现用"回拉前后目录差集"——
    #   多台并发采集时，每边都会看到对方新建的目录，$newDirs[0] 取任意一个 →
    #   实测多台同采：B 机横幅印成了 A 机的 SN 及其归档包，而中间 [ARCHIVE] 行是对的） ───
    $dirsAfter = @(Get-ChildItem $remoteOutDir -Directory -ErrorAction SilentlyContinue)
    $pulled = $null
    foreach ($rsn in $replacedSNs) {
        $cand = Join-Path $remoteOutDir $rsn
        if (Test-Path (Join-Path $cand "hwscope_report.json")) { $pulled = Get-Item $cand; break }
        if (-not $pulled -and (Test-Path $cand)) { $pulled = Get-Item $cand }   # 报告生成失败时也先记住本轮目录
    }
    if (-not $pulled) {
        $newDirs = @($dirsAfter | Where-Object { $dirsBefore -notcontains $_.Name })
        $pulled = if ($newDirs.Count -gt 0) { $newDirs[0] } else { $dirsAfter | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
    }
    if (-not $pulled) { $pulled = Get-ChildItem $remoteOutDir -Recurse -Depth 1 -Filter "hwscope_report.json" -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.Directory } }
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  远程采集完成" -ForegroundColor Green
    if ($pulled) {
        Write-Host "  采集目录: $($pulled.FullName)"
        $reports = Get-ChildItem $pulled.FullName -Filter "hwscope_report.*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        if ($reports) { Write-Host "  报告: $($reports -join ' ')" }
        # v1.53.6: also report the archive path -- pull also archives remote logs/ into
        #   logs/remote_logs\<SN>-<timestamp>.tar.gz, which the completion banner never mentioned.
        #   Match by this machine's folder name (SN) prefix + newest, so other machines' archives are not picked.
        $remoteLogsDir = Join-Path $ProjectDir "logs/remote_logs"
        $arc = Get-ChildItem $remoteLogsDir -Filter "$($pulled.Name)-*.tar.gz" -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($arc) { Write-Host "  归档包: $($arc.FullName)" }
        else      { Write-Host "  归档包: (not found: $($pulled.Name)-*.tar.gz)" }
    } else {
        Write-Host "  采集目录: (未定位到本次采集目录，请检查 $remoteOutDir)" -ForegroundColor Yellow
    }
    Write-Host "========================================" -ForegroundColor Green
}
finally {
    # 远端清理已在执行/回拉命令内完成（rm -rf 随远端脚本执行）；此处无额外 ssh（避免再要密码）
    # v1.48.65：本地临时包改为无条件清理——原实现只在成功路径 Remove-Item，认证失败/中途 exit 时
    # 会把 hwscope_push_*.tgz / hwscope_pull_*.tgz 残留在 %TEMP%（实测多次失败后累积）
    if ($pushFile) { Remove-Item $pushFile -Force -ErrorAction SilentlyContinue }
    if ($pullFile) { Remove-Item $pullFile -Force -ErrorAction SilentlyContinue }
    # v1.54.16：清掉 askpass 脚本与内存中的密码
    Clear-SshAskPass
}
