# Claude API Traffic Logger
# Bundles claude-code-logger (HTTP proxy) + Fluent Bit (OTLP shipper)
#
# Architecture:
#   Claude Code --HTTP--> claude-code-logger:8000 --HTTPS--> api.anthropic.com
#                              |
#                              v (logs)
#                         Fluent Bit --OTLP--> Seq

FROM node:22-slim

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Fluent Bit
RUN curl -fsSL https://packages.fluentbit.io/fluentbit.key | gpg --dearmor -o /usr/share/keyrings/fluentbit.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/fluentbit.gpg] https://packages.fluentbit.io/debian/bookworm bookworm main" \
       > /etc/apt/sources.list.d/fluentbit.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends fluent-bit \
    && rm -rf /var/lib/apt/lists/*

# Install claude-code-logger globally
RUN npm install -g claude-code-logger

# Create log directory
RUN mkdir -p /var/log

# Copy configuration files
COPY fluent-bit.conf /etc/fluent-bit/fluent-bit.conf
COPY parsers.conf /etc/fluent-bit/parsers.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose the proxy port
EXPOSE 8000

# Health check - verify the proxy is responding
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -sf http://localhost:8000/ || exit 1

ENTRYPOINT ["/entrypoint.sh"]
