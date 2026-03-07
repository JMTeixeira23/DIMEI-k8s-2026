# docker/hello-world/Dockerfile
# Multi-stage smoke-test image.
# Stage 1 compiles a minimal static Go binary.
# Stage 2 copies it into distroless — no shell, no package manager.
#
# Using distroless keeps the Phase 2 SBOM minimal and clean.
# The nonroot variant enforces least-privilege execution.

# ── Build stage ──────────────────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY main.go .
# Fully static binary — no libc dependency, works in distroless
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /hello .

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot

LABEL org.opencontainers.image.title="hello-world"
LABEL org.opencontainers.image.description="Phase 1 smoke-test image"
LABEL org.opencontainers.image.source="https://github.com/YOUR_ORG/YOUR_REPO"
LABEL org.opencontainers.image.licenses="MIT"

COPY --from=builder /hello /hello
USER nonroot:nonroot
ENTRYPOINT ["/hello"]
