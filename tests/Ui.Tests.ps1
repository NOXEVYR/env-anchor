# Executed inside the actual UI script or embedded executable, on synthetic paths only.
$uiChecks=New-Object Collections.Generic.List[string]
function Ui-Check($value,$message){if(-not $value){throw ('UI FAIL: '+$message+' | '+$status.Text)};$uiChecks.Add('PASS: '+$message)}
function Pump-UiTask {
    $deadline=[DateTime]::Now.AddSeconds(60)
    while($script:busy -and [DateTime]::Now -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 15}
    Ui-Check (-not $script:busy) 'background task completes with responsive message pump'
    Ui-Check ($null -eq $script:worker) 'background worker disposed after completion'
}
$uiFixture=Join-Path $env:TEMP ('env-anchor-ui8-'+[Guid]::NewGuid().ToString('N'))
$inputA=Join-Path $uiFixture 'InputA';$inputB=Join-Path $uiFixture 'InputB';$inputC=Join-Path $uiFixture 'InputC'
$uiStore=Join-Path $uiFixture 'Plan';$uiTarget=Join-Path $uiFixture 'DataA'
New-Item -ItemType Directory -Path $inputA,$inputB,$inputC | Out-Null
Set-Content -LiteralPath (Join-Path $inputA 'setting.txt') -Value 'synthetic settings'
Set-Content -LiteralPath (Join-Path $inputB 'draft.txt') -Value 'draft remains'
$script:choices=New-Object Collections.ArrayList
foreach($pair in @(@('桌面文件',$inputA),@('软件配置',$inputB),@('项目资源',$inputC))){[void]$script:choices.Add((New-Choice $pair[0] $pair[1]))}
$script:choices[0].Target=$uiTarget;$script:choices[1].Target=Join-Path $uiFixture 'DraftDestination';$script:choices[1].Edited=$true
$form.ShowInTaskbar=$false;$form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-32000,-32000)
$form.Show();[Windows.Forms.Application]::DoEvents();Render-Choices
$allButton.PerformClick();Ui-Check (@($script:choices|Where-Object{$_.Checked}).Count -eq 3) 'select all updates underlying model'
$searchBox.Text='软件';Ui-Check ($list.Items.Count -eq 1) 'search filters visible rows'
Ui-Check (@($script:choices|Where-Object{$_.Checked}).Count -eq 3) 'search preserves checked hidden rows'
$noneButton.PerformClick();Ui-Check (@($script:choices|Where-Object{$_.Checked}).Count -eq 0) 'deselect all includes hidden rows'
$searchBox.Text='';$script:choices[0].Checked=$true;Render-Choices
$script:choices[0].Target='';$targetBox.Text=Join-Path $uiFixture 'PreviewOnly';Render-Choices
Ui-Check ($list.Items[0].SubItems[2].Text.StartsWith($targetBox.Text)) 'default target preview reacts to edits'
$script:choices[0].Target=$uiTarget;Render-Choices
$draftFile=Join-Path $uiFixture 'draft.envanchor.json';Save-Draft $draftFile
$script:choices.Clear();Load-Draft $draftFile
Ui-Check ($script:choices.Count -eq 3 -and $script:choices[0].Checked -and $script:choices[1].Edited) 'saved draft restores paths, checks and custom targets'
$draftBefore=$script:choices;$badDraft=Join-Path $uiFixture 'bad.envanchor.json'
'{"Kind":"EnvAnchorDraft","Version":1,"DefaultRoot":"relative","Items":[]}'|Set-Content -LiteralPath $badDraft
$draftRejected=$false;try{Load-Draft $badDraft}catch{$draftRejected=$true}
Ui-Check ($draftRejected -and [object]::ReferenceEquals($draftBefore,$script:choices)) 'invalid draft leaves existing model intact'
Set-Busy $true
foreach($control in @($newButton,$openButton,$list,$preflightButton,$targetBox,$refMaps,$importMaps,$startupButton)) {Ui-Check (-not $control.Enabled) ('busy gate: '+$control.GetType().Name)}
$form.Close();Ui-Check (-not $form.IsDisposed -and $form.Visible) 'busy close intercepted'
Set-Busy $false
$jobs=@([pscustomobject]@{Name='桌面文件';Source=$inputA;Target=$uiTarget})
$requests=ConvertTo-Json -InputObject $jobs -Compress
$script:previewRequest=@{Operation='Apply';Store=$uiStore;RequestsJson=$requests}
Start-BackgroundTask 'Get-OperationPreview' $script:previewRequest 'preview';Pump-UiTask
Ui-Check ($null -ne $script:preview -and $script:preview.CanProceed) 'background preflight result reaches review page'
Ui-Check (-not(Test-Path -LiteralPath $uiStore)) 'UI preflight creates no plan directory'
Ui-Check ($script:activePage -eq 'review' -and $executeButton.Enabled) 'execute enabled only after valid preview'
Invalidate-Preview;Ui-Check (-not $executeButton.Enabled) 'editing invalidates execution approval'
$operationArgs=@{Operation='Apply';Store=$uiStore;RequestsJson=$requests}
Start-BackgroundTask 'Invoke-PlanOperation' $operationArgs 'operation';Pump-UiTask
Ui-Check (Test-OurLink $inputA $uiTarget) 'UI operation performs synthetic migration'
Ui-Check ($script:choices.Count -eq 3) 'operation refresh preserves unexecuted draft rows'
$draft=@($script:choices|Where-Object{$_.Source -eq $inputB})[0]
Ui-Check ($draft.Target -eq (Join-Path $uiFixture 'DraftDestination') -and $draft.Edited) 'operation refresh preserves draft target edits'
Ui-Check (@($script:choices|Where-Object{$_.Checked}).Count -eq 1) 'operation refresh preserves checked scope'
$beforeStore=$script:planStore;$beforeCount=$script:choices.Count
$badPlan=Join-Path $uiFixture 'Malformed';New-Item -ItemType Directory -Path $badPlan|Out-Null
[pscustomobject]@{Version=1;User=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Entries=@([pscustomobject]@{Source=$inputC})}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $badPlan 'state.json') -Encoding UTF8
$rejected=$false;try{Open-Plan $badPlan}catch{$rejected=$true}
Ui-Check ($rejected -and $script:planStore -eq $beforeStore -and $script:choices.Count -eq $beforeCount) 'failed plan open leaves prior context and drafts intact'
foreach($page in @('workspace','references','recovery','records','help','review')){Show-Page $page;Ui-Check $pages[$page].Visible ('navigation opens '+$page)}
# Test the real shortcut implementation against a private synthetic Startup directory.
$startupFixture=Join-Path $uiFixture 'Startup';New-Item -ItemType Directory -Path $startupFixture|Out-Null
$script:Store=$uiStore;Set-ResumeShortcut $true $startupFixture
Ui-Check (Test-Path -LiteralPath (Join-Path $startupFixture 'EnvAnchor-Resume.lnk')) 'isolated resume shortcut installed'
Set-ResumeShortcut $false $startupFixture
Ui-Check (-not(Test-Path -LiteralPath (Join-Path $startupFixture 'EnvAnchor-Resume.lnk'))) 'isolated resume shortcut removed'
$logOutside=Join-Path $uiFixture 'LogOutside';$logAlias=Join-Path $uiFixture 'LogAlias'
New-Item -ItemType Directory -Path $logOutside|Out-Null
New-Item -ItemType Junction -Path $logAlias -Target $logOutside|Out-Null
Write-ResumeFailure $logAlias 'synthetic failure'
Ui-Check (-not(Test-Path -LiteralPath (Join-Path $logOutside '恢复错误.log'))) 'resume error reporting refuses a linked plan directory'
$shortcutRejected=$false;try{Set-ResumeShortcut $true $logAlias}catch{$shortcutRejected=$true}
Ui-Check ($shortcutRejected -and -not(Test-Path -LiteralPath (Join-Path $logOutside 'EnvAnchor-Resume.lnk'))) 'shortcut installation refuses a linked Startup ancestor'

# Scan and repair through separate worker runspaces, including signed-report JSON transport.
$scanRoot=Join-Path $uiFixture 'References';$nextTools=Join-Path $uiFixture 'NewTools';$oldTools=Join-Path $uiFixture 'OldTools'
New-Item -ItemType Directory -Path $scanRoot,$nextTools|Out-Null
$nextTool=Join-Path $nextTools 'tool.exe';[IO.File]::WriteAllText($nextTool,'fixture, never executed')
$scanConfig=Join-Path $scanRoot 'settings.json';[IO.File]::WriteAllText($scanConfig,(@{path=(Join-Path $oldTools 'tool.exe')}|ConvertTo-Json))
$scanArgs=@{RootsJson=(ConvertTo-Json -InputObject @($scanRoot) -Compress);MappingsJson=(ConvertTo-Json -InputObject @(@{Old=$oldTools;New=$nextTools}) -Compress)}
Start-BackgroundTask 'Get-ReferenceReport' $scanArgs 'references';Pump-UiTask
Ui-Check ($referenceList.Items.Count -eq 1 -and $script:referenceReport.Items[0].Repairable) 'reference worker renders a repairable path'
$referenceList.Items[0].Checked=$true
Ui-Check $repairButton.Enabled 'selecting a supported reference enables repair'
$repairArgs=@{ReportJson=($script:referenceReport|ConvertTo-Json -Depth 24 -Compress);SelectedJson='[0]'}
Start-BackgroundTask 'Invoke-ReferenceRepair' $repairArgs 'repair';Pump-UiTask
$repaired=Get-Content -LiteralPath $scanConfig -Raw|ConvertFrom-Json
Ui-Check ($repaired.path -eq $nextTool -and $referenceList.Items.Count -eq 0) 'reference worker repairs JSON then invalidates stale results'

$manifestFile=Join-Path $uiFixture 'recovery.json'
Start-BackgroundTask 'Export-RecoveryManifest' @{Store=$uiStore;Path=$manifestFile} 'export';Pump-UiTask
Ui-Check (Test-Path -LiteralPath $manifestFile) 'recovery manifest exports from actual migrated plan'
$recoveryStore=Join-Path $uiFixture 'RecoveryPlan';$recoverySource=Join-Path $uiFixture 'RecoveredSource'
$script:importRequest=@{Path=$manifestFile;NewStore=$recoveryStore;MappingsJson=(ConvertTo-Json -InputObject @(@{Old=$inputA;New=$recoverySource}) -Compress)}
$checkImport=@{};foreach($key in $script:importRequest.Keys){$checkImport[$key]=$script:importRequest[$key]};$checkImport.Preview=$true
Start-BackgroundTask 'Import-RecoveryManifest' $checkImport 'importPreview';Pump-UiTask
Ui-Check ($script:importPreview.CanImport -and -not(Test-Path -LiteralPath $recoveryStore)) 'recovery preview validates mapping without creating plan'
$script:dirty=$true;$script:importPrompt='';$originalConfirm=(Get-Command Confirm-Action).ScriptBlock
try{
    function Confirm-Action($message){$script:importPrompt=$message;return $false}
    $draftCount=$script:choices.Count;Request-RecoveryImport
    Ui-Check ($script:importPrompt.Contains('未保存草稿') -and $script:importPrompt.Contains('放弃')) 'import explicitly confirms loss of unsaved drafts'
    Ui-Check (-not $script:busy -and $script:choices.Count -eq $draftCount -and $script:dirty -and -not(Test-Path -LiteralPath $recoveryStore)) 'cancelled import keeps drafts and creates no plan'
}finally{Set-Item -Path Function:Confirm-Action -Value $originalConfirm}
Start-BackgroundTask 'Import-RecoveryManifest' $script:importRequest 'import';Pump-UiTask
Ui-Check ($script:planStore -eq $recoveryStore -and -not(Test-Path -LiteralPath $recoverySource)) 'import opens a new plan without connecting or modifying old plan'
Start-BackgroundTask 'Invoke-PlanOperation' @{Operation='Resume';Store=$recoveryStore;RequestsJson='[]'} 'operation';Pump-UiTask
Ui-Check (Test-OurLink $recoverySource $uiTarget) 'imported plan reconnects a remapped source'
$script:dirty=$false;New-Plan
Ui-Check (-not $script:planStore -and -not $targetBox.Text) 'new plan clears previous plan location'
$missingStoreRejected=$false;try{Request-Preview 'Apply'}catch{$missingStoreRejected=$_.Exception.Message.Contains('选择默认保存位置')}
Ui-Check ($missingStoreRejected -and -not $script:busy) 'new plan requires explicit new location'
$targetBox.Text=$uiStore;$reuseRejected=$false;try{Request-Preview 'Apply'}catch{$reuseRejected=$_.Exception.Message.Contains('已有方案')}
Ui-Check ($reuseRejected -and -not $script:busy) 'new plan cannot silently append into an existing plan'

# Public screenshots use synthetic display values and never reveal real user directories.
$script:suppressChanges=$true;$script:planStore='E:\个人环境';$targetBox.Text='E:\个人环境';$searchBox.Text='';$script:suppressChanges=$false
$script:choices=New-Object Collections.ArrayList
foreach($pair in @(@('桌面文件','Desktop'),@('文档资料','Documents'),@('软件配置','AppData\Example'),@('项目资源','Projects'))){$c=New-Choice $pair[0] ('C:\Users\Demo\'+$pair[1]) ('E:\个人环境\'+$pair[0]);$c.Checked=$true;[void]$script:choices.Add($c)}
Render-Choices;foreach($item in $list.Items){$item.SubItems[3].Text='待检查'}
$summaryLabel.Text='共 4 项   /   已勾选 4 项   /   已连接 0 项';$detailBox.Text="桌面文件 · 待检查`r`n原位置：C:\Users\Demo\Desktop`r`n保存到：E:\个人环境\桌面文件"
$status.Text='就绪。先检查路径和引用，再开始迁移。原数据与备份保留。';$logBox.Text='示例：迁移前检查 → 确认执行 → 查看结果。';$script:dirty=$false
function Save-UiPreview($name){[Windows.Forms.Application]::DoEvents();$list.Refresh();$referenceList.Refresh();$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height);try{$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $env:TEMP ('env-anchor-'+$name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}}
foreach($layout in @(@(1200,830,'preview'),@(1024,701,'preview-compact'),@(1460,960,'preview-wide'))){
    $form.ClientSize=New-Object Drawing.Size($layout[0],$layout[1]);Layout-Workspace;Show-Page 'workspace';[Windows.Forms.Application]::DoEvents()
    foreach($control in @($list,$targetBox,$detailBox,$preflightButton,$undoButton,$saveDraftButton,$loadDraftButton)){
        Ui-Check ($control.Visible -and $control.Left -ge 0 -and $control.Top -ge 0 -and $control.Right -le $control.Parent.ClientSize.Width -and $control.Bottom -le $control.Parent.ClientSize.Height) ('layout bounds '+$layout[2]+' / '+$control.GetType().Name)
    }
    Ui-Check ($list.Height -ge 100 -and $list.Bottom -lt $detailBox.Top) ('usable content list '+$layout[2]);Save-UiPreview $layout[2]
}
$form.ClientSize=New-Object Drawing.Size(1200,830);Layout-Workspace
[void]$refMaps.Rows.Add('D:\Tools','E:\Tools')
$demoReport=[pscustomobject]@{Items=@([pscustomobject]@{Kind='JSON';File='C:\Users\Demo\AppData\Example\settings.json';Original='D:\Tools\editor.exe';Proposed='E:\Tools\editor.exe';Status='可修复';Repairable=$true},[pscustomobject]@{Kind='Shortcut';File='C:\Users\Demo\Desktop\Editor.lnk';Original='D:\Tools\editor.exe';Proposed='E:\Tools\editor.exe';Status='可修复';Repairable=$true},[pscustomobject]@{Kind='Python';File='C:\Users\Demo\Projects\.venv\pyvenv.cfg';Original='D:\Python311';Proposed='';Status='需重建虚拟环境';Repairable=$false});Warnings=@('示例数据；不代表实际扫描结果。');ScannedFiles=12;Truncated=$false}
$script:referenceReport=$demoReport;Render-References $demoReport;Show-Page 'references';Save-UiPreview 'preview-references'
$demoReport.Truncated=$true;Render-References $demoReport;Ui-Check ($referenceNotes.Text.Contains('扫描未完整完成')) 'limited scans visibly report incomplete coverage'
$demoReport.Truncated=$false;Render-References $demoReport
$referenceList.Items[2].Checked=$true;Ui-Check (-not $referenceList.Items[2].Checked) 'diagnostic-only references cannot be checked for repair'
$manifestBox.Text='E:\备份\环境恢复清单.json';$newStoreBox.Text='F:\恢复方案';[void]$importMaps.Rows.Add('C:\Users\OldUser','C:\Users\Demo');[void]$importMaps.Rows.Add('E:\个人环境','F:\个人环境')
$importNotes.Text="映射示例。检查后会显示逐项结果和阻塞原因。`r`n创建新方案不会立即连接原目录。";Show-Page 'recovery';$recoveryTabs.SelectedIndex=1;Save-UiPreview 'preview-recovery'
$uiChecks|Set-Content -LiteralPath (Join-Path $env:TEMP 'env-anchor-ui-tests.txt') -Encoding UTF8
$timer.Dispose();$tips.Dispose();$form.Dispose()
Write-Output ('UI integration passed: '+$uiChecks.Count+' checks; fixture retained: '+$uiFixture)
