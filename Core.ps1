Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Save-State($State, $Store) {
    $path = Join-Path $Store 'state.json'
    $temp = "$path.tmp"
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temp, $path, "$path.bak") }
    else { [IO.File]::Move($temp, $path) }
}
function Read-State($Store) {
    $state = Get-Content -LiteralPath (Join-Path $Store 'state.json') -Raw | ConvertFrom-Json
    if ($state.Version -ne 1 -or $state.User -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
        throw '此方案不属于当前 Windows 用户，或版本不兼容。'
    }
    return $state
}
function Assert-PlainTree($Path) {
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
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $start.Arguments='"'+$Source.TrimEnd('\')+'" "'+$Target.TrimEnd('\')+'" /E /XJ /COPY:DAT /DCOPY:DAT /R:0 /W:0 /NFL /NDL /NJH /NJS /NP'
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process; $process.StartInfo=$start
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $result=$stdout.Result+$stderr.Result
        if ($process.ExitCode -ge 8) { throw "复制失败，原目录保留。请关闭相关软件并检查空间。$result" }
    } finally {$process.Dispose()}
    foreach ($file in Get-ChildItem -LiteralPath $Source -File -Recurse -Force) {
        $relative = $file.FullName.Substring($Source.TrimEnd('\').Length).TrimStart('\')
        $dest = Join-Path $Target $relative
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { throw "校验失败：$relative" }
        if ((Get-ContentHash $file.FullName) -ne (Get-ContentHash $dest)) { throw "内容发生变化或校验失败：$relative" }
    }
}
function Get-ContentHash($Path) {
    $stream=[IO.File]::OpenRead($Path)
    $hash=[Security.Cryptography.SHA256]::Create()
    try {return [BitConverter]::ToString($hash.ComputeHash($stream))}
    finally {$stream.Dispose(); $hash.Dispose()}
}
function Test-OurLink($Source, $Target) {
    $item = Get-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    if ($item.LinkType -ne 'Junction' -or @($item.Target).Count -ne 1 -or $item.Target[0].TrimEnd('\') -ine $Target.TrimEnd('\')) {
        throw "已有其他链接，停止操作：$Source"
    }
    return $true
}
function Connect-Entry($Entry, $State, $Store) {
    if (-not (Test-Path -LiteralPath $Entry.Target -PathType Container)) { throw "持久数据目录不存在，停止恢复：$($Entry.Target)" }
    if (Test-OurLink $Entry.Source $Entry.Target) { return }
    Assert-PlainTree $Entry.Target
    $backup = $null
    if (Test-Path -LiteralPath $Entry.Source) {
        Assert-PlainTree $Entry.Source
        $backup = $Entry.Source + '.env-anchor-backup-' + [Guid]::NewGuid().ToString('N')
        $Entry.Backups = @($Entry.Backups) + $backup
        Save-State $State $Store
        Move-Item -LiteralPath $Entry.Source -Destination $backup
    }
    try { New-Item -ItemType Junction -Path $Entry.Source -Target $Entry.Target | Out-Null }
    catch {
        if ($backup -and -not (Test-Path -LiteralPath $Entry.Source)) { Move-Item -LiteralPath $backup -Destination $Entry.Source }
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
    if (Test-PathOverlap $Source $Target) { throw '原目录和目标目录不能相同或互相包含。' }
    if (Test-PathOverlap $Source $Store) { throw '原目录不能与方案保存目录重叠。' }
    $storePath=[IO.Path]::GetFullPath($Store).TrimEnd('\')
    $targetPath=[IO.Path]::GetFullPath($Target).TrimEnd('\')
    if ($storePath -ieq $targetPath -or $storePath.StartsWith($targetPath+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '目标目录不能包含方案保存目录。' }
    if (Test-PathOverlap $Target (Join-Path $Store 'Tool')) {throw '目标目录不能使用方案的 Tool 工具目录。'}
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
function Add-Entry($Source, $Label, $State, $Store, [string]$Target='') {
    $sourcePath = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    foreach ($existing in @($State.Entries)) {
        if ($existing.Source -ieq $sourcePath) { throw '此目录已经在方案中，请使用重新挂接。' }
        if ($existing.Source.StartsWith($sourcePath + '\', [StringComparison]::OrdinalIgnoreCase) -or $sourcePath.StartsWith($existing.Source + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '不能重复迁移父目录和子目录。' }
    }
    if (-not $Target) {$Target=Join-Path $Store ('Data\' + [Guid]::NewGuid().ToString('N'))}
    $Target=[IO.Path]::GetFullPath($Target).TrimEnd('\')
    Assert-EntryPaths $sourcePath $Target $State $Store
    Assert-PlainTree $sourcePath
    $entry = [pscustomobject]@{Label=$Label; Source=$sourcePath; Target=$Target; Backups=@(); Phase='Copying'}
    $State.Entries = @($State.Entries) + $entry
    Save-State $State $Store
    Copy-Verified $entry.Source $entry.Target
    $entry.Phase = 'Ready'
    Save-State $State $Store
    Connect-Entry $entry $State $Store
}
function Resume-State($State, $Store) {
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
function Undo-State($State, $Store) {
    foreach ($entry in @($State.Entries)) {
        if ($entry.Phase -eq 'Restored') { continue }
        if ($entry.Phase -eq 'RelocatingReady') { Complete-Relocation $entry $State $Store }
        if ($entry.Phase -ne 'Copying' -and -not (Test-Path -LiteralPath $entry.Target -PathType Container)) {throw "目标磁盘或数据目录不可用，停止撤销：$($entry.Target)"}
        if (Test-OurLink $entry.Source $entry.Target) {
            $entry.Phase = 'Restoring'
            Save-State $State $Store
            # Directory.Delete removes only the junction, never its target.
            [IO.Directory]::Delete($entry.Source)
        }
        elseif ($entry.Phase -eq 'Linked' -and (Test-Path -LiteralPath $entry.Source)) {
            throw "原位置已经变成普通目录，请先重新挂接以保留两边的数据，再撤销：$($entry.Source)"
        }
        if ($entry.Phase -eq 'Restoring' -or -not (Test-Path -LiteralPath $entry.Source)) {
            Copy-Verified $entry.Target $entry.Source
        }
        $entry.Phase = 'Restored'
        Save-State $State $Store
    }
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
    $old=$Entry.Target; $next=$Entry.PendingTarget
    Assert-PlainTree $next
    $item=Get-Item -LiteralPath $Entry.Source -Force -ErrorAction SilentlyContinue
    if($item) {
        if($item.LinkType -ne 'Junction' -or @($item.Target).Count -ne 1) {throw '换位置前原目录必须是当前方案的连接，请先重新连接。'}
        if($item.Target[0].TrimEnd('\') -ieq $old.TrimEnd('\')) {[IO.Directory]::Delete($Entry.Source)}
        elseif($item.Target[0].TrimEnd('\') -ine $next.TrimEnd('\')) {throw '原目录链接已被其他程序修改，停止换位置。'}
    }
    try {
        if(-not (Test-Path -LiteralPath $Entry.Source)) {New-Item -ItemType Junction -Path $Entry.Source -Target $next | Out-Null}
    } catch {
        if(-not (Test-Path -LiteralPath $Entry.Source)) {New-Item -ItemType Junction -Path $Entry.Source -Target $old | Out-Null}
        throw
    }
    $Entry | Add-Member -NotePropertyName PreviousTargets -NotePropertyValue (@($old)) -Force
    $Entry.Target=$next; $Entry.PendingTarget=''; $Entry.Phase='Linked'
    Save-State $State $Store
}
function Move-EntryTarget($Entry, $Target, $State, $Store) {
    if($Entry.Phase -eq 'RelocatingReady'){Complete-Relocation $Entry $State $Store}
    if($Entry.Target -ieq $Target){return}
    if($Entry.Phase -ne 'Linked' -and $Entry.Phase -ne 'Ready'){throw '请先完成上次迁移或撤销，再修改位置。'}
    $others=[pscustomobject]@{Entries=@($State.Entries | Where-Object {$_.Source -ine $Entry.Source})}
    Assert-EntryPaths $Entry.Source $Target $others $Store
    if(Test-PathOverlap $Entry.Target $Target){throw '新位置不能与旧数据位置重叠。'}
    Connect-Entry $Entry $State $Store
    Copy-Verified $Entry.Target $Target
    $Entry | Add-Member -NotePropertyName PendingTarget -NotePropertyValue $Target -Force
    $Entry.Phase='RelocatingReady'; Save-State $State $Store
    Complete-Relocation $Entry $State $Store
}
