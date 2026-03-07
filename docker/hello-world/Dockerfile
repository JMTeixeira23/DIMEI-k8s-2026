FROM alpine:3.19

LABEL org.opencontainers.image.title="hello-world"
LABEL org.opencontainers.image.description="Phase 1 smoke-test image"
LABEL org.opencontainers.image.source="https://github.com/JMTeixeira23/DIMEI-k8s-2026"
LABEL org.opencontainers.image.licenses="MIT"

# Bakes the commit SHA into the image — ensures every commit produces
# a unique digest, which prevents the ECR immutable tag conflict on re-runs
ARG GIT_SHA=unknown
ENV GIT_SHA=${GIT_SHA}

RUN echo "Built from commit: ${GIT_SHA}" > /build-info.txt

CMD ["sh", "-c", "echo '=== Phase 1 smoke test PASSED ===' && echo 'Commit:' $GIT_SHA && echo 'Host:' $(hostname)"]
