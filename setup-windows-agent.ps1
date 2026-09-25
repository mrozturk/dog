# Bu Windows bilgisayarı evde sürekli açık duran "ana ajan bilgisayarı" yapar:
#   - Tailscale (her yerden güvenli erişim)
#   - OpenSSH Server (Termius / diğer bilgisayardan SSH, varsayılan kabuk PowerShell)
#   - Uyku / hazırda bekletme kapalı, Windows Update gece habersiz yeniden başlatmaz
#   - Uzak Masaüstü (Windows Pro ise)
#   - Git + Claude Code
#   - Oturum açılınca "claude remote-control" otomatik başlar (telefondan yönetim)
#
# Kullanım: PowerShell'i YÖNETİCİ olarak aç ve:
#   Set-ExecutionPolicy -Scope Process Bypass -Force; .\setup-windows-agent.ps1

$ErrorActionPreference = 'Continue'
# Konsola tıklanınca çıktının donmasını (QuickEdit) engelle
Set-ItemProperty -Path 'HKCU:\Console' -Name QuickEdit -Value 0 -ErrorAction SilentlyContinue
$AgentDir = Join-Path $env:USERPROFILE 'agent'

function Log($msg) { Write-Host "`n==> $msg" -ForegroundColor Green }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "Bu script'i YÖNETİCİ PowerShell'de çalıştır (Başlat > PowerShell > sağ tık > Yönetici olarak çalıştır)." -ForegroundColor Red
  exit 1
}

Log "Tailscale ve Git kuruluyor (winget)"
if (-not (Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe")) {
  winget install --id Tailscale.Tailscale -e --source winget --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  winget install --id Git.Git -e --source winget --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

Log "OpenSSH Server açılıyor (Windows Update'ten iner, 5-15 dk sürebilir, bekle)"
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -PropertyType String -Force `
  -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' | Out-Null

Log "Uyku / hazırda bekletme kapatılıyor"
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change disk-timeout-ac 0
powercfg /change monitor-timeout-ac 15
powercfg /hibernate off

Log "Windows Update'in oturum açıkken habersiz yeniden başlatması engelleniyor"
$wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $wu -Force | Out-Null
New-ItemProperty -Path $wu -Name NoAutoRebootWithLoggedOnUsers -PropertyType DWord -Value 1 -Force | Out-Null

Log "Uzak Masaüstü açılıyor (Windows Home'da çalışmaz, sorun değil)"
try {
  Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
  Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction Stop
} catch { Write-Host "Uzak Masaüstü açılamadı (muhtemelen Windows Home)." -ForegroundColor Yellow }

Log "Claude Code kuruluyor"
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
}

Log "Ajan çalışma klasörü ve oturum açılışında remote-control görevi"
New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null
$startScript = Join-Path $AgentDir 'start-remote-control.ps1'
@"
Set-Location '$AgentDir'
`$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User') + ';' + "`$env:USERPROFILE\.local\bin"
while (`$true) {
  claude remote-control
  Write-Host 'remote-control kapandı, 10 sn sonra yeniden başlıyor...'
  Start-Sleep 10
}
"@ | Set-Content -Encoding UTF8 $startScript

$action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoExit -ExecutionPolicy Bypass -File `"$startScript`""
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
Register-ScheduledTask -TaskName 'Claude Remote Control' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Log "Tailscale'e bağlanılıyor (tarayıcı açılırsa giriş yap)"
& "$env:ProgramFiles\Tailscale\tailscale.exe" up --unattended --timeout 180s
$tsIp = (& "$env:ProgramFiles\Tailscale\tailscale.exe" ip -4 2>$null | Select-Object -First 1)

Write-Host @"

================================================================
 KURULUM TAMAM
================================================================
 Bilgisayar adı : $env:COMPUTERNAME
 Tailscale IP   : $tsIp
 Kullanıcı      : $env:USERNAME

 Diğer bilgisayardan / Linux'tan (Tailscale açık):
     ssh $env:USERNAME@$tsIp
 Telefondan Termius:
     Host $tsIp, kullanıcı $env:USERNAME, Windows şifren
 Uzak Masaüstü (Pro ise): mstsc ile $tsIp

 SON ADIMLAR (bir kez):
  1. Yeni bir PowerShell aç:  claude   -> tarayıcıdan giriş yap, sonra çık
  2. Oturumu kapatıp aç (veya Görev Zamanlayıcı'da 'Claude Remote Control'
     görevini çalıştır). Artık telefondaki Claude uygulamasında bu
     bilgisayar görünecek.
  3. Elektrik kesilince kendi açılsın istiyorsan BIOS'ta
     'Restore on AC Power Loss' = Power On yap.
  4. Elektrik kesintisinden sonra şifresiz oturum açsın istiyorsan
     Sysinternals Autologon aracını kullan (remote-control oturum
     açılınca başlar).
================================================================
"@
