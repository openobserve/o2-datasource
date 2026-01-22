# AWS VPC Flow Logs to OpenObserve

Stream AWS VPC Flow Logs to OpenObserve for network traffic analysis, security monitoring, and troubleshooting.

## Overview

VPC Flow Logs capture information about IP traffic flowing to and from network interfaces in your VPC. This solution provides two deployment options to stream these logs to OpenObserve for analysis and visualization.

## Deployment Options

### Option 1: Direct Firehose (Recommended)

**Architecture:** VPC Flow Logs → Firehose → OpenObserve

- **Template:** `vpc-flowlogs-to-openobserve-firehose.yaml`
- **Stack Prefix:** `vpc-flowlogs-firehose-<VPC-ID>`
- **Advantages:**
  - Simpler architecture with fewer components
  - Lower latency - logs stream directly to OpenObserve
  - Lower cost - no Kinesis Data Streams or CloudWatch Logs costs
  - Direct integration as documented in [OpenObserve blog](https://openobserve.ai/blog/how-to-capture-aws-vpc-flow-logs-and-analyze-them/)

**Use this option when:**
- You want the simplest and most cost-effective solution
- You don't need CloudWatch Logs integration
- You want real-time flow log streaming

### Option 2: CloudWatch Logs (Alternative)

**Architecture:** VPC Flow Logs → CloudWatch Logs → Kinesis → Firehose → OpenObserve

- **Template:** `vpc-flowlogs-to-openobserve-cloudwatch.yaml`
- **Stack Prefix:** `vpc-flowlogs-cw-<VPC-ID>`
- **Advantages:**
  - Logs available in CloudWatch for AWS-native querying
  - Can set custom retention policies
  - Integration with CloudWatch Logs Insights
  - Can apply CloudWatch Logs filters

**Use this option when:**
- You need CloudWatch Logs integration for compliance or existing workflows
- You want to query logs using CloudWatch Logs Insights
- You need CloudWatch alarms based on flow log patterns

## VPC Flow Log Fields

The solution captures and enriches the following fields:

### Standard Fields
- `version` - VPC Flow Logs version
- `account_id` - AWS account ID
- `interface_id` - Network interface ID (ENI)
- `srcaddr` - Source IP address
- `dstaddr` - Destination IP address
- `srcport` - Source port number
- `dstport` - Destination port number
- `protocol` - IANA protocol number
- `packets` - Number of packets transferred
- `bytes` - Number of bytes transferred
- `start` - Start time (Unix timestamp)
- `end` - End time (Unix timestamp)
- `action` - Traffic action (ACCEPT or REJECT)
- `log_status` - Logging status (OK, NODATA, SKIPDATA)

### Enriched Fields
- `protocol_name` - Human-readable protocol name (TCP, UDP, ICMP, etc.)
- `timestamp` - ISO 8601 timestamp for indexing
- `vpc_flow_log` - Boolean flag for filtering

### Protocol Enrichment

The Lambda transformation function automatically enriches protocol numbers with human-readable names:

| Protocol Number | Protocol Name |
|----------------|---------------|
| 1 | ICMP |
| 6 | TCP |
| 17 | UDP |
| 47 | GRE |
| 50 | ESP |
| 51 | AH |
| 58 | ICMPv6 |
| 89 | OSPF |
| 132 | SCTP |

## Prerequisites

1. AWS CLI installed and configured
2. Appropriate AWS permissions:
   - CloudFormation stack creation
   - VPC Flow Logs configuration
   - Firehose, Lambda, S3, IAM role creation
   - CloudWatch Logs (for Option 2)
   - Kinesis Data Streams (for Option 2)
3. OpenObserve account with:
   - API endpoint URL
   - Access key (base64 encoded `username:password`)

## Quick Start

### 1. Deploy VPC Flow Logs

```bash
# Make scripts executable
chmod +x deploy.sh cleanup.sh

# Run deployment script
./deploy.sh
```

The deployment script will:
1. List available VPCs in your AWS account
2. Prompt you to select deployment option (Firehose or CloudWatch)
3. Ask for VPC ID and traffic type (ALL/ACCEPT/REJECT)
4. Collect OpenObserve configuration details
5. Deploy the CloudFormation stack

### 2. Manual Deployment

If you prefer manual deployment:

```bash
# Option 1: Direct Firehose
aws cloudformation deploy \
  --template-file vpc-flowlogs-to-openobserve-firehose.yaml \
  --stack-name vpc-flowlogs-firehose-<VPC-ID-SUFFIX> \
  --parameter-overrides \
      OpenObserveEndpoint=https://api.openobserve.ai/api/your-org/default/_kinesis \
      OpenObserveAccessKey=<base64-encoded-credentials> \
      StreamName=vpc-flow-logs-stream \
      VpcId=vpc-xxxxx \
      TrafficType=ALL \
      BackupS3BucketName=vpc-flowlogs-backup-unique-name \
  --capabilities CAPABILITY_IAM

# Option 2: CloudWatch Logs
aws cloudformation deploy \
  --template-file vpc-flowlogs-to-openobserve-cloudwatch.yaml \
  --stack-name vpc-flowlogs-cw-<VPC-ID-SUFFIX> \
  --parameter-overrides \
      OpenObserveEndpoint=https://api.openobserve.ai/api/your-org/default/_kinesis \
      OpenObserveAccessKey=<base64-encoded-credentials> \
      StreamName=vpc-flow-logs-stream \
      VpcId=vpc-xxxxx \
      TrafficType=ALL \
      ShardCount=1 \
      BackupS3BucketName=vpc-flowlogs-backup-unique-name \
      CloudWatchLogGroupRetention=7 \
  --capabilities CAPABILITY_IAM
```

## Parameters

### Common Parameters (Both Options)

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| OpenObserveEndpoint | OpenObserve API endpoint URL | - | Yes |
| OpenObserveAccessKey | Base64 encoded credentials | - | Yes |
| StreamName | OpenObserve stream name | vpc-flow-logs-stream | No |
| VpcId | VPC ID to monitor | - | Yes |
| TrafficType | Traffic type to log (ALL/ACCEPT/REJECT) | ALL | No |
| BackupS3BucketName | S3 bucket for failed records | - | Yes |

### CloudWatch Option Additional Parameters

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| ShardCount | Kinesis stream shard count | 1 | No |
| CloudWatchLogGroupRetention | Log retention in days | 7 | No |

## Network Analysis Examples

### Query Examples in OpenObserve

#### 1. Top Talkers (Source IPs)
```sql
SELECT srcaddr, SUM(bytes) as total_bytes, SUM(packets) as total_packets
FROM vpc_flow_logs_stream
WHERE vpc_flow_log = true
GROUP BY srcaddr
ORDER BY total_bytes DESC
LIMIT 10
```

#### 2. Top Destinations
```sql
SELECT dstaddr, dstport, protocol_name, COUNT(*) as connection_count
FROM vpc_flow_logs_stream
WHERE vpc_flow_log = true
GROUP BY dstaddr, dstport, protocol_name
ORDER BY connection_count DESC
LIMIT 20
```

#### 3. Rejected Traffic Analysis
```sql
SELECT srcaddr, dstaddr, dstport, protocol_name, COUNT(*) as reject_count
FROM vpc_flow_logs_stream
WHERE vpc_flow_log = true AND action = 'REJECT'
GROUP BY srcaddr, dstaddr, dstport, protocol_name
ORDER BY reject_count DESC
LIMIT 10
```

#### 4. Top Protocols by Traffic Volume
```sql
SELECT protocol_name,
       COUNT(*) as flow_count,
       SUM(bytes) as total_bytes,
       SUM(packets) as total_packets
FROM vpc_flow_logs_stream
WHERE vpc_flow_log = true
GROUP BY protocol_name
ORDER BY total_bytes DESC
```

#### 5. Port Scan Detection
```sql
SELECT srcaddr,
       COUNT(DISTINCT dstport) as unique_ports,
       COUNT(*) as connection_attempts
FROM vpc_flow_logs_stream
WHERE vpc_flow_log = true
  AND action = 'REJECT'
GROUP BY srcaddr
HAVING unique_ports > 20
ORDER BY unique_ports DESC
```

#### 6. Large Data Transfers
```sql
SELECT srcaddr, dstaddr, protocol_name,
       SUM(bytes) as total_bytes,
       SUM(packets) as total_packets
FROM vpc_flow_logs_stream
WHERE vpc_flow_log = true
GROUP BY srcaddr, dstaddr, protocol_name
HAVING total_bytes > 1000000000  -- More than 1GB
ORDER BY total_bytes DESC
```

#### 7. SSH Connection Attempts
```sql
SELECT srcaddr, dstaddr, action, COUNT(*) as attempts
FROM vpc_flow_logs_stream
WHERE vpc_flow_log = true
  AND dstport = 22
  AND protocol_name = 'TCP'
GROUP BY srcaddr, dstaddr, action
ORDER BY attempts DESC
```

#### 8. Traffic by Network Interface
```sql
SELECT interface_id,
       action,
       COUNT(*) as flow_count,
       SUM(bytes) as total_bytes
FROM vpc_flow_logs_stream
WHERE vpc_flow_log = true
GROUP BY interface_id, action
ORDER BY total_bytes DESC
```

### Security Monitoring Use Cases

1. **DDoS Detection**: Identify unusual spikes in rejected traffic or connections from single sources
2. **Port Scanning**: Detect sources attempting connections to many different ports
3. **Data Exfiltration**: Monitor large outbound data transfers
4. **Unauthorized Access**: Track rejected connection attempts to sensitive ports
5. **Traffic Baseline**: Establish normal traffic patterns for anomaly detection

## Monitoring and Troubleshooting

### Verify Flow Logs are Being Created

```bash
# List flow logs for a VPC
aws ec2 describe-flow-logs --filter "Name=resource-id,Values=vpc-xxxxx"

# Check flow log status
aws ec2 describe-flow-logs --flow-log-ids fl-xxxxx
```

### Check Firehose Delivery Stream

```bash
# Get delivery stream metrics
aws firehose describe-delivery-stream \
  --delivery-stream-name vpc-flowlogs-firehose-xxxxx-to-openobserve

# Check for delivery errors
aws cloudwatch get-metric-statistics \
  --namespace AWS/Firehose \
  --metric-name DeliveryToHttpEndpoint.Success \
  --dimensions Name=DeliveryStreamName,Value=vpc-flowlogs-firehose-xxxxx-to-openobserve \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-01T23:59:59Z \
  --period 3600 \
  --statistics Sum
```

### View Lambda Transformation Logs

```bash
# Tail Lambda logs
aws logs tail /aws/lambda/vpc-flowlogs-firehose-xxxxx-flowlog-transformer --follow
```

### Check S3 Backup Bucket for Failed Records

```bash
# List failed records
aws s3 ls s3://vpc-flowlogs-backup-bucket/failed-flowlogs/ --recursive

# Download failed records for analysis
aws s3 sync s3://vpc-flowlogs-backup-bucket/failed-flowlogs/ ./failed-logs/
```

## Cost Considerations

### Option 1: Direct Firehose (Lower Cost)
- VPC Flow Logs: $0.50 per GB ingested
- Firehose: $0.029 per GB ingested
- Lambda: Minimal (transformation processing)
- S3: Storage for failed records only

### Option 2: CloudWatch Logs (Higher Cost)
- VPC Flow Logs: $0.50 per GB ingested
- CloudWatch Logs: $0.50 per GB ingested
- Kinesis Data Streams: $0.015 per shard-hour + $0.014 per million PUT requests
- Firehose: $0.029 per GB ingested
- Lambda: Minimal (transformation processing)
- S3: Storage for failed records only

**Cost Optimization Tips:**
1. Use `ACCEPT` or `REJECT` traffic type instead of `ALL` to reduce volume
2. Set appropriate CloudWatch Logs retention (Option 2)
3. Use S3 lifecycle policies to delete old backup logs
4. Monitor and adjust Kinesis shard count based on throughput (Option 2)

## Cleanup

```bash
# Run cleanup script
./cleanup.sh
```

The cleanup script will:
1. List all VPC Flow Logs stacks (prefix: `vpc-flowlogs-`)
2. Display stack details including VPC ID and resources
3. Prompt for stack selection (all or specific)
4. Empty S3 backup buckets before deletion
5. Delete CloudFormation stacks
6. Optionally remove orphaned VPC Flow Logs

### Manual Cleanup

```bash
# Delete stack
aws cloudformation delete-stack --stack-name vpc-flowlogs-firehose-xxxxx

# Wait for deletion
aws cloudformation wait stack-delete-complete --stack-name vpc-flowlogs-firehose-xxxxx

# Empty and delete S3 bucket
aws s3 rm s3://vpc-flowlogs-backup-bucket --recursive
aws s3 rb s3://vpc-flowlogs-backup-bucket

# Delete VPC Flow Log (if orphaned)
aws ec2 delete-flow-logs --flow-log-ids fl-xxxxx
```

## Architecture Comparison

### Direct Firehose (Option 1)
```
VPC Flow Logs
    ↓
Firehose (with Lambda transformation)
    ↓
OpenObserve

Backup: S3 (failed records only)
```

### CloudWatch Logs (Option 2)
```
VPC Flow Logs
    ↓
CloudWatch Logs
    ↓
Kinesis Data Streams
    ↓
Firehose (with Lambda transformation)
    ↓
OpenObserve

Backup: S3 (failed records only)
```

## Traffic Types

- **ALL**: Capture all network traffic (both accepted and rejected)
- **ACCEPT**: Capture only accepted traffic (successful connections)
- **REJECT**: Capture only rejected traffic (blocked by security groups or NACLs)

**Recommendation:** Start with `ALL` to get complete visibility, then adjust based on your monitoring needs and cost constraints.

## Best Practices

1. **Start Small**: Deploy to a single VPC first to validate the setup
2. **Monitor Costs**: Track ingestion volume and adjust traffic type if needed
3. **Set Retention Policies**: Configure appropriate CloudWatch and S3 retention
4. **Use Protocol Enrichment**: Leverage the built-in protocol name mapping for better analysis
5. **Create Dashboards**: Build OpenObserve dashboards for common use cases
6. **Set Alerts**: Configure alerts for security events (rejected traffic, port scans)
7. **Regular Review**: Periodically review flow log patterns and adjust filters

## References

- [OpenObserve VPC Flow Logs Guide](https://openobserve.ai/blog/how-to-capture-aws-vpc-flow-logs-and-analyze-them/)
- [AWS VPC Flow Logs Documentation](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html)
- [AWS Kinesis Firehose Documentation](https://docs.aws.amazon.com/firehose/latest/dev/what-is-this-service.html)
- [IANA Protocol Numbers](https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml)

## Support

For issues or questions:
1. Check CloudWatch Logs for Lambda errors
2. Verify OpenObserve endpoint and credentials
3. Review S3 backup bucket for failed records
4. Check AWS service quotas and limits
5. Consult OpenObserve documentation for stream configuration

## License

This solution is provided as-is for use with AWS and OpenObserve services.
