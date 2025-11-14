# Server Dockerfile
# Build binary locally on host, then copy into Alpine container
# This avoids corporate firewall issues with Go module downloads
FROM alpine/curl:latest

# Create app directory
WORKDIR /root/

# Copy pre-built binary from build directory (built on host)
COPY build/fluidity-server .

# Create config and certs directories (files will be mounted at runtime)
RUN mkdir -p ./config ./certs

# Copy default configuration files (can be overridden with volume mounts)
COPY configs/server.yaml ./config/server.yaml

# Expose server port
EXPOSE 8443

# Command to run
CMD ["./fluidity-server", "--config", "./config/server.yaml"]