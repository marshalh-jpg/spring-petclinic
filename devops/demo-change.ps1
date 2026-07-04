<#
===============================================================================
 demo-change.ps1 - Push a visible code change to demonstrate the pipeline
===============================================================================
 Updates the PetClinic welcome message with a timestamp, commits and pushes.
 Jenkins' SCM polling (every ~2 minutes) detects the commit, rebuilds, rescans
 (SonarQube + ZAP) and redeploys to the production VM automatically.

 Evidence flow for the rubric:
   1. Screenshot http://localhost:8888 BEFORE running this (old welcome text)
   2. Run this script; screenshot the commit on GitHub
   3. Screenshot the new Jenkins build (cause: "Started by an SCM change")
   4. When green, refresh http://localhost:8888 -> new timestamped welcome text

 The change targets src/main/resources/messages/messages.properties on purpose:
 it is user-visible on the home page and does not touch Java sources (the
 project enforces spring-javaformat on .java files, so resource edits are the
 safe demo path).
===============================================================================
#>

[CmdletBinding()]
param(
    [string]$AppDir = ""
)

$ErrorActionPreference = "Stop"

if (-not $AppDir) {
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $AppDir = Join-Path $base "devsecops\app"
}

$msgFile = Join-Path $AppDir "src\main\resources\messages\messages.properties"
if (-not (Test-Path $msgFile)) {
    throw "Cannot find $msgFile - run setup.ps1 first (it clones your fork into devsecops\app)."
}

$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$content = [System.IO.File]::ReadAllText($msgFile)
$new = $content -replace '(?m)^welcome=.*$', "welcome=Welcome! (pipeline update $stamp)"
if ($new -eq $content) {
    throw "Could not find a 'welcome=' key in messages.properties - has the upstream file changed?"
}
$new = $new -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($msgFile, $new, [System.Text.UTF8Encoding]::new($false))
Write-Host "[OK] welcome message updated to: Welcome! (pipeline update $stamp)" -ForegroundColor Green

git -C $AppDir add -A
git -C $AppDir -c user.name="DevSecOps Demo" -c user.email="devsecops@local" `
    commit -m "Demo change: update welcome message ($stamp)"
if ($LASTEXITCODE -ne 0) { throw "git commit failed" }

git -C $AppDir push origin HEAD
if ($LASTEXITCODE -ne 0) { throw "git push failed - authenticate to GitHub (git push from $AppDir) and retry." }

Write-Host ""
Write-Host "[OK] Change pushed." -ForegroundColor Green
Write-Host ""
Write-Host "What happens next (no action needed):" -ForegroundColor Yellow
Write-Host "  * Within ~2 minutes Jenkins SCM polling detects the commit and starts a build."
Write-Host "  * Watch it live:      http://localhost:8080/blue"
Write-Host "  * Build cause shows:  'Started by an SCM change'  (screenshot this!)"
Write-Host "  * When the build is green, refresh the production app:  http://localhost:8888"
Write-Host "    The home page heading now shows the timestamped welcome message."
