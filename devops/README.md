# Spring PetClinic DevSecOps Pipeline — Fully Automated (Windows 11)

One command provisions a complete DevSecOps environment: **Jenkins** (CI/CD),
**SonarQube** (static analysis), **OWASP ZAP** (dynamic security scanning),
**Prometheus + Grafana** (monitoring), all containerized on a custom Docker
network, plus **Ansible** deployment to a **production VM** — with zero manual
clicks. The first pipeline build queues itself.

---

## 1. Architecture

```
Windows 11 host
│
├── Docker Desktop (WSL2) ── custom network: devsecops-net
│     ├── jenkins      :8080   custom image (LTS + Ansible + Docker CLI +
│     │                        plugins preinstalled + Configuration-as-Code)
│     ├── sonarqube    :9000   static analysis (SAST)
│     ├── prometheus   :9090 ──scrapes──► jenkins:8080/prometheus/
│     ├── grafana      :3000 ──queries──► prometheus (auto-provisioned)
│     ├── zap          :8090   persistent ZAP daemon; per-build baseline
│     │                        scans run as ephemeral containers
│     └── petclinic-staging :8080 (internal) — created by the pipeline,
│                                  target of the ZAP DAST scan
│
├── Multipass VM "prod-server" (Ubuntu LTS on Hyper-V)  ◄── PRODUCTION
│     └── petclinic.service (systemd) listening on :8080
│
└── netsh portproxy bridges (host → VM):
      2222 → VM:22    Jenkins/Ansible SSH via host.docker.internal:2222
      8888 → VM:8080  browse production at http://localhost:8888
```

**Pipeline flow per commit:** Checkout → Build & Unit Tests → SonarQube
Analysis → Docker Image → Deploy Staging → ZAP Baseline Scan (report
published in Jenkins) → Ansible Deploy to VM → Production Smoke Test.

### Key design decisions

| Decision | Why |
|---|---|
| **Multipass** for the VM instead of VirtualBox/Vagrant | Multipass uses Hyper-V natively, the same hypervisor family as Docker Desktop's WSL2 backend — no hypervisor conflict, one-command Ubuntu VMs, JSON-scriptable. |
| **`host.docker.internal` + netsh portproxy** for container→VM traffic | Docker containers and a Hyper-V VM live on different virtual switches; routing between them is not guaranteed. Bouncing through the Windows host is the one deterministic path, and it survives Docker network changes. |
| **JCasC + Job DSL** in a custom Jenkins image | Users, credentials, the SonarQube server, all plugins and the pipeline job exist the moment Jenkins boots — the Job DSL `queue()` even starts build #1. No setup wizard, no clicks. |
| **SonarQube token via REST API** | Solves the chicken-and-egg: SonarQube must be up before a token exists, and Jenkins needs the token at boot. The script waits for UP, rotates the default password, generates a token, and passes it to Jenkins as an env var consumed by JCasC. |
| **`SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true`** + WSL `vm.max_map_count` fix | Belt-and-suspenders against the single most common SonarQube-in-Docker failure (embedded Elasticsearch refusing to start). |
| **Jenkins runs as root with the Docker socket mounted** | Docker-outside-of-Docker: pipeline `docker build/run` commands drive Docker Desktop's engine directly. Root avoids the socket-GID permission maze. Lab-only tradeoff — see Security notes. |
| **SSH keys generated inside a throwaway Alpine container** | Sidesteps Windows `ssh-keygen` empty-passphrase quoting bugs and file-permission issues on Windows-mounted keys. |
| **All generated files written LF / UTF-8 no BOM** | CRLF inside a Jenkinsfile `sh` block or a YAML playbook is the classic silent Windows-authored-pipeline killer. |

---

## 2. Prerequisites

- **Windows 11 Pro/Enterprise** (Hyper-V available).
  *Windows 11 Home:* install VirtualBox, then run `multipass set local.driver=virtualbox` once after installing Multipass.
  This path needs three extra one-time host fixes, all explained in section 10 —
  `setup.ps1` itself already launches the VM with 1 vCPU and bridged networking
  to account for the first two:
  - Enable the **Windows Hypervisor Platform** optional feature (`Enable-WindowsOptionalFeature
    -Online -FeatureName HypervisorPlatform -All`) and reboot. Without it, VirtualBox's UEFI
    boot can deadlock outright when Docker Desktop's WSL2 backend is also using the hypervisor.
  - VirtualBox 7.2.x has a known race condition that hangs UEFI boot when a VM has 2+ vCPUs
    ([forum report](https://forums.virtualbox.org/viewtopic.php?t=114397)) — `setup.ps1` launches
    with `--cpus 1` to avoid it.
  - VirtualBox's default NAT networking is **not host-routable**, which breaks both `multipass
    info`'s IP reporting and the `netsh portproxy` bridges in STEP 7. `setup.ps1` launches with
    `--network name=Ethernet` (bridged to the host's physical adapter) instead — if your machine
    is on Wi-Fi rather than wired Ethernet, change that to `--network name=Wi-Fi` (run `multipass
    networks` to see the exact adapter names available).
  - Windows' **IP Helper service** (`iphlpsvc`) must be *running* for `netsh portproxy` rules to
    actually forward traffic — it's often `Manual` startup and not started by default. Run
    `Start-Service iphlpsvc; Set-Service iphlpsvc -StartupType Automatic` once so it survives reboots.
- **≥ 16 GB RAM** recommended (SonarQube + Jenkins + Maven builds + a 2 GB VM). Docker Desktop's WSL2 default (50 % of host RAM) is fine.
- **~15 GB free disk** for images, volumes and the VM.
- Tools (install via winget, then **start Docker Desktop** and wait for the whale to settle):

```powershell
winget install -e --id Docker.DockerDesktop
winget install -e --id Canonical.Multipass
winget install -e --id Git.Git
```

- A **GitHub fork** of `https://github.com/spring-projects/spring-petclinic`
  (click *Fork* in the GitHub UI) and the ability to push to it from this
  machine (the first `git push` opens a Git Credential Manager browser sign-in).

---

## 3. Quick start

Open **Windows Terminal → PowerShell → Run as administrator**, `cd` to the
folder containing these scripts, then:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -ForkUrl "https://github.com/<YOUR-USER>/spring-petclinic.git"
```

First run: **20–35 minutes** (image pulls, Jenkins plugin installs, VM launch,
first Maven build). The first pipeline build queues automatically — watch it at
<http://localhost:8080/blue> (admin / admin). When it's green, the PetClinic
welcome screen is live on the VM at <http://localhost:8888>.

Then demonstrate the automatic rebuild + redeploy on a code change:

```powershell
powershell -ExecutionPolicy Bypass -File .\demo-change.ps1
```

---

## 4. Access table

| Service | URL | Credentials |
|---|---|---|
| Jenkins (classic UI) | <http://localhost:8080> | admin / admin |
| Jenkins Blue Ocean | <http://localhost:8080/blue> | admin / admin |
| SonarQube | <http://localhost:9000> | admin / DevSecOps!2026 |
| Prometheus | <http://localhost:9090> | — |
| Grafana | <http://localhost:3000> | admin / admin |
| ZAP daemon (API UI) | <http://localhost:8090> | — |
| **Production app (VM)** | <http://localhost:8888> | — (also `http://<VM-IP>:8080`; run `multipass info prod-server` for the IP) |

---

## 5. What the automation does, step by step (assignment mapping)

Every numbered assignment requirement is satisfied automatically. The
`docker run` commands and every configuration file are inside `setup.ps1`
(clearly labeled STEP 0–10 sections); the generated copies land in
`.\devsecops\` and in your fork.

1. **Fork + clone** — you fork once in the GitHub UI; `setup.ps1` clones the
   fork to `.\devsecops\app`, injects `Jenkinsfile`, `Dockerfile` and
   `ansible/`, commits and pushes (STEP 9).
2. **Custom Docker network** — `docker network create devsecops-net` (STEP 3);
   every service container joins it, so containers resolve each other by name
   (`sonarqube`, `jenkins`, `petclinic-staging`, …).
3. **Jenkins in Docker** — custom image built from `devsecops\jenkins\Dockerfile`
   on top of `jenkins/jenkins:lts-jdk21`, adding Ansible, the Docker CLI, all
   plugins from `plugins.txt`, and the JCasC file (STEP 10). Runs with the
   Docker socket mounted so pipeline stages can build/run containers.
4. **SonarQube in Docker** — `sonarqube:community` with persistent volumes
   (STEP 4). The script waits for status **UP**, changes the default admin
   password, generates an analysis token and creates the
   `http://jenkins:8080/sonarqube-webhook/` quality-gate webhook via the REST
   API — the token flows into Jenkins credentials through JCasC.
5. **Prometheus in Docker** — `prom/prometheus` with `prometheus.yml`
   scraping `jenkins:8080/prometheus/` every 15 s (STEP 8).
6. **Grafana in Docker** — `grafana/grafana` with an auto-provisioned
   Prometheus datasource and **two dashboards**: a custom overview plus the
   community "Jenkins Performance and Health" dashboard (grafana.com #9964),
   downloaded and wired to the datasource automatically (STEP 8).
7. **ZAP in Docker** — a persistent `zaproxy/zap-stable` daemon on the network
   (STEP 8) for inspection/screenshots; each build additionally runs an
   ephemeral `zap-baseline.py` scan container against the staging deployment.
8. **Jenkins pipeline from the fork** — the `petclinic-devsecops` pipeline job
   is created by Job DSL inside the JCasC file, pointing at your fork's
   `Jenkinsfile` on `main`; `queue()` starts build #1 at boot.
9. **SCM polling trigger** — `pollSCM('H/2 * * * *')` in the Jenkinsfile
   (registered after the first run): Jenkins polls the repo every ~2 minutes.
10. **Build steps** — `./mvnw -B clean package` with unit tests; JUnit results
    are published to Jenkins (Testcontainers-dependent `*IntegrationTests`
    are excluded so the build is self-contained).
11. **SonarQube static analysis** — `withSonarQubeEnv('SonarQube')` +
    `sonar-maven-plugin`; results appear on the SonarQube project dashboard.
    **Blue Ocean** is preinstalled — open `/blue` to visualize the build.
12. **ZAP execution + published report** — the baseline (passive/spider) scan
    targets `http://petclinic-staging:8080`; the HTML report is copied out of
    the scan container and published as a post-build action via the **HTML
    Publisher** plugin — the **"ZAP Security Report"** link on the job page.
13. **Prometheus plugin in Jenkins** — preinstalled via `plugins.txt`; its
    metrics endpoint (`/prometheus/`) is what Prometheus scrapes.
14. **Grafana ← Prometheus ← Jenkins** — datasource and dashboards provision
    themselves; open Grafana → Dashboards after the first couple of builds.
15. **Production VM** — `multipass launch prod-server` (Ubuntu LTS, 2 vCPU /
    2 GB) in STEP 6; the Jenkins SSH public key is authorized for `ubuntu@`.
16. **Ansible deployment from the Jenkins server** — Ansible is installed in
    the Jenkins image; the pipeline runs `ansible-playbook ansible/deploy.yml`,
    which installs Java on the VM, copies the freshly built jar and
    (re)starts a `petclinic` systemd service. Connectivity:
    `host.docker.internal:2222 → VM:22`.
17. **Welcome screen on the VM** — final pipeline stage smoke-tests the
    production URL; open <http://localhost:8888> yourself for the screenshot.
18. **Code change → automatic build/test/deploy** — `demo-change.ps1` updates
    the welcome message with a timestamp and pushes; polling triggers the next
    build, and the visible change proves the new version was deployed.

---

## 6. Pipeline stages (what each does)

| Stage | Tool | Outcome |
|---|---|---|
| Checkout | Git | Pulls your fork's `main`. |
| Build & Unit Tests | Maven wrapper | `clean package` + unit tests; JUnit report published. |
| SonarQube Analysis | sonar-maven-plugin | SAST results pushed to the SonarQube server (token + URL injected by `withSonarQubeEnv`). |
| Build Docker Image | Docker | `petclinic:<BUILD_NUMBER>` from the repo `Dockerfile`. |
| Deploy to Staging | Docker | Runs the image on `devsecops-net`; waits until HTTP 200. |
| ZAP Security Scan | zap-baseline.py | DAST against staging; `zap-report.html` published in Jenkins. |
| Deploy to Production | Ansible → VM | Jar copied over SSH; systemd service restarted. |
| Production Smoke Test | curl | Fails the build if the VM app doesn't answer. |

---

## 7. Screenshot checklist (matches the 20-point rubric)

1. **Production welcome screen**: <http://localhost:8888> — bonus credibility:
   put a terminal with `multipass info prod-server` beside the browser to show
   it's served from the VM.
2. **Jenkins**: job page with Stage View; **Blue Ocean** run view (`/blue`);
   *Manage Jenkins → System* → "SonarQube servers" section; *Plugins* page
   filtered for "prometheus" (proves the plugin is installed).
3. **SonarQube**: the `spring-petclinic` project dashboard (bugs, code smells,
   coverage) at <http://localhost:9000>.
4. **Prometheus**: *Status → Targets* showing the `jenkins` job **UP**; a graph
   of `default_jenkins_builds_last_build_duration_milliseconds`.
5. **Grafana**: both provisioned Jenkins dashboards with live data.
6. **ZAP**: the "ZAP Security Report" link + rendered HTML report in a Jenkins
   build; <http://localhost:8090> for the running daemon.
7. **Change evidence** (before/after): (a) welcome page *before*; (b)
   `demo-change.ps1` output and the commit on GitHub; (c) the new Jenkins build
   whose cause reads **"Started by an SCM change"**; (d) welcome page *after*,
   showing the timestamped message — the deployed version is visibly different.

## 8. Demo video shot list (~60–90 s)

1. Terminal: run `demo-change.ps1`; show the commit landing on GitHub.
2. Blue Ocean: the build starts by itself (cause: SCM change); stages go green
   one by one — point out SonarQube, ZAP and Ansible stages.
3. SonarQube dashboard: new analysis timestamp.
4. Jenkins build page: open the ZAP Security Report.
5. Refresh <http://localhost:8888>: the updated welcome text.
6. Prometheus target UP → Grafana dashboard reflecting the new build metrics.

---

## 9. Re-running, reboots, idempotency

`setup.ps1` is **safe to re-run**: containers are recreated, while data volumes
(Jenkins config/history, SonarQube analyses), the VM and your cloned fork are
reused. **After a host reboot the VM may receive a new IP — simply re-run
`setup.ps1`**; it re-reads the IP and refreshes the port proxies.

## 10. Troubleshooting

| Symptom | Fix |
|---|---|
| "Docker Desktop is not running" | Start Docker Desktop, wait for the whale icon to settle, re-run. |
| A port is busy (8080/9000/9090/3000/8090/8888/2222) | Free it (`netstat -ano \| findstr :8080`) or edit the port in `setup.ps1`. |
| SonarQube never reaches UP | `docker logs sonarqube`; give Docker ≥ 6–8 GB RAM (Docker Desktop → Settings → Resources, or `%UserProfile%\.wslconfig`). |
| `git push` fails | `cd .\devsecops\app; git push` once and finish the browser sign-in, then re-run the script. |
| First build fails at the Ansible stage | Verify the SSH path: `docker exec jenkins ssh -i /root/.ssh/id_rsa -p 2222 -o StrictHostKeyChecking=no ubuntu@host.docker.internal hostname` should print `prod-server`. If the VM IP changed (reboot), re-run `setup.ps1`, then *Rebuild* in Jenkins. |
| Multipass on Windows 11 Home | Install VirtualBox, then `multipass set local.driver=virtualbox`. |
| Future **Java** code changes fail the build with formatting violations | PetClinic enforces `spring-javaformat` on `.java` sources. Run `./mvnw spring-javaformat:apply` before committing Java edits. (The demo script edits a resources file precisely to avoid this.) |
| `multipass launch` times out / VM shows `Running` with `IPv4: N/A` forever, VBoxHeadless pegs a CPU core | VirtualBox 7.2.x deadlocking on UEFI boot — see the two VirtualBox-driver bullets in section 2 (Windows Hypervisor Platform + 1 vCPU). Kill the stuck VM first: `multipass delete prod-server; multipass purge`, then re-run `setup.ps1`. |
| VM has an IP but `netsh portproxy` still can't reach it (`localhost:2222`/`:8888` refuse or time out even from the host itself) | The **IP Helper service** isn't running — `netsh portproxy` rules are inert without it. `Start-Service iphlpsvc; Set-Service iphlpsvc -StartupType Automatic`. |
| Maven build fails instantly at `validate` with `NoHttp: http:// URLs are not allowed` | PetClinic's `nohttp-checkstyle` rule scans the **entire repo**, including `devops/`, `Jenkinsfile` and `ansible/`, which legitimately reference `http://localhost`/`http://host.docker.internal`. Exclude them in `pom.xml`'s `nohttp-checkstyle-validation` execution: add `**/devops/**/*,**/Jenkinsfile,**/ansible/**/*` to the plugin's `<excludes>`. |
| Ansible/Ansible-deploy stage fails with `ssh: connect to host host.docker.internal port 2222: Network is unreachable` (or `Connection refused` even though SSH works fine) | `host.docker.internal` resolves to **both** an IPv6 and IPv4 address inside the Jenkins container, but the `netsh portproxy` bridges are IPv4-only. Force IPv4: add `-4` to `ansible_ssh_common_args` in `ansible/inventory.ini` and to the `curl` call in the Jenkinsfile's Production Smoke Test stage. If it's `Connection refused` rather than `unreachable`, that's the IP Helper issue above, not this one. |
| First pipeline build never starts even though the job exists (`lastBuild` 404s, queue is empty) | Jenkins reloads a **persisted** build queue from `JENKINS_HOME` on container start, which can race with and discard the Job DSL's boot-time `queue()` call (`Loading queue will discard previously scheduled items` in `docker logs jenkins`). This mainly bites re-runs where the Jenkins volume already existed. Trigger it manually: get a CSRF crumb and POST to build, e.g. `curl -c cj.txt -u admin:admin http://localhost:8080/crumbIssuer/api/json` then `curl -b cj.txt -u admin:admin -H "Jenkins-Crumb: <crumb>" -X POST http://localhost:8080/job/petclinic-devsecops/build` (or just click *Build Now* in the UI). |
| First production deploy's smoke test times out even though Ansible succeeded | The VM only has 1 vCPU (see section 2), so Spring Boot's first cold start (Hibernate/JPA init) can take longer than the smoke test's 180 s budget. Check `multipass exec prod-server -- journalctl -u petclinic -f` — if it's still initializing, just re-run the build once the app has finished starting; subsequent starts are faster. |
| Grafana plugin-metric panels empty right after setup | Metrics appear after the first builds complete; the `up{job="jenkins"}` panel is populated immediately. |

## 11. Teardown

```powershell
# containers + network + proxies (keeps data, VM, fork):
powershell -ExecutionPolicy Bypass -File .\teardown.ps1

# full wipe:
powershell -ExecutionPolicy Bypass -File .\teardown.ps1 -RemoveVolumes -RemoveVm
```

---

## 12. File inventory (submission checklist)

**This kit (provisioning scripts):**

| File | Purpose |
|---|---|
| `setup.ps1` | End-to-end provisioning: all `docker run` commands, SonarQube API bootstrap, VM creation, networking, fork injection, Jenkins boot. |
| `demo-change.ps1` | Pushes the visible code change for the trigger/redeploy evidence. |
| `teardown.ps1` | Clean removal. |
| `README.md` | This document (the step-by-step instructions deliverable). |

**Generated by `setup.ps1` into `.\devsecops\` (config-file deliverables):**

| File | Purpose |
|---|---|
| `jenkins\Dockerfile` | Custom Jenkins image (Ansible, Docker CLI, plugins, JCasC). |
| `jenkins\plugins.txt` | Blue Ocean, SonarQube Scanner, Prometheus, HTML Publisher, Job DSL, JCasC, Git/GitHub, Docker Pipeline, JUnit. |
| `jenkins\casc.yaml` | Jenkins Configuration-as-Code: security, SonarQube server, credential, the pipeline job (Job DSL) + `queue()`. |
| `prometheus\prometheus.yml` | Scrape config for Jenkins metrics. |
| `grafana\provisioning\*`, `grafana\dashboards\*` | Datasource + dashboard provisioning (custom + community #9964). |

**Committed into your fork by `setup.ps1`:**

| File | Purpose |
|---|---|
| `Jenkinsfile` | The declarative pipeline (all stages above, `pollSCM` trigger, ZAP report publishing). |
| `Dockerfile` | App image (`eclipse-temurin:21-jre` + the built jar). |
| `ansible\inventory.ini` | Production host via `host.docker.internal:2222`. |
| `ansible\deploy.yml` | Java install, jar copy, systemd service on the VM. |

## 13. Security notes (lab conveniences — do not reuse in real environments)

`admin/admin` credentials, a root Jenkins with the Docker socket mounted, a
disabled ZAP API key, relaxed Jenkins CSP (so the ZAP report renders styled)
and `StrictHostKeyChecking=no` are deliberate lab-only simplifications. Nothing
here is exposed beyond localhost/your machine, but change credentials before
showing the environment anywhere shared.

## 14. Honest note on "first-time success"

Every step has health checks, retries and explicit failure messages, and the
riskiest integrations (Elasticsearch limits, container→VM networking, the
Jenkins setup wizard, SonarQube token bootstrap, Windows line endings) are
engineered around. No script can *guarantee* perfection on arbitrary machines
— network hiccups, port conflicts and antivirus interference exist — which is
what the troubleshooting table is for. On a standard Windows 11 + Docker
Desktop + Multipass box, this runs end-to-end unattended.
