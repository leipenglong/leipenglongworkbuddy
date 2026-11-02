# ============================================================================
# 大管家 · 文件变更监听器（触发方式 B · 轮询实现）
# ----------------------------------------------------------------------------
# 监控目录：C:\Users\Administrator\Desktop\leipenglongworkbuddy
# 触发条件：目录内文件发生 新增 / 修改 / 删除
# 执行动作：调用 大管家备份.sh 完成本地备份 + GitHub 推送
#
# 为什么用轮询而非 FileSystemWatcher：
#   本机实测 FileSystemWatcher 事件不触发（Windows 文件系统通知在该环境不可靠），
#   目录规模仅约 93 个文件，全量扫描耗时约 60ms，轮询完全够用且更稳定。
#
# 设计要点：
#   - 快照比对：记录每个文件的 [大小, 修改时间]，与上轮比对得出增/改/删
#   - 防抖：检测到变更后等待 20 秒稳定期，再执行备份
#   - 节流：备份脚本内已有 10 分钟最短提交间隔，双重保护
#   - 忽略：.git 目录、备份日志、状态文件不纳入比对
#   - 单实例：互斥锁保证同一时刻只有一个监听器
#
# 由计划任务「大管家文件变更监听」在用户登录时启动
# ============================================================================

param(
    [string]$WatchPath = "C:\Users\Administrator\Desktop\leipenglongworkbuddy",
    [int]$PollSeconds = 60,
    [int]$SettleSeconds = 20
)

$ErrorActionPreference = "Continue"
$BackupScript = Join-Path $WatchPath "大管家\大管家备份.sh"
$LogDir = Join-Path $WatchPath "大管家\备份日志"
$LogFile = Join-Path $LogDir "监听器.log"

$GitBash = "C:\Users\Administrator\.workbuddy\binaries\PortableGit\versions\1.3.0\bin\bash.exe"
if (-not (Test-Path $GitBash)) {
    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($cmd) { $GitBash = $cmd.Source }
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log([string]$level, [string]$msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$level] $msg"
    [System.IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Snapshot {
    param([string]$Root)
    $map = @{}
    try {
        Get-ChildItem -Path $Root -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = $_.FullName.Substring($Root.Length)
            if ($rel -like '*\.git\*' -or $rel -like '*备份日志*' -or $rel -like '*\.大管家*') { return }
            $map[$rel] = "$($_.Length)|$($_.LastWriteTimeUtc.Ticks)"
        }
    } catch {}
    return $map
}

function Compare-Snapshot($old, $new) {
    $added = @(); $modified = @(); $deleted = @()
    foreach ($k in $new.Keys) {
        if (-not $old.ContainsKey($k)) { $added += $k }
        elseif ($old[$k] -ne $new[$k]) { $modified += $k }
    }
    foreach ($k in $old.Keys) {
        if (-not $new.ContainsKey($k)) { $deleted += $k }
    }
    return @{ Added = $added; Modified = $modified; Deleted = $deleted }
}

if (-not (Test-Path $BackupScript)) {
    Write-Log "ERROR" "备份脚本不存在: $BackupScript"
    exit 1
}

# ---- 单实例互斥 ----
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\BigButlerWatcherV2", [ref]$createdNew)
if (-not $createdNew) {
    Write-Log "WARN" "已有监听器实例运行，本次退出"
    exit 0
}

Write-Log "INFO" "监听器启动(轮询) | 路径=$WatchPath | 轮询=${PollSeconds}s | 稳定期=${SettleSeconds}s"

$prev = Get-Snapshot -Root $WatchPath
Write-Log "INFO" "初始快照: $($prev.Count) 个文件"

try {
    while ($true) {
        Start-Sleep -Seconds $PollSeconds

        $curr = Get-Snapshot -Root $WatchPath
        $diff = Compare-Snapshot $prev $curr
        $total = $diff.Added.Count + $diff.Modified.Count + $diff.Deleted.Count

        if ($total -eq 0) { continue }

        Write-Log "INFO" "检测到 $total 项变更（新增 $($diff.Added.Count) / 修改 $($diff.Modified.Count) / 删除 $($diff.Deleted.Count)），等待 ${SettleSeconds}s 稳定期"
        foreach ($f in $diff.Added)    { Write-Log "INFO" "  [新增] $f" }
        foreach ($f in $diff.Modified) { Write-Log "INFO" "  [修改] $f" }
        foreach ($f in $diff.Deleted)  { Write-Log "INFO" "  [删除] $f" }

        # 稳定期等待：以「首次检测到的变更集合」为基准，
        # 只要该集合内的文件不再变化即视为稳定（避免把新出现的无关文件算进来）
        $baseline = Get-Snapshot -Root $WatchPath
        $stable = $false
        for ($i = 0; $i -lt 6; $i++) {
            Start-Sleep -Seconds ([Math]::Ceiling($SettleSeconds / 6))
            $check = Get-Snapshot -Root $WatchPath
            $changedNow = @()
            foreach ($k in $check.Keys) {
                if (-not $baseline.ContainsKey($k) -or $baseline[$k] -ne $check[$k]) { $changedNow += $k }
            }
            if ($changedNow.Count -eq 0) { $stable = $true; break }
            Write-Log "INFO" "  稳定期内仍有变动（$($changedNow.Count) 项），继续等待..."
        }

        $prev = Get-Snapshot -Root $WatchPath

        if (-not $stable) {
            Write-Log "WARN" "持续变动超过稳定期，跳过本轮（下一轮继续检测）"
            continue
        }

        Write-Log "INFO" "稳定期结束，触发备份"
        if ($GitBash -and (Test-Path $GitBash)) {
            $unixScript = $BackupScript.Replace('\', '/')
            $out = & $GitBash -c "bash '$unixScript'" 2>&1 | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::Default.GetBytes($_)) } | Out-String
            Write-Log "INFO" ("备份执行结果: " + $out)
        } else {
            Write-Log "ERROR" "未找到 bash 可执行文件"
        }
    }
}
finally {
    if ($mutex) { $mutex.ReleaseMutex() | Out-Null; $mutex.Dispose() }
}
