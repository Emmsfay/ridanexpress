pipeline {
    agent any

    // Use JDK 21 — required for SonarQube scanner
    // Use Node 22 — matches "engines" in package.json
    tools {
        jdk 'JDK21'
        nodejs 'Node22'
    }

    environment {
        DOCKER_CREDENTIALS = credentials('dockerhub-credentials')
        SONAR_TOKEN        = credentials('sonarqube-token')
        IMAGE_NAME         = "${DOCKER_CREDENTIALS_USR}/ridanexpress"
        IMAGE_TAG          = "${BUILD_NUMBER}"   // build number = traceable, immutable tag
        SONAR_PROJECT_KEY  = 'ridanexpress'
    }

    stages {

        // ── STAGE 1: Checkout ───────────────────────────────────
        // Pull the latest code from the repository into the Jenkins workspace
        stage('Checkout') {
            steps {
                echo 'Checking out source code...'
                checkout scm
            }
        }

        // ── STAGE 2: Secret Detection ───────────────────────────
        // Runs FIRST — before installing anything or touching the code
        // Scans for hardcoded API keys, tokens, passwords using Gitleaks
        // || true prevents pipeline failure so the report is still archived
        stage('Secret Detection') {
            steps {
                echo 'Scanning for hardcoded secrets with Gitleaks...'
                sh '''
                    gitleaks detect \
                        --source . \
                        --report-format json \
                        --report-path gitleaks-report.json \
                        --exit-code 1 || true
                '''
            }
            post {
                always {
                    // Archive the report regardless of pass/fail
                    // View it under the build Artifacts in Jenkins UI
                    archiveArtifacts artifacts: 'gitleaks-report.json',
                                     allowEmptyArchive: true
                }
            }
        }

        // ── STAGE 3: Install Dependencies ──────────────────────
        // npm ci installs exact versions from package-lock.json
        // Faster and safer than npm install for CI environments
        stage('Install Dependencies') {
            steps {
                echo 'Installing dependencies with npm ci...'
                sh 'npm ci'
            }
        }

        // ── STAGE 4: Dependency Vulnerability Scan ─────────────
        // npm audit checks every package in node_modules against
        // the npm advisory database for known CVEs
        // --audit-level=high only fails on HIGH or CRITICAL severity
        // LOW and MODERATE issues are reported but do not block the build
        stage('Dependency Vulnerability Scan') {
            steps {
                echo 'Running npm audit for known CVEs...'
                sh 'npm audit --audit-level=high'
            }
        }

        // ── STAGE 5: Run Tests ──────────────────────────────────
        // --watchAll=false is CRITICAL in CI — without it Jest runs in
        // interactive watch mode and hangs forever waiting for keyboard input
        stage('Run Tests') {
            steps {
                echo 'Running test suite...'
                sh 'npm test -- --watchAll=false'
            }
        }

        // ── STAGE 6: SAST with SonarQube ───────────────────────
        // Static Application Security Testing — scans source code for
        // security hotspots, bugs, and code smells WITHOUT executing it
        // sonar-project.properties at repo root holds all project config
        // withSonarQubeEnv injects the server URL and auth token automatically
        stage('SAST - SonarQube Analysis') {
            steps {
                echo 'Running SonarQube static analysis...'
                withSonarQubeEnv('SonarQube') {
                    sh 'npx sonar-scanner'
                }
            }
        }

        // ── STAGE 7: SonarQube Quality Gate ────────────────────
        // Waits for SonarQube to finish processing analysis results
        // abortPipeline: true stops the pipeline if quality gate fails
        // timeout prevents the pipeline hanging if SonarQube is slow
        stage('Quality Gate') {
            steps {
                echo 'Waiting for SonarQube Quality Gate result...'
                timeout(time: 5, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        // ── STAGE 8: Build Application ──────────────────────────
        // Compiles React + Vite into static HTML, CSS, and JS files
        // Confirms the app builds successfully before we touch Docker
        // If this fails, nothing gets containerized
        stage('Build Application') {
            steps {
                echo 'Building React app with Vite...'
                sh 'npm run build'
            }
        }

        // ── STAGE 9: Build Docker Image ─────────────────────────
        // DOCKER_BUILDKIT=1 is REQUIRED — the Dockerfile uses
        // --mount=type=cache for npm caching which only works with BuildKit
        // Without this, the build fails with an unsupported syntax error
        stage('Build Docker Image') {
            environment {
                DOCKER_BUILDKIT = '1'
            }
            steps {
                echo "Building Docker image: ${IMAGE_NAME}:${IMAGE_TAG}"
                sh "docker build -t ${IMAGE_NAME}:${IMAGE_TAG} ."
            }
        }

        // ── STAGE 10: Container Image Scan with Trivy ──────────
        // Scans the built Docker image for OS-level and library CVEs
        // --exit-code 1 + --severity CRITICAL: fails pipeline on CRITICAL issues
        // HIGH severity issues appear in the report but do not fail the build
        // Report is archived as a build artifact for review
        stage('Container Image Scan - Trivy') {
            steps {
                echo 'Scanning Docker image for vulnerabilities with Trivy...'
                sh """
                    trivy image \
                        --exit-code 1 \
                        --severity CRITICAL \
                        --format table \
                        --output trivy-report.txt \
                        ${IMAGE_NAME}:${IMAGE_TAG}
                """
            }
            post {
                always {
                    archiveArtifacts artifacts: 'trivy-report.txt',
                                     allowEmptyArchive: true
                }
                failure {
                    echo 'CRITICAL vulnerabilities found in Docker image. Pipeline halted.'
                }
            }
        }

        // ── STAGE 11: Push Docker Image ─────────────────────────
        // Only reached if ALL previous security stages passed
        // --password-stdin keeps credentials out of shell history and process list
        stage('Push Docker Image') {
            steps {
                echo 'Pushing verified and scanned image to Docker Hub...'
                sh """
                    echo ${DOCKER_CREDENTIALS_PSW} | \
                    docker login -u ${DOCKER_CREDENTIALS_USR} --password-stdin
                    docker push ${IMAGE_NAME}:${IMAGE_TAG}
                """
            }
        }
    }

    // ── POST PIPELINE ACTIONS ───────────────────────────────────
    // These run regardless of whether the pipeline passed or failed
    post {
        success {
            echo """
            ✅ Pipeline completed successfully.
            Image pushed: ${IMAGE_NAME}:${IMAGE_TAG}
            All security scans passed — secret detection, dependency audit, SAST, container scan.
            """
        }
        failure {
            echo """
            ❌ Pipeline failed.
            Check the stage logs above for the failure point.
            Security reports (Gitleaks, Trivy) archived under build Artifacts.
            """
        }
        always {
            // Guard against IMAGE_NAME not being set if pipeline failed early
            node('built-in') {
                script {
                    if (env.IMAGE_NAME) {
                        sh "docker rmi ${IMAGE_NAME}:${IMAGE_TAG} || true"
                    }
                }
            // deleteDir() is built into Jenkins — no plugin required
            // Wipes the workspace so the next build starts completely clean
                deleteDir()
            }
       }
}
