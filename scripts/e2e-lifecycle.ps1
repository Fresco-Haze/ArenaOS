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

function GetBr { Call GET "/tournaments/$script:tid/bracket" $null $script:tok }
function NodeOf($b,$nid){ @($b.Json.nodes | Where-Object { $_.nodeId -eq $nid })[0] }
function MatchOf($nid){ (NodeOf (GetBr) $nid).match }
function St { (Call GET "/tournaments/$script:tid" $null $script:tok).Json.tournament.state }
function StateIs($label,$want){ $got=St; Check "$label state is $want" ($got -eq $want) "got $got" }
function Refused($label,$x,$status,$code,$wantState){
  Expect $label $x $status $code
  StateIs "  after '$label'" $wantState
}
function Tx($action,$body=$null,$token=$script:tok){ Call POST "/tournaments/$script:tid/$action" $body $token }
function Skip($label){ Info "[$label] setup failed, scenario skipped" }
function Play($label,$node,$want){
  $m=(NodeOf (GetBr) $node.nodeId).match
  if(-not $m){ Check "$label has a match to play" $false; return $null }
  $a=$m.competitorA.player; $c=$m.competitorB.player
  $side = if($want -eq 'A' -or $want -eq 'B'){ $want } elseif($want -eq $a){ 'A' } else { 'B' }
  Expect "$label start" (Call POST "/matches/$($m.matchId)/start" $null $script:tok) 200
  $res=Call POST "/matches/$($m.matchId)/result" @{type='Winner';winner=$side} $script:tok
  Expect "$label : $a vs $c, $side wins" $res 200
  [pscustomobject]@{mid=$m.matchId;a=$a;b=$c}
}
function Roles {
  $b=GetBr; $nn=@($b.Json.nodes)
  $script:rl=@{
    semis=@($nn | Where-Object { $_.round -eq 1 } | Sort-Object nodeId)
    final=@($nn | Where-Object { $_.round -eq 2 })[0]
  }
  $script:rolesOk=[bool](($script:rl.semis.Count -eq 2) -and $script:rl.final)
}
# stage: 'draft' | 'closed' (RegistrationClosed, bracket exists) | 'started' (InProgress)
function NewSE($label,$stage){
  $before=$script:fail
  $resp=Call POST '/tournaments' @{name="LC $label $script:id";organizer='E2E Runner';format='SingleElimination';visibility='Public';maxParticipants=4;thirdPlaceMatch=$false} $script:tok
  Expect "[$label] create tournament ($stage)" $resp 201
  if($resp.Status -ne 201){ return $false }
  $script:tid=$resp.Json.tournamentId
  $tt=$script:tid
  if($stage -ne 'draft'){
    Expect "[$label] publish" (Call POST "/tournaments/$tt/publish" $null $script:tok) 204
    Expect "[$label] open registration" (Call POST "/tournaments/$tt/open-registration" $null $script:tok) 204
    foreach($nm in 'Ayo','Bela','Chidi','Dara'){
      Expect "[$label] register $nm" (Call POST "/tournaments/$tt/registrations" @{type='Individual';player=$nm} $script:tok) 201
    }
    Expect "[$label] close registration" (Call POST "/tournaments/$tt/close-registration" $null $script:tok) 204
    Expect "[$label] generate bracket" (Call POST "/tournaments/$tt/bracket" $null $script:tok) 201
  }
  if($stage -eq 'started'){
    Expect "[$label] start tournament" (Call POST "/tournaments/$tt/start" $null $script:tok) 204
  }
  return ($script:fail -eq $before)
}

# ---------- Setup
Stage 'Setup'
$health=Call GET '/health'; Expect 'backend reachable' $health 200
if($health.Status -ne 200){ exit 1 }
$id=Get-Random -Maximum 999999; $pw='Passw0rd!lc'
$script:id=$id
$u1="lc_$id"; $u2="lc_${id}b"
Expect 'register owner' (Call POST '/register' @{username=$u1;email="$u1@example.com";password=$pw}) 201
Expect 'register other user' (Call POST '/register' @{username=$u2;email="$u2@example.com";password=$pw}) 201
$script:tok=(Call POST '/login' @{username=$u1;password=$pw}).Json.token
$tok2=(Call POST '/login' @{username=$u2;password=$pw}).Json.token
Check 'both sessions obtained' (($script:tok -match '^[0-9a-f]{64}$') -and ($tok2 -match '^[0-9a-f]{64}$'))
if(-not (($script:tok -match '^[0-9a-f]{64}$') -and ($tok2 -match '^[0-9a-f]{64}$'))){ Done }

# ---------- A0: wrong-state transitions and precedence (RegistrationClosed)
Stage 'A0 Pause/resume/reopen from the wrong state, and ownership precedence'
if(NewSE 'A0' 'closed'){
  StateIs '[A0] baseline' 'RegistrationClosed'
  Refused '[A0] pause from RegistrationClosed' (Tx 'pause') 409 'INVALID_TRANSITION' 'RegistrationClosed'
  Refused '[A0] resume from RegistrationClosed' (Tx 'resume') 409 'INVALID_TRANSITION' 'RegistrationClosed'
  Refused '[A0] reopen from RegistrationClosed, blank reason: state error first' (Tx 'reopen' @{reason=''}) 409 'INVALID_TRANSITION' 'RegistrationClosed'
  Refused '[A0] non-owner pause on wrong state: ownership first' (Tx 'pause' $null $tok2) 403 'NOT_TOURNAMENT_OWNER' 'RegistrationClosed'
  Refused '[A0] non-owner reopen, wrong state, blank reason: ownership first' (Tx 'reopen' @{reason=''} $tok2) 403 'NOT_TOURNAMENT_OWNER' 'RegistrationClosed'
} else { Skip 'A0' }

# ---------- A: pause and resume
Stage 'A Pause and resume (InProgress)'
if(NewSE 'A' 'started'){
  Roles
  if(-not $script:rolesOk){ Check '[A] roles found (2 semis, final)' $false } else {
    $x=$script:rl
    $p1=Play '[A] semi 1' $x.semis[0] 'A'
    $m2=MatchOf $x.semis[1].nodeId
    StateIs '[A] before pause' 'InProgress'
    Expect '[A] pause' (Tx 'pause') 204
    StateIs '[A] after pause' 'Paused'
    Refused '[A] double pause refused' (Tx 'pause') 409 'INVALID_TRANSITION' 'Paused'
    Refused '[A] start match while paused' (Call POST "/matches/$($m2.matchId)/start" $null $script:tok) 409 'FORBIDDEN_STATE' 'Paused'
    Refused '[A] record result on a Scheduled match while paused (lifecycle check precedes match status)' (Call POST "/matches/$($m2.matchId)/result" @{type='Winner';winner='A'} $script:tok) 409 'FORBIDDEN_STATE' 'Paused'
    Refused '[A] correct completed semi 1 while paused' (Call PUT "/matches/$($p1.mid)/result" @{type='Winner';winner='B'} $script:tok) 409 'FORBIDDEN_STATE' 'Paused'
    Refused '[A] complete while paused' (Tx 'complete') 409 'TOURNAMENT_PAUSED' 'Paused'
    Expect '[A] scheduling is still allowed while paused' (Call PUT "/matches/$($m2.matchId)/schedule" @{start='2030-01-01T10:00:00Z'} $script:tok) 200
    $m2n=MatchOf $x.semis[1].nodeId
    Check '[A] schedule persisted' ($null -ne $m2n.scheduledStart) "got $($m2n.scheduledStart)"
    Check '[A] semi 2 untouched by refusals (Scheduled, no outcome)' (($m2n.status -eq 'Scheduled') -and ($null -eq $m2n.outcome))
    Check '[A] semi 1 outcome unchanged (winner A)' ((MatchOf $x.semis[0].nodeId).outcome.winner -eq 'A')
    Expect '[A] resume' (Tx 'resume') 204
    StateIs '[A] after resume' 'InProgress'
    Refused '[A] double resume refused' (Tx 'resume') 409 'INVALID_TRANSITION' 'InProgress'
    Expect '[A] start semi 2 after resume' (Call POST "/matches/$($m2.matchId)/start" $null $script:tok) 200
    Expect '[A] pause again (semi 2 in progress)' (Tx 'pause') 204
    Refused '[A] record result on an InProgress match while paused' (Call POST "/matches/$($m2.matchId)/result" @{type='Winner';winner='A'} $script:tok) 409 'FORBIDDEN_STATE' 'Paused'
    $m2p=MatchOf $x.semis[1].nodeId
    Check '[A] semi 2 still InProgress, no outcome' (($m2p.status -eq 'InProgress') -and ($null -eq $m2p.outcome)) "$($m2p.status)"
    Expect '[A] resume again' (Tx 'resume') 204
    Expect '[A] record semi 2 after resume' (Call POST "/matches/$($m2.matchId)/result" @{type='Winner';winner='A'} $script:tok) 200
    $pf=Play '[A] final' $x.final 'A'
    Expect '[A] complete' (Tx 'complete') 200
    StateIs '[A] end' 'Completed'
    Refused '[A] pause on a Completed tournament' (Tx 'pause') 409 'INVALID_TRANSITION' 'Completed'
  }
} else { Skip 'A' }

# ---------- B: reopen
Stage 'B Reopen a Completed tournament'
if(NewSE 'B' 'started'){
  Roles
  if(-not $script:rolesOk){ Check '[B] roles found' $false } else {
    $x=$script:rl
    $s1=Play '[B] semi 1' $x.semis[0] 'A'
    $s2=Play '[B] semi 2' $x.semis[1] 'A'
    $fn=Play '[B] final' $x.final 'A'
    Expect '[B] complete' (Tx 'complete') 200
    StateIs '[B] after complete' 'Completed'
    Refused '[B] non-owner reopen, blank reason: ownership first' (Tx 'reopen' @{reason=''} $tok2) 403 'NOT_TOURNAMENT_OWNER' 'Completed'
    $bl=Tx 'reopen' @{reason=''}
    Expect '[B] reopen with blank reason' $bl 400 'VALIDATION_FAILED'
    Check '[B] error names the reason field' ($bl.Json.error.details.field -eq 'reason') "$($bl.Raw)"
    StateIs '  after blank reason' 'Completed'
    Refused '[B] reopen with whitespace-only reason' (Tx 'reopen' @{reason='   '}) 400 'VALIDATION_FAILED' 'Completed'
    Refused '[B] cancel a Completed tournament, blank reason: state error first' (Tx 'cancel' @{reason=''}) 409 'FORBIDDEN_STATE' 'Completed'
    Refused '[B] cancel a Completed tournament, real reason' (Tx 'cancel' @{reason='too late'}) 409 'FORBIDDEN_STATE' 'Completed'
    Refused '[B] complete again' (Tx 'complete') 409 'TOURNAMENT_ALREADY_COMPLETED' 'Completed'
    Expect '[B] reopen with a reason' (Tx 'reopen' @{reason='scoreboard error in the final'}) 204
    StateIs '[B] after reopen' 'InProgress'
    Refused '[B] reopen from InProgress, blank reason: state error first' (Tx 'reopen' @{reason=''}) 409 'INVALID_TRANSITION' 'InProgress'
    Refused '[B] correct semi 1 while the final is played' (Call PUT "/matches/$($s1.mid)/result" @{type='Winner';winner='B'} $script:tok) 409 'DOWNSTREAM_MATCH_STARTED' 'InProgress'
    Check '[B] semi 1 outcome unchanged (winner A)' ((MatchOf $x.semis[0].nodeId).outcome.winner -eq 'A')
    Expect '[B] correct the final (B wins instead)' (Call PUT "/matches/$($fn.mid)/result" @{type='Winner';winner='B'} $script:tok) 200
    Check '[B] corrected final persisted (winner B)' ((MatchOf $x.final.nodeId).outcome.winner -eq 'B')
    Expect '[B] complete again' (Tx 'complete') 200
    StateIs '[B] after second completion' 'Completed'
    Check '[B] corrected final still persisted after completion' ((MatchOf $x.final.nodeId).outcome.winner -eq 'B')
    Refused '[B] correction after completion' (Call PUT "/matches/$($fn.mid)/result" @{type='Winner';winner='A'} $script:tok) 409 'TOURNAMENT_ALREADY_COMPLETED' 'Completed'
  }
} else { Skip 'B' }

# ---------- C: cancel while InProgress
Stage 'C Cancel while InProgress'
if(NewSE 'C' 'started'){
  Roles
  if(-not $script:rolesOk){ Check '[C] roles found' $false } else {
    $x=$script:rl
    $c1=Play '[C] semi 1' $x.semis[0] 'A'
    $c2=MatchOf $x.semis[1].nodeId
    Expect '[C] start semi 2' (Call POST "/matches/$($c2.matchId)/start" $null $script:tok) 200
    Refused '[C] non-owner cancel with blank reason: ownership first' (Tx 'cancel' @{reason=''} $tok2) 403 'NOT_TOURNAMENT_OWNER' 'InProgress'
    Refused '[C] cancel with blank reason' (Tx 'cancel' @{reason=''}) 400 'VALIDATION_FAILED' 'InProgress'
    Refused '[C] cancel with whitespace-only reason' (Tx 'cancel' @{reason='   '}) 400 'VALIDATION_FAILED' 'InProgress'
    Refused '[C] cancel with no reason field' (Tx 'cancel' @{}) 400 'INVALID_BODY' 'InProgress'
    Expect '[C] cancel with a reason' (Tx 'cancel' @{reason='venue unavailable'}) 204
    StateIs '[C] after cancel' 'Cancelled'
    Refused '[C] start match' (Call POST "/matches/$($c2.matchId)/start" $null $script:tok) 409 'FORBIDDEN_STATE' 'Cancelled'
    Refused '[C] record result' (Call POST "/matches/$($c2.matchId)/result" @{type='Winner';winner='A'} $script:tok) 409 'FORBIDDEN_STATE' 'Cancelled'
    Refused '[C] correct semi 1' (Call PUT "/matches/$($c1.mid)/result" @{type='Winner';winner='B'} $script:tok) 409 'FORBIDDEN_STATE' 'Cancelled'
    Refused '[C] schedule a match' (Call PUT "/matches/$($c2.matchId)/schedule" @{start='2030-01-01T10:00:00Z'} $script:tok) 409 'FORBIDDEN_STATE' 'Cancelled'
    Refused '[C] pause' (Tx 'pause') 409 'INVALID_TRANSITION' 'Cancelled'
    Refused '[C] resume' (Tx 'resume') 409 'INVALID_TRANSITION' 'Cancelled'
    Refused '[C] reopen with a real reason' (Tx 'reopen' @{reason='changed our minds'}) 409 'INVALID_TRANSITION' 'Cancelled'
    Refused '[C] complete' (Tx 'complete') 409 'TOURNAMENT_ALREADY_CANCELLED' 'Cancelled'
    Refused '[C] cancel again' (Tx 'cancel' @{reason='again'}) 409 'FORBIDDEN_STATE' 'Cancelled'
    $vc=Call GET "/tournaments/$script:tid" $null $script:tok
    Expect '[C] cancelled tournament is still readable' $vc 200
    Check '[C] state Cancelled, owner flag kept' (($vc.Json.tournament.state -eq 'Cancelled') -and ($vc.Json.viewerIsOwner -eq $true))
    $bc=GetBr
    Expect '[C] cancelled bracket is still readable' $bc 200
    Check '[C] bracket intact (3 nodes)' (@($bc.Json.nodes).Count -eq 3) "$(@($bc.Json.nodes).Count)"
    Check '[C] semi 1 outcome unchanged (winner A)' ((MatchOf $x.semis[0].nodeId).outcome.winner -eq 'A')
    # probes, informational only
    $pm=MatchOf $x.semis[1].nodeId
    Info "PROBE match that was InProgress at cancellation: status '$($pm.status)', outcome '$($pm.outcome.type)'"
    $pub=Call GET '/tournaments'
    $inPub=@($pub.Json.tournaments | Where-Object { $_.tournamentId -eq $script:tid }).Count
    Info "PROBE cancelled public tournament in the public list: $(if($inPub -gt 0){'yes'}else{'no'}) (list HTTP $($pub.Status))"
    $mine=Call GET '/me/tournaments' $null $script:tok
    $inMine=@($mine.Json.tournaments | Where-Object { $_.tournamentId -eq $script:tid }).Count
    Info "PROBE cancelled tournament in the owner's own list: $(if($inMine -gt 0){'yes'}else{'no'})"
    $anon=Call GET "/tournaments/$script:tid"
    Info "PROBE anonymous read of the cancelled public tournament: HTTP $($anon.Status)"
  }
} else { Skip 'C' }

# ---------- D: cancel from earlier states, ownership, no credentials
Stage 'D1 Cancel from Draft'
if(NewSE 'D1' 'draft'){
  StateIs '[D1] baseline' 'Draft'
  Expect '[D1] cancel from Draft' (Tx 'cancel' @{reason='created by mistake'}) 204
  StateIs '[D1] after cancel' 'Cancelled'
} else { Skip 'D1' }

Stage 'D2 Cancel from RegistrationClosed'
if(NewSE 'D2' 'closed'){
  StateIs '[D2] baseline' 'RegistrationClosed'
  Expect '[D2] cancel from RegistrationClosed' (Tx 'cancel' @{reason='not enough interest'}) 204
  StateIs '[D2] after cancel' 'Cancelled'
} else { Skip 'D2' }

Stage 'D3 Non-owner and unauthenticated callers'
if(NewSE 'D3' 'started'){
  Refused '[D3] non-owner pause' (Tx 'pause' $null $tok2) 403 'NOT_TOURNAMENT_OWNER' 'InProgress'
  Refused '[D3] non-owner resume' (Tx 'resume' $null $tok2) 403 'NOT_TOURNAMENT_OWNER' 'InProgress'
  Refused '[D3] non-owner cancel (real reason)' (Tx 'cancel' @{reason='nope'} $tok2) 403 'NOT_TOURNAMENT_OWNER' 'InProgress'
  Refused '[D3] non-owner reopen' (Tx 'reopen' @{reason='nope'} $tok2) 403 'NOT_TOURNAMENT_OWNER' 'InProgress'
  Refused '[D3] non-owner complete' (Tx 'complete' $null $tok2) 403 'NOT_TOURNAMENT_OWNER' 'InProgress'
  Refused '[D3] pause without credentials' (Tx 'pause' $null $null) 401 'UNAUTHENTICATED' 'InProgress'
  Refused '[D3] cancel without credentials' (Tx 'cancel' @{reason='x'} $null) 401 'UNAUTHENTICATED' 'InProgress'
} else { Skip 'D3' }

Done
