param([string]$Base='http://localhost:3000')
$ErrorActionPreference='Stop'
$script:pass=0; $script:fail=0
function Stage($t){ Write-Host "`n== $t" -ForegroundColor Cyan }
function Info($t){ Write-Host "  INFO  $t" -ForegroundColor Yellow }
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
  try { $res=Invoke-WebRequest @p; $status=[int]$res.StatusCode; $text=$res.Content }
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
function Code($x){ if($x.Json -and $x.Json.error){ $x.Json.error.code } else { '' } }
function Expect($name,$x,$status,$code=''){
  $ok = ($x.Status -eq $status) -and ($code -eq '' -or (Code $x) -eq $code)
  Check $name $ok "got $($x.Status) $(Code $x) $($x.Raw)"
}

function GetBr { Call GET "/tournaments/$script:tid/bracket" $null $tok }
function NodeOf($b,$nid){ @($b.Json.nodes | Where-Object { $_.nodeId -eq $nid })[0] }
function SlotAt($n,$pos){ if($pos -eq 'A'){ $n.slotA } else { $n.slotB } }
function Pname($slot){ if($slot.type -eq 'Filled'){ $slot.participant.player } else { "<$($slot.type)>" } }
function PairKey($m){ (@($m.competitorA.player,$m.competitorB.player) | Sort-Object) -join ',' }
function Holds($label,$nid,$pos,$name){
  $n=NodeOf (GetBr) $nid
  $got=Pname (SlotAt $n $pos)
  Check "$label slot $pos holds $name" ($got -eq $name) "got $got"
}
function MatchIs($label,$nid,$names,$status){
  $m=(NodeOf (GetBr) $nid).match
  if(-not $m){ Check "$label has a match" $false; return }
  $want=(@($names) | Sort-Object) -join ','
  Check "$label match is $status ($want)" (((PairKey $m) -eq $want) -and ($m.status -eq $status)) "got $(PairKey $m) $($m.status)"
}
function NoMatch($label,$nid){ Check "$label has no match yet" ($null -eq (NodeOf (GetBr) $nid).match) }
function LinkTo($n,$kind,$dest,$slots){
  $l=$n.$kind
  if($null -eq $l -or $null -eq $dest){ return $false }
  (($l.node -eq $dest.nodeId) -and ($slots -contains $l.slot))
}
function Play($label,$node,$want){
  $m=(NodeOf (GetBr) $node.nodeId).match
  if(-not $m){ Check "$label has a match to play" $false; return $null }
  $a=$m.competitorA.player; $c=$m.competitorB.player
  $side = if($want -eq 'A' -or $want -eq 'B'){ $want } elseif($want -eq $a){ 'A' } else { 'B' }
  Expect "$label start" (Call POST "/matches/$($m.matchId)/start" $null $tok) 200
  $res=Call POST "/matches/$($m.matchId)/result" @{type='Winner';winner=$side} $tok
  Expect "$label : $a vs $c, $side wins" $res 200
  $win = if($side -eq 'A'){ $a } else { $c }
  $los = if($side -eq 'A'){ $c } else { $a }
  [pscustomobject]@{mid=$m.matchId;winner=$win;loser=$los;a=$a;b=$c}
}
function LnkStr($l){ if($null -eq $l){ '-' } else { "$($l.node)$($l.slot)" } }
function Dump($b){
  foreach($nd in @($b.Json.nodes | Sort-Object round,nodeId)){
    Info ("{0,4} {1,-7} R{2} A={3,-16} B={4,-16} match={5,-5} W>{6,-6} L>{7}" -f $nd.nodeId,$nd.stage,$nd.round,(Pname $nd.slotA),(Pname $nd.slotB),[bool]$nd.match,(LnkStr $nd.winnerTo),(LnkStr $nd.loserTo))
  }
}
function Roles {
  $b=GetBr; $nn=@($b.Json.nodes)
  $tp=$b.Json.thirdPlaceNodeId
  $script:rl=@{
    b=$b
    semis=@($nn | Where-Object { $_.round -eq 1 } | Sort-Object nodeId)
    final=@($nn | Where-Object { $_.round -eq 2 -and $_.nodeId -ne $tp })[0]
    bronze=$(if($null -ne $tp){ NodeOf $b $tp } else { $null })
  }
  $h=$script:rl
  $script:rolesOk=[bool](($h.semis.Count -eq 2) -and $h.final -and $h.bronze)
}
function NewSE($label,$count,$tp){
  $resp=Call POST '/tournaments' @{name="3P $label $id";organizer='E2E Runner';format='SingleElimination';visibility='Public';maxParticipants=$count;thirdPlaceMatch=$tp} $tok
  Expect "[$label] create SingleElimination ($count players, thirdPlaceMatch=$tp)" $resp 201
  $script:tid=$resp.Json.tournamentId
  $tt=$script:tid
  Expect "[$label] publish" (Call POST "/tournaments/$tt/publish" $null $tok) 204
  Expect "[$label] open registration" (Call POST "/tournaments/$tt/open-registration" $null $tok) 204
  foreach($nm in @('Ayo','Bela','Chidi','Dara')[0..($count-1)]){
    Expect "[$label] register $nm" (Call POST "/tournaments/$tt/registrations" @{type='Individual';player=$nm} $tok) 201
  }
  Expect "[$label] close registration" (Call POST "/tournaments/$tt/close-registration" $null $tok) 204
  Expect "[$label] generate bracket" (Call POST "/tournaments/$tt/bracket" $null $tok) 201
  Expect "[$label] start tournament" (Call POST "/tournaments/$tt/start" $null $tok) 204
}

# ---------- Setup
Stage 'Setup'
$health=Call GET '/health'; Expect 'backend reachable' $health 200
if($health.Status -ne 200){ exit 1 }
$id=Get-Random -Maximum 999999; $user="tp_$id"; $pw='Passw0rd!tp'
Expect 'register' (Call POST '/register' @{username=$user;email="$user@example.com";password=$pw}) 201
$tok=(Call POST '/login' @{username=$user;password=$pw}).Json.token
Check 'got a token' ($tok -match '^[0-9a-f]{64}$')

# ---------- A: shape, routing, correction, guard, completion
Stage 'A1 Bracket shape (4 players, third-place on)'
NewSE 'A' 4 $true; Roles
Dump $script:rl.b
if(-not $script:rolesOk){ Check '[A] roles found (2 semis, final, bronze)' $false; Write-Host '  Shape differs from expectation. Paste the INFO dump above.' -ForegroundColor Red; Done }
$x=$script:rl; $b=$x.b; $nodes=@($b.Json.nodes)
$s0=$x.semis[0]; $s1=$x.semis[1]
Check '[A] 4 nodes' ($nodes.Count -eq 4) "$($nodes.Count)"
Check '[A] format SingleElimination, standings null, no grand final/reset' (($b.Json.format -eq 'SingleElimination') -and ($null -eq $b.Json.standings) -and ($null -eq $b.Json.grandFinalNodeId) -and ($null -eq $b.Json.resetNodeId))
Check '[A] thirdPlaceNodeId is set' ($null -ne $b.Json.thirdPlaceNodeId)
Check '[A] linksAvailable' ($b.Json.linksAvailable -eq $true)
Check '[A] only the 2 semifinals have matches at start' ((@($nodes | Where-Object { $_.match }).Count -eq 2) -and (@($x.semis | Where-Object { $_.match }).Count -eq 2))
Check '[A] semis: winners -> final (slots A,B)' ((LinkTo $s0 'winnerTo' $x.final @('A','B')) -and (LinkTo $s1 'winnerTo' $x.final @('A','B')) -and (((@($s0.winnerTo.slot,$s1.winnerTo.slot) | Sort-Object) -join ',') -eq 'A,B'))
Check '[A] semis: losers -> bronze (slots A,B)' ((LinkTo $s0 'loserTo' $x.bronze @('A','B')) -and (LinkTo $s1 'loserTo' $x.bronze @('A','B')) -and (((@($s0.loserTo.slot,$s1.loserTo.slot) | Sort-Object) -join ',') -eq 'A,B'))
Check '[A] final and bronze have no outgoing links' (($null -eq $x.final.winnerTo) -and ($null -eq $x.final.loserTo) -and ($null -eq $x.bronze.winnerTo) -and ($null -eq $x.bronze.loserTo))
Check '[A] final waits on winners, bronze waits on losers' (($x.final.slotA.type -eq 'AwaitingWinnerOf') -and ($x.final.slotB.type -eq 'AwaitingWinnerOf') -and ($x.bronze.slotA.type -eq 'AwaitingLoserOf') -and ($x.bronze.slotB.type -eq 'AwaitingLoserOf'))
Info "bronze node: stage $($x.bronze.stage), round $($x.bronze.round) (final round $($x.final.round))"
Expect '[A] toggling third-place after bracket exists is refused' (Call POST "/tournaments/$script:tid/third-place-match" @{thirdPlaceMatch=$false} $tok) 409
$tg=Call POST "/tournaments/$script:tid/third-place-match" @{thirdPlaceMatch=$false} $tok
Info "toggle after bracket returned $($tg.Status) '$(Code $tg)'"

Stage 'A2 Losers drop into bronze'
$p1=Play '[A] semi 1' $s0 'A'
Holds '[A] final' $x.final.nodeId $s0.winnerTo.slot $p1.winner
Holds '[A] bronze' $x.bronze.nodeId $s0.loserTo.slot $p1.loser
NoMatch '[A] final' $x.final.nodeId
NoMatch '[A] bronze' $x.bronze.nodeId
$p2=Play '[A] semi 2' $s1 'A'
Holds '[A] final' $x.final.nodeId $s1.winnerTo.slot $p2.winner
Holds '[A] bronze' $x.bronze.nodeId $s1.loserTo.slot $p2.loser
MatchIs '[A] final' $x.final.nodeId @($p1.winner,$p2.winner) 'Scheduled'
MatchIs '[A] bronze' $x.bronze.nodeId @($p1.loser,$p2.loser) 'Scheduled'

Stage 'A3 Correct semi 1: bronze takes the new loser'
$cr=Call PUT "/matches/$($p1.mid)/result" @{type='Winner';winner='B'} $tok
Expect '[A] correct semi 1 (B wins instead)' $cr 200
$t=$p1.winner; $p1.winner=$p1.loser; $p1.loser=$t
Holds '[A] final after correction' $x.final.nodeId $s0.winnerTo.slot $p1.winner
Holds '[A] bronze after correction' $x.bronze.nodeId $s0.loserTo.slot $p1.loser
MatchIs '[A] final after correction' $x.final.nodeId @($p1.winner,$p2.winner) 'Scheduled'
MatchIs '[A] bronze after correction' $x.bronze.nodeId @($p1.loser,$p2.loser) 'Scheduled'
Check '[A] corrected outcome persisted (winner B)' ((NodeOf (GetBr) $s0.nodeId).match.outcome.winner -eq 'B')

Stage 'A4 Guard: started bronze blocks correction'
$bm=(NodeOf (GetBr) $x.bronze.nodeId).match
Expect '[A] start bronze' (Call POST "/matches/$($bm.matchId)/start" $null $tok) 200
Expect '[A] correcting semi 1 after bronze started is refused' (Call PUT "/matches/$($p1.mid)/result" @{type='Winner';winner='A'} $tok) 409 'DOWNSTREAM_MATCH_STARTED'
Check '[A] refused correction changed nothing (semi 1 winner B)' ((NodeOf (GetBr) $s0.nodeId).match.outcome.winner -eq 'B')
Holds '[A] final unchanged' $x.final.nodeId $s0.winnerTo.slot $p1.winner
Holds '[A] bronze unchanged' $x.bronze.nodeId $s0.loserTo.slot $p1.loser

Stage 'A5 Completion needs both final and bronze'
$bres=Call POST "/matches/$($bm.matchId)/result" @{type='Winner';winner='A'} $tok
Expect '[A] record bronze result' $bres 200
Expect '[A] complete with final unplayed refused' (Call POST "/tournaments/$script:tid/complete" $null $tok) 409 'TOURNAMENT_NOT_COMPLETE'
$pf=Play '[A] final' $x.final 'A'
Expect '[A] complete tournament' (Call POST "/tournaments/$script:tid/complete" $null $tok) 200
$v=Call GET "/tournaments/$script:tid" $null $tok
Check '[A] state persisted as Completed' ($v.Json.tournament.state -eq 'Completed') $v.Json.tournament.state
Expect '[A] correcting after completion refused' (Call PUT "/matches/$($p2.mid)/result" @{type='Winner';winner='B'} $tok) 409 'TOURNAMENT_ALREADY_COMPLETED'

# ---------- B: completion order (final first, bronze last)
Stage 'B1 Final decided but bronze not: complete refused'
NewSE 'B' 4 $true; Roles
if(-not $script:rolesOk){ Check '[B] roles found' $false; Done }
$x=$script:rl
$q1=Play '[B] semi 1' $x.semis[0] 'A'
$q2=Play '[B] semi 2' $x.semis[1] 'A'
$qf=Play '[B] final' $x.final 'A'
Expect '[B] complete with bronze unplayed refused' (Call POST "/tournaments/$script:tid/complete" $null $tok) 409 'TOURNAMENT_NOT_COMPLETE'
$vb=Call GET "/tournaments/$script:tid" $null $tok
Check '[B] state still InProgress' ($vb.Json.tournament.state -eq 'InProgress') $vb.Json.tournament.state
Stage 'B2 Bronze decided: complete succeeds'
$qb=Play '[B] bronze' $x.bronze 'A'
Expect '[B] complete tournament' (Call POST "/tournaments/$script:tid/complete" $null $tok) 200
$vb=Call GET "/tournaments/$script:tid" $null $tok
Check '[B] state persisted as Completed' ($vb.Json.tournament.state -eq 'Completed') $vb.Json.tournament.state

# ---------- C: 3 players, option on, no bronze
Stage 'C 3 players: option on but no bronze node'
NewSE 'C' 3 $true
$bc=GetBr
Expect '[C] read bracket' $bc 200
Dump $bc
Check '[C] thirdPlaceNodeId is null' ($null -eq $bc.Json.thirdPlaceNodeId) "$($bc.Json.thirdPlaceNodeId)"
Check '[C] 3 nodes (2 semis + final)' (@($bc.Json.nodes).Count -eq 3) "$(@($bc.Json.nodes).Count)"
Check '[C] no node waits on a loser' (@($bc.Json.nodes | Where-Object { $_.slotA.type -eq 'AwaitingLoserOf' -or $_.slotB.type -eq 'AwaitingLoserOf' }).Count -eq 0)
$vc=Call GET "/tournaments/$script:tid" $null $tok
Info "tournament thirdPlaceMatch flag with 3 players: $($vc.Json.tournament.thirdPlaceMatch)"

# ---------- D: validation
Stage 'D Third-place only for single elimination'
$de=Call POST '/tournaments' @{name="3P DE $id";organizer='E2E Runner';format='DoubleElimination';visibility='Public';maxParticipants=4;thirdPlaceMatch=$true} $tok
Expect '[D] DoubleElimination + thirdPlaceMatch rejected' $de 400 'VALIDATION_FAILED'
Check '[D] error names the thirdPlaceMatch field' ($de.Json.error.details.field -eq 'thirdPlaceMatch') "$($de.Raw)"
$rr=Call POST '/tournaments' @{name="3P RR $id";organizer='E2E Runner';format='RoundRobin';visibility='Public';maxParticipants=4;thirdPlaceMatch=$true} $tok
Expect '[D] RoundRobin + thirdPlaceMatch rejected' $rr 400 'VALIDATION_FAILED'
Done
