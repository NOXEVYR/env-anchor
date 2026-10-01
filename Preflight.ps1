# Read-only operation inspection. Only directory metadata and state.json are read.
# The execution layer must revalidate immediately before changing any data.
$script:PreviewMaximumEntries = 250000
$script:PreviewMaximumDepth = 64

function Get-PreviewProperty($Value, [string]$Name, $Default = '') {
    if ($null -ne $Value -and $null -ne $Value.PSObject.Properties[$Name]) { return $Value.$Name }
    return $Default
}

function ConvertTo-PreviewPath($Path) {
    if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path)) { throw '目录路径不能为空。' }
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { throw '请选择完整的本地磁盘目录路径。' }
    # Match the executor's canonical-path contract before consulting the filesystem.
    Assert-CanonicalPath $Path '预检目录'
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($full -match '^[A-Za-z]:$') { throw '不能直接使用整个磁盘根目录。' }
    if ($full.Substring(2) -match ':') { throw '目录路径不能包含数据流。' }
    return $full
}

function Test-PreviewOverlap([string]$Left, [string]$Right) {
    return ($Left -ieq $Right -or $Left.StartsWith($Right + '\', [StringComparison]::OrdinalIgnoreCase) -or $Right.StartsWith($Left + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Get-PreviewAttributes([string]$Path) {
    try { return [IO.File]::GetAttributes($Path) }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
}

function Assert-PreviewAncestors([string]$Path, [switch]$AllowLeafLink) {
    $current = $Path
    $leaf = $true
    while ($current) {
        $attributes = Get-PreviewAttributes $current
        if ($null -ne $attributes) {
            if (-not ($attributes -band [IO.FileAttributes]::Directory)) { throw "目录路径包含文件：$current" }
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -and -not ($leaf -and $AllowLeafLink)) { throw "目录路径包含链接或云占位目录：$current" }
            if ([int]$attributes -band 0x441000) { throw "目录路径包含云占位或离线目录：$current" }
        }
        $leaf = $false
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}

function Get-PreviewLinkState([string]$Source, [string[]]$Targets) {
    $attributes = Get-PreviewAttributes $Source
    if ($null -eq $attributes) { return 'Missing' }
    if (-not ($attributes -band [IO.FileAttributes]::Directory)) { throw "原位置已经变成文件：$Source" }
    if (-not ($attributes -band [IO.FileAttributes]::ReparsePoint)) { return 'Plain' }
    $item = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    $linkType = Get-PreviewProperty $item 'LinkType'
    $actualTargets = @(Get-PreviewProperty $item 'Target' @())
    if ($linkType -ne 'Junction' -or $actualTargets.Count -ne 1) { throw "原位置是其他类型的链接：$Source" }
    $actual = ConvertTo-PreviewPath ([string]$actualTargets[0])
    foreach ($target in $Targets) { if ($actual -ieq $target) { return $actual } }
    throw "原位置连接到了其他目录：$Source"
}

function Get-EntryHealth($Entry) {
    try {
        $source = ConvertTo-PreviewPath (Get-PreviewProperty $Entry 'Source')
        $target = ConvertTo-PreviewPath (Get-PreviewProperty $Entry 'Target')
        $phase = Get-PreviewProperty $Entry 'Phase'
        if ($phase -eq 'Restored') { return '已撤销' }
        if ($phase -eq 'Copying') { return '复制未完成，需撤销后重试' }
        if ($phase -eq 'Restoring') { return '撤销未完成，需继续撤销' }
        if ($phase -eq 'RelocatingReady') { return '位置切换未完成，需恢复或撤销' }
        if ($phase -notin @('Ready', 'Linked')) { return '方案状态无效' }
        Assert-PreviewAncestors $target
        if ($null -eq (Get-PreviewAttributes $target)) { return '持久数据目录不可用' }
        Assert-PreviewAncestors $source -AllowLeafLink
        $link = Get-PreviewLinkState $source @($target)
        if ($link -ieq $target) { return '连接正常' }
        if ($link -eq 'Missing') { return '原位置缺失，可重新连接' }
        return '原位置为普通目录，可重新连接并保留副本'
    } catch { return ('连接异常：' + $_.Exception.Message) }
}

function Get-PreviewTreeStats([string]$Path, $Budget) {
    $bytes = [int64]0
    $files = [int64]0
    $stack = New-Object 'Collections.Generic.Stack[object]'
    Assert-PreviewAncestors $Path
    if ($null -eq (Get-PreviewAttributes $Path)) { throw "数据目录不存在：$Path" }
    $stack.Push([pscustomobject]@{ Path = $Path; Depth = 0 })
    while ($stack.Count) {
        $node = $stack.Pop()
        if ($node.Depth -gt $script:PreviewMaximumDepth) { throw "扫描超过最大深度 $script:PreviewMaximumDepth，统计不完整，请缩小范围：$($node.Path)" }
        # Recheck each queued directory and its ancestors immediately before entry.
        Assert-PreviewAncestors $node.Path
        # Enumerate one level lazily, and inspect attributes before entering a child.
        foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($node.Path)) {
            $Budget.Remaining--
            if ($Budget.Remaining -lt 0) { throw "扫描超过总条目预算 $script:PreviewMaximumEntries，统计不完整，请分批处理。" }
            $attributes = [IO.File]::GetAttributes($child)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -or ([int]$attributes -band 0x441000)) { throw "包含链接、云占位或离线文件，未遍历其内容：$child" }
            if ($attributes -band [IO.FileAttributes]::Directory) {
                $stack.Push([pscustomobject]@{ Path = $child; Depth = ($node.Depth + 1) })
            } else {
                $length = (New-Object IO.FileInfo($child)).Length
                if ($bytes -gt [int64]::MaxValue - $length) { throw '文件总大小超出统计范围。' }
                $bytes += $length
                $files++
            }
            if ($Budget.Remaining % 256 -eq 0) { Write-Progress -Activity '正在预检目录' -Status $Path -PercentComplete -1 }
        }
    }
    return [pscustomobject]@{ Bytes = $bytes; Files = $files }
}

function Get-PreviewVolume([string]$Path) {
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Path))
    if (-not $drive.IsReady) { throw "磁盘不可用：$($drive.Name)" }
    return [pscustomobject]@{ Name = $drive.Name; Type = $drive.DriveType.ToString(); Format = $drive.DriveFormat; FreeBytes = [int64]$drive.AvailableFreeSpace }
}

function Assert-PreviewPersistentVolume($Volume) {
    $systemRoot = [IO.Path]::GetPathRoot($env:SystemRoot)
    if ($Volume.Type -ne 'Fixed' -or $Volume.Format -ine 'NTFS' -or $Volume.Name -ieq $systemRoot) { throw "方案及持久数据应放在非系统固定 NTFS 磁盘：$($Volume.Name)" }
}

function Add-PreviewError($Item, [string]$Message) { [void]$Item.Errors.Add($Message) }
function Add-PreviewWarning($Item, [string]$Message) { [void]$Item.Warnings.Add($Message) }

function Get-OperationPreview {
    param(
        [ValidateSet('Apply', 'Resume', 'Undo')][string]$Operation,
        [string]$Store,
        [string]$RequestsJson = '[]',
        [switch]$RequirePersistentStorage
    )
    $errors = New-Object 'Collections.Generic.List[string]'
    $warnings = New-Object 'Collections.Generic.List[string]'
    $items = New-Object 'Collections.Generic.List[object]'
    $budget = @{ Remaining = $script:PreviewMaximumEntries }
    $scanCache = @{}
    $volumes = @{}
    $demands = @{}
    $entries = @()
    $requests = @()
    $storePath = ''
    try {
        $storePath = ConvertTo-PreviewPath $Store
        Assert-PreviewAncestors $storePath
        $storeVolume = Get-PreviewVolume $storePath
        $volumes[$storeVolume.Name] = $storeVolume
        if ($RequirePersistentStorage) { Assert-PreviewPersistentVolume $storeVolume }
        $statePath = Join-Path $storePath 'state.json'
        $stateAttributes = Get-PreviewAttributes $statePath
        if ($null -ne $stateAttributes) {
            if (($stateAttributes -band [IO.FileAttributes]::ReparsePoint) -or ($stateAttributes -band [IO.FileAttributes]::Directory)) { throw '方案状态文件不能是目录或链接。' }
            $state = Read-State $storePath
            $entries = @($state.Entries)
        } elseif ($Operation -ne 'Apply') { throw '此目录没有保存的方案。' }
        elseif ($null -ne (Get-PreviewAttributes $storePath)) {
            foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($storePath)) {
                if ([IO.Path]::GetFileName($child) -ne '.operation.lock') { throw '首次使用请选择空方案目录。' }
            }
        }
    } catch { [void]$errors.Add($_.Exception.Message) }
    try {
        if (-not $RequestsJson -or -not $RequestsJson.Trim().StartsWith('[') -or -not $RequestsJson.Trim().EndsWith(']')) { throw '请求必须是 JSON 项目数组。' }
        # Windows PowerShell 5.1 emits a JSON array as one pipeline object.
        $decodedRequests = ConvertFrom-Json -InputObject $RequestsJson -ErrorAction Stop
        $requests = @($decodedRequests)
    } catch { [void]$errors.Add('无法读取操作项目：' + $_.Exception.Message); $requests = @() }
    if ($Operation -eq 'Apply' -and -not $requests.Count) { [void]$errors.Add('请先勾选需要迁移的目录。') }
    if ($Operation -eq 'Undo' -and -not $requests.Count) { [void]$errors.Add('撤销必须明确勾选目录，不能使用空请求撤销整份方案。') }
    if ($Operation -eq 'Resume') {
        $requests = @($entries | Where-Object { (Get-PreviewProperty $_ 'Phase') -ne 'Restored' } | ForEach-Object {
            [pscustomobject]@{ Name = (Get-PreviewProperty $_ 'Label'); Source = (Get-PreviewProperty $_ 'Source'); Target = (Get-PreviewProperty $_ 'Target') }
        })
        if (-not $requests.Count) { [void]$errors.Add('方案没有可以重新连接的项目。') }
    }

    $seenSources = @{}
    foreach ($request in $requests) {
        $item = [pscustomobject]@{
            Name = [string](Get-PreviewProperty $request 'Name' (Get-PreviewProperty $request 'Label' '未命名项目'))
            Source = ''; Target = ''; Action = ''; Bytes = [int64]0; Files = [int64]0; Status = '待检查'
            Errors = (New-Object 'Collections.Generic.List[string]'); Warnings = (New-Object 'Collections.Generic.List[string]')
        }
        [void]$items.Add($item)
        if ($null -eq $request -or $request -isnot [pscustomobject]) {
            Add-PreviewError $item '请求数组只能包含目录项目对象。'
            continue
        }
        if ($Operation -eq 'Apply' -and ((Get-PreviewProperty $request 'Name' $null) -isnot [string])) {
            Add-PreviewError $item '迁移请求缺少有效名称。'
        }
        $entry = $null
        $copyFrom = ''
        $copyTo = ''
        $scanPaths = New-Object 'Collections.Generic.List[string]'
        try { $item.Source = ConvertTo-PreviewPath (Get-PreviewProperty $request 'Source') } catch { Add-PreviewError $item $_.Exception.Message }
        if ($item.Source) {
            if ($seenSources.ContainsKey($item.Source)) {
                Add-PreviewError $item '请求包含重复的原目录。'
                Add-PreviewError $seenSources[$item.Source] '请求包含重复的原目录。'
            } else { $seenSources[$item.Source] = $item }
            $matches = @($entries | Where-Object { (Get-PreviewProperty $_ 'Source') -ieq $item.Source -and ($Operation -ne 'Apply' -or (Get-PreviewProperty $_ 'Phase') -ne 'Restored') })
            if ($matches.Count -gt 1) { Add-PreviewError $item '方案包含重复的原目录。' }
            elseif ($matches.Count -eq 1) { $entry = $matches[0] }
            elseif ($Operation -ne 'Apply') { Add-PreviewError $item '所选原目录不在已保存方案中。' }
        }
        try {
            if ($Operation -eq 'Apply') { $item.Target = ConvertTo-PreviewPath (Get-PreviewProperty $request 'Target') }
            elseif ($null -ne $entry) { $item.Target = ConvertTo-PreviewPath (Get-PreviewProperty $entry 'Target') }
        } catch { Add-PreviewError $item $_.Exception.Message }
        if (-not $item.Source -or -not $item.Target) { continue }
        if ($storePath) {
            if (Test-PreviewOverlap $item.Source $storePath) { Add-PreviewError $item '原目录不能与方案保存目录重叠。' }
            if ($item.Target -ieq $storePath -or $storePath.StartsWith($item.Target + '\', [StringComparison]::OrdinalIgnoreCase)) { Add-PreviewError $item '目标目录不能包含方案保存目录。' }
            if (Test-PreviewOverlap $item.Target (Join-Path $storePath 'Tool')) { Add-PreviewError $item '目标目录不能使用方案的 Tool 工具目录。' }
            foreach ($reserved in @('state.json','state.json.bak','state.json.tmp','.operation.lock','operations.log')) {
                if (Test-PreviewOverlap $item.Target (Join-Path $storePath $reserved)) { Add-PreviewError $item ('目标目录与方案保存文件冲突：' + $reserved) }
            }
        }
        if (Test-PreviewOverlap $item.Source $item.Target) { Add-PreviewError $item '原目录和目标目录不能相同或互相包含。' }
        try { Assert-PreviewAncestors $item.Source -AllowLeafLink } catch { Add-PreviewError $item $_.Exception.Message }
        try { Assert-PreviewAncestors $item.Target } catch { Add-PreviewError $item $_.Exception.Message }
        $phase = Get-PreviewProperty $entry 'Phase'
        $oldTarget = $item.Target
        $pending = ''
        try {
            if ($null -ne $entry) { $oldTarget = ConvertTo-PreviewPath (Get-PreviewProperty $entry 'Target') }
            if ($phase -eq 'RelocatingReady') { $pending = ConvertTo-PreviewPath (Get-PreviewProperty $entry 'PendingTarget') }
            $link = Get-PreviewLinkState $item.Source @($oldTarget, $pending | Where-Object { $_ })
            if ($null -eq $entry) {
                $item.Action = 'Copy'
                if ($link -ne 'Plain') { throw '首次迁移需要存在的普通原目录。' }
                $copyFrom = $item.Source; $copyTo = $item.Target
            } elseif ($Operation -eq 'Apply') {
                if ($phase -notin @('Ready', 'Linked')) { throw '方案包含未完成操作，请先重新连接或撤销该项目。' }
                [void]$scanPaths.Add($oldTarget)
                if ($link -eq 'Plain') { [void]$scanPaths.Add($item.Source) }
                if ($oldTarget -ieq $item.Target) { $item.Action = 'Reconnect' }
                else {
                    $item.Action = 'Relocate'; $copyFrom = $oldTarget; $copyTo = $item.Target
                    if (Test-PreviewOverlap $oldTarget $item.Target) { throw '新位置不能与旧数据目录重叠。' }
                }
            } elseif ($Operation -eq 'Resume') {
                $item.Action = 'Resume'
                if ($phase -eq 'Copying') { throw '上次复制未完成，请撤销该项目后重试。' }
                if ($phase -eq 'Restoring') { throw '上次撤销未完成，请继续撤销。' }
                if ($phase -eq 'RelocatingReady') {
                    if ($link -eq 'Plain') { throw '位置切换需要当前方案的连接或缺失的原位置。' }
                    [void]$scanPaths.Add($pending)
                    if ($link -ine $pending) { [void]$scanPaths.Add($oldTarget) }
                    Add-PreviewWarning $item '执行时会校验新旧副本内容一致后完成位置切换。'
                } elseif ($phase -in @('Ready', 'Linked')) {
                    [void]$scanPaths.Add($oldTarget)
                    if ($link -eq 'Plain') { [void]$scanPaths.Add($item.Source) }
                } else { throw '项目状态无法重新连接。' }
            } else {
                if ($phase -eq 'Restored') { $item.Action = 'AlreadyRestored' }
                elseif ($phase -eq 'Copying') {
                    $item.Action = 'CancelCopy'
                    if ($link -ne 'Plain') { throw '首次复制未完成且原目录缺失或不是普通目录，不能把部分副本当作完整数据恢复。' }
                    [void]$scanPaths.Add($item.Source)
                } elseif ($phase -in @('Ready', 'Linked', 'Restoring', 'RelocatingReady')) {
                    $item.Action = 'Restore'
                    # Core validates the old authoritative target even after a pending
                    # junction has switched, before committing relocation during Undo.
                    [void]$scanPaths.Add($oldTarget)
                    if ($phase -eq 'RelocatingReady') {
                        if ($link -eq 'Plain') { throw '位置切换期间原位置变成普通目录，请先处理连接。' }
                        if ($link -ieq $pending) { $copyFrom = $pending; [void]$scanPaths.Add($pending) }
                        else { $copyFrom = $oldTarget }
                    } else { $copyFrom = $oldTarget }
                    [void]$scanPaths.Add($copyFrom)
                    if ($phase -eq 'Linked' -and $link -eq 'Plain') { throw '原位置已经变成普通目录，请先重新连接以保留两边数据，再撤销。' }
                    $copyTo = $item.Source
                    if ($link -eq 'Plain') { [void]$scanPaths.Add($item.Source) }
                    if ($phase -eq 'Ready' -and $link -eq 'Plain') { Add-PreviewWarning $item '撤销将先建立完整恢复暂存副本，现有原目录会保留为备份。' }
                    $journal = Get-PreviewProperty $entry 'RestoreJournal' $null
                    if ($null -ne $journal) {
                        $stage = ConvertTo-PreviewPath (Get-PreviewProperty $journal 'Stage')
                        Assert-PreviewAncestors $stage
                        if ($null -ne (Get-PreviewAttributes $stage)) { [void]$scanPaths.Add($stage) }
                        $step = Get-PreviewProperty $journal 'Step'
                        if ($step -eq 'Installed' -or ($step -eq 'BackedUp' -and $null -eq (Get-PreviewAttributes $stage) -and $link -eq 'Plain')) {
                            if ($link -ne 'Plain') { throw '已安装的恢复记录缺少普通原目录，请先检查恢复副本。' }
                            $copyFrom = ''; $copyTo = ''
                            Add-PreviewWarning $item '恢复日志显示副本已安装，执行时会校验原目录后完成撤销记录。'
                        } else { Add-PreviewWarning $item '空间估算包含完整恢复暂存副本；已有暂存可复用时实际新增占用可能更少。' }
                    }
                } else { throw '项目状态无法撤销。' }
            }
            if ($copyTo -and $Operation -eq 'Apply' -and $null -ne (Get-PreviewAttributes $copyTo)) {
                foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($copyTo)) { throw '目标文件夹已有内容，请选择空文件夹或新路径。' }
            }
            if ($copyFrom) { [void]$scanPaths.Add($copyFrom) }
            if ($link -eq 'Missing' -and $item.Action -in @('Reconnect', 'Resume', 'Relocate', 'Restore')) {
                $parent = [IO.Directory]::GetParent($item.Source).FullName
                if ($null -eq (Get-PreviewAttributes $parent)) { throw '原位置的父目录不存在，请先恢复父目录。' }
            }
            if ($phase -eq 'Ready' -and $link -eq 'Plain' -and $Operation -ne 'Undo') { Add-PreviewWarning $item '执行时会校验原目录和持久副本内容一致，再建立连接。' }
        } catch { Add-PreviewError $item $_.Exception.Message }

        foreach ($scanPath in @($scanPaths | Select-Object -Unique)) {
            try {
                if (-not $scanCache.ContainsKey($scanPath)) { $scanCache[$scanPath] = Get-PreviewTreeStats $scanPath $budget }
            } catch { Add-PreviewError $item $_.Exception.Message }
        }
        if ($copyFrom -and $copyTo -and $scanCache.ContainsKey($copyFrom)) {
            $item.Bytes = [int64]$scanCache[$copyFrom].Bytes
            $item.Files = [int64]$scanCache[$copyFrom].Files
        }
        try {
            # Persistent storage checks always apply to the saved destination, including Undo.
            $targetVolume = Get-PreviewVolume $item.Target
            $volumes[$targetVolume.Name] = $targetVolume
            if ($RequirePersistentStorage) { Assert-PreviewPersistentVolume $targetVolume }
            if ($pending) {
                $pendingVolume = Get-PreviewVolume $pending
                if ($RequirePersistentStorage) { Assert-PreviewPersistentVolume $pendingVolume }
            }
            if ($copyTo -and $copyFrom) {
                $destinationVolume = Get-PreviewVolume $copyTo
                $volumes[$destinationVolume.Name] = $destinationVolume
                if (-not $demands.ContainsKey($destinationVolume.Name)) { $demands[$destinationVolume.Name] = New-Object 'Collections.Generic.List[object]' }
                [void]$demands[$destinationVolume.Name].Add($item)
            }
        } catch { Add-PreviewError $item $_.Exception.Message }
    }

    # Validate the entire resulting batch against both selected and unselected entries.
    for ($i = 0; $i -lt $items.Count; $i++) {
        $item = $items[$i]
        if (-not $item.Source -or -not $item.Target) { continue }
        for ($j = $i + 1; $j -lt $items.Count; $j++) {
            $other = $items[$j]
            if (-not $other.Source -or -not $other.Target) { continue }
            foreach ($left in @($item.Source, $item.Target)) {
                foreach ($right in @($other.Source, $other.Target)) {
                    if (Test-PreviewOverlap $left $right) {
                        Add-PreviewError $item ('与所选项目目录重叠：' + $other.Name)
                        Add-PreviewError $other ('与所选项目目录重叠：' + $item.Name)
                    }
                }
            }
        }
        foreach ($saved in $entries) {
            if ((Get-PreviewProperty $saved 'Phase') -eq 'Restored' -and $Operation -eq 'Apply') { continue }
            $sameEntry = (Get-PreviewProperty $saved 'Source') -ieq $item.Source
            $savedPaths = @()
            if (-not $sameEntry) { $savedPaths += @((Get-PreviewProperty $saved 'Source'), (Get-PreviewProperty $saved 'Target'), (Get-PreviewProperty $saved 'PendingTarget')) }
            foreach ($historyName in @('Backups','PreviousTargets','RestoreStages')) { $savedPaths += @(Get-PreviewProperty $saved $historyName @()) }
            foreach ($savedPath in $savedPaths) {
                if (-not $savedPath) { continue }
                try {
                    $normalized = ConvertTo-PreviewPath $savedPath
                    if ((Test-PreviewOverlap $item.Source $normalized) -or (Test-PreviewOverlap $item.Target $normalized)) { Add-PreviewError $item ('与已有项目目录重叠：' + (Get-PreviewProperty $saved 'Label')) }
                } catch { Add-PreviewError $item ('已有方案路径无效：' + $_.Exception.Message) }
            }
        }
    }
    if ($Operation -eq 'Undo' -and $items.Count -and @($items | Where-Object { $_.Action -ne 'AlreadyRestored' }).Count -eq 0) { [void]$errors.Add('勾选项目中没有已迁移的目录。') }
    foreach ($volumeName in $demands.Keys) {
        $required = [decimal]0
        foreach ($item in $demands[$volumeName]) { $required += $item.Bytes }
        if ($required -gt $volumes[$volumeName].FreeBytes) {
            foreach ($item in $demands[$volumeName]) { Add-PreviewError $item ("磁盘 $volumeName 剩余空间不足：整批需要 $required 字节，可用 $($volumes[$volumeName].FreeBytes) 字节。") }
        }
    }
    $totalBytes = [int64]0
    $totalFiles = [int64]0
    foreach ($item in $items) {
        $item.Errors = @($item.Errors | Select-Object -Unique)
        $item.Warnings = @($item.Warnings | Select-Object -Unique)
        if ($item.Errors.Count) { $item.Status = '阻止执行' }
        elseif ($item.Action -eq 'AlreadyRestored') { $item.Status = '已撤销' }
        else { $item.Status = '可以执行' }
        foreach ($message in $item.Errors) { [void]$errors.Add($item.Name + '：' + $message) }
        foreach ($message in $item.Warnings) { [void]$warnings.Add($item.Name + '：' + $message) }
        if ($totalBytes -gt [int64]::MaxValue - $item.Bytes -or $totalFiles -gt [int64]::MaxValue - $item.Files) { [void]$errors.Add('整批统计超出数值范围。') }
        else { $totalBytes += $item.Bytes; $totalFiles += $item.Files }
    }
    [void]$warnings.Add('预检仅反映当前目录元数据；执行前仍会重新验证，复制时会校验文件内容，所需空间不含操作期间新增数据。')
    Write-Progress -Activity '正在预检目录' -Completed
    return [pscustomobject]@{ Operation = $Operation; Store = $storePath; CanProceed = ($errors.Count -eq 0); TotalBytes = $totalBytes; TotalFiles = $totalFiles; Items = @($items.ToArray()); Errors = @($errors.ToArray()); Warnings = @($warnings.ToArray()) }
}
