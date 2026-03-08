# medium — Alpine + curl + jq + git (~30 MB)
FROM alpine:3.19
RUN apk add --no-cache curl jq git bash openssl ca-certificates
LABEL org.opencontainers.image.title="supply-chain-medium"
LABEL org.opencontainers.image.description="Phase 4b size test — medium (~30MB)"
CMD ["sh", "-c", "echo medium-image hostname=$(hostname)"]