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
function Skip($label){ Info "[$label] setup failed, scenario skipped" }

function GetBr { Call GET "/tournaments/$script:tid/bracket" $null $script:tok }
function NodeOf($b,$nid){ @($b.Json.nodes | Where-Object { $_.nodeId -eq $nid })[0] }
function SlotAt($n,$pos){ if($pos -eq 'A'){ $n.slotA } else { $n.slotB } }
function Pname($slot){ if($slot.type -eq 'Filled'){ $slot.participant.player } else { "<$($slot.type)>" } }
function PairKey($m){ (@($m.competitorA.player,$m.competitorB.player) | Sort-Object) -join ',' }
function MatchOf($nid){ (NodeOf (GetBr) $nid).match }
function St { (Call GET "/tournaments/$script:tid" $null $script:tok).Json.tournament.state }
function StateIs($label,$want){ $got=St; Check "$label state is $want" ($got -eq $want) "got $got" }
function Holds($label,$nid,$pos,$name){
  $n=NodeOf (GetBr) $nid
  $got=Pname (SlotAt $n $pos)
  Check "$label slot $pos holds $name" ($got -eq $name) "got $got"
}
function MatchIs($label,$nid,$names,$status){
  $m=MatchOf $nid
  if(-not $m){ Check "$label has a match" $false; return }
  $want=(@($names) | Sort-Object) -join ','
  Check "$label match is $status ($want)" (((PairKey $m) -eq $want) -and ($m.status -eq $status)) "got $(PairKey $m) $($m.status)"
}
function NoMatch($label,$nid){ Check "$label has no match" ($null -eq (MatchOf $nid)) }
function OutcomeIs($label,$nid,$side){
  $m=MatchOf $nid
  if(-not $m){ Check "$label has a match" $false; return }
  Check "$label is Completed, winner $side" (($m.status -eq 'Completed') -and ($m.outcome.winner -eq $side)) "got $($m.status) $($m.outcome.winner)"
}
function LinkTo($n,$kind,$dest,$slots){
  $l=$n.$kind
  if($null -eq $l -or $null -eq $dest){ return $false }
  (($l.node -eq $dest.nodeId) -and ($slots -contains $l.slot))
}
function OtherPos($pos){ if($pos -eq 'A'){ 'B' } else { 'A' } }
function Play($label,$node,$want){
  $m=(NodeOf (GetBr) $node.nodeId).match
  if(-not $m){ Check "$label has a match to play" $false; return $null }
  $a=$m.competitorA.player; $c=$m.competitorB.player
  $side = if($want -eq 'A' -or $want -eq 'B'){ $want } elseif($want -eq $a){ 'A' } else { 'B' }
  Expect "$label start" (Call POST "/matches/$($m.matchId)/start" $null $script:tok) 200
  $res=Call POST "/matches/$($m.matchId)/result" @{type='Winner';winner=$side} $script:tok
  Expect "$label : $a vs $c, $side wins" $res 200
  $win = if($side -eq 'A'){ $a } else { $c }
  $los = if($side -eq 'A'){ $c } else { $a }
  [pscustomobject]@{mid=$m.matchId;winner=$win;loser=$los;a=$a;b=$c}
}
function StartNode($label,$nid){
  $m=MatchOf $nid
  if(-not $m){ Check "$label has a match to start" $false; return $null }
  Expect "$label start" (Call POST "/matches/$($m.matchId)/start" $null $script:tok) 200
  $m
}
function Finish($label,$nid,$side){
  $m=MatchOf $nid
  if(-not $m){ Check "$label has a match to finish" $false; return $null }
  $a=$m.competitorA.player; $c=$m.competitorB.player
  Expect "$label : $a vs $c, $side wins" (Call POST "/matches/$($m.matchId)/result" @{type='Winner';winner=$side} $script:tok) 200
  $win = if($side -eq 'A'){ $a } else { $c }
  $los = if($side -eq 'A'){ $c } else { $a }
  [pscustomobject]@{mid=$m.matchId;winner=$win;loser=$los;a=$a;b=$c}
}
function Correct($label,$mid,$side){
  Expect $label (Call PUT "/matches/$mid/result" @{type='Winner';winner=$side} $script:tok) 200
}
function Blocked($label,$mid,$side,$blockMid){
  $res=Call PUT "/matches/$mid/result" @{type='Winner';winner=$side} $script:tok
  Expect $label $res 409 'DOWNSTREAM_MATCH_STARTED'
  Check "  $label : error names the blocking match" ($res.Json.error.details.matchId -eq $blockMid) "got $($res.Json.error.details.matchId) want $blockMid"
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
    wb2n=$wb2.Count
    n5=@($wb2 | Where-Object { $_.match })[0]
    n6=@($wb2 | Where-Object { -not $_.match })[0]
    wbF=@($nn | Where-Object { $_.stage -eq 'Winners' -and $_.round -eq 3 })[0]
    l1=@($nn | Where-Object { $_.stage -eq 'Losers' -and $_.round -eq 1 })[0]
    l2a=@($lb2 | Where-Object { $_.slotB.type -ne 'Bye' })[0]
    l2b=@($lb2 | Where-Object { $_.slotB.type -eq 'Bye' })[0]
    l3=@($nn | Where-Object { $_.stage -eq 'Losers' -and $_.round -eq 3 })[0]
    lF=@($nn | Where-Object { $_.stage -eq 'Losers' -and $_.round -eq 4 })[0]
    gf1=(NodeOf $b $b.Json.grandFinalNodeId)
    rst=(NodeOf $b $b.Json.resetNodeId)
  }
  $h=$script:rl
  $script:rolesOk=[bool](($h.byes.Count -eq 3) -and ($h.reals.Count -eq 1) -and ($h.wb2n -eq 2) -and $h.n5 -and $h.n6 -and $h.wbF -and $h.l1 -and $h.l2a -and $h.l2b -and $h.l3 -and $h.lF -and $h.gf1 -and $h.rst)
}

function NewDE5($label){
  $before=$script:fail
  $resp=Call POST '/tournaments' @{name="DE5 $label $script:id";organizer='E2E Runner';format='DoubleElimination';visibility='Public';maxParticipants=5} $script:tok
  Expect "[$label] create DoubleElimination (max 5)" $resp 201
  if($resp.Status -ne 201){ return $false }
  $script:tid=$resp.Json.tournamentId
  $tt=$script:tid
  Expect "[$label] publish" (Call POST "/tournaments/$tt/publish" $null $script:tok) 204
  Expect "[$label] open registration" (Call POST "/tournaments/$tt/open-registration" $null $script:tok) 204
  foreach($nm in 'Ayo','Bela','Chidi','Dara','Eli'){
    Expect "[$label] register $nm" (Call POST "/tournaments/$tt/registrations" @{type='Individual';player=$nm} $script:tok) 201
  }
  Expect "[$label] close registration" (Call POST "/tournaments/$tt/close-registration" $null $script:tok) 204
  Expect "[$label] generate bracket" (Call POST "/tournaments/$tt/bracket" $null $script:tok) 201
  Expect "[$label] start tournament" (Call POST "/tournaments/$tt/start" $null $script:tok) 204
  return ($script:fail -eq $before)
}

function Shape($label){
  $x=$script:rl; $b=$x.b; $nodes=@($b.Json.nodes)
  $r4=$x.reals[0]
  Check "[$label] 14 nodes" ($nodes.Count -eq 14) "$($nodes.Count)"
  Check "[$label] 9 Winners-stage and 5 Losers-stage nodes" ((@($nodes | Where-Object { $_.stage -eq 'Winners' }).Count -eq 9) -and (@($nodes | Where-Object { $_.stage -eq 'Losers' }).Count -eq 5))
  Check "[$label] grand final + reset present, no third place, standings null" (($null -ne $b.Json.grandFinalNodeId) -and ($null -ne $b.Json.resetNodeId) -and ($null -eq $b.Json.thirdPlaceNodeId) -and ($null -eq $b.Json.standings))
  Check "[$label] linksAvailable" ($b.Json.linksAvailable -eq $true)
  Check "[$label] only 2 matches at start (the real WB R1 match and the pre-filled WB R2 node)" ((@($nodes | Where-Object { $_.match }).Count -eq 2) -and ($null -ne $r4.match) -and ($null -ne $x.n5.match))
  Check "[$label] the 3 bye nodes are (Filled, Bye) shaped" ((@($x.byes | Where-Object { (($_.slotA.type -eq 'Filled') -ne ($_.slotB.type -eq 'Filled')) -and (($_.slotA.type -eq 'Bye') -or ($_.slotB.type -eq 'Bye')) }).Count) -eq 3)
  $byePlayers=@($x.byes | ForEach-Object { if($_.slotA.type -eq 'Filled'){ $_.slotA.participant.player } else { $_.slotB.participant.player } }) | Sort-Object
  Info "byes went to: $($byePlayers -join ', ') | real WB R1 match: $(PairKey $r4.match) | pre-filled WB R2: $(PairKey $x.n5.match)"
  Check "[$label] first three registrants got the byes; Dara and Eli play the real match" ((($byePlayers -join ',') -eq 'Ayo,Bela,Chidi') -and ((PairKey $r4.match) -eq 'Dara,Eli') -and ((PairKey $x.n5.match) -eq 'Ayo,Bela')) "$($byePlayers -join ',') | $(PairKey $r4.match) | $(PairKey $x.n5.match)"
  $toN5=@($x.byes | Where-Object { $_.winnerTo.node -eq $x.n5.nodeId })
  $toN6=@($x.byes | Where-Object { $_.winnerTo.node -eq $x.n6.nodeId })
  Check "[$label] bye nodes: two feed n5 (slots A,B), one feeds n6 slot A, none has a loser link" (($toN5.Count -eq 2) -and ($toN6.Count -eq 1) -and (((@($toN5.winnerTo.slot) | Sort-Object) -join ',') -eq 'A,B') -and ($toN6[0].winnerTo.slot -eq 'A') -and (@($x.byes | Where-Object { $null -ne $_.loserTo }).Count -eq 0))
  Check "[$label] real WB R1: winner -> n6 slot B, loser -> LB R1 slot A" ((LinkTo $r4 'winnerTo' $x.n6 @('B')) -and (LinkTo $r4 'loserTo' $x.l1 @('A')))
  Check "[$label] n5: winner -> WB final A, loser -> LB R2a A" ((LinkTo $x.n5 'winnerTo' $x.wbF @('A')) -and (LinkTo $x.n5 'loserTo' $x.l2a @('A')))
  Check "[$label] n6: winner -> WB final B, loser -> bye-shaped LB R2b A" ((LinkTo $x.n6 'winnerTo' $x.wbF @('B')) -and (LinkTo $x.n6 'loserTo' $x.l2b @('A')))
  Check "[$label] WB final: winner -> GF1 A, loser -> LB final A" ((LinkTo $x.wbF 'winnerTo' $x.gf1 @('A')) -and (LinkTo $x.wbF 'loserTo' $x.lF @('A')))
  Check "[$label] LB R1 (bye-shaped): winner -> LB R2a B" (LinkTo $x.l1 'winnerTo' $x.l2a @('B'))
  Check "[$label] LB R2a: winner -> LB R3 A; LB R2b (bye-shaped): winner -> LB R3 B" ((LinkTo $x.l2a 'winnerTo' $x.l3 @('A')) -and (LinkTo $x.l2b 'winnerTo' $x.l3 @('B')))
  Check "[$label] LB R3: winner -> LB final B; LB final: winner -> GF1 B" ((LinkTo $x.l3 'winnerTo' $x.lF @('B')) -and (LinkTo $x.lF 'winnerTo' $x.gf1 @('B')))
  Check "[$label] no Losers node has a loser link" (@(@($x.l1,$x.l2a,$x.l2b,$x.l3,$x.lF) | Where-Object { $null -ne $_.loserTo }).Count -eq 0)
  Check "[$label] GF1: winner -> reset A, loser -> reset B; reset has no links" ((LinkTo $x.gf1 'winnerTo' $x.rst @('A')) -and (LinkTo $x.gf1 'loserTo' $x.rst @('B')) -and ($null -eq $x.rst.winnerTo) -and ($null -eq $x.rst.loserTo))
  Check "[$label] slot types: LB R1 AwL/Bye, R2a AwL/AwW, R2b AwL/Bye, R3 AwW/AwW, LB final AwL/AwW, n6 Filled/AwW" (($x.l1.slotA.type -eq 'AwaitingLoserOf') -and ($x.l1.slotB.type -eq 'Bye') -and ($x.l2a.slotA.type -eq 'AwaitingLoserOf') -and ($x.l2a.slotB.type -eq 'AwaitingWinnerOf') -and ($x.l2b.slotA.type -eq 'AwaitingLoserOf') -and ($x.l2b.slotB.type -eq 'Bye') -and ($x.l3.slotA.type -eq 'AwaitingWinnerOf') -and ($x.l3.slotB.type -eq 'AwaitingWinnerOf') -and ($x.lF.slotA.type -eq 'AwaitingLoserOf') -and ($x.lF.slotB.type -eq 'AwaitingWinnerOf') -and ($x.n6.slotA.type -eq 'Filled') -and ($x.n6.slotB.type -eq 'AwaitingWinnerOf'))
  $winDest=@($nodes | Where-Object { $_.winnerTo } | ForEach-Object { $_.winnerTo.node } | Sort-Object -Unique)
  $byeWinDest=@($nodes | Where-Object { ($winDest -contains $_.nodeId) -and (($_.slotA.type -eq 'Bye') -or ($_.slotB.type -eq 'Bye')) })
  Check "[$label] no node reached by a winner link has a Bye slot (the winner path is never bye-shaped)" ($byeWinDest.Count -eq 0) "$($byeWinDest.Count)"
  $lbBye=@($nodes | Where-Object { ($_.stage -eq 'Losers') -and (($_.slotA.type -eq 'Bye') -or ($_.slotB.type -eq 'Bye')) } | ForEach-Object { $_.nodeId } | Sort-Object)
  $wantBye=@($x.l1.nodeId,$x.l2b.nodeId) | Sort-Object
  Check "[$label] the only Losers nodes with a Bye slot are LB R1 and LB R2b" (($lbBye -join ',') -eq ($wantBye -join ',')) "$($lbBye -join ',')"
}

# ---------- Setup
Stage 'Setup'
$health=Call GET '/health'; Expect 'backend reachable' $health 200
if($health.Status -ne 200){ exit 1 }
$id=Get-Random -Maximum 999999; $script:id=$id; $user="de5_$id"; $pw='Passw0rd!de5'
Expect 'register' (Call POST '/register' @{username=$user;email="$user@example.com";password=$pw}) 201
$script:tok=(Call POST '/login' @{username=$user;password=$pw}).Json.token
Check 'got a token' ($script:tok -match '^[0-9a-f]{64}$')
if($script:tok -notmatch '^[0-9a-f]{64}$'){ Done }

# ---------- Tournament A: happy path through both pass-throughs
Stage 'A1 Create and bracket shape (5 players, 3 byes)'
if(NewDE5 'A'){
  Roles
  Dump $script:rl.b
  if(-not $script:rolesOk){
    Check '[A] roles found (shape matches the trace)' $false
    Write-Host '  Shape differs from the trace. Paste the INFO dump above.' -ForegroundColor Red
    Done
  }
  Shape 'A'
  $x=$script:rl; $r4=$x.reals[0]
  $chidi=Pname $x.n6.slotA

  Stage 'A2 First pass-through: loser of the real WB R1 match drops through LB R1'
  $q5=Play '[A] n5 (bye recipients)' $x.n5 'A'
  Holds '[A] WB final' $x.wbF.nodeId $x.n5.winnerTo.slot $q5.winner
  Holds '[A] LB R2a' $x.l2a.nodeId $x.n5.loserTo.slot $q5.loser
  NoMatch '[A] WB final' $x.wbF.nodeId
  NoMatch '[A] LB R2a' $x.l2a.nodeId
  $q4=Play '[A] real WB R1 match' $r4 'A'
  Holds '[A] n6' $x.n6.nodeId $r4.winnerTo.slot $q4.winner
  Holds '[A] LB R1' $x.l1.nodeId $r4.loserTo.slot $q4.loser
  Check '[A] LB R1 other slot is Bye' ((SlotAt (NodeOf (GetBr) $x.l1.nodeId) (OtherPos $r4.loserTo.slot)).type -eq 'Bye')
  Holds '[A] LB R2a (bye pass-through)' $x.l2a.nodeId $x.l1.winnerTo.slot $q4.loser
  NoMatch '[A] LB R1 (bye node never plays)' $x.l1.nodeId
  MatchIs '[A] LB R2a' $x.l2a.nodeId @($q5.loser,$q4.loser) 'Scheduled'
  MatchIs '[A] n6' $x.n6.nodeId @($chidi,$q4.winner) 'Scheduled'

  Stage 'A3 Second pass-through: loser of n6 drops through LB R2b'
  $q9=Play '[A] LB R2a' $x.l2a 'A'
  Holds '[A] LB R3' $x.l3.nodeId $x.l2a.winnerTo.slot $q9.winner
  NoMatch '[A] LB R3' $x.l3.nodeId
  $q6=Play '[A] n6' $x.n6 'A'
  Holds '[A] WB final' $x.wbF.nodeId $x.n6.winnerTo.slot $q6.winner
  Holds '[A] LB R2b (bye-shaped)' $x.l2b.nodeId $x.n6.loserTo.slot $q6.loser
  Check '[A] LB R2b other slot is Bye' ((SlotAt (NodeOf (GetBr) $x.l2b.nodeId) (OtherPos $x.n6.loserTo.slot)).type -eq 'Bye')
  Holds '[A] LB R3 (bye pass-through)' $x.l3.nodeId $x.l2b.winnerTo.slot $q6.loser
  NoMatch '[A] LB R2b (bye node never plays)' $x.l2b.nodeId
  MatchIs '[A] LB R3' $x.l3.nodeId @($q9.winner,$q6.loser) 'Scheduled'
  MatchIs '[A] WB final' $x.wbF.nodeId @($q5.winner,$q6.winner) 'Scheduled'

  Stage 'A4 Finish the bracket'
  $q7=Play '[A] WB final' $x.wbF 'A'
  Holds '[A] GF1' $x.gf1.nodeId $x.wbF.winnerTo.slot $q7.winner
  Holds '[A] LB final' $x.lF.nodeId $x.wbF.loserTo.slot $q7.loser
  $q11=Play '[A] LB R3' $x.l3 'A'
  Holds '[A] LB final' $x.lF.nodeId $x.l3.winnerTo.slot $q11.winner
  MatchIs '[A] LB final' $x.lF.nodeId @($q7.loser,$q11.winner) 'Scheduled'
  $q12=Play '[A] LB final' $x.lF 'A'
  Holds '[A] GF1' $x.gf1.nodeId $x.lF.winnerTo.slot $q12.winner
  MatchIs '[A] GF1' $x.gf1.nodeId @($q7.winner,$q12.winner) 'Scheduled'
  $q13=Play '[A] GF1 (WB champion wins)' $x.gf1 $q7.winner
  NoMatch '[A] reset' $x.rst.nodeId
  $rn=NodeOf (GetBr) $x.rst.nodeId
  Check '[A] reset voided to Bye/Bye' (($rn.slotA.type -eq 'Bye') -and ($rn.slotB.type -eq 'Bye')) "$($rn.slotA.type)/$($rn.slotB.type)"
  NoMatch '[A] LB R1 (still no match)' $x.l1.nodeId
  NoMatch '[A] LB R2b (still no match)' $x.l2b.nodeId
  Check '[A] 8 matches in total' (@((GetBr).Json.nodes | Where-Object { $_.match }).Count -eq 8) "$(@((GetBr).Json.nodes | Where-Object { $_.match }).Count)"
  Expect '[A] complete tournament' (Call POST "/tournaments/$script:tid/complete" $null $script:tok) 200
  StateIs '[A] end' 'Completed'
} else { Skip 'A' }

# ---------- Tournament B: corrections across both pass-throughs
Stage 'B1 Create, play the real WB R1 match first'
if(NewDE5 'B'){
  Roles
  if(-not $script:rolesOk){ Check '[B] roles found' $false; Dump $script:rl.b; Done }
  $x=$script:rl; $r4=$x.reals[0]
  $chidi=Pname $x.n6.slotA
  $mv4=Play '[B] real WB R1 match' $r4 'A'
  $wA=$mv4.winner; $lA=$mv4.loser
  Holds '[B] n6' $x.n6.nodeId $r4.winnerTo.slot $wA
  Holds '[B] LB R1' $x.l1.nodeId $r4.loserTo.slot $lA
  Holds '[B] LB R2a (pass-through)' $x.l2a.nodeId $x.l1.winnerTo.slot $lA
  NoMatch '[B] LB R2a' $x.l2a.nodeId
  MatchIs '[B] n6' $x.n6.nodeId @($chidi,$wA) 'Scheduled'

  Stage 'B2 Correct while LB R2a has no match: only the slots follow'
  Correct '[B] correct real WB R1 match (B wins instead)' $mv4.mid 'B'
  OutcomeIs '[B] real WB R1 match' $r4.nodeId 'B'
  Holds '[B] n6 after correction' $x.n6.nodeId $r4.winnerTo.slot $lA
  MatchIs '[B] n6 after correction' $x.n6.nodeId @($chidi,$lA) 'Scheduled'
  Holds '[B] LB R1 after correction' $x.l1.nodeId $r4.loserTo.slot $wA
  Holds '[B] LB R2a pass-through after correction' $x.l2a.nodeId $x.l1.winnerTo.slot $wA
  NoMatch '[B] LB R2a (still no match)' $x.l2a.nodeId

  Stage 'B3 Correct while LB R2a has a Scheduled match: the match is swapped'
  $mv5=Play '[B] n5 (bye recipients)' $x.n5 'A'
  Holds '[B] LB R2a (n5 loser)' $x.l2a.nodeId $x.n5.loserTo.slot $mv5.loser
  MatchIs '[B] LB R2a created with the passed-through loser' $x.l2a.nodeId @($mv5.loser,$wA) 'Scheduled'
  Correct '[B] correct real WB R1 match again (A wins)' $mv4.mid 'A'
  OutcomeIs '[B] real WB R1 match' $r4.nodeId 'A'
  Holds '[B] n6 after second correction' $x.n6.nodeId $r4.winnerTo.slot $wA
  MatchIs '[B] n6 after second correction' $x.n6.nodeId @($chidi,$wA) 'Scheduled'
  Holds '[B] LB R1 after second correction' $x.l1.nodeId $r4.loserTo.slot $lA
  Holds '[B] LB R2a slot after second correction' $x.l2a.nodeId $x.l1.winnerTo.slot $lA
  MatchIs '[B] LB R2a MATCH follows the correction' $x.l2a.nodeId @($mv5.loser,$lA) 'Scheduled'

  Stage 'B4 Started pass-through target blocks the correction'
  $m9=StartNode '[B] LB R2a' $x.l2a.nodeId
  if($m9){
    Blocked '[B] correct real WB R1 match after LB R2a started' $mv4.mid 'B' $m9.matchId
    OutcomeIs '[B] real WB R1 match unchanged' $r4.nodeId 'A'
    Holds '[B] LB R2a slot unchanged' $x.l2a.nodeId $x.l1.winnerTo.slot $lA
    MatchIs '[B] LB R2a unchanged' $x.l2a.nodeId @($mv5.loser,$lA) 'InProgress'
    Holds '[B] n6 unchanged' $x.n6.nodeId $r4.winnerTo.slot $wA
    MatchIs '[B] n6 match unchanged' $x.n6.nodeId @($chidi,$wA) 'Scheduled'
  }

  Stage 'B5 LB correction (handleLBSource) without a downstream match'
  $mv9=Finish '[B] LB R2a' $x.l2a.nodeId 'A'
  if($mv9 -and $m9){
    Holds '[B] LB R3' $x.l3.nodeId $x.l2a.winnerTo.slot $mv9.winner
    NoMatch '[B] LB R3' $x.l3.nodeId
    Blocked '[B] correct real WB R1 match after LB R2a completed' $mv4.mid 'B' $m9.matchId
    Correct '[B] correct LB R2a (B wins instead), no downstream match' $mv9.mid 'B'
    OutcomeIs '[B] LB R2a' $x.l2a.nodeId 'B'
    Holds '[B] LB R3 after LB correction' $x.l3.nodeId $x.l2a.winnerTo.slot $mv9.loser
    NoMatch '[B] LB R3 (still no match)' $x.l3.nodeId

    Stage 'B6 Second pass-through: n6 loser drops through LB R2b into LB R3'
    $mv6=Play '[B] n6' $x.n6 'A'
    Holds '[B] WB final' $x.wbF.nodeId $x.n6.winnerTo.slot $mv6.winner
    Holds '[B] LB R2b (bye-shaped)' $x.l2b.nodeId $x.n6.loserTo.slot $mv6.loser
    Check '[B] LB R2b other slot is Bye' ((SlotAt (NodeOf (GetBr) $x.l2b.nodeId) (OtherPos $x.n6.loserTo.slot)).type -eq 'Bye')
    Holds '[B] LB R3 (bye pass-through)' $x.l3.nodeId $x.l2b.winnerTo.slot $mv6.loser
    NoMatch '[B] LB R2b (bye node never plays)' $x.l2b.nodeId
    MatchIs '[B] LB R3' $x.l3.nodeId @($mv9.loser,$mv6.loser) 'Scheduled'
    MatchIs '[B] WB final' $x.wbF.nodeId @($mv5.winner,$mv6.winner) 'Scheduled'

    Stage 'B7 LB correction with a Scheduled downstream match'
    Correct '[B] correct LB R2a (A wins again), LB R3 match exists' $mv9.mid 'A'
    OutcomeIs '[B] LB R2a' $x.l2a.nodeId 'A'
    Holds '[B] LB R3 slot follows' $x.l3.nodeId $x.l2a.winnerTo.slot $mv9.winner
    MatchIs '[B] LB R3 MATCH follows' $x.l3.nodeId @($mv9.winner,$mv6.loser) 'Scheduled'

    Stage 'B8 Correct n6: loser passed through a bye node into an existing LB R3 match'
    Correct '[B] correct n6 (B wins instead)' $mv6.mid 'B'
    OutcomeIs '[B] n6' $x.n6.nodeId 'B'
    Holds '[B] WB final slot follows' $x.wbF.nodeId $x.n6.winnerTo.slot $mv6.loser
    MatchIs '[B] WB final MATCH follows' $x.wbF.nodeId @($mv5.winner,$mv6.loser) 'Scheduled'
    Holds '[B] LB R2b slot follows' $x.l2b.nodeId $x.n6.loserTo.slot $mv6.winner
    Holds '[B] LB R3 slot follows (pass-through)' $x.l3.nodeId $x.l2b.winnerTo.slot $mv6.winner
    MatchIs '[B] LB R3 MATCH follows (pass-through)' $x.l3.nodeId @($mv9.winner,$mv6.winner) 'Scheduled'

    Stage 'B9 Started LB R3 blocks both corrections'
    $m11=StartNode '[B] LB R3' $x.l3.nodeId
    if($m11){
      Blocked '[B] correct n6 after LB R3 started' $mv6.mid 'A' $m11.matchId
      OutcomeIs '[B] n6 unchanged' $x.n6.nodeId 'B'
      MatchIs '[B] LB R3 unchanged' $x.l3.nodeId @($mv9.winner,$mv6.winner) 'InProgress'
      MatchIs '[B] WB final unchanged' $x.wbF.nodeId @($mv5.winner,$mv6.loser) 'Scheduled'
      Blocked '[B] correct LB R2a after LB R3 started' $mv9.mid 'B' $m11.matchId
      OutcomeIs '[B] LB R2a unchanged' $x.l2a.nodeId 'A'
    }

    Stage 'B10 Finish and complete'
    $f11=Finish '[B] LB R3' $x.l3.nodeId 'A'
    Holds '[B] LB final' $x.lF.nodeId $x.l3.winnerTo.slot $f11.winner
    $f7=Play '[B] WB final' $x.wbF 'A'
    Holds '[B] GF1' $x.gf1.nodeId $x.wbF.winnerTo.slot $f7.winner
    Holds '[B] LB final' $x.lF.nodeId $x.wbF.loserTo.slot $f7.loser
    MatchIs '[B] LB final' $x.lF.nodeId @($f7.loser,$f11.winner) 'Scheduled'
    $f12=Play '[B] LB final' $x.lF 'A'
    Holds '[B] GF1' $x.gf1.nodeId $x.lF.winnerTo.slot $f12.winner
    $f13=Play '[B] GF1 (WB champion wins)' $x.gf1 $f7.winner
    NoMatch '[B] reset' $x.rst.nodeId
    Check '[B] 8 matches in total' (@((GetBr).Json.nodes | Where-Object { $_.match }).Count -eq 8) "$(@((GetBr).Json.nodes | Where-Object { $_.match }).Count)"
    Expect '[B] complete tournament' (Call POST "/tournaments/$script:tid/complete" $null $script:tok) 200
    StateIs '[B] end' 'Completed'
  }
} else { Skip 'B' }

Done
