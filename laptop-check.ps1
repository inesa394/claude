# laptop-check.ps1 - prueft einen Windows-Laptop auf Systemfehler und Netzwerkprobleme.
# Start (PowerShell, im Ordner der Datei):
#   powershell -ExecutionPolicy Bypass -File .\laptop-check.ps1
# Optional als Administrator starten, damit mehr Ereignisse lesbar sind.

$ErrorActionPreference = 'SilentlyContinue'
$script:Problems = 0
function Hdr($t)  { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  [WARN] $t" -ForegroundColor Yellow; $script:Problems++ }
function Info($t) { Write-Host "         $t" }

Hdr "System"
$os = Get-CimInstance Win32_OperatingSystem
Info "$($os.Caption) | Host: $env:COMPUTERNAME | $(Get-Date)"
$up = (Get-Date) - $os.LastBootUpTime
Info ("Laufzeit: {0} Tage {1} Std" -f $up.Days, $up.Hours)

Hdr "CPU"
$cpu = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
Info "Auslastung: $cpu %"
if ($cpu -gt 90) { Warn "Hohe CPU-Last" } else { Ok "CPU normal" }

Hdr "Arbeitsspeicher"
$tot = $os.TotalVisibleMemorySize / 1MB; $free = $os.FreePhysicalMemory / 1MB
$pct = [math]::Round(100 - $free / $tot * 100)
Info ("{0:N1} von {1:N1} GB belegt ({2} %)" -f ($tot - $free), $tot, $pct)
if ($pct -gt 90) { Warn "RAM fast voll" } else { Ok "RAM ok" }

Hdr "Festplatten"
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
  $p = [math]::Round(100 - $_.FreeSpace / $_.Size * 100)
  $msg = "{0} {1} % belegt ({2:N0} GB frei)" -f $_.DeviceID, $p, ($_.FreeSpace / 1GB)
  if ($p -ge 90) { Warn $msg } else { Ok $msg }
}
Get-PhysicalDisk | ForEach-Object {
  if ($_.HealthStatus -ne 'Healthy') { Warn "$($_.FriendlyName): $($_.HealthStatus)" }
  else { Ok "$($_.FriendlyName): Healthy" }
}

Hdr "Akku"
$b = Get-CimInstance Win32_Battery
if ($b) { Info "Ladestand: $($b.EstimatedChargeRemaining) %" } else { Info "Kein Akku erkannt" }

Hdr "Top-5 Prozesse (CPU-Zeit)"
Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 |
  ForEach-Object { Info ("{0,-25} {1,8:N0} MB" -f $_.ProcessName, ($_.WorkingSet64 / 1MB)) }

Hdr "Fehler in der Ereignisanzeige (letzte 24h)"
$since = (Get-Date).AddHours(-24)
foreach ($log in 'System', 'Application') {
  $ev = Get-WinEvent -FilterHashtable @{LogName = $log; Level = 1, 2; StartTime = $since } -MaxEvents 200
  # Bekannte harmlose Ereignisse ausblenden: DistributedCOM 10016 (COM-Berechtigungen)
  $noise = @($ev | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-DistributedCOM' -and $_.Id -eq 10016 })
  $ev = @($ev | Where-Object { -not ($_.ProviderName -eq 'Microsoft-Windows-DistributedCOM' -and $_.Id -eq 10016) })
  if ($noise.Count) { Info "$($noise.Count)x DistributedCOM 10016 ignoriert (harmlos)" }
  if ($ev.Count) {
    Warn "$log : $($ev.Count) Fehler:"
    $ev | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object {
      $first = $_.Group[0]
      $msg = ($first.Message -split "`r?`n")[0]
      if ($msg.Length -gt 110) { $msg = $msg.Substring(0, 110) + '...' }
      Info ("{0}x {1} (ID {2}): {3}" -f $_.Count, $first.ProviderName, $first.Id, $msg)
    }
  } else { Ok "$log : keine relevanten Fehler" }
}
$bsod = Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 41, 1001; StartTime = $since } -MaxEvents 5
if ($bsod) { Warn "Unerwarteter Neustart / Bluescreen in den letzten 24h" }

Hdr "Wichtige Dienste"
# Nur Dienste melden, die automatisch starten, NICHT verzoegert/triggerbasiert sind und dann trotzdem gestoppt sind.
# Windows markiert verzoegerte Starts in der Registry (DelayedAutostart) und Trigger-Starts im Unterschluessel TriggerInfo.
$noise = 'sppsvc|gupdate|GoogleUpdater|edgeupdate|MapsBroker|RemoteRegistry|TrustedInstaller|WMPNetworkSvc|SonosLibrary|HPDiag|HPAppHelper|CDPUserSvc|OneSyncSvc|wuauserv|BITS'
Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" | ForEach-Object {
  $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.Name)"
  $delayed = (Get-ItemProperty $key -Name DelayedAutostart).DelayedAutostart -eq 1
  $trigger = Test-Path "$key\TriggerInfo"
  if (-not $delayed -and -not $trigger -and $_.Name -notmatch $noise -and $_.ExitCode -ne 0) {
    Warn "Dienst gestoppt (ExitCode $($_.ExitCode)): $($_.DisplayName)"
  }
}

Hdr "Netzwerk-Adapter"
Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object {
  Ok "$($_.Name) ($($_.LinkSpeed))"
}
if (-not (Get-NetAdapter | Where-Object Status -eq 'Up')) { Warn "Kein aktiver Netzwerkadapter" }

Hdr "Gateway"
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop
if (-not $gw) { Warn "Kein Standard-Gateway" }
elseif (Test-Connection $gw -Count 2 -Quiet) { Ok "Gateway $gw erreichbar" }
else { Warn "Gateway $gw antwortet nicht (WLAN/Router pruefen)" }

Hdr "Internet (IP-Ebene)"
foreach ($ip in '1.1.1.1', '8.8.8.8') {
  if (Test-Connection $ip -Count 3 -Quiet) { Ok "$ip erreichbar" } else { Warn "$ip nicht erreichbar" }
}

Hdr "DNS"
foreach ($h in 'google.com', 'cloudflare.com', 'github.com') {
  if (Resolve-DnsName $h -DnsOnly -QuickTimeout) { Ok "DNS loest $h auf" } else { Warn "DNS kann $h nicht aufloesen" }
}
Info ("DNS-Server: " + ((Get-DnsClientServerAddress -AddressFamily IPv4).ServerAddresses | Sort-Object -Unique) -join ', ')

Hdr "HTTP/HTTPS"
foreach ($u in 'https://www.google.com', 'https://github.com') {
  try {
    $t = Measure-Command { $r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 8 }
    Ok ("{0} -> {1} ({2:N0} ms)" -f $u, $r.StatusCode, $t.TotalMilliseconds)
  } catch { Warn "$u -> Fehler/Timeout" }
}

Hdr "Latenz / Paketverlust (20 Pings an 1.1.1.1)"
$pings = Test-Connection 1.1.1.1 -Count 20
$ok = @($pings | Where-Object { $_.StatusCode -eq 0 -or $_.Status -eq 'Success' }).Count
$loss = [math]::Round((20 - $ok) / 20 * 100)
Info "Verlust: $loss %"
if ($loss -gt 2) { Warn "Paketverlust ueber 2 %" }

Hdr "Windows-Updates / Neustart ausstehend"
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { Warn "Neustart fuer Updates ausstehend" } else { Ok "Kein Neustart ausstehend" }

Hdr "Ergebnis"
if ($script:Problems -eq 0) { Write-Host "  Alles in Ordnung - keine Probleme gefunden." -ForegroundColor Green }
else { Write-Host "  $($script:Problems) Warnung(en) gefunden - siehe [WARN]-Zeilen oben." -ForegroundColor Yellow }
