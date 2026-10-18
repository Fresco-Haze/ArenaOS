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
function ScoreIs($label,$nid,$sa,$sb){
  $s=(NodeOf (GetBr) $nid).score
  Check "$label score is $sa-$sb" ($null -ne $s -and $s.a -eq $sa -and $s.b -eq $sb) "got $(if($null -eq $s){'none'}else{"$($s.a)-$($s.b)"})"
}
function ScoreNone($label,$nid){
  $s=(NodeOf (GetBr) $nid).score
  Check "$label has no stored score" ($null -eq $s) "got $($s.a)-$($s.b)"
}
function Unscored($label,$n){
  $u=(GetBr).Json.unscoredMatches
  Check "$label unscoredMatches is $n" ($u -eq $n) "got $u"
}
function WinnerIs($label,$nid,$side){
  $o=(NodeOf (GetBr) $nid).match.outcome
  Check "$label outcome is Winner $side" (($o.type -eq 'Winner') -and ($o.winner -eq $side)) "got $($o.type) $($o.winner)"
}
function Ef($method,$mid,$sa,$sb){ Call $method "/matches/$mid/efootball-result" @{scoreA=$sa;scoreB=$sb} $tok }
function Rec($label,$node,$sa,$sb){
  $m=(NodeOf (GetBr) $node.nodeId).match
  if(-not $m){ Check "$label has a match to play" $false; return $null }
  Expect "$label start" (Call POST "/matches/$($m.matchId)/start" $null $tok) 200
  $res=Ef POST $m.matchId $sa $sb
  Expect "$label : $($m.competitorA.player) $sa-$sb $($m.competitorB.player)" $res 200
  [pscustomobject]@{mid=$m.matchId;a=$m.competitorA.player;b=$m.competitorB.player}
}
function LnkStr($l){ if($null -eq $l){ '-' } else { "$($l.node)$($l.slot)" } }
function Dump($b){
  foreach($nd in @($b.Json.nodes | Sort-Object round,nodeId)){
    Info ("{0,4} R{1} A={2,-16} B={3,-16} match={4,-5} W>{5}" -f $nd.nodeId,$nd.round,(Pname $nd.slotA),(Pname $nd.slotB),[bool]$nd.match,(LnkStr $nd.winnerTo))
  }
}
function Roles {
  $b=GetBr; $nn=@($b.Json.nodes)
  $script:rl=@{
    b=$b
    semis=@($nn | Where-Object { $_.round -eq 1 } | Sort-Object nodeId)
    final=@($nn | Where-Object { $_.round -eq 2 })[0]
  }
  $h=$script:rl
  $script:rolesOk=[bool](($h.semis.Count -eq 2) -and $h.final -and $h.semis[0].winnerTo)
}
function NewSE($label){
  $resp=Call POST '/tournaments' @{name="EF $label $id";organizer='E2E Runner';format='SingleElimination';visibility='Public';maxParticipants=4;thirdPlaceMatch=$false} $tok
  Expect "[$label] create SingleElimination (4 players)" $resp 201
  $script:tid=$resp.Json.tournamentId
  $tt=$script:tid
  Expect "[$label] publish" (Call POST "/tournaments/$tt/publish" $null $tok) 204
  Expect "[$label] open registration" (Call POST "/tournaments/$tt/open-registration" $null $tok) 204
  foreach($nm in 'Ayo','Bela','Chidi','Dara'){
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
$id=Get-Random -Maximum 999999; $user="ef_$id"; $pw='Passw0rd!ef'
Expect 'register' (Call POST '/register' @{username=$user;email="$user@example.com";password=$pw}) 201
$tok=(Call POST '/login' @{username=$user;password=$pw}).Json.token
Check 'got a token' ($tok -match '^[0-9a-f]{64}$')

# ---------- A
Stage 'A1 Score-derived outcomes and rejected inputs'
NewSE 'A'; Roles
if(-not $script:rolesOk){ Check '[A] roles found (2 semis with links, final)' $false; Dump $script:rl.b; Done }
$x=$script:rl; $s0=$x.semis[0]; $s1=$x.semis[1]
$p0=Rec '[A] semi 1' $s0 3 1
WinnerIs '[A] semi 1' $s0.nodeId 'A'
ScoreIs '[A] semi 1' $s0.nodeId 3 1
Holds '[A] final' $x.final.nodeId $s0.winnerTo.slot 'Ayo'
$m1=(NodeOf (GetBr) $s1.nodeId).match
Expect '[A] start semi 2' (Call POST "/matches/$($m1.matchId)/start" $null $tok) 200
Expect '[A] draw score refused (nobody advances)' (Ef POST $m1.matchId 2 2) 409 'OUTCOME_NOT_ADVANCEABLE'
Expect '[A] negative score refused' (Ef POST $m1.matchId -1 2) 400 'INVALID_BODY'
$mm=(NodeOf (GetBr) $s1.nodeId).match
Check '[A] refused attempts left semi 2 InProgress, no score' (($mm.status -eq 'InProgress') -and ($null -eq (NodeOf (GetBr) $s1.nodeId).score)) "$($mm.status)"
$r1=Ef POST $m1.matchId 0 1
Expect '[A] semi 2 : Chidi 0-1 Dara' $r1 200
WinnerIs '[A] semi 2' $s1.nodeId 'B'
Holds '[A] final' $x.final.nodeId $s1.winnerTo.slot 'Dara'
MatchIs '[A] final' $x.final.nodeId @('Ayo','Dara') 'Scheduled'
Unscored '[A]' 0

Stage 'A2 Correct keeping the winner: score is overwritten'
Expect '[A] correct semi 1 to 5-0' (Ef PUT $p0.mid 5 0) 200
ScoreIs '[A] semi 1' $s0.nodeId 5 0
WinnerIs '[A] semi 1' $s0.nodeId 'A'
Holds '[A] final unchanged' $x.final.nodeId $s0.winnerTo.slot 'Ayo'

Stage 'A3 Correct flipping the winner: score replaced, bracket follows'
Expect '[A] correct semi 1 to 0-2' (Ef PUT $p0.mid 0 2) 200
ScoreIs '[A] semi 1' $s0.nodeId 0 2
WinnerIs '[A] semi 1' $s0.nodeId 'B'
Holds '[A] final' $x.final.nodeId $s0.winnerTo.slot 'Bela'
MatchIs '[A] final' $x.final.nodeId @('Bela','Dara') 'Scheduled'

Stage 'A4 Correcting to a draw is refused, nothing changes'
Expect '[A] correct semi 1 to 1-1 refused' (Ef PUT $p0.mid 1 1) 409 'OUTCOME_NOT_ADVANCEABLE'
ScoreIs '[A] semi 1 (unchanged)' $s0.nodeId 0 2
WinnerIs '[A] semi 1 (unchanged)' $s0.nodeId 'B'
Holds '[A] final (unchanged)' $x.final.nodeId $s0.winnerTo.slot 'Bela'

Stage 'A5 Plain result correction: stale score dropped only if winner changes'
Expect '[A] plain correct, same winner (B)' (Call PUT "/matches/$($p0.mid)/result" @{type='Winner';winner='B'} $tok) 200
ScoreIs '[A] semi 1 (winner unchanged, score kept)' $s0.nodeId 0 2
Unscored '[A]' 0
Expect '[A] plain correct, flipped winner (A)' (Call PUT "/matches/$($p0.mid)/result" @{type='Winner';winner='A'} $tok) 200
ScoreNone '[A] semi 1 (winner flipped, stale score dropped)' $s0.nodeId
Unscored '[A]' 1
Holds '[A] final' $x.final.nodeId $s0.winnerTo.slot 'Ayo'
Stage 'A6 Score correction restores a score'
Expect '[A] correct semi 1 to 4-3' (Ef PUT $p0.mid 4 3) 200
ScoreIs '[A] semi 1' $s0.nodeId 4 3
Unscored '[A]' 0

Stage 'A7 Started final blocks score correction (rollback)'
$fm=(NodeOf (GetBr) $x.final.nodeId).match
Expect '[A] start final' (Call POST "/matches/$($fm.matchId)/start" $null $tok) 200
Expect '[A] correct semi 1 after final started refused' (Ef PUT $p0.mid 0 1) 409 'DOWNSTREAM_MATCH_STARTED'
ScoreIs '[A] semi 1 (score untouched by refused correction)' $s0.nodeId 4 3
WinnerIs '[A] semi 1 (unchanged)' $s0.nodeId 'A'

Stage 'A8 Finish and completion guard'
Expect '[A] final : Ayo 2-0 Dara' (Ef POST $fm.matchId 2 0) 200
Expect '[A] complete tournament' (Call POST "/tournaments/$script:tid/complete" $null $tok) 200
Expect '[A] score correction after completion refused' (Ef PUT $p0.mid 0 1) 409 'TOURNAMENT_ALREADY_COMPLETED'
ScoreIs '[A] semi 1 (unchanged)' $s0.nodeId 4 3

# ---------- B
Stage 'B Result without a score, then a score correction attaches one'
NewSE 'B'; Roles
if(-not $script:rolesOk){ Check '[B] roles found' $false; Done }
$x=$script:rl; $t0=$x.semis[0]
$bm=(NodeOf (GetBr) $t0.nodeId).match
Expect '[B] start semi 1' (Call POST "/matches/$($bm.matchId)/start" $null $tok) 200
Expect '[B] plain result: A wins' (Call POST "/matches/$($bm.matchId)/result" @{type='Winner';winner='A'} $tok) 200
ScoreNone '[B] semi 1' $t0.nodeId
Unscored '[B]' 1
Expect '[B] score correction 2-1 (same winner)' (Ef PUT $bm.matchId 2 1) 200
ScoreIs '[B] semi 1' $t0.nodeId 2 1
Unscored '[B]' 0

# ---------- C: probe
Stage 'C Probe: score correction on matches that are not completed (INFO only)'
NewSE 'C'; Roles
$x=$script:rl
$cm0=(NodeOf (GetBr) $x.semis[0].nodeId).match
$cm1=(NodeOf (GetBr) $x.semis[1].nodeId).match
$pr=Ef PUT $cm0.matchId 2 1
Info "PUT efootball-result on a Scheduled match -> HTTP $($pr.Status) '$(Code $pr)'"
Expect '[C] start semi 2' (Call POST "/matches/$($cm1.matchId)/start" $null $tok) 200
$pr2=Ef PUT $cm1.matchId 2 1
Info "PUT efootball-result on an InProgress match -> HTTP $($pr2.Status) '$(Code $pr2)'"
foreach($pair in @(@('Scheduled',$x.semis[0],$pr),@('InProgress',$x.semis[1],$pr2))){
  $nm=(NodeOf (GetBr) $pair[1].nodeId).match
  Info "after probe the $($pair[0]) match is now status $($nm.status), outcome $($nm.outcome.type)"
}
Done
