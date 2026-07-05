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
                        if curl -4 -sf -o /dev/null http://host.docker.internal:8888; then
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
