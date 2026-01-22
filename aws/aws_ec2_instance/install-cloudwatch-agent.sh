#!/bin/bash

#######################################
# CloudWatch Agent Installation Script
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
echo "  CloudWatch Agent Installation"
echo "================================================"
echo -e "${NC}"

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${YELLOW}Cannot detect OS. Assuming Amazon Linux${NC}"
    OS="amzn"
fi

echo -e "${BLUE}Detected OS: $OS${NC}"

# Download and install CloudWatch Agent
echo -e "${BLUE}Downloading CloudWatch Agent...${NC}"

if [[ "$OS" == "amzn" ]] || [[ "$OS" == "rhel" ]] || [[ "$OS" == "centos" ]]; then
    wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
    sudo rpm -U ./amazon-cloudwatch-agent.rpm
    rm -f amazon-cloudwatch-agent.rpm
elif [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
    wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
    sudo dpkg -i -E ./amazon-cloudwatch-agent.deb
    rm -f amazon-cloudwatch-agent.deb
else
    echo -e "${YELLOW}Unsupported OS: $OS${NC}"
    exit 1
fi

# Get instance ID and region
INSTANCE_ID=$(ec2-metadata --instance-id | cut -d " " -f 2)
REGION=$(ec2-metadata --availability-zone | cut -d " " -f 2 | sed 's/[a-z]$//')

echo -e "${BLUE}Instance ID: $INSTANCE_ID${NC}"
echo -e "${BLUE}Region: $REGION${NC}"

# Create CloudWatch Agent configuration
echo -e "${BLUE}Creating CloudWatch Agent configuration...${NC}"

sudo tee /opt/aws/amazon-cloudwatch-agent/etc/config.json > /dev/null <<EOF
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/messages",
            "log_group_name": "/aws/ec2/instance/${INSTANCE_ID}/system",
            "log_stream_name": "{instance_id}/messages",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/secure",
            "log_group_name": "/aws/ec2/instance/${INSTANCE_ID}/system",
            "log_stream_name": "{instance_id}/secure",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/syslog",
            "log_group_name": "/aws/ec2/instance/${INSTANCE_ID}/system",
            "log_stream_name": "{instance_id}/syslog",
            "timezone": "UTC"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "EC2/Custom",
    "metrics_collected": {
      "cpu": {
        "measurement": [
          {"name": "cpu_usage_idle", "rename": "CPU_IDLE", "unit": "Percent"},
          {"name": "cpu_usage_iowait", "rename": "CPU_IOWAIT", "unit": "Percent"}
        ],
        "metrics_collection_interval": 60,
        "totalcpu": true
      },
      "disk": {
        "measurement": [
          {"name": "used_percent", "rename": "DISK_USED", "unit": "Percent"}
        ],
        "metrics_collection_interval": 60,
        "resources": ["*"]
      },
      "diskio": {
        "measurement": [
          {"name": "io_time", "rename": "DISK_IO", "unit": "Milliseconds"}
        ],
        "metrics_collection_interval": 60,
        "resources": ["*"]
      },
      "mem": {
        "measurement": [
          {"name": "mem_used_percent", "rename": "MEM_USED", "unit": "Percent"}
        ],
        "metrics_collection_interval": 60
      },
      "netstat": {
        "measurement": [
          {"name": "tcp_established", "rename": "TCP_CONN", "unit": "Count"}
        ],
        "metrics_collection_interval": 60
      }
    }
  }
}
EOF

# Start CloudWatch Agent
echo -e "${BLUE}Starting CloudWatch Agent...${NC}"

sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json

# Check status
sleep 2
STATUS=$(sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a query \
    -m ec2 \
    -c default | jq -r '.status')

if [ "$STATUS" == "running" ]; then
    echo -e "${GREEN}✓ CloudWatch Agent installed and running!${NC}"
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo "1. Verify IAM role allows CloudWatch:PutMetricData and logs:PutLogEvents"
    echo "2. Deploy CloudWatch Logs streaming to OpenObserve:"
    echo "   cd ../aws_cloudwatch_logs"
    echo "   ./deploy.sh"
    echo "   # Enter log group: /aws/ec2/instance/${INSTANCE_ID}/system"
    echo ""
    echo "3. Check agent status: sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a query -m ec2"
else
    echo -e "${YELLOW}⚠ Agent may have errors. Check logs:${NC}"
    echo "sudo tail -f /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log"
fi

echo ""
echo -e "${GREEN}Installation complete!${NC}"
