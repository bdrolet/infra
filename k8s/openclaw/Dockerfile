FROM node:24-bookworm-slim

# Install system deps needed by openclaw and its channel integrations
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    openssl \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g openclaw@latest

USER node
WORKDIR /home/node
EXPOSE 18789

CMD ["openclaw", "gateway", "--bind", "lan", "--port", "18789", "--allow-unconfigured"]
