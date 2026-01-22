#!/bin/bash

#######################################
# OpenTelemetry Collector Installation Script
# For monitoring existing EC2 instances
#######################################

set -e

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "================================================"
echo "  OpenTelemetry Collector Installation"
echo "================================================"
echo -e "${NC}"

# Get OpenObserve configuration
read -p "OpenObserve HTTP endpoint (e.g., https://api.openobserve.ai/api/org/default/): " OPENOBSERVE_ENDPOINT
read -p "OpenObserve username/email: " OPENOBSERVE_USER
read -sp "OpenObserve password: " OPENOBSERVE_PASS
echo ""

# Encode credentials
AUTH_HEADER=$(echo -n "${OPENOBSERVE_USER}:${OPENOBSERVE_PASS}" | base64)

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${YELLOW}Cannot detect OS. Assuming Amazon Linux${NC}"
    OS="amzn"
fi

echo -e "${BLUE}Detected OS: $OS${NC}"

# Download and install OpenTelemetry Collector
echo -e "${BLUE}Downloading OpenTelemetry Collector...${NC}"

OTEL_VERSION="0.94.0"
wget https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol_${OTEL_VERSION}_linux_amd64.tar.gz

tar -xzf otelcol_${OTEL_VERSION}_linux_amd64.tar.gz
sudo mv otelcol /usr/local/bin/
sudo chmod +x /usr/local/bin/otelcol

# Create config directory
sudo mkdir -p /etc/otelcol
sudo mkdir -p /var/log/otelcol

# Create configuration file
echo -e "${BLUE}Creating OpenTelemetry configuration...${NC}"

sudo tee /etc/otelcol/config.yaml > /dev/null <<EOF
receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
      memory:
      disk:
      filesystem:
      load:
      network:
      paging:
      processes:

  filelog:
    include:
      - /var/log/*.log
      - /var/log/messages
      - /var/log/secure
      - /var/log/syslog
    include_file_path: true
    include_file_name: true

processors:
  batch:
    timeout: 10s
    send_batch_size: 1024

  resourcedetection:
    detectors: [env, ec2, system]
    timeout: 5s

  resource:
    attributes:
      - key: service.name
        value: "ec2-monitoring"
        action: upsert

exporters:
  otlphttp:
    endpoint: "${OPENOBSERVE_ENDPOINT}v1/logs"
    headers:
      Authorization: "Basic ${AUTH_HEADER}"
      stream-name: "ec2-otel-logs"
    compression: gzip

  otlphttp/metrics:
    endpoint: "${OPENOBSERVE_ENDPOINT}v1/metrics"
    headers:
      Authorization: "Basic ${AUTH_HEADER}"
      stream-name: "ec2-otel-metrics"
    compression: gzip

service:
  pipelines:
    logs:
      receivers: [filelog]
      processors: [batch, resourcedetection, resource]
      exporters: [otlphttp]

    metrics:
      receivers: [hostmetrics]
      processors: [batch, resourcedetection, resource]
      exporters: [otlphttp/metrics]
EOF

# Create systemd service
echo -e "${BLUE}Creating systemd service...${NC}"

sudo tee /etc/systemd/system/otelcol.service > /dev/null <<EOF
[Unit]
Description=OpenTelemetry Collector
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/otelcol --config=/etc/otelcol/config.yaml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Start the service
echo -e "${BLUE}Starting OpenTelemetry Collector...${NC}"

sudo systemctl daemon-reload
sudo systemctl enable otelcol
sudo systemctl start otelcol

# Check status
sleep 2
if sudo systemctl is-active --quiet otelcol; then
    echo -e "${GREEN}✓ OpenTelemetry Collector installed and running!${NC}"
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo "1. Check logs: sudo journalctl -u otelcol -f"
    echo "2. View metrics in OpenObserve: ${OPENOBSERVE_ENDPOINT}"
    echo "3. Stream: ec2-otel-logs (logs) and ec2-otel-metrics (metrics)"
else
    echo -e "${YELLOW}⚠ Service started but may have errors. Check logs:${NC}"
    echo "sudo journalctl -u otelcol -n 50"
fi

# Cleanup
rm -f otelcol_${OTEL_VERSION}_linux_amd64.tar.gz

echo ""
echo -e "${GREEN}Installation complete!${NC}"
