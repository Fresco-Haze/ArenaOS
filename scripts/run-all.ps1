param(
  [string]$Base = 'http://localhost:3000',
  [string[]]$Only = @(),      # e.g. -Only de,squad  (matches the part after "e2e-")
  [switch]$StopOnFail,        # stop at the first script that fails
  [switch]$WithUnit           # also run `cabal test` at the end
)
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot
$logDir = Join-Path $dir 'logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# name, file, what it covers
$suite = @(
  @('core',      'e2e.ps1',           'auth, create, single elim, corrections, persistence'),
  @('rr',        'e2e-rr.ps1',        'round robin: standings, completion'),
  @('de',        'e2e-de.ps1',        'double elim, 4 players: reset, GF1 correction'),
  @('de6',       'e2e-de6.ps1',       'double elim, 6 players: bye pass-through'),
  @('de5',       'e2e-de5.ps1',       'double elim, 5 players: two pass-throughs'),
  @('3p',        'e2e-3p.ps1',        'third-place match'),
  @('ef',        'e2e-ef.ps1',        'eFootball score corrections'),
  @('lifecycle', 'e2e-lifecycle.ps1', 'pause, resume, reopen, cancel, ownership'),
  @('squad',     'e2e-squad.ps1',     'teams, squad registration, play-through')
)
if ($Only.Count -gt 0) { $suite = @($suite | Where-Object { $Only -contains $_[0] }) }
if ($suite.Count -eq 0) { Write-Host 'No scripts match -Only.' -ForegroundColor Red; exit 2 }

# Scripts on disk that the runner does not know about
$known = $suite | ForEach-Object { $_[1] }
Get-ChildItem $dir -Filter 'e2e*.ps1' | Where-Object { $_.Name -notin $known -and $_.Name -ne 'run-all.ps1' } |
  ForEach-Object { Write-Host "NOTE  $($_.Name) exists but is not in the suite list" -ForegroundColor Yellow }

# Backend must be up
try {
  $h = Invoke-RestMethod "$Base/health" -TimeoutSec 5
  if ($h.status -ne 'ok') { throw 'unexpected body' }
} catch {
  Write-Host "Backend not reachable at $Base. Start it with: cabal run arenaos-api" -ForegroundColor Red
  exit 2
}
Write-Host "Backend OK at $Base. Running $($suite.Count) script(s). Logs: $logDir`n" -ForegroundColor Cyan

$rows = @()
$overall = [Diagnostics.Stopwatch]::StartNew()
foreach ($s in $suite) {
  $name = $s[0]; $file = Join-Path $dir $s[1]
  if (-not (Test-Path $file)) {
    Write-Host ("{0,-10} MISSING  {1}" -f $name, $s[1]) -ForegroundColor Red
    $rows += [pscustomobject]@{Name=$name;Pass=0;Fail=0;Secs=0;Status='MISSING'}
    if ($StopOnFail) { break } else { continue }
  }
  $log = Join-Path $logDir "$stamp-$name.log"
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $file -Base $Base 2>&1 | ForEach-Object { "$_" }
  $code = $LASTEXITCODE
  $sw.Stop()
  $out | Set-Content $log -Encoding UTF8

  $pass = 0; $fail = 0; $parsed = $false
  $sum = $out | Where-Object { $_ -match '^\s*Passed\s+(\d+)\s+Failed\s+(\d+)' } | Select-Object -Last 1
  if ($sum -match 'Passed\s+(\d+)\s+Failed\s+(\d+)') { $pass = [int]$Matches[1]; $fail = [int]$Matches[2]; $parsed = $true }

  # Green only if it exited 0, printed a summary, and recorded zero failures
  $ok = ($code -eq 0) -and $parsed -and ($fail -eq 0)
  $status = if ($ok) { 'PASS' } elseif (-not $parsed) { 'NO RESULT' } else { 'FAIL' }
  $color = if ($ok) { 'Green' } else { 'Red' }
  Write-Host ("{0,-10} {1,-9} passed {2,4}  failed {3,3}  {4,5:N1}s   {5}" -f $name, $status, $pass, $fail, $sw.Elapsed.TotalSeconds, $s[2]) -ForegroundColor $color
  if (-not $ok) {
    $out | Where-Object { $_ -match '^\s*FAIL\s' } | ForEach-Object { Write-Host "    $($_.Trim())" -ForegroundColor Red }
    if (-not $parsed) { Write-Host "    no 'Passed N Failed M' line; last output:" -ForegroundColor Red; $out | Select-Object -Last 4 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red } }
    Write-Host "    full log: $log" -ForegroundColor DarkGray
  }
  $rows += [pscustomobject]@{Name=$name;Pass=$pass;Fail=$fail;Secs=$sw.Elapsed.TotalSeconds;Status=$status}
  if ((-not $ok) -and $StopOnFail) { Write-Host "`nStopping at first failure (-StopOnFail)." -ForegroundColor Yellow; break }
}

$unitOk = $null
if ($WithUnit) {
  Write-Host "`ncabal test ..." -ForegroundColor Cyan
  $u = & cabal test 2>&1 | ForEach-Object { "$_" }
  $u | Set-Content (Join-Path $logDir "$stamp-unit.log") -Encoding UTF8
  $line = $u | Where-Object { $_ -match '\d+ examples?, \d+ failures?' } | Select-Object -Last 1
  $unitOk = ($line -match ' 0 failures')
  Write-Host ("unit       {0}  {1}" -f $(if($unitOk){'PASS'}else{'FAIL'}), $line) -ForegroundColor $(if($unitOk){'Green'}else{'Red'})
}

$overall.Stop()
$bad = @($rows | Where-Object { $_.Status -ne 'PASS' })
$tp = ($rows | Measure-Object Pass -Sum).Sum; $tf = ($rows | Measure-Object Fail -Sum).Sum
Write-Host ("`n{0} script(s), {1} checks passed, {2} failed, {3:N0}s total." -f $rows.Count, $tp, $tf, $overall.Elapsed.TotalSeconds)
$allGood = ($bad.Count -eq 0) -and ($null -eq $unitOk -or $unitOk)
if ($allGood) { Write-Host 'ALL GREEN' -ForegroundColor Green; exit 0 }
else { Write-Host 'NOT GREEN' -ForegroundColor Red; exit 1 }
