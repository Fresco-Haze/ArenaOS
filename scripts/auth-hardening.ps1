$ErrorActionPreference = 'Stop'
$exe  = (cabal list-bin exe:arenaos-api).Trim()
$port = 3200
$db   = Join-Path $env:TEMP 'arenaos-auth-test.db'
Remove-Item $db, "$db-wal", "$db-shm" -ErrorAction SilentlyContinue

$keys = 'PORT','ARENAOS_DB','ARENAOS_TOKEN_TTL_SECONDS','ARENAOS_RATE_LIMIT'
$old = @{}; foreach ($k in $keys) { $old[$k] = (Get-Item "Env:$k" -ErrorAction SilentlyContinue).Value }
$env:PORT = "$port"; $env:ARENAOS_DB = $db
$env:ARENAOS_TOKEN_TTL_SECONDS = '10'; $env:ARENAOS_RATE_LIMIT = 'on'
$srv = Start-Process $exe -PassThru -WindowStyle Hidden
foreach ($k in $keys) { if ($null -eq $old[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue } else { Set-Item "Env:$k" $old[$k] } }

$base = "http://127.0.0.1:$port"; $pass = 0; $fail = 0
function Req($method, $path, $json, $token) {
  $a = @('-s','-o',"$env:TEMP\ah-body.txt",'-D',"$env:TEMP\ah-hdr.txt",'-w','%{http_code}','-X',$method,"$base$path",'-H','Content-Type: application/json')
  if ($token) { $a += @('-H',"Authorization: Bearer $token") }
  if ($json)  { Set-Content "$env:TEMP\ah-req.json" $json -NoNewline; $a += @('-d',"@$env:TEMP\ah-req.json") }
  $code = [int](& curl.exe @a)
  [pscustomobject]@{ Code = $code; Body = (Get-Content "$env:TEMP\ah-body.txt" -Raw); Headers = (Get-Content "$env:TEMP\ah-hdr.txt" -Raw) }
}
function Check($name, $cond) { if ($cond) { $script:pass++; "  PASS $name" } else { $script:fail++; "  FAIL $name" } }

try {
  for ($i = 0; $i -lt 50; $i++) { try { if ((Req GET '/health').Code -eq 200) { break } } catch {}; Start-Sleep -Milliseconds 200 }
  Check 'register alice' ((Req POST '/register' '{"username":"alice","email":"a@x.com","password":"correcthorse"}').Code -eq 201)
  Check 'register bob'   ((Req POST '/register' '{"username":"bob","email":"b@x.com","password":"correcthorse"}').Code -eq 201)
  $l = Req POST '/login' '{"username":"alice","password":"correcthorse"}'
  Check 'login ok' ($l.Code -eq 200)
  $tok = ($l.Body | ConvertFrom-Json).token
  Check 'token works' ((Req GET '/me/tournaments' $null $tok).Code -eq 200)
  Start-Sleep -Seconds 11
  Check 'token expired after TTL' ((Req GET '/me/tournaments' $null $tok).Code -eq 401)
  $codes = 1..5 | ForEach-Object { (Req POST '/login' '{"username":"alice","password":"wrongpass1"}').Code }
  Check '5 bad logins -> 401' ((($codes | Sort-Object -Unique) -join ',') -eq '401')
  $r6 = Req POST '/login' '{"username":"alice","password":"wrongpass1"}'
  Check '6th -> 429' ($r6.Code -eq 429)
  Check 'Retry-After header present' ($r6.Headers -match '(?im)^retry-after:\s*\d+')
  Check 'locked even with correct password' ((Req POST '/login' '{"username":"alice","password":"correcthorse"}').Code -eq 429)
  Check 'other user unaffected' ((Req POST '/login' '{"username":"bob","password":"correcthorse"}').Code -eq 200)
  Check 'register dave' ((Req POST '/register' '{"username":"dave","email":"d@x.com","password":"correcthorse"}').Code -eq 201)
  $dl = Req POST '/login' '{"username":"dave","password":"correcthorse"}'
  $dtok = ($dl.Body | ConvertFrom-Json).token
  $pc = 1..5 | ForEach-Object { (Req POST '/me/password' '{"currentPassword":"wrongpass1","newPassword":"newpassword1"}' $dtok).Code }
  Check '5 wrong current passwords -> 400' ((($pc | Sort-Object -Unique) -join ',') -eq '400')
  $p6 = Req POST '/me/password' '{"currentPassword":"wrongpass1","newPassword":"newpassword1"}' $dtok
  Check 'password change 6th wrong -> 429' ($p6.Code -eq 429)
  Check 'password change Retry-After present' ($p6.Headers -match '(?im)^retry-after:\s*\d+')
  Check 'password change locked even with correct current password' ((Req POST '/me/password' '{"currentPassword":"correcthorse","newPassword":"newpassword1"}' $dtok).Code -eq 429)
  $first429 = 0
  foreach ($i in 1..31) {
    $c = (Req POST '/login' ('{"username":"flood' + $i + '","password":"wrongpass1"}')).Code
    if ($c -eq 429) { $first429 = $i; break }
  }
  Check "per-IP limit trips between 20 and 31 failures (tripped at $first429)" ($first429 -ge 20 -and $first429 -le 31)
} finally {
  Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
}
"$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
