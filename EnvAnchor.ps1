param([ValidateSet('UI','Resume')][string]$Mode='UI', [string]$Store='E:\个人环境', [switch]$SmokeTest)
$ErrorActionPreference='Stop'
if (-not (Get-Command Save-State -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\Core.ps1" }
if (-not (Get-Command Get-OperationPreview -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\Preflight.ps1" }
if (-not (Get-Command Get-ReferenceReport -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\Environment.ps1" }

function Assert-Store {
    $script:Store = [IO.Path]::GetFullPath($script:Store).TrimEnd('\')
    Assert-PersistentPath $script:Store
}
function Assert-PersistentPath($Path) {
    $Path=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($Path)
    if ($root -notmatch '^[A-Z]:\\$' -or $Path -eq $root.TrimEnd('\')) { throw '请选择固定磁盘下的独立文件夹，不能选择磁盘根目录。' }
    if ($root.TrimEnd('\') -ieq $env:SystemDrive) {throw '请选择系统盘以外、不会还原的磁盘。'}
    $drive = New-Object IO.DriveInfo($root)
    if (-not $drive.IsReady -or $drive.DriveType -ne 'Fixed' -or $drive.DriveFormat -ne 'NTFS') { throw '保存位置需要使用已连接的 NTFS 固定磁盘。' }
    $current = $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '保存路径不能包含目录链接。' }
        }
        $current = Split-Path -Parent $current
    }
}
function Set-ResumeShortcut([bool]$Enabled, [string]$StartupDirectory='') {
    $startup = [Environment]::GetFolderPath('Startup')
    if($StartupDirectory){$startup=$StartupDirectory}
    $shortcutPath = Join-Path $startup 'EnvAnchor-Resume.lnk'
    Assert-PathAncestors $startup -IncludeLeaf
    Assert-RegularFilePath $shortcutPath
    if (-not $Enabled) {
        if (Test-Path -LiteralPath $shortcutPath) {
            $shell = New-Object -ComObject WScript.Shell
            $existing = $shell.CreateShortcut($shortcutPath)
            if ($existing.Arguments.EndsWith(('"'+$Store+'"'),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $shortcutPath }
        }
        return
    }
    $toolDir = Join-Path $Store 'Tool'
    Assert-StorePaths $Store
    Assert-PathAncestors $toolDir -IncludeLeaf
    New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
    $client=Get-Variable EnvAnchorExecutable -ValueOnly -ErrorAction SilentlyContinue
    if ($client) {
        $destination=Join-Path $toolDir 'EnvAnchor.exe'
        Assert-RegularFilePath $destination
        if ($client -ine $destination) {Copy-Item -LiteralPath $client -Destination $destination -Force}
    } else { foreach ($name in @('Core.ps1','Preflight.ps1','Environment.ps1','EnvAnchor.ps1','Ui.cs','Worker.cs','启动工具.cmd')) {
        $src = Join-Path $PSScriptRoot $name
        $dst = Join-Path $toolDir $name
        Assert-RegularFilePath $dst
        if ($src -ine $dst) { Copy-Item -LiteralPath $src -Destination $dst -Force }
    } }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    if ($client) {
        $shortcut.TargetPath=$destination
        $shortcut.Arguments='--resume --store "'+$Store+'"'
    } else {
        $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $toolDir 'EnvAnchor.ps1') + '" -Mode Resume -Store "' + $Store + '"'
    }
    $shortcut.WorkingDirectory = $toolDir
    $shortcut.Save()
}
function Write-ResumeFailure($Location,$Failure) {
    # Error reporting must not follow a replaced plan directory or linked log file.
    try {
        if(Test-Path -LiteralPath $Location -PathType Container){
            Assert-StorePaths $Location
            $log=Join-Path $Location '恢复错误.log';Assert-RegularFilePath $log
            $Failure|Out-String|Add-Content -LiteralPath $log -Encoding UTF8
        }
    } catch { }
}
if ($Mode -eq 'Resume') {
    try { Assert-Store; Invoke-PlanOperation -Operation Resume -Store $Store }
    catch {
        # Do not create an empty persistence store if its drive is missing.
        Write-ResumeFailure $Store $_
        throw
    }
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if(-not ('EnvAnchorUi.RoundedButton' -as [type])){Add-Type -Path "$PSScriptRoot\Ui.cs" -ReferencedAssemblies System.Drawing,System.Windows.Forms}
if(-not ('EnvAnchorUi.OperationWorker' -as [type])){Add-Type -Path "$PSScriptRoot\Worker.cs" -ReferencedAssemblies ([System.Management.Automation.PSObject].Assembly.Location)}
[Windows.Forms.Application]::EnableVisualStyles()
$script:busy=$false; $script:worker=$null; $script:jobKind=''; $script:jobArgs=@{}
$script:planStore=''; $script:choices=New-Object Collections.ArrayList
$script:rendering=$false; $script:dirty=$false; $script:preview=$null; $script:previewRequest=$null
$script:referenceReport=$null; $script:importPreview=$null; $script:importRequest=$null
$script:activePage='workspace'; $script:sessionLog=New-Object Collections.Generic.List[string]
$script:startupDirty=$false; $script:suppressChanges=$false
$form=New-Object EnvAnchorUi.DashboardForm
$form.Text='环境锚点 · 迁移与恢复'; $form.ClientSize=New-Object Drawing.Size(1200,830)
$form.MinimumSize=New-Object Drawing.Size(1040,740); $form.StartPosition='CenterScreen'; $form.SidebarWidth=188
$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.5); $form.AutoScaleMode='None'
$form.ForeColor=[Drawing.ColorTranslator]::FromHtml('#243D44')
$clientPath=Get-Variable EnvAnchorExecutable -ValueOnly -ErrorAction SilentlyContinue
if($clientPath){$form.Icon=[Drawing.Icon]::ExtractAssociatedIcon($clientPath)}
elseif(Test-Path "$PSScriptRoot\assets\app.ico"){$form.Icon=New-Object Drawing.Icon("$PSScriptRoot\assets\app.ico")}
$tips=New-Object Windows.Forms.ToolTip; $tips.AutoPopDelay=20000
function TextControl($parent,$text,$size=10,$bold=$false,$color='#243D44'){
    $c=New-Object Windows.Forms.Label; $c.Text=$text; $c.AutoEllipsis=$true; $c.UseMnemonic=$false
    $style=[Drawing.FontStyle]::Regular; if($bold){$style=[Drawing.FontStyle]::Bold}
    $c.Font=New-Object Drawing.Font('Microsoft YaHei UI',$size,$style); $c.ForeColor=[Drawing.ColorTranslator]::FromHtml($color)
    $c.BackColor=$parent.BackColor; $parent.Controls.Add($c); return $c
}
function ButtonControl($parent,$text,$action,$primary=$false,$icon=''){
    $c=New-Object EnvAnchorUi.RoundedButton; $c.Text=$text; $c.IconKind=$icon
    $c.BackColor=[Drawing.Color]::White; $c.ForeColor=$form.ForeColor; $c.FlatAppearance.BorderSize=1
    $c.FlatAppearance.BorderColor=[Drawing.ColorTranslator]::FromHtml('#D9E4E2'); $c.FlatAppearance.MouseOverBackColor=[Drawing.ColorTranslator]::FromHtml('#E5F1ED')
    if($primary){$c.BackColor=[Drawing.ColorTranslator]::FromHtml('#167D70'); $c.ForeColor=[Drawing.Color]::White; $c.FlatAppearance.MouseOverBackColor=[Drawing.ColorTranslator]::FromHtml('#126B60'); $c.FlatAppearance.BorderSize=0}
    $c.Cursor=[Windows.Forms.Cursors]::Hand; $c.Tag=$action
    $c.Add_Click({param($sender,$eventArgs) try {& $sender.Tag} catch {Set-Status $_.Exception.Message $true}})
    $parent.Controls.Add($c); return $c
}
function InputControl($parent,$text='',$readOnly=$false,$multi=$false){
    $c=New-Object Windows.Forms.TextBox; $c.Text=$text; $c.ReadOnly=$readOnly; $c.Multiline=$multi
    $c.BorderStyle='FixedSingle'; $c.BackColor=[Drawing.ColorTranslator]::FromHtml('#FAFCFB'); $c.ForeColor=$form.ForeColor
    if($multi){$c.ScrollBars='Vertical'}; $parent.Controls.Add($c); return $c
}
function ListControl($parent,$columns,$check=$false){
    $c=New-Object EnvAnchorUi.AnchorListView; $c.View='Details'; $c.FullRowSelect=$true; $c.MultiSelect=$false; $c.HideSelection=$false
    $c.CheckBoxes=$check; $c.BorderStyle='None'; $c.ShowItemToolTips=$true
    foreach($column in $columns){[void]$c.Columns.Add($column,140)}
    $images=New-Object Windows.Forms.ImageList; $images.ImageSize=New-Object Drawing.Size(1,32); $c.SmallImageList=$images
    $parent.Controls.Add($c); return $c
}
function MappingControl($parent){
    $g=New-Object Windows.Forms.DataGridView; $g.BackgroundColor=[Drawing.Color]::White; $g.BorderStyle='FixedSingle'; $g.RowHeadersVisible=$false
    $g.AllowUserToAddRows=$true; $g.AllowUserToDeleteRows=$true; $g.AutoSizeColumnsMode='Fill'; $g.SelectionMode='CellSelect'
    $g.EnableHeadersVisualStyles=$false; $g.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.ColorTranslator]::FromHtml('#EEF4F3')
    [void]$g.Columns.Add('Old','原路径 / 原目录前缀'); [void]$g.Columns.Add('New','新路径 / 新目录前缀')
    $parent.Controls.Add($g); return $g
}
function Get-Mappings($grid){
    [void]$grid.EndEdit(); $maps=@()
    foreach($row in $grid.Rows){if($row.IsNewRow){continue}; $old=[string]$row.Cells[0].Value; $new=[string]$row.Cells[1].Value
        if(-not $old -and -not $new){continue}; if(-not $old -or -not $new){throw '每条映射都需要填写原路径和新路径。'}
        $maps+=@([pscustomobject]@{Old=$old.Trim();New=$new.Trim()})
    }; return ,$maps
}
function Pick-Folder($description){$d=New-Object Windows.Forms.FolderBrowserDialog; $d.Description=$description; try{if($d.ShowDialog($form) -eq 'OK'){return $d.SelectedPath}}finally{$d.Dispose()}; return ''}
function Pick-File($save,$filter,$name=''){
    if($save){$d=New-Object Windows.Forms.SaveFileDialog}else{$d=New-Object Windows.Forms.OpenFileDialog}
    $d.Filter=$filter; $d.FileName=$name; try{if($d.ShowDialog($form) -eq 'OK'){return $d.FileName}}finally{$d.Dispose()}; return ''
}
function Confirm-Action($message){return [Windows.Forms.MessageBox]::Show($form,$message,'环境锚点 · 确认操作','YesNo','Question') -eq 'Yes'}
function Set-Status($message,$failure=$false){
    $status.Text=$message; $status.ForeColor=$form.ForeColor; if($failure){$status.ForeColor=[Drawing.ColorTranslator]::FromHtml('#A44538')}
    $script:sessionLog.Add(('[{0:HH:mm:ss}] {1}' -f [DateTime]::Now,$message)); if($script:sessionLog.Count -gt 500){$script:sessionLog.RemoveAt(0)}
    $logBox.Text=($script:sessionLog -join "`r`n`r`n"); $tips.SetToolTip($status,$message)
}
function Invalidate-Preview {if($script:suppressChanges){return}; $script:preview=$null; $script:previewRequest=$null; $executeButton.Enabled=$false; $script:dirty=$true}
function New-Choice($name,$source,$target='',$entry=$null){return [pscustomobject]@{Name=$name;Source=$source;Target=$target;Checked=$false;Entry=$entry;Edited=$false}}
function Default-Choices {
    $all=@(); foreach($pair in @(@('桌面文件','Desktop'),@('文档','MyDocuments'),@('图片','MyPictures'))){$p=[Environment]::GetFolderPath($pair[1]); if($p -and (Test-Path -LiteralPath $p -PathType Container)){$all+=New-Choice $pair[0] $p}}
    $download=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
    if($download -and $download.PSObject.Properties['{374DE290-123F-4565-9164-39C4925E467B}']){$p=[Environment]::ExpandEnvironmentVariables($download.'{374DE290-123F-4565-9164-39C4925E467B}');if(Test-Path -LiteralPath $p -PathType Container){$all+=New-Choice '下载' $p}}
    return ,$all
}
function Actual-Target($choice){if($choice.Target){return $choice.Target}; return Get-DefaultTarget $targetBox.Text $choice.Name $choice.Source}
function Selected-Choice {if($list.SelectedItems.Count){return $list.SelectedItems[0].Tag}; return $null}
function Choice-Health($choice){if($null -ne $choice.Entry){return Get-EntryHealth $choice.Entry};if(-not(Test-Path -LiteralPath $choice.Source -PathType Container)){return '来源缺失'};return '未迁移'}
function Render-Choices {
    $selected=Selected-Choice; $selectedSource='';if($selected){$selectedSource=$selected.Source}
    $script:rendering=$true; $list.BeginUpdate(); $list.Items.Clear()
    try{foreach($c in $script:choices){
        if($searchBox.Text -and (($c.Name+' '+$c.Source+' '+$c.Target).IndexOf($searchBox.Text,[StringComparison]::OrdinalIgnoreCase) -lt 0)){continue}
        $target=''; try{$target=Actual-Target $c}catch{$target='请选择有效保存位置'}
        $item=New-Object Windows.Forms.ListViewItem($c.Name); [void]$item.SubItems.Add($c.Source);[void]$item.SubItems.Add($target);[void]$item.SubItems.Add((Choice-Health $c))
        $item.Tag=$c; $item.Checked=$c.Checked; $item.ToolTipText="原位置：$($c.Source)`n保存到：$target"; [void]$list.Items.Add($item)
        if($c.Source -ieq $selectedSource){$item.Selected=$true}
    }}finally{$list.EndUpdate();$script:rendering=$false}
    Refresh-Counts; Refresh-Buttons; Update-Details
}
function Refresh-Counts {
    $checked=@($script:choices|Where-Object{$_.Checked}).Count; $linked=@($script:choices|Where-Object{$_.Entry -and (Choice-Health $_) -eq '已连接'}).Count
    $summaryLabel.Text=('共 {0} 项   /   已勾选 {1} 项   /   已连接 {2} 项' -f $script:choices.Count,$checked,$linked)
    $referenceScope.Text=('扫描范围：迁移清单中勾选的 {0} 个目录（已迁移项目扫描实际数据目录）' -f $checked)
    if($script:planStore){$planLabel.Text='当前方案  '+$script:planStore; $currentPlanBox.Text=$script:planStore}else{$planLabel.Text='新方案 · 执行迁移时在默认保存位置建立'; $currentPlanBox.Text='尚未打开或建立方案'}
    $tips.SetToolTip($planLabel,$planLabel.Text)
}
function Update-Details {
    $c=Selected-Choice; if(-not $c){$detailBox.Text='选择一项查看完整路径、连接状态和保留的备份。'; return}
    $backup='';if($c.Entry -and $c.Entry.Backups.Count){$backup="`r`n保留备份："+($c.Entry.Backups -join '；')}
    $detailBox.Text="$($c.Name) · $(Choice-Health $c)`r`n原位置：$($c.Source)`r`n保存到：$(Actual-Target $c)$backup"
}
function Refresh-Buttons {
    if($script:busy){return}; $hasPlan=[bool]$script:planStore; $hasChecked=@($script:choices|Where-Object{$_.Checked}).Count -gt 0; $selected=Selected-Choice
    $preflightButton.Enabled=$hasChecked; $undoButton.Enabled=$hasPlan -and $hasChecked; $resumeButton.Enabled=$hasPlan
    $editButton.Enabled=$null -ne $selected; $removeButton.Enabled=$null -ne $selected -and ($null -eq $selected.Entry -or $selected.Entry.Phase -eq 'Restored')
    $exportButton.Enabled=$hasPlan; $folderButton.Enabled=$hasPlan; $startupButton.Enabled=$hasPlan; $auto.Enabled=$hasPlan
    $executeButton.Enabled=$null -ne $script:preview -and $script:preview.CanProceed
    $importButton.Enabled=$null -ne $script:importPreview -and $script:importPreview.CanImport
    $scanButton.Enabled=$hasChecked; $repairButton.Enabled=$null -ne $script:referenceReport -and $referenceList.CheckedIndices.Count -gt 0
}
function Set-Busy($value){
    $script:busy=$value
    function Toggle-Controls($parent,$enabled){foreach($c in $parent.Controls){if($c -is [Windows.Forms.Button] -or $c -is [Windows.Forms.CheckBox] -or $c -is [Windows.Forms.ListView] -or $c -is [Windows.Forms.DataGridView] -or ($c -is [Windows.Forms.TextBox] -and -not $c.ReadOnly)){$c.Enabled=$enabled};if($c.HasChildren){Toggle-Controls $c $enabled}}}
    Toggle-Controls $form (-not $value); $progress.Visible=$value
    if(-not $value){Refresh-Buttons}
}
function Open-Plan($location,[switch]$Merge){
    $loaded=Read-State $location; $normalized=[IO.Path]::GetFullPath($location).TrimEnd('\'); $next=New-Object Collections.ArrayList
    if($Merge -and $script:planStore -ieq $normalized){foreach($c in $script:choices){[void]$next.Add($c)}}
    foreach($entry in $loaded.Entries){
        $existing=@($next|Where-Object{$_.Source -ieq $entry.Source})
        if($existing.Count){$existing[0].Entry=$entry;if(-not $existing[0].Edited){$existing[0].Target=$entry.Target}}
        else{[void]$next.Add((New-Choice $entry.Label $entry.Source $entry.Target $entry))}
    }
    # Commit UI context only after the complete model was constructed successfully.
    $script:planStore=$normalized; $script:choices=$next
    if(-not $Merge){$script:suppressChanges=$true; $targetBox.Text=$normalized; $searchBox.Text='';$script:suppressChanges=$false; $script:dirty=$false; $script:preview=$null}
    Render-Choices; Refresh-Startup
}
function New-Plan {
    if($script:dirty -and -not(Confirm-Action '当前有未执行的选择或目标修改。是否放弃这些草稿并新建方案？已有文件与方案不受影响。')){return}
    $script:planStore=''; $script:choices=New-Object Collections.ArrayList;foreach($c in (Default-Choices)){[void]$script:choices.Add($c)}
    $script:suppressChanges=$true;try{$targetBox.Text='';$searchBox.Text=''}finally{$script:suppressChanges=$false}
    $script:dirty=$false;$script:preview=$null;$script:previewRequest=$null;$script:referenceReport=$null;$script:importPreview=$null;Render-Choices;Refresh-Startup;Show-Page 'workspace';Set-Status '已进入新方案。请先选择新的默认保存位置，再添加或勾选需要迁移的内容。'
}
function Refresh-Startup {
    $script:suppressChanges=$true;$auto.Checked=$false;$loginState.Text='尚未配置登录重连'
    if($script:planStore){$p=Join-Path ([Environment]::GetFolderPath('Startup')) 'EnvAnchor-Resume.lnk';if(Test-Path -LiteralPath $p){$shell=New-Object -ComObject WScript.Shell;$shortcut=$shell.CreateShortcut($p)
        if($shortcut.Arguments.EndsWith(('"'+$script:planStore+'"'),[StringComparison]::OrdinalIgnoreCase)){$auto.Checked=$true;$loginState.Text='已安装当前方案入口 · 还原基线需由管理员确认'}else{$loginState.Text='登录入口当前关联另一方案'}
    }};$script:startupDirty=$false;$script:suppressChanges=$false
}
function Edit-Choice($choice=$null){
    $dialog=New-Object Windows.Forms.Form;$dialog.Text='项目设置';$dialog.ClientSize=New-Object Drawing.Size(670,330);$dialog.Font=$form.Font;$dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false;$dialog.BackColor=[Drawing.Color]::White
    $nLabel=TextControl $dialog '项目名称';$nLabel.SetBounds(22,21,120,24);$n=InputControl $dialog;$n.SetBounds(160,18,482,30)
    $sLabel=TextControl $dialog '原目录';$sLabel.SetBounds(22,71,120,24);$source=InputControl $dialog;$source.SetBounds(160,68,380,30)
    $sourcePick=New-Object EnvAnchorUi.RoundedButton;$sourcePick.Text='浏览';$sourcePick.SetBounds(548,66,94,34);$dialog.Controls.Add($sourcePick)
    $sourcePick.Tag=$source;$sourcePick.Add_Click({param($s,$e);$v=Pick-Folder '选择要迁移的具体目录';if($v){$s.Tag.Text=$v}})
    $tLabel=TextControl $dialog '保存到';$tLabel.SetBounds(22,121,120,24);$target=InputControl $dialog;$target.SetBounds(160,118,380,30)
    $targetPick=New-Object EnvAnchorUi.RoundedButton;$targetPick.Text='浏览';$targetPick.SetBounds(548,116,94,34);$dialog.Controls.Add($targetPick)
    $targetPick.Tag=$target;$targetPick.Add_Click({param($s,$e);$v=Pick-Folder '选择空目标目录';if($v){$s.Tag.Text=$v}})
    $hint=TextControl $dialog "保存到留空时跟随默认目录，每个项目使用独立子文件夹。`n已迁移项目只能修改目标；原路径由当前方案保护。" 9 $false '#6C8186';$hint.SetBounds(22,174,620,52)
    $ok=New-Object EnvAnchorUi.RoundedButton;$ok.Text='保存项目';$ok.DialogResult='OK';$ok.SetBounds(424,267,106,38);$dialog.Controls.Add($ok)
    $cancel=New-Object EnvAnchorUi.RoundedButton;$cancel.Text='取消';$cancel.DialogResult='Cancel';$cancel.SetBounds(538,267,104,38);$dialog.Controls.Add($cancel);$dialog.AcceptButton=$ok;$dialog.CancelButton=$cancel
    if($choice){$n.Text=$choice.Name;$source.Text=$choice.Source;$target.Text=$choice.Target;if($choice.Entry -and $choice.Entry.Phase -ne 'Restored'){$source.ReadOnly=$true;$sourcePick.Enabled=$false;$n.ReadOnly=$true}}
    try{if($dialog.ShowDialog($form) -ne 'OK'){return}; if(-not $n.Text.Trim()){throw '请输入项目名称。'}
        $path=[IO.Path]::GetFullPath($source.Text).TrimEnd('\');if(-not(Test-Path -LiteralPath $path -PathType Container)){throw '原目录不存在。'}
        $root=[IO.Path]::GetPathRoot($path).TrimEnd('\');$restricted=@($root,$env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA,(Join-Path $env:USERPROFILE 'AppData'),$env:ProgramFiles,${env:ProgramFiles(x86)})
        if($restricted -icontains $path -or $path.StartsWith($env:SystemRoot,[StringComparison]::OrdinalIgnoreCase)){throw '请选择具体文件或软件配置目录，不可选择磁盘根目录、Windows、整个用户目录或 AppData。'}
        if(@($script:choices|Where-Object{$_ -ne $choice -and $_.Source -ieq $path}).Count){throw '这个目录已经在清单中。'}
        $to=$target.Text.Trim();if($to){Assert-PersistentPath $to}
        if($choice){$choice.Name=$n.Text.Trim();$choice.Source=$path;$choice.Target=$to;$choice.Edited=$true}else{$choice=New-Choice $n.Text.Trim() $path $to;$choice.Checked=$true;$choice.Edited=$true;[void]$script:choices.Add($choice)}
        Invalidate-Preview;Render-Choices;Set-Status '项目已保存到当前草稿，尚未移动文件。'
    }finally{$dialog.Dispose()}
}
function Get-Engine { $engine=Get-Variable EnvAnchorCore -ValueOnly -ErrorAction SilentlyContinue;if($engine){return $engine};return ((@('Core.ps1','Preflight.ps1','Environment.ps1')|ForEach-Object{Get-Content -LiteralPath (Join-Path $PSScriptRoot $_) -Raw}) -join "`r`n") }
function Start-BackgroundTask($command,$arguments,$kind){
    if($script:busy){return};$script:jobArgs=$arguments;$script:jobKind=$kind
    try{$script:worker=New-Object EnvAnchorUi.OperationWorker;$script:worker.StartCommand((Get-Engine),$command,($arguments|ConvertTo-Json -Depth 24 -Compress));Set-Busy $true;$progress.Style='Marquee';Set-Status '正在后台检查和处理，窗口保持响应。';$timer.Start()}
    catch{if($script:worker){$script:worker.Dispose();$script:worker=$null};Set-Busy $false;throw}
}
function Request-Preview($operation){
    if(-not $script:planStore){
        if([string]::IsNullOrWhiteSpace($targetBox.Text)){throw '请先为新方案选择默认保存位置。'}
        if(Test-Path -LiteralPath (Join-Path $targetBox.Text 'state.json')){throw '此位置已有方案。请打开该方案继续，或为新方案选择其他独立目录。'}
    }
    $requests=@();foreach($c in $script:choices){if($c.Checked){$requests+=@([pscustomobject]@{Source=$c.Source;Target=(Actual-Target $c);Name=$c.Name})}}
    $location=$targetBox.Text;if($script:planStore){$location=$script:planStore}
    if($operation -ne 'Apply' -and -not $script:planStore){throw '请先打开已有方案。'}
    $script:preview=$null;$script:previewRequest=@{Operation=$operation;Store=$location;RequestsJson=(ConvertTo-Json -InputObject @($requests) -Depth 5 -Compress)}
    $taskArguments=@{};foreach($key in $script:previewRequest.Keys){$taskArguments[$key]=$script:previewRequest[$key]};$taskArguments.RequirePersistentStorage=$true
    Start-BackgroundTask 'Get-OperationPreview' $taskArguments 'preview'
}
function Operation-Label($operation){$labels=@{Apply='迁移';Resume='重新连接';Undo='撤销迁移'};if($labels.ContainsKey($operation)){return $labels[$operation]};return $operation}
function Render-Preview($report){
    $actions=@{Copy='迁移';Reconnect='重连';Relocate='换位置';Resume='恢复';Restore='复制回原目录';CancelCopy='终止未完成复制';AlreadyRestored='已经撤销'}
    $previewList.Items.Clear();foreach($item in $report.Items){$action=$item.Action;if($actions.ContainsKey($action)){$action=$actions[$action]};$row=New-Object Windows.Forms.ListViewItem($item.Name);[void]$row.SubItems.Add($action);[void]$row.SubItems.Add(('{0:N1} MB' -f ($item.Bytes/1MB)));[void]$row.SubItems.Add($item.Status);[void]$row.SubItems.Add($item.Target);$row.Tag=$item;$row.ToolTipText=(@($item.Errors)+@($item.Warnings)) -join "`n";[void]$previewList.Items.Add($row)}
    $scope='处理勾选项目';if($report.Operation -eq 'Resume'){$scope='重连当前方案的全部有效项目'}
    $reviewHeading.Text=('{0} · {1} 项 · 需复制 {2:N1} MB' -f $scope,@($report.Items).Count,($report.TotalBytes/1MB))
    $messages=@($report.Errors)+@($report.Warnings);$reviewNotes.Text=($messages -join "`r`n");if(-not $messages.Count){$reviewNotes.Text='预检通过。执行时仍会再次验证路径、文件内容和访问权限；原数据及备份保留。'}
    $executeButton.Enabled=$report.CanProceed;Show-Page 'review'
}
function Refresh-PlanAfterOperation {
    if(Test-Path -LiteralPath (Join-Path $script:jobArgs.Store 'state.json')){
        # Preserve all drafts, checks and custom targets when establishing the first plan too.
        $script:planStore=$script:jobArgs.Store; Open-Plan $script:planStore -Merge
    }
}
function Reference-Roots {
    $roots=@();foreach($c in $script:choices){if($c.Checked){$p=$c.Source;if($c.Entry -and $c.Entry.Phase -ne 'Restored'){$p=$c.Entry.Target};$roots+=$p}};return ,@($roots|Select-Object -Unique)
}
function Render-References($report){
    $kinds=@{Shortcut='快捷方式';VirtualEnvironment='Python 环境';Text='文本配置'}
    $referenceList.Items.Clear();$index=0;foreach($item in $report.Items){$kind=$item.Kind;if($kinds.ContainsKey($kind)){$kind=$kinds[$kind]};$row=New-Object Windows.Forms.ListViewItem($kind);[void]$row.SubItems.Add($item.Original);[void]$row.SubItems.Add($item.Proposed);[void]$row.SubItems.Add($item.Status);$row.Tag=$index;$row.ToolTipText=$item.File;[void]$referenceList.Items.Add($row);$index++}
    $incomplete='';if($report.Truncated){$incomplete='扫描未完整完成（数量、深度或访问限制），仍可能存在未检查的引用。'}
    $referenceNotes.Text=('扫描文件 {0} 个 · 识别引用 {1} 条。{2}{3}' -f $report.ScannedFiles,@($report.Items).Count,$incomplete,(@($report.Warnings)-join '；'));Refresh-Buttons
}
function Load-History {
    if(-not $script:planStore){Set-Status '请先打开方案以查看磁盘上的历史记录。';return}
    $path=Join-Path $script:planStore 'operations.log';if(Test-Path -LiteralPath $path){$logBox.Text=(Get-Content -LiteralPath $path -Tail 300) -join "`r`n"}else{$logBox.Text='当前方案尚无操作记录。'}
}
function Save-Draft([string]$Path){
    $data=[pscustomobject]@{Kind='EnvAnchorDraft';Version=1;DefaultRoot=$targetBox.Text;Items=@($script:choices|ForEach-Object{[pscustomobject]@{Name=$_.Name;Source=$_.Source;Target=$_.Target;Checked=[bool]$_.Checked}})}
    $data|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $Path -Encoding UTF8
    $script:dirty=$false;Set-Status ('草稿已保存：'+$Path)
}
function Load-Draft([string]$Path){
    if($script:planStore){throw '请先新建方案，再载入草稿。'}
    if((Get-Item -LiteralPath $Path).Length -gt 2MB){throw '草稿文件过大。'}
    $data=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json
    if($data.Kind -ne 'EnvAnchorDraft' -or $data.Version -ne 1 -or $data.Items -isnot [array] -or $data.Items.Count -gt 1000){throw '不是支持的环境清单。'}
    Assert-CanonicalPath $data.DefaultRoot '默认保存位置'
    $next=New-Object Collections.ArrayList
    foreach($item in $data.Items){
        if($item.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($item.Name) -or $item.Name.Length -gt 120 -or $item.Checked -isnot [bool]){throw '草稿包含无效项目。'}
        Assert-CanonicalPath $item.Source '原目录'
        if($item.Target){Assert-CanonicalPath $item.Target '保存到'}
        if(@($next|Where-Object{$_.Source -ieq $item.Source}).Count){throw '草稿包含重复原目录。'}
        $c=New-Choice $item.Name $item.Source $item.Target;$c.Checked=$item.Checked;$c.Edited=$true;[void]$next.Add($c)
    }
    $script:suppressChanges=$true
    try{$script:choices=$next;$targetBox.Text=$data.DefaultRoot;$searchBox.Text=''}finally{$script:suppressChanges=$false}
    $script:preview=$null;$script:previewRequest=$null;$script:dirty=$false;Render-Choices;Set-Status '草稿已载入，执行前仍需预检。'
}
function Request-RecoveryImport {
    if(-not $script:importPreview -or -not $script:importPreview.CanImport){throw '请先检查导入映射。'}
    $message='将在 '+$script:importRequest.NewStore+' 创建新方案，原方案不修改。之后仍需检查并重新连接。'
    if($script:dirty){$message+="`r`n当前有未保存草稿，继续将放弃并替换当前清单。要保留草稿，请取消并返回环境清单保存草稿。"}
    if(Confirm-Action $message){Start-BackgroundTask 'Import-RecoveryManifest' $script:importRequest 'import'}
}

# Application shell, with actual navigation and a persistent task status area.
$mark=New-Object Windows.Forms.PictureBox;$mark.SizeMode='Zoom';$mark.BackColor=[Drawing.ColorTranslator]::FromHtml('#EEF4F3')
$mark.Image=Get-Variable EnvAnchorMark -ValueOnly -ErrorAction SilentlyContinue;if(-not $mark.Image){$mark.Image=[Drawing.Image]::FromFile("$PSScriptRoot\assets\app.png")};$form.Controls.Add($mark)
$brand=TextControl $form '环境锚点' 17 $true;$brand.BackColor=$mark.BackColor
$brandSub=TextControl $form 'ENV ANCHOR' 8 $false '#708F88';$brandSub.BackColor=$mark.BackColor
$sideTag=TextControl $form "0.8 · 本地预览`n文件保留 / 引用诊断" 9 $false '#708F88';$sideTag.BackColor=$mark.BackColor
$title=TextControl $form '环境清单' 23 $true;$subtitle=TextControl $form '先整理要保留的内容，再检查路径与引用。' 10 $false '#71858A'
$planLabel=TextControl $form '' 9 $false '#57756E'
$newButton=ButtonControl $form '新方案' {New-Plan} $false 'add'
$openButton=ButtonControl $form '打开方案' {if($script:dirty -and -not(Confirm-Action '切换方案将放弃当前未执行草稿，是否继续？')){return};$p=Pick-Folder '选择包含 state.json 的方案目录';if($p){Open-Plan $p;Show-Page 'workspace';Set-Status ('已打开方案：'+$p)}} $false 'open'
$nav=@{};$pages=@{}
foreach($key in @('workspace','references','recovery','records','help','review')){$p=New-Object Windows.Forms.Panel;$p.BackColor=[Drawing.Color]::White;$p.Visible=$false;$form.Controls.Add($p);$pages[$key]=$p}
$nav.workspace=ButtonControl $form '环境清单' {Show-Page 'workspace'}
$nav.references=ButtonControl $form '引用诊断' {Show-Page 'references'}
$nav.recovery=ButtonControl $form '重连与恢复' {Show-Page 'recovery'}
$nav.records=ButtonControl $form '操作记录' {Show-Page 'records'}
$nav.help=ButtonControl $form '使用帮助' {Show-Page 'help'}
$status=TextControl $form '就绪。' 9 $false '#55706C';$status.BackColor=[Drawing.Color]::White
$taskLabel=TextControl $form '任务状态' 10 $true;$taskLabel.BackColor=[Drawing.Color]::White
$progress=New-Object Windows.Forms.ProgressBar;$progress.Visible=$false;$progress.MarqueeAnimationSpeed=30;$form.Controls.Add($progress)
$viewLogButton=ButtonControl $form '查看详情' {Show-Page 'records'}

$p=$pages.workspace
$targetLabel=TextControl $p '新项目默认保存位置' 11 $true
$targetBox=InputControl $p $Store
$browseButton=ButtonControl $p '选择位置' {$v=Pick-Folder '选择不会还原的非系统磁盘下独立空文件夹';if($v){Assert-PersistentPath $v;$targetBox.Text=$v}} $false 'folder'
$targetHint=TextControl $p '已有方案清单仍保留在上方显示的位置。修改默认位置只更新目标预览。' 9 $false '#75898D'
$addButton=ButtonControl $p '添加项目' {Edit-Choice} $false 'add'
$allButton=ButtonControl $p '全选' {foreach($c in $script:choices){$c.Checked=$true};Invalidate-Preview;Render-Choices}
$noneButton=ButtonControl $p '取消全选' {foreach($c in $script:choices){$c.Checked=$false};Invalidate-Preview;Render-Choices}
$searchBox=InputControl $p
$searchLabel=TextControl $p '筛选' 9 $false '#75898D'
$searchBox.AccessibleName='按项目名称或路径筛选'
$tips.SetToolTip($searchBox,'按项目名称或路径筛选；隐藏的已勾选项目仍包含在操作范围内。')
$summaryLabel=TextControl $p '' 9 $false '#167D70'
$list=ListControl $p @('项目','原位置','保存到','状态') $true
$detailBox=InputControl $p '' $true $true
$editButton=ButtonControl $p '编辑所选' {Edit-Choice (Selected-Choice)}
$removeButton=ButtonControl $p '移出清单' {$c=Selected-Choice;if($c -and (-not $c.Entry -or $c.Entry.Phase -eq 'Restored')){[void]$script:choices.Remove($c);Invalidate-Preview;Render-Choices;Set-Status '已移出草稿清单，没有删除文件。'}}
$defaultsButton=ButtonControl $p '勾选项跟随默认' {foreach($c in $script:choices){if($c.Checked){$c.Target='';$c.Edited=$true}};Invalidate-Preview;Render-Choices}
$preflightButton=ButtonControl $p '检查并迁移勾选项' {Request-Preview 'Apply'} $true 'arrow'
$undoButton=ButtonControl $p '撤销勾选项' {Request-Preview 'Undo'} $false 'undo'
$refreshButton=ButtonControl $p '刷新状态' {if($script:planStore){Open-Plan $script:planStore -Merge}else{Render-Choices};Set-Status '连接状态已刷新，未执行草稿保留。'}
$saveDraftButton=ButtonControl $p '保存草稿' {$path=Pick-File $true '环境清单 (*.envanchor.json)|*.envanchor.json' '环境清单.envanchor.json';if($path){Save-Draft $path}}
$loadDraftButton=ButtonControl $p '载入草稿' {$path=Pick-File $false '环境清单 (*.envanchor.json)|*.envanchor.json';if(-not $path){return};if($script:dirty -and -not(Confirm-Action '载入草稿将替换当前未执行清单，是否继续？')){return};Load-Draft $path}

$p=$pages.review
$reviewHeading=TextControl $p '预检结果' 14 $true
$reviewSub=TextControl $p '此页列出实际处理范围；预检本身不会移动文件或建立连接。' 9 $false '#72868A'
$previewList=ListControl $p @('项目','操作','复制量','检查状态','目标位置')
$reviewNotes=InputControl $p '' $true $true
$backButton=ButtonControl $p '返回修改' {Show-Page 'workspace'}
$executeButton=ButtonControl $p '确认执行' {if(-not $script:preview -or -not $script:preview.CanProceed){throw '请先完成预检。'};$message="即将$(Operation-Label $script:preview.Operation)，共 $(@($script:preview.Items).Count) 项。`n方案位置：$($script:previewRequest.Store)`n请关闭相关软件。已有备份和副本会保留。";if(Confirm-Action $message){Start-BackgroundTask 'Invoke-PlanOperation' $script:previewRequest 'operation'}} $true 'arrow'
$previewList.Add_SelectedIndexChanged({if($previewList.SelectedItems.Count){$it=$previewList.SelectedItems[0].Tag;$reviewNotes.Text="原位置：$($it.Source)`r`n目标：$($it.Target)`r`n"+((@($it.Errors)+@($it.Warnings)) -join "`r`n")}})

$p=$pages.references
$referenceScope=TextControl $p '' 10 $true
$referenceHint=TextControl $p '可选填路径映射。JSON 字符串值与快捷方式支持备份后修复；其他格式提供诊断。' 9 $false '#72868A'
$refMaps=MappingControl $p
$scanButton=ButtonControl $p '扫描所选目录引用' {$roots=Reference-Roots;if(-not $roots.Count){throw '请在环境清单勾选要扫描的目录。'};$maps=Get-Mappings $refMaps;Start-BackgroundTask 'Get-ReferenceReport' @{RootsJson=(ConvertTo-Json -InputObject $roots -Compress);MappingsJson=(ConvertTo-Json -InputObject $maps -Compress)} 'references'} $true
$repairButton=ButtonControl $p '修复勾选引用' {$indices=@($referenceList.CheckedItems|ForEach-Object{[int]$_.Tag});if(-not $indices.Count){return};if(Confirm-Action ('将修复 '+$indices.Count+' 条引用，修改前创建备份并复核文件是否发生变化。')){Start-BackgroundTask 'Invoke-ReferenceRepair' @{ReportJson=($script:referenceReport|ConvertTo-Json -Depth 24 -Compress);SelectedJson=(ConvertTo-Json -InputObject $indices -Compress)} 'repair'}}
$referenceList=ListControl $p @('类型','原引用','建议路径','诊断状态') $true
$referenceNotes=InputControl $p '扫描只覆盖勾选目录和支持的文件类型。加密凭据、服务、驱动和 Python 虚拟环境不做盲目替换。' $true $true
$referenceList.Add_ItemChecked({if(-not $script:busy){Refresh-Buttons}})
$referenceList.Add_SelectedIndexChanged({if($referenceList.SelectedItems.Count -and $script:referenceReport){$it=$script:referenceReport.Items[[int]$referenceList.SelectedItems[0].Tag];$referenceNotes.Text="文件：$($it.File)`r`n原引用：$($it.Original)`r`n建议：$($it.Proposed) · $($it.Status)"}})

$p=$pages.recovery
$recoveryTabs=New-Object Windows.Forms.TabControl;$p.Controls.Add($recoveryTabs)
$existingTab=New-Object Windows.Forms.TabPage('当前方案重连');$existingTab.BackColor=[Drawing.Color]::White;[void]$recoveryTabs.TabPages.Add($existingTab)
$importTab=New-Object Windows.Forms.TabPage('重装后导入');$importTab.BackColor=[Drawing.Color]::White;[void]$recoveryTabs.TabPages.Add($importTab)
$currentLabel=TextControl $existingTab '当前方案位置' 12 $true;$currentPlanBox=InputControl $existingTab '' $true
$recoverExplain=TextControl $existingTab "重新连接使用方案里保存的全部有效项目，不使用临时目标预览。`n目标磁盘离线时停止；原位置出现的新文件会保留为备份。" 10 $false '#637C80'
$resumeButton=ButtonControl $existingTab '检查并重新连接' {Request-Preview 'Resume'} $true 'link'
$folderButton=ButtonControl $existingTab '打开方案目录' {if($script:planStore -and (Test-Path -LiteralPath $script:planStore)){Start-Process explorer.exe -ArgumentList ('"'+$script:planStore+'"')}}
$exportButton=ButtonControl $existingTab '导出恢复清单' {$path=Pick-File $true '恢复清单 (*.json)|*.json' '环境恢复清单.json';if($path){Start-BackgroundTask 'Export-RecoveryManifest' @{Store=$script:planStore;Path=$path} 'export'}}
$exportHint=TextControl $existingTab '恢复清单不包含文件数据。请同时保留目标数据目录；重装后可重新映射用户目录和盘符。' 9 $false '#72868A'
$auto=New-Object Windows.Forms.CheckBox;$auto.Text='登录时自动重新连接';$existingTab.Controls.Add($auto)
$startupButton=ButtonControl $existingTab '保存登录设置' {if(-not $script:planStore){throw '请先打开方案。'};$state=Read-State $script:planStore;if($auto.Checked -and -not @($state.Entries|Where-Object{$_.Phase -ne 'Restored'}).Count){throw '当前方案没有需要重连的项目。'};$script:Store=$script:planStore;Set-ResumeShortcut $auto.Checked;Refresh-Startup;Set-Status '登录入口已保存。系统还原基线仍需管理员另行保存。'}
$loginState=TextControl $existingTab '' 9 $false '#72868A'
$auto.Add_CheckedChanged({if(-not $script:suppressChanges){$script:startupDirty=$true;$loginState.Text='登录选项已修改，尚未保存'}})
$manifestLabel=TextControl $importTab '恢复清单文件' 10 $true;$manifestBox=InputControl $importTab
$manifestPick=ButtonControl $importTab '选择清单' {$p=Pick-File $false '恢复清单 (*.json)|*.json';if($p){$manifestBox.Text=$p}}
$newStoreLabel=TextControl $importTab '新方案位置' 10 $true;$newStoreBox=InputControl $importTab
$newStorePick=ButtonControl $importTab '选择位置' {$p=Pick-Folder '选择非系统磁盘下独立空文件夹，导入建立新方案';if($p){$newStoreBox.Text=$p}}
$mapLabel=TextControl $importTab '旧路径 → 新路径映射（用户目录与磁盘可分别填写）' 10 $true
$importMaps=MappingControl $importTab
$importNotes=InputControl $importTab '先检查映射。导入只创建当前用户的新方案，不会立即连接、覆盖旧方案或修改原目录。' $true $true
$importCheckButton=ButtonControl $importTab '检查导入映射' {Assert-PersistentPath $newStoreBox.Text;$maps=Get-Mappings $importMaps;$script:importRequest=@{Path=$manifestBox.Text;NewStore=$newStoreBox.Text;MappingsJson=(ConvertTo-Json -InputObject $maps -Compress)};$taskArguments=@{};foreach($k in $script:importRequest.Keys){$taskArguments[$k]=$script:importRequest[$k]};$taskArguments.Preview=$true;Start-BackgroundTask 'Import-RecoveryManifest' $taskArguments 'importPreview'} $true
$importButton=ButtonControl $importTab '创建新方案' {Request-RecoveryImport}

$p=$pages.records
$logHeading=TextControl $p '本次任务与历史记录' 13 $true
$sessionButton=ButtonControl $p '本次任务' {$logBox.Text=$script:sessionLog -join "`r`n`r`n"}
$historyButton=ButtonControl $p '方案历史' {Load-History}
$copyLogButton=ButtonControl $p '复制记录' {if($logBox.Text){[Windows.Forms.Clipboard]::SetText($logBox.Text)}}
$saveLogButton=ButtonControl $p '导出记录' {$path=Pick-File $true '文本记录 (*.txt)|*.txt' '环境锚点-操作记录.txt';if($path){$logBox.Text|Set-Content -LiteralPath $path -Encoding UTF8}}
$logBox=InputControl $p '' $true $true
$helpBox=InputControl $pages.help @'
同机换盘
1. 新建或打开方案，确认方案清单位置与数据保存位置。
2. 添加具体目录，勾选项目；先检查再执行，旧路径通过目录联接继续访问。
3. 对需要改写路径的配置，在引用诊断中填入映射，先扫描再勾选修复。

系统重置 / 重装恢复
重置后原用户和路径仍在：打开原方案，检查并重新连接。
重装后身份或盘符改变：保留数据目录及提前导出的恢复清单，在“重装后导入”中映射路径，创建新方案，再检查重连。
恢复清单只记录位置和文件数量/大小，不是内容哈希，不包含你的文件，也不能代替数据备份。

引用诊断的边界
扫描选定目录，不遍历整个系统。支持的文本格式和快捷方式显示识别到的绝对路径。
自动修复仅支持 JSON 字符串值和快捷方式的目标/工作目录；修改前备份、检查文件摘要及目标存在性。
Python 虚拟环境需按依赖清单重建。注册表、PATH、服务/驱动、安装程序、加密凭据和软件授权暂不自动迁移。
未识别的二进制配置及应用内部数据库可能仍含引用，需要应用专用适配；扫描通过不能替代实际启动验证。

遇到未完成操作
不要删除原目录旁的备份或目标副本。目标离线先连接磁盘；复制未完成按提示撤销后重试；撤销重试会保留原位置内容并使用校验过的暂存副本。
操作期间不能关闭窗口。复制阶段显示阶段进度，校验阶段显示百分比，不提供强制取消。

草稿与方案
移出清单只移除未迁移草稿，不删除文件。已迁移项目需先撤销。
保存草稿可保留尚未执行的名称、路径与勾选；打开方案失败时原上下文保留。
全选包含搜索隐藏的项目，预检页会列出完整执行范围。
'@ $true $true

function Show-Page($key){
    $script:activePage=$key;foreach($k in $pages.Keys){$pages[$k].Visible=$k -eq $key}
    $labels=@{workspace=@('环境清单','整理目录与保存位置，先检查再迁移。');references=@('引用诊断','找出失效路径，按支持的格式备份并修复。');recovery=@('重连与恢复','保留原方案，建立清晰的路径与用户映射。');records=@('操作记录','查看本次结果、失败原因与方案历史。');help=@('使用帮助','了解两种迁移流程及当前支持范围。');review=@('执行前检查','核对完整处理范围，解决阻塞后再开始。')}
    $title.Text=$labels[$key][0];$subtitle.Text=$labels[$key][1]
    foreach($k in $nav.Keys){$nav[$k].BackColor=[Drawing.ColorTranslator]::FromHtml('#EEF4F3');$nav[$k].FlatAppearance.BorderSize=0;$nav[$k].ForeColor=[Drawing.ColorTranslator]::FromHtml('#617C77')}
    $active=$key;if($key -eq 'review'){$active='workspace'};$nav[$active].BackColor=[Drawing.ColorTranslator]::FromHtml('#D6EAE3');$nav[$active].ForeColor=[Drawing.ColorTranslator]::FromHtml('#126C60')
}
function Layout-Workspace {
    $form.SuspendLayout();$w=$form.ClientSize.Width;$h=$form.ClientSize.Height;$x=212;$cw=$w-236;$bodyY=120;$bodyH=$h-220
    $form.LocationCardBounds=New-Object Drawing.Rectangle($x,($bodyY-10),$cw,($bodyH+20));$form.StatusCardBounds=New-Object Drawing.Rectangle($x,($h-78),$cw,60)
    $mark.SetBounds(24,28,44,44);$brand.SetBounds(78,26,108,31);$brandSub.SetBounds(79,59,106,18);$sideTag.SetBounds(24,($h-78),150,52)
    $ny=132;foreach($k in @('workspace','references','recovery','records','help')){$nav[$k].SetBounds(16,$ny,156,46);$ny+=58}
    $title.SetBounds($x,19,($cw-280),41);$subtitle.SetBounds(($x+2),63,($cw-4),24);$planLabel.SetBounds(($x+2),88,($cw-4),20)
    $newButton.SetBounds(($x+$cw-250),24,106,35);$openButton.SetBounds(($x+$cw-134),24,134,35)
    foreach($p in $pages.Values){$p.SetBounds(($x+16),$bodyY,($cw-32),$bodyH)}
    $pw=$cw-32;$ph=$bodyH
    $targetLabel.SetBounds(0,2,250,25);$targetBox.SetBounds(0,35,($pw-128),30);$browseButton.SetBounds(($pw-116),31,116,36);$targetHint.SetBounds(0,71,$pw,23)
    $addButton.SetBounds(0,106,136,36);$allButton.SetBounds(146,106,74,36);$noneButton.SetBounds(228,106,106,36);$searchLabel.SetBounds(($pw-292),115,46,24);$searchBox.SetBounds(($pw-242),111,242,29)
    $summaryLabel.SetBounds(0,151,$pw,22);$list.SetBounds(0,179,$pw,([Math]::Max(100,$ph-365)))
    $list.Columns[0].Width=120;$list.Columns[1].Width=[int](($pw-232)/2);$list.Columns[2].Width=$pw-$list.Columns[1].Width-232;$list.Columns[3].Width=92
    $detailBox.SetBounds(0,($ph-177),($pw-156),75);$editButton.SetBounds(($pw-146),($ph-177),146,34);$removeButton.SetBounds(($pw-146),($ph-138),146,34)
    $defaultsButton.SetBounds(0,($ph-88),174,32);$saveDraftButton.SetBounds(184,($ph-88),108,32);$loadDraftButton.SetBounds(302,($ph-88),108,32)
    $preflightButton.SetBounds(0,($ph-43),198,42);$undoButton.SetBounds(210,($ph-43),150,42);$refreshButton.SetBounds(($pw-130),($ph-43),130,42)
    $reviewHeading.SetBounds(0,8,$pw,32);$reviewSub.SetBounds(0,48,$pw,25);$previewList.SetBounds(0,87,$pw,($ph-253));$reviewNotes.SetBounds(0,($ph-151),$pw,92)
    $previewList.Columns[0].Width=110;$previewList.Columns[1].Width=90;$previewList.Columns[2].Width=95;$previewList.Columns[3].Width=130;$previewList.Columns[4].Width=[Math]::Max(160,$pw-445)
    $backButton.SetBounds(0,($ph-43),140,42);$executeButton.SetBounds(($pw-174),($ph-43),174,42)
    $referenceScope.SetBounds(0,5,$pw,25);$referenceHint.SetBounds(0,39,$pw,26);$refMaps.SetBounds(0,78,$pw,106)
    $scanButton.SetBounds(0,196,190,38);$repairButton.SetBounds(202,196,170,38);$referenceList.SetBounds(0,246,$pw,([Math]::Max(100,$ph-341)));$referenceNotes.SetBounds(0,($ph-82),$pw,80)
    $referenceList.Columns[0].Width=96;$referenceList.Columns[1].Width=[int](($pw-240)/2);$referenceList.Columns[2].Width=[int](($pw-240)/2);$referenceList.Columns[3].Width=122
    $recoveryTabs.SetBounds(0,0,$pw,$ph);$tw=$pw-16;$th=$ph-34
    $currentLabel.SetBounds(18,20,400,28);$currentPlanBox.SetBounds(18,58,($tw-36),30);$recoverExplain.SetBounds(18,105,($tw-36),63)
    $resumeButton.SetBounds(18,181,190,42);$folderButton.SetBounds(220,181,146,42);$exportButton.SetBounds(378,181,166,42);$exportHint.SetBounds(18,239,($tw-36),48)
    $auto.SetBounds(18,310,270,30);$startupButton.SetBounds(320,306,168,38);$loginState.SetBounds(18,358,($tw-36),45)
    $manifestLabel.SetBounds(14,17,118,24);$manifestBox.SetBounds(140,14,($tw-278),30);$manifestPick.SetBounds(($tw-126),11,112,36)
    $newStoreLabel.SetBounds(14,66,118,24);$newStoreBox.SetBounds(140,63,($tw-278),30);$newStorePick.SetBounds(($tw-126),60,112,36)
    $mapLabel.SetBounds(14,113,($tw-28),25);$importMaps.SetBounds(14,147,($tw-28),120);$importNotes.SetBounds(14,281,($tw-28),([Math]::Max(70,$th-347)))
    $importCheckButton.SetBounds(14,($th-50),168,40);$importButton.SetBounds(194,($th-50),168,40)
    $logHeading.SetBounds(0,8,$pw,30);$sessionButton.SetBounds(0,53,108,34);$historyButton.SetBounds(118,53,108,34);$copyLogButton.SetBounds(($pw-238),53,110,34);$saveLogButton.SetBounds(($pw-118),53,118,34);$logBox.SetBounds(0,103,$pw,($ph-105));$helpBox.SetBounds(0,0,$pw,$ph)
    $taskLabel.SetBounds(($x+16),($h-67),96,23);$status.SetBounds(($x+120),($h-67),($cw-270),40);$viewLogButton.SetBounds(($x+$cw-128),($h-67),112,36);$progress.SetBounds(($x+16),($h-35),90,5)
    $form.ResumeLayout();$form.Invalidate()
}
$form.Add_Resize({Layout-Workspace})
$targetBox.Add_TextChanged({if(-not $script:suppressChanges){Invalidate-Preview;Render-Choices}})
$searchBox.Add_TextChanged({if(-not $script:suppressChanges){Render-Choices}})
$list.Add_ItemChecked({param($sender,$eventArgs);if(-not $script:rendering -and $eventArgs.Item.Tag){$eventArgs.Item.Tag.Checked=$eventArgs.Item.Checked;Invalidate-Preview;Refresh-Counts;Refresh-Buttons}})
$list.Add_SelectedIndexChanged({if(-not $script:rendering){Update-Details;Refresh-Buttons}})
$referenceList.Add_ItemCheck({param($sender,$eventArgs)
    if($eventArgs.NewValue -eq [Windows.Forms.CheckState]::Checked){
        if(-not $script:referenceReport -or -not $script:referenceReport.Items[$eventArgs.Index].Repairable){$eventArgs.NewValue=[Windows.Forms.CheckState]::Unchecked}
    }
})
$referenceList.Add_ItemChecked({Refresh-Buttons})
$list.Add_DoubleClick({try{Edit-Choice (Selected-Choice)}catch{Set-Status $_.Exception.Message $true}})
$invalidateImport={if(-not $script:busy){$script:importPreview=$null;$script:importRequest=$null;$importButton.Enabled=$false}}
$manifestBox.Add_TextChanged($invalidateImport);$newStoreBox.Add_TextChanged($invalidateImport);$importMaps.Add_CellValueChanged($invalidateImport);$importMaps.Add_RowsRemoved($invalidateImport)
$refMaps.Add_CellValueChanged({$script:referenceReport=$null;$repairButton.Enabled=$false});$refMaps.Add_RowsRemoved({$script:referenceReport=$null;$repairButton.Enabled=$false})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=150
$timer.Add_Tick({
    if(-not $script:worker){return}
    if(-not $script:worker.Completed){$status.Text=$script:worker.Progress;$percent=$script:worker.Percent;if($percent -ge 0){$progress.Style='Continuous';$progress.Value=[Math]::Min(100,$percent)}else{$progress.Style='Marquee'};return}
    $timer.Stop();$kind=$script:jobKind;$errorText=$script:worker.Finish();$json=$script:worker.ResultJson;$script:worker.Dispose();$script:worker=$null;Set-Busy $false
    try{
        if($kind -eq 'operation'){Refresh-PlanAfterOperation;$script:preview=$null;Refresh-Buttons}
        if($errorText){throw $errorText};$result=$null;if($json){$result=ConvertFrom-Json $json}
        switch($kind){
            'preview' {$script:preview=$result;Render-Preview $result;Set-Status ('检查完成：'+@($result.Errors).Count+' 个阻塞，'+@($result.Warnings).Count+' 个提醒。')}
            'operation' {Set-Status ('操作完成。方案：'+$script:planStore+'。未执行项目草稿已保留。');Show-Page 'workspace';if($script:jobArgs.Operation -eq 'Undo'){$s=Read-State $script:planStore;if(-not @($s.Entries|Where-Object{$_.Phase -ne 'Restored'}).Count){$script:Store=$script:planStore;Set-ResumeShortcut $false;Refresh-Startup}}}
            'references' {$script:referenceReport=$result;Render-References $result;Set-Status ('引用扫描完成：'+@($result.Items).Count+' 条识别结果。')}
            'repair' {$script:referenceReport=$null;$referenceList.Items.Clear();Refresh-Buttons;$failures=@($result.Errors).Count;$message=('已修复 {0} 条引用，{1} 个失败。' -f $result.Changed,$failures);$details=@($message)+@($result.Errors)+@($result.BackupPaths|ForEach-Object{'备份：'+$_});Set-Status ($details -join "`r`n") ($failures -gt 0);$referenceNotes.Text=($details -join "`r`n")+"`r`n请重新扫描后再修复。"}
            'export' {Set-Status ('恢复清单已导出：'+$script:jobArgs.Path+'。请同时保留数据目录。')}
            'importPreview' {$script:importPreview=$result;$text=@($result.Errors)+@($result.Warnings);foreach($e in $result.Entries){$text+=('原位置：'+$e.Source+' → 数据：'+$e.Target)};$importNotes.Text=$text -join "`r`n";Refresh-Buttons;Set-Status '导入检查完成，尚未创建方案。'}
            'import' {Open-Plan $script:jobArgs.NewStore;$script:importPreview=$null;Refresh-Buttons;Set-Status '新方案已创建，未连接原目录。请检查映射并执行重新连接。';$recoveryTabs.SelectedIndex=0}
        }
    }catch{Set-Status ('未完成：'+$_.Exception.Message) $true;Refresh-Buttons}
})
$form.Add_FormClosing({param($sender,$eventArgs);if($script:busy){$eventArgs.Cancel=$true;Set-Status '正在处理文件，请等待任务完成后关闭。'}elseif(-not $SmokeTest -and ($script:dirty -or $script:startupDirty)){$eventArgs.Cancel=-not(Confirm-Action '有未保存草稿或登录设置，是否仍要退出？')}})
foreach($c in (Default-Choices)){[void]$script:choices.Add($c)}
Layout-Workspace;Render-Choices;Refresh-Startup;Show-Page 'workspace'
Set-Status '就绪。先勾选内容并检查，尚未修改任何文件或登录设置。'
if(-not $SmokeTest -and (Test-Path -LiteralPath (Join-Path $Store 'state.json'))){try{Open-Plan $Store}catch{Set-Status $_.Exception.Message $true}}
if($SmokeTest){$testCode=Get-Variable EnvAnchorUITests -ValueOnly -ErrorAction SilentlyContinue;if($testCode){& ([scriptblock]::Create($testCode))}else{. "$PSScriptRoot\tests\Ui.Tests.ps1"};return}
try{[void]$form.ShowDialog()}finally{$timer.Dispose();$tips.Dispose();$form.Dispose()}
