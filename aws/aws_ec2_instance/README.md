# EC2 Instance Monitoring to OpenObserve

Monitor existing EC2 instances by installing monitoring agents that send logs and metrics to OpenObserve.

## Important: Agent-Based Monitoring

Unlike other AWS services (CloudFront, RDS, etc.), EC2 monitoring requires **installing an agent** on your instances. This directory provides **3 deployment methods**:

1. **SSM-based deployment** (CloudFormation) - Automated agent installation via Systems Manager
2. **Manual installation scripts** - SSH to instances and run scripts
3. **CloudWatch streaming** - Use `aws_cloudwatch_logs` templates for existing CloudWatch setups

---

## Deployment Methods

### Method 1: SSM-based (CloudFormation) ⭐ NEW

**Use CloudFormation + Systems Manager to automatically install agents on tagged instances!**

```bash
chmod +x deploy-ssm.sh
./deploy-ssm.sh
```

**Features:**
- ✅ CloudFormation deployment (infrastructure as code)
- ✅ Tag-based instance targeting
- ✅ Automatic agent installation via SSM
- ✅ No SSH required
- ✅ Scales to multiple instances automatically
- ✅ Re-runs every 30 days to ensure agents are running

**Requirements:**
- Instances must have SSM agent installed (pre-installed on Amazon Linux 2/2023)
- Instances must have IAM role with `AmazonSSMManagedInstanceCore` policy
- Tag instances with `monitoring=enabled` (or custom tag)

**Templates:**
- `ec2-otel-via-ssm.yaml` - OpenTelemetry via SSM
- `ec2-cloudwatch-via-ssm.yaml` - CloudWatch Agent via SSM

**Stack naming:** `ec2-otel-ssm` or `ec2-cw-ssm`

---

### Method 2: Manual Installation Scripts

**SSH to each instance and run installation scripts.**

**Scripts:**
- `install-otel-collector.sh` - OpenTelemetry
- `install-cloudwatch-agent.sh` - CloudWatch Agent

**Best for:** One-off installations, instances without SSM

---

### Method 3: CloudWatch Streaming Only

**If instances already have CloudWatch Agent installed**, use `aws_cloudwatch_logs` to stream to OpenObserve.

---

## Monitoring Options

### Option 1: OpenTelemetry Collector (Recommended)

**Architecture:**
```
EC2 Instance (OTel Agent) → OpenObserve (Direct OTLP HTTP)
```

**Features:**
- ✅ Direct connection to OpenObserve (no AWS streaming services)
- ✅ Lowest cost (~$3/month - just data transfer)
- ✅ Lowest latency (direct push)
- ✅ Rich metrics: CPU, memory, disk, network, load, processes
- ✅ File logs: /var/log/*.log, messages, secure, syslog
- ✅ Industry standard (vendor-agnostic)
- ✅ Traces support (future)

**Cost:** ~$3/month (1GB/day data transfer)

**Best for:** Modern infrastructure, cost-conscious deployments, multi-cloud

---

### Option 2: CloudWatch Agent + Streaming Pipeline

**Architecture:**
```
EC2 Instance (CW Agent) → CloudWatch Logs → Kinesis → Lambda → Firehose → OpenObserve
                        ↓
                  CloudWatch Metrics
```

**Features:**
- ✅ AWS-native monitoring
- ✅ CloudWatch Logs for AWS Console querying
- ✅ Integration with AWS services
- ✅ CloudWatch alarms and dashboards
- ❌ Higher cost (~$47/month)
- ❌ Higher latency (multi-hop pipeline)

**Cost:** ~$47/month (CloudWatch streaming)

**Best for:** AWS-centric organizations, compliance requiring CloudWatch retention

---

## Quick Start

### Method 1: SSM-based Deployment (CloudFormation) ⭐ RECOMMENDED

**Deploy agents to multiple instances using CloudFormation + Systems Manager:**

```bash
chmod +x deploy-ssm.sh
./deploy-ssm.sh
```

**Steps:**
1. **Tag your instances:**
   ```bash
   aws ec2 create-tags \
     --resources i-0c997328b573d7d30 \
     --tags Key=monitoring,Value=enabled
   ```

2. **Ensure instances have SSM IAM role:**
   ```bash
   # Check if instance has IAM role
   aws ec2 describe-instances --instance-ids i-0c997328b573d7d30 \
     --query 'Reservations[0].Instances[0].IamInstanceProfile'

   # If no role, create and attach one with AmazonSSMManagedInstanceCore policy
   ```

3. **Run deploy script:**
   ```bash
   ./deploy-ssm.sh
   # Choose OpenTelemetry (option 1) or CloudWatch (option 2)
   # Enter OpenObserve credentials
   # Agents install automatically on all tagged instances!
   ```

4. **Verify:**
   - SSM will install the agent within minutes
   - Check: `aws ssm list-commands`
   - View data in OpenObserve

---

### Method 2: Manual Installation Scripts

### For OpenTelemetry Collector (Recommended)

**1. Copy installation script to your EC2 instance:**

```bash
# From your local machine
scp -i your-key.pem install-otel-collector.sh ec2-user@<instance-ip>:~
```

**2. SSH to your instance and run:**

```bash
ssh -i your-key.pem ec2-user@<instance-ip>
chmod +x install-otel-collector.sh
./install-otel-collector.sh
```

**3. Enter OpenObserve credentials when prompted:**
- Endpoint: `https://api.openobserve.ai/api/your-org/default/`
- Username/email: `your-email@example.com`
- Password: `your-password`

**4. Verify in OpenObserve:**
- Logs stream: `ec2-otel-logs`
- Metrics stream: `ec2-otel-metrics`

---

### For CloudWatch Agent

**1. Install CloudWatch Agent on EC2:**

```bash
# Copy script to instance
scp -i your-key.pem install-cloudwatch-agent.sh ec2-user@<instance-ip>:~

# SSH and run
ssh -i your-key.pem ec2-user@<instance-ip>
chmod +x install-cloudwatch-agent.sh
./install-cloudwatch-agent.sh
```

**2. Deploy CloudWatch streaming pipeline:**

```bash
cd ../aws_cloudwatch_logs
./deploy.sh
# Enter log group: /aws/ec2/instance/i-0c997328b573d7d30/system
```

---

## Prerequisites

### EC2 Instance Requirements

1. **Network access** to OpenObserve endpoint (HTTPS outbound)
2. **IAM role** (for CloudWatch option only):
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "cloudwatch:PutMetricData",
           "logs:CreateLogGroup",
           "logs:CreateLogStream",
           "logs:PutLogEvents"
         ],
         "Resource": "*"
       }
     ]
   }
   ```
3. **SSH access** to install agent
4. **Supported OS:** Amazon Linux, Ubuntu, Debian, RHEL, CentOS

### Local Machine Requirements

- AWS CLI (for CloudWatch streaming deployment)
- SSH key for EC2 access
- `scp` for file transfer

---

## Installation Scripts

### OpenTelemetry Collector: `install-otel-collector.sh`

**What it does:**
1. Downloads OpenTelemetry Collector v0.94.0
2. Installs to `/usr/local/bin/otelcol`
3. Creates configuration in `/etc/otelcol/config.yaml`
4. Sets up systemd service
5. Starts collector automatically
6. Configures log and metric collection

**Logs collected:**
- `/var/log/*.log`
- `/var/log/messages`
- `/var/log/secure`
- `/var/log/syslog`

**Metrics collected:**
- CPU usage
- Memory usage
- Disk I/O
- Filesystem usage
- Network traffic
- Load average
- Process count
- Paging activity

**Configuration file:** `/etc/otelcol/config.yaml`

**Service management:**
```bash
sudo systemctl status otelcol
sudo systemctl restart otelcol
sudo systemctl stop otelcol
sudo journalctl -u otelcol -f
```

---

### CloudWatch Agent: `install-cloudwatch-agent.sh`

**What it does:**
1. Downloads and installs CloudWatch Agent
2. Detects instance ID and region automatically
3. Creates configuration in `/opt/aws/amazon-cloudwatch-agent/etc/config.json`
4. Starts agent
5. Sends logs to CloudWatch Logs group: `/aws/ec2/instance/<INSTANCE-ID>/system`
6. Sends metrics to CloudWatch namespace: `EC2/Custom`

**Logs collected:**
- `/var/log/messages` (system logs)
- `/var/log/secure` (auth logs)
- `/var/log/syslog` (Ubuntu/Debian)

**Metrics collected:**
- CPU usage (idle, iowait)
- Memory usage
- Disk usage
- Disk I/O
- Network connections (TCP)

**Configuration file:** `/opt/aws/amazon-cloudwatch-agent/etc/config.json`

**Service management:**
```bash
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a query -m ec2
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a stop -m ec2
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a start -m ec2
sudo tail -f /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log
```

---

## CloudWatch Streaming Pipeline (CloudWatch Option Only)

If you installed CloudWatch Agent, deploy the streaming pipeline to send logs to OpenObserve:

### Using aws_cloudwatch_logs Templates

```bash
cd /Users/mdmosaraf/Documents/cloudformation/aws_cloudwatch_logs
./deploy.sh
```

**When prompted:**
- Log Group: `/aws/ec2/instance/<INSTANCE-ID>/system`
- Filter Pattern: `` (leave empty for all logs)

This creates:
- Kinesis Data Stream
- Lambda transformation
- Firehose to OpenObserve
- Subscription filter

**Stack naming:** `cw-logs-aws-ec2-instance-<INSTANCE-ID>-system`

---

## Cost Comparison

### OpenTelemetry Option

| Component | Monthly Cost |
|-----------|--------------|
| OpenTelemetry Collector | $0 |
| Data transfer (1GB/day) | ~$2.70 |
| **Total** | **~$3/month** |

### CloudWatch Option

| Component | Monthly Cost |
|-----------|--------------|
| CloudWatch Agent | $0 |
| CloudWatch Logs ingestion (1GB/day) | ~$1.50 |
| CloudWatch Logs storage | ~$1.50 |
| Kinesis Data Stream (1 shard) | ~$30 |
| Kinesis Firehose | ~$15 |
| Lambda | ~$2 |
| **Total** | **~$50/month** |

**Savings with OpenTelemetry:** ~94% cost reduction!

---

## Monitoring Multiple EC2 Instances

### OpenTelemetry Approach

Run `install-otel-collector.sh` on each instance. All instances send to OpenObserve directly.

**Identify instances in OpenObserve:**
```sql
-- Auto-detected fields from resource detection
SELECT * FROM "ec2-otel-logs"
WHERE host_name = 'i-0c997328b573d7d30'

SELECT * FROM "ec2-otel-metrics"
WHERE cloud_instance_id = 'i-0c997328b573d7d30'

-- Query metrics by instance
SELECT avg(value) FROM "ec2-otel-metrics"
WHERE metric_name = 'system.cpu.utilization'
GROUP BY cloud_instance_id
```

### CloudWatch Approach

Deploy one streaming stack per instance:

```bash
cd ../aws_cloudwatch_logs

# Instance 1
export LOG_GROUP_NAME="/aws/ec2/instance/i-0c997328b573d7d30/system"
./deploy.sh

# Instance 2
export LOG_GROUP_NAME="/aws/ec2/instance/i-1234567890abcdef0/system"
./deploy.sh
```

---

## Customization

### OpenTelemetry: Add Application Logs

Edit `/etc/otelcol/config.yaml`:

```yaml
receivers:
  filelog:
    include:
      - /var/log/*.log
      - /var/log/messages
      - /var/app/logs/*.log          # Add your app logs
      - /opt/myapp/logs/error.log    # Specific log files
      - /home/app/application.log
```

Restart: `sudo systemctl restart otelcol`

### OpenTelemetry: Change Collection Interval

```yaml
receivers:
  hostmetrics:
    collection_interval: 10s  # Change from 30s to 10s for higher resolution
```

### CloudWatch: Add Application Logs

Edit `/opt/aws/amazon-cloudwatch-agent/etc/config.json`:

```json
{
  "file_path": "/var/app/logs/application.log",
  "log_group_name": "/aws/ec2/instance/${INSTANCE_ID}/application",
  "log_stream_name": "{instance_id}/app"
}
```

Restart:
```bash
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json
```

---

## Auto Scaling Groups

### For OpenTelemetry

Add to Launch Template User Data:

```bash
#!/bin/bash
cd /tmp
wget https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.94.0/otelcol_0.94.0_linux_amd64.tar.gz
tar -xzf otelcol_0.94.0_linux_amd64.tar.gz
sudo mv otelcol /usr/local/bin/
sudo mkdir -p /etc/otelcol

# Create config (embed your OpenObserve credentials)
sudo cat > /etc/otelcol/config.yaml <<'EOF'
# ... paste your config here ...
EOF

# Create and start systemd service
# ... (same as install script)
```

### For CloudWatch

CloudWatch Agent can be installed via Systems Manager or User Data. See AWS documentation.

---

## Troubleshooting

### OpenTelemetry: No Data in OpenObserve

1. **Check service status:**
   ```bash
   sudo systemctl status otelcol
   sudo journalctl -u otelcol -n 100
   ```

2. **Verify network connectivity:**
   ```bash
   curl -v https://api.openobserve.ai
   ```

3. **Check configuration:**
   ```bash
   cat /etc/otelcol/config.yaml
   ```

4. **Test credentials:**
   ```bash
   echo -n "email:password" | base64
   # Verify matches what's in config
   ```

5. **Check file permissions:**
   ```bash
   ls -la /var/log/
   # Ensure otelcol can read log files
   ```

### CloudWatch: No Logs in CloudWatch

1. **Check agent status:**
   ```bash
   sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a query -m ec2
   ```

2. **Verify IAM role attached to instance:**
   ```bash
   aws ec2 describe-instances --instance-ids i-0c997328b573d7d30 \
     --query 'Reservations[0].Instances[0].IamInstanceProfile'
   ```

3. **Check agent logs:**
   ```bash
   sudo tail -f /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log
   ```

4. **Verify log groups created:**
   ```bash
   aws logs describe-log-groups --log-group-name-prefix "/aws/ec2/instance/"
   ```

### CloudWatch: No Data in OpenObserve

Use the troubleshooting guide from `../aws_cloudwatch_logs/README.md`

---

## Security Best Practices

1. **Use IMDSv2** for instance metadata:
   ```bash
   aws ec2 modify-instance-metadata-options \
     --instance-id i-0c997328b573d7d30 \
     --http-tokens required
   ```

2. **Rotate OpenObserve credentials** regularly

3. **Use AWS Secrets Manager** for storing credentials (advanced)

4. **Restrict agent permissions** with least-privilege IAM roles

5. **Enable encryption** for CloudWatch Logs (CloudWatch option)

6. **Use VPC endpoints** for CloudWatch/Kinesis (CloudWatch option)

7. **Limit log file collection** to necessary paths only

8. **Run agents as non-root** user (requires proper file permissions)

---

## Uninstallation

### Remove OpenTelemetry Collector

```bash
sudo systemctl stop otelcol
sudo systemctl disable otelcol
sudo rm /etc/systemd/system/otelcol.service
sudo rm /usr/local/bin/otelcol
sudo rm -rf /etc/otelcol
sudo systemctl daemon-reload
```

### Remove CloudWatch Agent

```bash
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a stop -m ec2

# Amazon Linux/RHEL
sudo rpm -e amazon-cloudwatch-agent

# Ubuntu/Debian
sudo dpkg -r amazon-cloudwatch-agent
```

### Remove CloudWatch Streaming Stack

```bash
cd ../aws_cloudwatch_logs
./cleanup.sh
# Select the EC2 log group stack
```

---

## SSM-based Deployment Details

### How It Works

1. **CloudFormation creates:**
   - SSM Document (installation script)
   - SSM Association (targets tagged instances)

2. **SSM automatically:**
   - Finds instances with matching tags
   - Runs installation document on each instance
   - Re-runs every 30 days to ensure agents stay running

3. **No SSH needed:**
   - All done via Systems Manager
   - Works with private instances (no public IP needed)

### Tag Your Instances

```bash
# Single instance
aws ec2 create-tags \
  --resources i-0c997328b573d7d30 \
  --tags Key=monitoring,Value=enabled

# Multiple instances
aws ec2 create-tags \
  --resources i-0c997328b573d7d30 i-1234567890abcdef0 \
  --tags Key=monitoring,Value=enabled

# All instances in a region (be careful!)
INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text)
aws ec2 create-tags --resources $INSTANCES --tags Key=monitoring,Value=enabled
```

### Monitor SSM Execution

```bash
# List recent commands
aws ssm list-commands \
  --filters Key=DocumentName,Value=ec2-otel-ssm-install-otel

# Check command status
aws ssm list-command-invocations \
  --command-id <command-id> \
  --details

# Check on specific instance
aws ssm describe-instance-associations-status \
  --instance-id i-0c997328b573d7d30
```

### Cleanup SSM Stacks

**Using cleanup script (Recommended):**

```bash
chmod +x cleanup-ssm.sh
./cleanup-ssm.sh
```

The script will:
1. Find all SSM monitoring stacks (`ec2-otel-ssm`, `ec2-cw-ssm`)
2. Show stack details and targeted instances
3. Prompt for confirmation
4. **Offer to uninstall agents from instances** (via SSM - no SSH needed!)
5. Delete CloudFormation stack

**Manual cleanup:**

```bash
# Delete the SSM association stack
aws cloudformation delete-stack --stack-name ec2-otel-ssm

# This removes:
# - SSM Document
# - SSM Association
# - (Agents remain installed on instances - uninstall manually if needed)
```

---

## Files

### CloudFormation Templates (SSM-based)
- `ec2-otel-via-ssm.yaml` - OpenTelemetry via Systems Manager
- `ec2-cloudwatch-via-ssm.yaml` - CloudWatch Agent via Systems Manager
- `deploy-ssm.sh` - SSM deployment script
- `cleanup-ssm.sh` - SSM cleanup script (with agent uninstall option)

### Installation Scripts (Manual)
- `install-otel-collector.sh` - OpenTelemetry manual installation
- `install-cloudwatch-agent.sh` - CloudWatch Agent manual installation

### Documentation
- `README.md` - This file

**Note:** For CloudWatch streaming pipeline, use `../aws_cloudwatch_logs/` templates.

---

## FAQ

**Q: Do I need CloudFormation for EC2 monitoring?**
A: Not required, but **recommended using SSM-based deployment** (`deploy-ssm.sh`) for automated agent installation across multiple instances. For single instances, use manual installation scripts.

**Q: What's the difference between SSM deployment and manual scripts?**
A: SSM deployment uses CloudFormation + Systems Manager to automatically install agents on tagged instances (no SSH needed). Manual scripts require SSH to each instance. Use SSM for multiple instances or automated deployments.

**Q: Can I use SSM with existing instances?**
A: Yes! SSM deployment is specifically designed for existing instances. Just tag them with `monitoring=enabled` and run `./deploy-ssm.sh`.

**Q: Can I monitor existing instances?**
A: Yes! These scripts are specifically for existing instances. Just SSH in and run the installation script.

**Q: Which option should I choose?**
A: **OpenTelemetry** for most cases (94% cheaper, simpler, direct). **CloudWatch** if you need AWS-native integration or compliance requirements.

**Q: How do I monitor multiple instances?**
A: Run the installation script on each instance. All instances can use the same OpenObserve endpoint.

**Q: Does this work with Auto Scaling?**
A: Yes! Add the installation commands to your Launch Template User Data.

**Q: Can I collect custom application logs?**
A: Yes! Edit the agent config to add your application log file paths.

**Q: What about Windows instances?**
A: OpenTelemetry supports Windows. Download the Windows release and adjust paths in the config.

**Q: How do I identify which instance sent which log?**
A: Both agents include instance metadata (instance ID, hostname, region) automatically.

**Q: Can I use SSM Run Command instead of SSH?**
A: Yes! Use AWS Systems Manager Run Command to execute the installation script remotely.

**Q: What if I already use CloudWatch Agent?**
A: Great! Just deploy the streaming pipeline using `../aws_cloudwatch_logs/deploy.sh` to send CloudWatch Logs to OpenObserve.

---

## Support

- [OpenTelemetry Collector Documentation](https://opentelemetry.io/docs/collector/)
- [AWS CloudWatch Agent Guide](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Install-CloudWatch-Agent.html)
- [OpenObserve Documentation](https://openobserve.ai/docs)
- [EC2 Instance Metadata](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html)

---

## Summary

✅ **Two agent options:** OpenTelemetry (direct, cheap) or CloudWatch (AWS-native, expensive)
✅ **Installation scripts:** Ready to run on existing instances
✅ **No new instances:** Designed for monitoring existing infrastructure
✅ **Low cost:** ~$3/mo (OTel) vs ~$50/mo (CloudWatch)
✅ **Rich telemetry:** Metrics, logs, and traces (OTel)
✅ **Easy setup:** Copy script, run, done
✅ **Auto-detection:** Instance ID, region, OS automatically detected
✅ **Scalable:** Install on unlimited instances
✅ **Flexible:** Customize log paths and collection intervals
