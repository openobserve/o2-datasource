# S3 Access Logs to OpenObserve

Monitor and analyze AWS S3 Access Logs using OpenObserve. This solution automatically processes S3 access logs and sends them to OpenObserve for analysis, alerting, and visualization.

## Architecture

```
S3 Bucket (Source)
    ↓ (Access Logging Enabled)
Destination S3 Bucket (Access Logs)
    ↓ (S3 Event Notification)
Lambda Function (Log Processor)
    ↓ (Parse & Transform)
Kinesis Firehose
    ↓ (HTTP Endpoint)
OpenObserve
```

### Components

1. **Source S3 Bucket**: The bucket you want to monitor (existing bucket)
2. **Destination S3 Bucket**: Receives S3 access logs from the source bucket
3. **Lambda Function**: Processes log files, parses space-delimited format, converts to JSON
4. **Kinesis Firehose**: Delivers logs to OpenObserve with buffering and retry logic
5. **Backup S3 Bucket**: Stores failed records for troubleshooting

## S3 Access Log Format

S3 Access Logs are written in a space-delimited format with quoted strings. Each log entry contains:

### Log Fields

| Field | Description | Example |
|-------|-------------|---------|
| bucket_owner | Canonical User ID of bucket owner | 79a59df900b949e55d96a1e698fbacedfd6e09d98eacf8f8d5218e7cd47ef2be |
| bucket | Bucket name | example-bucket |
| time | Request timestamp | [06/Feb/2019:00:00:38 +0000] |
| remote_ip | Client IP address | 192.0.2.3 |
| requester | IAM identity or AWS account | arn:aws:iam::123456789012:user/alice |
| request_id | Request ID | 3E57427F33A59F07 |
| operation | S3 operation | REST.GET.OBJECT |
| key | Object key | photos/2019/08/puppy.jpg |
| request_uri | Request URI | "GET /example-bucket/photos/2019/08/puppy.jpg HTTP/1.1" |
| http_status | HTTP status code | 200 |
| error_code | S3 error code | NoSuchKey, AccessDenied, etc. |
| bytes_sent | Bytes sent to client | 2662992 |
| object_size | Object size in bytes | 3462992 |
| total_time | Total request time (ms) | 70 |
| turn_around_time | Time from receipt to first byte (ms) | 10 |
| referer | HTTP Referer header | "http://www.example.com/page.html" |
| user_agent | HTTP User-Agent header | "curl/7.15.1" |
| version_id | Object version ID (if versioning enabled) | 3HL4kqtJvjVBH40Nrjfkd |
| host_id | S3 host ID for request | s9lzHYrFp76ZVxRcpX9+5cjAnEH2ROuNkd2BHfIa6UkFVdtjf5mKR3/eTPFvsiP/ |
| signature_version | Signature version | SigV4 |
| cipher_suite | SSL cipher suite | ECDHE-RSA-AES128-GCM-SHA256 |
| authentication_type | Authentication type | AuthHeader |
| host_header | Host header from request | s3.us-west-2.amazonaws.com |
| tls_version | TLS version | TLSv1.2 |
| access_point_arn | Access Point ARN (if used) | arn:aws:s3:us-west-2:123456789012:accesspoint/example |
| acl_required | Whether ACL was required | Yes/No |

### Sample Log Entry

```
79a59df900b949e55d96a1e698fbacedfd6e09d98eacf8f8d5218e7cd47ef2be example-bucket [06/Feb/2019:00:00:38 +0000] 192.0.2.3 arn:aws:iam::123456789012:user/alice 3E57427F33A59F07 REST.GET.OBJECT photos/2019/08/puppy.jpg "GET /example-bucket/photos/2019/08/puppy.jpg HTTP/1.1" 200 - 2662992 3462992 70 10 "http://www.example.com/page.html" "curl/7.15.1" - s9lzHYrFp76ZVxRcpX9+5cjAnEH2ROuNkd2BHfIa6UkFVdtjf5mKR3/eTPFvsiP/ SigV4 ECDHE-RSA-AES128-GCM-SHA256 AuthHeader s3.us-west-2.amazonaws.com TLSv1.2 - -
```

### Converted JSON Format

The Lambda function converts each log line to JSON:

```json
{
  "bucket_owner": "79a59df900b949e55d96a1e698fbacedfd6e09d98eacf8f8d5218e7cd47ef2be",
  "bucket": "example-bucket",
  "time": "06/Feb/2019:00:00:38 +0000",
  "timestamp": "2019-02-06T00:00:38Z",
  "remote_ip": "192.0.2.3",
  "requester": "arn:aws:iam::123456789012:user/alice",
  "request_id": "3E57427F33A59F07",
  "operation": "REST.GET.OBJECT",
  "key": "photos/2019/08/puppy.jpg",
  "request_uri": "GET /example-bucket/photos/2019/08/puppy.jpg HTTP/1.1",
  "http_status": 200,
  "error_code": "",
  "bytes_sent": 2662992,
  "object_size": 3462992,
  "total_time": 70,
  "turn_around_time": 10,
  "referer": "http://www.example.com/page.html",
  "user_agent": "curl/7.15.1",
  "version_id": "",
  "host_id": "s9lzHYrFp76ZVxRcpX9+5cjAnEH2ROuNkd2BHfIa6UkFVdtjf5mKR3/eTPFvsiP/",
  "signature_version": "SigV4",
  "cipher_suite": "ECDHE-RSA-AES128-GCM-SHA256",
  "authentication_type": "AuthHeader",
  "host_header": "s3.us-west-2.amazonaws.com",
  "tls_version": "TLSv1.2",
  "access_point_arn": "",
  "acl_required": ""
}
```

## Common S3 Operations

| Operation | Description |
|-----------|-------------|
| REST.GET.OBJECT | Download object |
| REST.PUT.OBJECT | Upload object |
| REST.DELETE.OBJECT | Delete object |
| REST.HEAD.OBJECT | Get object metadata |
| REST.POST.OBJECT | Upload object via POST |
| REST.COPY.OBJECT | Copy object |
| REST.GET.BUCKET | List bucket objects |
| REST.GET.BUCKETVERSIONS | List object versions |
| REST.GET.ACL | Get object/bucket ACL |
| REST.PUT.ACL | Set object/bucket ACL |

## Prerequisites

- AWS CLI installed and configured
- AWS account with permissions to create CloudFormation stacks
- OpenObserve instance with API endpoint and access key
- Existing S3 bucket to monitor

## Quick Start

### 1. Deploy the Stack

```bash
./deploy.sh
```

The script will:
1. List all S3 buckets in your account
2. Prompt you to select a bucket to monitor
3. Generate unique bucket names for logs and backups
4. Create CloudFormation stack with all resources
5. Automatically enable S3 access logging on the source bucket

### 2. Monitor Logs

After deployment, S3 access logs will be automatically processed and sent to OpenObserve.

**Important**: S3 Access Logs have eventual consistency and may take **several hours** to appear.

## Manual Deployment

### Step 1: Configure Parameters

Edit the CloudFormation template parameters:

```bash
aws cloudformation create-stack \
  --stack-name s3-access-logs-my-bucket \
  --template-body file://s3-access-logs-to-openobserve.yaml \
  --parameters \
    ParameterKey=OpenObserveEndpoint,ParameterValue="https://api.openobserve.ai/api/your-org/default/_kinesis" \
    ParameterKey=OpenObserveAccessKey,ParameterValue="your-base64-encoded-key" \
    ParameterKey=StreamName,ParameterValue="s3-access-logs" \
    ParameterKey=SourceBucketName,ParameterValue="my-bucket" \
    ParameterKey=LogDestinationBucketName,ParameterValue="s3-access-logs-my-bucket-12345" \
    ParameterKey=BackupS3BucketName,ParameterValue="s3-backup-my-bucket-12345" \
    ParameterKey=LogPrefix,ParameterValue="s3-access-logs/" \
  --capabilities CAPABILITY_IAM
```

### Step 2: Enable S3 Access Logging

After the stack is created, enable access logging on your source bucket:

```bash
aws s3api put-bucket-logging \
  --bucket my-bucket \
  --bucket-logging-status '{
    "LoggingEnabled": {
      "TargetBucket": "s3-access-logs-my-bucket-12345",
      "TargetPrefix": "s3-access-logs/"
    }
  }'
```

### Step 3: Verify Configuration

```bash
# Check logging configuration
aws s3api get-bucket-logging --bucket my-bucket

# Monitor Lambda logs
aws logs tail /aws/lambda/s3-access-logs-my-bucket-log-processor --follow
```

## How S3 Access Logging Works

### Enabling S3 Access Logging

S3 Access Logging must be explicitly enabled on each bucket:

1. **Target Bucket**: Specify where logs should be written
2. **Log Prefix**: Optional prefix for log objects
3. **Permissions**: Target bucket must have appropriate bucket policy

### Log Delivery

- **Best-Effort Delivery**: S3 access logging is best-effort, not guaranteed
- **Eventual Consistency**: Logs may take hours to appear
- **Periodic Delivery**: Logs are written periodically (typically every few hours)
- **Multiple Log Files**: S3 may create multiple log files per delivery
- **No Real-Time**: Not suitable for real-time monitoring

### Log File Naming

S3 generates log files with this naming pattern:

```
TargetPrefix/YYYY-MM-DD-HH-MM-SS-UniqueString/
```

Example:
```
s3-access-logs/2024-01-15-12-30-45-1234567890ABCDEF/
```

## Use Cases

### 1. Access Pattern Analysis

Track how users access your S3 buckets:

```sql
-- Most downloaded objects
SELECT key, COUNT(*) as downloads, SUM(bytes_sent) as total_bytes
FROM s3_access_logs
WHERE operation = 'REST.GET.OBJECT' AND http_status = 200
GROUP BY key
ORDER BY downloads DESC
LIMIT 100
```

### 2. Security Monitoring

Detect unauthorized access attempts:

```sql
-- Failed access attempts
SELECT remote_ip, requester, operation, key, error_code, COUNT(*) as attempts
FROM s3_access_logs
WHERE http_status >= 400
GROUP BY remote_ip, requester, operation, key, error_code
ORDER BY attempts DESC
```

### 3. Cost Analysis

Analyze data transfer costs:

```sql
-- Data transfer by IP
SELECT remote_ip,
       COUNT(*) as requests,
       SUM(bytes_sent) as total_bytes,
       SUM(bytes_sent) / 1024 / 1024 / 1024 as total_gb
FROM s3_access_logs
WHERE operation = 'REST.GET.OBJECT'
GROUP BY remote_ip
ORDER BY total_bytes DESC
```

### 4. Performance Analysis

Identify slow requests:

```sql
-- Slowest requests
SELECT operation, key, total_time, object_size, remote_ip
FROM s3_access_logs
WHERE total_time > 1000  -- More than 1 second
ORDER BY total_time DESC
LIMIT 100
```

### 5. User Agent Analysis

Track client applications:

```sql
-- Top user agents
SELECT user_agent, COUNT(*) as requests
FROM s3_access_logs
GROUP BY user_agent
ORDER BY requests DESC
LIMIT 20
```

### 6. Security: Detect Suspicious Activity

```sql
-- Multiple failed requests from same IP
SELECT remote_ip,
       COUNT(*) as failed_requests,
       ARRAY_AGG(DISTINCT error_code) as error_codes
FROM s3_access_logs
WHERE http_status >= 400
GROUP BY remote_ip
HAVING COUNT(*) > 10
ORDER BY failed_requests DESC
```

### 7. Compliance: Track Object Deletions

```sql
-- Track all DELETE operations
SELECT timestamp, requester, bucket, key, http_status
FROM s3_access_logs
WHERE operation = 'REST.DELETE.OBJECT'
ORDER BY timestamp DESC
```

## Cost Optimization

### Lifecycle Policies

The template includes automatic lifecycle policies:

- **90 days**: Logs expire and are deleted
- **30 days**: Logs transition to STANDARD_IA (cheaper storage)
- **Backup bucket**: Failed records deleted after 30 days

### Estimated Costs

Monthly costs for typical usage:

| Component | Cost (per bucket) |
|-----------|-------------------|
| S3 Storage (logs) | $0.50 - $5 |
| Lambda Executions | $0.20 - $2 |
| Firehose Delivery | $0.30 - $3 |
| **Total** | **~$1 - $10/month** |

Costs depend on:
- Request volume to your S3 bucket
- Log retention period
- Number of log files generated

### Cost Reduction Tips

1. **Increase log prefix specificity**: Only log specific paths
2. **Reduce retention**: Lower lifecycle expiration days
3. **Sample logs**: Only process a percentage of log files
4. **Batch processing**: Increase Lambda batch size

## Monitoring and Troubleshooting

### Check S3 Access Logging Status

```bash
# Verify logging is enabled
aws s3api get-bucket-logging --bucket your-bucket-name
```

Expected output:
```json
{
    "LoggingEnabled": {
        "TargetBucket": "s3-access-logs-your-bucket-12345",
        "TargetPrefix": "s3-access-logs/"
    }
}
```

### Monitor Lambda Processing

```bash
# Tail Lambda logs in real-time
aws logs tail /aws/lambda/s3-access-logs-your-bucket-log-processor --follow

# Get recent errors
aws logs filter-log-events \
  --log-group-name /aws/lambda/s3-access-logs-your-bucket-log-processor \
  --filter-pattern "ERROR"
```

### Check Firehose Delivery

```bash
# Describe Firehose stream
aws firehose describe-delivery-stream \
  --delivery-stream-name s3-access-logs-your-bucket-to-openobserve

# Check CloudWatch metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/Firehose \
  --metric-name DeliveryToHttpEndpoint.Success \
  --dimensions Name=DeliveryStreamName,Value=s3-access-logs-your-bucket-to-openobserve \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

### List Access Log Files

```bash
# List all log files
aws s3 ls s3://s3-access-logs-your-bucket-12345/s3-access-logs/ --recursive

# Count log files
aws s3 ls s3://s3-access-logs-your-bucket-12345/s3-access-logs/ --recursive | wc -l
```

### Check Failed Records

```bash
# List failed records in backup bucket
aws s3 ls s3://s3-backup-your-bucket-12345/failed-logs/ --recursive

# Download and inspect failed record
aws s3 cp s3://s3-backup-your-bucket-12345/failed-logs/2024/01/15/record.gz - | gunzip
```

### Common Issues

#### 1. Logs Not Appearing

**Symptom**: No logs in destination bucket after several hours

**Solutions**:
- S3 access logs have eventual consistency (wait up to 24 hours)
- Verify logging is enabled: `aws s3api get-bucket-logging --bucket your-bucket`
- Check bucket policy allows S3 logging service to write
- Ensure source bucket is receiving requests

#### 2. Lambda Not Triggering

**Symptom**: Log files appear but Lambda doesn't process them

**Solutions**:
- Check S3 event notification is configured correctly
- Verify Lambda has permissions to be invoked by S3
- Check Lambda execution role has S3 read permissions
- Review CloudWatch logs for Lambda errors

#### 3. Parse Errors

**Symptom**: Lambda shows parse errors in CloudWatch logs

**Solutions**:
- S3 access log format may vary slightly
- Download sample log and test regex pattern
- Update Lambda parsing logic if needed
- Some log lines may be incomplete (normal, skip them)

#### 4. Firehose Delivery Failures

**Symptom**: Records in backup bucket (failed deliveries)

**Solutions**:
- Verify OpenObserve endpoint is accessible
- Check OpenObserve access key is correct
- Review Firehose CloudWatch logs
- Inspect failed records for formatting issues

#### 5. High Lambda Costs

**Symptom**: Unexpected Lambda charges

**Solutions**:
- Many small log files increase invocations
- Consider batching multiple files
- Increase Lambda memory for faster processing
- Review lifecycle policies to delete logs sooner

## Security Best Practices

### 1. Least Privilege IAM

The CloudFormation template follows least privilege:
- Lambda only reads from log bucket
- Firehose only writes to backup bucket
- No public access on any buckets

### 2. Encryption

All buckets use encryption:
- **S3 Server-Side Encryption**: AES256
- **Firehose**: GZIP compression for data in transit

### 3. Access Control

- **Block Public Access**: Enabled on all buckets
- **Bucket Policies**: Restrict to specific AWS services
- **IAM Roles**: Use roles, not IAM users

### 4. Monitoring

Set up CloudWatch alarms for:
- High error rates in Lambda
- Firehose delivery failures
- Unusual access patterns in S3

### 5. Log Retention

- Don't retain logs longer than needed
- Use lifecycle policies to auto-delete
- Archive to Glacier for long-term storage

## Advanced Configuration

### Custom Log Prefix

Filter logs to specific paths:

```bash
# Only log access to /images/* objects
ParameterKey=LogPrefix,ParameterValue="s3-access-logs/images/"
```

### Multiple Buckets

Deploy separate stacks for each bucket:

```bash
./deploy.sh  # Select bucket-1
./deploy.sh  # Select bucket-2
```

Stack naming convention: `s3-access-logs-{bucket-name}`

### Cross-Account Logging

Enable logging to bucket in different account:

1. Update bucket policy in destination account
2. Specify destination bucket in different account
3. Use cross-account IAM role for Lambda

### CloudWatch Alarms

Create alarms for monitoring:

```bash
# Alert on Lambda errors
aws cloudwatch put-metric-alarm \
  --alarm-name s3-access-logs-lambda-errors \
  --alarm-description "Alert on Lambda processing errors" \
  --metric-name Errors \
  --namespace AWS/Lambda \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 5 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=FunctionName,Value=s3-access-logs-your-bucket-log-processor
```

## Cleanup

### Using Cleanup Script

```bash
./cleanup.sh
```

The script will:
1. Find all `s3-access-logs-*` stacks
2. Show resources to be deleted
3. Optionally disable S3 access logging on source bucket
4. Empty all S3 buckets
5. Delete CloudFormation stack

### Manual Cleanup

```bash
# Disable S3 access logging
aws s3api put-bucket-logging \
  --bucket your-bucket \
  --bucket-logging-status {}

# Empty buckets
aws s3 rm s3://s3-access-logs-your-bucket-12345 --recursive
aws s3 rm s3://s3-backup-your-bucket-12345 --recursive

# Delete stack
aws cloudformation delete-stack --stack-name s3-access-logs-your-bucket

# Wait for deletion
aws cloudformation wait stack-delete-complete --stack-name s3-access-logs-your-bucket
```

## Comparison: S3 Access Logs vs CloudTrail

| Feature | S3 Access Logs | CloudTrail Data Events |
|---------|----------------|------------------------|
| **Delivery Time** | Hours (eventual) | 5-15 minutes |
| **Completeness** | Best-effort | Guaranteed |
| **Cost** | Very low (~$1/month) | Higher (~$0.10 per 100k events) |
| **Detail Level** | HTTP-level details | API-level details |
| **Use Case** | Analytics, cost analysis | Compliance, auditing |
| **Object-level ops** | Yes | Yes |
| **Bucket-level ops** | Yes | Yes |

**Recommendation**:
- Use **S3 Access Logs** for cost-effective analytics and monitoring
- Use **CloudTrail** for compliance and real-time security monitoring
- Use **both** for comprehensive coverage

## References

- [AWS S3 Access Logging Documentation](https://docs.aws.amazon.com/AmazonS3/latest/userguide/ServerLogs.html)
- [S3 Access Log Format](https://docs.aws.amazon.com/AmazonS3/latest/userguide/LogFormat.html)
- [Enabling S3 Access Logging](https://docs.aws.amazon.com/AmazonS3/latest/userguide/enable-server-access-logging.html)
- [OpenObserve Documentation](https://openobserve.ai/docs)

## Support

For issues or questions:
1. Check CloudWatch Logs for Lambda errors
2. Review CloudFormation events for stack issues
3. Verify S3 access logging is enabled
4. Check OpenObserve connectivity

## License

This solution is provided as-is for monitoring AWS S3 Access Logs with OpenObserve.
