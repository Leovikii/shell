<#
批量删除文件到回收站（兼容 PowerShell 5.1）
优化点：
 - 当输入以 "." 开头（如 ".wav"）时，仅按扩展名（最后一段扩展名）精确匹配；
 - 否则仍按文件名包含或扩展名匹配；
 - 增加日志功能：每次运行覆盖上次日志（脚本目录下 Delete-To-Recycle.log），记录详细信息。
注意：建议将此脚本文件保存为 UTF-8（带 BOM）以确保编辑器与 PowerShell 控制台显示中文/日文正确。
#>

# 尽量让控制台使用 UTF8 输出（在某些终端下有帮助）
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# 确定脚本目录（用于存放日志），兼容交互执行和脚本执行
try {
    if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $scriptDir = (Get-Location).Path
    }
} catch {
    $scriptDir = (Get-Location).Path
}

$logFile = Join-Path $scriptDir 'Delete-To-Recycle.log'

# 初始化日志（覆盖之前的日志）
try {
    '' | Out-File -FilePath $logFile -Encoding UTF8 -Force
} catch {
    Write-Host "无法创建/初始化日志文件：$logFile 。错误：$_" -ForegroundColor Yellow
}

function Write-Log {
    param([string]$Text)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "$ts `t $Text"
    try {
        $line | Out-File -FilePath $logFile -Encoding UTF8 -Append
    } catch {
        # 若写日志失败也不要中断主流程
        Write-Host "日志写入失败：$_" -ForegroundColor Yellow
    }
    Write-Host $Text
}

Write-Log "=== 脚本启动 ==="
Write-Log ("脚本目录：{0}" -f $scriptDir)

# 选择目录（使用 Shell.Application 的 BrowseForFolder）
try {
    $shell = New-Object -ComObject Shell.Application
    $folderObj = $shell.BrowseForFolder(0, '请选择要搜索的根目录（将递归查询所有子文件夹）', 0, 0)
} catch {
    Write-Log ("无法创建 Shell.Application COM 对象：{0}" -f $_.ToString())
    exit 1
}

if (-not $folderObj) {
    Write-Log "未选择目录，脚本退出。"
    exit 0
}

$rootPath = $folderObj.Self.Path
Write-Log ("已选择根目录：{0}" -f $rootPath)
Write-Log ""

# 获取关键字（循环直到有效输入或用户退出）
while ($true) {
    $inputRaw = Read-Host "请输入关键字（若输入以 . 开头，例如 .wav，则仅按扩展名精确匹配；输入 q 退出）"
    if (-not $inputRaw) {
        Write-Host "关键字不能为空，请重试。" -ForegroundColor Yellow
        continue
    }
    if ($inputRaw.Trim().ToLower() -eq 'q') {
        Write-Log "用户取消，脚本退出。"
        exit 0
    }
    $keyword = $inputRaw.Trim()
    break
}

Write-Log ("用户关键字：{0}" -f $keyword)

# 判断是否为扩展名模式（只有当用户输入以 '.' 开头时视为扩展名精确匹配）
$extMode = $false
if ($keyword.StartsWith('.')) {
    $extMode = $true
    $extCandidate = $keyword.ToLower()
    Write-Log ("扩展名模式：是，扩展名候选 = {0}" -f $extCandidate)
} else {
    $extMode = $false
    # 在非点开头时，保持原来行为：既匹配文件名包含关键字，也将关键字（带点）作为扩展名候选
    if ($keyword.StartsWith('.')) { $extCandidate = $keyword } else { $extCandidate = ".$keyword" }
    $extCandidate = $extCandidate.ToLower()
    Write-Log ("扩展名模式：否，将同时按文件名包含和扩展名候选（{0}）匹配" -f $extCandidate)
}

# 搜索文件（递归），忽略无权限项
Write-Log "开始递归搜索匹配文件..."
try {
    $allFiles = Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force -ErrorAction SilentlyContinue
    Write-Log ("递归获取文件数：{0}" -f $allFiles.Count)
} catch {
    Write-Log ("搜索时发生错误：{0}" -f $_.ToString())
    exit 1
}

# 过滤逻辑
$matches = New-Object System.Collections.ArrayList
foreach ($f in $allFiles) {
    try {
        # 使用 FileInfo.Extension 返回最后一段扩展名（含点），适合精确扩展匹配
        $ext = $f.Extension
        if ($ext -eq $null) { $ext = "" }
        if ($extMode) {
            # 仅按扩展名精确匹配（不考虑文件名中出现关键字）
            if ($ext.ToLower() -eq $extCandidate) {
                [void]$matches.Add($f)
            }
        } else {
            # 非扩展名模式：文件名包含关键字（不区分大小写）或最后扩展等于 extCandidate
            $nameHas = ($f.Name.IndexOf($keyword, [System.StringComparison]::InvariantCultureIgnoreCase) -ge 0)
            $extMatch = ($ext.ToLower() -eq $extCandidate)
            if ($nameHas -or $extMatch) {
                [void]$matches.Add($f)
            }
        }
    } catch {
        # 忽略个别文件处理异常
        Write-Log ("过滤单文件时异常（忽略）：{0} => {1}" -f $f.FullName, $_.ToString())
        continue
    }
}

$matchCount = $matches.Count
Write-Log ("匹配到文件数：{0}" -f $matchCount)

if ($matchCount -eq 0) {
    Write-Log "未找到匹配文件，脚本结束。"
    exit 0
}

# 列出匹配文件
Write-Log "------------- 匹配文件列表 -------------"
$idx = 1
foreach ($m in $matches) {
    $sizeKB = [math]::Round(($m.Length / 1KB), 2)
    $lastWrite = $m.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
    $line = ("[{0}] {1} KB  {2}  {3}" -f $idx, $sizeKB, $lastWrite, $m.FullName)
    Write-Log $line
    $idx++
}
Write-Log "-----------------------------------------"

# 确认删除
$confirm = Read-Host "是否将以上 $matchCount 个文件移动到回收站？(输入 Y 确认，其他键取消)"
if ($confirm.Trim().ToUpper() -ne 'Y') {
    Write-Log "用户取消删除操作，脚本结束。"
    exit 0
}

# 尝试加载 Microsoft.VisualBasic 程序集以使用 FileSystem.DeleteFile
$useVBDelete = $false
try {
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    if ([type]::GetType("Microsoft.VisualBasic.FileIO.FileSystem")) {
        $useVBDelete = $true
        Write-Log "已加载 Microsoft.VisualBasic，优先使用 FileSystem.DeleteFile 移动到回收站。"
    } else {
        $useVBDelete = $false
        Write-Log "Microsoft.VisualBasic.FileIO.FileSystem 不可用，回退到 Shell.Application 方法。"
    }
} catch {
    $useVBDelete = $false
    Write-Log ("加载 Microsoft.VisualBasic 失败，回退到 Shell.Application 方法。错误：{0}" -f $_.ToString())
}

# 准备 Recycle Bin COM（仅在需要回退时创建）
$recycle = $null
if (-not $useVBDelete) {
    try {
        $sh = New-Object -ComObject Shell.Application
        $recycle = $sh.Namespace(0xA)
        if ($recycle -eq $null) {
            Write-Log "无法获取回收站 COM 命名空间（Namespace 0xA 返回 null）。"
        } else {
            Write-Log "已获取回收站 COM 命名空间，用于回退删除方法。"
        }
    } catch {
        Write-Log ("获取回收站 COM 命名空间失败：{0}" -f $_.ToString())
        $recycle = $null
    }
}

$deleted = 0
$failed = New-Object System.Collections.ArrayList

foreach ($file in $matches) {
    $full = $file.FullName
    Write-Log ("开始删除: {0}" -f $full)
    $success = $false

    if ($useVBDelete) {
        try {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $full,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            )
            $success = $true
            Write-Log ("  -> 已通过 Microsoft.VisualBasic 移动到回收站：{0}" -f $full)
        } catch {
            Write-Log ("  -> Microsoft.VisualBasic 删除失败：{0}" -f $_.ToString())
            $success = $false
        }
    }

    if (-not $success) {
        if ($recycle -ne $null) {
            try {
                # MoveHere 支持字符串路径
                $recycle.MoveHere($full)
                $success = $true
                Write-Log ("  -> 已通过 Shell.Application.MoveHere 移动到回收站：{0}" -f $full)
            } catch {
                Write-Log ("  -> Shell.Application.MoveHere 删除失败：{0}" -f $_.ToString())
                $success = $false
            }
        } else {
            Write-Log "  -> 未能进行回退删除（回收站 COM 未可用）。"
            $success = $false
        }
    }

    if ($success) {
        [void]$deleted++
    } else {
        [void]$failed.Add($full)
    }
}

# 总结
Write-Log ("操作完成。已尝试删除：{0} ，成功移动到回收站：{1} ，失败：{2}" -f $matchCount, $deleted, $failed.Count)
if ($failed.Count -gt 0) {
    Write-Log "失败文件列表："
    foreach ($f in $failed) { Write-Log ("  {0}" -f $f) }
    Write-Log "失败原因可能包括：文件被占用、无权限、路径过长或系统限制等。"
}

Write-Log "=== 脚本结束 ==="
