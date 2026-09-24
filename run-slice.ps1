$base = "http://localhost:3000"
$login = Invoke-RestMethod -Method Post -Uri "$base/login" -Body '{"username":"jae","password":"pw123"}' -ContentType "application/json"
$h = @{ "Authorization" = "Bearer $($login.token)" }

function Invoke-Api($path, $body) {
  try {
    if ($body) {
      Invoke-RestMethod -Method Post -Uri "$base$path" -Headers $h -Body $body -ContentType "application/json"
    } else {
      Invoke-RestMethod -Method Post -Uri "$base$path" -Headers $h
    }
  } catch {
    Write-Host "FAILED: POST $path" -ForegroundColor Red
    Write-Host $_.ErrorDetails.Message
    throw
  }
}

function Get-Bracket {
  Invoke-RestMethod -Uri "$base/tournaments/$tid/bracket" -Headers $h
}

$t = Invoke-Api "/tournaments" '{"name":"Script Cup","organizer":"Jae","format":"SingleElimination","visibility":"Public","maxParticipants":4}'
$tid = $t.tournamentId
Write-Host "Created tournament $tid"

Invoke-Api "/tournaments/$tid/publish" | Out-Null
Invoke-Api "/tournaments/$tid/open-registration" | Out-Null
foreach ($n in "Alice","Bob","Cara","Dan") {
  Invoke-Api "/tournaments/$tid/registrations" ('{"type":"Individual","player":"' + $n + '"}') | Out-Null
}
Invoke-Api "/tournaments/$tid/close-registration" | Out-Null
Invoke-Api "/tournaments/$tid/bracket" | Out-Null
Write-Host "Bracket generated"

while ($true) {
  $b = Get-Bracket
  $open = @($b.nodes | Where-Object { $_.match -and $_.match.status -eq "Scheduled" } | ForEach-Object { $_.match })
  if ($open.Count -eq 0) { break }
  foreach ($m in $open) {
    Invoke-Api "/matches/$($m.matchId)/start" | Out-Null
    Invoke-Api "/matches/$($m.matchId)/result" '{"type":"Winner","winner":"A"}' | Out-Null
    Write-Host ("Played match {0}: {1} beat {2}" -f $m.matchId, $m.competitorA.player, $m.competitorB.player)
  }
}

Write-Host ""
Write-Host "Final bracket:"
$b = Get-Bracket
foreach ($n in $b.nodes) {
  $m = $n.match
  if ($m) {
    $w = if ($m.outcome.winner -eq "A") { $m.competitorA.player } else { $m.competitorB.player }
    Write-Host ("  Round {0}: {1} vs {2}  ->  {3}" -f $n.round, $m.competitorA.player, $m.competitorB.player, $w)
  }
}