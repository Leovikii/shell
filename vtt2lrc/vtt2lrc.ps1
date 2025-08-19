<#
vtt2lrc.ps1
PowerShell 5.1 兼容

功能：
 - 递归查找用户选择目录下的所有 .vtt 文件（强制递归）
 - 对每个文件使用同目录下的 subtitle-to-lrc.exe --no-length-limit "路径" 进行转换
 - 识别转换器生成的 .lrc 文件（常见命名形式），并将其重命名为：原文件名（去掉所有后缀，包括常见音频后缀） + .lrc
   例如： "xxx.wav.vtt" -> 目标 "xxx.lrc"
 - 如果目标 .lrc 已存在则覆盖
 - 详细日志记录到脚本目录下的 vtt2lrc_log.txt（每次运行覆盖旧日志）
 - 可将已成功转换的原 .vtt 文件移入回收站（用户确认）
#>

# 控制台输出编码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 获取脚本目录（兼容双击与 PowerShell 执行）
if ($PSScriptRoot -and $PSScriptRoot -ne '') {
    $ScriptDir = $PSScriptRoot
} else {
    $ScriptDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Definition -Parent
}

# 转换器信息
$ConverterName = 'subtitle-to-lrc.exe'
$ConverterPath = Join-Path -Path $ScriptDir -ChildPath $ConverterName
if (-not (Test-Path -LiteralPath $ConverterPath)) {
    Write-Host "错误：未在脚本目录找到 $ConverterName 。请把 $ConverterName 放在与本脚本相同的文件夹后重试。" -ForegroundColor Red
    exit 1
}

# 日志文件（固定名，每次运行覆盖）
$logPath = Join-Path -Path $ScriptDir -ChildPath 'vtt2lrc_log.txt'
"" | Out-File -FilePath $logPath -Encoding UTF8
function Log {
    param([string]$Text, [switch]$NoConsole)
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$time`t$Text"
    if (-not $NoConsole) { Write-Host $Text }
    $line | Out-File -FilePath $logPath -Encoding UTF8 -Append
}

Log "脚本启动. ScriptDir=$ScriptDir; Converter=$ConverterPath"

# 载入 WinForms 选择目录
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()
$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$folderDialog.Description = "请选择包含 .vtt 文件的根目录（将递归查找所有子文件夹）"
$folderDialog.ShowNewFolderButton = $false

$result = $folderDialog.ShowDialog()
if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
    Log "用户取消选择文件夹。"
    exit 0
}
$RootFolder = $folderDialog.SelectedPath
Log "用户选择目录: $RootFolder"

# 递归查找 .vtt 文件（必须递归）
try {
    $vttFiles = Get-ChildItem -LiteralPath $RootFolder -Filter *.vtt -File -Recurse -ErrorAction SilentlyContinue
} catch {
    Log "查找文件异常: $($_.Exception.Message)"
    Write-Host "查找文件时发生错误：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (-not $vttFiles -or $vttFiles.Count -eq 0) {
    Log "未找到 .vtt 文件。"
    Write-Host "在所选目录及子目录中未找到任何 .vtt 文件。" -ForegroundColor Yellow
    exit 0
}

# 切换到脚本目录，确保 exe 可被正确调用
Set-Location -LiteralPath $ScriptDir

# 回收站删除依赖
Add-Type -AssemblyName Microsoft.VisualBasic

# 常见音频扩展（用于去掉 "音频格式" 部分）
$audioExts = @('.wav', '.mp3', '.flac', '.m4a', '.aac', '.ogg', '.wma', '.aiff', '.alac', '.ape')

# 结果列表
$successList = New-Object System.Collections.Generic.List[object]
$failedList  = New-Object System.Collections.Generic.List[object]

$total = $vttFiles.Count
$index = 0

foreach ($file in $vttFiles) {
    $index++
    $full = $file.FullName
    Log "处理文件: $full"
    Write-Host "[$index / $total] 处理： $full" -ForegroundColor Green

    # 目标干净基名：先去掉最后一个扩展（通常是 .vtt），然后去掉常见音频扩展（如果存在）
    try {
        $dir = [System.IO.Path]::GetDirectoryName($full)
        $nameNoLastExt = [System.IO.Path]::GetFileNameWithoutExtension($full)  # e.g. "xxx.wav" from "xxx.wav.vtt"
        $cleanBase = $nameNoLastExt
        $lower = $cleanBase.ToLower()
        foreach ($ext in $audioExts) {
            if ($lower.EndsWith($ext)) {
                $cleanBase = $cleanBase.Substring(0, $cleanBase.Length - $ext.Length)
                Log "  去掉音频后缀 $ext -> 基名变为: $cleanBase"
                break
            }
        }
        # 如果转换后基名为空（极端情况），恢复原不带扩展名
        if ([string]::IsNullOrWhiteSpace($cleanBase)) {
            $cleanBase = [System.IO.Path]::GetFileNameWithoutExtension($full)
        }
        $desiredLrcName = $cleanBase + '.lrc'
        $desiredLrcPath = Join-Path -Path $dir -ChildPath $desiredLrcName
        Log "  期望输出 LRC: $desiredLrcPath"
    } catch {
        Log "  生成目标 LRC 名称失败: $($_.Exception.Message)"
        $failedList.Add([pscustomobject]@{ File = $full; Reason = "生成目标名称失败: $($_.Exception.Message)" }) | Out-Null
        continue
    }

    # 始终带 --no-length-limit 参数调用转换器
    $argsArray = @('--no-length-limit', $full)
    $argString = ($argsArray -join ' ')
    Log "  执行命令: $ConverterPath $argString"
    try {
        $output = & $ConverterPath @argsArray 2>&1
        $exit = $LASTEXITCODE
    } catch {
        $output = $_.Exception.Message
        $exit = 1
    }

    # 记录输出
    if ($output -is [array]) {
        foreach ($line in $output) { Log "    OUT: $line" -NoConsole }
    } else {
        Log "    OUT: $output" -NoConsole
    }
    Log "    ExitCode=$exit"

    # 查找转换器可能生成的 lrc 文件（可能形式：1) name.wav.lrc （ChangeExtension）, 2) name.wav.vtt.lrc （append .lrc））
    $candidates = @()
    try {
        $candidate1 = [System.IO.Path]::ChangeExtension($full, '.lrc')   # e.g. name.wav.lrc
        $candidate2 = $full + '.lrc'                                     # e.g. name.wav.vtt.lrc
        $candidate3 = Join-Path -Path $dir -ChildPath ($cleanBase + '.lrc') # maybe already correct
        $candidates += $candidate1
        $candidates += $candidate2
        $candidates += $candidate3
        # 去重但保持顺序
        $candidates = $candidates | Select-Object -Unique
        Log "    检查候选输出: $($candidates -join ' ; ')"
    } catch {
        Log "    生成候选输出路径失败: $($_.Exception.Message)"
    }

    # 找到实际存在的候选输出文件（取第一个存在的）
    $producedLrc = $null
    foreach ($c in $candidates) {
        if ($null -ne $c -and (Test-Path -LiteralPath $c)) {
            $producedLrc = $c
            Log "    发现转换生成文件: $producedLrc"
            break
        }
    }

    # 如果没有找到生成文件但 exit code = 0，也认为可能成功（但仍需后续确认）
    if ((-not $producedLrc) -and ($exit -eq 0)) {
        Log "    未在候选路径找到 .lrc，但转换器退出码为 0（可能生成在其他位置）。会尝试将预期目标作为成功条件并检查。" 
        # 继续尝试以 desiredLrcPath 为目标检查
        if (Test-Path -LiteralPath $desiredLrcPath) {
            $producedLrc = $desiredLrcPath
            Log "    直接在期望位置发现 .lrc: $producedLrc"
        }
    }

    # 如果仍然没有找到生成文件，则记录失败
    if (-not $producedLrc) {
        Log "    未检测到转换器生成的 .lrc 文件。标记为失败。"
        $failedList.Add([pscustomobject]@{
            File = $full
            ExitCode = $exit
            Note = "未检测到输出 .lrc 文件 (候选: $($candidates -join '; '))"
            OutputSample = ($output | Select-Object -First 50) -join "`n"
        }) | Out-Null
        Write-Host "  -> 转换失败（未检测到输出文件）。" -ForegroundColor Red
        continue
    }

    # 如果 producedLrc 已经是我们期望的 desiredLrcPath，则视为成功
    $movedOrOk = $false
    try {
        if (([System.IO.Path]::GetFullPath($producedLrc)) -eq ([System.IO.Path]::GetFullPath($desiredLrcPath))) {
            # 已在期望位置
            Log "    生成文件已在目标位置： $desiredLrcPath"
            $movedOrOk = $true
        } else {
            # 移动/重命名 producedLrc 到 desiredLrcPath（覆盖）
            Log "    将生成文件移动到目标位置并覆盖: `n      源: $producedLrc `n      目标: $desiredLrcPath"
            # 如果目标存在，先尝试删除目标（以避免 Move-Item 在某些情况下失败）
            if (Test-Path -LiteralPath $desiredLrcPath) {
                try {
                    Remove-Item -LiteralPath $desiredLrcPath -Force -ErrorAction Stop
                    Log "      目标已存在，已删除旧文件: $desiredLrcPath"
                } catch {
                    Log "      删除目标失败: $($_.Exception.Message) - 继续尝试 Move-Item 覆盖"
                }
            }
            Move-Item -LiteralPath $producedLrc -Destination $desiredLrcPath -Force -ErrorAction Stop
            Log "    移动/重命名成功。"
            $movedOrOk = $true
        }
    } catch {
        Log "    移动/重命名失败: $($_.Exception.Message)"
        $failedList.Add([pscustomobject]@{
            File = $full
            ExitCode = $exit
            Note = "移动/重命名失败: $($_.Exception.Message)"
            Produced = $producedLrc
            Desired = $desiredLrcPath
            OutputSample = ($output | Select-Object -First 50) -join "`n"
        }) | Out-Null
        Write-Host "  -> 转换后移动/重命名失败（已记录）。" -ForegroundColor Red
        continue
    }

    # 最终检查目标 .lrc 是否存在
    if ($movedOrOk -and (Test-Path -LiteralPath $desiredLrcPath)) {
        Log "  最终确认目标 .lrc 存在: $desiredLrcPath"
        Write-Host "  -> 转换并重命名成功: $desiredLrcName" -ForegroundColor DarkGreen
        $successList.Add($full) | Out-Null
    } else {
        Log "  最终确认目标 .lrc 不存在: $desiredLrcPath"
        $failedList.Add([pscustomobject]@{
            File = $full
            ExitCode = $exit
            Note = "最终目标 .lrc 不存在"
            Desired = $desiredLrcPath
            Produced = $producedLrc
        }) | Out-Null
        Write-Host "  -> 最终确认失败（目标 .lrc 不存在）。" -ForegroundColor Red
    }
} # end foreach files

# 汇总
Log "转换结束: Total=$total; Success=$($successList.Count); Failed=$($failedList.Count)"
Write-Host ""
Write-Host "转换完成。共找到 $total 个 .vtt 文件。" -ForegroundColor Cyan
Write-Host "成功： $($successList.Count)   失败： $($failedList.Count)" -ForegroundColor Cyan

if ($failedList.Count -gt 0) {
    Log "失败文件清单："
    foreach ($f in $failedList) {
        Log "FAILED: $($f.File)"
        if ($f.PSObject.Properties['ExitCode']) { Log "  Exit=$($f.ExitCode)" }
        if ($f.PSObject.Properties['Note']) { Log "  Note=$($f.Note)" }
        if ($f.PSObject.Properties['Produced']) { Log "  Produced=$($f.Produced)" }
        if ($f.PSObject.Properties['Desired']) { Log "  Desired=$($f.Desired)" }
        if ($f.PSObject.Properties['OutputSample']) {
            Log "  输出片段:`n$($f.OutputSample -replace "`n","`n    ")"
        }
    }
}

# 删除（移回收站）询问
if ($successList.Count -gt 0) {
    $msg = "已成功转换 $($successList.Count) 个文件。是否将这些已成功转换的原 .vtt 文件移动到回收站？（可在回收站恢复）"
    $caption = "删除（移回收站）确认"
    $dialogResult = [System.Windows.Forms.MessageBox]::Show($msg, $caption, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::Yes) {
        Log "用户选择将已转换文件移到回收站。"
        Write-Host "正在将已成功转换的 .vtt 文件移到回收站..." -ForegroundColor Yellow
        foreach ($p in $successList) {
            try {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $p,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                )
                Write-Host " 已移至回收站： $p" -ForegroundColor DarkGreen
                Log "  删除(回收站): 成功 - $p"
            } catch {
                Write-Host " 无法移至回收站： $p   错误： $($_.Exception.Message)" -ForegroundColor Red
                Log "  删除(回收站)失败: $p; Err=$($_.Exception.Message)"
            }
        }
        Write-Host "删除（回收站）操作完成。" -ForegroundColor Cyan
    } else {
        Log "用户选择保留原 .vtt 文件。"
        Write-Host "已选择保留原 .vtt 文件。" -ForegroundColor Cyan
    }
} else {
    Log "无已成功转换文件，无删除操作。"
    Write-Host "没有成功转换的文件，因此无需删除操作。" -ForegroundColor Cyan
}

Log "脚本结束."
Write-Host ""
Write-Host "全部工作完成。日志保存在： $logPath" -ForegroundColor Green
exit 0
