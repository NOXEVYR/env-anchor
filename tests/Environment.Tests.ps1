$ErrorActionPreference='Stop'
if (-not (Get-Command Save-State -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\..\Core.ps1" }
if (-not (Get-Command Get-ReferenceReport -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\..\Environment.ps1" }
function Assert-EnvironmentTest($Value,[string]$Message) { if (-not $Value) { throw "FAIL: $Message" }; Write-Output "PASS: $Message" }
function JsonArray($Values) { return (ConvertTo-Json -InputObject @($Values) -Depth 100 -Compress) }
function ReportJson($Report) { return ($Report | ConvertTo-Json -Depth 100 -Compress) }
function ThrowsEnvironment($Action) { try { & $Action | Out-Null; return $false } catch { return $true } }
$fixture=Join-Path $env:TEMP ('env-anchor-environment-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$links=New-Object 'Collections.Generic.List[string]'
try {
    $root=Join-Path $fixture 'Scan'; $old=Join-Path $fixture '旧目录'; $next=Join-Path $fixture '新目录'; $specific=Join-Path $fixture 'Specific'
    foreach ($dir in @($root,$old,$next,$specific)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    $oldFile=Join-Path $old 'tool.exe'; $newFile=Join-Path $next 'tool.exe'; $deepOld=Join-Path $old 'Foo'; $deepNext=Join-Path $specific 'thing.exe'
    [IO.Directory]::CreateDirectory($deepOld)|Out-Null; [IO.File]::WriteAllText($oldFile,'old');[IO.File]::WriteAllText($newFile,'new');[IO.File]::WriteAllText($deepNext,'specific')
    $maps=@([pscustomobject]@{Old=$old;New=$next},[pscustomobject]@{Old=$deepOld;New=$specific})
    $jsonFile=Join-Path $root 'config.json'
    $original=[pscustomobject]@{path=$oldFile;nested=@([pscustomobject]@{path=(Join-Path $deepOld 'thing.exe')});boundary=(Join-Path $old 'Foobar\thing.exe');unchanged='中文设置';token=$oldFile}
    [IO.File]::WriteAllText($jsonFile,($original|ConvertTo-Json -Depth 20))
    [IO.File]::WriteAllText((Join-Path $root '.env'),('SECRET='+$oldFile));[IO.File]::WriteAllText((Join-Path $root 'credentials.json'),('{"path":"SECRET"}'))
    [IO.File]::WriteAllText((Join-Path $root 'settings.ini'),('path="'+$oldFile+'"'))
    [IO.File]::WriteAllText((Join-Path $root 'pyvenv.cfg'),('home = '+$old))
    $shell=New-Object -ComObject WScript.Shell
    $lnkFile=Join-Path $root 'app.lnk';$shortcut=$shell.CreateShortcut($lnkFile);$shortcut.TargetPath=$oldFile;$shortcut.WorkingDirectory=$old;$shortcut.Save()
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut);[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    $external=Join-Path $fixture 'External';[IO.Directory]::CreateDirectory($external)|Out-Null
    [IO.File]::WriteAllText((Join-Path $external 'outside.json'),($original|ConvertTo-Json -Depth 20))
    $link=Join-Path $root 'outside';New-Item -ItemType Junction -Path $link -Target $external|Out-Null;$links.Add($link)
    $report=Get-ReferenceReport -RootsJson (JsonArray @($root)) -MappingsJson (JsonArray $maps)
    Assert-EnvironmentTest (@($report.Items | Where-Object {$_.File -eq $jsonFile -and $_.Original -eq $original.nested[0].path -and $_.Proposed -eq $deepNext}).Count -eq 1) 'longest boundary mapping wins for decoded JSON path'
    Assert-EnvironmentTest (@($report.Items | Where-Object {$_.Original -eq $original.boundary -and $_.Proposed -eq (Join-Path $next 'Foobar\thing.exe')}).Count -eq 1) 'Foo prefix does not match Foobar'
    Assert-EnvironmentTest (@($report.Items | Where-Object {$_.File -match '(credentials|\.env$|outside)'}).Count -eq 0) 'sensitive files and external links skipped'
    Assert-EnvironmentTest (@($report.Items | Where-Object {$_.Kind -eq 'VirtualEnvironment' -and -not $_.Repairable}).Count -eq 1) 'pyvenv requires rebuild'
    Assert-EnvironmentTest (@($report.Items | Where-Object {$_.Kind -eq 'Text' -and $_.Repairable}).Count -eq 0) 'text is diagnostic only'
    $indices=@();for($i=0;$i -lt $report.Items.Count;$i++){if($report.Items[$i].Repairable){$indices+=$i}}
    $beforeHash=Get-ContentHash $jsonFile
    # The UI recreates its PowerShell runspace for each command: preserve that boundary.
    $engine=Get-Variable EnvAnchorCore -ValueOnly -ErrorAction SilentlyContinue
    if (-not $engine) { $engine=(Get-Content -LiteralPath "$PSScriptRoot\..\Core.ps1" -Raw)+"`r`n"+(Get-Content -LiteralPath "$PSScriptRoot\..\Environment.ps1" -Raw) }
    $worker=[PowerShell]::Create()
    try {
        [void]$worker.AddScript($engine).Invoke();$worker.Commands.Clear()
        [void]$worker.AddScript('param($r,$s) Invoke-ReferenceRepair -ReportJson $r -SelectedJson $s').AddArgument((ReportJson $report)).AddArgument((JsonArray $indices))
        $repair=@($worker.Invoke())[0]
        if($worker.Streams.Error.Count){throw $worker.Streams.Error[0]}
    } finally {$worker.Dispose()}
    if ($repair.Errors.Count) { Write-Output ($repair | ConvertTo-Json -Depth 10) }
    Assert-EnvironmentTest ($repair.Errors.Count -eq 0 -and $repair.Changed -eq 4 -and $repair.BackupPaths.Count -eq 2) 'JSON and shortcut repaired with one backup per file'
    $updated=ConvertFrom-Json (Read-EnvironmentText $jsonFile).Text
    Assert-EnvironmentTest ($updated.path -eq $newFile -and $updated.nested[0].path -eq $deepNext -and $updated.boundary -eq $original.boundary -and $updated.token -eq $oldFile -and $updated.unchanged -eq '中文设置') 'BOM-less UTF8 Chinese paths and other strings preserved'
    Assert-EnvironmentTest ((Get-ContentHash (@($repair.BackupPaths|Where-Object{$_ -like ($jsonFile+'*')})[0])) -eq $beforeHash) 'backup retains exact original bytes'
    $shell=New-Object -ComObject WScript.Shell;$shortcut=$shell.CreateShortcut($lnkFile)
    Assert-EnvironmentTest ($shortcut.TargetPath -eq $newFile -and $shortcut.WorkingDirectory -eq $next) 'shortcut target and working directory repaired'
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut);[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    $stale=Invoke-ReferenceRepair -ReportJson (ReportJson $report) -SelectedJson (JsonArray @($indices[0]))
    Assert-EnvironmentTest ($stale.Changed -eq 0 -and $stale.Errors.Count -gt 0) 'concurrent file change rejected'
    $tampered=ReportJson $report | ConvertFrom-Json;$tampered.Items[0].File=Join-Path $external 'outside.json'
    $rejected=Invoke-ReferenceRepair -ReportJson (ReportJson $tampered) -SelectedJson '[0]'
    Assert-EnvironmentTest ($rejected.Changed -eq 0 -and $rejected.Errors.Count -gt 0) 'tampered report and external file rejected'
    $unicodeFile=Join-Path $root 'unicode.json'
    [IO.File]::WriteAllText($unicodeFile,([pscustomobject]@{path=$oldFile;note='中文'}|ConvertTo-Json),[Text.Encoding]::Unicode)
    $unknownFile=Join-Path $root 'unknown.json';$unknownText='{"path":"C:\\Old\\file.exe","note":"caf'+[char]233+'"}'
    [IO.File]::WriteAllBytes($unknownFile,[Text.Encoding]::GetEncoding(1252).GetBytes($unknownText))
    $encodingReport=Get-ReferenceReport -RootsJson (JsonArray @($root)) -MappingsJson (JsonArray $maps)
    Assert-EnvironmentTest (@($encodingReport.Items|Where-Object{$_.File -eq $unknownFile}).Count -eq 0 -and ($encodingReport.Warnings -join ' ') -match '编码') 'unconfirmed ANSI encoding skipped without exposing content'
    $unicodeIndices=@();for($i=0;$i -lt $encodingReport.Items.Count;$i++){if($encodingReport.Items[$i].File -eq $unicodeFile){$unicodeIndices+=$i}}
    $unicodeRepair=Invoke-ReferenceRepair -ReportJson (ReportJson $encodingReport) -SelectedJson (JsonArray $unicodeIndices)
    $unicodeBytes=[IO.File]::ReadAllBytes($unicodeFile)
    Assert-EnvironmentTest ($unicodeRepair.Changed -eq 1 -and $unicodeRepair.Errors.Count -eq 0 -and $unicodeBytes[0] -eq 255 -and $unicodeBytes[1] -eq 254 -and (ConvertFrom-Json (Read-EnvironmentText $unicodeFile).Text).note -eq '中文') 'UTF16 BOM and Chinese text retained during JSON repair'
    $noMap=Get-ReferenceReport -RootsJson (JsonArray @($root))
    Assert-EnvironmentTest (@($noMap.Items | Where-Object {$_.Repairable}).Count -eq 0) 'no mapping diagnoses without offering repair'
    Assert-EnvironmentTest (@($noMap.Items | Where-Object {$_.Status -eq '原路径失效'}).Count -gt 0 -and @($noMap.Items | Where-Object {$_.Status -eq '原路径存在'}).Count -gt 0) 'unmapped references report existing and missing paths'
    $linkRootReport=Get-ReferenceReport -RootsJson (JsonArray @($link)) -MappingsJson (JsonArray $maps)
    Assert-EnvironmentTest ($linkRootReport.ScannedFiles -eq 0 -and $linkRootReport.Items.Count -eq 0) 'root directory link is never traversed'
    $limit=$script:ReferenceMaximumEntries;$script:ReferenceMaximumEntries=2
    try {$limited=Get-ReferenceReport -RootsJson (JsonArray @($root));Assert-EnvironmentTest $limited.Truncated 'scan entry budget reports truncation'}finally{$script:ReferenceMaximumEntries=$limit}
    Assert-EnvironmentTest (ThrowsEnvironment { Get-ReferenceReport -RootsJson '["relative"]' }) 'relative scan root rejected'
    $losslessRoot=Join-Path $fixture 'Lossless';[IO.Directory]::CreateDirectory($losslessRoot)|Out-Null
    $oldToken=ConvertTo-Json -InputObject $oldFile -Compress;$newToken=ConvertTo-Json -InputObject $newFile -Compress
    $number='900719925474099312345678901234567890';$decimal='0.123456789012345678901234567890'
    $tail=', "id": '+$number+', "decimal": '+$decimal+', "hugeExponent": 1e999999, "untouched": "\u4E2D\/x", "Case": 1, "case": 2, "negzero": -0.000e+00 }  '
    $duplicateText="`r`n{`t"+'"path": '+$oldToken+', "path": '+$oldToken+', "path": '+$oldToken+$tail+"`r`n"
    $duplicateExpected="`r`n{`t"+'"path": '+$newToken+', "path": '+$newToken+', "path": '+$oldToken+$tail+"`r`n"
    $arrayText=' [ '+$oldToken+', true, null, {"nested": '+$oldToken+'}, '+$number+', '+$decimal+' ]  '
    $arrayExpected=' [ '+$newToken+', true, null, {"nested": '+$newToken+'}, '+$number+', '+$decimal+' ]  '
    $rootText="`r`n "+$oldToken+" `r`n";$rootExpected="`r`n "+$newToken+" `r`n"
    $escapedOld=$oldToken.Replace('\\','\u005c')
    $cases=@(
        [pscustomobject]@{Name='duplicates';Text=$duplicateText;Expected=$duplicateExpected;Selected=2;Encoding=(New-Object Text.UTF8Encoding($false))},
        [pscustomobject]@{Name='array';Text=$arrayText;Expected=$arrayExpected;Selected=2;Encoding=(New-Object Text.UnicodeEncoding($true,$true))},
        [pscustomobject]@{Name='rootstring';Text=$rootText;Expected=$rootExpected;Selected=1;Encoding=(New-Object Text.UTF8Encoding($true))},
        [pscustomobject]@{Name='escapedpath';Text=('{"path":'+$escapedOld+'}');Expected=('{"path":'+$newToken+'}');Selected=1;Encoding=(New-Object Text.UTF32Encoding($false,$true))}
    )
    foreach($case in $cases){
        $caseFile=Join-Path $losslessRoot ($case.Name+'.json');[IO.File]::WriteAllText($caseFile,$case.Text,$case.Encoding)
        $caseReport=Get-ReferenceReport -RootsJson (JsonArray @($losslessRoot)) -MappingsJson (JsonArray $maps)
        $caseIndices=@();for($i=0;$i -lt $caseReport.Items.Count;$i++){if($caseReport.Items[$i].File -eq $caseFile -and $caseIndices.Count -lt $case.Selected){$caseIndices+=$i}}
        $caseHash=Get-ContentHash $caseFile
        $caseRepair=Invoke-ReferenceRepair -ReportJson (ReportJson $caseReport) -SelectedJson (JsonArray $caseIndices)
        Assert-EnvironmentTest ($caseIndices.Count -eq $case.Selected -and $caseRepair.Errors.Count -eq 0 -and $caseRepair.Changed -eq $case.Selected -and (Read-EnvironmentText $caseFile).Text -ceq $case.Expected) ('lossless JSON '+$case.Name+' preserves all unselected characters')
        $expectedBytes=@($case.Encoding.GetPreamble())+@($case.Encoding.GetBytes($case.Expected))
        Assert-EnvironmentTest ([Convert]::ToBase64String([IO.File]::ReadAllBytes($caseFile)) -ceq [Convert]::ToBase64String([byte[]]$expectedBytes) -and (Get-ContentHash $caseRepair.BackupPaths[0]) -eq $caseHash) ('lossless JSON '+$case.Name+' preserves encoding BOM and exact backup')
    }
    $invalidFile=Join-Path $losslessRoot 'invalid.json';[IO.File]::WriteAllText($invalidFile,('{"path":'+$oldToken+', "broken":01}'))
    $invalidReport=Get-ReferenceReport -RootsJson (JsonArray @($losslessRoot)) -MappingsJson (JsonArray $maps)
    Assert-EnvironmentTest (@($invalidReport.Items|Where-Object{$_.File -eq $invalidFile}).Count -eq 0) 'malformed JSON rejected before any repair is offered'
    [IO.Directory]::Delete($link);$links.Remove($link)|Out-Null
    $store=Join-Path $fixture 'OldStore';$source=Join-Path $fixture 'OldProfile\App';$target=Join-Path $fixture 'OldDrive\Data'
    foreach($dir in @($store,$target)){[IO.Directory]::CreateDirectory($dir)|Out-Null};[IO.File]::WriteAllText((Join-Path $target 'data.txt'),'persistent data')
    $state=[pscustomobject]@{Version=1;User=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Entries=@([pscustomobject]@{Label='中文应用';Source=$source;Target=$target;Backups=@();Phase='Linked'})}
    Save-State $state $store
    $manifestPath=Join-Path $fixture 'recovery.json';Export-RecoveryManifest $store $manifestPath|Out-Null
    $manifest=ConvertFrom-Json (Read-EnvironmentText $manifestPath -Manifest).Text
    Assert-EnvironmentTest ($manifest.Kind -eq 'EnvAnchorRecovery' -and $manifest.Entries[0].Summary.Bytes -eq 15 -and -not $manifest.Entries[0].Summary.IsContentHash) 'export provides metadata summary and no content hash claim'
    $state.Entries[0].Phase='Ready';Save-State $state $store
    Assert-EnvironmentTest (ThrowsEnvironment {Export-RecoveryManifest $store (Join-Path $fixture 'partial.json')}) 'partial plan export blocked'
    $state.Entries[0].Phase='Linked';Save-State $state $store
    $manifest.OriginalProfile=Join-Path $fixture 'OldProfile';$manifest.OriginalSID='S-1-5-21-1-2-3-4567'
    [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 20));$manifestHash=Get-ContentHash $manifestPath
    $newProfile=Join-Path $fixture 'NewProfile';$newDrive=Join-Path $fixture 'NewDrive';$newTarget=Join-Path $newDrive 'Data';$newStore=Join-Path $fixture 'NewStore'
    [IO.Directory]::CreateDirectory($newTarget)|Out-Null;[IO.File]::WriteAllText((Join-Path $newTarget 'data.txt'),'persistent data')
    $importMaps=@([pscustomobject]@{Old=$manifest.OriginalProfile;New=$newProfile},[pscustomobject]@{Old=(Join-Path $fixture 'OldDrive');New=$newDrive})
    $countBefore=@(Get-ChildItem -LiteralPath $fixture -Recurse -Force).Count
    $preview=Import-RecoveryManifest -Path $manifestPath -NewStore $newStore -MappingsJson (JsonArray $importMaps) -Preview
    Assert-EnvironmentTest ($preview.CanImport -and $preview.Entries[0].Source -eq (Join-Path $newProfile 'App') -and $preview.Entries[0].Target -eq $newTarget) 'import maps profile and target independently'
    Assert-EnvironmentTest (-not(Test-Path -LiteralPath $newStore) -and @(Get-ChildItem -LiteralPath $fixture -Recurse -Force).Count -eq $countBefore) 'preview produces zero filesystem writes'
    $blocked=Import-RecoveryManifest -Path $manifestPath -NewStore $newStore -Preview
    Assert-EnvironmentTest (-not $blocked.CanImport) 'foreign profile without source mapping blocked'
    Import-RecoveryManifest -Path $manifestPath -NewStore $newStore -MappingsJson (JsonArray $importMaps)|Out-Null
    $newState=Read-State $newStore
    $stateBytes=[IO.File]::ReadAllBytes((Join-Path $newStore 'state.json'))
    Assert-EnvironmentTest ($newState.Entries[0].Label -eq '中文应用' -and $stateBytes[0] -eq 239 -and $stateBytes[1] -eq 187 -and $stateBytes[2] -eq 191) 'UTF8 manifest imports Chinese metadata into BOM state compatible with Core'
    Assert-EnvironmentTest ($newState.User -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -and $newState.Entries[0].Phase -eq 'Linked' -and $newState.Entries[0].Backups.Count -eq 0 -and -not(Test-Path -LiteralPath $newState.Entries[0].Source)) 'import creates current SID state without connection or copied data'
    Assert-EnvironmentTest ((Get-ContentHash $manifestPath) -eq $manifestHash -and (Read-State $store).User -eq $state.User) 'old manifest and old plan unchanged'
    $repeat=Import-RecoveryManifest -Path $manifestPath -NewStore $newStore -MappingsJson (JsonArray $importMaps) -Preview
    Assert-EnvironmentTest (-not $repeat.CanImport) 'nonempty new store cannot be overwritten'
    $targetLink=Join-Path $fixture 'TargetLink';New-Item -ItemType Junction -Path $targetLink -Target $newTarget|Out-Null;$links.Add($targetLink)
    $badMaps=@([pscustomobject]@{Old=$manifest.OriginalProfile;New=$newProfile},[pscustomobject]@{Old=$target;New=$targetLink})
    $bad=Import-RecoveryManifest -Path $manifestPath -NewStore (Join-Path $fixture 'RejectedStore') -MappingsJson (JsonArray $badMaps) -Preview
    Assert-EnvironmentTest (-not $bad.CanImport) 'linked target rejected during import'
    $nestedLink=Join-Path $newTarget 'outside';New-Item -ItemType Junction -Path $nestedLink -Target $external|Out-Null;$links.Add($nestedLink)
    $bad=Import-RecoveryManifest -Path $manifestPath -NewStore (Join-Path $fixture 'RejectedStore') -MappingsJson (JsonArray $importMaps) -Preview
    Assert-EnvironmentTest (-not $bad.CanImport) 'nested target external link rejected without traversal'
    [IO.Directory]::Delete($nestedLink);$links.Remove($nestedLink)|Out-Null
    $bad=Import-RecoveryManifest -Path $manifestPath -NewStore (Join-Path $newTarget 'Plan') -MappingsJson (JsonArray $importMaps) -Preview
    Assert-EnvironmentTest (-not $bad.CanImport) 'new store nested within target rejected'
    $bad=Import-RecoveryManifest -Path $manifestPath -NewStore (Join-Path $fixture 'RejectedStore') -MappingsJson '[{"Old":"C:\\Missing","New":"C:\\Other"},{"Old":"C:\\Missing","New":"C:\\Duplicated"}]' -Preview
    Assert-EnvironmentTest (-not $bad.CanImport) 'duplicate prefix mappings rejected'
    $danger=@([pscustomobject]@{Old=$manifest.OriginalProfile;New=$env:SystemRoot},[pscustomobject]@{Old=(Join-Path $fixture 'OldDrive');New=$newDrive})
    $bad=Import-RecoveryManifest -Path $manifestPath -NewStore (Join-Path $fixture 'RejectedStore') -MappingsJson (JsonArray $danger) -Preview
    Assert-EnvironmentTest (-not $bad.CanImport) 'dangerous system source rejected'
    Write-Output 'Environment tests completed.'
} finally {
    foreach ($link in $links) { if ([IO.Directory]::Exists($link)) { [IO.Directory]::Delete($link) } }
    $resolved=[IO.Path]::GetFullPath($fixture)
    if ($resolved.StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('env-anchor-environment-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
