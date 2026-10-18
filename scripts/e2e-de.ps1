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

# ---------- helpers
function GetBr { Call GET "/tournaments/$script:tid/bracket" $null $tok }
function NodeOf($b,$id){ @($b.Json.nodes | Where-Object { $_.nodeId -eq $id })[0] }
function SlotAt($n,$pos){ if($pos -eq 'A'){ $n.slotA } else { $n.slotB } }
function Pname($slot){ if($slot.type -eq 'Filled'){ $slot.participant.player } else { "<$($slot.type)>" } }
function PairKey($m){ (@($m.competitorA.player,$m.competitorB.player) | Sort-Object) -join ',' }
function SideOf($p,$name){ if($p.a -eq $name){ 'A' } else { 'B' } }
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
  Check "$label has no match yet" ($null -eq (NodeOf (GetBr) $nodeId).match)
}
function LinkTo($n,$kind,$dest,$slots){
  $l=$n.$kind
  if($null -eq $l){ return $false }
  (($l.node -eq $dest.nodeId) -and ($slots -contains $l.slot))
}
function Play($label,$node,$want){
  $m=(NodeOf (GetBr) $node.nodeId).match
  if(-not $m){ Check "$label has a match to play" $false; return $null }
  $a=$m.competitorA.player; $c=$m.competitorB.player
  $side = if($want -eq 'A' -or $want -eq 'B'){ $want } elseif($want -eq $a){ 'A' } else { 'B' }
  Expect "$label start" (Call POST "/matches/$($m.matchId)/start" $null $tok) 200
  $r=Call POST "/matches/$($m.matchId)/result" @{type='Winner';winner=$side} $tok
  Expect "$label : $a vs $c, $side wins" $r 200
  $win = if($side -eq 'A'){ $a } else { $c }
  $los = if($side -eq 'A'){ $c } else { $a }
  [pscustomobject]@{mid=$m.matchId;winner=$win;loser=$los;a=$a;b=$c}
}
function Roles {
  $b=GetBr
  $n=@($b.Json.nodes)
  $script:R=@{
    b=$b
    wb1=@($n | Where-Object { $_.stage -eq 'Winners' -and $_.round -eq 1 } | Sort-Object nodeId)
    wbF=@($n | Where-Object { $_.stage -eq 'Winners' -and $_.round -eq 2 })[0]
    lb1=@($n | Where-Object { $_.stage -eq 'Losers'  -and $_.round -eq 1 })[0]
    lbF=@($n | Where-Object { $_.stage -eq 'Losers'  -and $_.round -eq 2 })[0]
    gf1=(NodeOf $b $b.Json.grandFinalNodeId)
    rst=(NodeOf $b $b.Json.resetNodeId)
  }
}
function NewDE($label){
  $r=Call POST '/tournaments' @{name="DE $label $id";organizer='E2E Runner';format='DoubleElimination';visibility='Public';maxParticipants=4} $tok
  Expect "[$label] create DoubleElimination" $r 201
  $script:tid=$r.Json.tournamentId
  $t=$script:tid
  Expect "[$label] publish" (Call POST "/tournaments/$t/publish" $null $tok) 204
  Expect "[$label] open registration" (Call POST "/tournaments/$t/open-registration" $null $tok) 204
  foreach($n in 'Ayo','Bela','Chidi','Dara'){
    Expect "[$label] register $n" (Call POST "/tournaments/$t/registrations" @{type='Individual';player=$n} $tok) 201
  }
  Expect "[$label] close registration" (Call POST "/tournaments/$t/close-registration" $null $tok) 204
  Expect "[$label] generate bracket" (Call POST "/tournaments/$t/bracket" $null $tok) 201
  Expect "[$label] start tournament" (Call POST "/tournaments/$t/start" $null $tok) 204
}
function Shape($label){
  $R=$script:R; $b=$R.b; $nodes=@($b.Json.nodes)
  Check "[$label] 7 nodes" ($nodes.Count -eq 7) "$($nodes.Count)"
  Check "[$label] format DoubleElimination" ($b.Json.format -eq 'DoubleElimination')
  Check "[$label] grand final + reset ids present" (($null -ne $b.Json.grandFinalNodeId) -and ($null -ne $b.Json.resetNodeId))
  Check "[$label] no third-place node" ($null -eq $b.Json.thirdPlaceNodeId)
  Check "[$label] standings is null (not round robin)" ($null -eq $b.Json.standings)
  Check "[$label] linksAvailable" ($b.Json.linksAvailable -eq $true)
  Check "[$label] roles found: 2 WB1, WB final, LB1, LB final, GF1, reset" (($R.wb1.Count -eq 2) -and $R.wbF -and $R.lb1 -and $R.lbF -and $R.gf1 -and $R.rst)
  Check "[$label] only the 2 WB round-1 nodes have matches" ((@($nodes | Where-Object { $_.match }).Count -eq 2) -and (@($R.wb1 | Where-Object { $_.match }).Count -eq 2))
  $w0=$R.wb1[0]; $w1=$R.wb1[1]
  Check "[$label] WB1 winners -> WB final (slots A,B)" ((LinkTo $w0 'winnerTo' $R.wbF @('A','B')) -and (LinkTo $w1 'winnerTo' $R.wbF @('A','B')) -and ((@($w0.winnerTo.slot,$w1.winnerTo.slot)|Sort-Object) -join ',') -eq 'A,B')
  Check "[$label] WB1 losers -> LB1 (slots A,B)" ((LinkTo $w0 'loserTo' $R.lb1 @('A','B')) -and (LinkTo $w1 'loserTo' $R.lb1 @('A','B')) -and ((@($w0.loserTo.slot,$w1.loserTo.slot)|Sort-Object) -join ',') -eq 'A,B')
  Check "[$label] WB final: winner -> GF1 A, loser -> LB final A" ((LinkTo $R.wbF 'winnerTo' $R.gf1 @('A')) -and (LinkTo $R.wbF 'loserTo' $R.lbF @('A')))
  Check "[$label] LB1: winner -> LB final B, no loser link" ((LinkTo $R.lb1 'winnerTo' $R.lbF @('B')) -and ($null -eq $R.lb1.loserTo))
  Check "[$label] LB final: winner -> GF1 B, no loser link" ((LinkTo $R.lbF 'winnerTo' $R.gf1 @('B')) -and ($null -eq $R.lbF.loserTo))
  Check "[$label] GF1: winner -> reset A, loser -> reset B" ((LinkTo $R.gf1 'winnerTo' $R.rst @('A')) -and (LinkTo $R.gf1 'loserTo' $R.rst @('B')))
  Check "[$label] reset has no outgoing links" (($null -eq $R.rst.winnerTo) -and ($null -eq $R.rst.loserTo))
  Check "[$label] stages: WB final/GF1/reset Winners, LB nodes Losers" (($R.wbF.stage -eq 'Winners') -and ($R.gf1.stage -eq 'Winners') -and ($R.lb1.stage -eq 'Losers') -and ($R.lbF.stage -eq 'Losers'))
  Check "[$label] waiting slots typed correctly" (($R.wbF.slotA.type -eq 'AwaitingWinnerOf') -and ($R.lb1.slotA.type -eq 'AwaitingLoserOf') -and ($R.lbF.slotA.type -eq 'AwaitingLoserOf') -and ($R.lbF.slotB.type -eq 'AwaitingWinnerOf') -and ($R.gf1.slotB.type -eq 'AwaitingWinnerOf') -and ($R.rst.slotA.type -eq 'AwaitingWinnerOf') -and ($R.rst.slotB.type -eq 'AwaitingLoserOf'))
}
function ToGF1($label,$full){
  $R=$script:R
  $w0=$R.wb1[0]; $w1=$R.wb1[1]
  $p1=Play "[$label] WB R1 #1" $w0 'A'
  Holds "[$label] WB final" $R.wbF.nodeId $w0.winnerTo.slot $p1.winner
  Holds "[$label] LB1" $R.lb1.nodeId $w0.loserTo.slot $p1.loser
  NoMatch "[$label] WB final" $R.wbF.nodeId
  NoMatch "[$label] LB1" $R.lb1.nodeId
  $p2=Play "[$label] WB R1 #2" $w1 'A'
  Holds "[$label] WB final" $R.wbF.nodeId $w1.winnerTo.slot $p2.winner
  Holds "[$label] LB1" $R.lb1.nodeId $w1.loserTo.slot $p2.loser
  MatchIs "[$label] WB final" $R.wbF.nodeId @($p1.winner,$p2.winner) 'Scheduled'
  MatchIs "[$label] LB1" $R.lb1.nodeId @($p1.loser,$p2.loser) 'Scheduled'
  if($full){
    $cr=Call PUT "/matches/$($p1.mid)/result" @{type='Winner';winner='B'} $tok
    Expect "[$label] correct WB R1 #1 (B wins instead)" $cr 200
    $t=$p1.winner; $p1.winner=$p1.loser; $p1.loser=$t
    Holds "[$label] WB final after correction" $R.wbF.nodeId $w0.winnerTo.slot $p1.winner
    Holds "[$label] LB1 after correction" $R.lb1.nodeId $w0.loserTo.slot $p1.loser
    MatchIs "[$label] WB final after correction" $R.wbF.nodeId @($p1.winner,$p2.winner) 'Scheduled'
    MatchIs "[$label] LB1 after correction" $R.lb1.nodeId @($p1.loser,$p2.loser) 'Scheduled'
    Check "[$label] corrected outcome persisted (winner B)" ((NodeOf (GetBr) $w0.nodeId).match.outcome.winner -eq 'B')
  }
  $p3=Play "[$label] WB final" $R.wbF 'A'
  Holds "[$label] GF1" $R.gf1.nodeId $R.wbF.winnerTo.slot $p3.winner
  Holds "[$label] LB final" $R.lbF.nodeId $R.wbF.loserTo.slot $p3.loser
  NoMatch "[$label] GF1" $R.gf1.nodeId
  NoMatch "[$label] LB final" $R.lbF.nodeId
  if($full){
    Expect "[$label] correcting WB R1 after WB final played is blocked" (Call PUT "/matches/$($p1.mid)/result" @{type='Winner';winner='A'} $tok) 409 'DOWNSTREAM_MATCH_STARTED'
  }
  $p4=Play "[$label] LB1" $R.lb1 'A'
  Holds "[$label] LB final" $R.lbF.nodeId $R.lb1.winnerTo.slot $p4.winner
  MatchIs "[$label] LB final" $R.lbF.nodeId @($p3.loser,$p4.winner) 'Scheduled'
  $p5=Play "[$label] LB final (LB1 winner takes it)" $R.lbF $p4.winner
  Holds "[$label] GF1" $R.gf1.nodeId $R.lbF.winnerTo.slot $p4.winner
  MatchIs "[$label] GF1" $R.gf1.nodeId @($p3.winner,$p4.winner) 'Scheduled'
  NoMatch "[$label] reset" $R.rst.nodeId
  Check "[$label] reset slots still waiting" (((NodeOf (GetBr) $R.rst.nodeId).slotA.type -eq 'AwaitingWinnerOf') -and ((NodeOf (GetBr) $R.rst.nodeId).slotB.type -eq 'AwaitingLoserOf'))
  [pscustomobject]@{wf=$p3.winner;lw=$p4.winner}
}

# ---------- Setup
Stage 'Setup'
$r=Call GET '/health'; Expect 'backend reachable' $r 200
if($r.Status -ne 200){ exit 1 }
$id=Get-Random -Maximum 999999; $user="de_$id"; $pw='Passw0rd!de'
Expect 'register' (Call POST '/register' @{username=$user;email="$user@example.com";password=$pw}) 201
$tok=(Call POST '/login' @{username=$user;password=$pw}).Json.token
Check 'got a token' ($tok -match '^[0-9a-f]{64}$')

# ---------- Tournament A: reset path
Stage 'A1 Create and bracket shape'
NewDE 'A'; Roles; Shape 'A'
Stage 'A2 Play to the grand final (with WB corrections)'
$g=ToGF1 'A' $true
Stage 'A3 LB champion wins GF1 -> reset is played'
$gf=$script:R.gf1; $rst=$script:R.rst
$pg=Play '[A] GF1 (LB champion wins)' $gf $g.lw
Holds '[A] reset' $rst.nodeId $gf.winnerTo.slot $g.lw
Holds '[A] reset' $rst.nodeId $gf.loserTo.slot $g.wf
MatchIs '[A] reset' $rst.nodeId @($g.lw,$g.wf) 'Scheduled'
Expect '[A] complete before reset is played refused' (Call POST "/tournaments/$script:tid/complete" $null $tok) 409 'TOURNAMENT_NOT_COMPLETE'
$pr=Play '[A] reset (WB champion wins)' $rst $g.wf
Expect '[A] complete tournament' (Call POST "/tournaments/$script:tid/complete" $null $tok) 200
$v=Call GET "/tournaments/$script:tid" $null $tok
Check '[A] state persisted as Completed' ($v.Json.tournament.state -eq 'Completed') $v.Json.tournament.state
Expect '[A] complete again refused' (Call POST "/tournaments/$script:tid/complete" $null $tok) 409 'TOURNAMENT_ALREADY_COMPLETED'

# ---------- Tournament B: GF1 correction retracts the reset
Stage 'B1 Create and play to the grand final'
NewDE 'B'; Roles; Shape 'B'
$g=ToGF1 'B' $false
Stage 'B2 GF1 correction: reset required -> decisive'
$gf=$script:R.gf1; $rst=$script:R.rst
$pg=Play '[B] GF1 (LB champion wins)' $gf $g.lw
MatchIs '[B] reset' $rst.nodeId @($g.lw,$g.wf) 'Scheduled'
$toWF=SideOf $pg $g.wf
Expect '[B] correct GF1 to WB champion (reset retracted)' (Call PUT "/matches/$($pg.mid)/result" @{type='Winner';winner=$toWF} $tok) 200
NoMatch '[B] reset (after retraction)' $rst.nodeId
$rn=NodeOf (GetBr) $rst.nodeId
Check '[B] reset node voided to Bye/Bye' (($rn.slotA.type -eq 'Bye') -and ($rn.slotB.type -eq 'Bye')) "$($rn.slotA.type)/$($rn.slotB.type)"
Check '[B] GF1 now shows the WB champion as winner' ((NodeOf (GetBr) $gf.nodeId).match.outcome.winner -eq $toWF)
Stage 'B3 Decisive -> reset required (documented refusal)'
$toLW=SideOf $pg $g.lw
$r=Call PUT "/matches/$($pg.mid)/result" @{type='Winner';winner=$toLW} $tok
Expect '[B] back-correction refused: 409 GF1_RESET_NOT_RESTORABLE' $r 409 'GF1_RESET_NOT_RESTORABLE'
Info "back-correction returned HTTP $($r.Status) code '$(Code $r)' (expected a 4xx; CorrectionIntegrityViolation maps to internalError = 500)"
Check '[B] refused correction changed nothing (GF1 winner)' ((NodeOf (GetBr) $gf.nodeId).match.outcome.winner -eq $toWF)
NoMatch '[B] reset (still absent)' $rst.nodeId
Stage 'B4 Complete'
Expect '[B] complete tournament (decisive GF1)' (Call POST "/tournaments/$script:tid/complete" $null $tok) 200
$v=Call GET "/tournaments/$script:tid" $null $tok
Check '[B] state persisted as Completed' ($v.Json.tournament.state -eq 'Completed') $v.Json.tournament.state
Done
