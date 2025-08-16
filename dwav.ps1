<#
Remove-Wav-Interactive.ps1 （修正版）
交互式删除指定文件夹（及子文件夹）内的 指定扩展文件（默认 .wav）
运行：powershell -ExecutionPolicy Bypass -File .\Remove-Wav-Interactive.ps1
#>

Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8

function Read-Paths {
    param($prompt)
    while ($true) {
        $raw = Read-Host $prompt
        if (-not $raw) { Write-Host "未输入路径，请重试。" -ForegroundColor Yellow; continue }
        $parts = $raw -split '[;,|]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        $resolved = @()
        foreach ($p in $parts) {
            if ($p -eq '.') { $resolved += (Get-Location).Path } else { $resolved += $p }
        }
        return $resolved
    }
}

function Confirm-YesNo($message, $defaultYes=$true) {
    $suffix = if ($defaultYes) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $ans = Read-Host "$message $suffix"
        if ($ans -eq '') { return $defaultYes }
        switch ($ans.ToLower()) {
            'y' { return $true }
            'n' { return $false }
            default { Write-Host "请输入 Y 或 N。" -ForegroundColor Yellow }
        }
    }
}

Write-Host "交互式删除 文件脚本（默认扩展：wav）" -ForegroundColor Cyan
Write-Host "----------------------------------"

# 1) 扩展
$extInput = Read-Host "要删除的文件扩展（不带点，回车默认：wav）"
if (-not $extInput) { $extensions = @('wav') } else { $extensions = $extInput -split '[;,|]' | ForEach-Object { $_.Trim().ToLower() } }

# 2) 路径输入
$paths = Read-Paths "输入要处理的文件夹路径（多个用分号或逗号分隔，输入 . 表示当前目录）"

# 验证路径存在
$validPaths = @()
foreach ($p in $paths) {
    if (Test-Path -Path $p -PathType Container) {
        $validPaths += (Resolve-Path -Path $p).Path
    } else {
        Write-Warning "路径不存在或不是目录： $p （将被忽略）"
    }
}
if (-not $validPaths) {
    Write-Host "未发现有效目录，脚本结束。" -ForegroundColor Red
    exit 1
}

# 3) 递归
$recurse = Confirm-YesNo "是否递归子文件夹查找？" $true

# 4) 演练模式（仅列出）
$whatIf = Confirm-YesNo "是否先进行演练（仅列出将被删除的文件）？（建议：Y）" $true

# 5) 是否回收
$recycle = $false
if (-not $whatIf) {
    $recycle = Confirm-YesNo "删除时是否将文件移动到回收站？（否则永久删除）" $true
}

Write-Host "`n开始扫描目标目录..." -ForegroundColor Cyan
$found = @()
foreach ($folder in $validPaths) {
    try {
        if ($recurse) {
            $items = Get-ChildItem -Path $folder -Recurse -File -ErrorAction SilentlyContinue
        } else {
            $items = Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue
        }
        foreach ($it in $items) {
            $ext = $it.Extension.TrimStart('.').ToLower()
            if ($extensions -contains $ext) { $found += $it }
        }
    } catch {
        Write-Warning "扫描 $folder 时出错：$_"
    }
}

if (-not $found) {
    Write-Host "`n未找到匹配的文件（扩展：$($extensions -join ',')）。" -ForegroundColor Green
    exit 0
}

Write-Host "`n找到 $($found.Count) 个匹配文件：" -ForegroundColor Yellow
$found | ForEach-Object { Write-Host "  " $_.FullName }

if ($whatIf) {
    Write-Host "`n当前为演练模式（WhatIf）：仅列出，不会删除/移动任何文件。" -ForegroundColor Magenta
    if (Confirm-YesNo "现在要执行真实删除/移动操作吗（将跳过演练并继续）？" $false) {
        $whatIf = $false
        $recycle = Confirm-YesNo "删除时是否将文件移动到回收站？（否则永久删除）" $true
    } else {
        Write-Host "已结束（保持演练状态）。" -ForegroundColor Cyan
        exit 0
    }
}

# 最终预览并确认（修复处：先计算字符串变量，然后输出，避免解析 if 表达式问题）
$modeText = if ($recycle) { "移动到回收站" } else { "永久删除" }

Write-Host "`n操作预览："
Write-Host "  目标路径： "
$validPaths | ForEach-Object { Write-Host "    $_" }
Write-Host "  扩展： $($extensions -join ',')"
Write-Host "  递归： $recurse"
Write-Host "  模式： $modeText" -ForegroundColor Yellow

$ok = Read-Host "`n确认现在对上述 $($found.Count) 个文件执行操作？ 输入 Y 确认，其他键取消"
if ($ok -ne 'Y' -and $ok -ne 'y') {
    Write-Host "已取消操作。" -ForegroundColor Cyan
    exit 0
}

# 尝试加载 Microsoft.VisualBasic（用于回收站），若失败则回退
$vbAvailable = $false
if ($recycle) {
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        $vbAvailable = $true
    } catch {
        Write-Warning "无法加载 Microsoft.VisualBasic（回收站功能不可用），将改为永久删除。"
        $vbAvailable = $false
        $recycle = $false
    }
}

# 执行删除/移动
$success = 0
$failed = 0
Write-Host "`n开始执行..." -ForegroundColor Cyan
foreach ($f in $found) {
    try {
        if ($recycle -and $vbAvailable) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $f.FullName,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            )
        } else {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
        }
        $success++
    } catch {
        Write-Warning "处理失败： $($f.FullName) —— $_"
        $failed++
    }
}

Write-Host "`n完成： 成功 $success ， 失败 $failed。" -ForegroundColor Green
if ($failed -gt 0) { Write-Host "请检查失败项的权限或路径是否被占用。" -ForegroundColor Yellow }
