$ErrorActionPreference = 'Stop'
if (-not (Get-Command Save-State -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\..\Core.ps1" }
if (-not (Get-Command Get-OperationPreview -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\..\Preflight.ps1" }
$fixture = Join-Path $env:TEMP ('env-anchor-preflight-' + [Guid]::NewGuid().ToString('N'))
$fixture = [IO.Path]::GetFullPath($fixture)
$links = New-Object 'Collections.Generic.List[string]'
$preflightReport = @{ Checks = 0 }
$originalVolume = ${function:Get-PreviewVolume}
$originalEntries = $script:PreviewMaximumEntries
$originalDepth = $script:PreviewMaximumDepth
function Check($Value, [string]$Message) {
    if (-not $Value) { throw ("FAIL: $Message; preview errors: " + ($p.Errors -join ' | ')) }
    $preflightReport.Checks++
    Write-Output "PASS: $Message"
}
function New-Tree([string]$Name, [int]$Bytes = 0) {
    $path = Join-Path $fixture $Name
    [void][IO.Directory]::CreateDirectory($path)
    if ($Bytes) { [IO.File]::WriteAllBytes((Join-Path $path 'data.bin'), (New-Object byte[] $Bytes)) }
    return $path
}
function Jobs($Value) { return ConvertTo-Json -InputObject @($Value) -Depth 12 -Compress }
function New-Entry($Source, $Target, $Phase = 'Linked') {
    return [pscustomobject]@{ Label = 'saved'; Source = $Source; Target = $Target; Phase = $Phase; Backups = @() }
}
function Write-Plan($Store, $Entries) {
    [void][IO.Directory]::CreateDirectory($Store)
    $state = [pscustomobject]@{ Version = 1; User = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; Entries = @($Entries) }
    $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Store 'state.json') -Encoding UTF8
}
function New-TestJunction($Source, $Target) {
    New-Item -ItemType Junction -Path $Source -Target $Target | Out-Null
    [void]$links.Add($Source)
}
try {
    [void][IO.Directory]::CreateDirectory($fixture)
    $sourceA = New-Tree 'SourceA' 5
    $sourceB = New-Tree 'SourceB' 7
    $store = Join-Path $fixture 'NewStore'
    $targetA = Join-Path $fixture 'TargetA'
    $targetB = Join-Path $fixture 'TargetB'
    $jobs = @([pscustomobject]@{Name='A';Source=$sourceA;Target=$targetA}, [pscustomobject]@{Name='B';Source=$sourceB;Target=$targetB})
    $p = Get-OperationPreview Apply $store (Jobs $jobs)
    Check $p.CanProceed 'valid batch passes'
    Check ($p.TotalBytes -eq 12 -and $p.TotalFiles -eq 2) 'batch counts exact bytes and files'
    Check ($p.Items.Count -eq 2 -and $p.Items[0].Action -eq 'Copy' -and $p.Items[0].Status -eq '可以执行') 'stable item interface'
    Check ($p.Operation -eq 'Apply' -and $p.Store -eq $store -and $p.Errors -is [array] -and $p.Warnings -is [array] -and $p.Items[0].Errors -is [array]) 'stable result arrays'
    Check (-not (Test-Path -LiteralPath $store) -and -not (Test-Path -LiteralPath $targetA)) 'preview creates neither store lock nor target'
    Check ((Get-Item -LiteralPath (Join-Path $sourceA 'data.bin')).Length -eq 5) 'preview preserves source content'
    $p = Get-OperationPreview Apply $store (Jobs @($jobs[0],$jobs[0]))
    Check (-not $p.CanProceed -and $p.Items[0].Errors.Count -gt 0 -and $p.Items[1].Errors.Count -gt 0) 'duplicate source blocks both items'
    $p = Get-OperationPreview Apply $store (Jobs @($jobs[0], [pscustomobject]@{Name='B';Source=$sourceB;Target=$targetA}))
    Check (-not $p.CanProceed -and $p.Items[0].Errors.Count -and $p.Items[1].Errors.Count) 'duplicate destination blocks both items'
    $p = Get-OperationPreview Apply $store (Jobs @($jobs[0], [pscustomobject]@{Name='B';Source=$sourceB;Target=(Join-Path $sourceA 'nested')}))
    Check (-not $p.CanProceed -and $p.Items[0].Errors.Count -and $p.Items[1].Errors.Count) 'cross item ancestor conflict blocks batch'
    $nonempty = New-Tree 'Nonempty' 3
    $p = Get-OperationPreview Apply $store (Jobs @([pscustomobject]@{Name='missing';Source=(Join-Path $fixture 'Missing');Target=$targetA},[pscustomobject]@{Name='full';Source=$sourceB;Target=$nonempty}))
    Check (-not $p.CanProceed -and $p.Items[0].Errors.Count -and $p.Items[1].Errors.Count -and $p.Errors.Count -ge 2) 'all projects report independent filesystem errors'
    $p = Get-OperationPreview Apply $store (Jobs @($jobs[0], 42))
    Check (-not $p.CanProceed -and $p.Items.Count -eq 2 -and $p.Items[1].Errors.Count) 'invalid object does not discard other project diagnostics'
    $p = Get-OperationPreview Apply $store '{invalid'
    Check (-not $p.CanProceed -and $p.Errors.Count) 'malformed request blocks'
    $p = Get-OperationPreview Apply $store '[]'
    Check (-not $p.CanProceed) 'empty apply blocks'
    $p = Get-OperationPreview Apply $store (Jobs @([pscustomobject]@{Source=$sourceA;Target=$targetA}))
    Check (-not $p.CanProceed) 'missing apply name blocks'
    foreach ($badPath in @('relative', ($fixture+'\SourceA\..\SourceA'), ($sourceA+'\'), ($sourceA+'/nested'), ($sourceA+':stream'), (Join-Path $fixture 'CON'))) {
        $p = Get-OperationPreview Apply $store (Jobs @([pscustomobject]@{Name='unsafe';Source=$badPath;Target=$targetA}))
        Check (-not $p.CanProceed) ('unsafe request path blocks: ' + $badPath)
    }
    $p = Get-OperationPreview Apply $sourceA (Jobs $jobs[0])
    Check (-not $p.CanProceed) 'source overlapping store blocks'
    $p = Get-OperationPreview Apply $store (Jobs @([pscustomobject]@{Name='tool';Source=$sourceA;Target=(Join-Path $store 'Tool\Data')}))
    Check (-not $p.CanProceed) 'tool destination blocks'
    $p = Get-OperationPreview Apply $store (Jobs @([pscustomobject]@{Name='metadata';Source=$sourceA;Target=(Join-Path $store 'state.json')}))
    Check (-not $p.CanProceed) 'reserved state destination blocks before state exists'
    $script:PreviewMaximumEntries = 1
    $p = Get-OperationPreview Apply $store (Jobs $jobs)
    Check (-not $p.CanProceed -and @($p.Errors | Where-Object {$_ -like '*预算*'}).Count) 'whole batch scan budget cannot pass incomplete statistics'
    $script:PreviewMaximumEntries = $originalEntries
    $deep = New-Tree 'Deep\one\two' 1
    $script:PreviewMaximumDepth = 0
    $p = Get-OperationPreview Apply $store (Jobs @([pscustomobject]@{Name='deep';Source=(Join-Path $fixture 'Deep');Target=$targetA}))
    Check (-not $p.CanProceed -and @($p.Errors | Where-Object {$_ -like '*深度*'}).Count) 'scan depth budget blocks'
    $script:PreviewMaximumDepth = $originalDepth
    $linkedTree = New-Tree 'LinkedTree'
    $nestedLink = Join-Path $linkedTree 'outside'
    New-TestJunction $nestedLink $sourceB
    $p = Get-OperationPreview Apply $store (Jobs @([pscustomobject]@{Name='link';Source=$linkedTree;Target=$targetA}))
    Check (-not $p.CanProceed -and $p.TotalFiles -eq 0 -and @($p.Errors | Where-Object {$_ -like '*未遍历*'}).Count) 'nested junction is rejected without traversal'
    $p = Get-OperationPreview Apply $store (Jobs @([pscustomobject]@{Name='ancestor';Source=(Join-Path $nestedLink 'new');Target=$targetA}))
    Check (-not $p.CanProceed) 'linked ancestor blocks'
    function Get-PreviewVolume([string]$Path) { return [pscustomobject]@{Name='P:\';Type='Fixed';Format='NTFS';FreeBytes=[int64]10} }
    $p = Get-OperationPreview Apply $store (Jobs $jobs)
    Check (-not $p.CanProceed -and $p.Items[0].Errors.Count -and $p.Items[1].Errors.Count) 'space demand is summed on one volume'
    function Get-PreviewVolume([string]$Path) { return [pscustomobject]@{Name='P:\';Type='Fixed';Format='NTFS';FreeBytes=[int64]1000} }
    $p = Get-OperationPreview Apply $store (Jobs $jobs) -RequirePersistentStorage
    Check $p.CanProceed 'fixed nonsystem NTFS persistent volume passes'
    foreach ($badVolume in @([pscustomobject]@{Name=([IO.Path]::GetPathRoot($env:SystemRoot));Type='Fixed';Format='NTFS';FreeBytes=1000},[pscustomobject]@{Name='P:\';Type='Removable';Format='NTFS';FreeBytes=1000},[pscustomobject]@{Name='P:\';Type='Fixed';Format='exFAT';FreeBytes=1000})) {
        function Get-PreviewVolume([string]$Path) { return $badVolume }
        $p = Get-OperationPreview Apply $store (Jobs $jobs) -RequirePersistentStorage
        Check (-not $p.CanProceed) ('persistent volume blocks: ' + $badVolume.Type + '/' + $badVolume.Format + '/' + $badVolume.Name)
    }
    ${function:Get-PreviewVolume} = $originalVolume
    $savedStore = New-Tree 'SavedStore'
    $savedTarget = New-Tree 'SavedTarget' 7
    $savedSource = Join-Path $fixture 'SavedSource'
    New-TestJunction $savedSource $savedTarget
    $entry = New-Entry $savedSource $savedTarget
    Write-Plan $savedStore @($entry)
    $stateFile = Join-Path $savedStore 'state.json'
    $stateHash = Get-ContentHash $stateFile
    $stateTime = (Get-Item -LiteralPath $stateFile).LastWriteTimeUtc
    $undoJob = [pscustomobject]@{Name='undo';Source=$savedSource}
    $p = Get-OperationPreview Undo $savedStore (Jobs $undoJob)
    Check ($p.CanProceed -and $p.TotalBytes -eq 7 -and $p.TotalFiles -eq 1 -and $p.Items[0].Action -eq 'Restore') 'linked undo includes full sibling restore staging demand'
    Check ((Get-ContentHash $stateFile) -eq $stateHash -and (Get-Item -LiteralPath $stateFile).LastWriteTimeUtc -eq $stateTime -and -not (Test-Path -LiteralPath (Join-Path $savedStore '.operation.lock'))) 'saved preview leaves state bytes timestamp and lock unchanged'
    Check ((Get-EntryHealth $entry) -eq '连接正常') 'health detects live junction'
    $p = Get-OperationPreview Resume $savedStore
    Check ($p.CanProceed -and $p.TotalBytes -eq 0 -and $p.Items[0].Action -eq 'Resume') 'resume connection does not demand a data copy'
    $p = Get-OperationPreview Undo $savedStore '[]'
    Check (-not $p.CanProceed) 'empty undo blocks whole plan undo'
    $p = Get-OperationPreview Undo $savedStore (Jobs @([pscustomobject]@{Name='unknown';Source=$sourceA}))
    Check (-not $p.CanProceed -and @($p.Errors | Where-Object {$_ -like '*不在*'}).Count) 'unknown undo source blocks'
    function Get-PreviewVolume([string]$Path) {
        if ($Path -eq $savedSource) { return [pscustomobject]@{Name=([IO.Path]::GetPathRoot($env:SystemRoot));Type='Fixed';Format='NTFS';FreeBytes=[int64]1000} }
        return [pscustomobject]@{Name='P:\';Type='Fixed';Format='NTFS';FreeBytes=[int64]1000}
    }
    $p = Get-OperationPreview Undo $savedStore (Jobs $undoJob) -RequirePersistentStorage
    Check $p.CanProceed 'persistent undo permits source on system volume'
    function Get-PreviewVolume([string]$Path) { return [pscustomobject]@{Name='P:\';Type='Fixed';Format='NTFS';FreeBytes=[int64]6} }
    $p = Get-OperationPreview Undo $savedStore (Jobs $undoJob)
    Check (-not $p.CanProceed) 'undo staging demand blocks insufficient free space'
    ${function:Get-PreviewVolume} = $originalVolume
    [IO.Directory]::Delete($savedSource)
    $p = Get-OperationPreview Resume $savedStore
    Check ($p.CanProceed -and (Get-EntryHealth $entry) -eq '原位置缺失，可重新连接') 'missing source can reconnect with existing parent'
    [void][IO.Directory]::CreateDirectory($savedSource)
    [IO.File]::WriteAllBytes((Join-Path $savedSource 'local.bin'), (New-Object byte[] 3))
    $p = Get-OperationPreview Undo $savedStore (Jobs $undoJob)
    Check (-not $p.CanProceed) 'linked state with ordinary source blocks undo'
    $entry.Phase = 'Ready'; Write-Plan $savedStore @($entry)
    $p = Get-OperationPreview Undo $savedStore (Jobs $undoJob)
    Check ($p.CanProceed -and $p.TotalBytes -eq 7) 'ready ordinary source undo still budgets full restore stage'
    Check ((Get-Item -LiteralPath (Join-Path $savedSource 'local.bin')).Length -eq 3) 'ready preview retains source conflict data'
    $entry.Phase = 'Copying'; Write-Plan $savedStore @($entry)
    $p = Get-OperationPreview Undo $savedStore (Jobs $undoJob)
    Check ($p.CanProceed -and $p.Items[0].Action -eq 'CancelCopy' -and $p.TotalBytes -eq 0) 'incomplete initial copy cancellation uses existing original'
    $p = Get-OperationPreview Resume $savedStore
    Check (-not $p.CanProceed) 'copying state blocks reconnect'
    $entry.Phase = 'Restoring'
    $stage = $savedSource + '.env-anchor-restore-' + [Guid]::NewGuid().ToString('N')
    [void][IO.Directory]::CreateDirectory($stage)
    [IO.File]::WriteAllBytes((Join-Path $stage 'partial.bin'), (New-Object byte[] 1))
    $entry | Add-Member RestoreStages @($stage)
    $entry | Add-Member RestoreJournal ([pscustomobject]@{Stage=$stage;ConflictBackup='';Step='Copying'})
    Write-Plan $savedStore @($entry)
    $p = Get-OperationPreview Undo $savedStore (Jobs $undoJob)
    Check ($p.CanProceed -and $p.TotalBytes -eq 7 -and $p.Warnings.Count -gt 1) 'interrupted restore conservatively budgets new full stage'
    $entry.RestoreJournal.Step = 'Installed'; Write-Plan $savedStore @($entry)
    $p = Get-OperationPreview Undo $savedStore (Jobs $undoJob)
    Check ($p.CanProceed -and $p.TotalBytes -eq 0) 'installed restore only finalizes journal'
    $entry.RestoreJournal.Step = 'Copying'
    $linkedStage = $savedSource + '.env-anchor-restore-' + [Guid]::NewGuid().ToString('N')
    New-TestJunction $linkedStage $sourceB
    $entry.RestoreStages = @($stage,$linkedStage); $entry.RestoreJournal.Stage = $linkedStage
    Write-Plan $savedStore @($entry)
    $p = Get-OperationPreview Undo $savedStore (Jobs $undoJob)
    Check (-not $p.CanProceed) 'restore journal stage link blocks without traversal'
    $entry = New-Entry $savedSource $savedTarget 'Ready'
    $backup = $savedSource + '.env-anchor-backup-' + [Guid]::NewGuid().ToString('N')
    $entry.Backups = @($backup)
    Write-Plan $savedStore @($entry)
    $p = Get-OperationPreview Apply $savedStore (Jobs @([pscustomobject]@{Name='history';Source=$savedSource;Target=$backup}))
    Check (-not $p.CanProceed -and @($p.Errors | Where-Object {$_ -like '*已有项目*'}).Count) 'relocation cannot overwrite recorded historical backup'
    $entry.Phase = 'Restored'; Write-Plan $savedStore @($entry)
    $p = Get-OperationPreview Undo $savedStore (Jobs $undoJob)
    Check (-not $p.CanProceed -and $p.Items[0].Status -eq '已撤销') 'all restored selection blocks redundant undo'
    Check ((Get-EntryHealth $entry) -eq '已撤销') 'health reports restored phase in Chinese'
    $entry.Phase = 'Unknown'; Write-Plan $savedStore @($entry)
    $p = Get-OperationPreview Resume $savedStore
    Check (-not $p.CanProceed -and @($p.Errors | Where-Object {$_ -like '*阶段*'}).Count) 'strict state schema rejects unknown phase'
    [IO.File]::WriteAllText($stateFile, '{broken')
    $p = Get-OperationPreview Undo $savedStore (Jobs $undoJob)
    Check (-not $p.CanProceed) 'malformed stored state blocks without rewriting'
    Check ([IO.File]::ReadAllText($stateFile) -eq '{broken') 'malformed state remains byte identical'
    $relocateSource = Join-Path $fixture 'RelocateSource'
    $relocateTarget = New-Tree 'RelocateTarget' 4
    $pendingTarget = New-Tree 'PendingTarget' 6
    New-TestJunction $relocateSource $relocateTarget
    $relocate = New-Entry $relocateSource $relocateTarget 'RelocatingReady'
    $relocate | Add-Member PendingTarget $pendingTarget
    Write-Plan $savedStore @($relocate)
    $relocateJob = [pscustomobject]@{Name='relocate';Source=$relocateSource}
    $p = Get-OperationPreview Resume $savedStore
    Check ($p.CanProceed -and $p.Warnings.Count -gt 1) 'relocation resume previews metadata and requires execution content comparison'
    $p = Get-OperationPreview Undo $savedStore (Jobs $relocateJob)
    Check ($p.CanProceed -and $p.TotalBytes -eq 4) 'undo before relocation switch estimates old authoritative target'
    [IO.Directory]::Delete($relocateSource)
    New-TestJunction $relocateSource $pendingTarget
    $p = Get-OperationPreview Undo $savedStore (Jobs $relocateJob)
    Check ($p.CanProceed -and $p.TotalBytes -eq 6) 'undo after relocation switch estimates pending target'
    [IO.Directory]::Move($relocateTarget, ($relocateTarget+'.offline'))
    $p = Get-OperationPreview Undo $savedStore (Jobs $relocateJob)
    Check (-not $p.CanProceed) 'relocation undo requires old target for Core validation'
    [IO.Directory]::Move(($relocateTarget+'.offline'), $relocateTarget)
    $relocate.Phase = 'Linked'; $relocate.PendingTarget = ''; $relocate.Target = $pendingTarget
    Write-Plan $savedStore @($relocate)
    $newTarget = Join-Path $fixture 'NewRelocationTarget'
    $p = Get-OperationPreview Apply $savedStore (Jobs @([pscustomobject]@{Name='relocate';Source=$relocateSource;Target=$newTarget}))
    Check ($p.CanProceed -and $p.TotalBytes -eq 6 -and $p.Items[0].Action -eq 'Relocate') 'normal relocation estimates full target copy'
    $foreignSource = Join-Path $fixture 'ForeignSource'
    New-TestJunction $foreignSource $sourceA
    $foreign = New-Entry $foreignSource $sourceB
    Write-Plan $savedStore @($foreign)
    $p = Get-OperationPreview Resume $savedStore
    Check (-not $p.CanProceed -and (Get-EntryHealth $foreign) -like '连接异常：*') 'foreign junction blocks resume and reports Chinese health error'
    Write-Output "Preflight checks passed: $($preflightReport.Checks)"
} finally {
    ${function:Get-PreviewVolume} = $originalVolume
    $script:PreviewMaximumEntries = $originalEntries
    $script:PreviewMaximumDepth = $originalDepth
    # Only known synthetic junction leaves are removed before deleting this fixture.
    foreach ($link in $links) {
        if ([IO.Directory]::Exists($link) -and ([IO.File]::GetAttributes($link) -band [IO.FileAttributes]::ReparsePoint)) { [IO.Directory]::Delete($link) }
    }
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('env-anchor-preflight-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } else { throw 'Synthetic fixture cleanup path validation failed.' }
}
