#Requires -RunAsAdministrator
<#
===============================================================================
 setup.ps1 - Fully automated DevSecOps pipeline for Spring PetClinic
 Target host: Windows 11 + Docker Desktop (WSL2) + Multipass + Git
===============================================================================
 What this script provisions, unattended:

   1.  Kernel setting for SonarQube's embedded Elasticsearch
   2.  All configuration files (Jenkins image, JCasC, Prometheus, Grafana,
       Jenkinsfile, app Dockerfile, Ansible playbook + inventory)
   3.  Custom Docker network 'devsecops-net'
   4.  SonarQube container  -> waits for UP, sets admin password, generates an
       analysis token and a Jenkins webhook via the REST API
   5.  SSH keypair (generated inside a throwaway Linux container - no Windows
       ssh-keygen quoting issues)
   6.  Multipass Ubuntu VM 'prod-server' (the production web server) with the
       Jenkins public key authorized
   7.  netsh portproxy bridges  host:2222 -> VM:22  and  host:8888 -> VM:8080
       (a Jenkins container reaches the VM via host.docker.internal - the one
       deterministic container->VM path on Docker Desktop)
   8.  Prometheus, Grafana (auto-provisioned datasource + dashboards) and a
       persistent ZAP daemon container
   9.  Injects Jenkinsfile/Dockerfile/Ansible into YOUR spring-petclinic fork,
       commits and pushes
   10. Builds a custom Jenkins image (Ansible + Docker CLI + plugins + JCasC),
       starts it, installs the SSH key, and the first pipeline build queues
       automatically (Job DSL 'queue()')

 Usage (Administrator PowerShell console):
   powershell -ExecutionPolicy Bypass -File .\setup.ps1 `
       -ForkUrl "https://github.com/<YOUR-USER>/spring-petclinic.git"

 The script is idempotent: safe to re-run (also the fix after a host reboot,
 because the VM IP can change and the port proxies must be refreshed).
===============================================================================
#>

[CmdletBinding()]
param(
    [string]$ForkUrl = "",
    [string]$WorkDir = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $WorkDir) {
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $WorkDir = Join-Path $base "devsecops"
}

# ----------------------------- helpers --------------------------------------

function Write-Step([string]$m) {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor DarkCyan
    Write-Host "  $m" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor DarkCyan
}
function Write-Ok([string]$m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Info([string]$m) { Write-Host "  $m" -ForegroundColor Gray }

# Writes text with LF line endings, UTF-8 without BOM (critical: CRLF or a BOM
# inside Jenkinsfile/shell/yaml content breaks Linux-side tooling).
function Write-LF([string]$Path, [string]$Content) {
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lf = $Content -replace "`r`n", "`n"
    if (-not $lf.EndsWith("`n")) { $lf += "`n" }
    [System.IO.File]::WriteAllText($Path, $lf, [System.Text.UTF8Encoding]::new($false))
}

# Runs a native command discarding output; returns the exit code. Used for
# commands whose failure is expected/ignorable (idempotent deletes etc.).
function Invoke-Quiet([string]$CommandLine) {
    cmd /c "$CommandLine >nul 2>&1"
    return $LASTEXITCODE
}

function Assert-LastExit([string]$What) {
    if ($LASTEXITCODE -ne 0) { throw "FAILED: $What (exit code $LASTEXITCODE)" }
}

# ----------------------------- STEP 0: preflight -----------------------------

Write-Step "STEP 0 - Preflight checks"

foreach ($tool in @("docker", "git", "multipass")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw @"
Required tool '$tool' was not found on PATH. Install the prerequisites:

    winget install -e --id Docker.DockerDesktop
    winget install -e --id Canonical.Multipass
    winget install -e --id Git.Git

Then start Docker Desktop and re-run this script.
(Windows 11 Home only: install VirtualBox and run 'multipass set local.driver=virtualbox' once.)
"@
    }
}

if ((Invoke-Quiet "docker info") -ne 0) {
    throw "Docker Desktop is not running. Start it, wait for the whale icon to settle, then re-run."
}
Write-Ok "docker, git and multipass found; Docker engine is responding"

if (-not $ForkUrl) {
    $ForkUrl = Read-Host "Enter the HTTPS URL of YOUR spring-petclinic fork (e.g. https://github.com/<you>/spring-petclinic.git)"
}
$ForkUrl = $ForkUrl.Trim()
if ($ForkUrl -notmatch '^https://') {
    throw "The fork URL must be HTTPS (Jenkins clones it anonymously). Got: $ForkUrl"
}
if ($ForkUrl -match 'github\.com/spring-projects/spring-petclinic') {
    throw "That is the upstream repository. Fork it on GitHub first (Fork button) and pass YOUR fork's URL."
}
if ($ForkUrl -notmatch '\.git$') { $ForkUrl = "$ForkUrl.git" }
Write-Ok "Using fork: $ForkUrl"
Write-Info "Working directory: $WorkDir"
Write-Info "First run takes roughly 20-35 minutes (image pulls, plugin installs, first Maven build)."

# ------------------- STEP 1: kernel setting for SonarQube --------------------

Write-Step "STEP 1 - Elasticsearch kernel setting (SonarQube)"
if ((Invoke-Quiet "wsl -d docker-desktop sysctl -w vm.max_map_count=262144") -eq 0) {
    Write-Ok "vm.max_map_count=262144 applied inside the docker-desktop WSL VM"
} else {
    Write-Info "Could not set vm.max_map_count (non-fatal: SONAR_ES_BOOTSTRAP_CHECKS_DISABLE is used as a fallback)."
}

# ------------------- STEP 2: write all configuration files -------------------

Write-Step "STEP 2 - Writing configuration files to $WorkDir"

foreach ($d in @("jenkins", "prometheus", "grafana\provisioning\datasources",
                 "grafana\provisioning\dashboards", "grafana\dashboards", "keys")) {
    New-Item -ItemType Directory -Path (Join-Path $WorkDir $d) -Force | Out-Null
}

# ---- Jenkins plugins (installed at image build time; dependencies resolved
# ---- automatically by jenkins-plugin-cli) ----
$pluginsTxt = @'
configuration-as-code
job-dsl
workflow-aggregator
git
github
blueocean
sonar
prometheus
htmlpublisher
docker-workflow
junit
'@
Write-LF (Join-Path $WorkDir "jenkins\plugins.txt") $pluginsTxt

# ---- Custom Jenkins image: LTS + Ansible + Docker CLI + plugins + JCasC ----
$jenkinsDockerfile = @'
FROM jenkins/jenkins:lts-jdk21
USER root

# Ansible (deploys to the production VM), SSH client, and the Docker CLI
# (which talks to Docker Desktop's engine through the mounted docker.sock).
RUN apt-get update && \
    apt-get install -y --no-install-recommends ansible openssh-client sshpass curl ca-certificates gnupg && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

# Pre-install all Jenkins plugins at build time (no setup wizard, no clicks).
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Configuration-as-Code: users, SonarQube server, credentials, pipeline job.
COPY casc.yaml /usr/local/casc.yaml
ENV CASC_JENKINS_CONFIG=/usr/local/casc.yaml

# Skip the setup wizard; relax CSP so the ZAP HTML report renders with styling.
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Dhudson.model.DirectoryBrowserSupport.CSP="
'@
Write-LF (Join-Path $WorkDir "jenkins\Dockerfile") $jenkinsDockerfile

# ---- Jenkins Configuration-as-Code. ${SONAR_TOKEN} and ${GITHUB_REPO_URL}
# ---- are substituted from container environment variables at startup. ----
$cascYaml = @'
jenkins:
  systemMessage: "Spring PetClinic DevSecOps - provisioned automatically via Configuration-as-Code"
  numExecutors: 2
  securityRealm:
    local:
      allowsSignup: false
      users:
        - id: "admin"
          password: "admin"
  authorizationStrategy:
    loggedInUsersCanDoAnything:
      allowAnonymousRead: false

unclassified:
  location:
    url: "http://localhost:8080/"
  sonarGlobalConfiguration:
    buildWrapperEnabled: false
    installations:
      - name: "SonarQube"
        serverUrl: "http://sonarqube:9000"
        credentialsId: "sonar-token"

credentials:
  system:
    domainCredentials:
      - credentials:
          - string:
              scope: GLOBAL
              id: "sonar-token"
              description: "SonarQube analysis token (generated by setup.ps1)"
              secret: "${SONAR_TOKEN}"

jobs:
  - script: |
      pipelineJob('petclinic-devsecops') {
        description('CI/CD + security + monitoring pipeline for Spring PetClinic (generated by JCasC/Job DSL).')
        definition {
          cpsScm {
            scm {
              git {
                remote { url('${GITHUB_REPO_URL}') }
                branch('*/main')
              }
            }
            scriptPath('Jenkinsfile')
            lightweight(true)
          }
        }
      }
      queue('petclinic-devsecops')
'@
Write-LF (Join-Path $WorkDir "jenkins\casc.yaml") $cascYaml

# ---- Prometheus: scrape itself + the Jenkins Prometheus plugin endpoint ----
$prometheusYml = @'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'jenkins'
    metrics_path: '/prometheus/'
    static_configs:
      - targets: ['jenkins:8080']
'@
Write-LF (Join-Path $WorkDir "prometheus\prometheus.yml") $prometheusYml

# ---- Grafana provisioning: Prometheus datasource + file-based dashboards ----
$grafanaDatasource = @'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
'@
Write-LF (Join-Path $WorkDir "grafana\provisioning\datasources\datasource.yml") $grafanaDatasource

$grafanaProvider = @'
apiVersion: 1
providers:
  - name: 'devsecops'
    orgId: 1
    folder: ''
    type: file
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
'@
Write-LF (Join-Path $WorkDir "grafana\provisioning\dashboards\provider.yml") $grafanaProvider

$grafanaDashboard = @'
{
  "uid": "jenkins-devsecops",
  "title": "Jenkins - DevSecOps Overview (custom)",
  "tags": ["jenkins", "devsecops"],
  "timezone": "browser",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "30s",
  "time": { "from": "now-3h", "to": "now" },
  "panels": [
    {
      "type": "stat",
      "title": "Jenkins Scrape Target Up",
      "id": 1,
      "gridPos": { "h": 6, "w": 6, "x": 0, "y": 0 },
      "targets": [ { "expr": "up{job=\"jenkins\"}", "refId": "A" } ]
    },
    {
      "type": "stat",
      "title": "Build Queue Size",
      "id": 2,
      "gridPos": { "h": 6, "w": 6, "x": 6, "y": 0 },
      "targets": [ { "expr": "default_jenkins_queue_size_value", "refId": "A" } ]
    },
    {
      "type": "timeseries",
      "title": "Jenkins Scrape Duration (s)",
      "id": 3,
      "gridPos": { "h": 6, "w": 12, "x": 12, "y": 0 },
      "targets": [ { "expr": "scrape_duration_seconds{job=\"jenkins\"}", "refId": "A" } ]
    },
    {
      "type": "timeseries",
      "title": "Last Build Duration per Job (ms)",
      "id": 4,
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 6 },
      "targets": [ { "expr": "default_jenkins_builds_last_build_duration_milliseconds", "legendFormat": "{{jenkins_job}}", "refId": "A" } ]
    },
    {
      "type": "timeseries",
      "title": "Total Builds Recorded",
      "id": 5,
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 6 },
      "targets": [ { "expr": "sum(default_jenkins_builds_duration_milliseconds_summary_count)", "refId": "A" } ]
    }
  ]
}
'@
Write-LF (Join-Path $WorkDir "grafana\dashboards\jenkins-overview.json") $grafanaDashboard

# ---- Files injected into the spring-petclinic fork -------------------------

$jenkinsfile = @'
pipeline {
    agent any

    triggers {
        // SCM polling: check the Git repository for new commits every ~2 min.
        pollSCM('H/2 * * * *')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build & Unit Tests') {
            steps {
                // Testcontainers-based *IntegrationTests are excluded so the
                // build is self-contained; all plain unit tests still run.
                sh "./mvnw -B clean package -Dtest='!*IntegrationTests' -Dsurefire.failIfNoSpecifiedTests=false"
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'target/surefire-reports/*.xml'
                }
            }
        }

        stage('SonarQube Analysis') {
            steps {
                withSonarQubeEnv('SonarQube') {
                    sh './mvnw -B org.sonarsource.scanner.maven:sonar-maven-plugin:5.0.0.4389:sonar -Dsonar.projectKey=spring-petclinic -Dsonar.projectName=spring-petclinic -Dsonar.host.url=$SONAR_HOST_URL -Dsonar.token=$SONAR_AUTH_TOKEN'
                }
            }
        }

        stage('Build Docker Image') {
            steps {
                sh 'docker build -t petclinic:$BUILD_NUMBER -t petclinic:latest .'
            }
        }

        stage('Deploy to Staging') {
            steps {
                sh '''
                    docker rm -f petclinic-staging || true
                    docker run -d --name petclinic-staging --network devsecops-net petclinic:$BUILD_NUMBER
                    echo "Waiting for the staging app to come up..."
                    for i in $(seq 1 36); do
                        if curl -sf -o /dev/null http://petclinic-staging:8080; then
                            echo "Staging is UP"
                            exit 0
                        fi
                        sleep 5
                    done
                    echo "Staging app did not start in time"
                    docker logs petclinic-staging | tail -50
                    exit 1
                '''
            }
        }

        stage('ZAP Security Scan (DAST)') {
            steps {
                sh '''
                    docker rm -f zap-scan || true
                    docker run --name zap-scan --network devsecops-net zaproxy/zap-stable \
                        bash -c "mkdir -p /zap/wrk && cd /zap/wrk && zap-baseline.py -t http://petclinic-staging:8080 -r zap-report.html -I" || true
                    docker cp zap-scan:/zap/wrk/zap-report.html ./zap-report.html || true
                    docker rm -f zap-scan || true
                '''
            }
        }

        stage('Deploy to Production (Ansible -> VM)') {
            steps {
                sh '''
                    JAR=$(ls $WORKSPACE/target/*.jar | head -1)
                    echo "Deploying $JAR to the production VM via Ansible..."
                    ansible-playbook -i ansible/inventory.ini ansible/deploy.yml -e app_jar=$JAR
                '''
            }
        }

        stage('Production Smoke Test') {
            steps {
                sh '''
                    echo "Verifying production (host.docker.internal:8888 -> VM:8080)..."
                    for i in $(seq 1 36); do
                        if curl -sf -o /dev/null http://host.docker.internal:8888; then
                            echo "PRODUCTION DEPLOYMENT VERIFIED"
                            exit 0
                        fi
                        sleep 5
                    done
                    echo "Production app did not respond in time"
                    exit 1
                '''
            }
        }
    }

    post {
        always {
            publishHTML(target: [
                allowMissing: true,
                alwaysLinkToLastBuild: true,
                keepAll: true,
                reportDir: '.',
                reportFiles: 'zap-report.html',
                reportName: 'ZAP Security Report'
            ])
            archiveArtifacts artifacts: 'zap-report.html, target/*.jar', allowEmptyArchive: true
        }
    }
}
'@

$appDockerfile = @'
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
'@

$ansibleInventory = @'
[prod]
prod-server ansible_host=host.docker.internal ansible_port=2222 ansible_user=ubuntu ansible_ssh_private_key_file=/root/.ssh/id_rsa ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
'@

$ansiblePlaybook = @'
---
- name: Deploy Spring PetClinic to the production VM
  hosts: prod
  become: true
  vars:
    app_jar: ""   # passed by Jenkins with -e app_jar=/path/to/jar

  tasks:
    - name: Install Java runtime
      apt:
        name: openjdk-21-jre-headless
        state: present
        update_cache: yes

    - name: Create application directory
      file:
        path: /opt/petclinic
        state: directory
        mode: '0755'

    - name: Copy application jar
      copy:
        src: "{{ app_jar }}"
        dest: /opt/petclinic/petclinic.jar
        mode: '0644'

    - name: Install systemd service
      copy:
        dest: /etc/systemd/system/petclinic.service
        mode: '0644'
        content: |
          [Unit]
          Description=Spring PetClinic
          After=network.target

          [Service]
          User=ubuntu
          ExecStart=/usr/bin/java -jar /opt/petclinic/petclinic.jar
          SuccessExitStatus=143
          Restart=always
          RestartSec=5

          [Install]
          WantedBy=multi-user.target

    - name: Restart and enable the service
      systemd:
        name: petclinic
        state: restarted
        enabled: yes
        daemon_reload: yes
'@

Write-Ok "All configuration files written"

# ------------------- STEP 3: custom Docker network ---------------------------

Write-Step "STEP 3 - Custom Docker network"
Invoke-Quiet "docker network create devsecops-net" | Out-Null
Write-Ok "Network 'devsecops-net' present"

# ------------------- STEP 4: SonarQube --------------------------------------

Write-Step "STEP 4 - SonarQube (static analysis server)"
Invoke-Quiet "docker rm -f sonarqube" | Out-Null
$sonarArgs = @(
    'run', '-d', '--name', 'sonarqube', '--network', 'devsecops-net',
    '-p', '9000:9000',
    '-e', 'SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true',
    '-v', 'sonarqube_data:/opt/sonarqube/data',
    '-v', 'sonarqube_extensions:/opt/sonarqube/extensions',
    '-v', 'sonarqube_logs:/opt/sonarqube/logs',
    '--restart', 'unless-stopped',
    'sonarqube:community'
)
& docker @sonarArgs | Out-Null
Assert-LastExit "docker run sonarqube"
Write-Info "Waiting for SonarQube to report status UP (2-5 minutes on first boot)..."

$sonarUp = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        $s = Invoke-RestMethod -Uri "http://localhost:9000/api/system/status" -TimeoutSec 5
        if ($s.status -eq "UP") { $sonarUp = $true; break }
    } catch {}
    Start-Sleep -Seconds 10
}
if (-not $sonarUp) { throw "SonarQube did not become ready within 10 minutes. Diagnose with: docker logs sonarqube" }
Write-Ok "SonarQube is UP at http://localhost:9000"

$SonarPass = "DevSecOps!2026"
$hdrDefault = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:admin")) }
try {
    Invoke-RestMethod -Method Post -Uri "http://localhost:9000/api/users/change_password" `
        -Headers $hdrDefault -Body @{ login = "admin"; previousPassword = "admin"; password = $SonarPass } | Out-Null
    Write-Ok "SonarQube admin password set (admin / $SonarPass)"
} catch {
    Write-Info "Admin password already changed on a previous run (OK)"
}

$hdr = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$SonarPass")) }
$tokenName = "jenkins-" + (Get-Date -Format "yyyyMMddHHmmss")
$tok = Invoke-RestMethod -Method Post -Uri "http://localhost:9000/api/user_tokens/generate" `
    -Headers $hdr -Body @{ name = $tokenName }
$SonarToken = $tok.token
if (-not $SonarToken) { throw "Failed to generate a SonarQube analysis token." }
Write-Ok "SonarQube analysis token generated ($tokenName)"

try {
    Invoke-RestMethod -Method Post -Uri "http://localhost:9000/api/webhooks/create" `
        -Headers $hdr -Body @{ name = "jenkins"; url = "http://jenkins:8080/sonarqube-webhook/" } | Out-Null
    Write-Ok "SonarQube -> Jenkins quality-gate webhook created"
} catch {
    Write-Info "Webhook already exists (OK)"
}

# ------------------- STEP 5: SSH keypair (via Linux container) ---------------

Write-Step "STEP 5 - SSH keypair for Ansible (Jenkins -> VM)"
$KeysDir = Join-Path $WorkDir "keys"
if (-not (Test-Path (Join-Path $KeysDir "id_rsa"))) {
    $ka = @(
        'run', '--rm', '-v', "${KeysDir}:/keys", 'alpine:latest',
        'sh', '-c',
        "apk add --no-cache openssh-keygen >/dev/null 2>&1 && ssh-keygen -q -t rsa -b 4096 -N '' -f /keys/id_rsa"
    )
    & docker @ka
    Assert-LastExit "generate SSH keypair inside an alpine container"
    Write-Ok "New 4096-bit RSA keypair generated in $KeysDir"
} else {
    Write-Info "Reusing existing keypair in $KeysDir"
}
$PubKeyFile = Join-Path $KeysDir "id_rsa.pub"

# ------------------- STEP 6: production VM (Multipass) -----------------------

Write-Step "STEP 6 - Production web server VM (Multipass / Hyper-V)"
$vmState = ""
try {
    $ml = multipass list --format json | ConvertFrom-Json
    $vm = $ml.list | Where-Object { $_.name -eq "prod-server" }
    if ($vm) { $vmState = [string]$vm.state }
} catch {}

if (-not $vmState) {
    Write-Info "Launching Ubuntu LTS VM 'prod-server' (1 vCPU / 2 GB RAM / 8 GB disk, bridged to Ethernet)..."
    multipass launch --name prod-server --cpus 1 --memory 2G --disk 8G --network name=Ethernet
    Assert-LastExit "multipass launch prod-server"
} else {
    if ($vmState -eq "Deleted") { Invoke-Quiet "multipass recover prod-server" | Out-Null }
    Invoke-Quiet "multipass start prod-server" | Out-Null
    Write-Info "VM 'prod-server' already exists (state was: $vmState) - reusing it"
}

$infoJson = multipass info prod-server --format json | ConvertFrom-Json
$VmIp = ($infoJson.info.'prod-server'.ipv4 | Where-Object { $_ -and $_ -ne "N/A" -and $_ -notmatch '^10\.0\.2\.' } | Select-Object -First 1)
if (-not $VmIp) {
    $hostnameOutput = multipass exec prod-server -- hostname -I 2>$null
    if ($hostnameOutput) {
        $VmIp = ($hostnameOutput -split '\s+' | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^10\.0\.2\.' } | Select-Object -First 1)
    }
}
if (-not $VmIp) {
    throw "Could not determine the VM's IP address. Try 'multipass start prod-server' then 'multipass info prod-server', and re-run this script."
}
Write-Ok "VM 'prod-server' running at $VmIp"

multipass transfer $PubKeyFile prod-server:/home/ubuntu/jenkins_key.pub
Assert-LastExit "multipass transfer public key"
multipass exec prod-server -- bash -c "mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF -f ~/jenkins_key.pub ~/.ssh/authorized_keys || cat ~/jenkins_key.pub >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"
Assert-LastExit "authorize the Jenkins SSH key on the VM"
Write-Ok "Jenkins public key authorized for ubuntu@prod-server"

# ------------------- STEP 7: host->VM port bridges ---------------------------

Write-Step "STEP 7 - Port proxies (containers reach the VM via host.docker.internal)"
Invoke-Quiet "netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=2222" | Out-Null
cmd /c "netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=2222 connectaddress=$VmIp connectport=22 >nul"
Assert-LastExit "netsh portproxy 2222 -> ${VmIp}:22"
Invoke-Quiet "netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=8888" | Out-Null
cmd /c "netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=8888 connectaddress=$VmIp connectport=8080 >nul"
Assert-LastExit "netsh portproxy 8888 -> ${VmIp}:8080"

Invoke-Quiet "netsh advfirewall firewall delete rule name=DevSecOps-SSH-2222" | Out-Null
Invoke-Quiet "netsh advfirewall firewall add rule name=DevSecOps-SSH-2222 dir=in action=allow protocol=TCP localport=2222" | Out-Null
Invoke-Quiet "netsh advfirewall firewall delete rule name=DevSecOps-App-8888" | Out-Null
Invoke-Quiet "netsh advfirewall firewall add rule name=DevSecOps-App-8888 dir=in action=allow protocol=TCP localport=8888" | Out-Null
Write-Ok "host:2222 -> VM:22 (SSH/Ansible)   host:8888 -> VM:8080 (production app)"

# ------------------- STEP 8: monitoring + ZAP containers ---------------------

Write-Step "STEP 8 - Prometheus, Grafana and ZAP"

Invoke-Quiet "docker rm -f prometheus" | Out-Null
$promCfg = Join-Path $WorkDir "prometheus\prometheus.yml"
$pa = @(
    'run', '-d', '--name', 'prometheus', '--network', 'devsecops-net',
    '-p', '9090:9090',
    '-v', "${promCfg}:/etc/prometheus/prometheus.yml:ro",
    '--restart', 'unless-stopped', 'prom/prometheus'
)
& docker @pa | Out-Null
Assert-LastExit "docker run prometheus"
Write-Ok "Prometheus running at http://localhost:9090"

# Community Jenkins dashboard (grafana.com id 9964); non-fatal if offline.
try {
    $resp = Invoke-WebRequest -Uri "https://grafana.com/api/dashboards/9964/revisions/latest/download" -UseBasicParsing -TimeoutSec 30
    $dash = $resp.Content -replace '\$\{DS_PROMETHEUS\}', 'Prometheus'
    Write-LF (Join-Path $WorkDir "grafana\dashboards\jenkins-community-9964.json") $dash
    Write-Ok "Community Jenkins dashboard #9964 downloaded and wired to the Prometheus datasource"
} catch {
    Write-Info "Could not download community dashboard 9964 (non-fatal; the custom dashboard is still provisioned)."
}

Invoke-Quiet "docker rm -f grafana" | Out-Null
$ga = @(
    'run', '-d', '--name', 'grafana', '--network', 'devsecops-net',
    '-p', '3000:3000',
    '-e', 'GF_SECURITY_ADMIN_USER=admin',
    '-e', 'GF_SECURITY_ADMIN_PASSWORD=admin',
    '-v', ((Join-Path $WorkDir 'grafana\provisioning') + ':/etc/grafana/provisioning:ro'),
    '-v', ((Join-Path $WorkDir 'grafana\dashboards') + ':/var/lib/grafana/dashboards:ro'),
    '--restart', 'unless-stopped', 'grafana/grafana'
)
& docker @ga | Out-Null
Assert-LastExit "docker run grafana"
Write-Ok "Grafana running at http://localhost:3000 (admin / admin)"

Invoke-Quiet "docker rm -f zap" | Out-Null
$za = @(
    'run', '-d', '--name', 'zap', '--network', 'devsecops-net',
    '-p', '8090:8090', '--restart', 'unless-stopped',
    'zaproxy/zap-stable', 'zap.sh', '-daemon', '-host', '0.0.0.0', '-port', '8090',
    '-config', 'api.disablekey=true',
    '-config', 'api.addrs.addr.name=.*',
    '-config', 'api.addrs.addr.regex=true'
)
& docker @za | Out-Null
Assert-LastExit "docker run zap"
Write-Ok "ZAP daemon running at http://localhost:8090 (per-build baseline scans run as ephemeral containers)"

Write-Info "Pre-pulling the app runtime image (eclipse-temurin:21-jre) so the first pipeline run is faster..."
Invoke-Quiet "docker pull eclipse-temurin:21-jre" | Out-Null

# ------------------- STEP 9: inject pipeline files into the fork -------------

Write-Step "STEP 9 - Injecting Jenkinsfile/Dockerfile/Ansible into your fork and pushing"

$AppDir = Join-Path $WorkDir "app"
if (-not (Test-Path (Join-Path $AppDir ".git"))) {
    git clone $ForkUrl $AppDir
    Assert-LastExit "git clone $ForkUrl"
} else {
    Write-Info "Fork already cloned at $AppDir - reusing it"
}

Write-LF (Join-Path $AppDir "Jenkinsfile") $jenkinsfile
Write-LF (Join-Path $AppDir "Dockerfile") $appDockerfile
Write-LF (Join-Path $AppDir "ansible\inventory.ini") $ansibleInventory
Write-LF (Join-Path $AppDir "ansible\deploy.yml") $ansiblePlaybook

git -C $AppDir add -A
$dirty = git -C $AppDir status --porcelain
if ($dirty) {
    git -C $AppDir -c user.name="DevSecOps Setup" -c user.email="devsecops@local" `
        commit -m "Add DevSecOps pipeline (Jenkinsfile, Dockerfile, Ansible deployment)"
    Assert-LastExit "git commit"
} else {
    Write-Info "Pipeline files already committed - nothing new to commit"
}

git -C $AppDir push origin HEAD
if ($LASTEXITCODE -ne 0) {
    throw @"
git push to your fork failed. Fix authentication and re-run:
  1) cd $AppDir
  2) git push        (sign in via the Git Credential Manager browser popup)
  3) re-run setup.ps1
"@
}
Write-Ok "Pipeline files pushed to $ForkUrl"

# ------------------- STEP 10: Jenkins ---------------------------------------

Write-Step "STEP 10 - Jenkins (custom image: Ansible + Docker CLI + plugins + JCasC)"

docker build -t custom-jenkins (Join-Path $WorkDir "jenkins")
Assert-LastExit "docker build custom-jenkins"

Invoke-Quiet "docker rm -f jenkins" | Out-Null
$ja = @(
    'run', '-d', '--name', 'jenkins', '--network', 'devsecops-net',
    '-p', '8080:8080', '-p', '50000:50000',
    '-u', 'root',
    '-v', 'jenkins_home:/var/jenkins_home',
    '-v', '/var/run/docker.sock:/var/run/docker.sock',
    '-e', "SONAR_TOKEN=$SonarToken",
    '-e', "GITHUB_REPO_URL=$ForkUrl",
    '--restart', 'unless-stopped', 'custom-jenkins'
)
& docker @ja | Out-Null
Assert-LastExit "docker run jenkins"
Write-Info "Waiting for Jenkins to come up..."

$jenkinsUp = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:8080/login" -UseBasicParsing -TimeoutSec 5
        if ($r.StatusCode -eq 200) { $jenkinsUp = $true; break }
    } catch {}
    Start-Sleep -Seconds 5
}
if (-not $jenkinsUp) { throw "Jenkins did not come up within 5 minutes. Diagnose with: docker logs jenkins" }

docker exec jenkins bash -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
Assert-LastExit "prepare /root/.ssh in Jenkins"
docker cp (Join-Path $KeysDir "id_rsa") jenkins:/root/.ssh/id_rsa
Assert-LastExit "copy private key into Jenkins"
docker exec jenkins chmod 600 /root/.ssh/id_rsa
Assert-LastExit "chmod private key in Jenkins"
Write-Ok "Jenkins is UP; deployment SSH key installed"

# ------------------- Summary -------------------------------------------------

Write-Step "ALL DONE - the first pipeline build is already queued"
Write-Host ""
Write-Host "  Service            URL                                Credentials" -ForegroundColor Yellow
Write-Host "  -----------------  ---------------------------------  --------------------"
Write-Host "  Jenkins            http://localhost:8080              admin / admin"
Write-Host "  Blue Ocean         http://localhost:8080/blue         admin / admin"
Write-Host "  SonarQube          http://localhost:9000              admin / $SonarPass"
Write-Host "  Prometheus         http://localhost:9090              -"
Write-Host "  Grafana            http://localhost:3000              admin / admin"
Write-Host "  ZAP daemon         http://localhost:8090              -"
Write-Host "  PRODUCTION (VM)    http://localhost:8888              -   (also http://${VmIp}:8080)"
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "   1. Watch the first build:  http://localhost:8080/blue  (first run ~8-15 min: Maven downloads)"
Write-Host "   2. When it is green, open  http://localhost:8888  -> PetClinic welcome screen on the VM"
Write-Host "   3. Demonstrate auto-rebuild on a code change:  powershell -ExecutionPolicy Bypass -File .\demo-change.ps1"
Write-Host "   4. Take the screenshots listed in README.md"
Write-Host ""
Write-Host "  NOTE: after a host reboot the VM IP can change - just re-run setup.ps1 (idempotent)." -ForegroundColor Gray
Write-Host ""
