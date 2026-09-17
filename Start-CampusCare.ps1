[CmdletBinding()]
param([switch]$Stop,[switch]$NoBrowser)
$ErrorActionPreference="Stop"
$projectRoot=$PSScriptRoot
function Assert-Command([string]$Name,[string]$HelpText){if(-not(Get-Command $Name -ErrorAction SilentlyContinue)){throw "$Name was not found. $HelpText"}}
Set-Location -LiteralPath $projectRoot
Assert-Command docker "Install Docker Desktop, start it, then run this script again."
try { docker info *> $null } catch { throw "Docker Desktop is not running. Start Docker Desktop and try again." }
if($Stop){docker compose down;Write-Host "CampusCare has stopped." -ForegroundColor Yellow;exit 0}
$composeArgs=@("compose","up","-d","--build")
Write-Host "Starting CampusCare..." -ForegroundColor Cyan
& docker @composeArgs
if($LASTEXITCODE -ne 0){throw "CampusCare could not start. Run 'docker compose logs' for details."}
Write-Host "`nCampusCare is ready:" -ForegroundColor Green
Write-Host "  Website: http://localhost:8080"
Write-Host "  API:     http://localhost:5000/api/health"
Write-Host "`nTo stop it later: .\Start-CampusCare.ps1 -Stop"
if(-not $NoBrowser){Start-Process "http://localhost:8080"}
