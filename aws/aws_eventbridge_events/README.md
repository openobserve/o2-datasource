# EventBridge Events to OpenObserve - CloudFormation Template

Stream AWS EventBridge events to OpenObserve in near real-time using AWS CloudFormation with automated deployment scripts.

Monitor any AWS service events (EC2 state changes, S3 events, Lambda errors, custom applications, etc.) in one unified platform.

## Quick Start

### Using the Deploy Script (Recommended)

```bash
chmod +x deploy.sh
./deploy.sh
```

The script will:
1. Check prerequisites (AWS CLI, jq)
2. Validate AWS credentials
3. Show common event pattern examples
4. Prompt for event pattern selection or custom JSON
5. Suggest rule name based on pattern
6. Generate unique stack name automatically
7. Create all required resources
8. Configure EventBridge rule automatically

---

## Architecture

```
EventBridge Rule (any AWS service) → Kinesis Firehose → OpenObserve
                                            ↓
                                       S3 (Failed)
```

### Resources Created

1. **EventBridge Rule** - Captures events matching the pattern
2. **Kinesis Firehose** - Delivers events to OpenObserve with retry logic
3. **S3 Bucket** - Failed records backup (30-day retention)
4. **IAM Roles** - EventBridgeToFirehoseRole, FirehoseDeliveryRole

**Note:** Works with any AWS service that emits EventBridge events.

---

## Features

- ✅ **Near real-time streaming** (seconds delay)
- ✅ **Any AWS service** (EC2, S3, Lambda, RDS, ECS, etc.)
- ✅ **Custom application events** (your own event bus)
- ✅ **Flexible event patterns** (filter by source, detail-type, content)
- ✅ **Failed records backup** to S3
- ✅ **Built-in retry logic** via Firehose
- ✅ **Multi-rule support** (isolated stacks per rule)
- ✅ **Simple deployment** (one command)
- ✅ **Low cost** (~$15-20/month per rule)

---

## Common Event Patterns

The deploy script provides 10 common patterns. You can also create custom patterns.

### 1. All EC2 State Changes

**Use Case:** Monitor instance starts, stops, terminations

```json
{
  "source": ["aws.ec2"],
  "detail-type": ["EC2 Instance State-change Notification"]
}
```

**Stack name:** `eventbridge-ec2-state-changes`

**Events captured:**
- Instance running
- Instance stopped
- Instance terminated
- Instance pending

**Test:**
```bash
aws ec2 run-instances --image-id ami-xxxxx --instance-type t2.micro
aws ec2 stop-instances --instance-ids i-xxxxx
```

---

### 2. All AWS Events

**Use Case:** Comprehensive monitoring across all AWS services

```json
{
  "source": [{"prefix": "aws."}]
}
```

**Stack name:** `eventbridge-all-aws-events`

**Warning:** High volume! Use filtering in OpenObserve or more specific patterns.

**Events captured:**
- All EC2, S3, Lambda, RDS, ECS, etc. events
- Any AWS service that emits EventBridge events

---

### 3. S3 Object Created Events

**Use Case:** Monitor file uploads, trigger workflows

```json
{
  "source": ["aws.s3"],
  "detail-type": ["Object Created"]
}
```

**Stack name:** `eventbridge-s3-object-created`

**Events captured:**
- PutObject
- PostObject
- CopyObject
- CompleteMultipartUpload

**Note:** Requires S3 Event Notifications configured on bucket

---

### 4. Lambda Function Errors

**Use Case:** Track Lambda failures in real-time

```json
{
  "source": ["aws.lambda"],
  "detail-type": ["Lambda Function Execution State Change"],
  "detail": {
    "status": ["Failed"]
  }
}
```

**Stack name:** `eventbridge-lambda-errors`

**Events captured:**
- Function execution failures
- Timeout errors
- Runtime errors

---

### 5. Auto Scaling Events

**Use Case:** Monitor scaling activities

```json
{
  "source": ["aws.autoscaling"]
}
```

**Stack name:** `eventbridge-autoscaling-events`

**Events captured:**
- Scale up/down events
- Instance launch/termination
- Health check failures

---

### 6. ECS Task State Changes

**Use Case:** Monitor container deployments

```json
{
  "source": ["aws.ecs"],
  "detail-type": ["ECS Task State Change"]
}
```

**Stack name:** `eventbridge-ecs-task-changes`

**Events captured:**
- Task running
- Task stopped
- Task failed

---

### 7. CodePipeline State Changes

**Use Case:** Track CI/CD pipeline executions

```json
{
  "source": ["aws.codepipeline"],
  "detail-type": ["CodePipeline Pipeline Execution State Change"]
}
```

**Stack name:** `eventbridge-codepipeline-changes`

**Events captured:**
- Pipeline started
- Pipeline succeeded
- Pipeline failed
- Stage state changes

---

### 8. CloudTrail API Calls

**Use Case:** Audit AWS API usage (requires CloudTrail)

```json
{
  "source": ["aws.cloudtrail"],
  "detail-type": ["AWS API Call via CloudTrail"]
}
```

**Stack name:** `eventbridge-cloudtrail-api-calls`

**Events captured:**
- Any AWS API call logged by CloudTrail
- IAM actions
- S3 operations
- EC2 operations

**Note:** CloudTrail must be enabled and configured

---

### 9. RDS Database Events

**Use Case:** Monitor database state, failovers, backups

```json
{
  "source": ["aws.rds"]
}
```

**Stack name:** `eventbridge-rds-events`

**Events captured:**
- Database state changes
- Automated backups
- Failover events
- Maintenance events

---

### 10. Custom Application Events

**Use Case:** Your own application events

```json
{
  "source": ["custom.myapp"],
  "detail-type": ["order.placed"]
}
```

**Stack name:** `eventbridge-custom-app-events`

**Send custom events:**
```bash
aws events put-events --entries '[
  {
    "Source": "custom.myapp",
    "DetailType": "order.placed",
    "Detail": "{\"orderId\":\"12345\",\"amount\":99.99,\"customer\":\"john@example.com\"}"
  }
]'
```

---

## Advanced Event Patterns

### Multiple Sources

```json
{
  "source": ["aws.ec2", "aws.autoscaling", "aws.ecs"]
}
```

### Filter by Region

```json
{
  "source": ["aws.ec2"],
  "detail": {
    "region": ["us-east-1"]
  }
}
```

### Filter by Specific Instance IDs

```json
{
  "source": ["aws.ec2"],
  "detail-type": ["EC2 Instance State-change Notification"],
  "detail": {
    "instance-id": ["i-1234567890abcdef0", "i-0987654321fedcba0"]
  }
}
```

### Filter by Tags

```json
{
  "source": ["aws.ec2"],
  "detail": {
    "instance-id": [{
      "exists": true
    }],
    "tags": {
      "Environment": ["production"]
    }
  }
}
```

### HTTP Status Codes (API Gateway)

```json
{
  "source": ["aws.apigateway"],
  "detail": {
    "responseData": {
      "status": [{
        "numeric": [">=", 500]
      }]
    }
  }
}
```

### Complex Conditions

```json
{
  "source": ["aws.ec2"],
  "detail-type": ["EC2 Instance State-change Notification"],
  "detail": {
    "state": ["terminated", "stopped"],
    "region": ["us-east-1", "us-west-2"]
  }
}
```

See [EventBridge Pattern Reference](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-event-patterns.html)

---

## Multiple Rules Support

Deploy multiple EventBridge rules with isolated resources:

```bash
# Rule 1: EC2 events
./deploy.sh
# Select: 1 (EC2 state changes)
# Stack created: eventbridge-ec2-state-changes

# Rule 2: Lambda errors
./deploy.sh
# Select: 4 (Lambda errors)
# Stack created: eventbridge-lambda-errors

# Rule 3: Custom pattern
./deploy.sh
# Enter custom JSON pattern
# Stack created: eventbridge-custom-rule
```

### Stack Naming Convention

**Pattern:** `eventbridge-<RULE-NAME>`

**Examples:**
- `eventbridge-ec2-state-changes`
- `eventbridge-lambda-errors`
- `eventbridge-s3-object-created`
- `eventbridge-all-aws-events`

**Each deployment creates:**
- Dedicated CloudFormation stack
- Separate EventBridge rule
- Independent Firehose delivery stream
- Isolated S3 backup bucket
- Unique IAM roles

---

## Prerequisites

1. **AWS CLI** installed and configured
2. **jq** for JSON processing (`brew install jq` on macOS)
3. **OpenObserve** account (cloud or self-hosted)
4. **AWS Permissions:**
   - CloudFormation (create/update/delete stacks)
   - EventBridge (create rules, put events)
   - S3 (create buckets, put/get objects)
   - IAM (create/attach roles)
   - Kinesis Firehose (create delivery streams)

---

## Configuration

### Option 1: Edit deploy.sh (Lines 18-24)

```bash
OPENOBSERVE_ENDPOINT="https://api.openobserve.ai/api/YOUR-ORG/default/_kinesis_firehose"
OPENOBSERVE_ACCESS_KEY="BASE64_ENCODED_CREDENTIALS"
STREAM_NAME="eventbridge-events"
RULE_NAME=""  # Leave empty to prompt
EVENT_PATTERN=""  # Leave empty to prompt
AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-us-east-2}"
```

### Option 2: Use Environment Variables

```bash
export OPENOBSERVE_ENDPOINT="https://api.openobserve.ai/api/YOUR-ORG/default/_kinesis_firehose"
export OPENOBSERVE_ACCESS_KEY="BASE64_ENCODED_CREDENTIALS"
export STREAM_NAME="eventbridge-events"
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
| `StreamName` | OpenObserve stream name | `eventbridge-events` | No |
| `RuleName` | EventBridge rule name | - | Yes |
| `EventPattern` | Event pattern JSON | - | Yes |
| `BackupS3BucketName` | S3 bucket for failed records (unique) | Auto-generated | Yes |

---

## Manual Deployment

```bash
aws cloudformation create-stack \
  --stack-name eventbridge-ec2-state-changes \
  --template-body file://eventbridge-to-openobserve.yaml \
  --parameters \
    ParameterKey=OpenObserveEndpoint,ParameterValue="https://api.openobserve.ai/..." \
    ParameterKey=OpenObserveAccessKey,ParameterValue="BASE64_KEY" \
    ParameterKey=StreamName,ParameterValue="eventbridge-events" \
    ParameterKey=RuleName,ParameterValue="ec2-state-changes" \
    ParameterKey=EventPattern,ParameterValue='{"source":["aws.ec2"],"detail-type":["EC2 Instance State-change Notification"]}' \
    ParameterKey=BackupS3BucketName,ParameterValue="eventbridge-backup-12345" \
  --capabilities CAPABILITY_IAM \
  --region us-east-2
```

---

## Cost Breakdown

### Per EventBridge Rule

| Resource | Monthly Cost |
|----------|--------------|
| EventBridge (first 1M events) | Free |
| Kinesis Firehose | ~$15 |
| S3 backup storage | ~$0.50 |
| **Total** | **~$15-20/month** |

### Multiple Rules

| Rules | Est. Monthly Cost |
|-------|-------------------|
| 1 | ~$15-20 |
| 3 | ~$45-60 |
| 5 | ~$75-100 |
| 10 | ~$150-200 |

### Cost Optimization Tips

1. **Use specific patterns** - Avoid capturing all events
2. **Set S3 lifecycle** - Delete old backups (already configured for 30 days)
3. **Increase buffer size** - Reduce Firehose requests (adjust in template)
4. **Monitor usage** - Check EventBridge and Firehose metrics

**Free Tier Benefits:**
- EventBridge: First 1 million events/month free (always)
- S3: 5GB free for first 12 months

---

## Testing

### Test EC2 Events

```bash
# Create test instance
aws ec2 run-instances \
  --image-id ami-0c55b159cbfafe1f0 \
  --instance-type t2.micro \
  --count 1

# Get instance ID from output
INSTANCE_ID="i-xxxxx"

# Stop instance (triggers event)
aws ec2 stop-instances --instance-ids $INSTANCE_ID

# Terminate instance (triggers event)
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
```

### Send Custom Events

```bash
aws events put-events --entries '[
  {
    "Source": "custom.myapp",
    "DetailType": "order.placed",
    "Detail": "{\"orderId\":\"12345\",\"amount\":99.99,\"customer\":\"john@example.com\",\"items\":[{\"product\":\"Widget\",\"quantity\":2}]}"
  }
]'
```

### Verify Events in OpenObserve

Events should appear within seconds in your OpenObserve stream!

---

## Monitoring

### List All Deployed Stacks

```bash
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE \
  --query 'StackSummaries[?starts_with(StackName, `eventbridge-`)].{Name:StackName,Status:StackStatus,Created:CreationTime}' \
  --output table
```

### Check EventBridge Rule Status

```bash
aws events describe-rule --name ec2-state-changes
```

### List Rule Targets

```bash
aws events list-targets-by-rule --rule ec2-state-changes
```

### Monitor Firehose Delivery

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Firehose \
  --metric-name DeliveryToHttpEndpoint.Success \
  --dimensions Name=DeliveryStreamName,Value=eventbridge-ec2-state-changes-to-openobserve \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

### Check Failed Records

```bash
# Get backup bucket name from stack
BACKUP_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name eventbridge-ec2-state-changes \
  --query 'Stacks[0].Outputs[?OutputKey==`BackupS3BucketName`].OutputValue' \
  --output text)

# List failed records
aws s3 ls s3://$BACKUP_BUCKET/failed-events/ --recursive
```

### Monitor EventBridge Metrics

```bash
# Events matched by rule
aws cloudwatch get-metric-statistics \
  --namespace AWS/Events \
  --metric-name TriggeredRules \
  --dimensions Name=RuleName,Value=ec2-state-changes \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum

# Failed invocations
aws cloudwatch get-metric-statistics \
  --namespace AWS/Events \
  --metric-name FailedInvocations \
  --dimensions Name=RuleName,Value=ec2-state-changes \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

---

## Cleanup

### Using Cleanup Script (Recommended)

```bash
chmod +x cleanup.sh
./cleanup.sh
```

The script will:
1. Find all EventBridge stacks (searches for `eventbridge-*`)
2. Display resources to be deleted
3. Prompt for confirmation
4. Remove EventBridge rule targets
5. Empty S3 buckets
6. Delete CloudFormation stack
7. Check for orphaned rules

### Manual Cleanup

```bash
# List stack resources
aws cloudformation describe-stack-resources \
  --stack-name eventbridge-ec2-state-changes

# Empty S3 bucket
BACKUP_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name eventbridge-ec2-state-changes \
  --query 'Stacks[0].Outputs[?OutputKey==`BackupS3BucketName`].OutputValue' \
  --output text)
aws s3 rm s3://$BACKUP_BUCKET --recursive

# Delete stack
aws cloudformation delete-stack --stack-name eventbridge-ec2-state-changes

# Wait for completion
aws cloudformation wait stack-delete-complete --stack-name eventbridge-ec2-state-changes
```

---

## Troubleshooting

### No Events Appearing in OpenObserve

1. **Verify EventBridge rule exists:**
   ```bash
   aws events describe-rule --name ec2-state-changes
   ```

2. **Check rule targets:**
   ```bash
   aws events list-targets-by-rule --rule ec2-state-changes
   ```

3. **Verify events are being matched:**
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/Events \
     --metric-name TriggeredRules \
     --dimensions Name=RuleName,Value=ec2-state-changes \
     --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 60 \
     --statistics Sum
   ```

4. **Check Firehose delivery:**
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/Firehose \
     --metric-name DeliveryToHttpEndpoint.Success \
     --dimensions Name=DeliveryStreamName,Value=eventbridge-ec2-state-changes-to-openobserve \
     --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 300 \
     --statistics Sum
   ```

5. **Check failed records in S3:**
   ```bash
   aws s3 ls s3://$BACKUP_BUCKET/error-events/ --recursive
   ```

### Invalid Event Pattern Error

**Error:** `Parameter EventPattern is not valid`

**Solution:** Validate your JSON pattern:
```bash
echo '{"source":["aws.ec2"]}' | jq .
```

Make sure:
- Valid JSON syntax
- Proper quotes (double quotes for JSON)
- No trailing commas
- Follow [EventBridge pattern syntax](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-event-patterns.html)

### S3 Bucket Already Exists

**Error:** `Bucket already exists`

**Solution:** The script auto-generates unique bucket names with timestamps. If you see this error:
1. Check if there's an existing stack with same name
2. Delete the old stack first: `./cleanup.sh`
3. Redeploy: `./deploy.sh`

### EventBridge Rule Limit Exceeded

**Error:** `LimitExceededException: You have exceeded the maximum number of rules`

**Solution:**
- Default limit: 300 rules per region
- Request limit increase via AWS Support
- Consider combining rules with broader patterns

### Firehose Delivery Failures

Check failed records in S3:
```bash
aws s3 ls s3://$BACKUP_BUCKET/failed-events/ --recursive
aws s3 cp s3://$BACKUP_BUCKET/failed-events/... - | gunzip
```

Common causes:
- Invalid OpenObserve endpoint
- Incorrect access key
- Network connectivity issues
- OpenObserve quota exceeded

### High Costs

**Reduce event volume:**
1. Use more specific event patterns (filter by detail-type, source)
2. Filter by resource tags
3. Review what's generating excessive events
4. Increase Firehose buffer size to reduce requests

---

## Advanced Configuration

### Custom Firehose Buffering

Edit `eventbridge-to-openobserve.yaml`:

```yaml
BufferingHints:
  SizeInMBs: 5      # Increase to reduce requests (1-100 MB)
  IntervalInSeconds: 300  # Increase to reduce requests (60-900 seconds)
```

### Multiple OpenObserve Streams

**Same stream (aggregated events):**
```bash
export STREAM_NAME="eventbridge-events"
./deploy.sh  # Rule 1
./deploy.sh  # Rule 2
# All events go to same OpenObserve stream
```

**Separate streams (isolated):**
```bash
export STREAM_NAME="eventbridge-ec2"
./deploy.sh  # EC2 events

export STREAM_NAME="eventbridge-lambda"
./deploy.sh  # Lambda events
```

### Add Custom Headers

Edit the template to add headers:

```yaml
HttpParameters:
  HeaderParameters:
    X-Event-Source: 'aws-eventbridge'
    X-Rule-Name: !Ref RuleName
    X-Custom-Header: 'your-value'
```

### Update Existing Stack

```bash
aws cloudformation update-stack \
  --stack-name eventbridge-ec2-state-changes \
  --template-body file://eventbridge-to-openobserve.yaml \
  --parameters \
    ParameterKey=EventPattern,ParameterValue='{"source":["aws.ec2","aws.autoscaling"]}' \
    ParameterKey=OpenObserveEndpoint,UsePreviousValue=true \
    ParameterKey=OpenObserveAccessKey,UsePreviousValue=true \
    ParameterKey=StreamName,UsePreviousValue=true \
    ParameterKey=RuleName,UsePreviousValue=true \
    ParameterKey=BackupS3BucketName,UsePreviousValue=true \
  --capabilities CAPABILITY_IAM
```

### Query Events in OpenObserve

Filter by rule name or event source:

```sql
-- All EC2 events
SELECT * FROM "eventbridge-events"
WHERE source = 'aws.ec2'

-- Failed Lambda executions
SELECT * FROM "eventbridge-events"
WHERE source = 'aws.lambda'
AND detail.status = 'Failed'

-- Events from specific rule
SELECT * FROM "eventbridge-events"
WHERE "X-Rule-Name" = 'ec2-state-changes'

-- Count events by source
SELECT source, COUNT(*) as count
FROM "eventbridge-events"
GROUP BY source
ORDER BY count DESC
```

---

## Use Cases

### Real-Time Security Monitoring

**Monitor unauthorized API calls:**
```json
{
  "source": ["aws.cloudtrail"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "errorCode": [{"exists": true}]
  }
}
```

### Application Deployment Tracking

**Track ECS deployments:**
```json
{
  "source": ["aws.ecs"],
  "detail-type": ["ECS Deployment State Change"]
}
```

### Cost Optimization Alerts

**Detect large EC2 instances:**
```json
{
  "source": ["aws.ec2"],
  "detail-type": ["EC2 Instance State-change Notification"],
  "detail": {
    "instance-type": [{"prefix": "m5."}]
  }
}
```

### Multi-Region Monitoring

Deploy to multiple regions:

```bash
# Deploy to us-east-1
export AWS_REGION="us-east-1"
./deploy.sh

# Deploy to us-west-2
export AWS_REGION="us-west-2"
./deploy.sh

# Same rule name, different regions
# All events go to same OpenObserve stream with region field
```

---

## Security Best Practices

1. **Use AWS Secrets Manager** for OpenObserve credentials
2. **Enable S3 encryption** at rest (already configured)
3. **Enable CloudTrail** to audit EventBridge activity
4. **Restrict IAM roles** to least privilege
5. **Use VPC endpoints** for Firehose if needed
6. **Rotate OpenObserve credentials** regularly
7. **Enable MFA** on AWS accounts
8. **Tag resources** for compliance tracking
9. **Monitor failed invocations** via CloudWatch

---

## How It Works

### Event Flow

1. **AWS service generates event** → EventBridge default bus
2. **EventBridge rule matches** → Filters events by pattern
3. **Rule triggers Firehose** → Sends matched events
4. **Firehose buffers** → Batches events for efficiency
5. **Firehose delivers** → HTTP POST to OpenObserve
6. **Failed records** → Backed up to S3 for retry

### Event Format

**EventBridge event structure:**
```json
{
  "version": "0",
  "id": "c7c4e8c1-1234-5678-9abc-def012345678",
  "detail-type": "EC2 Instance State-change Notification",
  "source": "aws.ec2",
  "account": "123456789012",
  "time": "2026-01-22T12:00:00Z",
  "region": "us-east-2",
  "resources": ["arn:aws:ec2:us-east-2:123456789012:instance/i-1234567890abcdef0"],
  "detail": {
    "instance-id": "i-1234567890abcdef0",
    "state": "running"
  }
}
```

This exact JSON is sent to OpenObserve (no transformation needed).

---

## Event Pattern Examples

### Filter by Account ID

```json
{
  "account": ["123456789012"]
}
```

### Filter by Time Range

```json
{
  "time": [{
    "hour": [9, 10, 11, 12, 13, 14, 15, 16, 17]
  }]
}
```

### Exclude Specific Events

```json
{
  "source": ["aws.ec2"],
  "detail-type": [{
    "anything-but": ["AWS API Call via CloudTrail"]
  }]
}
```

### Match Any of Multiple Values

```json
{
  "detail": {
    "state": ["running", "stopped", "terminated"]
  }
}
```

### Numeric Matching

```json
{
  "detail": {
    "duration": [{
      "numeric": [">", 1000]
    }]
  }
}
```

### Exists/Not Exists

```json
{
  "detail": {
    "errorCode": [{"exists": true}]
  }
}
```

---

## FAQ

**Q: Does EventBridge work with all AWS services?**
A: Yes! EventBridge receives events from 90+ AWS services automatically.

**Q: Can I capture events from custom applications?**
A: Yes! Use custom event bus or send to default bus with custom source.

**Q: What's the event delivery latency?**
A: Typically seconds. EventBridge → Firehose → OpenObserve is near real-time.

**Q: Can I filter events before sending to OpenObserve?**
A: Yes! Use EventBridge event patterns to filter at the source.

**Q: What happens to failed deliveries?**
A: Failed events are automatically backed up to S3 for 30 days.

**Q: Can I have multiple rules for the same event?**
A: Yes! Deploy multiple stacks with different patterns.

**Q: Does this work with custom event buses?**
A: Yes! Edit the template to specify custom event bus ARN.

**Q: Can I capture events from other AWS accounts?**
A: Yes! Configure cross-account EventBridge (requires additional setup).

**Q: What's the maximum event size?**
A: EventBridge supports up to 256 KB per event.

**Q: Can I transform events before sending?**
A: Not in this template, but you can add Lambda transformation in Firehose.

---

## Files

- `eventbridge-to-openobserve.yaml` - CloudFormation template
- `deploy.sh` - Interactive deployment script with pattern examples
- `cleanup.sh` - Automated resource cleanup script
- `README.md` - This documentation

---

## Support

- [AWS EventBridge Documentation](https://docs.aws.amazon.com/eventbridge/)
- [EventBridge Event Patterns](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-event-patterns.html)
- [OpenObserve Documentation](https://openobserve.ai/docs)
- [Kinesis Firehose](https://docs.aws.amazon.com/firehose/)
- [AWS Service Events](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-service-event.html)

---

## Summary

✅ **Near real-time monitoring** - Events appear in OpenObserve within seconds
✅ **Any AWS service** - EC2, S3, Lambda, RDS, ECS, and 90+ more
✅ **Custom events** - Your own applications and workflows
✅ **Flexible filtering** - EventBridge patterns for precise control
✅ **Automated deployment** - `deploy.sh` with common patterns
✅ **Multi-rule support** - Isolated stack per rule
✅ **Low cost** - ~$15-20/month per rule
✅ **Easy cleanup** - `cleanup.sh` removes all resources
✅ **Production ready** - Security, monitoring, failover included
✅ **Scalable** - Deploy unlimited rules independently
