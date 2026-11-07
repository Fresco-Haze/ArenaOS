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
$id=Get-Random -Maximum 999999; $pw='Passw0rd!pr'
function NewUser($tag){
  $u="pr_${tag}_$id"
  Expect "register $tag" (Call POST '/register' @{username=$u;email="$u@example.com";password=$pw}) 201
  $t=(Call POST '/login' @{username=$u;password=$pw}).Json.token
  [pscustomobject]@{Name=$u;Token=$t}
}
$owner=NewUser 'own'; $p1=NewUser 'p1'; $p2=NewUser 'p2'; $fan1=NewUser 'f1'; $fan2=NewUser 'f2'
$r=Call POST '/tournaments' @{name="Predict $id";organizer='E2E Runner';format='SingleElimination';visibility='Public';maxParticipants=4;participantMode='IndividualOnly'} $owner.Token
Expect 'create tournament' $r 201
$tid=$r.Json.tournamentId
Expect 'publish' (Call POST "/tournaments/$tid/publish" $null $owner.Token) 204
Expect 'open registration' (Call POST "/tournaments/$tid/open-registration" $null $owner.Token) 204
foreach($p in @($p1,$p2)){
  $r=Call POST "/tournaments/$tid/join" $null $p.Token
  Expect "join $($p.Name)" $r 201
  Check '  joined, not pending' ($r.Json.status -eq 'Joined') "$($r.Json.status)"
}
Expect 'close registration' (Call POST "/tournaments/$tid/close-registration" $null $owner.Token) 204
Expect 'generate bracket' (Call POST "/tournaments/$tid/bracket" $null $owner.Token) 201
$b=Call GET "/tournaments/$tid/bracket" $null $owner.Token
Expect 'read bracket' $b 200
$node=@($b.Json.nodes | Where-Object { $_.match } | Sort-Object nodeId) | Select-Object -First 1
Check 'bracket has a match' ($null -ne $node)
if($null -eq $node){ Done }
$mid=$node.match.matchId
Write-Host ("  INFO  match {0}: {1} vs {2}" -f $mid,$node.match.competitorA.player,$node.match.competitorB.player) -ForegroundColor Yellow

Stage '2 Who may predict, and what is refused'
Expect 'signed out refused' (Call PUT "/matches/$mid/prediction" @{pick='A'}) 401 'UNAUTHENTICATED'
Expect 'bad match id is 404' (Call PUT '/matches/abc/prediction' @{pick='A'} $fan1.Token) 404 'NOT_FOUND'
Expect 'bad pick value is 400' (Call PUT "/matches/$mid/prediction" @{pick='X'} $fan1.Token) 400 'INVALID_BODY'
Expect 'organizer refused' (Call PUT "/matches/$mid/prediction" @{pick='A'} $owner.Token) 403 'PREDICTION_NOT_ALLOWED'
Expect 'joined player 1 refused' (Call PUT "/matches/$mid/prediction" @{pick='A'} $p1.Token) 403 'PREDICTION_NOT_ALLOWED'
Expect 'joined player 2 refused' (Call PUT "/matches/$mid/prediction" @{pick='B'} $p2.Token) 403 'PREDICTION_NOT_ALLOWED'
Expect 'draw refused outside round robin' (Call PUT "/matches/$mid/prediction" @{pick='Draw'} $fan1.Token) 400 'PICK_NOT_ALLOWED'

Stage '3 Saving and changing picks'
$r=Call PUT "/matches/$mid/prediction" @{pick='B'} $fan1.Token
Expect 'fan1 picks B' $r 200
Check '  response says saved with pick B' (($r.Json.saved -eq $true) -and ($r.Json.pick -eq 'B')) $r.Raw
$r=Call GET "/tournaments/$tid/predictions" $null $fan1.Token
Expect 'fan1 reads own picks' $r 200
$mine=@($r.Json)
Check '  one pick, B, pending' (($mine.Count -eq 1) -and ($mine[0].pick -eq 'B') -and ($mine[0].result -eq 'pending') -and ($mine[0].matchId -eq $mid)) $r.Raw
Expect 'fan1 changes pick to A' (Call PUT "/matches/$mid/prediction" @{pick='A'} $fan1.Token) 200
$r=Call GET "/tournaments/$tid/predictions" $null $fan1.Token
$mine=@($r.Json)
Check '  still one pick, now A' (($mine.Count -eq 1) -and ($mine[0].pick -eq 'A')) $r.Raw
Expect 'fan2 picks B' (Call PUT "/matches/$mid/prediction" @{pick='B'} $fan2.Token) 200
Expect 'my picks needs a login' (Call GET "/tournaments/$tid/predictions") 401 'UNAUTHENTICATED'
Expect 'my picks with bad id is 404' (Call GET '/tournaments/abc/predictions' $null $fan1.Token) 404 'NOT_FOUND'
$r=Call GET "/tournaments/$tid/predictions/leaderboard"
Expect 'leaderboard readable without a token' $r 200
Check '  empty while picks are pending' (@($r.Json).Count -eq 0) $r.Raw
Expect 'leaderboard with bad id is 404' (Call GET '/tournaments/abc/predictions/leaderboard') 404 'NOT_FOUND'

Stage '4 Match starts, result recorded'
Expect 'start match' (Call POST "/matches/$mid/start" $null $owner.Token) 200
Expect 'pick refused once started' (Call PUT "/matches/$mid/prediction" @{pick='A'} $fan1.Token) 409 'PREDICTIONS_CLOSED'
Expect 'record result: A wins' (Call POST "/matches/$mid/result" @{type='Winner';winner='A'} $owner.Token) 200
Expect 'pick refused after the result' (Call PUT "/matches/$mid/prediction" @{pick='B'} $fan2.Token) 409 'PREDICTIONS_CLOSED'
$r=Call GET "/tournaments/$tid/predictions" $null $fan1.Token
Check 'fan1 pick A is correct' ((@($r.Json).Count -eq 1) -and (@($r.Json)[0].result -eq 'correct')) $r.Raw
$r=Call GET "/tournaments/$tid/predictions" $null $fan2.Token
Check 'fan2 pick B is wrong' ((@($r.Json).Count -eq 1) -and (@($r.Json)[0].result -eq 'wrong')) $r.Raw

Stage '5 Leaderboard'
$lb=Call GET "/tournaments/$tid/predictions/leaderboard"
Expect 'leaderboard readable without a token' $lb 200
$rows=@($lb.Json)
Check 'two rows' ($rows.Count -eq 2) "$($rows.Count) $($lb.Raw)"
if($rows.Count -ge 2){
  Check 'rank 1 is fan1: 1 correct, 0 wrong, 1 point' (($rows[0].rank -eq 1) -and ($rows[0].username -eq $fan1.Name) -and ($rows[0].correct -eq 1) -and ($rows[0].wrong -eq 0) -and ($rows[0].points -eq 1)) $lb.Raw
  Check 'rank 2 is fan2: 0 correct, 1 wrong, 0 points' (($rows[1].rank -eq 2) -and ($rows[1].username -eq $fan2.Name) -and ($rows[1].correct -eq 0) -and ($rows[1].wrong -eq 1) -and ($rows[1].points -eq 0)) $lb.Raw
}
Done