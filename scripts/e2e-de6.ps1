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
function NodeOf($b,$id){ @($b.Json.nodes | Where-Object { $_.nodeId -eq $id })[0] }
function SlotAt($n,$pos){ if($pos -eq 'A'){ $n.slotA } else { $n.slotB } }
function Pname($slot){ if($slot.type -eq 'Filled'){ $slot.participant.player } else { "<$($slot.type)>" } }
function PairKey($m){ (@($m.competitorA.player,$m.competitorB.player) | Sort-Object) -join ',' }
function Holds($label,$nodeId,$pos,$name){
  $n=NodeOf (GetBr) $nodeId
  $got=Pname (SlotAt $n $pos)
  Check "$label slot $pos holds $name" ($got -eq $name) "got $got"
}
function MatchIs($label,$nodeId,$names,$status){
  $m=(NodeOf (GetBr) $nodeId).match
  if(-not $m){ Check "$label has a match" $false; return }
  $want=(@($names) | Sort-Object) -join ','
  Check "$label match is $status ($want)" (((PairKey $m) -eq $want) -and ($m.status -eq $status)) "got $(PairKey $m) $($m.status)"
}
function NoMatch($label,$nodeId){
  Check "$label has no match" ($null -eq (NodeOf (GetBr) $nodeId).match)
}
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
    Info ("{0,4} {1,-7} R{2} A={3,-14} B={4,-14} match={5,-5} W>{6,-6} L>{7}" -f $nd.nodeId,$nd.stage,$nd.round,(Pname $nd.slotA),(Pname $nd.slotB),[bool]$nd.match,(LnkStr $nd.winnerTo),(LnkStr $nd.loserTo))
  }
}

function Roles {
  $b=GetBr; $nn=@($b.Json.nodes)
  $wb1=@($nn | Where-Object { $_.stage -eq 'Winners' -and $_.round -eq 1 } | Sort-Object nodeId)
  $wb2=@($nn | Where-Object { $_.stage -eq 'Winners' -and $_.round -eq 2 } | Sort-Object nodeId)
  $lb2=@($nn | Where-Object { $_.stage -eq 'Losers' -and $_.round -eq 2 } | Sort-Object nodeId)
  $script:rl=@{
    b=$b
    byes=@($wb1 | Where-Object { -not $_.match })
    reals=@($wb1 | Where-Object { $_.match })
    n5=@($wb2 | Where-Object { $_.match })[0]
    n6=@($wb2 | Where-Object { -not $_.match })[0]
    wbF=@($nn | Where-Object { $_.stage -eq 'Winners' -and $_.round -eq 3 })[0]
    lb1=@($nn | Where-Object { $_.stage -eq 'Losers' -and $_.round -eq 1 })[0]
    n9=@($lb2 | Where-Object { $_.slotB.type -ne 'Bye' })[0]
    n10=@($lb2 | Where-Object { $_.slotB.type -eq 'Bye' })[0]
    lb3=@($nn | Where-Object { $_.stage -eq 'Losers' -and $_.round -eq 3 })[0]
    lbF=@($nn | Where-Object { $_.stage -eq 'Losers' -and $_.round -eq 4 })[0]
    gf1=(NodeOf $b $b.Json.grandFinalNodeId)
    rst=(NodeOf $b $b.Json.resetNodeId)
  }
  $h=$script:rl
  $script:rolesOk=[bool](($h.byes.Count -eq 2) -and ($h.reals.Count -eq 2) -and $h.n5 -and $h.n6 -and $h.wbF -and $h.lb1 -and $h.n9 -and $h.n10 -and $h.lb3 -and $h.lbF -and $h.gf1 -and $h.rst)
}

function NewDE6($label){
  $resp=Call POST '/tournaments' @{name="DE6 $label $id";organizer='E2E Runner';format='DoubleElimination';visibility='Public';maxParticipants=6} $tok
  Expect "[$label] create DoubleElimination (max 6)" $resp 201
  $script:tid=$resp.Json.tournamentId
  $tt=$script:tid
  Expect "[$label] publish" (Call POST "/tournaments/$tt/publish" $null $tok) 204
  Expect "[$label] open registration" (Call POST "/tournaments/$tt/open-registration" $null $tok) 204
  foreach($nm in 'Ayo','Bela','Chidi','Dara','Eli','Fay'){
    Expect "[$label] register $nm" (Call POST "/tournaments/$tt/registrations" @{type='Individual';player=$nm} $tok) 201
  }
  Expect "[$label] close registration" (Call POST "/tournaments/$tt/close-registration" $null $tok) 204
  Expect "[$label] generate bracket" (Call POST "/tournaments/$tt/bracket" $null $tok) 201
  Expect "[$label] start tournament" (Call POST "/tournaments/$tt/start" $null $tok) 204
}

function Shape($label){
  $x=$script:rl; $b=$x.b; $nodes=@($b.Json.nodes)
  $bye0=$x.byes[0]; $bye1=$x.byes[1]; $re0=$x.reals[0]; $re1=$x.reals[1]
  Check "[$label] 14 nodes" ($nodes.Count -eq 14) "$($nodes.Count)"
  Check "[$label] 9 Winners-stage and 5 Losers-stage nodes" ((@($nodes | Where-Object { $_.stage -eq 'Winners' }).Count -eq 9) -and (@($nodes | Where-Object { $_.stage -eq 'Losers' }).Count -eq 5))
  Check "[$label] grand final + reset present, no third place, standings null" (($null -ne $b.Json.grandFinalNodeId) -and ($null -ne $b.Json.resetNodeId) -and ($null -eq $b.Json.thirdPlaceNodeId) -and ($null -eq $b.Json.standings))
  Check "[$label] linksAvailable" ($b.Json.linksAvailable -eq $true)
  Check "[$label] only 3 matches at start (2 real WB R1 + the pre-filled WB R2 node)" (@($nodes | Where-Object { $_.match }).Count -eq 3)
  Check "[$label] bye nodes are (Filled, Bye) shaped" ((@($x.byes | Where-Object { (($_.slotA.type -eq 'Filled') -ne ($_.slotB.type -eq 'Filled')) -and (($_.slotA.type -eq 'Bye') -or ($_.slotB.type -eq 'Bye')) }).Count) -eq 2)
  $byePlayers=@($x.byes | ForEach-Object { if($_.slotA.type -eq 'Filled'){ $_.slotA.participant.player } else { $_.slotB.participant.player } }) | Sort-Object
  Check "[$label] the 2 bye players are the pre-filled WB R2 match" ((PairKey $x.n5.match) -eq ($byePlayers -join ',')) "$(PairKey $x.n5.match) vs $($byePlayers -join ',')"
  Info "byes went to: $($byePlayers -join ', ')"
  Check "[$label] bye nodes: winner -> WB R2 pre-filled node (slots A,B), no loser link" ((LinkTo $bye0 'winnerTo' $x.n5 @('A','B')) -and (LinkTo $bye1 'winnerTo' $x.n5 @('A','B')) -and (((@($bye0.winnerTo.slot,$bye1.winnerTo.slot) | Sort-Object) -join ',') -eq 'A,B') -and ($null -eq $bye0.loserTo) -and ($null -eq $bye1.loserTo))
  Check "[$label] real WB R1: winners -> n6 (A,B), losers -> LB1 (A,B)" ((LinkTo $re0 'winnerTo' $x.n6 @('A','B')) -and (LinkTo $re1 'winnerTo' $x.n6 @('A','B')) -and (((@($re0.winnerTo.slot,$re1.winnerTo.slot) | Sort-Object) -join ',') -eq 'A,B') -and (LinkTo $re0 'loserTo' $x.lb1 @('A','B')) -and (LinkTo $re1 'loserTo' $x.lb1 @('A','B')) -and (((@($re0.loserTo.slot,$re1.loserTo.slot) | Sort-Object) -join ',') -eq 'A,B'))
  Check "[$label] n5: winner -> WB final A, loser -> LB R2 (n9) A" ((LinkTo $x.n5 'winnerTo' $x.wbF @('A')) -and (LinkTo $x.n5 'loserTo' $x.n9 @('A')))
  Check "[$label] n6: winner -> WB final B, loser -> bye-shaped LB R2 (n10) A" ((LinkTo $x.n6 'winnerTo' $x.wbF @('B')) -and (LinkTo $x.n6 'loserTo' $x.n10 @('A')))
  Check "[$label] WB final: winner -> GF1 A, loser -> LB final A" ((LinkTo $x.wbF 'winnerTo' $x.gf1 @('A')) -and (LinkTo $x.wbF 'loserTo' $x.lbF @('A')))
  Check "[$label] LB1: winner -> n9 B, no loser link" ((LinkTo $x.lb1 'winnerTo' $x.n9 @('B')) -and ($null -eq $x.lb1.loserTo))
  Check "[$label] n9: winner -> LB3 A; n10: winner -> LB3 B" ((LinkTo $x.n9 'winnerTo' $x.lb3 @('A')) -and (LinkTo $x.n10 'winnerTo' $x.lb3 @('B')))
  Check "[$label] LB3: winner -> LB final B; LB final: winner -> GF1 B" ((LinkTo $x.lb3 'winnerTo' $x.lbF @('B')) -and (LinkTo $x.lbF 'winnerTo' $x.gf1 @('B')))
  Check "[$label] LB nodes have no loser links" ((@(@($x.n9,$x.n10,$x.lb3,$x.lbF) | Where-Object { $null -ne $_.loserTo }).Count) -eq 0)
  Check "[$label] GF1: winner -> reset A, loser -> reset B; reset has no links" ((LinkTo $x.gf1 'winnerTo' $x.rst @('A')) -and (LinkTo $x.gf1 'loserTo' $x.rst @('B')) -and ($null -eq $x.rst.winnerTo) -and ($null -eq $x.rst.loserTo))
  Check "[$label] slot types: LB1 AwL/AwL, n9 AwL/AwW, n10 AwL/Bye, LB3 AwW/AwW, LB final AwL/AwW" (($x.lb1.slotA.type -eq 'AwaitingLoserOf') -and ($x.lb1.slotB.type -eq 'AwaitingLoserOf') -and ($x.n9.slotA.type -eq 'AwaitingLoserOf') -and ($x.n9.slotB.type -eq 'AwaitingWinnerOf') -and ($x.n10.slotA.type -eq 'AwaitingLoserOf') -and ($x.n10.slotB.type -eq 'Bye') -and ($x.lb3.slotA.type -eq 'AwaitingWinnerOf') -and ($x.lb3.slotB.type -eq 'AwaitingWinnerOf') -and ($x.lbF.slotA.type -eq 'AwaitingLoserOf') -and ($x.lbF.slotB.type -eq 'AwaitingWinnerOf'))
}

# Plays n5, both real WB R1 matches, LB1, and n6. Stops with n6 done and LB3 slot B filled by pass-through.
function Phase1($label){
  $x=$script:rl
  $re0=$x.reals[0]; $re1=$x.reals[1]
  $p5=Play "[$label] n5 (bye recipients)" $x.n5 'A'
  Holds "[$label] WB final" $x.wbF.nodeId $x.n5.winnerTo.slot $p5.winner
  Holds "[$label] n9" $x.n9.nodeId $x.n5.loserTo.slot $p5.loser
  NoMatch "[$label] WB final" $x.wbF.nodeId
  $p3=Play "[$label] WB R1 real #1" $re0 'A'
  Holds "[$label] n6" $x.n6.nodeId $re0.winnerTo.slot $p3.winner
  Holds "[$label] LB1" $x.lb1.nodeId $re0.loserTo.slot $p3.loser
  NoMatch "[$label] n6" $x.n6.nodeId
  NoMatch "[$label] LB1" $x.lb1.nodeId
  $p4=Play "[$label] WB R1 real #2" $re1 'A'
  Holds "[$label] n6" $x.n6.nodeId $re1.winnerTo.slot $p4.winner
  Holds "[$label] LB1" $x.lb1.nodeId $re1.loserTo.slot $p4.loser
  MatchIs "[$label] n6" $x.n6.nodeId @($p3.winner,$p4.winner) 'Scheduled'
  MatchIs "[$label] LB1" $x.lb1.nodeId @($p3.loser,$p4.loser) 'Scheduled'
  $p8=Play "[$label] LB1" $x.lb1 'A'
  Holds "[$label] n9" $x.n9.nodeId $x.lb1.winnerTo.slot $p8.winner
  MatchIs "[$label] n9" $x.n9.nodeId @($p5.loser,$p8.winner) 'Scheduled'
  $p6=Play "[$label] n6" $x.n6 'A'
  Holds "[$label] WB final" $x.wbF.nodeId $x.n6.winnerTo.slot $p6.winner
  Holds "[$label] n10 (bye-shaped)" $x.n10.nodeId $x.n6.loserTo.slot $p6.loser
  Check "[$label] n10 other slot is Bye" ((NodeOf (GetBr) $x.n10.nodeId).slotB.type -eq 'Bye')
  Holds "[$label] LB3 (bye pass-through)" $x.lb3.nodeId $x.n10.winnerTo.slot $p6.loser
  NoMatch "[$label] n10 (bye node never plays)" $x.n10.nodeId
  MatchIs "[$label] WB final" $x.wbF.nodeId @($p5.winner,$p6.winner) 'Scheduled'
  [pscustomobject]@{p5=$p5;p3=$p3;p4=$p4;p8=$p8;p6=$p6}
}

# ---------- Setup
Stage 'Setup'
$health=Call GET '/health'; Expect 'backend reachable' $health 200
if($health.Status -ne 200){ exit 1 }
$id=Get-Random -Maximum 999999; $user="de6_$id"; $pw='Passw0rd!de6'
Expect 'register' (Call POST '/register' @{username=$user;email="$user@example.com";password=$pw}) 201
$tok=(Call POST '/login' @{username=$user;password=$pw}).Json.token
Check 'got a token' ($tok -match '^[0-9a-f]{64}$')

# ---------- Tournament A: happy path through the bye shape
Stage 'A1 Create and bracket shape (6 players, 2 byes)'
NewDE6 'A'; Roles
Dump $script:rl.b
if(-not $script:rolesOk){ Check '[A] roles found (shape matches the trace)' $false; Write-Host '  Shape differs from the trace. Paste the INFO dump above.' -ForegroundColor Red; Done }
Shape 'A'
Stage 'A2 Play to the bye pass-through'
$ph=Phase1 'A'
Stage 'A3 Finish the bracket'
$x=$script:rl
$q9=Play '[A] n9' $x.n9 'A'
Holds '[A] LB3' $x.lb3.nodeId $x.n9.winnerTo.slot $q9.winner
MatchIs '[A] LB3' $x.lb3.nodeId @($q9.winner,$ph.p6.loser) 'Scheduled'
$qF=Play '[A] WB final' $x.wbF 'A'
Holds '[A] GF1' $x.gf1.nodeId $x.wbF.winnerTo.slot $qF.winner
Holds '[A] LB final' $x.lbF.nodeId $x.wbF.loserTo.slot $qF.loser
$q11=Play '[A] LB3' $x.lb3 'A'
Holds '[A] LB final' $x.lbF.nodeId $x.lb3.winnerTo.slot $q11.winner
MatchIs '[A] LB final' $x.lbF.nodeId @($qF.loser,$q11.winner) 'Scheduled'
$qL=Play '[A] LB final' $x.lbF 'A'
Holds '[A] GF1' $x.gf1.nodeId $x.lbF.winnerTo.slot $qL.winner
MatchIs '[A] GF1' $x.gf1.nodeId @($qF.winner,$qL.winner) 'Scheduled'
$qG=Play '[A] GF1 (WB champion wins)' $x.gf1 $qF.winner
NoMatch '[A] reset' $x.rst.nodeId
$rn=NodeOf (GetBr) $x.rst.nodeId
Check '[A] reset voided to Bye/Bye' (($rn.slotA.type -eq 'Bye') -and ($rn.slotB.type -eq 'Bye')) "$($rn.slotA.type)/$($rn.slotB.type)"
NoMatch '[A] n10 (still no match)' $x.n10.nodeId
Check '[A] 10 matches in total' (@((GetBr).Json.nodes | Where-Object { $_.match }).Count -eq 10)
Expect '[A] complete tournament' (Call POST "/tournaments/$script:tid/complete" $null $tok) 200
$v=Call GET "/tournaments/$script:tid" $null $tok
Check '[A] state persisted as Completed' ($v.Json.tournament.state -eq 'Completed') $v.Json.tournament.state

# ---------- Tournament B: correction when the loser was passed through a bye
Stage 'B1 Create and play to the pass-through'
NewDE6 'B'; Roles
if(-not $script:rolesOk){ Check '[B] roles found' $false; Done }
$phb=Phase1 'B'
$x=$script:rl
$p6=$phb.p6
$newWinner=$p6.b; $newLoser=$p6.a
Stage 'B2 Correct n6 (its loser was passed through the bye node into LB3)'
$cr=Call PUT "/matches/$($p6.mid)/result" @{type='Winner';winner='B'} $tok
Expect '[B] correct n6 (B wins instead)' $cr 200
Check '[B] corrected outcome persisted (winner B)' ((NodeOf (GetBr) $x.n6.nodeId).match.outcome.winner -eq 'B')
Holds '[B] WB final after correction' $x.wbF.nodeId $x.n6.winnerTo.slot $newWinner
MatchIs '[B] WB final match after correction' $x.wbF.nodeId @($phb.p5.winner,$newWinner) 'Scheduled'
Holds '[B] n10 after correction' $x.n10.nodeId $x.n6.loserTo.slot $newLoser
Holds '[B] LB3 after correction (pass-through must follow)' $x.lb3.nodeId $x.n10.winnerTo.slot $newLoser
Stage 'B3 LB3 materializes with the corrected loser'
$q9=Play '[B] n9' $x.n9 'A'
MatchIs '[B] LB3' $x.lb3.nodeId @($q9.winner,$newLoser) 'Scheduled'
Stage 'B4 Correction after LB3 has started must be refused'
$m11=(NodeOf (GetBr) $x.lb3.nodeId).match
if($m11){ Expect '[B] start LB3' (Call POST "/matches/$($m11.matchId)/start" $null $tok) 200 }
$late=Call PUT "/matches/$($p6.mid)/result" @{type='Winner';winner='A'} $tok
Expect '[B] correcting n6 after LB3 started is refused' $late 409 'DOWNSTREAM_MATCH_STARTED'
Check '[B] n6 outcome unchanged by the refused correction (winner B)' ((NodeOf (GetBr) $x.n6.nodeId).match.outcome.winner -eq 'B')
Done
