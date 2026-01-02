@echo off
cd /d "%~dp0"
:: --- 1. 自动获取管理员权限 ---
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo Requesting Admin access...
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"
    "%temp%\getadmin.vbs"
    exit /b
)
if exist "%temp%\getadmin.vbs" ( del "%temp%\getadmin.vbs" )

echo ==========================================
echo    NAS 极简作息设置 (每天 01:00睡 - 09:00醒)
echo ==========================================
echo.

:: --- 2. 创建任务 (使用 PowerShell 以确保 WakeToRun 参数生效) ---

powershell.exe -Command ^
  "$ActionSleep = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-WindowStyle Hidden -Command \"Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Application]::SetSuspendState([System.Windows.Forms.PowerState]::Suspend, $false, $false)\"';" ^
  "$TriggerSleep = New-ScheduledTaskTrigger -Daily -At '01:00';" ^
  "$SettingsSleep = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable:$false;" ^
  "Register-ScheduledTask -TaskName 'NAS_AutoSleep' -Action $ActionSleep -Trigger $TriggerSleep -Settings $SettingsSleep -User 'SYSTEM' -RunLevel Highest -Force | Out-Null;" ^
  ^
  "$ActionWake = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c echo NAS Awakening... & timeout 5';" ^
  "$TriggerWake = New-ScheduledTaskTrigger -Daily -At '09:00';" ^
  "$SettingsWake = New-ScheduledTaskSettingsSet -WakeToRun -Priority 1;" ^
  "Register-ScheduledTask -TaskName 'NAS_AutoWake' -Action $ActionWake -Trigger $TriggerWake -Settings $SettingsWake -User 'SYSTEM' -RunLevel Highest -Force | Out-Null;"

:: --- 3. 验证结果 ---
schtasks /query /tn "NAS_AutoSleep" >nul 2>&1 && echo [OK] 01:00 睡眠任务 - 已就绪 || echo [X] 睡眠任务创建失败
schtasks /query /tn "NAS_AutoWake" >nul 2>&1 && echo [OK] 09:00 唤醒任务 - 已就绪 || echo [X] 唤醒任务创建失败

echo.
echo 完成。
pause