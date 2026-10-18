param([string]$Base='http://localhost:3000',[switch]$Verify)
$ErrorActionPreference='Stop'
$script:pass=0; $script:fail=0
$stateFile=Join-Path $env:TEMP 'arenaos-e2e.json'

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
function SlotPlayer($slot){ if($slot.type -eq 'Filled'){ $slot.participant.player } else { $null } }

# ---------- 1 Health
Stage '1 API health'
$r=Call GET '/health'
Expect "GET /health on $Base" $r 200
Check 'body status = ok' ($r.Json.status -eq 'ok')
if($r.Status -ne 200){ Write-Host 'Backend unreachable. Stopping.' -ForegroundColor Red; exit 1 }

# ---------- Verify mode (run after restarting the backend)
if($Verify){
  Stage 'Verify after backend restart'
  $s=Get-Content $stateFile -Raw | ConvertFrom-Json
  $r=Call POST '/login' @{username=$s.user;password=$s.pw}
  Expect 'old account can still log in' $r 200
  $t=$r.Json.token
  $v=Call GET "/tournaments/$($s.tid)" $null $t
  Expect 'tournament still exists' $v 200
  Check 'state is InProgress' ($v.Json.tournament.state -eq 'InProgress') $v.Json.tournament.state
  Check '4 participants kept' (@($v.Json.participants).Count -eq 4)
  $b=Call GET "/tournaments/$($s.tid)/bracket" $null $t
  Expect 'bracket still exists' $b 200
  $n=@($b.Json.nodes | Where-Object { $_.nodeId -eq $s.node })[0]
  Check 'corrected result survived restart' ($n.match.status -eq 'Completed' -and $n.match.outcome.winner -eq 'B')
  Done
}

# ---------- 2 Authentication
Stage '2 Authentication'
$id=Get-Random -Maximum 999999
$user="e2e_$id"; $user2="e2e_${id}b"; $pw='Passw0rd!e2e'
$r=Call POST '/register' @{username=$user;email="$user@example.com";password=$pw}
Expect 'register owner' $r 201
Check 'register returns the username' ($r.Json.username -eq $user)
$r=Call POST '/register' @{username=$user;email="x$user@example.com";password=$pw}
Expect 'duplicate username rejected' $r 409 'USERNAME_TAKEN'
$r=Call POST '/register' @{username=$user2;email="$user2@example.com";password=$pw}
Expect 'register second user' $r 201
$r=Call POST '/login' @{username=$user;password='wrong-password'}
Expect 'wrong password rejected' $r 401 'INVALID_CREDENTIALS'
$r=Call POST '/login' @{username=$user;password=$pw}
Expect 'login owner' $r 200
$tok=$r.Json.token
Check 'token is 64 hex chars' ($tok -match '^[0-9a-f]{64}$')
$tok2=(Call POST '/login' @{username=$user2;password=$pw}).Json.token
Expect 'token works' (Call GET '/me/tournaments' $null $tok) 200
Expect 'no token rejected' (Call GET '/me/tournaments') 401 'UNAUTHENTICATED'
Expect 'bogus token rejected' (Call GET '/me/tournaments' $null 'deadbeef') 401 'UNAUTHENTICATED'

# ---------- 3 Tournament creation
Stage '3 Tournament creation'
$body=@{name="E2E $id";organizer='E2E Runner';format='SingleElimination';visibility='Public';maxParticipants=4;thirdPlaceMatch=$false;participantMode='IndividualOnly'}
Expect 'create without token rejected' (Call POST '/tournaments' $body) 401 'UNAUTHENTICATED'
Expect 'malformed body rejected' (Call POST '/tournaments' @{name='x'} $tok) 400 'INVALID_BODY'
Expect 'blank name rejected' (Call POST '/tournaments' @{name=' ';organizer='o';format='SingleElimination';visibility='Public';maxParticipants=4} $tok) 400 'VALIDATION_FAILED'
$r=Call POST '/tournaments' $body $tok
Expect 'create tournament' $r 201
$tid=$r.Json.tournamentId
Check 'got a real tournament id' ($tid -gt 0) "$tid"
$v=Call GET "/tournaments/$tid" $null $tok
Expect 'read it back' $v 200
Check 'name round-trips' ($v.Json.tournament.name -eq "E2E $id")
Check 'state is Draft' ($v.Json.tournament.state -eq 'Draft') $v.Json.tournament.state
Check 'viewerIsOwner is true' ($v.Json.viewerIsOwner -eq $true)
Expect 'non-owner cannot publish' (Call POST "/tournaments/$tid/publish" $null $tok2) 403 'NOT_TOURNAMENT_OWNER'

# ---------- 4 Participants and bracket
Stage '4 Participants and bracket'
Expect 'publish' (Call POST "/tournaments/$tid/publish" $null $tok) 204
Expect 'open registration' (Call POST "/tournaments/$tid/open-registration" $null $tok) 204
$a=Call GET "/tournaments/$tid"
Expect 'anonymous can read public tournament' $a 200
Check 'state is RegistrationOpen' ($a.Json.tournament.state -eq 'RegistrationOpen') $a.Json.tournament.state
function Reg($n){ Call POST "/tournaments/$tid/registrations" @{type='Individual';player=$n} $tok }
foreach($n in 'Ayo','Bela'){ $r=Reg $n; Expect "register $n" $r 201; Check "$n has registrationId" ($r.Json.registrationId -gt 0) }
Expect 'duplicate player rejected' (Reg 'Ayo') 409 'ALREADY_REGISTERED'
foreach($n in 'Chidi','Dara'){ Expect "register $n" (Reg $n) 201 }
Expect 'fifth player rejected (full)' (Reg 'Extra') 409 'REGISTRATION_CAPACITY_REACHED'
$v=Call GET "/tournaments/$tid" $null $tok
$names=@($v.Json.participants | ForEach-Object { $_.player }) | Sort-Object
Check 'exactly the 4 expected participants' (($names -join ',') -eq 'Ayo,Bela,Chidi,Dara') ($names -join ',')
Expect 'bracket before closing registration refused' (Call POST "/tournaments/$tid/bracket" $null $tok) 409 'INVALID_TRANSITION'
Expect 'close registration' (Call POST "/tournaments/$tid/close-registration" $null $tok) 204
$r=Call POST "/tournaments/$tid/bracket" $null $tok
Expect 'generate bracket' $r 201
Check 'bracketId returned' ($r.Json.bracketId -gt 0)
Expect 'second generate refused' (Call POST "/tournaments/$tid/bracket" $null $tok) 409 'BRACKET_ALREADY_EXISTS'
$b=Call GET "/tournaments/$tid/bracket" $null $tok
Expect 'read bracket' $b 200
$nodes=@($b.Json.nodes)
$r1=($nodes | Measure-Object round -Minimum).Minimum
$first=@($nodes | Where-Object { $_.round -eq $r1 })
Check '3 nodes (2 semis + final)' ($nodes.Count -eq 3) "$($nodes.Count)"
Check '2 nodes in first round' ($first.Count -eq 2) "$($first.Count)"
Check 'links available' ($b.Json.linksAvailable -eq $true)
$seeded=@($first | ForEach-Object { SlotPlayer $_.slotA; SlotPlayer $_.slotB } | Sort-Object)
Check 'all 4 players seeded into round 1' (($seeded -join ',') -eq 'Ayo,Bela,Chidi,Dara') ($seeded -join ',')
Expect 'start tournament' (Call POST "/tournaments/$tid/start" $null $tok) 204
$v=Call GET "/tournaments/$tid" $null $tok
Check 'state is InProgress' ($v.Json.tournament.state -eq 'InProgress') $v.Json.tournament.state

# ---------- 5 Match progression
Stage '5 Match progression'
$b=Call GET "/tournaments/$tid/bracket" $null $tok
$nodes=@($b.Json.nodes)
$first=@($nodes | Where-Object { $_.round -eq $r1 -and $_.match } | Sort-Object nodeId)
Check 'both first-round nodes have matches' ($first.Count -eq 2) "$($first.Count)"
$n=$first[0]; $m=$n.match; $mid=$m.matchId
Check 'match is Scheduled' ($m.status -eq 'Scheduled') $m.status
Expect 'result before start refused' (Call POST "/matches/$mid/result" @{type='Winner';winner='A'} $tok) 409 'MATCH_NOT_IN_PROGRESS'
$r=Call POST "/matches/$mid/start" $null $tok
Expect 'start match' $r 200
Check 'status InProgress' ($r.Json.status -eq 'InProgress') $r.Json.status
Expect 'bogus outcome type rejected' (Call POST "/matches/$mid/result" @{type='Bogus'} $tok) 400 'INVALID_BODY'
$r=Call POST "/matches/$mid/result" @{type='Winner';winner='A'} $tok
Expect 'record result: A wins' $r 200
Check 'match Completed, winner A' ($r.Json.status -eq 'Completed' -and $r.Json.outcome.winner -eq 'A')
Expect 'recording twice refused' (Call POST "/matches/$mid/result" @{type='Winner';winner='A'} $tok) 409 'MATCH_NOT_IN_PROGRESS'

function Advanced($expectName){
  $bb=Call GET "/tournaments/$tid/bracket" $null $tok
  $nn=@($bb.Json.nodes | Where-Object { $_.nodeId -eq $n.nodeId })[0]
  $dest=@($bb.Json.nodes | Where-Object { $_.nodeId -eq $nn.winnerTo.node })[0]
  $slot = if($nn.winnerTo.slot -eq 'A'){ $dest.slotA } else { $dest.slotB }
  Check "winner $expectName advanced into the next round" ((SlotPlayer $slot) -eq $expectName) "slot holds: $(SlotPlayer $slot)"
}
$nameA=$m.competitorA.player; $nameB=$m.competitorB.player
Check 'node has winnerTo link' ($null -ne $n.winnerTo)
Advanced $nameA
$r=Call PUT "/matches/$mid/result" @{type='Winner';winner='B'} $tok
Expect 'correct result: B wins' $r 200
Advanced $nameB

# ---------- 6 Persistence and errors
Stage '6 Persistence and session end'
$t3=(Call POST '/login' @{username=$user;password=$pw}).Json.token
$b=Call GET "/tournaments/$tid/bracket" $null $t3
$nn=@($b.Json.nodes | Where-Object { $_.nodeId -eq $n.nodeId })[0]
Check 'fresh session sees corrected result' ($nn.match.status -eq 'Completed' -and $nn.match.outcome.winner -eq 'B')
$mine=Call GET '/me/tournaments' $null $t3
Check 'tournament listed under /me/tournaments' (@($mine.Json.tournaments | Where-Object { $_.tournamentId -eq $tid }).Count -eq 1)
Expect 'logout' (Call POST '/logout' $null $t3) 204
Expect 'token dead after logout' (Call GET '/me/tournaments' $null $t3) 401 'UNAUTHENTICATED'
@{tid=$tid;user=$user;pw=$pw;node=$n.nodeId} | ConvertTo-Json | Set-Content $stateFile
Write-Host "`nState saved. Restart the backend, then run:  .\scripts\e2e.ps1 -Verify" -ForegroundColor Yellow
Done
