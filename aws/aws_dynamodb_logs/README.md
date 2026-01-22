# DynamoDB Streams to OpenObserve - CloudFormation Templates

Monitor DynamoDB table changes in real-time by streaming item-level modifications to OpenObserve using AWS CloudFormation.

## Quick Start

### Using the Deploy Script (Recommended)

```bash
chmod +x deploy.sh
./deploy.sh
```

The script will:
1. Prompt for deployment type (Kinesis-based or Lambda-based)
2. List available DynamoDB tables
3. Validate prerequisites and AWS credentials
4. Create unique stack with isolated resources
5. Enable DynamoDB Streams if not already enabled
6. Configure streaming to OpenObserve automatically

---

## Deployment Options

### Option 1: Kinesis-based (Recommended for Production)

**Architecture:**
```
DynamoDB Table → Kinesis Data Stream → Lambda → Firehose → OpenObserve
                                                     ↓
                                                S3 (Failed)
```

**Template:** `dynamodb-streams-to-openobserve.yaml`

**Features:**
- ✅ Higher throughput and scalability
- ✅ Kinesis Streaming Destination (AWS managed)
- ✅ Near real-time (seconds delay)
- ✅ Built-in buffering and retry
- ✅ Supports high-volume tables
- ❌ Higher cost (~$50/month per table)

**Best for:** Production tables, high-volume operations, mission-critical data

---

### Option 2: Lambda-based (Cost-effective)

**Architecture:**
```
DynamoDB Table → DynamoDB Streams → Lambda → Firehose → OpenObserve
                                                  ↓
                                             S3 (Failed)
```

**Template:** `dynamodb-streams-to-openobserve-lambda.yaml`

**Features:**
- ✅ Lower cost (~$25/month per table)
- ✅ Simpler setup (no Kinesis Stream)
- ✅ Native DynamoDB Streams integration
- ✅ Automatic retries and error handling
- ✅ Good for low-to-medium volume
- ❌ Cold start latency possible

**Best for:** Development tables, low-volume tables, cost-sensitive environments

---

## Multiple Tables Support

Deploy to multiple DynamoDB tables with isolated resources:

```bash
# Table 1
./deploy.sh
# Choose deployment type, enter: users-table
# Stack created: ddb-kinesis-users-table

# Table 2
./deploy.sh
# Choose deployment type, enter: orders-table
# Stack created: ddb-lambda-orders-table

# Table 3
./deploy.sh
# Choose deployment type, enter: products-table
# Stack created: ddb-kinesis-products-table
```

### Stack Naming Convention

**Pattern:**
- Kinesis-based: `ddb-kinesis-<TABLE-NAME-SLUG>`
- Lambda-based: `ddb-lambda-<TABLE-NAME-SLUG>`

**Examples:**
- `UsersTable` → `ddb-kinesis-userstable`
- `orders-prod` → `ddb-lambda-orders-prod`
- `Products_Dev` → `ddb-kinesis-products-dev`

**Each deployment creates:**
- Dedicated CloudFormation stack
- Separate Kinesis/Firehose streams (Kinesis option) or Lambda (Lambda option)
- Independent transformation function
- Isolated S3 backup bucket
- Unique IAM roles

---

## Prerequisites

1. **AWS CLI** installed and configured
2. **jq** for JSON processing (`brew install jq` on macOS)
3. **OpenObserve** account (cloud or self-hosted)
4. **Existing DynamoDB table** (script uses existing tables)
5. **AWS Permissions:**
   - CloudFormation (create/update/delete stacks)
   - DynamoDB (describe tables, update table, enable streams)
   - S3 (create buckets, put/get objects)
   - Lambda (create functions, event source mappings)
   - IAM (create/attach roles)
   - Kinesis (create streams/firehose) - for Kinesis option

---

## Configuration

### Option 1: Edit deploy.sh (Lines 18-24)

```bash
OPENOBSERVE_ENDPOINT="https://api.openobserve.ai/api/YOUR-ORG/default/_kinesis_firehose"
OPENOBSERVE_ACCESS_KEY="BASE64_ENCODED_CREDENTIALS"
STREAM_NAME="dynamodb-streams"
DYNAMODB_TABLE_NAME=""  # Leave empty to prompt
AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-us-east-2}"
```

### Option 2: Use Environment Variables

```bash
export OPENOBSERVE_ENDPOINT="https://api.openobserve.ai/api/YOUR-ORG/default/_kinesis_firehose"
export OPENOBSERVE_ACCESS_KEY="BASE64_ENCODED_CREDENTIALS"
export DYNAMODB_TABLE_NAME="my-table"
export STREAM_NAME="dynamodb-streams"
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

## DynamoDB Streams Overview

### What Gets Captured?

DynamoDB Streams capture **item-level modifications**:
- **INSERT** - New items added
- **MODIFY** - Existing items updated
- **REMOVE** - Items deleted

### Stream View Types

When enabling streams, you can choose:
- **KEYS_ONLY** - Only the key attributes
- **NEW_IMAGE** - The entire item after the change
- **OLD_IMAGE** - The entire item before the change
- **NEW_AND_OLD_IMAGES** - Both before and after (recommended)

Our templates use **NEW_AND_OLD_IMAGES** by default.

---

## Manual Deployment

### Kinesis-based

```bash
aws cloudformation create-stack \
  --stack-name ddb-kinesis-my-table \
  --template-body file://dynamodb-streams-to-openobserve.yaml \
  --parameters \
    ParameterKey=OpenObserveEndpoint,ParameterValue="https://api.openobserve.ai/..." \
    ParameterKey=OpenObserveAccessKey,ParameterValue="BASE64_KEY" \
    ParameterKey=StreamName,ParameterValue="dynamodb-streams" \
    ParameterKey=DynamoDBTableName,ParameterValue="my-table" \
    ParameterKey=BackupS3BucketName,ParameterValue="ddb-backup-12345" \
    ParameterKey=ShardCount,ParameterValue="1" \
  --capabilities CAPABILITY_IAM \
  --region us-east-2
```

### Lambda-based

```bash
# First, enable DynamoDB Streams
aws dynamodb update-table \
  --table-name my-table \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
  --region us-east-2

# Get stream ARN
STREAM_ARN=$(aws dynamodb describe-table \
  --table-name my-table \
  --query 'Table.LatestStreamArn' \
  --output text \
  --region us-east-2)

# Deploy stack
aws cloudformation create-stack \
  --stack-name ddb-lambda-my-table \
  --template-body file://dynamodb-streams-to-openobserve-lambda.yaml \
  --parameters \
    ParameterKey=OpenObserveEndpoint,ParameterValue="https://api.openobserve.ai/..." \
    ParameterKey=OpenObserveAccessKey,ParameterValue="BASE64_KEY" \
    ParameterKey=StreamName,ParameterValue="dynamodb-streams" \
    ParameterKey=DynamoDBTableName,ParameterValue="my-table" \
    ParameterKey=DynamoDBStreamArn,ParameterValue="$STREAM_ARN" \
    ParameterKey=BackupS3BucketName,ParameterValue="ddb-backup-12345" \
    ParameterKey=BatchSize,ParameterValue="100" \
  --capabilities CAPABILITY_IAM \
  --region us-east-2
```

---

## Parameters

### Kinesis-based Template

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| `OpenObserveEndpoint` | OpenObserve HTTP endpoint URL | - | Yes |
| `OpenObserveAccessKey` | Base64 encoded credentials | - | Yes |
| `StreamName` | OpenObserve stream name | `dynamodb-streams` | No |
| `DynamoDBTableName` | Existing DynamoDB table name | - | Yes |
| `BackupS3BucketName` | S3 bucket for failed records | Auto-generated | Yes |
| `ShardCount` | Kinesis shards (1-10) | `1` | No |

### Lambda-based Template

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| `OpenObserveEndpoint` | OpenObserve HTTP endpoint URL | - | Yes |
| `OpenObserveAccessKey` | Base64 encoded credentials | - | Yes |
| `StreamName` | OpenObserve stream name | `dynamodb-streams` | No |
| `DynamoDBTableName` | Existing DynamoDB table name | - | Yes |
| `DynamoDBStreamArn` | DynamoDB Stream ARN | Auto-detected | Yes |
| `BackupS3BucketName` | S3 bucket for failed records | Auto-generated | Yes |
| `BatchSize` | Records per Lambda invocation | `100` | No |

---

## Cost Breakdown

### Kinesis-based (~1M writes/day)

| Resource | Monthly Cost |
|----------|--------------|
| Kinesis Data Stream (1 shard) | ~$30 |
| Kinesis Firehose | ~$15 |
| Lambda invocations | ~$5 |
| S3 backup storage | ~$0.50 |
| **Total** | **~$50/month** |

### Lambda-based (~1M writes/day)

| Resource | Monthly Cost |
|----------|--------------|
| DynamoDB Streams (reads) | ~$5 |
| Lambda invocations | ~$5 |
| Kinesis Firehose | ~$15 |
| S3 backup storage | ~$0.50 |
| **Total** | **~$25/month** |

### Multiple Tables

| Tables | Kinesis-based | Lambda-based |
|--------|---------------|--------------|
| 1 | ~$50 | ~$25 |
| 3 | ~$150 | ~$75 |
| 5 | ~$250 | ~$125 |
| 10 | ~$500 | ~$250 |

### Cost Optimization

1. **Use Lambda-based** for low-volume tables
2. **Increase batch size** (Lambda option) to reduce invocations
3. **Reduce shard count** (Kinesis option) if throughput permits
4. **Use conditional writes** in DynamoDB to reduce stream records
5. **Monitor costs** with AWS Cost Explorer

---

## Monitoring

### List All Deployed Stacks

```bash
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE \
  --query 'StackSummaries[?starts_with(StackName, `ddb-`)].{Name:StackName,Type:StackName,Status:StackStatus}' \
  --output table
```

### Check Lambda Logs

```bash
# Kinesis-based
aws logs tail /aws/lambda/ddb-kinesis-my-table-stream-transformer --follow

# Lambda-based
aws logs tail /aws/lambda/ddb-lambda-my-table-stream-processor --follow
```

### Monitor Kinesis Stream (Kinesis option)

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name IncomingRecords \
  --dimensions Name=StreamName,Value=ddb-kinesis-my-table-dynamodb-stream \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

### Monitor Lambda Execution (Lambda option)

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=ddb-lambda-my-table-stream-processor \
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
  --dimensions Name=DeliveryStreamName,Value=ddb-kinesis-my-table-to-openobserve \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

### Check Failed Records

```bash
BACKUP_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name ddb-kinesis-my-table \
  --query 'Stacks[0].Outputs[?OutputKey==`BackupS3BucketName`].OutputValue' \
  --output text)

aws s3 ls s3://$BACKUP_BUCKET/failed-logs/ --recursive
```

---

## Testing

### Insert Test Data

```bash
# Insert a new item
aws dynamodb put-item \
  --table-name my-table \
  --item '{
    "id": {"S": "test-123"},
    "name": {"S": "Test User"},
    "email": {"S": "test@example.com"},
    "created_at": {"N": "1737489600"}
  }'
```

### Update Test Data

```bash
# Update an item
aws dynamodb update-item \
  --table-name my-table \
  --key '{"id": {"S": "test-123"}}' \
  --update-expression "SET #name = :name" \
  --expression-attribute-names '{"#name": "name"}' \
  --expression-attribute-values '{":name": {"S": "Updated Name"}}'
```

### Delete Test Data

```bash
# Delete an item
aws dynamodb delete-item \
  --table-name my-table \
  --key '{"id": {"S": "test-123"}}'
```

**Result:** All operations (INSERT, MODIFY, REMOVE) should appear in OpenObserve within seconds!

---

## JSON Output Format

### Sample DynamoDB Stream Record in OpenObserve

```json
{
  "timestamp": "2026-01-22T08:30:15Z",
  "eventID": "a1b2c3d4-5678-90ab-cdef-1234567890ab",
  "eventName": "MODIFY",
  "eventSource": "aws:dynamodb",
  "awsRegion": "us-east-2",
  "tableName": "users-table",
  "streamViewType": "NEW_AND_OLD_IMAGES",
  "keys": {
    "id": "user-123"
  },
  "newImage": {
    "id": "user-123",
    "name": "John Doe",
    "email": "john@example.com",
    "status": "active",
    "updated_at": 1737537015
  },
  "oldImage": {
    "id": "user-123",
    "name": "John Doe",
    "email": "john.old@example.com",
    "status": "pending",
    "updated_at": 1737450000
  },
  "approximateCreationDateTime": 1737537015,
  "sizeBytes": 256
}
```

### Event Types

**INSERT:**
```json
{
  "eventName": "INSERT",
  "keys": {"id": "new-123"},
  "newImage": {...},
  "oldImage": {}
}
```

**MODIFY:**
```json
{
  "eventName": "MODIFY",
  "keys": {"id": "existing-123"},
  "newImage": {...},
  "oldImage": {...}
}
```

**REMOVE:**
```json
{
  "eventName": "REMOVE",
  "keys": {"id": "deleted-123"},
  "newImage": {},
  "oldImage": {...}
}
```

---

## Cleanup

### Using Cleanup Script (Recommended)

```bash
chmod +x cleanup.sh
./cleanup.sh
```

The script will:
1. Find all DynamoDB Streams stacks (`ddb-kinesis-*`, `ddb-lambda-*`)
2. Display resources to be deleted
3. Prompt for confirmation
4. Remove Kinesis destinations (Kinesis option)
5. Empty S3 buckets
6. Delete CloudFormation stack
7. Check for orphaned Lambda log groups

**Note:** DynamoDB Streams will remain enabled on the table after cleanup. To disable:

```bash
aws dynamodb update-table \
  --table-name my-table \
  --stream-specification StreamEnabled=false \
  --region us-east-2
```

### Manual Cleanup

```bash
# Empty S3 bucket
BACKUP_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name ddb-kinesis-my-table \
  --query 'Stacks[0].Outputs[?OutputKey==`BackupS3BucketName`].OutputValue' \
  --output text)
aws s3 rm s3://$BACKUP_BUCKET --recursive

# Delete stack
aws cloudformation delete-stack --stack-name ddb-kinesis-my-table

# Wait for completion
aws cloudformation wait stack-delete-complete --stack-name ddb-kinesis-my-table
```

---

## Troubleshooting

### Stack Creation Failed: "Kinesis Streaming Destination already exists"

**Cause:** Table already has a Kinesis streaming destination configured.

**Solution:**
1. Check existing destinations:
   ```bash
   aws dynamodb describe-kinesis-streaming-destination \
     --table-name my-table
   ```
2. Remove old destination:
   ```bash
   aws dynamodb disable-kinesis-streaming-destination \
     --table-name my-table \
     --stream-arn <old-stream-arn>
   ```
3. Redeploy with `./deploy.sh`

### No Data Appearing in OpenObserve

**1. Verify DynamoDB Streams enabled:**
```bash
aws dynamodb describe-table \
  --table-name my-table \
  --query 'Table.StreamSpecification'
```

**2. Check stream is receiving data:**
```bash
aws dynamodb describe-table \
  --table-name my-table \
  --query 'Table.LatestStreamArn' \
  --output text
```

**3. Check Lambda/Kinesis logs:**
```bash
# Kinesis option
aws logs tail /aws/lambda/ddb-kinesis-my-table-stream-transformer --since 30m

# Lambda option
aws logs tail /aws/lambda/ddb-lambda-my-table-stream-processor --since 30m
```

**4. Verify Firehose delivery:**
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Firehose \
  --metric-name DeliveryToHttpEndpoint.Success \
  --dimensions Name=DeliveryStreamName,Value=ddb-kinesis-my-table-to-openobserve \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

**5. Check failed records:**
```bash
aws s3 ls s3://<backup-bucket>/error-logs/ --recursive
```

### Lambda Timeout Errors (Lambda option)

For high-volume tables, increase Lambda timeout:

```yaml
# Edit dynamodb-streams-to-openobserve-lambda.yaml
Timeout: 600  # Increase from 300 (5 minutes max for DynamoDB stream processing)
MemorySize: 1024  # Increase from 512
```

### Decimal/Float Conversion Issues

DynamoDB uses Decimal type for numbers. The Lambda includes a `DecimalEncoder` to convert to float automatically. If you see errors, check the Lambda logs for details.

### Event Source Mapping Errors

**Error:** `InvalidParameterValueException: Cannot access stream`

**Solution:**
- Ensure DynamoDB Streams are enabled
- Verify Lambda has correct IAM permissions
- Wait a few seconds after enabling streams before deploying

---

## Advanced Configuration

### Custom Lambda Transformation

Edit the Lambda code in templates to add custom fields:

```python
transformed = {
    'timestamp': datetime.utcnow().isoformat() + 'Z',
    'eventID': event_id,
    'eventName': event_name,
    'tableName': table_name,
    'keys': keys,
    'newImage': new_image,
    'oldImage': old_image,
    # Add custom fields
    'environment': 'production',
    'team': 'platform',
    'cost_center': '12345',
    'region': aws_region
}
```

### Filter Specific Event Types

Modify Lambda to filter events:

```python
# Only process INSERT events
if event_name != 'INSERT':
    continue

# Only process MODIFY and REMOVE
if event_name not in ['MODIFY', 'REMOVE']:
    continue
```

### Multiple OpenObserve Streams

**Same stream (aggregated):**
```bash
export STREAM_NAME="dynamodb-streams"
./deploy.sh  # Table 1
./deploy.sh  # Table 2
```

**Separate streams:**
```bash
export STREAM_NAME="dynamodb-users"
export DYNAMODB_TABLE_NAME="users-table"
./deploy.sh

export STREAM_NAME="dynamodb-orders"
export DYNAMODB_TABLE_NAME="orders-table"
./deploy.sh
```

### Query in OpenObserve

```sql
-- All INSERT events
SELECT * FROM "dynamodb-streams"
WHERE eventName = 'INSERT'

-- Specific table changes
SELECT * FROM "dynamodb-streams"
WHERE tableName = 'users-table'

-- Recent modifications
SELECT * FROM "dynamodb-streams"
WHERE eventName = 'MODIFY'
AND timestamp > now() - interval '1 hour'

-- Track specific item changes
SELECT * FROM "dynamodb-streams"
WHERE keys.id = 'user-123'
ORDER BY timestamp DESC
```

---

## Use Cases

### Real-time Analytics

Monitor table activity for dashboards and metrics:
```bash
export STREAM_NAME="dynamodb-analytics"
./deploy.sh
```

### Data Synchronization

Track changes for replication to other systems:
```bash
export STREAM_NAME="dynamodb-sync"
export DYNAMODB_TABLE_NAME="master-table"
./deploy.sh
```

### Audit Trail

Monitor all modifications for compliance:
```bash
export STREAM_NAME="dynamodb-audit"
export DYNAMODB_TABLE_NAME="sensitive-data-table"
./deploy.sh
```

### Event-driven Workflows

Trigger workflows based on table changes (monitor in OpenObserve, trigger externally).

---

## Security Best Practices

1. **Use AWS Secrets Manager** for OpenObserve credentials
2. **Enable S3 encryption** at rest (already configured)
3. **Enable CloudTrail** to audit DynamoDB access
4. **Restrict IAM roles** to least privilege
5. **Enable point-in-time recovery** on DynamoDB tables
6. **Use VPC endpoints** for Kinesis/Firehose if in VPC
7. **Rotate credentials** regularly
8. **Enable DynamoDB encryption** at rest
9. **Monitor access patterns** for anomalies

---

## FAQ

**Q: Does this modify my DynamoDB table?**
A: No. It only enables DynamoDB Streams (non-intrusive) and creates monitoring resources.

**Q: Will enabling streams affect table performance?**
A: Minimal impact. DynamoDB Streams are designed for low-latency capture without affecting table operations.

**Q: What's the difference between DynamoDB Streams and Kinesis Streaming Destination?**
A: DynamoDB Streams is the native feature (used by Lambda option). Kinesis Streaming Destination is a newer AWS-managed integration to Kinesis Data Streams (used by Kinesis option).

**Q: Can I stream from multiple tables?**
A: Yes! Run `./deploy.sh` multiple times for different tables. Each gets isolated resources.

**Q: Which option should I choose?**
A: **Kinesis-based** for high-volume production tables. **Lambda-based** for development or low-volume tables.

**Q: Are old table items sent to OpenObserve?**
A: No. Only changes after deployment are captured (INSERT, MODIFY, REMOVE operations).

**Q: Can I get the full table snapshot?**
A: No. DynamoDB Streams only capture changes. For full table export, use DynamoDB export to S3 feature separately.

**Q: What happens if Lambda fails?**
A: Failed records are backed up to S3 for manual reprocessing. Lambda also has automatic retry (3 attempts).

**Q: Can I disable streams later?**
A: Yes, but you should delete the CloudFormation stack first, then disable streams on the table.

---

## Files

- `dynamodb-streams-to-openobserve.yaml` - Kinesis-based template (recommended)
- `dynamodb-streams-to-openobserve-lambda.yaml` - Lambda-based template (cost-effective)
- `deploy.sh` - Interactive deployment script with multi-table support
- `cleanup.sh` - Automated resource cleanup script
- `README.md` - This documentation

---

## Support

- [AWS CloudFormation Documentation](https://docs.aws.amazon.com/cloudformation/)
- [OpenObserve Documentation](https://openobserve.ai/docs)
- [DynamoDB Streams Guide](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Streams.html)
- [Kinesis Streaming Destination](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/kds.html)
- [DynamoDB Best Practices](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/best-practices.html)

---

## Summary

✅ **Two deployment options:** Kinesis ($50/mo) or Lambda ($25/mo)
✅ **Item-level tracking:** INSERT, MODIFY, REMOVE events
✅ **Near real-time:** Changes appear in OpenObserve within seconds
✅ **Auto JSON conversion:** DynamoDB format → structured JSON
✅ **Multi-table support:** Isolated stacks per table
✅ **Easy deployment:** Automated scripts with validation
✅ **Production ready:** Security, monitoring, error handling included
✅ **Non-intrusive:** Uses existing tables, minimal performance impact
