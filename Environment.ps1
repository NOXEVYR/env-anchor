# Reference inspection never executes configuration or follows directory links.
$script:ReferenceMaximumEntries = 20000
$script:ReferenceMaximumDepth = 16
$script:ReferenceMaximumBytes = 1048576

function ConvertFrom-EnvironmentArray([string]$Json) {
    if ($Json.Length -gt 8388608 -or $Json.Trim() -notmatch '^\[') { throw '请求必须是有限大小的 JSON 数组。' }
    $value = ConvertFrom-Json -InputObject $Json
    if ($null -ne $value -and $value -isnot [array]) { throw '请求必须是 JSON 数组。' }
    return ,@($value)
}
function ConvertTo-EnvironmentPath($Path) {
    Assert-CanonicalPath $Path '路径'
    if ($Path -notmatch '^[A-Za-z]:\\') { throw '仅支持本地磁盘绝对路径。' }
    return [IO.Path]::GetFullPath($Path)
}
function Assert-EnvironmentAncestors([string]$Path) {
    $current = $Path
    while ($current) {
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch [IO.FileNotFoundException] { $attributes = $null }
        catch [IO.DirectoryNotFoundException] { $attributes = $null }
        if ($null -ne $attributes -and (($attributes -band [IO.FileAttributes]::ReparsePoint) -or ([int]$attributes -band 0x441000))) { throw '路径包含链接、云占位或离线文件。' }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }; $current = $parent.FullName
    }
}
function Test-EnvironmentWithin([string]$Path, [string]$Root) {
    $base = $Root.TrimEnd('\')
    return ($Path -ieq $base -or $Path.StartsWith($base+'\', [StringComparison]::OrdinalIgnoreCase))
}
function Get-EnvironmentMappings([string]$Json) {
    $maps = New-Object 'Collections.Generic.List[object]'
    foreach ($map in (ConvertFrom-EnvironmentArray $Json)) {
        if ($null -eq $map -or $map -isnot [pscustomobject] -or -not $map.PSObject.Properties['Old'] -or -not $map.PSObject.Properties['New']) { throw '映射必须包含 Old 和 New。' }
        $old = ConvertTo-EnvironmentPath $map.Old; $new = ConvertTo-EnvironmentPath $map.New
        if (@($maps | Where-Object { $_.Old -ieq $old }).Count) { throw '映射旧路径重复。' }
        $maps.Add([pscustomobject]@{ Old=$old.TrimEnd('\'); New=$new.TrimEnd('\') })
    }
    return ,@($maps | Sort-Object { $_.Old.Length } -Descending)
}
function Resolve-EnvironmentMapping([string]$Path, $Mappings) {
    foreach ($map in $Mappings) { if (Test-EnvironmentWithin $Path $map.Old) { return ($map.New + $Path.Substring($map.Old.Length)) } }
    return $Path
}
function Test-SensitiveReferenceName([string]$Name) { return ($Name -match '(?i)(^\.env(?:\.|$)|token|credential|password|secret|private[-_]?key|auth|api[-_]?key)') }
function Test-ReferencePath($Value) {
    if ($Value -isnot [string] -or $Value.Length -gt 32767 -or $Value -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+\\)') { return $false }
    try { Assert-CanonicalPath $Value '引用'; return $true } catch { return $false }
}
function Read-EnvironmentText([string]$Path, [switch]$Manifest) {
    # Windows PowerShell 5.1 defaults to the active ANSI code page without a BOM.
    # Never let that default reinterpret a user configuration or a UTF-8 manifest.
    $bytes=[IO.File]::ReadAllBytes($Path); $offset=0
    $encoding=New-Object Text.UTF8Encoding($false,$true)
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254 -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) { $encoding=New-Object Text.UTF32Encoding($false,$true,$true); $offset=4 }
    elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 254 -and $bytes[3] -eq 255) { $encoding=New-Object Text.UTF32Encoding($true,$true,$true); $offset=4 }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { $encoding=New-Object Text.UTF8Encoding($true,$true); $offset=3 }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) { $encoding=New-Object Text.UnicodeEncoding($false,$true,$true); $offset=2 }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) { $encoding=New-Object Text.UnicodeEncoding($true,$true,$true); $offset=2 }
    if ($Manifest -and $encoding.CodePage -ne 65001) { throw '恢复清单必须使用 UTF-8 编码。' }
    $text=$encoding.GetString($bytes,$offset,$bytes.Length-$offset)
    if ($text.IndexOf([char]0) -ge 0) { throw '文本编码无法安全确认。' }
    return [pscustomobject]@{Text=$text;Encoding=$encoding}
}
function Add-ReferenceValue($Context, [string]$Kind, [string]$Value, $Locator, [bool]$CanRepair) {
    if (-not (Test-ReferencePath $Value)) { return }
    $proposed = Resolve-EnvironmentMapping $Value $Context.Mappings
    $status = '原路径存在'
    if (-not (Test-Path -LiteralPath $Value)) { $status='原路径失效' }
    $repairable = $CanRepair -and $proposed -ine $Value -and (Test-Path -LiteralPath $proposed)
    if ($proposed -ine $Value) { if (Test-Path -LiteralPath $proposed) { $status='映射目标存在' } else { $status='映射目标不存在' } }
    if ($repairable) { try { Assert-EnvironmentAncestors $proposed } catch { $repairable=$false; $status='映射目标包含链接或不可安全访问' } }
    if ($Kind -eq 'VirtualEnvironment') { $status='虚拟环境需要重建，不能替换路径修复'; $repairable=$false }
    if ($Context.Items.Count -ge $script:ReferenceMaximumEntries) { $Context.Truncated=$true; return }
    $Context.Items.Add([pscustomobject]@{Kind=$Kind; File=$Context.File; Original=$Value; Proposed=$proposed; Status=$status; Repairable=[bool]$repairable; FileHash=$Context.Hash; Locator=@($Locator); Root=$Context.Root})
}
function Skip-ReferenceJsonSpace($Parser) {
    # Match(text,start) is required because \G anchors at the current token.
    $match=([regex]'\G[ \t\r\n]*').Match($Parser.Text,$Parser.Position)
    $Parser.Position+=$match.Length
}
function Read-ReferenceJsonString($Parser) {
    $match=([regex]'\G"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"').Match($Parser.Text,$Parser.Position)
    if (-not $match.Success) { throw 'JSON 字符串无效。' }
    $start=$Parser.Position; $Parser.Position+=$match.Length
    # Only a single string is decoded; numbers and duplicate object members never
    # enter PowerShell's object serializer.
    $decoded=(ConvertFrom-Json ('{"value":'+$match.Value+'}')).value
    return [pscustomobject]@{Value=$decoded;Start=$start;Length=$match.Length}
}
function Assert-ReferenceJsonCharacter($Parser,[char]$Expected) {
    Skip-ReferenceJsonSpace $Parser
    if ($Parser.Position -ge $Parser.Text.Length -or $Parser.Text[$Parser.Position] -cne $Expected) { throw 'JSON 结构无效。' }
    $Parser.Position++
}
function Read-ReferenceJsonValue($Parser,[int]$Depth=0,[bool]$Sensitive=$false) {
    if ($Depth -gt 64 -or $Parser.Count -ge 100000) { throw 'JSON 嵌套或项目数量超出安全限制。' }
    $Parser.Count++; Skip-ReferenceJsonSpace $Parser
    if ($Parser.Position -ge $Parser.Text.Length) { throw 'JSON 值缺失。' }
    $char=$Parser.Text[$Parser.Position]
    if ($char -ceq '"') {
        $token=Read-ReferenceJsonString $Parser
        if (-not $Sensitive -and (Test-ReferencePath $token.Value)) { $Parser.Tokens.Add($token) }
    } elseif ($char -ceq '{') {
        $Parser.Position++; Skip-ReferenceJsonSpace $Parser
        if ($Parser.Position -lt $Parser.Text.Length -and $Parser.Text[$Parser.Position] -ceq '}') { $Parser.Position++; return }
        while ($true) {
            Skip-ReferenceJsonSpace $Parser; $key=Read-ReferenceJsonString $Parser
            Assert-ReferenceJsonCharacter $Parser ':'
            Read-ReferenceJsonValue $Parser ($Depth+1) ($Sensitive -or (Test-SensitiveReferenceName $key.Value))
            Skip-ReferenceJsonSpace $Parser
            if ($Parser.Position -lt $Parser.Text.Length -and $Parser.Text[$Parser.Position] -ceq '}') { $Parser.Position++; break }
            Assert-ReferenceJsonCharacter $Parser ','
        }
    } elseif ($char -ceq '[') {
        $Parser.Position++; Skip-ReferenceJsonSpace $Parser
        if ($Parser.Position -lt $Parser.Text.Length -and $Parser.Text[$Parser.Position] -ceq ']') { $Parser.Position++; return }
        while ($true) {
            Read-ReferenceJsonValue $Parser ($Depth+1) $Sensitive; Skip-ReferenceJsonSpace $Parser
            if ($Parser.Position -lt $Parser.Text.Length -and $Parser.Text[$Parser.Position] -ceq ']') { $Parser.Position++; break }
            Assert-ReferenceJsonCharacter $Parser ','
        }
    } else {
        $match=([regex]'\G(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)').Match($Parser.Text,$Parser.Position)
        if (-not $match.Success) { throw 'JSON 值无效。' }; $Parser.Position+=$match.Length
    }
}
function Get-ReferenceJsonTokens([string]$Text) {
    $parser=@{Text=$Text;Position=0;Count=0;Tokens=(New-Object 'Collections.Generic.List[object]')}
    Read-ReferenceJsonValue $parser; Skip-ReferenceJsonSpace $parser
    if ($parser.Position -ne $Text.Length) { throw 'JSON 有多余或不完整内容。' }
    return ,$parser.Tokens.ToArray()
}
function Protect-ReferenceReport($Report) {
    Add-Type -AssemblyName System.Security
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Report | ConvertTo-Json -Depth 100 -Compress))
    return [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes, [Text.Encoding]::UTF8.GetBytes('EnvAnchorReferenceV1'), [Security.Cryptography.DataProtectionScope]::CurrentUser))
}
function Get-ReferenceReport {
    param([string]$RootsJson, [string]$MappingsJson='[]')
    $roots=ConvertFrom-EnvironmentArray $RootsJson; $maps=Get-EnvironmentMappings $MappingsJson
    if ($roots.Count -gt 128) { throw '一次最多选择 128 个扫描根目录。' }
    $warnings=New-Object 'Collections.Generic.List[string]'
    $context=@{Items=(New-Object 'Collections.Generic.List[object]');Mappings=$maps;Truncated=$false;File='';Hash='';Root=''}
    $count=0; $budget=$script:ReferenceMaximumEntries; $shell=$null
    try {
        foreach ($rootValue in $roots) {
            $root=ConvertTo-EnvironmentPath $rootValue
            try { Assert-EnvironmentAncestors $root; if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw '扫描根目录不存在。' } }
            catch { $warnings.Add(('跳过扫描根目录：'+$_.Exception.Message)); continue }
            $stack=New-Object 'Collections.Generic.Stack[object]'; $stack.Push(@{Path=$root;Depth=0})
            while ($stack.Count -and $budget -gt 0) {
                $node=$stack.Pop()
                try {
                    foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($node.Path)) {
                        $budget--; if ($budget -lt 0) { $context.Truncated=$true; break }
                        $attributes=[IO.File]::GetAttributes($path)
                        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -or ([int]$attributes -band 0x441000)) { $warnings.Add('跳过目录链接或云占位项。'); continue }
                        $name=[IO.Path]::GetFileName($path)
                        if (Test-SensitiveReferenceName $name) { continue }
                        if ($attributes -band [IO.FileAttributes]::Directory) {
                            if ($node.Depth -lt $script:ReferenceMaximumDepth) { $stack.Push(@{Path=$path;Depth=$node.Depth+1}) } else { $context.Truncated=$true }; continue
                        }
                        $extension=[IO.Path]::GetExtension($path).ToLowerInvariant()
                        if ($extension -notin @('.json','.lnk','.ini','.yaml','.yml','.toml','.xml','.config','.cfg','.ps1','.bat','.cmd','.txt','.reg')) { continue }
                        if ((New-Object IO.FileInfo($path)).Length -gt $script:ReferenceMaximumBytes) { $context.Truncated=$true; continue }
                        $count++; $context.File=$path; $context.Root=$root; $context.Hash=Get-ContentHash $path
                        try {
                            if ($extension -eq '.lnk') {
                                if ($null -eq $shell) { $shell=New-Object -ComObject WScript.Shell }
                                $shortcut=$shell.CreateShortcut($path)
                                try { foreach ($field in @('TargetPath','WorkingDirectory')) { Add-ReferenceValue $context 'Shortcut' $shortcut.$field @($field) $true } }
                                finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
                            } elseif ($extension -eq '.json') {
                                $json=Read-EnvironmentText $path
                                foreach ($token in (Get-ReferenceJsonTokens $json.Text)) { Add-ReferenceValue $context 'JSON' $token.Value @([pscustomobject]@{Type='Token';Start=$token.Start;Length=$token.Length}) $true }
                            }
                            else {
                                $text=(Read-EnvironmentText $path).Text
                                $kind='Text'; if ($name -ieq 'pyvenv.cfg') { $kind='VirtualEnvironment' }
                                # Quoted paths retain spaces; unquoted paths are bounded by whitespace.
                                $pattern='["''](?<path>(?:[A-Za-z]:\\|\\\\)[^"''\r\n]+)["'']|(?<path>[A-Za-z]:\\[^\s"''<>|;,=]+)'
                                foreach ($match in [regex]::Matches($text,$pattern)) { Add-ReferenceValue $context $kind $match.Groups['path'].Value @([int]$match.Index) $false }
                            }
                            if ((Get-ContentHash $path) -ne $context.Hash) { throw '扫描期间文件发生变化。' }
                        } catch { $warnings.Add(('跳过编码无法确认或无法稳定解析的 '+$extension+' 文件。')); for ($i=$context.Items.Count-1;$i -ge 0;$i--) { if ($context.Items[$i].File -ieq $path) { $context.Items.RemoveAt($i) } } }
                    }
                } catch { $warnings.Add('部分目录无法读取，扫描结果不完整。'); $context.Truncated=$true }
            }
            if ($stack.Count -or $budget -le 0) { $context.Truncated=$true }
        }
    } finally { if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) } }
    $warnings.Add('仅 JSON 字符串值与快捷方式可自动修复；JSON 只替换勾选的字符串，保留其他内容与格式。文本配置和虚拟环境需人工处理。')
    $report=[pscustomobject]@{Version=1;Items=$context.Items.ToArray();Warnings=@($warnings | Select-Object -Unique);ScannedFiles=$count;Truncated=[bool]$context.Truncated}
    $report | Add-Member -NotePropertyName Seal -NotePropertyValue (Protect-ReferenceReport $report)
    return $report
}
function Invoke-ReferenceRepair {
    param([string]$ReportJson, [string]$SelectedJson)
    $errors=New-Object 'Collections.Generic.List[string]'; $backups=New-Object 'Collections.Generic.List[string]'; $changed=0
    try {
        if ($ReportJson.Length -gt 16777216) { throw '诊断报告过大。' }
        $supplied=ConvertFrom-Json $ReportJson
        Add-Type -AssemblyName System.Security
        $clear=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($supplied.Seal),[Text.Encoding]::UTF8.GetBytes('EnvAnchorReferenceV1'),[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $report=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($clear))
        $supplied.PSObject.Properties.Remove('Seal')
        if (($supplied | ConvertTo-Json -Depth 100 -Compress) -cne ($report | ConvertTo-Json -Depth 100 -Compress)) { throw '诊断报告已被修改，请重新扫描。' }
        $selected=ConvertFrom-EnvironmentArray $SelectedJson; $jobs=New-Object 'Collections.Generic.List[object]'; $seen=@{}
        foreach ($index in $selected) {
            if ($index -isnot [int] -or $index -lt 0 -or $index -ge @($report.Items).Count -or $seen.ContainsKey($index)) { throw '修复选择索引无效或重复。' }
            $seen[$index]=$true; $item=$report.Items[$index]
            if (-not $item.Repairable -or $item.Kind -notin @('JSON','Shortcut')) { throw '所选引用不能自动修复。' }; $jobs.Add($item)
        }
    } catch { $errors.Add(('修复请求无效：'+$_.Exception.Message)); return [pscustomobject]@{Changed=0;BackupPaths=@();Errors=@($errors)} }
    foreach ($group in @($jobs | Group-Object File)) {
        $temp=''; $locked=$null
        try {
            $first=$group.Group[0]; $file=ConvertTo-EnvironmentPath $first.File
            if (-not (Test-EnvironmentWithin $file $first.Root) -or (Test-SensitiveReferenceName ([IO.Path]::GetFileName($file)))) { throw '文件越过扫描安全根目录。' }
            Assert-EnvironmentAncestors $file
            foreach ($item in $group.Group) {
                if ($item.FileHash -ne $first.FileHash -or -not (Test-Path -LiteralPath $item.Proposed)) { throw '目标失效或诊断不一致。' }
                Assert-CanonicalPath $item.Proposed '修复目标'; Assert-EnvironmentAncestors $item.Proposed
            }
            if ((Get-ContentHash $file) -ne $first.FileHash) { throw '文件已发生变化，请重新扫描。' }
            $backup=$file+'.env-anchor-reference-backup-'+[Guid]::NewGuid().ToString('N')
            $temp=Join-Path ([IO.Path]::GetDirectoryName($file)) ('.env-anchor-reference-'+[Guid]::NewGuid().ToString('N')+[IO.Path]::GetExtension($file))
            if ($first.Kind -eq 'JSON') {
                $document=Read-EnvironmentText $file
                $text=$document.Text; $tokens=@{}
                foreach ($token in (Get-ReferenceJsonTokens $text)) { $tokens[$token.Start]=$token }
                $changes=New-Object 'Collections.Generic.List[object]'; $positions=@{}
                foreach ($item in $group.Group) {
                    if (@($item.Locator).Count -ne 1) { throw 'JSON token 定位无效，请重新扫描。' }
                    $slot=$item.Locator[0]
                    if ($slot.Type -cne 'Token' -or $slot.Start -isnot [int] -or -not $tokens.ContainsKey($slot.Start) -or $positions.ContainsKey($slot.Start)) { throw 'JSON token 定位无效或重复，请重新扫描。' }
                    $token=$tokens[$slot.Start]
                    if ($token.Length -ne $slot.Length -or $token.Value -cne $item.Original) { throw 'JSON 原字符串不再匹配。' }
                    $positions[$slot.Start]=$true
                    $changes.Add([pscustomobject]@{Start=$token.Start;Length=$token.Length;Text=(ConvertTo-Json -InputObject ([string]$item.Proposed) -Compress)})
                }
                foreach ($change in ($changes | Sort-Object Start -Descending)) { $text=$text.Remove($change.Start,$change.Length).Insert($change.Start,$change.Text) }
                Get-ReferenceJsonTokens $text | Out-Null
                [IO.File]::WriteAllText($temp,$text,$document.Encoding)
            } else {
                [IO.File]::Copy($file,$temp,$false); $shell=New-Object -ComObject WScript.Shell; $shortcut=$shell.CreateShortcut($temp)
                try {
                    foreach ($item in $group.Group) { $field=[string]$item.Locator[0]; if ($field -notin @('TargetPath','WorkingDirectory') -or $shortcut.$field -cne $item.Original) { throw ('快捷方式原属性不再匹配：'+$field) } }
                    foreach ($item in $group.Group) { $field=[string]$item.Locator[0]; $shortcut.$field=$item.Proposed }; $shortcut.Save()
                }
                finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
            }
            # A read/delete share excludes concurrent writers while checking and replacing.
            Assert-EnvironmentAncestors $file
            $locked=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
            $sha=[Security.Cryptography.SHA256]::Create()
            try { $hash=[BitConverter]::ToString($sha.ComputeHash($locked)) } finally { $sha.Dispose() }
            if ($hash -ne $first.FileHash) { throw '写入前文件发生变化，已停止。' }
            [IO.File]::Replace($temp,$file,$backup); $temp=''; $backups.Add($backup); $changed+=$group.Count
        } catch { $errors.Add(('修复失败：'+$_.Exception.Message)) }
        finally { if ($null -ne $locked) { $locked.Dispose() }; if ($temp -and [IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
    }
    return [pscustomobject]@{Changed=$changed;BackupPaths=@($backups);Errors=@($errors)}
}

function Assert-RecoverySafeLocation([string]$Path, [switch]$Source) {
    if ($Path.TrimEnd('\') -ieq [IO.Path]::GetPathRoot($Path).TrimEnd('\')) { throw '恢复路径不能是整个磁盘。' }
    foreach ($system in @($env:SystemRoot,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData)) { if ($system -and (Test-EnvironmentWithin $Path $system)) { throw '恢复路径不能使用系统或程序目录。' } }
    $users=Join-Path ([IO.Path]::GetPathRoot($env:USERPROFILE)) 'Users'
    if ($Path -ieq $users -or $Path -ieq $env:USERPROFILE -or $Path -match '(?i)\\Users\\[^\\]+(?:\\AppData(?:\\(?:Local|Roaming|LocalLow))?)?$' -or $Path -match '(?i)\\AppData(?:\\(?:Local|Roaming|LocalLow))?$') { throw '不能恢复整个用户目录或 AppData 根目录。' }
    if ($Source -and (Test-EnvironmentWithin $Path $users) -and -not (Test-EnvironmentWithin $Path $env:USERPROFILE)) { throw '原位置属于其他用户，请映射到当前用户目录。' }
}
function Get-RecoveryTreeSummary([string]$Path) {
    Assert-EnvironmentAncestors $Path
    if (-not [IO.Directory]::Exists($Path)) { throw '目标不是普通目录。' }
    $files=[int64]0; $bytes=[int64]0; $dirs=[int64]0; $budget=250000
    $stack=New-Object 'Collections.Generic.Stack[object]'; $stack.Push(@{Path=$Path;Depth=0})
    while ($stack.Count) {
        $node=$stack.Pop(); if ($node.Depth -gt 64) { throw '数据树过深，无法导出完整摘要。' }
        foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($node.Path)) {
            $budget--; if ($budget -lt 0) { throw '数据树超过摘要预算。' }
            $attributes=[IO.File]::GetAttributes($child)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -or ([int]$attributes -band 0x441000)) { throw '数据树包含链接或云占位项。' }
            if ($attributes -band [IO.FileAttributes]::Directory) { $dirs++; $stack.Push(@{Path=$child;Depth=$node.Depth+1}) }
            else { $files++; $bytes+=(New-Object IO.FileInfo($child)).Length }
        }
    }
    return [pscustomobject]@{Files=$files;Directories=$dirs;Bytes=$bytes;IsContentHash=$false;Meaning='仅文件数量和大小摘要，不校验文件内容'}
}
function Export-RecoveryManifest {
    param([string]$Store,[string]$Path)
    $Store=ConvertTo-EnvironmentPath $Store; $Path=ConvertTo-EnvironmentPath $Path
    Assert-EnvironmentAncestors $Store; Assert-EnvironmentAncestors $Path
    $state=Read-State $Store
    if (-not @($state.Entries).Count -or @($state.Entries | Where-Object {$_.Phase -cne 'Linked'}).Count) { throw '仅完整 Linked 方案可导出；存在未完成或已撤销项目。' }
    if (Test-EnvironmentWithin $Path $Store) { throw '恢复清单请保存到方案目录之外。' }
    $entries=@()
    foreach ($entry in $state.Entries) {
        if ((Test-EnvironmentWithin $Path $entry.Target) -or (Test-EnvironmentWithin $Path $entry.Source)) { throw '清单不能写入被管理的数据目录。' }
        $entries+= [pscustomobject]@{Label=$entry.Label;Source=$entry.Source;Target=$entry.Target;Summary=(Get-RecoveryTreeSummary $entry.Target)}
    }
    $manifest=[pscustomobject]@{Kind='EnvAnchorRecovery';Version=1;OriginalSID=$state.User;OriginalProfile=$env:USERPROFILE;OriginalStore=$Store;Entries=@($entries)}
    $temp=$Path+'.tmp-'+[Guid]::NewGuid().ToString('N')
    try { [IO.File]::WriteAllText($temp,($manifest|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false))); if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,($Path+'.backup-'+[Guid]::NewGuid().ToString('N'))) } else { [IO.File]::Move($temp,$Path) } }
    finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
    return [pscustomobject]@{Path=$Path;Entries=$entries.Count;Warnings=@('清单不复制数据，摘要不是内容哈希；请同时保留目标数据目录。')}
}
function Import-RecoveryManifest {
    param([string]$Path,[string]$NewStore,[string]$MappingsJson='[]',[switch]$Preview)
    $errors=New-Object 'Collections.Generic.List[string]'; $warnings=New-Object 'Collections.Generic.List[string]'; $entries=New-Object 'Collections.Generic.List[object]'; $state=$null
    try {
        $Path=ConvertTo-EnvironmentPath $Path; $NewStore=ConvertTo-EnvironmentPath $NewStore
        Assert-EnvironmentAncestors $Path; Assert-EnvironmentAncestors $NewStore; Assert-RecoverySafeLocation $NewStore
        if (-not [IO.File]::Exists($Path) -or (New-Object IO.FileInfo($Path)).Length -gt 4194304) { throw '恢复清单不存在或超过 4 MiB。' }
        $manifest=ConvertFrom-Json (Read-EnvironmentText $Path -Manifest).Text
        if ($manifest -isnot [pscustomobject]) { throw '清单必须是 JSON 对象。' }
        foreach ($field in @('Kind','Version','OriginalSID','OriginalProfile','OriginalStore','Entries')) { if (-not $manifest.PSObject.Properties[$field]) { throw ('清单缺少字段：'+$field) } }
        if ($manifest.Kind -cne 'EnvAnchorRecovery' -or $manifest.Version -isnot [int] -or $manifest.Version -ne 1 -or $manifest.OriginalSID -isnot [string] -or $manifest.OriginalSID -notmatch '^S-1-\d+(?:-\d+)+$' -or $manifest.Entries -isnot [array] -or $manifest.Entries.Count -lt 1 -or $manifest.Entries.Count -gt 128) { throw '恢复清单类型、版本或项目无效。' }
        $profile=ConvertTo-EnvironmentPath $manifest.OriginalProfile; $oldStore=ConvertTo-EnvironmentPath $manifest.OriginalStore
        if ((Test-PathOverlap $NewStore $oldStore) -or (Test-PathOverlap $NewStore $Path)) { throw '新方案必须独立于旧方案和恢复清单。' }
        if (Test-Path -LiteralPath $NewStore) { if (-not (Test-Path -LiteralPath $NewStore -PathType Container) -or @(Get-ChildItem -LiteralPath $NewStore -Force).Count) { throw '新方案必须是不存在或独立空目录。' } }
        $maps=Get-EnvironmentMappings $MappingsJson
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $different=$manifest.OriginalSID -ne $sid -or $profile -ine $env:USERPROFILE
        if ($different) { $warnings.Add('原用户与当前用户不同；将建立当前 SID 的新方案。') }
        foreach ($entry in $manifest.Entries) {
            if ($entry -isnot [pscustomobject]) { throw '清单项目必须是对象。' }
            foreach ($field in @('Label','Source','Target','Summary')) { if (-not $entry.PSObject.Properties[$field]) { throw ('清单项目缺少字段：'+$field) } }
            if ($entry.Label -isnot [string] -or $entry.Label.Length -gt 512 -or $entry.Summary -isnot [pscustomobject]) { throw '清单项目名称或摘要无效。' }
            foreach ($field in @('Files','Directories','Bytes')) { if (-not $entry.Summary.PSObject.Properties[$field] -or ($entry.Summary.$field -isnot [int] -and $entry.Summary.$field -isnot [long]) -or $entry.Summary.$field -lt 0) { throw '数据摘要无效。' } }
            if (-not $entry.Summary.PSObject.Properties['IsContentHash'] -or $entry.Summary.IsContentHash -isnot [bool] -or $entry.Summary.IsContentHash) { throw '清单摘要不能声称内容哈希校验。' }
            $original=ConvertTo-EnvironmentPath $entry.Source; $originalTarget=ConvertTo-EnvironmentPath $entry.Target
            if ($original -ieq $profile) { throw '清单不能恢复整个原用户目录。' }
            $source=Resolve-EnvironmentMapping $original $maps; $target=Resolve-EnvironmentMapping $originalTarget $maps
            $source=ConvertTo-EnvironmentPath $source; $target=ConvertTo-EnvironmentPath $target
            if ($different -and (Test-EnvironmentWithin $original $profile) -and $source -ieq $original) { throw '旧用户原位置未映射，停止以免写入旧用户目录。' }
            Assert-RecoverySafeLocation $source -Source; Assert-RecoverySafeLocation $target
            Assert-EnvironmentAncestors $source; Assert-EnvironmentAncestors $target
            if ((Test-PathOverlap $source $NewStore) -or (Test-PathOverlap $target $NewStore) -or (Test-PathOverlap $source $Path) -or (Test-PathOverlap $target $Path)) { throw '新方案、清单和数据目录必须互相独立。' }
            if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw '映射后的目标数据目录不存在。' }
            $summary=Get-RecoveryTreeSummary $target
            if ($summary.Files -ne $entry.Summary.Files -or $summary.Bytes -ne $entry.Summary.Bytes -or $summary.Directories -ne $entry.Summary.Directories) { $warnings.Add('目标数量或大小与导出时不同；此摘要不证明内容完整，请核对数据。') }
            $entries.Add([pscustomobject]@{Label=$entry.Label;Source=$source;Target=$target;Backups=@();Phase='Linked'})
        }
        $state=[pscustomobject]@{Version=1;User=$sid;Entries=$entries.ToArray()}
        Assert-StateSchema $state $NewStore
        $warnings.Add('只创建新方案，不复制数据或连接目录；必须随后预检并重新连接。')
    } catch { $errors.Add($_.Exception.Message) }
    $result=[pscustomobject]@{CanImport=($errors.Count -eq 0);Entries=$entries.ToArray();Errors=@($errors);Warnings=@($warnings | Select-Object -Unique);Store=$NewStore}
    if ($Preview) { return $result }
    if ($errors.Count) { throw ('导入被阻止：'+($errors -join '；')) }
    # Publish the complete state with an exclusive rename; never overwrite a plan.
    Assert-EnvironmentAncestors $NewStore
    if (-not [IO.Directory]::Exists($NewStore)) { [IO.Directory]::CreateDirectory($NewStore) | Out-Null }
    if (@(Get-ChildItem -LiteralPath $NewStore -Force).Count) { throw '新方案目录已发生变化，请重新检查。' }
    $temp=Join-Path $NewStore ('.import-'+[Guid]::NewGuid().ToString('N')+'.tmp')
    try {
        $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            # Match Core Save-State's UTF-8 BOM so Read-State remains safe on PS 5.1.
            $encoding=New-Object Text.UTF8Encoding($true,$true); $preamble=$encoding.GetPreamble()
            $stream.Write($preamble,0,$preamble.Length)
            $bytes=$encoding.GetBytes(($state|ConvertTo-Json -Depth 20)); $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true)
        } finally { $stream.Dispose() }
        Assert-EnvironmentAncestors $NewStore
        if (@(Get-ChildItem -LiteralPath $NewStore -Force | Where-Object {$_.FullName -ine $temp}).Count) { throw '新方案目录已发生变化，停止导入。' }
        [IO.File]::Move($temp,(Join-Path $NewStore 'state.json'))
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
    return $result
}

