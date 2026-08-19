# register-serge-tasks.ps1 — native-Windows replacements for the two most
# useful systemd units, via Task Scheduler:
#   "Serge router"          — LiteLLM proxy at logon (KeepAlive-ish: restarts at next logon)
#   "Serge budget watchdog" — budget-watchdog.sh every 5 minutes
# Both run through Git Bash so router.env is sourced exactly like on Linux.
# Run from a regular (non-admin) PowerShell. Remove with:
#   schtasks /Delete /TN "Serge router" /F
#   schtasks /Delete /TN "Serge budget watchdog" /F

$ErrorActionPreference = 'Stop'

# Locate Git Bash
$bash = @(
  "$env:ProgramFiles\Git\bin\bash.exe",
  "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
  "$env:LocalAppData\Programs\Git\bin\bash.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bash) { throw "Git Bash not found - install Git for Windows first." }

Write-Host "Using Git Bash: $bash"

# Router: source router.env, exec litellm (same command as the Linux service).
$routerCmd = 'set -a; [ -f ~/.serge/router.env ] && . ~/.serge/router.env; set +a; exec ~/.local/bin/litellm --config ~/.serge/litellm.yaml --port 4000 >> ~/.serge/monitor/router.log 2>&1'
schtasks /Create /F /TN "Serge router" /SC ONLOGON /TR "`"$bash`" -lc `"$routerCmd`"" | Out-Null
Write-Host 'Registered: "Serge router" (at logon)'

# Budget watchdog: every 5 minutes, $10/day cap (matches the systemd drop-in).
$wdCmd = 'SERGE_DAILY_CAP_USD=10 ~/.serge/budget-watchdog.sh >> ~/.serge/monitor/budget-watchdog.log 2>&1'
schtasks /Create /F /TN "Serge budget watchdog" /SC MINUTE /MO 5 /TR "`"$bash`" -lc `"$wdCmd`"" | Out-Null
Write-Host 'Registered: "Serge budget watchdog" (every 5 min)'

# Start the router now rather than waiting for next logon.
schtasks /Run /TN "Serge router" | Out-Null
Write-Host 'Router task started. Check:  curl -s localhost:4000/v1/models'
