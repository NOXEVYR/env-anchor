param([ValidateSet('UI','Resume')][string]$Mode='UI', [string]$Store='E:\个人环境', [switch]$SmokeTest)
$ErrorActionPreference='Stop'
if (-not (Get-Command Save-State -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\Core.ps1" }

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
function Get-Plan {
    Assert-Store
    $script:planStore=$Store
    if (Test-Path -LiteralPath (Join-Path $Store 'state.json')) { return Read-State $Store }
    if ((Test-Path -LiteralPath $Store) -and @(Get-ChildItem -LiteralPath $Store -Force).Count) { throw '首次使用请选择空文件夹，避免与已有数据混用。' }
    New-Item -ItemType Directory -Path $Store -Force | Out-Null
    $state = [pscustomobject]@{Version=1; User=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value; Entries=@()}
    Save-State $state $Store
    return $state
}
function Set-ResumeShortcut([bool]$Enabled) {
    $startup = [Environment]::GetFolderPath('Startup')
    $shortcutPath = Join-Path $startup 'EnvAnchor-Resume.lnk'
    if (-not $Enabled) {
        if (Test-Path -LiteralPath $shortcutPath) {
            $shell = New-Object -ComObject WScript.Shell
            $existing = $shell.CreateShortcut($shortcutPath)
            if ($existing.Arguments.Contains($Store)) { Remove-Item -LiteralPath $shortcutPath }
        }
        return
    }
    $toolDir = Join-Path $Store 'Tool'
    New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
    $client=Get-Variable EnvAnchorExecutable -ValueOnly -ErrorAction SilentlyContinue
    if ($client) {
        $destination=Join-Path $toolDir 'EnvAnchor.exe'
        if ($client -ine $destination) {Copy-Item -LiteralPath $client -Destination $destination -Force}
    } else { foreach ($name in @('Core.ps1','EnvAnchor.ps1','启动工具.cmd')) {
        $src = Join-Path $PSScriptRoot $name
        $dst = Join-Path $toolDir $name
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
if ($Mode -eq 'Resume') {
    try { Assert-Store; $state=Read-State $Store; Resume-State $state $Store }
    catch {
        # Do not create an empty persistence store if its drive is missing.
        if (Test-Path -LiteralPath $Store -PathType Container) { $_ | Out-String | Add-Content -LiteralPath (Join-Path $Store '恢复错误.log') -Encoding UTF8 }
        throw
    }
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if(-not ('EnvAnchorUi.RoundedButton' -as [type])) {Add-Type -Path "$PSScriptRoot\Ui.cs" -ReferencedAssemblies System.Drawing,System.Windows.Forms}
[Windows.Forms.Application]::EnableVisualStyles()
$form=New-Object Windows.Forms.Form
$form.Text='环境锚点 0.2.0 · Windows 10'; $form.ClientSize=New-Object Drawing.Size(960,710)
$form.StartPosition='CenterScreen'; $form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
$form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false
function Label($Text,$X,$Y,$W,$H) {
    $c=New-Object Windows.Forms.Label; $c.Text=$Text; $c.SetBounds($X,$Y,$W,$H); $form.Controls.Add($c)
}
Label '把个人文件和软件配置保留在不还原的磁盘' 24 20 710 30
Label '默认保存目录 / 已有方案位置（可选非系统盘；请确认所选磁盘不会还原）' 24 62 900 25
$pathBox=New-Object Windows.Forms.TextBox; $pathBox.Text=$Store; $pathBox.SetBounds(24,92,600,28); $form.Controls.Add($pathBox)
$browse=New-Object EnvAnchorUi.RoundedButton; $browse.Text='浏览'; $browse.SetBounds(638,90,96,32); $form.Controls.Add($browse)
$browse.Add_Click({$dialog=New-Object Windows.Forms.FolderBrowserDialog; if($dialog.ShowDialog() -eq 'OK'){$pathBox.Text=$dialog.SelectedPath}; $dialog.Dispose()})
Label '勾选需要迁移的目录；选中一行后可单独指定目标文件夹' 24 138 900 26
$list=New-Object Windows.Forms.ListView; $list.SetBounds(24,170,912,170); $list.CheckBoxes=$true; $list.View='Details'; $list.FullRowSelect=$true; $list.MultiSelect=$false; $list.HideSelection=$false; $form.Controls.Add($list)
[void]$list.Columns.Add('目录',120); [void]$list.Columns.Add('原位置',350); [void]$list.Columns.Add('目标位置',410)
$script:choices=New-Object Collections.ArrayList
$script:planStore=''
function Add-Choice($Name,$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    if (@($script:choices | Where-Object {$_.Path -ieq $Path}).Count) { return }
    [void]$script:choices.Add([pscustomobject]@{Name=$Name;Path=$Path;Target=''})
    $item=New-Object Windows.Forms.ListViewItem($Name)
    [void]$item.SubItems.Add($Path); [void]$item.SubItems.Add('跟随默认保存目录（独立子文件夹）'); [void]$list.Items.Add($item)
}
Add-Choice '桌面文件' ([Environment]::GetFolderPath('Desktop'))
Add-Choice '文档' ([Environment]::GetFolderPath('MyDocuments'))
$downloads=(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders').'{374DE290-123F-4565-9164-39C4925E467B}'
Add-Choice '下载' ([Environment]::ExpandEnvironmentVariables($downloads))
$add=New-Object EnvAnchorUi.RoundedButton; $add.Text='添加软件配置目录…'; $add.SetBounds(24,350,205,34); $form.Controls.Add($add)
$add.Add_Click({
    $dialog=New-Object Windows.Forms.FolderBrowserDialog; $dialog.Description='选择具体软件的配置文件夹，不要选择整个 AppData 或用户目录'
    if($dialog.ShowDialog() -eq 'OK') {
        $selected=$dialog.SelectedPath.TrimEnd('\'); $profile=$env:USERPROFILE.TrimEnd('\')
        $forbidden=@($profile,"$profile\AppData",$env:APPDATA,$env:LOCALAPPDATA,"$profile\AppData\LocalLow")
        if(-not $selected.StartsWith($profile+'\',[StringComparison]::OrdinalIgnoreCase) -or $forbidden -icontains $selected) {
            [void][Windows.Forms.MessageBox]::Show('请选择当前用户目录内具体软件的配置文件夹。')
        } else { Add-Choice ('软件：'+(Split-Path $selected -Leaf)) $selected; Update-TargetPreview }
    }; $dialog.Dispose()
})
$targetButton=New-Object EnvAnchorUi.RoundedButton; $targetButton.Text='设置所选目录目标…'; $targetButton.SetBounds(245,350,205,34); $form.Controls.Add($targetButton)
$targetButton.Add_Click({
    if ($list.SelectedIndices.Count -eq 0) {[void][Windows.Forms.MessageBox]::Show('请先在列表中选中一行。'); return}
    $index=$list.SelectedIndices[0]
    $dialog=New-Object Windows.Forms.FolderBrowserDialog; $dialog.Description='选择目标磁盘上的空文件夹，可点击新建文件夹。该磁盘必须不会被还原。'
    if ($dialog.ShowDialog() -eq 'OK') {
        try {
            Assert-PersistentPath $dialog.SelectedPath
            $script:choices[$index].Target=$dialog.SelectedPath
            $list.Items[$index].SubItems[2].Text=$dialog.SelectedPath
        } catch {[void][Windows.Forms.MessageBox]::Show($_.Exception.Message)}
    }; $dialog.Dispose()
})
$defaultButton=New-Object EnvAnchorUi.RoundedButton; $defaultButton.Text='所选项跟随默认'; $defaultButton.SetBounds(466,350,170,34); $form.Controls.Add($defaultButton)
$defaultButton.Add_Click({if($list.SelectedIndices.Count){$index=$list.SelectedIndices[0]; $script:choices[$index].Target=''; Update-TargetPreview}})
$allButton=New-Object EnvAnchorUi.RoundedButton; $allButton.Text='全选'; $form.Controls.Add($allButton)
$noneButton=New-Object EnvAnchorUi.RoundedButton; $noneButton.Text='取消全选'; $form.Controls.Add($noneButton)
$batchButton=New-Object EnvAnchorUi.RoundedButton; $batchButton.Text='勾选项统一用默认路径'; $form.Controls.Add($batchButton)
$openButton=New-Object EnvAnchorUi.RoundedButton; $openButton.Text='打开已有方案'; $form.Controls.Add($openButton)
function Update-TargetPreview {
    for($i=0;$i -lt $script:choices.Count;$i++) {
        $choice=$script:choices[$i]
        if($choice.Target){$list.Items[$i].SubItems[2].Text=$choice.Target}
        else {
            try {$list.Items[$i].SubItems[2].Text=Get-DefaultTarget $pathBox.Text $choice.Name $choice.Path}
            catch {$list.Items[$i].SubItems[2].Text='请选择有效默认路径'}
        }
        $list.Items[$i].ToolTipText=$list.Items[$i].SubItems[2].Text
    }
}
$pathBox.Add_TextChanged({Update-TargetPreview})
$allButton.Add_Click({foreach($item in $list.Items){$item.Checked=$true}})
$noneButton.Add_Click({foreach($item in $list.Items){$item.Checked=$false}})
$batchButton.Add_Click({
    if(-not $list.CheckedIndices.Count){$status.Text='请先全选或勾选需要统一迁移的目录。'; return}
    foreach($index in $list.CheckedIndices){$script:choices[$index].Target=''}
    Update-TargetPreview
    $status.Text='已统一目标预览。修改顶部默认路径后，点击「统一迁移勾选项」才会移动文件。'
})
function Open-Plan($Location) {
    $loaded=Read-State $Location
    $script:planStore=[IO.Path]::GetFullPath($Location).TrimEnd('\')
    foreach($entry in $loaded.Entries) {
        if($entry.Phase -eq 'Restored'){continue}
        if(-not @($script:choices | Where-Object {$_.Path -ieq $entry.Source}).Count) {
            # Preserve missing/reset source entries so reconnect remains possible.
            [void]$script:choices.Add([pscustomobject]@{Name=$entry.Label;Path=$entry.Source;Target=$entry.Target})
            $item=New-Object Windows.Forms.ListViewItem($entry.Label)
            [void]$item.SubItems.Add($entry.Source); [void]$item.SubItems.Add($entry.Target); [void]$list.Items.Add($item)
        }
        for($i=0;$i -lt $script:choices.Count;$i++) {
            if($script:choices[$i].Path -ieq $entry.Source){$script:choices[$i].Target=$entry.Target}
        }
    }
    Update-TargetPreview
    $status.Text="已打开方案：$script:planStore`r`n换位置：全选 → 修改默认路径 → 勾选项统一用默认路径 → 统一迁移。"
}
$openButton.Add_Click({
    $dialog=New-Object Windows.Forms.FolderBrowserDialog; $dialog.Description='选择含 state.json 的原方案目录'
    if($dialog.ShowDialog() -eq 'OK') {
        try {Open-Plan $dialog.SelectedPath} catch {$status.Text=$_.Exception.Message}
    }; $dialog.Dispose()
})
$auto=New-Object Windows.Forms.CheckBox; $auto.Text='安装登录自动挂接入口（必须再由管理员保存到还原基线）'; $auto.SetBounds(24,403,900,28); $form.Controls.Add($auto)
Label '例如桌面 → E:\桌面，Clash → F:\Clash。更换已有迁移的磁盘：先撤销，再选新的空目标文件夹迁移。' 24 446 912 25
Label '首次迁移请关闭相关软件。只保留文件和配置，不包含图标排列、任务栏或 TUN 驱动。' 24 475 912 25
$apply=New-Object EnvAnchorUi.RoundedButton; $apply.Text='一键迁移'; $apply.SetBounds(24,522,160,38); $form.Controls.Add($apply)
$resume=New-Object EnvAnchorUi.RoundedButton; $resume.Text='重置后重新挂接'; $resume.SetBounds(198,522,180,38); $form.Controls.Add($resume)
$undo=New-Object EnvAnchorUi.RoundedButton; $undo.Text='撤销并复制回原处'; $undo.SetBounds(392,522,200,38); $form.Controls.Add($undo)
$status=New-Object Windows.Forms.TextBox; $status.Multiline=$true; $status.ReadOnly=$true; $status.ScrollBars='Vertical'; $status.SetBounds(24,583,912,103); $status.Text='就绪。备份和目标磁盘数据不会自动删除。方案位置也需要保存在不还原的磁盘。'; $form.Controls.Add($status)
function Run-Action($Action) {
    $apply.Enabled=$false; $resume.Enabled=$false; $undo.Enabled=$false
    $form.UseWaitCursor=$true; $status.Text='正在处理和校验文件，请勿关闭窗口…'; $form.Refresh()
    try {
        $script:Store=$pathBox.Text
        if($script:planStore){$script:Store=$script:planStore}
        & $Action
        $status.Text="完成。方案保存在：$Store`r`n备份仍保留在原目录旁。自动入口只有保存进还原基线后才可跨重置生效。"
    } catch { $status.Text="未完成：$($_.Exception.Message)`r`n已完成的项目保存在方案中；请勿删除备份，可使用撤销。" }
    finally {$apply.Enabled=$true; $resume.Enabled=$true; $undo.Enabled=$true; $form.UseWaitCursor=$false}
}
$apply.Add_Click({ Run-Action {
    if($list.CheckedIndices.Count -eq 0) {throw '请先勾选需要迁移的目录。'}
    $state=Get-Plan
    if (@($state.Entries).Count -and @($state.Entries | Where-Object {$_.Phase -ne 'Restored'}).Count -eq 0) {
        Copy-Item -LiteralPath (Join-Path $Store 'state.json') -Destination (Join-Path $Store ('state-history-'+[Guid]::NewGuid().ToString('N')+'.json'))
        $state.Entries=@(); Save-State $state $Store
    }
    $planned=[pscustomobject]@{Entries=@($state.Entries)}
    $jobs=@()
    foreach($index in $list.CheckedIndices) {
        $choice=$script:choices[$index]
        $src=[IO.Path]::GetFullPath($choice.Path).TrimEnd('\')
        if($Store.StartsWith($src+'\',[StringComparison]::OrdinalIgnoreCase) -or $src.StartsWith($Store+'\',[StringComparison]::OrdinalIgnoreCase) -or $src -ieq $Store) {throw '保存位置不能与迁移目录重叠。'}
        $target=$choice.Target
        if(-not $target){$target=Get-DefaultTarget $pathBox.Text $choice.Name $src}
        Assert-PersistentPath $target
        $existing=@($state.Entries | Where-Object {$_.Source -ieq $src})
        $others=[pscustomobject]@{Entries=@($planned.Entries | Where-Object {$_.Source -ine $src})}
        if(-not $existing.Count -or $existing[0].Target -ine $target) {Assert-EntryPaths $src $target $others $Store}
        if($existing.Count) {
            if($existing[0].Target -ine $target -and (Test-PathOverlap $existing[0].Target $target)){throw '新位置不能与旧数据目录重叠。'}
        } else {Assert-PlainTree $src}
        $planned.Entries=@($others.Entries)+@([pscustomobject]@{Source=$src;Target=$target})
        $jobs+=@([pscustomobject]@{Source=$src;Target=$target;Name=$choice.Name;Existing=$existing})
    }
    foreach($job in $jobs){
        if($job.Existing.Count){Move-EntryTarget $job.Existing[0] $job.Target $state $Store}
        else {Add-Entry $job.Source $job.Name $state $Store $job.Target}
    }
    if($auto.Checked){Set-ResumeShortcut $true}
} })
$resume.Add_Click({ Run-Action { Assert-Store; $state=Read-State $Store; Resume-State $state $Store; if($auto.Checked){Set-ResumeShortcut $true} } })
$undo.Add_Click({ Run-Action { Assert-Store; $state=Read-State $Store; Undo-State $state $Store; Set-ResumeShortcut $false } })

# Unified desktop styling; all actions above retain the same data workflow.
$form.Text='环境锚点'; $form.ClientSize=New-Object Drawing.Size(1080,790)
$form.BackColor=[Drawing.ColorTranslator]::FromHtml('#F3F5F8')
$form.ForeColor=[Drawing.ColorTranslator]::FromHtml('#243247')
$form.ShowIcon=$true
$clientPath=Get-Variable EnvAnchorExecutable -ValueOnly -ErrorAction SilentlyContinue
if($clientPath){$form.Icon=[Drawing.Icon]::ExtractAssociatedIcon($clientPath)}
elseif(Test-Path -LiteralPath "$PSScriptRoot\assets\app.ico"){$form.Icon=New-Object Drawing.Icon("$PSScriptRoot\assets\app.ico")}
$form.FormBorderStyle='Sizable'; $form.MaximizeBox=$true
$form.MinimumSize=New-Object Drawing.Size(920,640)
$form.AutoScroll=$true; $form.AutoScrollMinSize=New-Object Drawing.Size(1080,790)
$form.AutoScaleMode='None'
foreach($control in @($form.Controls)) {
    if($control -is [Windows.Forms.Label]) {$form.Controls.Remove($control); $control.Dispose()}
}
$background=New-Object Drawing.Bitmap(1080,790)
$backgroundGraphics=[Drawing.Graphics]::FromImage($background)
$backgroundGraphics.Clear($form.BackColor)
function Surface($X,$Y,$W,$H,$Color) {
    $brush=New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml($Color))
    if($X -eq 0){$backgroundGraphics.FillRectangle($brush,$X,$Y,$W,$H)}
    else {[EnvAnchorUi.Shapes]::Card($backgroundGraphics,(New-Object Drawing.Rectangle($X,$Y,$W,$H)), $brush.Color)}
    $brush.Dispose()
}
function Text-Line($Text,$X,$Y,$W,$H,$Size,$Color,$Bold=$false,$Background='') {
    $label=New-Object Windows.Forms.Label; $label.Text=$Text; $label.SetBounds($X,$Y,$W,$H)
    $style=[Drawing.FontStyle]::Regular; if($Bold){$style=[Drawing.FontStyle]::Bold}
    $label.Font=New-Object Drawing.Font('Microsoft YaHei UI',$Size,$style)
    $label.ForeColor=[Drawing.ColorTranslator]::FromHtml($Color)
    if($Background){$label.BackColor=[Drawing.ColorTranslator]::FromHtml($Background)}
    $form.Controls.Add($label)
}
Surface 0 0 208 790 '#142D38'
Surface 240 110 808 122 '#FFFFFF'
Surface 240 250 808 287 '#FFFFFF'
Surface 240 553 808 58 '#E7F1EE'
$backgroundGraphics.Dispose(); $form.BackgroundImage=$background
$mark=New-Object Windows.Forms.PictureBox; $mark.SetBounds(25,27,58,58); $mark.SizeMode='Zoom'
$mark.Image=Get-Variable EnvAnchorMark -ValueOnly -ErrorAction SilentlyContinue
if(-not $mark.Image){$mark.Image=[Drawing.Image]::FromFile("$PSScriptRoot\assets\app.png")}
$mark.BackColor=[Drawing.ColorTranslator]::FromHtml('#142D38'); $form.Controls.Add($mark)
Text-Line '环境锚点' 94 30 110 32 16 '#FFFFFF' $true '#142D38'
Text-Line 'ENV ANCHOR' 96 65 109 20 8 '#8FB5B5' $false '#142D38'
Text-Line 'DESKTOP EDITION  /  0.5' 29 101 178 25 8 '#8FB5B5' $false '#142D38'
Text-Line "重启之后，`n熟悉的环境还在。" 29 143 155 68 13 '#D8E8E8' $false '#142D38'
Text-Line '01   选择保留位置' 29 263 164 26 11 '#FFFFFF' $true '#142D38'
Text-Line '使用不会还原的磁盘' 29 297 167 24 9 '#8FB5B5' $false '#142D38'
Text-Line '02   添加文件与配置' 29 355 175 26 11 '#FFFFFF' $true '#142D38'
Text-Line '每个目录可单独设置' 29 389 167 24 9 '#8FB5B5' $false '#142D38'
Text-Line '03   迁移并保留' 29 447 167 26 11 '#FFFFFF' $true '#142D38'
Text-Line '自动校验，原目录留备份' 29 481 174 24 9 '#8FB5B5' $false '#142D38'
Text-Line "本地运行 · 无需联网`nWindows 10" 29 710 173 50 9 '#8FB5B5' $false '#142D38'
Text-Line '你的环境，安心保留。' 240 27 720 42 24 '#1D3440' $true
Text-Line '桌面 · 文档 · 软件配置     /     选择位置，迁移文件，重置后重新连接。' 242 77 800 24 10 '#6B7C8C'
Text-Line '默认保存位置' 260 126 245 28 12 '#243247' $true '#FFFFFF'
$openButton.SetBounds(868,120,160,32)
$pathBox.SetBounds(260,166,635,32); $pathBox.BorderStyle='FixedSingle'; $pathBox.Font=New-Object Drawing.Font('Microsoft YaHei UI',11)
$browse.SetBounds(913,162,115,38); $browse.Text='选择文件夹'
Text-Line '请选择不会还原的非系统磁盘，例如 E:\个人环境。' 260 204 745 20 9 '#788794' $false '#FFFFFF'
Text-Line '需要保留的内容' 260 265 270 28 12 '#243247' $true '#FFFFFF'
$selectionLabel=New-Object Windows.Forms.Label; $selectionLabel.SetBounds(650,270,178,22)
$selectionLabel.ForeColor=[Drawing.ColorTranslator]::FromHtml('#167D70'); $selectionLabel.BackColor=[Drawing.Color]::White
$selectionLabel.Font=New-Object Drawing.Font('Microsoft YaHei UI',9); $form.Controls.Add($selectionLabel)
$selectionLabel.Text='已选择 0 项'
$list.Add_ItemChecked({$selectionLabel.Text=('已选择 '+$list.CheckedIndices.Count+' 项')})
$allButton.SetBounds(838,262,74,32); $noneButton.SetBounds(922,262,106,32)
$list.SetBounds(260,307,768,167); $list.BorderStyle='None'; $list.BackColor=[Drawing.Color]::White
$list.Columns[0].Width=116; $list.Columns[1].Width=300; $list.Columns[2].Width=330
$rowImages=New-Object Windows.Forms.ImageList; $rowImages.ImageSize=New-Object Drawing.Size(1,32); $list.SmallImageList=$rowImages
$list.ShowItemToolTips=$true
$add.SetBounds(260,486,160,34); $add.Text='+  添加软件配置'
$targetButton.SetBounds(430,486,148,34); $targetButton.Text='修改单项目标'
$defaultButton.SetBounds(588,486,140,34); $defaultButton.Text='单项跟随默认'
$batchButton.SetBounds(738,486,290,34)
$auto.SetBounds(257,568,270,26); $auto.Text='登录时自动重新连接'; $auto.BackColor=[Drawing.ColorTranslator]::FromHtml('#E7F1EE')
Text-Line '需将登录入口保存进系统还原基线' 647 572 375 24 9 '#52786D' $false '#E7F1EE'
$apply.SetBounds(240,628,196,43); $apply.Text='统一迁移勾选项'
$resume.SetBounds(450,628,196,43); $resume.Text='重置后重新连接'
$undo.SetBounds(660,628,198,43); $undo.Text='撤销并还原文件'
foreach($button in @($browse,$add,$targetButton,$defaultButton,$apply,$resume,$undo,$allButton,$noneButton,$batchButton,$openButton)) {
    $button.FlatStyle='Flat'; $button.FlatAppearance.BorderColor=[Drawing.ColorTranslator]::FromHtml('#D9E1E7')
    $button.FlatAppearance.BorderSize=1
    $button.FlatAppearance.MouseOverBackColor=[Drawing.ColorTranslator]::FromHtml('#E8F1F0')
    $button.BackColor=[Drawing.Color]::White; $button.ForeColor=$form.ForeColor
    $button.Cursor=[Windows.Forms.Cursors]::Hand
}
$apply.BackColor=[Drawing.ColorTranslator]::FromHtml('#167D70'); $apply.ForeColor=[Drawing.Color]::White
$apply.FlatAppearance.BorderSize=0; $apply.FlatAppearance.MouseOverBackColor=[Drawing.ColorTranslator]::FromHtml('#126B60')
$apply.Font=New-Object Drawing.Font('Microsoft YaHei UI',11,[Drawing.FontStyle]::Bold)
$undo.ForeColor=[Drawing.ColorTranslator]::FromHtml('#68798A')
$status.SetBounds(240,692,808,73); $status.BorderStyle='None'; $status.BackColor=$form.BackColor
$status.ForeColor=[Drawing.ColorTranslator]::FromHtml('#667989'); $status.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
$status.Text="就绪。迁移前请关闭相关软件；原目录备份和目标磁盘数据都会保留。`r`n保留文件和配置，不包含桌面图标排列、任务栏或 TUN 驱动。"
$form.ActiveControl=$browse
Update-TargetPreview
if(-not $SmokeTest -and (Test-Path -LiteralPath (Join-Path $Store 'state.json'))) {
    try {Open-Plan $Store} catch {$status.Text=$_.Exception.Message}
}
if ($SmokeTest) {
    $form.ShowInTaskbar=$false; $form.StartPosition="Manual"; $form.Location=New-Object Drawing.Point(-32000,-32000); $form.Show(); [Windows.Forms.Application]::DoEvents()
    $readyText=$status.Text
    $apply.PerformClick()
    if ($status.Text -notlike '*请先勾选*') {throw '空选择的界面校验失败。'}
    $status.Text=$readyText
    $allButton.PerformClick()
    if($list.CheckedIndices.Count -ne $list.Items.Count){throw '全选失败。'}
    $originalDefault=$pathBox.Text
    $pathBox.Text='F:\BatchPreviewOnly'
    $batchButton.PerformClick()
    foreach($item in $list.Items){if($item.SubItems[2].Text -notlike 'F:\BatchPreviewOnly\*'){throw '统一目标预览失败。'}}
    $pathBox.Text=$originalDefault
    $noneButton.PerformClick()
    if($list.CheckedIndices.Count){throw '取消全选失败。'}
    $status.Text=$readyText
    if ($list.Items.Count) {
        $list.Items[0].Selected=$true
        $script:choices[0].Target='F:\UITestOnly'
        $defaultButton.PerformClick()
        if ($script:choices[0].Target) {throw '跟随默认位置的界面事件失败。'}
        $list.Items[0].Selected=$false
    }
    foreach($control in @($pathBox,$list,$apply,$resume,$undo,$targetButton,$allButton,$batchButton,$openButton)) {
        if(-not $control.Visible -or $control.Right -gt $form.ClientSize.Width -or $control.Bottom -gt $form.ClientSize.Height) {throw '界面控件可见性检查失败。'}
    }
    # Public preview uses synthetic display paths; actual migration choices are untouched.
    for($i=0;$i -lt $list.Items.Count;$i++) {
        $list.Items[$i].SubItems[1].Text='C:\Users\Demo\'+(Split-Path $script:choices[$i].Path -Leaf)
        $list.Items[$i].SubItems[2].Text='E:\个人环境\'+$script:choices[$i].Name
    }
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    $preview=Join-Path $env:TEMP 'env-anchor-preview.png'
    $bitmap.Save($preview,[Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose(); $form.Dispose(); Write-Output "UI construction passed: $preview"; return
}
[void]$form.ShowDialog()
