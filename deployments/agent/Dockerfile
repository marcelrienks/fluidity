# Agent Dockerfile
# Build binary locally on host, then copy into Alpine container
# This avoids corporate firewall issues with Go module downloads
FROM alpine/curl:latest

# Create app directory
WORKDIR /root/

# Copy pre-built binary from build directory (built on host)
COPY build/fluidity-agent .

# Create config and certs directories (files will be mounted at runtime)
RUN mkdir -p ./config ./certs

# Copy default configuration files (can be overridden with volume mounts)
COPY configs/agent.yaml ./config/agent.yaml

# Expose proxy port
EXPOSE 8080

# Command to run
CMD ["./fluidity-agent", "--config", "./config/agent.yaml"]