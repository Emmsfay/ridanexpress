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

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Copy Vite build output (dist/, not build/)
COPY --from=builder /app/dist /usr/share/nginx/html
COPY --from=builder /app/src/assets/Images/banner/logo.png \
                    /usr/share/nginx/html/images/logo.png

# SPA routing + non-root port
COPY nginx.conf /etc/nginx/conf.d/default.conf

RUN chown -R appuser:appgroup /usr/share/nginx/html && \
    chown -R appuser:appgroup /var/cache/nginx && \
    chown -R appuser:appgroup /var/log/nginx && \
    touch /tmp/nginx.pid && \
    chown appuser:appgroup /tmp/nginx.pid

RUN sed -i 's/^user/#user/' /etc/nginx/nginx.conf && \
    sed -i 's|pid\s*/var/run/nginx.pid;|pid /tmp/nginx.pid;|' /etc/nginx/nginx.conf

USER appuser

EXPOSE 80
