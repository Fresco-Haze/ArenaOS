param([string]$Base='http://localhost:3000')
$ErrorActionPreference='Stop'
$script:pass=0; $script:fail=0
function Stage($t){ Write-Host "`n== $t" -ForegroundColor Cyan }
function Check($name,$ok,$detail=''){
  if($ok){ $script:pass++; Write-Host "  PASS  $name" -ForegroundColor Green }
  else   { $script:fail++; Write-Host "  FAIL  $name  $detail" -ForegroundColor Red }
}
function Done {
  $c = if($script:fail){'Red'}else{'Green'}
  Write-Host "`nPassed $($script:pass)  Failed $($script:fail)" -ForegroundColor $c
  exit ([int]($script:fail -gt 0))
}
function Call($Method,$Path,$Body=$null,$Token=$null){
  $h=@{}; if($Token){ $h.Authorization="Bearer $Token" }
  $p=@{Uri="$Base$Path";Method=$Method;Headers=$h;UseBasicParsing=$true}
  if($null -ne $Body){ $p.Body=($Body|ConvertTo-Json -Depth 10 -Compress); $p.ContentType='application/json' }
  try { $r=Invoke-WebRequest @p; $status=[int]$r.StatusCode; $text=$r.Content }
  catch {
    $resp=$_.Exception.Response
    if(-not $resp){ return [pscustomobject]@{Status=0;Json=$null;Raw=$_.Exception.Message} }
    $status=[int]$resp.StatusCode
    $text=$_.ErrorDetails.Message
    if(-not $text){ try{ $text=(New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() }catch{} }
  }
  $json=$null; if($text){ try{ $json=$text|ConvertFrom-Json }catch{} }
  [pscustomobject]@{Status=$status;Json=$json;Raw=$text}
}
function Code($r){ if($r.Json -and $r.Json.error){ $r.Json.error.code } else { '' } }
function Expect($name,$r,$status,$code=''){
  $ok = ($r.Status -eq $status) -and ($code -eq '' -or (Code $r) -eq $code)
  Check $name $ok "got $($r.Status) $(Code $r) $($r.Raw)"
}

Stage '1 Setup'
$r=Call GET '/health'; Expect 'backend reachable' $r 200
if($r.Status -ne 200){ exit 1 }
$id=Get-Random -Maximum 999999; $user="rr_$id"; $pw='Passw0rd!rr'
Expect 'register' (Call POST '/register' @{username=$user;email="$user@example.com";password=$pw}) 201
$tok=(Call POST '/login' @{username=$user;password=$pw}).Json.token
$r=Call POST '/tournaments' @{name="RR $id";organizer='E2E Runner';format='RoundRobin';visibility='Public';maxParticipants=4;participantMode='IndividualOnly'} $tok
Expect 'create RoundRobin tournament' $r 201
$tid=$r.Json.tournamentId
$v=Call GET "/tournaments/$tid" $null $tok
Check 'format is RoundRobin' ($v.Json.tournament.format -eq 'RoundRobin') $v.Json.tournament.format
Check 'thirdPlaceMatch is false' ($v.Json.tournament.thirdPlaceMatch -eq $false)
Expect 'publish' (Call POST "/tournaments/$tid/publish" $null $tok) 204
Expect 'open registration' (Call POST "/tournaments/$tid/open-registration" $null $tok) 204
foreach($n in 'Ayo','Bela','Chidi','Dara'){
  Expect "register $n" (Call POST "/tournaments/$tid/registrations" @{type='Individual';player=$n} $tok) 201
}
Expect 'close registration' (Call POST "/tournaments/$tid/close-registration" $null $tok) 204
Expect 'generate bracket' (Call POST "/tournaments/$tid/bracket" $null $tok) 201

Stage '2 Bracket shape'
$b=Call GET "/tournaments/$tid/bracket" $null $tok
Expect 'read bracket' $b 200
$nodes=@($b.Json.nodes)
Check 'format RoundRobin' ($b.Json.format -eq 'RoundRobin')
Check '6 nodes (4 choose 2)' ($nodes.Count -eq 6) "$($nodes.Count)"
Check 'every node has a match' (@($nodes | Where-Object { $_.match }).Count -eq 6)
Check 'no third-place / grand-final / reset node' (($null -eq $b.Json.thirdPlaceNodeId) -and ($null -eq $b.Json.grandFinalNodeId) -and ($null -eq $b.Json.resetNodeId))
Check 'all stages are Winners or Losers' (@($nodes | Where-Object { $_.stage -notin 'Winners','Losers' }).Count -eq 0)
$pairs=@($nodes | ForEach-Object { (@($_.match.competitorA.player,$_.match.competitorB.player) | Sort-Object) -join '|' } | Sort-Object -Unique)
Check 'all 6 distinct pairings present' ($pairs.Count -eq 6) ($pairs -join ' ')
Write-Host ("  INFO  stages: {0} | linksAvailable: {1} | nodes with winnerTo: {2}" -f ((@($nodes.stage) | Sort-Object -Unique) -join ','), $b.Json.linksAvailable, @($nodes | Where-Object { $_.winnerTo }).Count) -ForegroundColor Yellow
$st=@($b.Json.standings)
Check 'standings present before any result' ($st.Count -eq 4) "$($st.Count)"
Check 'all points 0 at start' (@($st | Where-Object { $_.points -ne 0 }).Count -eq 0)
Check 'unscoredMatches is 0' ($b.Json.unscoredMatches -eq 0)

Stage '3 Play the matches'
Expect 'start tournament' (Call POST "/tournaments/$tid/start" $null $tok) 204
$goals=@{
  'Ayo|Bela'  =@{Ayo=3;Bela=0}
  'Ayo|Chidi' =@{Ayo=2;Chidi=2}
  'Ayo|Dara'  =@{Ayo=1;Dara=0}
  'Bela|Chidi'=@{Bela=2;Chidi=1}
  'Bela|Dara' =@{Bela=1;Dara=1}
  'Chidi|Dara'=@{Chidi=4;Dara=0}
}
$ordered=@($nodes | Sort-Object nodeId)
$firstMid=$null
for($i=0;$i -lt $ordered.Count;$i++){
  $m=$ordered[$i].match; $mid=$m.matchId
  $a=$m.competitorA.player; $bn=$m.competitorB.player
  $key=(@($a,$bn) | Sort-Object) -join '|'
  $g=$goals[$key]
  Expect "start $key" (Call POST "/matches/$mid/start" $null $tok) 200
  $r=Call POST "/matches/$mid/efootball-result" @{scoreA=$g[$a];scoreB=$g[$bn]} $tok
  Expect "score $key  $a $($g[$a]) - $($g[$bn]) $bn" $r 200
  $draw = $g[$a] -eq $g[$bn]
  Check "  outcome type correct for $key" ($r.Json.outcome.type -eq $(if($draw){'Draw'}else{'Winner'})) "$($r.Json.outcome.type)"
  if($i -eq 0){ $firstMid=$mid }
  if($i -eq 4){
    Expect 'complete with 1 match left refused' (Call POST "/tournaments/$tid/complete" $null $tok) 409 'TOURNAMENT_NOT_COMPLETE'
    Expect 'correcting a round-robin score refused' (Call PUT "/matches/$firstMid/efootball-result" @{scoreA=0;scoreB=0} $tok) 409 'CORRECTION_UNSUPPORTED_FORMAT'
  }
}

Stage '4 Standings'
$b=Call GET "/tournaments/$tid/bracket" $null $tok
$st=@($b.Json.standings)
$want=@(
  @{n='Ayo';  p=7;gf=6;ga=2;gd=4},
  @{n='Chidi';p=4;gf=7;ga=4;gd=3},
  @{n='Bela'; p=4;gf=3;ga=5;gd=-2},
  @{n='Dara'; p=1;gf=1;ga=6;gd=-5}
)
Check '4 rows' ($st.Count -eq 4)
for($i=0;$i -lt 4;$i++){
  $w=$want[$i]; $row=$st[$i]
  Check ("rank {0} is {1}" -f ($i+1),$w.n) ($row.participant.player -eq $w.n) "got $($row.participant.player)"
  Check ("  {0}: pts {1} GF {2} GA {3} GD {4}" -f $w.n,$w.p,$w.gf,$w.ga,$w.gd) (($row.points -eq $w.p) -and ($row.goalsFor -eq $w.gf) -and ($row.goalsAgainst -eq $w.ga) -and ($row.goalDifference -eq $w.gd)) ("got {0}/{1}/{2}/{3}" -f $row.points,$row.goalsFor,$row.goalsAgainst,$row.goalDifference)
}
Check 'unscoredMatches is 0' ($b.Json.unscoredMatches -eq 0) "$($b.Json.unscoredMatches)"
Check 'every node shows its score' (@($b.Json.nodes | Where-Object { -not $_.score }).Count -eq 0)

Stage '5 Complete'
$r=Call POST "/tournaments/$tid/complete" $null $tok
Expect 'complete tournament' $r 200
Check 'returned state Completed' ($r.Json.state -eq 'Completed') $r.Json.state
$v=Call GET "/tournaments/$tid" $null $tok
Check 'state persisted as Completed' ($v.Json.tournament.state -eq 'Completed')
Expect 'complete again refused' (Call POST "/tournaments/$tid/complete" $null $tok) 409 'TOURNAMENT_ALREADY_COMPLETED'
Done
