# CloudWatch Logs to OpenObserve - CloudFormation Template

Stream CloudWatch Logs to OpenObserve in near real-time using AWS CloudFormation with automated deployment scripts.

## Quick Start

### Using the Deploy Script (Recommended)

```bash
chmod +x deploy.sh
./deploy.sh
```

The script will:
1. Check prerequisites (AWS CLI, jq)
2. Validate AWS credentials
3. List available CloudWatch Log Groups
4. Prompt for log group name and filter pattern
5. Generate unique stack name automatically
6. Create all required resources
7. Configure subscription filter automatically

---

## Architecture

```
CloudWatch Logs (existing) → Subscription Filter → Kinesis Stream → Lambda → Firehose → OpenObserve
                                                                                  ↓
                                                                             S3 (Failed)
```

### Resources Created

1. **Kinesis Data Stream** - Real-time log streaming
2. **Lambda Function** - Gzip decompression & JSON transformation
3. **Kinesis Firehose** - Delivery to OpenObserve with retry logic
4. **S3 Bucket** - Failed records backup (30-day retention)
5. **Subscription Filter** - Connects existing log group to Kinesis
6. **IAM Roles** - CloudWatchLogsRole, LambdaExecutionRole, FirehoseDeliveryRole

**Note:** Does NOT create CloudWatch Log Group - uses your existing log groups.

---

## Features

- ✅ **Near real-time streaming** (seconds delay)
- ✅ **Automatic gzip decompression** from CloudWatch
- ✅ **JSON transformation** (CloudWatch → structured JSON)
- ✅ **Configurable log filtering** (reduce costs, stream relevant logs only)
- ✅ **Failed records backup** to S3
- ✅ **Built-in retry logic** via Firehose
- ✅ **Multi-log-group support** (isolated stacks per log group)
- ✅ **Works with existing log groups** (no creation, no retention changes)

---

## Multiple Log Groups Support

Deploy to multiple CloudWatch Log Groups with isolated resources:

```bash
# Log Group 1
./deploy.sh
# Enter: /aws/lambda/app1
# Stack created: cw-logs-aws-lambda-app1

# Log Group 2
./deploy.sh
# Enter: /aws/ecs/service1
# Stack created: cw-logs-aws-ecs-service1

# Log Group 3
./deploy.sh
# Enter: /aws/rds/cluster/my-db
# Stack created: cw-logs-aws-rds-cluster-my-db
```

### Stack Naming Convention

**Pattern:** `cw-logs-<LOG-GROUP-SLUG>`

**Conversion Examples:**
- `/aws/lambda/my-app` → `cw-logs-aws-lambda-my-app`
- `/aws/ecs/service1` → `cw-logs-aws-ecs-service1`
- `/aws/eks/common-dev/cluster` → `cw-logs-aws-eks-common-dev-cluster`
- `API-Gateway-Logs_abc/prod` → `cw-logs-api-gateway-logs-abc-prod`

**Each deployment creates:**
- Dedicated CloudFormation stack
- Separate Kinesis stream & Firehose
- Independent Lambda function
- Isolated S3 backup bucket
- Unique IAM roles

---

## Prerequisites

1. **AWS CLI** installed and configured
2. **jq** for JSON processing (`brew install jq` on macOS)
3. **OpenObserve** account (cloud or self-hosted)
4. **Existing CloudWatch Log Group** (script uses existing groups)
5. **AWS Permissions:**
   - CloudFormation (create/update/delete stacks)
   - CloudWatch Logs (describe log groups, create subscription filters)
   - S3 (create buckets, put/get objects)
   - Lambda (create functions)
   - IAM (create/attach roles)
   - Kinesis (create streams/firehose)

---

## Configuration

### Option 1: Edit deploy.sh (Lines 18-24)

```bash
OPENOBSERVE_ENDPOINT="https://api.openobserve.ai/api/YOUR-ORG/default/_kinesis_firehose"
OPENOBSERVE_ACCESS_KEY="BASE64_ENCODED_CREDENTIALS"
STREAM_NAME="cloudwatch-logs"
LOG_GROUP_NAME=""  # Leave empty to prompt
FILTER_PATTERN=""  # Leave empty to prompt
AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-us-east-2}"
```

### Option 2: Use Environment Variables

```bash
export OPENOBSERVE_ENDPOINT="https://api.openobserve.ai/api/YOUR-ORG/default/_kinesis_firehose"
export OPENOBSERVE_ACCESS_KEY="BASE64_ENCODED_CREDENTIALS"
export LOG_GROUP_NAME="/aws/lambda/my-app"
export FILTER_PATTERN=""
export STREAM_NAME="cloudwatch-logs"
export AWS_PROFILE="your-profile"
export AWS_REGION="us-east-2"

./deploy.sh
```

### Get OpenObserve Credentials

```bash
# Generate base64 access key
echo -n "your-email@example.com:your-password" | base64
```

---

## Parameters

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| `OpenObserveEndpoint` | OpenObserve HTTP endpoint URL | - | Yes |
| `OpenObserveAccessKey` | Base64 encoded credentials | - | Yes |
| `StreamName` | OpenObserve stream name | `cloudwatch-logs-stream` | No |
| `LogGroupName` | Existing CloudWatch Log Group name | - | Yes |
| `BackupS3BucketName` | S3 bucket for failed records (unique) | Auto-generated | Yes |
| `ShardCount` | Number of Kinesis shards (1-10) | `1` | No |
| `FilterPattern` | CloudWatch filter pattern | `""` (all logs) | No |

---

## Filter Patterns

Stream specific logs using CloudWatch Logs filter patterns:

```bash
# All logs (default)
FilterPattern=""

# Logs containing "ERROR"
FilterPattern="ERROR"

# Lambda REPORT lines only
FilterPattern="[report_type = REPORT]"

# Specific log level
FilterPattern="[..., level = ERROR]"

# HTTP 5xx errors
FilterPattern="[..., status_code >= 500]"

# JSON field filtering
FilterPattern='{ $.level = "ERROR" }'

# Multiple conditions
FilterPattern='[time, request_id, event_type = Error, message]'
```

See [AWS Filter Pattern Syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html)

---

## Manual Deployment

```bash
aws cloudformation create-stack \
  --stack-name cw-logs-aws-lambda-my-app \
  --template-body file://cloudwatch-logs-to-openobserve.yaml \
  --parameters \
    ParameterKey=OpenObserveEndpoint,ParameterValue="https://api.openobserve.ai/..." \
    ParameterKey=OpenObserveAccessKey,ParameterValue="BASE64_KEY" \
    ParameterKey=StreamName,ParameterValue="cloudwatch-logs" \
    ParameterKey=LogGroupName,ParameterValue="/aws/lambda/my-app" \
    ParameterKey=BackupS3BucketName,ParameterValue="cw-backup-12345" \
    ParameterKey=ShardCount,ParameterValue="1" \
    ParameterKey=FilterPattern,ParameterValue="" \
  --capabilities CAPABILITY_IAM \
  --region us-east-2
```

---

## Cost Breakdown

### Per Log Group (~1GB/day logs)

| Resource | Monthly Cost |
|----------|--------------|
| Kinesis Data Stream (1 shard) | ~$30 |
| Kinesis Firehose | ~$15 |
| Lambda invocations | ~$2 |
| S3 backup storage | ~$0.50 |
| **Total** | **~$47/month** |

### Multiple Log Groups

| Log Groups | Est. Monthly Cost |
|------------|-------------------|
| 1 | ~$47 |
| 3 | ~$141 |
| 5 | ~$235 |
| 10 | ~$470 |

### Cost Optimization Tips

1. **Use filter patterns** - Stream only ERROR/WARN logs
2. **Reduce shard count** - Use 1 shard for most workloads
3. **Set log retention** - Delete old logs from CloudWatch:
   ```bash
   aws logs put-retention-policy \
     --log-group-name /aws/lambda/my-app \
     --retention-in-days 7
   ```
4. **Adjust buffering** - Increase Firehose buffer size to reduce requests

---

## Common Use Cases

### Lambda Function Logs

```bash
export LOG_GROUP_NAME="/aws/lambda/my-function"
export FILTER_PATTERN="[report_type = REPORT]"
./deploy.sh
```

### ECS Service Logs

```bash
export LOG_GROUP_NAME="/aws/ecs/my-service"
export FILTER_PATTERN='{ $.level = "ERROR" || $.level = "WARN" }'
./deploy.sh
```

### API Gateway Access Logs

```bash
export LOG_GROUP_NAME="API-Gateway-Execution-Logs_abc123/prod"
export FILTER_PATTERN="[..., status >= 400]"
./deploy.sh
```

### EKS Cluster Logs

```bash
export LOG_GROUP_NAME="/aws/eks/my-cluster/cluster"
export FILTER_PATTERN=""  # All logs
./deploy.sh
```

### RDS Database Logs

```bash
export LOG_GROUP_NAME="/aws/rds/cluster/my-db/error"
export FILTER_PATTERN=""  # All logs
./deploy.sh
```

### Custom Application Logs

```bash
export LOG_GROUP_NAME="/aws/application/my-app"
export FILTER_PATTERN='{ $.severity = "error" }'
./deploy.sh
```

---

## Monitoring

### List All Deployed Stacks

```bash
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE \
  --query 'StackSummaries[?starts_with(StackName, `cw-logs-`)].{Name:StackName,Status:StackStatus,Created:CreationTime}' \
  --output table
```

### Check Lambda Transformation Logs

```bash
# Replace with your stack name
aws logs tail /aws/lambda/cw-logs-aws-lambda-my-app-log-transformer --follow
```

### Check Subscription Filter Status

```bash
aws logs describe-subscription-filters \
  --log-group-name /aws/lambda/my-app
```

### Monitor Kinesis Stream

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name IncomingRecords \
  --dimensions Name=StreamName,Value=cw-logs-aws-lambda-my-app-cloudwatch-logs \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

### Monitor Firehose Delivery

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Firehose \
  --metric-name DeliveryToHttpEndpoint.Success \
  --dimensions Name=DeliveryStreamName,Value=cw-logs-aws-lambda-my-app-to-openobserve \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

### Check Failed Records

```bash
# Get backup bucket name from stack
BACKUP_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name cw-logs-aws-lambda-my-app \
  --query 'Stacks[0].Outputs[?OutputKey==`BackupS3BucketName`].OutputValue' \
  --output text)

# List failed records
aws s3 ls s3://$BACKUP_BUCKET/failed-logs/ --recursive
```

---

## Testing

### Send Test Logs

```bash
# Create log stream if it doesn't exist
aws logs create-log-stream \
  --log-group-name /aws/lambda/my-app \
  --log-stream-name test-stream

# Send test log event
aws logs put-log-events \
  --log-group-name /aws/lambda/my-app \
  --log-stream-name test-stream \
  --log-events timestamp=$(date +%s)000,message="Test log from CloudWatch"
```

Logs should appear in OpenObserve within seconds!

---

## Cleanup

### Using Cleanup Script (Recommended)

```bash
chmod +x cleanup.sh
./cleanup.sh
```

The script will:
1. Find all CloudWatch Logs stacks (searches for `cw-logs-*` and `cloudwatch-logs*`)
2. Display resources to be deleted
3. Prompt for confirmation
4. Remove subscription filters automatically
5. Empty S3 buckets
6. Delete CloudFormation stack
7. Check for orphaned Lambda log groups

### Manual Cleanup

```bash
# List stack resources
aws cloudformation describe-stack-resources \
  --stack-name cw-logs-aws-lambda-my-app

# Empty S3 bucket
BACKUP_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name cw-logs-aws-lambda-my-app \
  --query 'Stacks[0].Outputs[?OutputKey==`BackupS3BucketName`].OutputValue' \
  --output text)
aws s3 rm s3://$BACKUP_BUCKET --recursive

# Delete stack
aws cloudformation delete-stack --stack-name cw-logs-aws-lambda-my-app

# Wait for completion
aws cloudformation wait stack-delete-complete --stack-name cw-logs-aws-lambda-my-app
```

---

## Troubleshooting

### Stack Creation Failed: "LogGroup already exists"

**Cause:** Previous versions of the template tried to create the log group.

**Solution:** Use the updated template (it now uses existing log groups instead of creating them).

If you see this error:
```
Resource handler returned message: "Resource of type 'AWS::Logs::LogGroup'
with identifier '/aws/lambda/my-app' already exists."
```

The template has been fixed - just delete the failed stack and redeploy:
```bash
aws cloudformation delete-stack --stack-name <failed-stack-name>
./deploy.sh  # Run again
```

### No Logs Appearing in OpenObserve

1. **Verify subscription filter exists:**
   ```bash
   aws logs describe-subscription-filters \
     --log-group-name /aws/lambda/my-app
   ```

2. **Check Kinesis is receiving data:**
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/Kinesis \
     --metric-name IncomingRecords \
     --dimensions Name=StreamName,Value=<your-stream-name> \
     --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 60 \
     --statistics Sum
   ```

3. **Check Lambda transformation logs:**
   ```bash
   aws logs tail /aws/lambda/cw-logs-aws-lambda-my-app-log-transformer --since 30m
   ```

4. **Check Firehose delivery metrics:**
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/Firehose \
     --metric-name DeliveryToHttpEndpoint.Success \
     --dimensions Name=DeliveryStreamName,Value=<your-firehose-name> \
     --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 300 \
     --statistics Sum
   ```

5. **Check failed records in S3:**
   ```bash
   aws s3 ls s3://<backup-bucket>/error-logs/ --recursive
   ```

### Lambda Timeout Errors

If processing large batches of logs, increase Lambda timeout:

```yaml
# Edit cloudwatch-logs-to-openobserve.yaml
Timeout: 120  # Increase from 60
MemorySize: 512  # Increase from 256
```

Then update the stack:
```bash
aws cloudformation update-stack \
  --stack-name cw-logs-aws-lambda-my-app \
  --template-body file://cloudwatch-logs-to-openobserve.yaml \
  --parameters ParameterKey=OpenObserveEndpoint,UsePreviousValue=true \
               ... (all other parameters with UsePreviousValue=true) \
  --capabilities CAPABILITY_IAM
```

### High Costs

**Reduce log volume:**
1. Use filter patterns to stream only ERROR/WARN logs
2. Set CloudWatch log retention to 7 days:
   ```bash
   aws logs put-retention-policy \
     --log-group-name /aws/lambda/my-app \
     --retention-in-days 7
   ```
3. Lower Kinesis shard count if throughput is low
4. Review what's generating excessive logs

### Permission Errors

```bash
# Check IAM roles
aws iam get-role --role-name cw-logs-aws-lambda-my-app-LambdaExecutionRole
aws iam list-role-policies --role-name cw-logs-aws-lambda-my-app-LambdaExecutionRole

# Check subscription filter permissions
aws logs describe-subscription-filters --log-group-name /aws/lambda/my-app
```

### Subscription Limit Exceeded

CloudWatch Log Groups can have **only 1 subscription filter**.

**Error:** `LimitExceededException: Resource limit exceeded`

**Solution:**
1. Check existing filters:
   ```bash
   aws logs describe-subscription-filters --log-group-name /aws/lambda/my-app
   ```
2. Delete old filter:
   ```bash
   aws logs delete-subscription-filter \
     --log-group-name /aws/lambda/my-app \
     --filter-name <old-filter-name>
   ```
3. Redeploy with `./deploy.sh`

---

## Advanced Configuration

### Custom Lambda Transformation

Edit the Lambda code in `cloudwatch-logs-to-openobserve.yaml` to add custom fields:

```python
transformed = {
    'timestamp': event.get('timestamp'),
    'message': event.get('message'),
    'logGroup': log_group,
    'logStream': log_stream,
    'id': event.get('id'),
    # Add custom fields
    'environment': 'production',
    'team': 'platform',
    'cost_center': '12345',
    'region': 'us-east-2'
}
```

### Multiple OpenObserve Streams

**Same stream (aggregated logs):**
```bash
export STREAM_NAME="cloudwatch-logs"
./deploy.sh  # Log group 1
./deploy.sh  # Log group 2
# All logs go to same OpenObserve stream
```

**Separate streams (isolated):**
```bash
export STREAM_NAME="cloudwatch-logs-prod"
export LOG_GROUP_NAME="/aws/lambda/prod-app"
./deploy.sh

export STREAM_NAME="cloudwatch-logs-staging"
export LOG_GROUP_NAME="/aws/lambda/staging-app"
./deploy.sh
```

### Update Existing Stack

```bash
aws cloudformation update-stack \
  --stack-name cw-logs-aws-lambda-my-app \
  --template-body file://cloudwatch-logs-to-openobserve.yaml \
  --parameters \
    ParameterKey=ShardCount,ParameterValue=2 \
    ParameterKey=FilterPattern,ParameterValue="ERROR" \
    ParameterKey=OpenObserveEndpoint,UsePreviousValue=true \
    ParameterKey=OpenObserveAccessKey,UsePreviousValue=true \
    ParameterKey=StreamName,UsePreviousValue=true \
    ParameterKey=LogGroupName,UsePreviousValue=true \
    ParameterKey=BackupS3BucketName,UsePreviousValue=true \
  --capabilities CAPABILITY_IAM \
  --region us-east-2
```

### Query Logs in OpenObserve

When using the same stream for multiple log groups, filter by `logGroup` field:

```sql
-- All ERROR logs from Lambda functions
SELECT * FROM "cloudwatch-logs"
WHERE logGroup LIKE '/aws/lambda/%'
AND message LIKE '%ERROR%'

-- Specific log group
SELECT * FROM "cloudwatch-logs"
WHERE logGroup = '/aws/lambda/my-app'

-- Multiple log groups
SELECT * FROM "cloudwatch-logs"
WHERE logGroup IN ('/aws/lambda/app1', '/aws/lambda/app2')
```

---

## Security Best Practices

1. **Use AWS Secrets Manager** for OpenObserve credentials instead of hardcoded values
2. **Enable S3 encryption** at rest (already configured in template)
3. **Enable CloudTrail** to audit access to log data
4. **Restrict IAM roles** to least privilege
5. **Use VPC endpoints** for Kinesis/Firehose if running in VPC
6. **Rotate OpenObserve credentials** regularly
7. **Set appropriate log retention** to minimize data exposure
8. **Enable MFA** on AWS accounts with CloudFormation permissions
9. **Tag resources** for cost allocation and compliance

---

## How It Works

### Log Flow

1. **Application writes logs** → CloudWatch Log Group
2. **Subscription filter** → Filters logs, sends to Kinesis (gzip compressed)
3. **Kinesis Stream** → Buffers logs for reliability
4. **Firehose reads** → Triggers Lambda for transformation
5. **Lambda function:**
   - Decodes base64
   - Decompresses gzip
   - Parses CloudWatch Logs JSON format
   - Transforms to structured JSON
   - Returns transformed records
6. **Firehose delivers** → Sends to OpenObserve HTTP endpoint
7. **Failed records** → Backed up to S3 for manual reprocessing

### JSON Transformation

**CloudWatch Logs format (gzip compressed):**
```json
{
  "messageType": "DATA_MESSAGE",
  "owner": "123456789012",
  "logGroup": "/aws/lambda/my-app",
  "logStream": "2026/01/21/[$LATEST]abc123",
  "subscriptionFilters": ["filter-name"],
  "logEvents": [
    {
      "id": "37...",
      "timestamp": 1737489600000,
      "message": "ERROR: Database connection failed"
    }
  ]
}
```

**After Lambda transformation (JSON):**
```json
{
  "timestamp": 1737489600000,
  "message": "ERROR: Database connection failed",
  "logGroup": "/aws/lambda/my-app",
  "logStream": "2026/01/21/[$LATEST]abc123",
  "id": "37..."
}
```

---

## FAQ

**Q: Does this create a new CloudWatch Log Group?**
A: No. The template uses your existing log groups. It only creates the subscription filter, Kinesis, Lambda, and S3 resources.

**Q: Can I stream logs from an existing log group?**
A: Yes! That's the recommended approach. The template works with existing log groups.

**Q: What if my log group already has a subscription filter?**
A: CloudWatch allows only 1 subscription filter per log group. You'll need to delete the existing one first.

**Q: Can logs be in JSON format?**
A: Yes! Lambda automatically decompresses gzip data from CloudWatch and converts to structured JSON before sending to OpenObserve.

**Q: Can I filter logs before sending?**
A: Yes! Use the `FilterPattern` parameter to stream only matching logs (e.g., ERROR logs only).

**Q: Can I share resources across log groups?**
A: Not recommended. Each log group gets isolated resources for easier management and troubleshooting.

**Q: What's the maximum number of log groups I can stream?**
A: AWS allows 200 CloudFormation stacks per region. Practically, cost (~$47/mo per log group) is the main limit.

**Q: How do I query logs from multiple log groups in OpenObserve?**
A: Use the same `STREAM_NAME` for all log groups, then filter by the `logGroup` field in queries.

**Q: What happens to failed log records?**
A: Failed records are automatically backed up to S3 (`error-logs/` prefix) for 30 days, then deleted.

**Q: Can I change the filter pattern after deployment?**
A: Yes! Update the stack with a new `FilterPattern` parameter value.

---

## Files

- `cloudwatch-logs-to-openobserve.yaml` - CloudFormation template
- `deploy.sh` - Interactive deployment script with multi-log-group support
- `cleanup.sh` - Automated resource cleanup script
- `README.md` - This documentation

---

## Support

- [AWS CloudFormation Documentation](https://docs.aws.amazon.com/cloudformation/)
- [OpenObserve Documentation](https://openobserve.ai/docs)
- [CloudWatch Logs Guide](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/)
- [Filter Pattern Syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html)
- [Kinesis Data Streams](https://docs.aws.amazon.com/kinesis/)

---

## Summary

✅ **Near real-time streaming** - Logs appear in OpenObserve within seconds
✅ **Uses existing log groups** - No creation, no retention changes
✅ **Automated deployment** - `deploy.sh` handles everything
✅ **Multi-log-group support** - Unique stack per log group
✅ **Auto JSON conversion** - Lambda transforms CloudWatch format
✅ **Filter support** - Stream only relevant logs to reduce costs
✅ **Easy cleanup** - `cleanup.sh` removes all resources safely
✅ **Production ready** - Security, monitoring, cost optimization included
✅ **Failed records backup** - S3 backup with 30-day retention
✅ **Scalable** - Deploy to unlimited log groups independently
