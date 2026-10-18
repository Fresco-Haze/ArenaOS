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
function PN($p){ if($p.type -eq 'Squad'){ $p.team.name } else { $p.player } }
function Pname($slot){ if($slot.type -eq 'Filled'){ PN $slot.participant } else { "<$($slot.type)>" } }
function PairKey($m){ (@((PN $m.competitorA),(PN $m.competitorB)) | Sort-Object) -join ',' }
function GetBr { Call GET "/tournaments/$script:tid/bracket" $null $script:tok }
function NodeOf($b,$nid){ @($b.Json.nodes | Where-Object { $_.nodeId -eq $nid })[0] }
function St { (Call GET "/tournaments/$script:tid" $null $script:tok).Json.tournament.state }
function StateIs($label,$want){ $got=St; Check "$label state is $want" ($got -eq $want) "got $got" }
function Refused($label,$x,$status,$code,$wantState){
  Expect $label $x $status $code
  StateIs "  after '$label'" $wantState
}
function Skip($label){ Info "[$label] setup failed, scenario skipped" }
function RegS($tid,$name,$token=$script:tok){ Call POST "/tournaments/$tid/registrations" @{type='Squad';teamName=$name} $token }
function RegI($tid,$name,$token=$script:tok){ Call POST "/tournaments/$tid/registrations" @{type='Individual';player=$name} $token }
function MkTeam($name,$cap,$members,$token=$script:tok){ Call POST '/teams' @{name=$name;captain=$cap;members=$members} $token }
function NewT($label,$mode,$max,$stage){
  $before=$script:fail
  $resp=Call POST '/tournaments' @{name="SQ $label $script:id";organizer='E2E Runner';format='SingleElimination';visibility='Public';maxParticipants=$max;thirdPlaceMatch=$false;participantMode=$mode} $script:tok
  Expect "[$label] create $mode tournament (max $max, $stage)" $resp 201
  if($resp.Status -ne 201){ return $false }
  $script:tid=$resp.Json.tournamentId
  if($stage -eq 'open'){
    Expect "[$label] publish" (Call POST "/tournaments/$($script:tid)/publish" $null $script:tok) 204
    Expect "[$label] open registration" (Call POST "/tournaments/$($script:tid)/open-registration" $null $script:tok) 204
  }
  return ($script:fail -eq $before)
}
function HoldsSquad($label,$nid,$pos,$name){
  $n=NodeOf (GetBr) $nid
  $s= if($pos -eq 'A'){ $n.slotA } else { $n.slotB }
  $ok=($s.type -eq 'Filled') -and ($s.participant.type -eq 'Squad') -and ($s.participant.team.name -eq $name) -and ((@($s.participant.team.members) -join ',') -eq ($script:members[$name] -join ','))
  Check "$label slot $pos holds squad '$name' with its members" $ok "got $(Pname $s)"
}
function PlayS($label,$node,$side){
  $m=(NodeOf (GetBr) $node.nodeId).match
  if(-not $m){ Check "$label has a match to play" $false; return $null }
  $a=PN $m.competitorA; $c=PN $m.competitorB
  Expect "$label start" (Call POST "/matches/$($m.matchId)/start" $null $script:tok) 200
  Expect "$label : $a vs $c, $side wins" (Call POST "/matches/$($m.matchId)/result" @{type='Winner';winner=$side} $script:tok) 200
  [pscustomobject]@{mid=$m.matchId;a=$a;b=$c;winner=$(if($side -eq 'A'){$a}else{$c});loser=$(if($side -eq 'A'){$c}else{$a})}
}

# ---------- Setup
Stage 'Setup'
$health=Call GET '/health'; Expect 'backend reachable' $health 200
if($health.Status -ne 200){ exit 1 }
$id=Get-Random -Maximum 999999; $script:id=$id; $pw='Passw0rd!sq'
$u1="sq_$id"; $u2="sq_${id}b"
Expect 'register owner' (Call POST '/register' @{username=$u1;email="$u1@example.com";password=$pw}) 201
Expect 'register other user' (Call POST '/register' @{username=$u2;email="$u2@example.com";password=$pw}) 201
$script:tok=(Call POST '/login' @{username=$u1;password=$pw}).Json.token
$tok2=(Call POST '/login' @{username=$u2;password=$pw}).Json.token
$sessOk=(($script:tok -match '^[0-9a-f]{64}$') -and ($tok2 -match '^[0-9a-f]{64}$'))
Check 'both sessions obtained' $sessOk
if(-not $sessOk){ Done }

# ---------- S1 team creation
Stage 'S1 Team creation and listing'
$script:members=@{}
$teamNames='Lions','Tigers','Bears','Wolves','Hawks','Foxes','Otters'
$teams=@()
foreach($tn in $teamNames){
  $nm="$tn $id"; $mem=@("${tn}1_$id","${tn}2_$id")
  $teams += ,@($nm,$mem)
  $script:members[$nm]=$mem
}
$t0=$teams[0]
Expect '[S1] create without token refused' (MkTeam $t0[0] $t0[1][0] $t0[1] $null) 401 'UNAUTHENTICATED'
Expect '[S1] no token AND bad body: auth first' (Call POST '/teams' @{name='x'} $null) 401 'UNAUTHENTICATED'
Expect '[S1] missing fields refused' (Call POST '/teams' @{name='x'} $script:tok) 400 'INVALID_BODY'
$cn=MkTeam $t0[0] 'Nobody' $t0[1]
Expect '[S1] captain not in members refused' $cn 400 'VALIDATION_FAILED'
Check '[S1] error names the captain field' ($cn.Json.error.details.field -eq 'captain') "$($cn.Raw)"
Expect '[S1] empty members refused' (MkTeam "Empty $id" 'Nobody' @()) 400 'VALIDATION_FAILED'
$r=MkTeam $t0[0] $t0[1][0] $t0[1]
Expect "[S1] create team '$($t0[0])'" $r 201
Check '[S1] response echoes name, captain, members' (($r.Json.name -eq $t0[0]) -and ($r.Json.captain -eq $t0[1][0]) -and ((@($r.Json.members) -join ',') -eq ($t0[1] -join ','))) "$($r.Raw)"
$dup=MkTeam $t0[0] $t0[1][0] $t0[1]
Expect '[S1] duplicate name refused' $dup 409 'TEAM_NAME_TAKEN'
Check '[S1] error carries the name' ($dup.Json.error.details.name -eq $t0[0]) "$($dup.Raw)"
Expect '[S1] duplicate name by another user refused (names are global)' (MkTeam $t0[0] $t0[1][0] $t0[1] $tok2) 409 'TEAM_NAME_TAKEN'
Expect '[S1] bad captain beats duplicate name' (MkTeam $t0[0] 'Nobody' $t0[1]) 400 'VALIDATION_FAILED'
for($i=1;$i -lt $teams.Count;$i++){
  Expect "[S1] create team '$($teams[$i][0])'" (MkTeam $teams[$i][0] $teams[$i][1][0] $teams[$i][1]) 201
}
Expect '[S1] list without token refused' (Call GET '/teams') 401 'UNAUTHENTICATED'
$lt=Call GET '/teams' $null $script:tok
Expect '[S1] list teams' $lt 200
$missing=@($teams | Where-Object { $n=$_[0]; @($lt.Json.teams | Where-Object { $_.name -eq $n }).Count -ne 1 })
Check '[S1] all 7 new teams listed exactly once' ($missing.Count -eq 0) "missing: $(($missing | ForEach-Object { $_[0] }) -join ', ')"
$lt2=Call GET '/teams' $null $tok2
Check '[S1] the other user sees the same teams (global)' (@($lt2.Json.teams | Where-Object { $_.name -eq $t0[0] }).Count -eq 1)

# ---------- S2 registration rules
Stage 'S2a State precedes kind (Draft, individual-only, squad submitted)'
if(NewT 'W' 'IndividualOnly' 4 'draft'){
  $tidW=$script:tid
  Refused '[W] squad into a Draft individual tournament: state error first' (RegS $tidW $t0[0]) 409 'INVALID_TRANSITION' 'Draft'
} else { Skip 'W' }

Stage 'S2b Individual-only tournament rejects squads'
if(NewT 'I' 'IndividualOnly' 4 'open'){
  $tidI=$script:tid
  $ri=RegS $tidI $t0[0]
  Expect '[I] squad into individual tournament refused' $ri 409 'PARTICIPANT_KIND_NOT_ALLOWED'
  Check '[I] error says IndividualOnly is allowed' ($ri.Json.error.details.allowed -eq 'IndividualOnly') "$($ri.Raw)"
  Expect '[I] individual still accepted' (RegI $tidI 'Solo') 201
  $vi=Call GET "/tournaments/$tidI" $null $script:tok
  Check '[I] only the individual is registered' ((@($vi.Json.participants).Count -eq 1) -and ($vi.Json.participants[0].type -eq 'Individual')) "$(@($vi.Json.participants).Count)"
} else { Skip 'I' }

Stage 'S2c Squad tournament registration rules (capacity 2)'
if(NewT 'Q' 'SquadOnly' 2 'open'){
  $tidQ=$script:tid
  $rq=RegI $tidQ 'Solo'
  Expect '[Q] individual into squad tournament refused' $rq 409 'PARTICIPANT_KIND_NOT_ALLOWED'
  Check '[Q] error says SquadOnly is allowed' ($rq.Json.error.details.allowed -eq 'SquadOnly') "$($rq.Raw)"
  Expect '[Q] unknown team refused' (RegS $tidQ "NoSuchTeam $id") 404 'NOT_FOUND'
  Expect '[Q] non-owner registering a known team refused' (RegS $tidQ $teams[0][0] $tok2) 403 'NOT_TOURNAMENT_OWNER'
  Expect '[Q] missing teamName refused' (Call POST "/tournaments/$tidQ/registrations" @{type='Squad'} $script:tok) 400 'INVALID_BODY'
  Expect '[Q] unknown participant type refused' (Call POST "/tournaments/$tidQ/registrations" @{type='Alien';teamName='x'} $script:tok) 400 'INVALID_BODY'
  $rg=RegS $tidQ $teams[0][0]
  Expect "[Q] register '$($teams[0][0])'" $rg 201
  Check '[Q] registrationId returned' ($rg.Json.registrationId -gt 0)
  Expect '[Q] same team again refused' (RegS $tidQ $teams[0][0]) 409 'ALREADY_REGISTERED'
  Expect "[Q] register '$($teams[1][0])'" (RegS $tidQ $teams[1][0]) 201
  Expect '[Q] third team refused (full)' (RegS $tidQ $teams[2][0]) 409 'REGISTRATION_CAPACITY_REACHED'
  $vq=Call GET "/tournaments/$tidQ" $null $script:tok
  $ps=@($vq.Json.participants)
  Check '[Q] exactly 2 squads registered' (($ps.Count -eq 2) -and (@($ps | Where-Object { $_.type -eq 'Squad' }).Count -eq 2)) "$($ps.Count)"
  $okm=$true; foreach($pp in $ps){ if((@($pp.team.members) -join ',') -ne ($script:members[$pp.team.name] -join ',')){ $okm=$false } }
  Check '[Q] registered squads carry the right members' $okm
  Check '[Q] tournament reports SquadOnly' ($vq.Json.tournament.participantMode -eq 'SquadOnly')
} else { Skip 'Q' }

# ---------- S3 play-through
Stage 'S3 Four-team squad tournament, played through'
if(NewT 'S3' 'SquadOnly' 4 'open'){
  $tidS=$script:tid
  for($i=3;$i -le 6;$i++){ Expect "[S3] register '$($teams[$i][0])'" (RegS $tidS $teams[$i][0]) 201 }
  Expect '[S3] close registration' (Call POST "/tournaments/$tidS/close-registration" $null $script:tok) 204
  Expect '[S3] generate bracket' (Call POST "/tournaments/$tidS/bracket" $null $script:tok) 201
  Expect '[S3] start tournament' (Call POST "/tournaments/$tidS/start" $null $script:tok) 204
  $b=GetBr; $nn=@($b.Json.nodes)
  $semis=@($nn | Where-Object { $_.round -eq 1 } | Sort-Object nodeId)
  $final=@($nn | Where-Object { $_.round -eq 2 })[0]
  if(-not (($semis.Count -eq 2) -and $final)){ Check '[S3] roles found (2 semis, final)' $false }
  else {
    Check '[S3] both semifinals are squad vs squad' (@($semis | Where-Object { ($_.match.competitorA.type -eq 'Squad') -and ($_.match.competitorB.type -eq 'Squad') }).Count -eq 2)
    $p1=PlayS '[S3] semi 1' $semis[0] 'A'
    HoldsSquad '[S3] final' $final.nodeId $semis[0].winnerTo.slot $p1.winner
    $p2=PlayS '[S3] semi 2' $semis[1] 'A'
    HoldsSquad '[S3] final' $final.nodeId $semis[1].winnerTo.slot $p2.winner
    $fm=(NodeOf (GetBr) $final.nodeId).match
    Check '[S3] final is Scheduled between the two winners' (($null -ne $fm) -and ((PairKey $fm) -eq ((@($p1.winner,$p2.winner) | Sort-Object) -join ','))) "$(if($fm){PairKey $fm})"
    Expect '[S3] correct semi 1 (B wins instead)' (Call PUT "/matches/$($p1.mid)/result" @{type='Winner';winner='B'} $script:tok) 200
    HoldsSquad '[S3] final after correction' $final.nodeId $semis[0].winnerTo.slot $p1.loser
    $fm2=(NodeOf (GetBr) $final.nodeId).match
    Check '[S3] final match now holds the corrected winner, not the old one' (($null -ne $fm2) -and ((PairKey $fm2) -eq ((@($p1.loser,$p2.winner) | Sort-Object) -join ','))) "$(if($fm2){PairKey $fm2})"
    $pf=PlayS '[S3] final' $final 'A'
    Expect '[S3] complete tournament' (Call POST "/tournaments/$tidS/complete" $null $script:tok) 200
    StateIs '[S3] end' 'Completed'
    $vs=Call GET "/tournaments/$tidS" $null $script:tok
    Check '[S3] 4 squads on the tournament view' ((@($vs.Json.participants).Count -eq 4) -and (@($vs.Json.participants | Where-Object { $_.type -eq 'Squad' }).Count -eq 4))
  }
} else { Skip 'S3' }

# ---------- Probes (INFO only)
Stage 'P Probes (informational, nothing asserted)'
if(NewT 'P' 'SquadOnly' 8 'open'){
  $tidP=$script:tid
  $blank=(' ' * (3 + (Get-Random -Maximum 60)))
  $pb=MkTeam $blank "blank_$id" @("blank_$id")
  Info "PROBE create team with a blank name -> HTTP $($pb.Status) '$(Code $pb)'"
  if($pb.Status -eq 201){
    $pr=RegS $tidP $blank
    Info "PROBE register that blank-named team -> HTTP $($pr.Status) '$(Code $pr)' (201 would mean blank names pass; 400 means a team can exist that can never register)"
  }
  $pd=MkTeam "Dup $id" "d_$id" @("d_$id","d_$id")
  Info "PROBE duplicate member names in one team -> HTTP $($pd.Status) '$(Code $pd)'"
  $pc=MkTeam "BlankCap $id" '' @('')
  Info "PROBE blank captain with members [''] -> HTTP $($pc.Status) '$(Code $pc)'"
  $pl=MkTeam $teams[0][0].ToLower() "case_$id" @("case_$id")
  Info "PROBE team name differing only by case ('$($teams[0][0].ToLower())') -> HTTP $($pl.Status) '$(Code $pl)'"
  $ps2=MkTeam "Shared $id" $teams[0][1][0] @($teams[0][1][0])
  Info "PROBE same player in two teams -> HTTP $($ps2.Status) '$(Code $ps2)'"
  $pt=RegS $tidP $teams[0][0]
  Info "PROBE same team registered in a second tournament -> HTTP $($pt.Status) '$(Code $pt)'"
  $a1=Call POST "/tournaments/$tidP/registrations" @{type='Squad';teamName="NoSuchTeam $id"}
  $a2=Call POST "/tournaments/$tidP/registrations" @{type='Squad';teamName=$teams[1][0]}
  Info "PROBE AUTH register unknown team, no token -> HTTP $($a1.Status) '$(Code $a1)'"
  Info "PROBE AUTH register known team, no token   -> HTTP $($a2.Status) '$(Code $a2)'"
  if(($a1.Status -eq 404) -and ($a2.Status -eq 401)){
    Info 'PROBE AUTH result: team names can be probed without credentials (404 = no such team, 401 = exists)'
  }
} else { Skip 'P' }

Done
