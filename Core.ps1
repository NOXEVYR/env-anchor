Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Save-State($State, $Store) {
    Assert-StorePaths $Store
    $path = Join-Path $Store 'state.json'
    $temp = "$path.tmp"
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temp, $path, "$path.bak") }
    else { [IO.File]::Move($temp, $path) }
}
function Read-State($Store) {
    Assert-StorePaths $Store
    $state = Get-Content -LiteralPath (Join-Path $Store 'state.json') -Raw | ConvertFrom-Json
    Assert-StateSchema $state $Store
    return $state
}
function Assert-CanonicalPath($Value, $Field) {
    if ($Value -isnot [string] -or -not $Value -or -not [IO.Path]::IsPathRooted($Value) -or
        $Value -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+(?:\\|$))' -or
        $Value.Contains('/') -or $Value -match '[\x00-\x1f*?]' -or $Value -match '(?<!^[A-Za-z]):') {
        throw "方案路径无效：$Field"
    }
    $full=[IO.Path]::GetFullPath($Value)
    $canonical=$full.TrimEnd('\')
    if ($canonical -ine $Value.TrimEnd('\') -or ($Value.EndsWith('\') -and $Value -ine [IO.Path]::GetPathRoot($Value))) {
        throw "方案路径必须是规范化绝对路径：$Field"
    }
    foreach ($part in $Value.Substring([IO.Path]::GetPathRoot($Value).Length).Split('\')) {
        if ($part -and ($part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)')) {throw "方案路径包含不安全名称：$Field"}
    }
}
function Assert-PathAncestors($Path, [switch]$IncludeLeaf) {
    Assert-CanonicalPath $Path '执行路径'
    $current=[IO.Path]::GetFullPath($Path)
    if (-not $IncludeLeaf) {$current=Split-Path -Parent $current}
    $parents=New-Object 'Collections.Generic.Stack[string]'
    while ($current) {$parents.Push($current);$current=Split-Path -Parent $current}
    # Check from the root down so we never inspect a descendant before its parent.
    while ($parents.Count) {
        $parent=$parents.Pop()
        $item=Get-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
        if ($item -and (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {throw "执行路径包含文件或目录链接，停止操作：$parent"}
    }
}
function Assert-RegularFilePath($Path) {
    Assert-PathAncestors $Path
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {throw "方案保存文件路径不是普通文件：$Path"}
}
function Assert-StorePaths($Store) {
    Assert-PathAncestors $Store -IncludeLeaf
    foreach ($name in @('state.json','state.json.bak','state.json.tmp','.operation.lock','operations.log')) {Assert-RegularFilePath (Join-Path $Store $name)}
}
function Assert-EntryRuntimePaths($Entry,$Store) {
    Assert-StorePaths $Store
    # Source alone may be our junction. Its ancestors may never be reparse points.
    Assert-PathAncestors $Entry.Source
    Assert-PathAncestors $Entry.Target -IncludeLeaf
    foreach ($name in @('Backups','PreviousTargets','RestoreStages')) {
        if (-not $Entry.PSObject.Properties[$name]) {continue}
        foreach ($path in @($Entry.$name)) {Assert-PathAncestors $path -IncludeLeaf}
    }
    if ($Entry.PSObject.Properties['PendingTarget'] -and $Entry.PendingTarget) {Assert-PathAncestors $Entry.PendingTarget -IncludeLeaf}
}
function Assert-StateSchema($State, $Store, [switch]$AllowForeignUser) {
    if ($null -eq $State -or $State -isnot [pscustomobject]) {throw '方案必须是 JSON 对象。'}
    foreach ($name in @('Version','User','Entries')) {if (-not $State.PSObject.Properties[$name]) {throw "方案缺少字段：$name"}}
    if (($State.Version -isnot [int] -and $State.Version -isnot [long]) -or $State.Version -ne 1) {throw '方案版本不兼容。'}
    if ($State.User -isnot [string] -or $State.User -notmatch '^S-1-\d+(?:-\d+)+$') {throw '方案 Windows 用户 SID 无效。'}
    try {$null=New-Object Security.Principal.SecurityIdentifier($State.User)} catch {throw '方案 Windows 用户 SID 无效。'}
    if (-not $AllowForeignUser -and $State.User -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {throw '此方案不属于当前 Windows 用户。'}
    if ($null -eq $State.Entries -or $State.Entries -isnot [array]) {throw '方案 Entries 必须是数组。'}
    Assert-CanonicalPath $Store 'Store'
    $paths=New-Object 'Collections.Generic.List[object]'
    $index=0
    foreach ($entry in @($State.Entries)) {
        if ($null -eq $entry -or $entry -isnot [pscustomobject]) {throw '方案项目必须是对象。'}
        foreach ($name in @('Label','Source','Target','Backups','Phase')) {if (-not $entry.PSObject.Properties[$name]) {throw "方案项目缺少字段：$name"}}
        if ($entry.Label -isnot [string] -or $entry.Phase -isnot [string] -or $entry.Phase -cnotin @('Copying','Ready','Linked','Restoring','Restored','RelocatingReady')) {throw '方案包含无效名称或未知操作阶段。'}
        Assert-CanonicalPath $entry.Source 'Source'; Assert-CanonicalPath $entry.Target 'Target'
        if (Test-PathOverlap $entry.Source $entry.Target) {throw '方案原目录和目标目录重叠。'}
        if ($null -eq $entry.Backups -or $entry.Backups -isnot [array]) {throw '方案 Backups 必须是数组。'}
        $entryPaths=@([pscustomobject]@{Path=$entry.Source;Kind='Source'},[pscustomobject]@{Path=$entry.Target;Kind='Target'})
        foreach ($name in @('Backups','PreviousTargets','RestoreStages')) {
            if (-not $entry.PSObject.Properties[$name]) {continue}
            if ($null -eq $entry.$name -or $entry.$name -isnot [array]) {throw "方案 $name 必须是数组。"}
            foreach ($path in @($entry.$name)) {
                Assert-CanonicalPath $path $name
                if ($name -eq 'Backups' -and $path -notmatch ('^'+[regex]::Escape($entry.Source)+'\.env-anchor-backup-[a-fA-F0-9]{32}$')) {throw '方案备份路径与原目录不匹配。'}
                if ($name -eq 'RestoreStages' -and $path -notmatch ('^'+[regex]::Escape($entry.Source)+'\.env-anchor-restore-[a-fA-F0-9]{32}$')) {throw '方案恢复暂存路径与原目录不匹配。'}
                $entryPaths+= [pscustomobject]@{Path=$path;Kind=$name}
            }
        }
        $pending=''
        if ($entry.PSObject.Properties['PendingTarget']) {
            if ($entry.PendingTarget -isnot [string]) {throw '方案 PendingTarget 必须是字符串。'}
            $pending=$entry.PendingTarget
            if ($pending) {Assert-CanonicalPath $pending 'PendingTarget'; $entryPaths+=[pscustomobject]@{Path=$pending;Kind='PendingTarget'}}
        }
        if (($entry.Phase -eq 'RelocatingReady') -ne [bool]$pending) {throw '方案换位置阶段与 PendingTarget 不一致。'}
        if ($entry.PSObject.Properties['RestoreJournal'] -and $null -ne $entry.RestoreJournal) {
            $journal=$entry.RestoreJournal
            if ($journal -isnot [pscustomobject] -or $entry.Phase -notin @('Restoring','Restored')) {throw '方案恢复记录与阶段不一致。'}
            foreach ($name in @('Stage','ConflictBackup','Step')) {if (-not $journal.PSObject.Properties[$name]) {throw "方案恢复记录缺少字段：$name"}}
            if ($journal.Step -isnot [string] -or $journal.Step -cnotin @('Copying','Prepared','BackedUp','Installed') -or $journal.ConflictBackup -isnot [string]) {throw '方案恢复记录无效。'}
            Assert-CanonicalPath $journal.Stage 'RestoreJournal.Stage'
            if (-not $entry.PSObject.Properties['RestoreStages'] -or @($entry.RestoreStages) -inotcontains $journal.Stage) {throw '恢复暂存路径未记录。'}
            if ($journal.ConflictBackup -and @($entry.Backups) -inotcontains $journal.ConflictBackup) {throw '恢复冲突备份未记录。'}
        }
        foreach ($path in $entryPaths) {
            if ($path.Kind -eq 'Source' -or $path.Kind -eq 'Backups' -or $path.Kind -eq 'RestoreStages') {
                if (Test-PathOverlap $path.Path $Store) {throw '方案原目录、备份或暂存目录与方案保存目录冲突。'}
            } else {
                $storeFull=[IO.Path]::GetFullPath($Store).TrimEnd('\')
                $value=$path.Path.TrimEnd('\')
                if ($value -ieq $storeFull -or $storeFull.StartsWith($value+'\',[StringComparison]::OrdinalIgnoreCase) -or
                    (Test-PathOverlap $value (Join-Path $Store 'Tool')) -or (Test-PathOverlap $value (Join-Path $Store 'state.json')) -or
                    (Test-PathOverlap $value (Join-Path $Store 'state.json.bak')) -or (Test-PathOverlap $value (Join-Path $Store 'state.json.tmp')) -or
                    (Test-PathOverlap $value (Join-Path $Store '.operation.lock')) -or (Test-PathOverlap $value (Join-Path $Store 'operations.log'))) {throw '方案数据路径与方案保存文件冲突。'}
            }
            foreach ($other in $paths) {if (Test-PathOverlap $path.Path $other.Path) {throw '方案项目路径或历史副本彼此重叠。'}}
            $paths.Add([pscustomobject]@{Path=$path.Path;Entry=$index})
        }
        $index++
    }
}
function Assert-PlainTree($Path) {
    Assert-PathAncestors $Path
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "不是普通文件夹：$Path" }
    # Walk level by level; never traverse a junction before checking it.
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($item.FullName)
    while ($pending.Count) {
        foreach ($child in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "包含链接或云占位文件，请先单独处理：$($child.FullName)" }
            if ($child.PSIsContainer) { $pending.Push($child.FullName) }
        }
    }
}
function Copy-Verified($Source, $Target) {
    Assert-PlainTree $Source
    if(Test-PathOverlap $Source $Target){throw '复制源和目标不能重叠。'}
    if(Test-Path -LiteralPath $Target){Assert-PlainTree $Target}
    Assert-PathAncestors $Target -IncludeLeaf
    Write-Progress -Activity '正在复制文件' -Status $Source -PercentComplete -1
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $start.Arguments='"'+$Source.TrimEnd('\')+'" "'+$Target.TrimEnd('\')+'" /E /XJ /COPY:DAT /DCOPY:DAT /R:0 /W:0 /NFL /NDL /NJH /NJS /NP'
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process; $process.StartInfo=$start
    try {
        Assert-PlainTree $Source; Assert-PlainTree $Target
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $result=$stdout.Result+$stderr.Result
        if ($process.ExitCode -ge 8) { throw "复制失败，原目录保留。请关闭相关软件并检查空间。$result" }
    } finally {$process.Dispose()}
    $files=@(Get-ChildItem -LiteralPath $Source -File -Recurse -Force)
    $completed=0
    foreach ($file in $files) {
        $completed++
        Write-Progress -Activity '正在校验文件' -Status $file.Name -PercentComplete ([int](100*$completed/[Math]::Max(1,$files.Count)))
        $relative = $file.FullName.Substring($Source.TrimEnd('\').Length).TrimStart('\')
        $dest = Join-Path $Target $relative
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { throw "校验失败：$relative" }
        if ((Get-ContentHash $file.FullName) -ne (Get-ContentHash $dest)) { throw "内容发生变化或校验失败：$relative" }
    }
    Assert-CopyMatches $Source $Target
}
function Assert-CopyMatches($Source,$Target) {
    Assert-PlainTree $Source; Assert-PlainTree $Target
    $sourceDirs=@(Get-ChildItem -LiteralPath $Source -Recurse -Force | Where-Object {$_.PSIsContainer} | ForEach-Object {$_.FullName.Substring($Source.TrimEnd('\').Length).TrimStart('\')})
    $targetDirs=@(Get-ChildItem -LiteralPath $Target -Recurse -Force | Where-Object {$_.PSIsContainer} | ForEach-Object {$_.FullName.Substring($Target.TrimEnd('\').Length).TrimStart('\')})
    if ($sourceDirs.Count -ne $targetDirs.Count) {throw '复制完成后目录列表发生变化，请保留两份数据并重新迁移。'}
    foreach ($directory in $sourceDirs) {if ($targetDirs -inotcontains $directory) {throw '复制完成后目录列表发生变化，请保留两份数据并重新迁移。'}}
    $files=@(Get-ChildItem -LiteralPath $Source -File -Recurse -Force)
    if($files.Count -ne @(Get-ChildItem -LiteralPath $Target -File -Recurse -Force).Count){throw '复制完成后文件列表发生变化，请保留两份数据并重新迁移。'}
    foreach($file in $files){
        $relative=$file.FullName.Substring($Source.TrimEnd('\').Length).TrimStart('\')
        $other=Join-Path $Target $relative
        if(-not (Test-Path -LiteralPath $other -PathType Leaf) -or (Get-ContentHash $file.FullName) -ne (Get-ContentHash $other)){throw '复制完成后内容发生变化，已停止切换连接；请先关闭相关软件。'}
    }
}
function Get-ContentHash($Path) {
    Assert-RegularFilePath $Path
    $stream=[IO.File]::OpenRead($Path)
    $hash=[Security.Cryptography.SHA256]::Create()
    try {return [BitConverter]::ToString($hash.ComputeHash($stream))}
    finally {$stream.Dispose(); $hash.Dispose()}
}
function Test-OurLink($Source, $Target) {
    Assert-PathAncestors $Source
    $item = Get-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    if ($item.LinkType -ne 'Junction' -or @($item.Target).Count -ne 1 -or $item.Target[0].TrimEnd('\') -ine $Target.TrimEnd('\')) {
        throw "已有其他链接，停止操作：$Source"
    }
    return $true
}
function Connect-Entry($Entry, $State, $Store) {
    Assert-StateSchema $State $Store
    Assert-EntryRuntimePaths $Entry $Store
    if (-not (Test-Path -LiteralPath $Entry.Target -PathType Container)) { throw "持久数据目录不存在，停止恢复：$($Entry.Target)" }
    if (Test-OurLink $Entry.Source $Entry.Target) {
        if($Entry.Phase -eq 'Ready'){$Entry.Phase='Linked'; Save-State $State $Store}
        return
    }
    Assert-PlainTree $Entry.Target
    $backup = $null
    if (Test-Path -LiteralPath $Entry.Source) {
        Assert-PlainTree $Entry.Source
        if($Entry.Phase -eq 'Ready'){Assert-CopyMatches $Entry.Source $Entry.Target}
        $backup = $Entry.Source + '.env-anchor-backup-' + [Guid]::NewGuid().ToString('N')
        $Entry.Backups = @($Entry.Backups) + $backup
        Save-State $State $Store
        Assert-PlainTree $Entry.Source; Assert-PathAncestors $backup -IncludeLeaf
        Move-Item -LiteralPath $Entry.Source -Destination $backup
    }
    try {
        Assert-PathAncestors $Entry.Source; Assert-PlainTree $Entry.Target
        New-Item -ItemType Junction -Path $Entry.Source -Target $Entry.Target | Out-Null
    }
    catch {
        if ($backup -and -not (Test-Path -LiteralPath $Entry.Source)) {
            Assert-PathAncestors $Entry.Source; Assert-PlainTree $backup
            Move-Item -LiteralPath $backup -Destination $Entry.Source
        }
        throw
    }
    $Entry.Phase = 'Linked'
    Save-State $State $Store
}
function Test-PathOverlap($Left, $Right) {
    $a=[IO.Path]::GetFullPath($Left).TrimEnd('\')
    $b=[IO.Path]::GetFullPath($Right).TrimEnd('\')
    return ($a -ieq $b -or $a.StartsWith($b+'\',[StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a+'\',[StringComparison]::OrdinalIgnoreCase))
}
function Assert-EntryPaths($Source, $Target, $State, $Store) {
    Assert-StorePaths $Store
    Assert-PathAncestors $Source
    Assert-PathAncestors $Target -IncludeLeaf
    if (Test-PathOverlap $Source $Target) { throw '原目录和目标目录不能相同或互相包含。' }
    if (Test-PathOverlap $Source $Store) { throw '原目录不能与方案保存目录重叠。' }
    $storePath=[IO.Path]::GetFullPath($Store).TrimEnd('\')
    $targetPath=[IO.Path]::GetFullPath($Target).TrimEnd('\')
    if ($storePath -ieq $targetPath -or $storePath.StartsWith($targetPath+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '目标目录不能包含方案保存目录。' }
    if (Test-PathOverlap $Target (Join-Path $Store 'Tool')) {throw '目标目录不能使用方案的 Tool 工具目录。'}
    foreach ($name in @('state.json','state.json.bak','state.json.tmp','.operation.lock','operations.log')) {
        if (Test-PathOverlap $Target (Join-Path $Store $name)) {throw '目标目录不能使用方案的保存文件路径。'}
    }
    foreach ($existing in @($State.Entries)) {
        if ((Test-PathOverlap $Source $existing.Source) -or (Test-PathOverlap $Target $existing.Target) -or
            (Test-PathOverlap $Source $existing.Target) -or (Test-PathOverlap $Target $existing.Source)) {
            throw '所选目录与已有迁移项目重叠，请使用独立目标文件夹；已有项目请重新挂接。'
        }
    }
    $current=$targetPath
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item=Get-Item -LiteralPath $current -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw '目标路径不能包含文件或目录链接。'}
        }
        $current=Split-Path -Parent $current
    }
    if ((Test-Path -LiteralPath $Target) -and @(Get-ChildItem -LiteralPath $Target -Force).Count) {throw '目标文件夹已有内容，请选择空文件夹或新路径。'}
}
function Assert-HistoryPaths($Source,$Target,$Entries) {
    foreach ($entry in @($Entries)) {
        foreach ($name in @('Backups','PreviousTargets','RestoreStages')) {
            if (-not $entry.PSObject.Properties[$name]) {continue}
            foreach ($path in @($entry.$name)) {
                if ((Test-PathOverlap $Source $path) -or (Test-PathOverlap $Target $path)) {throw '所选目录与方案保留的历史副本或恢复暂存目录重叠。'}
            }
        }
    }
}
function Add-Entry($Source, $Label, $State, $Store, [string]$Target='') {
    Assert-StateSchema $State $Store
    Assert-StorePaths $Store
    $sourcePath = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    foreach ($existing in @($State.Entries)) {
        if ($existing.Source -ieq $sourcePath) { throw '此目录已经在方案中，请使用重新挂接。' }
        if ($existing.Source.StartsWith($sourcePath + '\', [StringComparison]::OrdinalIgnoreCase) -or $sourcePath.StartsWith($existing.Source + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '不能重复迁移父目录和子目录。' }
    }
    if (-not $Target) {$Target=Join-Path $Store ('Data\' + [Guid]::NewGuid().ToString('N'))}
    $Target=[IO.Path]::GetFullPath($Target).TrimEnd('\')
    Assert-HistoryPaths $sourcePath $Target $State.Entries
    Assert-EntryPaths $sourcePath $Target $State $Store
    Assert-PlainTree $sourcePath
    $entry = [pscustomobject]@{Label=$Label; Source=$sourcePath; Target=$Target; Backups=@(); Phase='Copying'}
    Assert-StateSchema ([pscustomobject]@{Version=$State.Version;User=$State.User;Entries=@($State.Entries)+@($entry)}) $Store
    $State.Entries = @($State.Entries) + $entry
    Save-State $State $Store
    Copy-Verified $entry.Source $entry.Target
    $entry.Phase = 'Ready'
    Save-State $State $Store
    Connect-Entry $entry $State $Store
}
function Resume-State($State, $Store) {
    Assert-StateSchema $State $Store
    Assert-StorePaths $Store
    # Validate all entries before repairing the first connection.
    foreach ($entry in @($State.Entries)) {
        Assert-EntryRuntimePaths $entry $Store
        if ($entry.Phase -eq 'Restored') {continue}
        Assert-ResumeEntry $entry
    }
    foreach ($entry in @($State.Entries)) {
        if ($entry.Phase -eq 'Restored') { continue }
        if ($entry.Phase -eq 'RelocatingReady') { Complete-Relocation $entry $State $Store; continue }
        if ($entry.Phase -eq 'Copying') {
            throw "上次复制未完成：$($entry.Label)。请先撤销方案后重试，不会挂接未完成的数据。"
        }
        if ($entry.Phase -eq 'Restoring') { throw '上次撤销未完成，请再次执行撤销。' }
        Connect-Entry $entry $State $Store
    }
}
function Assert-ResumeEntry($Entry) {
    Assert-PathAncestors $Entry.Source
    if ($Entry.Phase -eq 'Copying') {throw "上次复制未完成：$($Entry.Label)。请先撤销方案后重试，不会挂接未完成的数据。"}
    if ($Entry.Phase -eq 'Restoring') {throw '上次撤销未完成，请再次执行撤销。'}
    Assert-PlainTree $Entry.Target
    if ($Entry.Phase -eq 'RelocatingReady') {
        Assert-PlainTree $Entry.PendingTarget
        $item=Get-Item -LiteralPath $Entry.Source -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.LinkType -ne 'Junction' -or @($item.Target).Count -ne 1 -or
            ($item.Target[0].TrimEnd('\') -ine $Entry.Target.TrimEnd('\') -and $item.Target[0].TrimEnd('\') -ine $Entry.PendingTarget.TrimEnd('\')))) {throw '原目录链接已被其他程序修改，停止换位置。'}
        if (-not $item -or $item.Target[0].TrimEnd('\') -ieq $Entry.Target.TrimEnd('\')) {Assert-CopyMatches $Entry.Target $Entry.PendingTarget}
    } elseif (-not (Test-OurLink $Entry.Source $Entry.Target) -and (Test-Path -LiteralPath $Entry.Source)) {
        Assert-PlainTree $Entry.Source
        if ($Entry.Phase -eq 'Ready') {Assert-CopyMatches $Entry.Source $Entry.Target}
    }
}
function Undo-State($State, $Store, $Sources=@()) {
    Assert-StateSchema $State $Store
    Assert-StorePaths $Store
    foreach ($source in @($Sources)) {if (@($State.Entries.Source) -inotcontains $source) {throw '撤销请求包含未知原目录。'}}
    foreach ($entry in @($State.Entries)) {
        Assert-EntryRuntimePaths $entry $Store
        if ((@($Sources).Count -and $Sources -inotcontains $entry.Source) -or $entry.Phase -eq 'Restored') {continue}
        if ($entry.Phase -eq 'Copying') {
            if (-not (Test-Path -LiteralPath $entry.Source -PathType Container)) {throw '首次复制未完成且原目录缺失，不能把部分副本当作完整数据恢复。请检查原目录和备份。'}
            Assert-PlainTree $entry.Source; continue
        }
        if (-not (Test-Path -LiteralPath $entry.Target -PathType Container)) {throw "目标磁盘或数据目录不可用，停止撤销：$($entry.Target)"}
        Assert-PlainTree $entry.Target
        if ($entry.PSObject.Properties['RestoreJournal'] -and $entry.RestoreJournal -and $entry.RestoreJournal.Step -eq 'Installed') {Assert-PlainTree $entry.Source}
        if ($entry.Phase -eq 'RelocatingReady') {
            $item=Get-Item -LiteralPath $entry.Source -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.LinkType -ne 'Junction' -or @($item.Target).Count -ne 1 -or
                ($item.Target[0].TrimEnd('\') -ine $entry.Target.TrimEnd('\') -and $item.Target[0].TrimEnd('\') -ine $entry.PendingTarget.TrimEnd('\')))) {throw '原目录链接已被其他程序修改，停止撤销。'}
        } elseif (-not (Test-OurLink $entry.Source $entry.Target) -and (Test-Path -LiteralPath $entry.Source)) {
            Assert-PlainTree $entry.Source
            if ($entry.Phase -eq 'Linked') {throw "原位置已经变成普通目录，请先重新挂接以保留两边的数据，再撤销：$($entry.Source)"}
        }
    }
    foreach ($entry in @($State.Entries)) {
        if(@($Sources).Count -and $Sources -inotcontains $entry.Source){continue}
        if ($entry.Phase -eq 'Restored') { continue }
        if($entry.Phase -eq 'Copying') {
            if(-not (Test-Path -LiteralPath $entry.Source -PathType Container)){throw '首次复制未完成且原目录缺失，不能把部分副本当作完整数据恢复。请检查原目录和备份。'}
            Assert-PlainTree $entry.Source
            $entry.Phase='Restored'; Save-State $State $Store; continue
        }
        if ($entry.Phase -eq 'RelocatingReady') {
            # Undo may abandon a stale staged copy while the original target is still authoritative.
            $link=Get-Item -LiteralPath $entry.Source -Force -ErrorAction SilentlyContinue
            if(-not $link -and (Test-Path -LiteralPath $entry.Target -PathType Container)){
                Assert-PathAncestors $entry.Source; Assert-PlainTree $entry.Target
                New-Item -ItemType Junction -Path $entry.Source -Target $entry.Target | Out-Null
                $link=Get-Item -LiteralPath $entry.Source -Force
            }
            if($link -and $link.LinkType -eq 'Junction' -and $link.Target[0] -ieq $entry.Target){
                $entry.Phase='Linked'; $entry.PendingTarget=''; Save-State $State $Store
            } else {Complete-Relocation $entry $State $Store}
        }
        if ($entry.Phase -ne 'Copying' -and -not (Test-Path -LiteralPath $entry.Target -PathType Container)) {throw "目标磁盘或数据目录不可用，停止撤销：$($entry.Target)"}
        $ourLink=Test-OurLink $entry.Source $entry.Target
        if (-not $ourLink -and $entry.Phase -eq 'Linked' -and (Test-Path -LiteralPath $entry.Source)) {
            throw "原位置已经变成普通目录，请先重新挂接以保留两边的数据，再撤销：$($entry.Source)"
        }
        Restore-EntrySafely $entry $State $Store
    }
}

function Restore-EntrySafely($Entry, $State, $Store) {
    Assert-EntryRuntimePaths $Entry $Store
    # Every write into a user-visible Source is an atomic directory move from a
    # verified sibling. Existing ordinary directories always get a journaled backup.
    $journal=$null
    if ($Entry.PSObject.Properties['RestoreJournal']) {$journal=$Entry.RestoreJournal}
    if ($journal -and $journal.Step -eq 'Installed') {
        Assert-PlainTree $Entry.Source
        $Entry.Phase='Restored'; Save-State $State $Store; return
    }
    if ($journal -and $journal.Step -eq 'BackedUp' -and -not (Test-Path -LiteralPath $journal.Stage) -and (Test-Path -LiteralPath $Entry.Source)) {
        # The move completed before its state save. Never recopy over subsequent edits.
        Assert-PlainTree $Entry.Source
        $matches=$false
        try {Assert-CopyMatches $Entry.Target $Entry.Source; $matches=$true} catch {}
        if ($matches) {
            $journal.Step='Installed'; Save-State $State $Store
            $Entry.Phase='Restored'; Save-State $State $Store; return
        }
        # An ordinary Source may have been edited or recreated after the interrupted
        # install. Preserve it as a conflict backup before installing a fresh stage.
    }
    $useStage=$false
    if ($journal -and $journal.Step -in @('Prepared','BackedUp') -and (Test-Path -LiteralPath $journal.Stage)) {
        try {Assert-CopyMatches $Entry.Target $journal.Stage; $useStage=$true} catch {
            # Keep the stale stage and rebuild from the current authoritative target.
        }
    }
    if (-not $useStage) {
        $stage=$Entry.Source+'.env-anchor-restore-'+[Guid]::NewGuid().ToString('N')
        $stages=@(); if ($Entry.PSObject.Properties['RestoreStages']) {$stages=@($Entry.RestoreStages)}
        $Entry | Add-Member -NotePropertyName RestoreStages -NotePropertyValue ($stages+@($stage)) -Force
        $journal=[pscustomobject]@{Stage=$stage;ConflictBackup='';Step='Copying'}
        $Entry | Add-Member -NotePropertyName RestoreJournal -NotePropertyValue $journal -Force
        $Entry.Phase='Restoring'; Save-State $State $Store
        Copy-Verified $Entry.Target $stage
        $journal.Step='Prepared'; Save-State $State $Store
    }
    Assert-CopyMatches $Entry.Target $journal.Stage
    if (Test-OurLink $Entry.Source $Entry.Target) {
        # Directory.Delete removes only the junction, never its target.
        [IO.Directory]::Delete($Entry.Source)
    }
    if (Test-Path -LiteralPath $Entry.Source) {
        Assert-PlainTree $Entry.Source
        $backup=$journal.ConflictBackup
        if (-not $backup -or (Test-Path -LiteralPath $backup)) {
            $backup=$Entry.Source+'.env-anchor-backup-'+[Guid]::NewGuid().ToString('N')
            $Entry.Backups=@($Entry.Backups)+@($backup)
            $journal.ConflictBackup=$backup
            Save-State $State $Store
        }
        Assert-PlainTree $Entry.Source; Assert-PathAncestors $backup -IncludeLeaf
        [IO.Directory]::Move($Entry.Source,$backup)
    }
    $journal.Step='BackedUp'; Save-State $State $Store
    # Recheck after releasing the original position; failure preserves the stage,
    # authoritative target and conflict backup for the next retry.
    Assert-CopyMatches $Entry.Target $journal.Stage
    Assert-PathAncestors $Entry.Source; Assert-PlainTree $journal.Stage
    [IO.Directory]::Move($journal.Stage,$Entry.Source)
    $journal.Step='Installed'; Save-State $State $Store
    $Entry.Phase='Restored'; Save-State $State $Store
}

function Get-DefaultTarget($Root, $Label, $Source) {
    $name=$Label -replace '[<>:"/\\|?*\x00-\x1f]', '_'
    $name=$name.Trim().TrimEnd('.')
    if(-not $name){$name='文件'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$id=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Source.ToLowerInvariant()))).Replace('-','').Substring(0,8)} finally {$sha.Dispose()}
    return Join-Path $Root ($name+'-'+$id)
}
function Complete-Relocation($Entry, $State, $Store) {
    Assert-StateSchema $State $Store
    Assert-EntryRuntimePaths $Entry $Store
    $old=$Entry.Target; $next=$Entry.PendingTarget
    Assert-PlainTree $next
    $item=Get-Item -LiteralPath $Entry.Source -Force -ErrorAction SilentlyContinue
    if($item) {
        if($item.LinkType -ne 'Junction' -or @($item.Target).Count -ne 1) {throw '换位置前原目录必须是当前方案的连接，请先重新连接。'}
        if($item.Target[0].TrimEnd('\') -ieq $old.TrimEnd('\')) {
            Assert-CopyMatches $old $next
            if (-not (Test-OurLink $Entry.Source $old)) {throw '原目录连接已改变，停止换位置。'}
            [IO.Directory]::Delete($Entry.Source)
        }
        elseif($item.Target[0].TrimEnd('\') -ine $next.TrimEnd('\')) {throw '原目录链接已被其他程序修改，停止换位置。'}
    }
    elseif(Test-Path -LiteralPath $old -PathType Container){Assert-CopyMatches $old $next}
    try {
        Assert-PathAncestors $Entry.Source; Assert-PlainTree $next
        if(-not (Test-Path -LiteralPath $Entry.Source)) {New-Item -ItemType Junction -Path $Entry.Source -Target $next | Out-Null}
    } catch {
        Assert-PathAncestors $Entry.Source; Assert-PlainTree $old
        if(-not (Test-Path -LiteralPath $Entry.Source)) {New-Item -ItemType Junction -Path $Entry.Source -Target $old | Out-Null}
        throw
    }
    $history=@()
    if($Entry.PSObject.Properties['PreviousTargets']){$history=@($Entry.PreviousTargets)}
    $Entry | Add-Member -NotePropertyName PreviousTargets -NotePropertyValue ($history+@($old)) -Force
    $Entry.Target=$next; $Entry.PendingTarget=''; $Entry.Phase='Linked'
    Save-State $State $Store
}
function Move-EntryTarget($Entry, $Target, $State, $Store) {
    Assert-StateSchema $State $Store
    Assert-EntryRuntimePaths $Entry $Store
    if($Entry.Phase -eq 'RelocatingReady'){Complete-Relocation $Entry $State $Store}
    if($Entry.Target -ieq $Target){Connect-Entry $Entry $State $Store; return}
    if($Entry.Phase -ne 'Linked' -and $Entry.Phase -ne 'Ready'){throw '请先完成上次迁移或撤销，再修改位置。'}
    Assert-HistoryPaths $Entry.Source $Target $State.Entries
    $others=[pscustomobject]@{Entries=@($State.Entries | Where-Object {$_.Source -ine $Entry.Source})}
    Assert-EntryPaths $Entry.Source $Target $others $Store
    if(Test-PathOverlap $Entry.Target $Target){throw '新位置不能与旧数据位置重叠。'}
    Connect-Entry $Entry $State $Store
    Copy-Verified $Entry.Target $Target
    $Entry | Add-Member -NotePropertyName PendingTarget -NotePropertyValue $Target -Force
    $Entry.Phase='RelocatingReady'; Save-State $State $Store
    Complete-Relocation $Entry $State $Store
}

function Invoke-PlanOperation {
    param([ValidateSet('Apply','Resume','Undo')][string]$Operation,[string]$Store,[string]$RequestsJson='[]')
    Assert-CanonicalPath $Store 'Store'
    Assert-StorePaths $Store
    $decoded=ConvertFrom-Json $RequestsJson
    $requests=@($decoded)
    if($Operation -in @('Apply','Undo')) {
        if(-not $requests.Count){throw '请先勾选需要处理的目录。'}
        $seen=@()
        foreach ($job in $requests) {
            if ($null -eq $job -or $job -isnot [pscustomobject] -or -not $job.PSObject.Properties['Source']) {throw '操作请求缺少原目录。'}
            Assert-CanonicalPath $job.Source '请求 Source'
            if ($seen -icontains $job.Source) {throw '同一批请求不能重复指定原目录。'}
            $seen+= $job.Source
            if ($Operation -eq 'Apply') {
                if (-not $job.PSObject.Properties['Target'] -or -not $job.PSObject.Properties['Name'] -or $job.Name -isnot [string]) {throw '迁移请求缺少有效名称或目标目录。'}
                Assert-CanonicalPath $job.Target '请求 Target'
            }
        }
    }
    if(-not (Test-Path -LiteralPath $Store)) {
        if($Operation -ne 'Apply'){throw '方案目录不存在。'}
        New-Item -ItemType Directory -Path $Store -Force | Out-Null
    }
    Assert-StorePaths $Store
    try {$lock=[IO.File]::Open((Join-Path $Store '.operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch {throw '此方案正在由另一个窗口或自动重连处理，请稍后再试。'}
    try {
        Assert-StorePaths $Store
        $fresh=-not (Test-Path -LiteralPath (Join-Path $Store 'state.json'))
        if($fresh -and $Operation -ne 'Apply'){throw '此目录没有保存的方案。'}
        if($fresh -and @(Get-ChildItem -LiteralPath $Store -Force | Where-Object {$_.Name -ne '.operation.lock'}).Count){throw '首次使用请选择空方案目录。'}
        if($fresh){$state=[pscustomobject]@{Version=1;User=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Entries=@()}}
        else {$state=Read-State $Store}
        if($Operation -eq 'Resume'){Resume-State $state $Store}
        elseif($Operation -eq 'Undo') {
            $sources=@($requests | ForEach-Object {$_.Source})
            foreach ($source in $sources) {if (@($state.Entries.Source) -inotcontains $source) {throw '撤销请求包含未知原目录。'}}
            if(-not @($state.Entries | Where-Object {$sources -icontains $_.Source -and $_.Phase -ne 'Restored'}).Count){throw '勾选项目中没有已迁移的目录。'}
            Undo-State $state $Store $sources
        } else {
            $active=@($state.Entries | Where-Object {$_.Phase -ne 'Restored'})
            $planned=[pscustomobject]@{Entries=@($active)}
            foreach($job in $requests) {
                Assert-HistoryPaths $job.Source $job.Target $active
                $existing=@($active | Where-Object {$_.Source -ieq $job.Source})
                $others=[pscustomobject]@{Entries=@($planned.Entries | Where-Object {$_.Source -ine $job.Source})}
                if(-not $existing.Count -or $existing[0].Target -ine $job.Target){Assert-EntryPaths $job.Source $job.Target $others $Store}
                if(-not $existing.Count){Assert-PlainTree $job.Source}
                elseif($existing[0].Phase -notin @('Ready','Linked','RelocatingReady')){throw '方案包含未完成操作，请先重新连接或撤销该项目。'}
                elseif($existing[0].Target -ine $job.Target -and (Test-PathOverlap $existing[0].Target $job.Target)){throw '新位置不能与旧数据目录重叠。'}
                if($existing.Count){Assert-EntryRuntimePaths $existing[0] $Store;Assert-ResumeEntry $existing[0]}
                $planned.Entries=@($others.Entries)+@([pscustomobject]@{Source=$job.Source;Target=$job.Target})
            }
            if(@($state.Entries).Count -ne $active.Count){
                $historyFile=Join-Path $Store ('state-history-'+[Guid]::NewGuid().ToString('N')+'.json')
                Assert-RegularFilePath $historyFile;Assert-StorePaths $Store
                Copy-Item -LiteralPath (Join-Path $Store 'state.json') -Destination $historyFile
            }
            $state.Entries=$active
            Save-State $state $Store
            foreach($job in $requests) {
                $existing=@($state.Entries | Where-Object {$_.Source -ieq $job.Source})
                Write-Progress -Activity '处理迁移项目' -Status $job.Name -PercentComplete -1
                if($existing.Count){Move-EntryTarget $existing[0] $job.Target $state $Store}
                else {Add-Entry $job.Source $job.Name $state $Store $job.Target}
            }
        }
        Assert-StorePaths $Store
        ('{0:o} {1} 完成' -f [DateTime]::Now,$Operation) | Add-Content -LiteralPath (Join-Path $Store 'operations.log') -Encoding UTF8
    } catch {
        # Do not pollute a fresh directory when validation failed before a plan was created.
        $operationError=$_
        try {
            Assert-StorePaths $Store
            if(Test-Path -LiteralPath (Join-Path $Store 'state.json')) {('{0:o} {1} 失败: {2}' -f [DateTime]::Now,$Operation,$operationError.Exception.Message) | Add-Content -LiteralPath (Join-Path $Store 'operations.log') -Encoding UTF8}
        } catch {}
        throw
    } finally {$lock.Dispose()}
}
