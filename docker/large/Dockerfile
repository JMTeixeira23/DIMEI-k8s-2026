# large — Python 3.12 slim (~120 MB)
# Represents a typical microservice runtime image
FROM python:3.12-slim
RUN pip install --no-cache-dir requests flask boto3 pyyaml cryptography
LABEL org.opencontainers.image.title="supply-chain-large"
LABEL org.opencontainers.image.description="Phase 4b size test — large (~120MB)"
CMD ["python3", "-c", "print('large-image')"]