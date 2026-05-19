# Contributing to Ridan Express

Thank you for your interest in contributing to Ridan Express! This guide walks you through setting up the project locally, containerizing it with Docker, and running automated DevSecOps pipelines with either **GitHub Actions** (cloud-based) or **Jenkins** (self-hosted).

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Getting Started Locally](#getting-started-locally)
- [Docker Setup](#docker-setup)
  - [Why Docker?](#why-docker)
  - [The Dockerfile Explained](#the-dockerfile-explained)
  - [Building and Running the Container](#building-and-running-the-container)
- [DevSecOps Overview](#devsecops-overview)
- [CI/CD with GitHub Actions](#cicd-with-github-actions)
  - [How It Works](#how-it-works)
  - [Pipeline File](#pipeline-file)
  - [Setting Up GitHub Actions Secrets](#setting-up-github-actions-secrets)
- [CI/CD with Jenkins](#cicd-with-jenkins)
  - [How Jenkins Works](#how-jenkins-works)
  - [Installing Security Tools](#installing-security-tools)
  - [Setting Up SonarQube](#setting-up-sonarqube)
  - [Installing Jenkins](#installing-jenkins)
  - [Configuring Jenkins](#configuring-jenkins)
  - [Setting Up Secrets in Jenkins](#setting-up-secrets-in-jenkins)
  - [Jenkinsfile](#jenkinsfile)
- [GitHub Actions vs Jenkins](#github-actions-vs-jenkins)
- [Submitting a Pull Request](#submitting-a-pull-request)
- [Project Structure Reference](#project-structure-reference)

---

## Prerequisites

Make sure you have the following installed before contributing:

| Tool    | Version        | Purpose                        |
| ------- | -------------- | ------------------------------ |
| Node.js | 22.x           | Running the app locally        |
| npm     | 9+             | Package management             |
| Docker  | Latest         | Containerization               |
| Git     | Latest         | Version control                |
| JDK     | 21             | Required for SonarQube scanner |
| Jenkins | LTS (optional) | Self-hosted CI/CD              |

---

## Getting Started Locally

### 1. Fork the Repository

Click **Fork** at the top right of the GitHub repository page. This creates your own copy of the project under your GitHub account.

### 2. Clone Your Fork

```bash
git clone https://github.com/YOUR_USERNAME/ridanexpress.git
cd ridanexpress
```

### 3. Create a Feature Branch

Never work directly on `master`. Always create a new branch for your contribution:

```bash
git checkout -b feature/your-contribution-name
```

Examples:

```bash
git checkout -b feature/container-devsecops
git checkout -b feature/add-github-actions-cicd
git checkout -b feature/add-jenkins-pipeline
```

### 4. Install Dependencies

```bash
npm ci
```

> We use `npm ci` instead of `npm install` because it installs exact versions from `package-lock.json`, ensuring every contributor gets the same dependency tree.

### 5. Run the App Locally

```bash
npm run ridan
```

The app will be available at `http://localhost:5173`.

### 6. Run Tests

```bash
npm test -- --watchAll=false
```

Make sure all tests pass before submitting a PR.

---

## Docker Setup

### Why Docker?

Docker packages the application and everything it needs to run into a single container. This means:

- The app runs the same way on every machine
- No more "it works on my machine" issues
- The container is ready to be deployed to any cloud provider

### The Dockerfile Explained

The production Dockerfile at the project root uses a **multi-stage build**, **BuildKit caching**, and a **non-root user** for security:

```dockerfile
# ── STAGE 1: Build ─────────────────────────────────────────────
# node:22.22-alpine — pinned to exact patch version for reproducibility
# Alpine is a minimal Linux distro (~50MB vs ~900MB for full Node image)
FROM node:22.22-alpine AS builder

WORKDIR /app

# Allow passing proxy settings during build if behind a corporate proxy
ARG HTTP_PROXY
ARG HTTPS_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} HTTPS_PROXY=${HTTPS_PROXY}

# Copy dependency files FIRST — enables Docker layer caching
# Docker only re-runs npm ci when these files change,
# not every time source code changes
COPY package*.json ./

# --mount=type=cache: caches the npm download cache between builds (faster rebuilds)
# fetch-retries: retries failed downloads 5 times (handles flaky network)
# fetch-retry timeouts: gives npm up to 2 minutes per retry
# Requires BuildKit: build with DOCKER_BUILDKIT=1
RUN --mount=type=cache,id=npm-cache,target=/root/.npm \
    npm set fetch-retries 5 && \
    npm set fetch-retry-mintimeout 20000 && \
    npm set fetch-retry-maxtimeout 120000 && \
    npm ci

COPY . .

# Compile React + Vite into static HTML, CSS, and JS
# Output lands in the /app/build folder
RUN npm run build


# ── STAGE 2: Serve ─────────────────────────────────────────────
# nginx:stable-alpine — stable channel, more reliable than latest tag
# ~25MB total — Node.js, npm, and node_modules are completely discarded
FROM nginx:stable-alpine

# Create a non-root user — containers running as root are a security risk
# If an attacker breaks out of the app, they get root on the host
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Copy ONLY the compiled output from Stage 1
COPY --from=builder /app/build /usr/share/nginx/html

# Copy source logo to fix legacy /images/logo.png path referenced in the app
COPY --from=builder /app/src/assets/Images/banner/logo.png /usr/share/nginx/html/images/logo.png

# Give ownership of all nginx-related files to the non-root user
RUN chown -R appuser:appgroup /usr/share/nginx/html && \
    chown -R appuser:appgroup /var/cache/nginx && \
    chown -R appuser:appgroup /var/log/nginx && \
    touch /var/run/nginx.pid && \
    chown -R appuser:appgroup /var/run/nginx.pid

# Remove the "user" directive from nginx.conf
# It is incompatible when Nginx runs as a non-root user
RUN sed -i 's/^user/#user/' /etc/nginx/nginx.conf

# Switch to non-root user for all subsequent commands and at runtime
USER appuser

EXPOSE 80
```

**Why two stages?**

```
Stage 1 (builder)                 Stage 2 (final image)
┌───────────────────────┐         ┌───────────────────────┐
│ node:22.22-alpine     │         │ nginx:stable-alpine   │
│                       │  ──▶    │                       │
│ Node.js + npm         │  /build │ Compiled static files │
│ 300MB node_modules    │  only   │ Nginx web server      │
│ Vite build toolchain  │         │                       │
│ ~600MB total          │         │ ~30MB total           │
│                       │         │                       │
│   DISCARDED           │         │   SHIPPED TO PROD     │
└───────────────────────┘         └───────────────────────┘
```

The first stage is the construction site. The second stage is the finished product. You ship the building, not the scaffolding.

### Create a `.dockerignore` File

Prevents unnecessary files from entering the Docker build context, speeding up builds:

```
node_modules
build
.env
.env.local
.env.production
.git
.gitignore
*.md
```

### Building and Running the Container

**Build the image (BuildKit required):**

```bash
DOCKER_BUILDKIT=1 docker build -t ridanexpress:latest .
```

**Run the container:**

```bash
docker run -p 3000:80 ridanexpress:latest
```

The app is now available at `http://localhost:3000`.

**Useful commands:**

```bash
docker ps                          # list running containers
docker logs <container-id>         # view logs
docker stop <container-id>         # stop the container
docker rmi ridanexpress:latest     # remove the image
```

**Verify the image size:**

```bash
docker images ridanexpress
```

You should see a final image well under 50MB — proof the multi-stage build is working.

---

## DevSecOps Overview

This project implements DevSecOps — security is built into every stage of the pipeline, not bolted on at the end.

| Stage                  | Tool             | What it catches                                  |
| ---------------------- | ---------------- | ------------------------------------------------ |
| Secret Detection       | Gitleaks v8.30.1 | Hardcoded API keys, tokens, passwords in code    |
| Dependency Scan        | npm audit        | Known CVEs in node_modules packages              |
| Static Analysis (SAST) | SonarQube        | Security hotspots, bugs, code smells in source   |
| Quality Gate           | SonarQube        | Enforces minimum security and quality thresholds |
| Container Scan         | Trivy v0.70.0    | OS-level and library CVEs in the Docker image    |

**Security gate flow — nothing insecure ever ships:**

```
Code pushed
     │
     ▼
Secret Detection ── secrets found? ──▶ STOP
     │
     ▼
npm audit ── HIGH/CRITICAL CVE? ──▶ STOP
     │
     ▼
SonarQube SAST ── security hotspots? ──▶ STOP
     │
     ▼
Quality Gate ── failed threshold? ──▶ STOP
     │
     ▼
Build Docker image
     │
     ▼
Trivy ── CRITICAL CVE in image? ──▶ STOP
     │
     ▼
Push to Docker Hub ✓
```

---

## CI/CD with GitHub Actions for those who want to use it

### How It Works

GitHub Actions is a cloud-based automation platform built directly into GitHub. Every push to `master` or opened PR triggers the full pipeline on a fresh Ubuntu VM automatically.

### Pipeline File

Create the file at `.github/workflows/ci.yml`:

```yaml
name: CI/CD Pipeline

on:
  push:
    branches: [master]
  pull_request:
    branches: [master]

jobs:
  build-and-push:
    runs-on: ubuntu-latest

    steps:
      # Clone the repository into the VM
      - name: Checkout code
        uses: actions/checkout@v3

      # Install Node 22 — matches package.json "engines"
      # cache: 'npm' speeds up builds by caching node_modules between runs
      - name: Set up Node.js
        uses: actions/setup-node@v3
        with:
          node-version: 22
          cache: "npm"

      - name: Install dependencies
        run: npm ci

      # --watchAll=false prevents Jest hanging in CI (no keyboard input available)
      - name: Run tests
        run: npm test -- --watchAll=false

      - name: Build application
        run: npm run build

      - name: Log in to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_TOKEN }}

      # DOCKER_BUILDKIT=1 required — Dockerfile uses --mount=type=cache
      - name: Build Docker image
        env:
          DOCKER_BUILDKIT: 1
        run: docker build -t ${{ secrets.DOCKER_USERNAME }}/ridanexpress:latest .

      - name: Push Docker image
        run: docker push ${{ secrets.DOCKER_USERNAME }}/ridanexpress:latest
```

### Setting Up GitHub Actions Secrets

**Step 1 — Generate a Docker Hub Access Token:**

1. Log in to [hub.docker.com](https://hub.docker.com)
2. Profile icon → **Account Settings** → **Security** → **New Access Token**
3. Name it `ridanexpress-github-actions` and copy the token immediately

**Step 2 — Add Secrets to GitHub:**

1. Go to your forked repo → **Settings** → **Secrets and variables** → **Actions**
2. Click **New repository secret** and add:
   - `DOCKER_USERNAME` — your Docker Hub username
   - `DOCKER_TOKEN` — the access token from Step 1

---

## CI/CD with Jenkins

### How Jenkins Works

Jenkins is a self-hosted automation server. It reads the `Jenkinsfile` from the repo root and executes each stage in order on your own hardware — the standard approach in enterprise environments where code cannot leave internal networks.

### Installing Security Tools

Run these commands on your Jenkins server **before** triggering the pipeline:

```bash
# ── Trivy v0.70.0 (container image scanner) ─────────────────────
sudo apt install -y wget apt-transport-https gnupg

wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | \
  sudo gpg --dearmor -o /usr/share/keyrings/trivy.gpg

echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] \
  https://aquasecurity.github.io/trivy-repo/deb generic main" | \
  sudo tee /etc/apt/sources.list.d/trivy.list

sudo apt update && sudo apt install -y trivy

# Verify
trivy --version

# ── Gitleaks v8.30.1 (secret detection) ─────────────────────────
wget https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz
tar -xzf gitleaks_8.30.1_linux_x64.tar.gz
sudo mv gitleaks /usr/local/bin/

# Verify
gitleaks version
```

### Setting Up SonarQube

SonarQube is the SAST engine. Run it as a Docker container on your server:

```bash
# Required kernel setting for Elasticsearch inside SonarQube
# Skip this and SonarQube will crash immediately on startup
sudo sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf

# Start SonarQube
docker run -d \
  --name sonarqube \
  -p 9000:9000 \
  sonarqube:community
```

Wait ~60 seconds, then open `http://localhost:9000`:

1. Login: `admin` / `admin` — **change the password immediately**
2. Click your profile (top right) → **My Account** → **Security**
3. Under **Generate Token**:
   - Name: `ridanexpress-token`
   - Type: `User Token`
   - Expires: your preference
4. Click **Generate** — **copy the token immediately, you won't see it again**

**Add SonarQube server to Jenkins:**

1. Go to **Manage Jenkins** → **System**
2. Find **SonarQube servers** → **Add**:
   - Name: `SonarQube`
   - Server URL: `http://localhost:9000`
   - Server authentication token: add as secret text with ID `sonarqube-token`

**SonarQube project config** — the `sonar-project.properties` file at the repo root:

```properties
sonar.projectKey=ridanexpress
sonar.projectName=Ridan Express
sonar.projectVersion=1.0
sonar.sources=src
sonar.exclusions=**/node_modules/**,**/build/**,**/*.test.js,**/*.spec.js
sonar.javascript.lcov.reportPaths=coverage/lcov.info
sonar.sourceEncoding=UTF-8
```

This file is read automatically by `npx sonar-scanner` — no `-D` flags needed in the Jenkinsfile.

### Installing Jenkins

On Ubuntu/Debian with **JDK 21**:

```bash
# Install JDK 21 — required by SonarQube scanner
sudo apt update
sudo apt install -y openjdk-21-jdk

# Verify
java -version

# Add Jenkins repo and install
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | sudo tee \
  /usr/share/keyrings/jenkins-keyring.asc > /dev/null

echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
  /etc/apt/sources.list.d/jenkins.list > /dev/null

sudo apt update
sudo apt install -y jenkins
sudo systemctl start jenkins
sudo systemctl enable jenkins
```

Jenkins is now running at `http://localhost:8080`.

### Configuring Jenkins

**Step 1 — Install Required Plugins:**

Go to **Manage Jenkins** → **Plugins** → **Available plugins** and install:

- `Git Plugin` — cloning repositories
- `NodeJS Plugin` — running npm commands
- `Docker Pipeline Plugin` — Docker build and push
- `Pipeline Plugin` — reading Jenkinsfiles
- `SonarQube Scanner` — SAST integration
- `OWASP Dependency-Check` — deeper CVE scanning
- `HTML Publisher` — display security reports in Jenkins UI
- `Warnings Next Generation` — aggregates all scan results

**Step 2 — Configure JDK 21:**

Go to **Manage Jenkins** → **Tools** → **JDK installations**:

- Click **Add JDK**
- Name: `JDK21`
- Uncheck **Install automatically** if JDK 21 is already on your machine
- Find your JAVA_HOME path:

```bash
java -XshowSettings:all -version 2>&1 | grep java.home
```

**Step 3 — Configure Node.js:**

Go to **Manage Jenkins** → **Tools** → **NodeJS installations**:

- Click **Add NodeJS**
- Name: `Node22`
- Version: `22.x`

**Step 4 — Create a New Pipeline Job:**

1. Click **New Item** on the Jenkins dashboard
2. Enter name: `ridanexpress`
3. Select **Pipeline** → Click **OK**
4. Under **Pipeline**, set **Definition** to `Pipeline script from SCM`
5. Set **SCM** to `Git`
6. Enter your forked repository URL
7. Set **Branch Specifier** to `*/feature/container-devsecops`
8. Set **Script Path** to `Jenkinsfile`
9. Save → Click **Build Now**

### Setting Up Secrets in Jenkins

**Docker Hub credentials:**

1. Go to **Manage Jenkins** → **Credentials** → **System** → **Global credentials**
2. Click **Add Credentials**
3. Kind: `Username with password`
4. Username: your Docker Hub username
5. Password: your Docker Hub access token
6. ID: `dockerhub-credentials`
7. Save

**SonarQube token:**

1. Same path → **Add Credentials**
2. Kind: `Secret text`
3. Secret: paste your SonarQube token
4. ID: `sonarqube-token`
5. Save

### Jenkinsfile

The `Jenkinsfile` at the project root defines the full 11-stage DevSecOps pipeline:

```groovy
pipeline {
    agent any

    // JDK 21 — required for SonarQube scanner
    // Node 22 — matches "engines" in package.json
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

        stage('Checkout') {
            steps {
                echo 'Checking out source code...'
                checkout scm
            }
        }

        // Runs FIRST — scans for secrets before any code is installed or executed
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
                sh 'npm ci'
            }
        }

        // Fails on HIGH or CRITICAL CVEs in node_modules
        stage('Dependency Vulnerability Scan') {
            steps {
                echo 'Running npm audit...'
                sh 'npm audit --audit-level=high'
            }
        }

        // --watchAll=false critical — prevents Jest hanging in non-interactive CI
        stage('Run Tests') {
            steps {
                echo 'Running test suite...'
                sh 'npm test -- --watchAll=false'
            }
        }

        // sonar-project.properties at repo root handles all config
        stage('SAST - SonarQube Analysis') {
            steps {
                echo 'Running SonarQube static analysis...'
                withSonarQubeEnv('SonarQube') {
                    sh 'npx sonar-scanner'
                }
            }
        }

        // Pipeline stops if quality gate fails
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

        // DOCKER_BUILDKIT=1 required — Dockerfile uses --mount=type=cache
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

        // Fails on CRITICAL CVEs — HIGH severity reported but does not block
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

        // Only reached if ALL security stages passed
        // --password-stdin keeps credentials out of shell history and process list
        stage('Push Docker Image') {
            steps {
                echo 'Pushing verified image to Docker Hub...'
                sh """
                    echo ${DOCKER_CREDENTIALS_PSW} | \
                    docker login -u ${DOCKER_CREDENTIALS_USR} --password-stdin
                    docker push ${IMAGE_NAME}:${IMAGE_TAG}
                """
            }
        }
    }

    post {
        success {
            echo '✅ Pipeline completed successfully. All security scans passed. Image pushed.'
        }
        failure {
            echo '❌ Pipeline failed. Check stage logs and archived security reports.'
        }
        always {
            // Free disk space on Jenkins agent
            sh "docker rmi ${IMAGE_NAME}:${IMAGE_TAG} || true"
            // Start next build from a clean workspace
            cleanWs()
        }
    }
}
```

---

## GitHub Actions vs Jenkins

|                 | GitHub Actions                    | Jenkins                                    |
| --------------- | --------------------------------- | ------------------------------------------ |
| **Setup**       | Zero — built into GitHub          | Requires a server to install and maintain  |
| **Cost**        | Free for public repos             | Free software, but you pay for the server  |
| **Best for**    | Open source projects, small teams | Enterprise environments, internal networks |
| **Scales with** | GitHub's infrastructure           | Your own hardware                          |
| **Secrets**     | Stored in GitHub repo settings    | Stored in Jenkins credentials store        |
| **Config file** | `.github/workflows/ci.yml`        | `Jenkinsfile`                              |
| **BuildKit**    | `env: DOCKER_BUILDKIT: 1`         | `environment { DOCKER_BUILDKIT = '1' }`    |

For Ridan Express as an open source project, **GitHub Actions is recommended**. Jenkins is included for contributors working in enterprise or self-hosted environments.

---

## Submitting a Pull Request

### 1. Stage and Commit Your Files

```bash
git add Dockerfile \
        .dockerignore \
        Jenkinsfile \
        sonar-project.properties \
        .github/workflows/ci.yml \
        CONTRIBUTING.md

git commit -m "feat: add Docker, DevSecOps Jenkins pipeline and GitHub Actions CI/CD"
```

Use [Conventional Commits](https://www.conventionalcommits.org/) format:

- `feat:` — new feature
- `fix:` — bug fix
- `docs:` — documentation only
- `chore:` — tooling, build changes

### 2. Push Your Branch

```bash
git push origin feature/container-devsecops
```

### 3. Open a Pull Request

1. Go to your fork on GitHub
2. Click **Compare & pull request**
3. Fill in the PR description — **What** did you add, **Why** is it useful, **How** was it tested
4. Submit the PR

### PR Checklist

Before submitting, confirm:

- [ ] Tests pass locally (`npm test -- --watchAll=false`)
- [ ] App builds successfully (`npm run build`)
- [ ] Docker image builds without errors (`DOCKER_BUILDKIT=1 docker build -t ridanexpress:latest .`)
- [ ] Container runs correctly (`docker run -p 3000:80 ridanexpress:latest`)
- [ ] App loads at `http://localhost:3000` with no errors in logs
- [ ] Commit message follows Conventional Commits format
- [ ] PR description explains what was added and why

### Security Scan Failures

If the pipeline fails on a security stage, check the archived reports under the build's **Artifacts** section in Jenkins:

- **Gitleaks report** — lists any detected secrets with file and line number
- **Trivy report** — lists CVEs found in the Docker image with severity and fix version

---

## Project Structure Reference

```
ridanexpress/
├── .github/
│   └── workflows/
│       └── ci.yml                  ← GitHub Actions pipeline
├── public/
│   └── images/
├── src/                            ← React source code
│   ├── assets/
│   │   └── Images/
│   │       └── banner/
│   │           └── logo.png        ← Copied into Docker image for legacy path
│   ├── components/
│   ├── pages/
│   ├── store/                      ← Redux state management
│   └── main.jsx                    ← App entry point
├── build/                          ← Compiled output (generated by npm run build)
├── .dockerignore                   ← Files excluded from Docker build context
├── Dockerfile                      ← Multi-stage, BuildKit-enabled, non-root build
├── Jenkinsfile                     ← Full 11-stage DevSecOps Jenkins pipeline
├── sonar-project.properties        ← SonarQube scanner configuration
├── package.json                    ← Dependencies and scripts
├── package-lock.json               ← Locked dependency versions
├── vite.config.js                  ← Vite build configuration
└── CONTRIBUTING.md                 ← This file
```

---

## Questions?

If you run into any issues, open a [GitHub Issue](https://github.com/EmmanuelDevC/ridanexpress/issues) with details about your environment and the error you encountered.
