# docker/hello-world/Dockerfile
# Simple smoke-test image — no compilation needed.
# Alpine is sufficient for Phase 1; distroless is used from Phase 2 onwards
# when the SBOM needs to be minimal and clean.

FROM alpine:3.19

LABEL org.opencontainers.image.title="hello-world"
LABEL org.opencontainers.image.description="Phase 1 smoke-test image"
LABEL org.opencontainers.image.source="https://github.com/JMTeixeira23/DIMEI-k8s-2026"
LABEL org.opencontainers.image.licenses="MIT"

RUN echo "Image built successfully" > /hello.txt

CMD ["sh", "-c", "echo '=== Phase 1 smoke test PASSED ===' && echo 'Time:' $(date) && echo 'Host:' $(hostname)"]