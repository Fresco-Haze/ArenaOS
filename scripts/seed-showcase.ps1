param([string]$Base='http://localhost:3000', [string]$Web='http://localhost:5173')
$ErrorActionPreference = 'Stop'

function Api($Method, $Path, $Body = $null, $Token = $null) {
  $h = @{}
  if ($Token) { $h.Authorization = "Bearer $Token" }
  $p = @{ Uri = "$Base$Path"; Method = $Method; Headers = $h; UseBasicParsing = $true }
  if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 10 -Compress); $p.ContentType = 'application/json' }
  try { $r = Invoke-WebRequest @p }
  catch {
    $code = 0
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    throw "$Method $Path failed ($code): $($_.ErrorDetails.Message)"
  }
  Start-Sleep -Milliseconds 120
  if ($r.Content) { try { return ($r.Content | ConvertFrom-Json) } catch { return $null } }
  return $null
}

$pool = 'NairobiNinja','SavannaSniper','KilimanjaroKid','MombasaMamba','NakuruNova','RiftValleyRush','LakesideLegend','BuruburuBlaze','WestieWolf','KarenKnight','MaasaiMarauder','TuskerTitan','SafariStorm','CoastalCrusher','HighlandHawk','DuskOwl'

# Deleted-free order: elimination first, double elimination last
$plan = @(
  @{ name='Friday Night Showdown'; game='eFootball';       format='SingleElimination'; n=8; prize=3000; seed=11 },
  @{ name='Weekend Warriors Cup'; game='Call of Duty';    format='SingleElimination'; n=8; prize=2000; seed=22 },
  @{ name='Campus Clash';         game='Chess';           format='SingleElimination'; n=8; prize=1000; seed=33 },
  @{ name='Sunday League';        game='EA Sports FC';    format='RoundRobin';        n=6; prize=1500; seed=44 },
  @{ name='Midweek Masters';      game='PUBG Mobile';     format='RoundRobin';        n=6; prize=2500; seed=55 },
  @{ name='Nairobi Open';         game='Mortal Kombat 1'; format='DoubleElimination'; n=6; prize=5000; seed=66 }
)

Write-Host "Target: $Base"
if ($Base -notmatch 'localhost|127\.0\.0\.1') {
  $c = Read-Host "This will WRITE to $Base. Type PRODUCTION to continue"
  if ($c -ne 'PRODUCTION') { "Cancelled."; return }
}
Api GET '/health' | Out-Null

$gl = @(Api GET '/games')
$known = @($gl | ForEach-Object { if ($_.name) { $_.name } else { "$_" } })
foreach ($t in $plan) { if ($known -notcontains $t.game) { throw "Game not found on target: $($t.game)" } }

$user = 'sweatlobby_events'
$email = Read-Host 'Organizer email (a real inbox you control)'
$sec = Read-Host 'Organizer password (hidden; 10+ chars, upper, lower, digit, symbol)' -AsSecureString
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
try { Api POST '/register' @{ username = $user; email = $email; password = $pw } | Out-Null; Write-Host "registered $user" }
catch { Write-Host "register skipped ($_) - trying login" }
$tok = (Api POST '/login' @{ username = $user; password = $pw }).token
if (-not $tok) { throw 'No token from login' }

$mine = ConvertTo-Json -InputObject (Api GET '/me/tournaments' $null $tok) -Depth 10 -Compress
$results = @()
foreach ($t in $plan) {
  if ($mine -like ('*"name":"' + $t.name + '"*')) { Write-Host "skip (already exists): $($t.name)"; continue }
  $rng = New-Object System.Random($t.seed)
  $players = @($pool | Sort-Object { $rng.Next() } | Select-Object -First $t.n)   # index 0 = strongest

  $body = @{ name = $t.name; organizer = 'SweatLobby Events'; format = $t.format; visibility = 'Public'; maxParticipants = $t.n; participantMode = 'IndividualOnly'; game = $t.game; prize = $t.prize }
  if ($t.format -eq 'SingleElimination') { $body.thirdPlaceMatch = $false }
  $tid = (Api POST '/tournaments' $body $tok).tournamentId
  if (-not $tid) { throw "No tournament id for $($t.name)" }
  Write-Host "created #$tid $($t.name)"

  Api POST "/tournaments/$tid/publish" $null $tok | Out-Null
  Api POST "/tournaments/$tid/open-registration" $null $tok | Out-Null
  foreach ($pn in $players) { Api POST "/tournaments/$tid/registrations" @{ type = 'Individual'; player = $pn } $tok | Out-Null }
  Api POST "/tournaments/$tid/close-registration" $null $tok | Out-Null
  Api POST "/tournaments/$tid/bracket" $null $tok | Out-Null
  Api POST "/tournaments/$tid/start" $null $tok | Out-Null

  $played = 0
  for ($guard = 0; $guard -lt 80; $guard++) {
    $b = Api GET "/tournaments/$tid/bracket" $null $tok
    $todo = @($b.nodes | Where-Object { $_.match -and $_.match.status -eq 'Scheduled' } | Sort-Object round, nodeId)
    if ($todo.Count -eq 0) { break }
    $m = $todo[0].match
    $ia = [Array]::IndexOf([string[]]$players, [string]$m.competitorA.player)
    $ib = [Array]::IndexOf([string[]]$players, [string]$m.competitorB.player)
    $aStronger = ($ia -lt $ib)
    Api POST "/matches/$($m.matchId)/start" $null $tok | Out-Null
    if ($t.format -eq 'RoundRobin') {
      $w = $rng.Next(1, 4); $l = $rng.Next(0, $w)
      if ($aStronger) { $sa = $w; $sb = $l } else { $sa = $l; $sb = $w }
      Api POST "/matches/$($m.matchId)/efootball-result" @{ scoreA = $sa; scoreB = $sb } $tok | Out-Null
    } else {
      $upset = ($rng.NextDouble() -lt 0.25)
      if ($aStronger -xor $upset) { $side = 'A' } else { $side = 'B' }
      Api POST "/matches/$($m.matchId)/result" @{ type = 'Winner'; winner = $side } $tok | Out-Null
    }
    $played++
  }

  $v = Api GET "/tournaments/$tid" $null $tok
  if ($v.tournament.state -ne 'Completed') { Api POST "/tournaments/$tid/complete" $null $tok | Out-Null; $v = Api GET "/tournaments/$tid" $null $tok }
  $line = "{0} | {1} | matches played: {2} | state: {3} | {4}/tournaments/{5}" -f $t.name, $t.game, $played, $v.tournament.state, $Web, $tid
  Write-Host $line
  $results += $line
}
$results | Set-Clipboard
"Done. $($results.Count) created. Summary copied to clipboard."