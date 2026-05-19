# ── STAGE 1: Build ─────────────────────────────────────────────
FROM node:22.22-alpine AS builder

WORKDIR /app

# Allow passing proxy settings during build and runtime
ARG HTTP_PROXY
ARG HTTPS_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} HTTPS_PROXY=${HTTPS_PROXY}

COPY package*.json ./
# Improve npm network reliability during image builds and cache npm between builds
# Uses BuildKit cache mount; enable BuildKit when running `docker build` (DOCKER_BUILDKIT=1).
RUN --mount=type=cache,id=npm-cache,target=/root/.npm \
    npm set fetch-retries 5 && \
    npm set fetch-retry-mintimeout 20000 && \
    npm set fetch-retry-maxtimeout 120000 && \
    npm ci

COPY . .
RUN npm run build


# ── STAGE 2: Serve ─────────────────────────────────────────────
FROM nginx:stable-alpine

# Create a non-root user — containers running as root are a security risk
# If an attacker breaks out of the app, they get root on the host
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Copy compiled files
COPY --from=builder /app/build /usr/share/nginx/html

# Ensure legacy absolute path /images/logo.png exists for references
# Some parts of the app reference /images/logo.png (not the hashed bundle path).
# Copy the original source logo into the final image so requests to /images/logo.png succeed.
COPY --from=builder /app/src/assets/Images/banner/logo.png /usr/share/nginx/html/images/logo.png

# Give ownership of nginx files to the non-root user
RUN chown -R appuser:appgroup /usr/share/nginx/html && \
    chown -R appuser:appgroup /var/cache/nginx && \
    chown -R appuser:appgroup /var/log/nginx && \
    touch /var/run/nginx.pid && \
    chown -R appuser:appgroup /var/run/nginx.pid

# Remove the "user" directive — incompatible when running as non-root
RUN sed -i 's/^user/#user/' /etc/nginx/nginx.conf

# Switch to non-root user
USER appuser

EXPOSE 80
