$base = "http://localhost:3000"
$ErrorActionPreference = "Stop"

function Call($method, $path, $token, $body) {
  $p = @{ Method = $method; Uri = "$base$path"; ContentType = "application/json" }
  if ($token) { $p.Headers = @{ Authorization = "Bearer $token" } }
  if ($body)  { $p.Body = $body }
  try { Invoke-RestMethod @p }
  catch { Write-Host "FAILED: $method $path" -ForegroundColor Red; Write-Host $_.ErrorDetails.Message; throw }
}

function New-Tournament($token, $name, $visibility, $max) {
  $b = @{ name = $name; organizer = "ArenaOS Demo"; format = "SingleElimination";
          visibility = $visibility; maxParticipants = $max } | ConvertTo-Json
  (Call Post "/tournaments" $token $b).tournamentId
}
function Open-Reg($token, $tid) {
  Call Post "/tournaments/$tid/publish" $token | Out-Null
  Call Post "/tournaments/$tid/open-registration" $token | Out-Null
}
function Add-Players($token, $tid, $names) {
  foreach ($n in $names) {
    Call Post "/tournaments/$tid/registrations" $token (@{ type = "Individual"; player = $n } | ConvertTo-Json) | Out-Null
  }
}
function Get-Scheduled($token, $tid) {
  $b = Call Get "/tournaments/$tid/bracket" $token
  @($b.nodes | Where-Object { $_.match -and $_.match.status -eq "Scheduled" } | ForEach-Object { $_.match })
}
function Play-Match($token, $mid, $side) {
  Call Post "/matches/$mid/start" $token | Out-Null
  Call Post "/matches/$mid/result" $token (@{ type = "Winner"; winner = $side } | ConvertTo-Json) | Out-Null
}
function Start-Bracket($token, $tid) {
  Call Post "/tournaments/$tid/close-registration" $token | Out-Null
  Call Post "/tournaments/$tid/bracket" $token | Out-Null
}

$tok = (Call Post "/login" $null '{"username":"organizer","password":"password123"}').token

# 1. A Draft, visible only to its owner
$t1 = New-Tournament $tok "Nairobi Open" "Public" 8

# 2. Registration open, three players in
$t2 = New-Tournament $tok "Kenyatta Cup" "Public" 8
Open-Reg $tok $t2
Add-Players $tok $t2 @("Wanjiku", "Otieno", "Kamau")

# 3. In progress: one semifinal done, the other under way
$t3 = New-Tournament $tok "KU Champions League" "Public" 4
Open-Reg $tok $t3
Add-Players $tok $t3 @("Amina", "Brian", "Chebet", "Dennis")
Start-Bracket $tok $t3
Call Post "/tournaments/$t3/start" $tok | Out-Null
$open = Get-Scheduled $tok $t3
Play-Match $tok $open[0].matchId "B"
Call Post "/matches/$($open[1].matchId)/start" $tok | Out-Null

# 4. Completed
$t4 = New-Tournament $tok "Grand Final Night" "Public" 4
Open-Reg $tok $t4
Add-Players $tok $t4 @("Esther", "Felix", "Grace", "Hassan")
Start-Bracket $tok $t4
while ($true) {
  $m = Get-Scheduled $tok $t4
  if ($m.Count -eq 0) { break }
  foreach ($x in $m) { Play-Match $tok $x.matchId "A" }
}
Call Post "/tournaments/$t4/start" $tok | Out-Null
Call Post "/tournaments/$t4/complete" $tok | Out-Null

# 5. A private draft
$t5 = New-Tournament $tok "Private Scrim" "Private" 4

Write-Host "Seeded tournaments: $t1 $t2 $t3 $t4 $t5"