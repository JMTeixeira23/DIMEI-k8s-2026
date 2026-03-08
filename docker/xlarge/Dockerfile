# xlarge — Node.js 20 + heavy dependencies (~400 MB)
# Represents a real-world enterprise application image
FROM node:20-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install a realistic set of npm packages to bulk up the image
RUN npm install -g \
    express \
    axios \
    lodash \
    moment \
    uuid \
    winston \
    dotenv \
    joi \
    bcrypt \
    jsonwebtoken

LABEL org.opencontainers.image.title="supply-chain-xlarge"
LABEL org.opencontainers.image.description="Phase 4b size test — xlarge (~400MB)"
CMD ["node", "-e", "console.log('xlarge-image')"]