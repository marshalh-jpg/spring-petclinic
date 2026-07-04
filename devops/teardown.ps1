#Requires -RunAsAdministrator
<#
===============================================================================
 teardown.ps1 - Remove everything setup.ps1 created
===============================================================================
 Default:        removes containers, the Docker network, port proxies and
                 firewall rules. Data volumes, the VM and your cloned fork
                 are KEPT so a later setup.ps1 re-run restores service fast.

 -RemoveVolumes  also deletes the Jenkins and SonarQube data volumes
 -RemoveVm       also deletes and purges the Multipass 'prod-server' VM

 Full wipe:
   powershell -ExecutionPolicy Bypass -File .\teardown.ps1 -RemoveVolumes -RemoveVm
===============================================================================
#>

[CmdletBinding()]
param(
    [switch]$RemoveVolumes,
    [switch]$RemoveVm
)

$ErrorActionPreference = "Continue"

function Invoke-Quiet([string]$CommandLine) {
    cmd /c "$CommandLine >nul 2>&1"
    return $LASTEXITCODE
}

Write-Host "Removing containers..." -ForegroundColor Cyan
foreach ($c in @("jenkins", "sonarqube", "prometheus", "grafana", "zap", "petclinic-staging", "zap-scan")) {
    Invoke-Quiet "docker rm -f $c" | Out-Null
    Write-Host "  removed (if present): $c"
}

Write-Host "Removing Docker network 'devsecops-net'..." -ForegroundColor Cyan
Invoke-Quiet "docker network rm devsecops-net" | Out-Null

if ($RemoveVolumes) {
    Write-Host "Removing data volumes..." -ForegroundColor Cyan
    foreach ($v in @("jenkins_home", "sonarqube_data", "sonarqube_extensions", "sonarqube_logs")) {
        Invoke-Quiet "docker volume rm $v" | Out-Null
        Write-Host "  removed (if present): $v"
    }
} else {
    Write-Host "Data volumes kept (use -RemoveVolumes to delete jenkins_home + sonarqube_*)." -ForegroundColor Gray
}

if ($RemoveVm) {
    Write-Host "Deleting Multipass VM 'prod-server'..." -ForegroundColor Cyan
    Invoke-Quiet "multipass delete prod-server" | Out-Null
    Invoke-Quiet "multipass purge" | Out-Null
} else {
    Write-Host "VM 'prod-server' kept (use -RemoveVm to delete it)." -ForegroundColor Gray
}

Write-Host "Removing port proxies and firewall rules..." -ForegroundColor Cyan
Invoke-Quiet "netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=2222" | Out-Null
Invoke-Quiet "netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=8888" | Out-Null
Invoke-Quiet "netsh advfirewall firewall delete rule name=DevSecOps-SSH-2222" | Out-Null
Invoke-Quiet "netsh advfirewall firewall delete rule name=DevSecOps-App-8888" | Out-Null

Write-Host ""
Write-Host "Teardown complete." -ForegroundColor Green
Write-Host "Note: docker images (custom-jenkins, petclinic:*, sonarqube, etc.) and the" -ForegroundColor Gray
Write-Host "cloned fork in .\devsecops\app are kept. Remove manually if desired:" -ForegroundColor Gray
Write-Host "  docker image prune -a          # removes ALL unused images" -ForegroundColor Gray
Write-Host "  Remove-Item -Recurse .\devsecops" -ForegroundColor Gray
