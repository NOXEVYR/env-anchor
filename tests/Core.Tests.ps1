$ErrorActionPreference='Stop'
if (-not (Get-Command Save-State -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\..\Core.ps1" }
$fixture=Join-Path $env:TEMP ('env-anchor-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
function Check($Value,$Message) {if(-not $Value){throw "FAIL: $Message"}; Write-Output "PASS: $Message"}
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
$incomplete=[pscustomobject]@{Version=1;User=$state.User;Entries=@([pscustomobject]@{Label='incomplete';Source=$source;Target=$store;Phase='Copying';Backups=@()})}
$rejected=$false
try {Resume-State $incomplete $store} catch {$rejected=$true}
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
Write-Output "Isolated fixture retained: $fixture"
