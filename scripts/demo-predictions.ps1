param([string]$Base='http://localhost:3000', [string]$Web='http://localhost:5173')
$ErrorActionPreference='Stop'
function Call($Method,$Path,$Body=$null,$Token=$null){
  $h=@{}; if($Token){ $h.Authorization="Bearer $Token" }
  $p=@{Uri="$Base$Path";Method=$Method;Headers=$h;UseBasicParsing=$true}
  if($null -ne $Body){ $p.Body=($Body|ConvertTo-Json -Depth 10 -Compress); $p.ContentType='application/json' }
  try { $r=Invoke-WebRequest @p; $text=$r.Content }
  catch { throw "$Method $Path failed: $($_.ErrorDetails.Message)" }
  if($text){ try{ $text|ConvertFrom-Json }catch{ $null } }
}
function NewUser($tag){
  $u="demo_${tag}_$id"
  Call POST '/register' @{username=$u;email="$u@example.com";password=$pw} | Out-Null
  [pscustomobject]@{Name=$u;Token=(Call POST '/login' @{username=$u;password=$pw}).token}
}
Call GET '/health' | Out-Null
$id=Get-Random -Maximum 999999; $pw='Passw0rd!demo'
$owner=NewUser 'owner'; $p1=NewUser 'p1'; $p2=NewUser 'p2'; $fan=NewUser 'fan'
$t=Call POST '/tournaments' @{name="Demo predictions $id";organizer='Demo';format='SingleElimination';visibility='Public';maxParticipants=4;participantMode='IndividualOnly'} $owner.Token
$tid=$t.tournamentId
Call POST "/tournaments/$tid/publish" $null $owner.Token | Out-Null
Call POST "/tournaments/$tid/open-registration" $null $owner.Token | Out-Null
Call POST "/tournaments/$tid/join" $null $p1.Token | Out-Null
Call POST "/tournaments/$tid/join" $null $p2.Token | Out-Null
Call POST "/tournaments/$tid/close-registration" $null $owner.Token | Out-Null
Call POST "/tournaments/$tid/bracket" $null $owner.Token | Out-Null
Write-Host ""
Write-Host "Tournament page: $Web/tournaments/$tid" -ForegroundColor Cyan
Write-Host "Password for all four: $pw"
Write-Host "  fan    $($fan.Name)    should see the Predict buttons"
Write-Host "  owner  $($owner.Name)  should NOT see them"
Write-Host "  p1     $($p1.Name)     should NOT see them (registered player)"
Write-Host "  p2     $($p2.Name)     should NOT see them (registered player)"
Write-Host "  signed out: should see 'Sign in to predict the winners'"
