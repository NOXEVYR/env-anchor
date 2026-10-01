$ErrorActionPreference='Stop'
if (-not (Get-Command Save-State -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\..\Core.ps1" }
$fixture=Join-Path $env:TEMP ('env-anchor-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$checkCount=[pscustomobject]@{Passed=0}
function Check($Value,$Message) {if(-not $Value){throw "FAIL: $Message"}; $checkCount.Passed++; Write-Output "PASS: $Message"}
$store=Join-Path $fixture 'Store'
$source=Join-Path $fixture 'Profile\配置'
New-Item -ItemType Directory -Path $store,$source | Out-Null
Set-Content -LiteralPath (Join-Path $source 'config.yaml') -Value 'initial'
New-Item -ItemType Directory -Path (Join-Path $source 'empty') | Out-Null
$state=[pscustomobject]@{Version=1;User=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Entries=@()}
Add-Entry $source 'test' $state $store
$entry=$state.Entries[0]
Check (Test-OurLink $source $entry.Target) 'migration creates correct junction'
Check (Test-Path -LiteralPath $entry.Backups[0]) 'original retained'
Check (Test-Path -LiteralPath (Join-Path $entry.Target 'empty')) 'empty directories copied'
Set-Content -LiteralPath (Join-Path $source 'config.yaml') -Value 'new preference'
Check ((Get-Content -LiteralPath (Join-Path $entry.Target 'config.yaml')) -eq 'new preference') 'changes persist in target'
[IO.Directory]::Delete($source)
New-Item -ItemType Directory -Path $source | Out-Null
Set-Content -LiteralPath (Join-Path $source 'config.yaml') -Value 'old reset baseline'
$state=Read-State $store
Resume-State $state $store
Check ((Get-Content -LiteralPath (Join-Path $source 'config.yaml')) -eq 'new preference') 'reset baseline cannot overwrite persistent data'
Resume-State $state $store
Check (@($state.Entries[0].Backups).Count -eq 2) 'resume is idempotent'
Undo-State $state $store
Check (-not ((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'undo restores ordinary directory'
Check ((Get-Content -LiteralPath (Join-Path $source 'config.yaml')) -eq 'new preference') 'undo copies current preferences back'
Check (Test-Path -LiteralPath $state.Entries[0].Target) 'undo retains persistent copy'
$bad=Join-Path $fixture 'bad'
New-Item -ItemType Directory -Path $bad | Out-Null
New-Item -ItemType Junction -Path (Join-Path $bad 'nested-link') -Target $source | Out-Null
$rejected=$false
try {Assert-PlainTree $bad} catch {$rejected=$true}
Check $rejected 'nested reparse points rejected'
[IO.Directory]::Delete((Join-Path $bad 'nested-link'))
$other=Join-Path $fixture 'other-link'
New-Item -ItemType Junction -Path $other -Target $source | Out-Null
$rejected=$false
try {Test-OurLink $other $store | Out-Null} catch {$rejected=$true}
Check $rejected 'unrelated junction rejected'
[IO.Directory]::Delete($other)
$incomplete=[pscustomobject]@{Version=1;User=$state.User;Entries=@([pscustomobject]@{Label='incomplete';Source=$source;Target=(Join-Path $fixture 'IncompleteTarget');Phase='Copying';Backups=@()})}
$rejected=$false
try {Resume-State $incomplete $store} catch {$rejected=$_.Exception.Message -like '*上次复制未完成*'}
Check $rejected 'interrupted copy cannot be linked'
$state.Entries[0].Phase='Restoring'
Save-State $state $store
Undo-State $state $store
Check ($state.Entries[0].Phase -eq 'Restored') 'interrupted undo can finish safely'
$customStore=Join-Path $fixture 'CustomPlan'
$customSource=Join-Path $fixture 'CustomProfile'
$customTarget=Join-Path $fixture 'ChosenDisk\Clash'
New-Item -ItemType Directory -Path $customStore,$customSource | Out-Null
Set-Content -LiteralPath (Join-Path $customSource 'config.yaml') -Value 'custom disk preference'
$customState=[pscustomobject]@{Version=1;User=$state.User;Entries=@()}
Add-Entry $customSource 'custom' $customState $customStore $customTarget
Check (Test-OurLink $customSource $customTarget) 'explicit destination is used exactly'
Check ((Read-State $customStore).Entries[0].Target -eq $customTarget) 'custom destination saved in plan'
[IO.Directory]::Delete($customSource)
New-Item -ItemType Directory -Path $customSource | Out-Null
Resume-State (Read-State $customStore) $customStore
Check ((Get-Content -LiteralPath (Join-Path $customSource 'config.yaml')) -eq 'custom disk preference') 'custom destination survives simulated reset'
$emptyState=[pscustomobject]@{Entries=@()}
$rejected=$false
try {Assert-EntryPaths $source $customTarget $emptyState $customStore} catch {$rejected=$true}
Check $rejected 'nonempty custom destination rejected'
$rejected=$false
try {Assert-EntryPaths $source (Join-Path $source 'nested') $emptyState $customStore} catch {$rejected=$true}
Check $rejected 'source and destination overlap rejected'
$rejected=$false
try {Assert-EntryPaths $source (Join-Path $customTarget 'nested') $customState $customStore} catch {$rejected=$true}
Check $rejected 'overlapping project destinations rejected'
Move-Item -LiteralPath $customTarget -Destination ($customTarget+'-offline')
$rejected=$false
try {Resume-State $customState $customStore} catch {$rejected=$true}
Check $rejected 'missing custom target blocks resume'
$rejected=$false
try {Undo-State $customState $customStore} catch {$rejected=$true}
Check $rejected 'missing custom target blocks undo before unlink'
Move-Item -LiteralPath ($customTarget+'-offline') -Destination $customTarget
Check (Test-OurLink $customSource $customTarget) 'junction retained when target unavailable'
Undo-State $customState $customStore
Check ((Get-Content -LiteralPath (Join-Path $customSource 'config.yaml')) -eq 'custom disk preference') 'custom destination undo restores content'
$batchStore=Join-Path $fixture 'BatchPlan'
New-Item -ItemType Directory -Path $batchStore | Out-Null
$batchState=[pscustomobject]@{Version=1;User=$state.User;Entries=@()}
foreach($name in @('Desktop','Clash')) {
    $original=Join-Path $fixture ('BatchProfile\'+$name)
    New-Item -ItemType Directory -Path $original -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $original 'setting.txt') -Value $name
    Add-Entry $original $name $batchState $batchStore
}
$previous=@($batchState.Entries | ForEach-Object {$_.Target})
$unified=Join-Path $fixture 'Unified'
foreach($entry in $batchState.Entries) {Move-EntryTarget $entry (Get-DefaultTarget $unified $entry.Label $entry.Source) $batchState $batchStore}
Check (@($batchState.Entries | Where-Object {$_.Target.StartsWith($unified+'\')}).Count -eq 2) 'batch relocation uses common root'
Check ($batchState.Entries[0].Target -ne $batchState.Entries[1].Target) 'batch entries keep independent destinations'
Check ((Get-Content -LiteralPath (Join-Path $batchState.Entries[0].Source 'setting.txt')) -eq 'Desktop') 'relocated desktop content intact'
Check ((Get-Content -LiteralPath (Join-Path $batchState.Entries[1].Source 'setting.txt')) -eq 'Clash') 'relocated app content intact'
Check ((Test-Path -LiteralPath $previous[0]) -and (Test-Path -LiteralPath $previous[1])) 'old destinations retained'
Check ((Read-State $batchStore).Entries[0].Target -eq $batchState.Entries[0].Target) 'new destination committed to original plan'
$a=Get-DefaultTarget $unified 'SameName' 'C:\one\config'
$b=Get-DefaultTarget $unified 'SameName' 'C:\two\config'
Check ($a -ne $b) 'same-name entries receive distinct subfolders'
$entry=$batchState.Entries[0]
$next=Join-Path $fixture 'CrashAfterUnlink'
Copy-Verified $entry.Target $next
$entry.PendingTarget=$next; $entry.Phase='RelocatingReady'; Save-State $batchState $batchStore
[IO.Directory]::Delete($entry.Source)
$batchState=Read-State $batchStore
Resume-State $batchState $batchStore
Check (Test-OurLink $batchState.Entries[0].Source $next) 'resume completes interrupted link switch'
$entry=$batchState.Entries[0]
$next=Join-Path $fixture 'CrashBeforeCommit'
Copy-Verified $entry.Target $next
$entry.PendingTarget=$next; $entry.Phase='RelocatingReady'; Save-State $batchState $batchStore
[IO.Directory]::Delete($entry.Source)
New-Item -ItemType Junction -Path $entry.Source -Target $next | Out-Null
$batchState=Read-State $batchStore
Resume-State $batchState $batchStore
Check ((Read-State $batchStore).Entries[0].Target -eq $next) 'resume commits already switched junction'
Undo-State $batchState $batchStore
Check ((Get-Content -LiteralPath (Join-Path $entry.Source 'setting.txt')) -eq 'Desktop') 'undo after relocation restores latest files'
$regStore=Join-Path $fixture 'RegressionPlan'
$regOne=Join-Path $fixture 'RegressionInputOne'
$regTwo=Join-Path $fixture 'RegressionInputTwo'
New-Item -ItemType Directory -Path $regOne,$regTwo | Out-Null
Set-Content -LiteralPath (Join-Path $regOne 'data.txt') -Value 'one'
Set-Content -LiteralPath (Join-Path $regTwo 'data.txt') -Value 'two'
$regJobs=@([pscustomobject]@{Source=$regOne;Target=(Join-Path $fixture 'RegressionTargetOne');Name='one'},[pscustomobject]@{Source=$regTwo;Target=(Join-Path $fixture 'RegressionTargetTwo');Name='two'})
Invoke-PlanOperation Apply $regStore (ConvertTo-Json -InputObject $regJobs)
Check ((Read-State $regStore).Entries.Count -eq 2) 'dispatcher creates multi-entry plan'
Invoke-PlanOperation Undo $regStore (ConvertTo-Json -InputObject @($regJobs[0]))
$regState=Read-State $regStore
Check ($regState.Entries[0].Phase -eq 'Restored' -and $regState.Entries[1].Phase -eq 'Linked') 'selective undo leaves other entry linked'
$regJobs[0].Target=Join-Path $fixture 'RegressionTargetOneAgain'
Invoke-PlanOperation Apply $regStore (ConvertTo-Json -InputObject @($regJobs[0]))
Check ((Read-State $regStore).Entries.Count -eq 2) 'restored entry can migrate again without disturbing others'
Check (Test-Path -LiteralPath (Join-Path $regStore 'operations.log')) 'operation log records results'
$held=[IO.File]::Open((Join-Path $regStore '.operation.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$rejected=$false
try {Invoke-PlanOperation Resume $regStore} catch {$rejected=$_.Exception.Message -like '*另一个窗口*'} finally {$held.Dispose()}
Check $rejected 'parallel operation on same plan is blocked'
Invoke-PlanOperation Resume $regStore
Check $true 'plan lock released after conflict'
# Snapshot an empty plan, then attempt the other window's real Apply before returning
# that snapshot. Without the lock this deterministically completes the peer first,
# leaving the outer window's cached "fresh" decision able to overwrite its record.
& {
    $raceStore=Join-Path $fixture 'FirstStartRacePlan'
    $raceOne=Join-Path $fixture 'FirstStartInputOne'
    $raceTwo=Join-Path $fixture 'FirstStartInputTwo'
    New-Item -ItemType Directory -Path $raceStore,$raceOne,$raceTwo | Out-Null
    Set-Content -LiteralPath (Join-Path $raceOne 'data.txt') -Value 'first window data'
    Set-Content -LiteralPath (Join-Path $raceTwo 'data.txt') -Value 'second window data'
    $raceJobs=@([pscustomobject]@{Source=$raceOne;Target=(Join-Path $fixture 'FirstStartTargetOne');Name='first'},[pscustomobject]@{Source=$raceTwo;Target=(Join-Path $fixture 'FirstStartTargetTwo');Name='second'})
    $race=[pscustomobject]@{StateChecked=$false;StateReadLocked=$false;Triggered=$false;PeerCompleted=$false;PeerBlocked=$false}
    function Test-Path {
        param([string]$LiteralPath,[string]$PathType)
        $exists=Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
        if($LiteralPath -eq (Join-Path $raceStore 'state.json') -and -not $race.StateChecked) {
            $race.StateChecked=$true
            $probe=$null
            try {$probe=[IO.File]::Open((Join-Path $raceStore '.operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
            catch [IO.IOException] {$race.StateReadLocked=$true}
            finally {if($null -ne $probe){$probe.Dispose()}}
        }
        return $exists
    }
    function Get-ChildItem {
        param([string]$LiteralPath,[switch]$Force,[switch]$File,[switch]$Recurse)
        $items=@(Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters)
        if($LiteralPath -eq $raceStore -and -not $race.Triggered) {
            $race.Triggered=$true
            try {
                Invoke-PlanOperation Apply $raceStore (ConvertTo-Json -InputObject @($raceJobs[1]))
                $race.PeerCompleted=$true
            } catch {
                if($_.Exception.Message -notlike '*另一个窗口*'){throw}
                $race.PeerBlocked=$true
            }
        }
        return $items
    }
    Invoke-PlanOperation Apply $raceStore (ConvertTo-Json -InputObject @($raceJobs[0]))
    if(-not $race.PeerCompleted){Invoke-PlanOperation Apply $raceStore (ConvertTo-Json -InputObject @($raceJobs[1]))}
    $raceState=Read-State $raceStore
    Check ($race.Triggered -and $raceState.Entries.Count -eq 2) 'interleaved first starts preserve both plan records'
    Check ($race.StateChecked -and $race.StateReadLocked) 'first-start state decision runs under exclusive plan lock'
    Check $race.PeerBlocked 'first-start empty-directory validation holds plan lock'
    foreach($job in $raceJobs) {
        $saved=@($raceState.Entries | Where-Object {$_.Source -eq $job.Source})
        Check ($saved.Count -eq 1 -and (Test-OurLink $job.Source $job.Target)) ('first-start connection recorded: '+$job.Name)
        Check ((Test-Path -LiteralPath $saved[0].Backups[0]) -and (Get-ContentHash (Join-Path $saved[0].Backups[0] 'data.txt')) -eq (Get-ContentHash (Join-Path $job.Target 'data.txt'))) ('first-start original data retained: '+$job.Name)
    }
}
$regState=Read-State $regStore
$regEntry=$regState.Entries[0]
[IO.Directory]::Delete($regEntry.Source)
New-Item -ItemType Directory -Path $regEntry.Source | Out-Null
Set-Content -LiteralPath (Join-Path $regEntry.Source 'data.txt') -Value 'reset baseline'
Move-EntryTarget $regEntry $regEntry.Target $regState $regStore
Check (Test-OurLink $regEntry.Source $regEntry.Target) 'same-target apply repairs reset connection'
$outside=Join-Path $fixture 'SyntheticOutside'
New-Item -ItemType Directory -Path $outside | Out-Null
$linkedDest=Join-Path $fixture 'LinkedCopyDestination'
New-Item -ItemType Junction -Path $linkedDest -Target $outside | Out-Null
$rejected=$false
try {Copy-Verified $regEntry.Target $linkedDest} catch {$rejected=$true}
Check ($rejected -and -not (Test-Path -LiteralPath (Join-Path $outside 'data.txt'))) 'copy refuses linked destination without writing through it'
[IO.Directory]::Delete($linkedDest)
$lost=[pscustomobject]@{Label='lost';Source=(Join-Path $fixture 'MissingOriginal');Target=$regEntry.Target;Phase='Copying';Backups=@()}
$rejected=$false
try {Undo-State ([pscustomobject]@{Version=1;User=$state.User;Entries=@($lost)}) $regStore} catch {$rejected=$_.Exception.Message -like '*首次复制未完成且原目录缺失*'}
Check ($rejected -and -not (Test-Path -LiteralPath $lost.Source)) 'incomplete copy is never restored as complete data'
$stale=Join-Path $fixture 'StaleRelocation'
Copy-Verified $regEntry.Target $stale
$regEntry | Add-Member -NotePropertyName PendingTarget -NotePropertyValue $stale -Force
$regEntry.Phase='RelocatingReady'; Save-State $regState $regStore
Set-Content -LiteralPath (Join-Path $regEntry.Target 'data.txt') -Value 'edited after copying'
$rejected=$false
try {Complete-Relocation $regEntry $regState $regStore} catch {$rejected=$true}
Check ($rejected -and (Test-OurLink $regEntry.Source $regEntry.Target)) 'stale relocation copy cannot replace newer source data'
$regEntry.Phase='Linked';$regEntry.PendingTarget='';Save-State $regState $regStore
$historyOne=Join-Path $fixture 'HistoryOne';$historyTwo=Join-Path $fixture 'HistoryTwo'
Move-EntryTarget $regEntry $historyOne $regState $regStore
Move-EntryTarget $regEntry $historyTwo $regState $regStore
Check (@($regEntry.PreviousTargets).Count -eq 2) 'successive relocations retain all previous target records'
$badStore=Join-Path $fixture 'BadBatchPlan'
$badSource=Join-Path $fixture 'UntouchedSource'; New-Item -ItemType Directory -Path $badSource | Out-Null
$badJobs=@([pscustomobject]@{Source=$badSource;Target=(Join-Path $fixture 'UnusedTarget');Name='valid'},[pscustomobject]@{Source=(Join-Path $fixture 'DoesNotExist');Target=(Join-Path $fixture 'UnusedTarget2');Name='invalid'})
$rejected=$false
try {Invoke-PlanOperation Apply $badStore (ConvertTo-Json -InputObject $badJobs)} catch {$rejected=$true}
Check ($rejected -and -not (Test-Path -LiteralPath (Join-Path $fixture 'UnusedTarget'))) 'invalid later batch item prevents earlier file changes'
Check (-not (Test-Path -LiteralPath (Join-Path $badStore 'state.json'))) 'failed batch validation leaves no misleading plan'
$lockedFile=Join-Path $regEntry.Target 'data.txt'
$handle=[IO.File]::Open($lockedFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$rejected=$false
try {Copy-Verified $regEntry.Target (Join-Path $fixture 'LockedCopy')} catch {$rejected=$true} finally {$handle.Dispose()}
Check ($rejected -and (Test-OurLink $regEntry.Source $regEntry.Target)) 'locked file fails without changing live connection'
$staleAgain=Join-Path $fixture 'StaleAgain'
Copy-Verified $regEntry.Target $staleAgain
$regEntry.PendingTarget=$staleAgain; $regEntry.Phase='RelocatingReady'; Save-State $regState $regStore
Set-Content -LiteralPath (Join-Path $regEntry.Target 'data.txt') -Value 'latest after failed relocation'
Undo-State $regState $regStore @($regEntry.Source)
Check ((Get-Content -LiteralPath (Join-Path $regEntry.Source 'data.txt')) -eq 'latest after failed relocation') 'undo can safely abandon stale pending relocation'
Check (Test-Path -LiteralPath $staleAgain) 'abandoned relocation copy is retained for inspection'
# Every path below belongs to the randomly allocated synthetic fixture.
function Clone-TestState($Value) {return ($Value | ConvertTo-Json -Depth 8 | ConvertFrom-Json)}
function Expect-Rejection($Action,$Message) {
    $didReject=$false
    try {& $Action} catch {$didReject=$true}
    Check $didReject $Message
}
$schemaStore=Join-Path $fixture 'SchemaPlan'
$schemaBase=[pscustomobject]@{Version=1;User=$state.User;Entries=@([pscustomobject]@{Label='schema';Source=(Join-Path $fixture 'SchemaSource');Target=(Join-Path $fixture 'SchemaTarget');Backups=@();Phase='Linked'})}
$schemaCases=@(
    @{Name='unknown phase';Edit={param($s) $s.Entries[0].Phase='Surprise'}},
    @{Name='incorrect phase casing';Edit={param($s) $s.Entries[0].Phase='linked'}},
    @{Name='source equals target';Edit={param($s) $s.Entries[0].Target=$s.Entries[0].Source}},
    @{Name='target inside source';Edit={param($s) $s.Entries[0].Target=Join-Path $s.Entries[0].Source 'child'}},
    @{Name='source inside target';Edit={param($s) $s.Entries[0].Source=Join-Path $s.Entries[0].Target 'child'}},
    @{Name='relative source';Edit={param($s) $s.Entries[0].Source='relative\config'}},
    @{Name='dot segment source';Edit={param($s) $s.Entries[0].Source=Join-Path $fixture 'SchemaSource\..\other'}},
    @{Name='reserved filename';Edit={param($s) $s.Entries[0].Source=Join-Path $fixture 'NUL.txt'}},
    @{Name='invalid SID';Edit={param($s) $s.User='S-1-999999999999999999999-1'}},
    @{Name='foreign SID';Edit={param($s) $s.User='S-1-5-18'}},
    @{Name='string version';Edit={param($s) $s.Version='1'}},
    @{Name='nonarray entries';Edit={param($s) $s.Entries=$s.Entries[0]}},
    @{Name='nonarray backups';Edit={param($s) $s.Entries[0].Backups='invalid'}},
    @{Name='unrelated backup path';Edit={param($s) $s.Entries[0].Backups=@(Join-Path $fixture 'UnrelatedBackup')}},
    @{Name='duplicate entry';Edit={param($s) $s.Entries=@($s.Entries[0],(Clone-TestState $s.Entries[0]))}},
    @{Name='historical target overlap';Edit={param($s) $s.Entries[0] | Add-Member PreviousTargets @($s.Entries[0].Target)}},
    @{Name='pending target wrong phase';Edit={param($s) $s.Entries[0] | Add-Member PendingTarget (Join-Path $fixture 'PendingTarget')}},
    @{Name='relocation without pending target';Edit={param($s) $s.Entries[0].Phase='RelocatingReady'}},
    @{Name='plan file target collision';Edit={param($s) $s.Entries[0].Target=Join-Path $schemaStore 'state.json'}},
    @{Name='unrelated restore stage';Edit={param($s) $s.Entries[0] | Add-Member RestoreStages @(Join-Path $fixture 'UnrelatedStage')}},
    @{Name='source overlaps plan store';Edit={param($s) $s.Entries[0].Source=Join-Path $schemaStore 'inside'}},
    @{Name='pending target overlaps source';Edit={param($s) $s.Entries[0].Phase='RelocatingReady';$s.Entries[0] | Add-Member PendingTarget (Join-Path $s.Entries[0].Source 'pending')}},
    @{Name='unrecorded journal stage';Edit={param($s) $s.Entries[0].Phase='Restoring';$s.Entries[0] | Add-Member RestoreJournal ([pscustomobject]@{Stage=($s.Entries[0].Source+'.env-anchor-restore-'+('a'*32));ConflictBackup='';Step='Prepared'})}},
    @{Name='journal inconsistent with phase';Edit={param($s) $stage=$s.Entries[0].Source+'.env-anchor-restore-'+('a'*32);$s.Entries[0] | Add-Member RestoreStages @($stage);$s.Entries[0] | Add-Member RestoreJournal ([pscustomobject]@{Stage=$stage;ConflictBackup='';Step='Prepared'})}},
    @{Name='unknown journal step';Edit={param($s) $stage=$s.Entries[0].Source+'.env-anchor-restore-'+('a'*32);$s.Entries[0].Phase='Restoring';$s.Entries[0] | Add-Member RestoreStages @($stage);$s.Entries[0] | Add-Member RestoreJournal ([pscustomobject]@{Stage=$stage;ConflictBackup='';Step='Unknown'})}}
)
foreach($case in $schemaCases) {
    $candidate=Clone-TestState $schemaBase
    & $case.Edit $candidate
    Expect-Rejection {Assert-StateSchema $candidate $schemaStore} ('schema rejects '+$case.Name)
}
$foreign=Clone-TestState $schemaBase; $foreign.User='S-1-5-18'
Assert-StateSchema $foreign $schemaStore -AllowForeignUser
Check $true 'inspection may validate a structurally valid foreign-user plan'
$foreign.User='S-1-999999999999999999999-1'
Expect-Rejection {Assert-StateSchema $foreign $schemaStore -AllowForeignUser} 'inspection still rejects structurally invalid SID'

$duplicateStore=Join-Path $fixture 'DuplicatePlan'
$duplicateSource=Join-Path $fixture 'DuplicateSource'
New-Item -ItemType Directory -Path $duplicateSource | Out-Null
Set-Content -LiteralPath (Join-Path $duplicateSource 'data.txt') -Value 'untouched duplicate input'
$duplicateJobs=@([pscustomobject]@{Name='one';Source=$duplicateSource;Target=(Join-Path $fixture 'DuplicateTargetOne')},[pscustomobject]@{Name='two';Source=$duplicateSource.ToUpperInvariant();Target=(Join-Path $fixture 'DuplicateTargetTwo')})
Expect-Rejection {Invoke-PlanOperation Apply $duplicateStore (ConvertTo-Json -InputObject $duplicateJobs)} 'Apply rejects case-insensitive duplicate sources in entire batch'
Check (-not (Test-Path -LiteralPath $duplicateStore) -and -not (Test-Path -LiteralPath $duplicateJobs[0].Target) -and (Get-Content -LiteralPath (Join-Path $duplicateSource 'data.txt')) -eq 'untouched duplicate input') 'duplicate batch makes no plan or file changes'
$undoPeer=(Read-State $regStore).Entries[1]
Expect-Rejection {Invoke-PlanOperation Undo $regStore '[]'} 'public Undo rejects empty selection'
$unknownJobs=@([pscustomobject]@{Source=$undoPeer.Source},[pscustomobject]@{Source=(Join-Path $fixture 'UnknownUndoSource')})
Expect-Rejection {Invoke-PlanOperation Undo $regStore (ConvertTo-Json -InputObject $unknownJobs)} 'public Undo rejects unknown source after valid selection'
Check (Test-OurLink $undoPeer.Source $undoPeer.Target) 'invalid Undo selection leaves valid entry connected'

# Schema and filesystem preflight must run before changing the first entry.
$validationStore=Join-Path $fixture 'ValidationPlan'
$validationJobs=@()
foreach($name in @('First','Second')) {
    $testInput=Join-Path $fixture ('Validation'+$name)
    New-Item -ItemType Directory -Path $testInput | Out-Null
    Set-Content -LiteralPath (Join-Path $testInput 'data.txt') -Value $name
    $validationJobs+= [pscustomobject]@{Name=$name;Source=$testInput;Target=(Join-Path $fixture ('ValidationTarget'+$name))}
}
Invoke-PlanOperation Apply $validationStore (ConvertTo-Json -InputObject $validationJobs)
$validationState=Read-State $validationStore
[IO.Directory]::Delete($validationJobs[0].Source)
New-Item -ItemType Directory -Path $validationJobs[0].Source | Out-Null
Set-Content -LiteralPath (Join-Path $validationJobs[0].Source 'data.txt') -Value 'first reset baseline'
$invalidPlan=Clone-TestState $validationState; $invalidPlan.Entries[1].Phase='UnknownPhase'
Save-State $invalidPlan $validationStore
foreach($op in @('Resume','Undo','Apply')) {
    Expect-Rejection {Invoke-PlanOperation $op $validationStore (ConvertTo-Json -InputObject $validationJobs)} ('whole plan rejects invalid later schema before '+$op)
}
Check ((Get-Content -LiteralPath (Join-Path $validationJobs[0].Source 'data.txt')) -eq 'first reset baseline' -and @(Get-ChildItem -LiteralPath $fixture -Filter 'ValidationFirst.env-anchor-backup-*').Count -eq 1) 'later schema failure preserves first source and backup count'
Save-State $validationState $validationStore
Move-Item -LiteralPath $validationJobs[1].Target -Destination ($validationJobs[1].Target+'-offline')
Expect-Rejection {Invoke-PlanOperation Apply $validationStore (ConvertTo-Json -InputObject $validationJobs)} 'Apply preflight rejects unavailable later existing target'
Expect-Rejection {Invoke-PlanOperation Resume $validationStore} 'Resume preflight rejects unavailable later target'
Check ((Get-Content -LiteralPath (Join-Path $validationJobs[0].Source 'data.txt')) -eq 'first reset baseline') 'unavailable later target leaves earlier reset baseline untouched'
Move-Item -LiteralPath ($validationJobs[1].Target+'-offline') -Destination $validationJobs[1].Target
Resume-State (Read-State $validationStore) $validationStore
Move-Item -LiteralPath $validationJobs[1].Target -Destination ($validationJobs[1].Target+'-offline')
Expect-Rejection {Invoke-PlanOperation Undo $validationStore (ConvertTo-Json -InputObject $validationJobs)} 'Undo preflight rejects unavailable later target before first unlink'
Check (Test-OurLink $validationJobs[0].Source $validationJobs[0].Target) 'unavailable later Undo target preserves earlier junction'
Move-Item -LiteralPath ($validationJobs[1].Target+'-offline') -Destination $validationJobs[1].Target
$validationState=Read-State $validationStore
$emptyHistory=Join-Path $fixture 'EmptyRetainedHistory'
New-Item -ItemType Directory -Path $emptyHistory | Out-Null
$validationState.Entries[1] | Add-Member PreviousTargets @($emptyHistory)
Save-State $validationState $validationStore
$historyJobs=@([pscustomobject]@{Source=$validationJobs[0].Source;Target=(Join-Path $fixture 'WouldRelocateFirst');Name='first'},[pscustomobject]@{Source=$validationJobs[1].Source;Target=$emptyHistory;Name='second'})
Expect-Rejection {Invoke-PlanOperation Apply $validationStore (ConvertTo-Json -InputObject $historyJobs)} 'Apply refuses reserved empty history target in later request'
Check (-not (Test-Path -LiteralPath $historyJobs[0].Target) -and (Test-OurLink $validationJobs[0].Source $validationJobs[0].Target)) 'later history collision prevents earlier relocation'
$historyJobs[1].Target=Join-Path $validationStore 'state.json.tmp'
Expect-Rejection {Invoke-PlanOperation Apply $validationStore (ConvertTo-Json -InputObject $historyJobs)} 'Apply refuses reserved unused plan-file target in later request'
Check (-not (Test-Path -LiteralPath $historyJobs[0].Target) -and -not (Test-Path -LiteralPath $historyJobs[1].Target)) 'later reserved plan-file collision creates no data directories'

# A Ready entry can become stale while its first connection is interrupted.
$validationState.Entries[1].Phase='Ready';Save-State $validationState $validationStore
[IO.Directory]::Delete($validationJobs[1].Source)
New-Item -ItemType Directory -Path $validationJobs[1].Source | Out-Null
Set-Content -LiteralPath (Join-Path $validationJobs[1].Source 'data.txt') -Value 'second changed after initial copy'
Expect-Rejection {Invoke-PlanOperation Apply $validationStore (ConvertTo-Json -InputObject $validationJobs)} 'Apply rejects stale later Ready source before first mutation'
Check (Test-OurLink $validationJobs[0].Source $validationJobs[0].Target) 'stale later Ready entry preserves earlier connection'

$directorySource=Join-Path $fixture 'DirectoryComparisonSource'
$directoryTarget=Join-Path $fixture 'DirectoryComparisonTarget'
New-Item -ItemType Directory -Path $directorySource,$directoryTarget,(Join-Path $directoryTarget 'extra-empty') | Out-Null
Expect-Rejection {Assert-CopyMatches $directorySource $directoryTarget} 'copy comparison detects extra empty directory'
New-Item -ItemType Directory -Path (Join-Path $directorySource 'different-empty') | Out-Null
Expect-Rejection {Assert-CopyMatches $directorySource $directoryTarget} 'copy comparison detects different empty directories with equal count'

# Legacy Restoring without a journal also preserves newly created Source data.
$restoreStore=Join-Path $fixture 'LegacyRestorePlan'
$restoreSource=Join-Path $fixture 'LegacyRestoreSource'
$restoreTarget=Join-Path $fixture 'LegacyRestoreTarget'
New-Item -ItemType Directory -Path $restoreStore,$restoreSource,$restoreTarget,(Join-Path $restoreSource 'old-only-empty'),(Join-Path $restoreTarget 'current-empty') | Out-Null
Set-Content -LiteralPath (Join-Path $restoreSource 'data.txt') -Value 'new source edit'
Set-Content -LiteralPath (Join-Path $restoreTarget 'data.txt') -Value 'authoritative target'
$restoreState=[pscustomobject]@{Version=1;User=$state.User;Entries=@([pscustomobject]@{Label='legacy';Source=$restoreSource;Target=$restoreTarget;Backups=@();Phase='Restoring'})}
Save-State $restoreState $restoreStore
Undo-State (Read-State $restoreStore) $restoreStore
$finishedRestore=Read-State $restoreStore
Check ((Get-Content -LiteralPath (Join-Path $restoreSource 'data.txt')) -eq 'authoritative target') 'legacy Restoring retry installs verified current target'
Check ((Get-Content -LiteralPath (Join-Path $finishedRestore.Entries[0].Backups[0] 'data.txt')) -eq 'new source edit') 'legacy Restoring retry backs up new source edit'
Check (-not (Test-Path -LiteralPath (Join-Path $restoreSource 'old-only-empty')) -and (Test-Path -LiteralPath (Join-Path $restoreSource 'current-empty'))) 'Restoring retry cannot merge obsolete empty directories back'

$staleStore=Join-Path $fixture 'StaleStagePlan'
$staleSource=Join-Path $fixture 'StaleStageSource'
$staleTarget=Join-Path $fixture 'StaleStageTarget'
$staleStage=$staleSource+'.env-anchor-restore-'+[Guid]::NewGuid().ToString('N')
New-Item -ItemType Directory -Path $staleStore,$staleSource,$staleTarget | Out-Null
Set-Content -LiteralPath (Join-Path $staleSource 'data.txt') -Value 'source preserved beside stale stage'
Set-Content -LiteralPath (Join-Path $staleTarget 'data.txt') -Value 'current authoritative stage data'
Copy-Verified $staleTarget $staleStage
New-Item -ItemType Directory -Path (Join-Path $staleStage 'obsolete-empty') | Out-Null
$staleState=[pscustomobject]@{Version=1;User=$state.User;Entries=@([pscustomobject]@{Label='stale stage';Source=$staleSource;Target=$staleTarget;Backups=@();Phase='Restoring';RestoreStages=@($staleStage);RestoreJournal=[pscustomobject]@{Stage=$staleStage;ConflictBackup='';Step='Prepared'}})}
Save-State $staleState $staleStore
Undo-State (Read-State $staleStore) $staleStore
$staleDone=Read-State $staleStore
Check (-not (Test-Path -LiteralPath (Join-Path $staleSource 'obsolete-empty')) -and (Get-Content -LiteralPath (Join-Path $staleSource 'data.txt')) -eq 'current authoritative stage data') 'stale Prepared stage with extra empty directory is rebuilt'
Check ((Test-Path -LiteralPath (Join-Path $staleStage 'obsolete-empty')) -and @($staleDone.Entries[0].RestoreStages).Count -eq 2) 'rejected restore stage remains retained and recorded'
Check ((Get-Content -LiteralPath (Join-Path $staleDone.Entries[0].Backups[0] 'data.txt')) -eq 'source preserved beside stale stage') 'stage rebuild preserves ordinary source in backup'

# Inject crashes at saves surrounding each irreversible filesystem transition.
$realSaveState=(Get-Command Save-State).ScriptBlock
foreach($crashStep in @('Copying','Prepared','BackedUp','InstalledBeforeSave','InstalledAfterSave')) {
    & {
        $crashStore=Join-Path $fixture ('JournalPlan'+$crashStep)
        $crashSource=Join-Path $fixture ('JournalSource'+$crashStep)
        $crashTarget=Join-Path $fixture ('JournalTarget'+$crashStep)
        New-Item -ItemType Directory -Path $crashStore,$crashSource | Out-Null
        Set-Content -LiteralPath (Join-Path $crashSource 'data.txt') -Value 'journal target data'
        $crashState=[pscustomobject]@{Version=1;User=$state.User;Entries=@()}
        Add-Entry $crashSource $crashStep $crashState $crashStore $crashTarget
        $crash=[pscustomobject]@{Fired=$false;Armed=$true}
        function Save-State($State,$Store) {
            $entry=$State.Entries[0]
            $step=''; if($entry.PSObject.Properties['RestoreJournal']){$step=$entry.RestoreJournal.Step}
            $shouldCrash=$crash.Armed -and -not $crash.Fired -and $step -and ($step -eq $crashStep -or ($step -eq 'Installed' -and $crashStep.StartsWith('Installed')))
            if($shouldCrash -and $crashStep -eq 'InstalledBeforeSave') {$crash.Fired=$true; throw 'synthetic journal interruption'}
            & $realSaveState $State $Store
            if($shouldCrash) {$crash.Fired=$true; throw 'synthetic journal interruption'}
        }
        $interrupted=$false
        try {Undo-State $crashState $crashStore} catch {$interrupted=$_.Exception.Message -eq 'synthetic journal interruption'}
        Check ($interrupted -and $crash.Fired) ('journal interruption injected at '+$crashStep)
        $crash.Armed=$false
        # Source can acquire new data after a restart, even while a prior stage exists.
        if(Test-OurLink $crashSource $crashTarget) {[IO.Directory]::Delete($crashSource)}
        if(-not (Test-Path -LiteralPath $crashSource)){New-Item -ItemType Directory -Path $crashSource | Out-Null}
        Set-Content -LiteralPath (Join-Path $crashSource 'data.txt') -Value ('post-crash source edit '+$crashStep)
        New-Item -ItemType Directory -Path (Join-Path $crashSource 'post-crash-empty') | Out-Null
        Undo-State (Read-State $crashStore) $crashStore
        $crashDone=Read-State $crashStore
        Check ($crashDone.Entries[0].Phase -eq 'Restored' -and -not ((Get-Item -LiteralPath $crashSource).Attributes -band [IO.FileAttributes]::ReparsePoint)) ('journal retry finishes ordinary Source at '+$crashStep)
        if($crashStep -eq 'InstalledAfterSave') {
            Check ((Get-Content -LiteralPath (Join-Path $crashSource 'data.txt')) -eq ('post-crash source edit '+$crashStep)) 'saved Installed step preserves subsequent edits in place'
        } else {
            $conflicts=@($crashDone.Entries[0].Backups | Where-Object {(Get-Content -LiteralPath (Join-Path $_ 'data.txt')) -eq ('post-crash source edit '+$crashStep)})
            Check ($conflicts.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $conflicts[0] 'post-crash-empty'))) ('journal retry preserves post-crash files and directories at '+$crashStep)
            Check ((Get-Content -LiteralPath (Join-Path $crashSource 'data.txt')) -eq 'journal target data' -and -not (Test-Path -LiteralPath (Join-Path $crashSource 'post-crash-empty'))) ('journal retry installs exact verified stage at '+$crashStep)
        }
        $backupCount=@($crashDone.Entries[0].Backups).Count
        Undo-State (Read-State $crashStore) $crashStore
        Check (@((Read-State $crashStore).Entries[0].Backups).Count -eq $backupCount) ('finished journal Undo is idempotent at '+$crashStep)
    }
}
function Expect-PathRejection($Action,$Message) {
    $didReject=$false
    try {& $Action} catch {$didReject=$_.Exception.Message -like '*执行路径包含*' -or $_.Exception.Message -like '*不是普通文件*'}
    Check $didReject $Message
}
# Leaf metadata does not reveal a junction in any parent component.
$ancestorOutside=Join-Path $fixture 'AncestorOutside'
$ancestorAlias=Join-Path $fixture 'AncestorAlias'
$ancestorStore=Join-Path $fixture 'AncestorPlan'
$ancestorTarget=Join-Path $fixture 'AncestorTarget'
New-Item -ItemType Directory -Path $ancestorOutside,$ancestorStore,$ancestorTarget,(Join-Path $ancestorOutside 'Source'),(Join-Path $ancestorOutside 'Plan') | Out-Null
Set-Content -LiteralPath (Join-Path $ancestorOutside 'Source\data.txt') -Value 'outside ancestor sentinel'
Set-Content -LiteralPath (Join-Path $ancestorTarget 'data.txt') -Value 'authoritative ancestor target'
New-Item -ItemType Junction -Path $ancestorAlias -Target $ancestorOutside | Out-Null
$ancestorSource=Join-Path $ancestorAlias 'Source'
$ancestorState=[pscustomobject]@{Version=1;User=$state.User;Entries=@([pscustomobject]@{Label='ancestor';Source=$ancestorSource;Target=$ancestorTarget;Backups=@();Phase='Linked'})}
Expect-PathRejection {Assert-PlainTree $ancestorSource} 'plain tree rejects a linked Source ancestor'
Expect-PathRejection {Copy-Verified $ancestorSource (Join-Path $fixture 'AncestorCopy')} 'copy rejects linked Source ancestor before writing target'
Expect-PathRejection {Resume-State $ancestorState $ancestorStore} 'login Core Resume rejects linked Source ancestor'
Expect-PathRejection {Undo-State $ancestorState $ancestorStore} 'Core Undo rejects linked Source ancestor'
Check ((Get-Content -LiteralPath (Join-Path $ancestorOutside 'Source\data.txt')) -eq 'outside ancestor sentinel' -and @(Get-ChildItem -LiteralPath $ancestorOutside -Filter 'Source.env-anchor-backup-*').Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $fixture 'AncestorCopy'))) 'linked Source ancestor cannot redirect backups or data copies'
Expect-PathRejection {Copy-Verified $ancestorTarget (Join-Path $ancestorAlias 'NewTarget')} 'copy rejects linked destination ancestor'

$outsidePlan=Join-Path $ancestorOutside 'Plan'
$aliasPlan=Join-Path $ancestorAlias 'Plan'
$emptyAncestorState=[pscustomobject]@{Version=1;User=$state.User;Entries=@()}
Save-State $emptyAncestorState $outsidePlan
$planSentinelHash=Get-ContentHash (Join-Path $outsidePlan 'state.json')
Expect-PathRejection {Save-State $emptyAncestorState $aliasPlan} 'Save-State rejects linked Store ancestor before writing'
Expect-PathRejection {Read-State $aliasPlan} 'Read-State rejects linked Store ancestor before reading'
Expect-PathRejection {Invoke-PlanOperation Resume $aliasPlan} 'public operation rejects linked Store ancestor before lock creation'
Check ((Get-ContentHash (Join-Path $outsidePlan 'state.json')) -eq $planSentinelHash -and -not (Test-Path -LiteralPath (Join-Path $outsidePlan '.operation.lock')) -and -not (Test-Path -LiteralPath (Join-Path $outsidePlan 'state.json.bak'))) 'linked Store ancestor preserves external state and creates no lock or backup'

# Retained backups/stages/history and pending destinations are also execution paths.
foreach($pathField in @('Backups','RestoreStages','PreviousTargets','PendingTarget')) {
    $runtimeSource=Join-Path $fixture ('RuntimeSource'+$pathField)
    $runtimeTarget=Join-Path $fixture ('RuntimeTarget'+$pathField)
    New-Item -ItemType Directory -Path $runtimeSource,$runtimeTarget | Out-Null
    $runtimeEntry=[pscustomobject]@{Label=$pathField;Source=$runtimeSource;Target=$runtimeTarget;Backups=@();Phase='Restoring'}
    $runtimeLink=Join-Path $fixture ('RuntimeLink'+$pathField)
    if($pathField -eq 'Backups') {$runtimeLink=$runtimeSource+'.env-anchor-backup-'+[Guid]::NewGuid().ToString('N');$runtimeEntry.Backups=@($runtimeLink)}
    elseif($pathField -eq 'RestoreStages') {$runtimeLink=$runtimeSource+'.env-anchor-restore-'+[Guid]::NewGuid().ToString('N');$runtimeEntry | Add-Member RestoreStages @($runtimeLink)}
    elseif($pathField -eq 'PreviousTargets') {$runtimeEntry | Add-Member PreviousTargets @($runtimeLink)}
    else {$runtimeEntry.Phase='RelocatingReady';$runtimeEntry | Add-Member PendingTarget $runtimeLink}
    New-Item -ItemType Junction -Path $runtimeLink -Target $ancestorOutside | Out-Null
    $runtimeState=[pscustomobject]@{Version=1;User=$state.User;Entries=@($runtimeEntry)}
    Expect-PathRejection {Undo-State $runtimeState $ancestorStore} ('execution rejects linked '+$pathField+' path before moving Source')
    Check ((Test-Path -LiteralPath $runtimeSource) -and @(Get-ChildItem -LiteralPath $runtimeSource -Force).Count -eq 0) ('linked '+$pathField+' rejection leaves Source untouched')
    [IO.Directory]::Delete($runtimeLink)
}

# Simulate a parent being replaced after Apply has copied/preflighted the source.
$realCopyVerified=(Get-Command Copy-Verified).ScriptBlock
& {
    $swapParent=Join-Path $fixture 'ApplySwapParent'
    $swapHeld=Join-Path $fixture 'ApplySwapOriginalHeld'
    $swapOutside=Join-Path $fixture 'ApplySwapOutside'
    $swapStore=Join-Path $fixture 'ApplySwapPlan'
    $swapSource=Join-Path $swapParent 'Source'
    $swapTarget=Join-Path $fixture 'ApplySwapTarget'
    New-Item -ItemType Directory -Path $swapSource,(Join-Path $swapOutside 'Source') | Out-Null
    Set-Content -LiteralPath (Join-Path $swapSource 'data.txt') -Value 'original preflight data'
    Set-Content -LiteralPath (Join-Path $swapOutside 'Source\data.txt') -Value 'post-preflight outside sentinel'
    $swap=[pscustomobject]@{Triggered=$false}
    function Copy-Verified($Source,$Target) {
        & $realCopyVerified $Source $Target
        if(-not $swap.Triggered -and $Source -eq $swapSource) {
            $swap.Triggered=$true
            [IO.Directory]::Move($swapParent,$swapHeld)
            New-Item -ItemType Junction -Path $swapParent -Target $swapOutside | Out-Null
        }
    }
    $swapJob=@([pscustomobject]@{Name='swap';Source=$swapSource;Target=$swapTarget})
    Expect-PathRejection {Invoke-PlanOperation Apply $swapStore (ConvertTo-Json -InputObject $swapJob)} 'Apply rechecks Source ancestors after validated copy before connection'
    Check ($swap.Triggered -and (Get-Content -LiteralPath (Join-Path $swapOutside 'Source\data.txt')) -eq 'post-preflight outside sentinel' -and @(Get-ChildItem -LiteralPath $swapOutside -Filter 'Source.env-anchor-backup-*').Count -eq 0) 'post-preflight parent swap cannot back up or replace outside Source'
    Check ((Get-Content -LiteralPath (Join-Path $swapHeld 'Source\data.txt')) -eq 'original preflight data' -and (Get-Content -LiteralPath (Join-Path $swapTarget 'data.txt')) -eq 'original preflight data') 'rejected parent swap retains original and verified target'
    [IO.Directory]::Delete($swapParent)
}
$realResumeEntry=(Get-Command Assert-ResumeEntry).ScriptBlock
& {
    $swapParent=Join-Path $fixture 'ResumeSwapParent'
    $swapHeld=Join-Path $fixture 'ResumeSwapOriginalHeld'
    $swapOutside=Join-Path $fixture 'ResumeSwapOutside'
    $swapStore=Join-Path $fixture 'ResumeSwapPlan'
    $swapSource=Join-Path $swapParent 'Source'
    $swapTarget=Join-Path $fixture 'ResumeSwapTarget'
    New-Item -ItemType Directory -Path $swapParent,$swapStore,$swapTarget,(Join-Path $swapOutside 'Source') | Out-Null
    Set-Content -LiteralPath (Join-Path $swapTarget 'data.txt') -Value 'resume persistent target'
    Set-Content -LiteralPath (Join-Path $swapOutside 'Source\data.txt') -Value 'resume outside sentinel'
    $swapState=[pscustomobject]@{Version=1;User=$state.User;Entries=@([pscustomobject]@{Label='resume swap';Source=$swapSource;Target=$swapTarget;Backups=@();Phase='Linked'})}
    Save-State $swapState $swapStore
    $swap=[pscustomobject]@{Triggered=$false}
    function Assert-ResumeEntry($Entry) {
        & $realResumeEntry $Entry
        if(-not $swap.Triggered) {
            $swap.Triggered=$true
            [IO.Directory]::Move($swapParent,$swapHeld)
            New-Item -ItemType Junction -Path $swapParent -Target $swapOutside | Out-Null
        }
    }
    Expect-PathRejection {Resume-State $swapState $swapStore} 'Resume rechecks Source ancestors after whole-plan preflight'
    Check ($swap.Triggered -and (Get-Content -LiteralPath (Join-Path $swapOutside 'Source\data.txt')) -eq 'resume outside sentinel' -and @(Get-ChildItem -LiteralPath $swapOutside -Filter 'Source.env-anchor-backup-*').Count -eq 0) 'login Resume parent swap leaves outside data untouched'
    [IO.Directory]::Delete($swapParent)
}
[IO.Directory]::Delete($ancestorAlias)
Write-Output "Core checks passed: $($checkCount.Passed)"
Write-Output "Isolated fixture retained: $fixture"
