FROM alpine:latest

# Install only necessary packages
RUN apk add --no-cache \
    bash \
    rsync \
    docker-cli \
    msmtp \
    ca-certificates \
    tzdata \
    coreutils

# Create directory for scripts
RUN mkdir -p /usr/local/bin

# Copy scripts
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY backup.sh /usr/local/bin/backup.sh

# Make scripts executable
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/backup.sh

# Entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]