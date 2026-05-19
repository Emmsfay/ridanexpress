pipeline {
    agent any

    environment {
        DOCKER_CREDENTIALS = credentials('dockerhub-credentials')
        SONAR_TOKEN        = credentials('sonarqube-token')
        IMAGE_NAME         = "${DOCKER_CREDENTIALS_USR}/ridanexpress"
        IMAGE_TAG          = "${BUILD_NUMBER}"
        SONAR_PROJECT_KEY  = 'ridanexpress'
    }

    stages {

        stage('Checkout') {
            steps {
                echo 'Checking out source code...'
                checkout scm
            }
        }

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
                    archiveArtifacts artifacts: 'gitleaks-report.json',
                                     allowEmptyArchive: true
                }
            }
        }

        stage('Install Dependencies') {
            steps {
                echo 'Installing dependencies with npm ci...'

                sh '''
                    export NVM_DIR="$HOME/.nvm"

                    if [ -s "$NVM_DIR/nvm.sh" ]; then
                        . "$NVM_DIR/nvm.sh"

                        nvm use 24 || nvm install 24

                        echo "Using node from: $(which node)"
                        node -v
                        npm -v

                        npm ci
                    else
                        echo "NVM not found"
                        exit 1
                    fi
                '''
            }
        }

        stage('Dependency Vulnerability Scan') {
            steps {
                echo 'Running npm audit for known CVEs...'

                sh '''
                    npm audit --audit-level=high || {
                        echo "Security vulnerabilities found"
                        exit 1
                    }
                '''
            }
        }

        stage('Run Tests') {
            steps {
                echo 'Running test suite...'
                sh 'npm test -- --watchAll=false || exit 1'
            }
        }

        stage('SAST - SonarQube Analysis') {
            agent { docker { image 'sonarsource/sonar-scanner-cli:latest' } }
            steps {
                echo 'Running SonarQube static analysis...'
                withSonarQubeEnv('SonarQube') {
                    sh 'sonar-scanner'
                }
            }
        }

        stage('Quality Gate') {
            steps {
                echo 'Waiting for SonarQube Quality Gate result...'
                timeout(time: 5, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }

        stage('Build Application') {
            steps {
                echo 'Building React app with Vite...'
                sh 'npm run build'
            }
        }

        stage('Build Docker Image') {
            environment {
                DOCKER_BUILDKIT = '1'
            }
            steps {
                echo "Building Docker image: ${IMAGE_NAME}:${IMAGE_TAG}"
                sh "docker build -t ${IMAGE_NAME}:${IMAGE_TAG} ."
            }
        }

        stage('Container Image Scan - Trivy') {
            steps {
                echo 'Scanning Docker image for vulnerabilities with Trivy...'
                sh '''
                    trivy image \
                        --exit-code 1 \
                        --severity HIGH,CRITICAL \
                        --format table \
                        --output trivy-report.txt \
                        ${IMAGE_NAME}:${IMAGE_TAG}
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'trivy-report.txt',
                                     allowEmptyArchive: true
                }
                failure {
                    echo 'Vulnerabilities found in Docker image.'
                }
            }
        }

        stage('Push Docker Image') {
            steps {
                echo 'Pushing verified image to Docker Hub...'
                sh '''
                    echo ${DOCKER_CREDENTIALS_PSW} | \
                    docker login -u ${DOCKER_CREDENTIALS_USR} --password-stdin

                    docker push ${IMAGE_NAME}:${IMAGE_TAG}
                '''
            }
        }
    }

    post {
        success {
            echo '✅ Pipeline completed successfully. Image pushed.'
        }
        failure {
            echo '❌ Pipeline failed. Check logs and reports.'
        }
        always {
            sh "docker rmi ${IMAGE_NAME}:${IMAGE_TAG} || true"
            deleteDir()
        }
    }
}
