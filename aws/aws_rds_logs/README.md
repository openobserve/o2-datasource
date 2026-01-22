# RDS Logs to OpenObserve - CloudFormation Template

Stream AWS RDS database logs to OpenObserve in near real-time using CloudFormation with automated deployment scripts.

## Quick Start

### Using the Deploy Script (Recommended)

```bash
chmod +x deploy.sh
./deploy.sh
```

The script will:
1. Check prerequisites (AWS CLI, jq)
2. Validate AWS credentials
3. List available RDS instances
4. Show CloudWatch Log Groups for selected RDS instance
5. Display available log types for the database engine
6. Prompt for log group selection
7. Generate unique stack name per RDS instance
8. Create all required resources
9. Configure subscription filter automatically

---

## Architecture

```
RDS → CloudWatch Logs → Subscription Filter → Kinesis Stream → Lambda → Firehose → OpenObserve
                                                                                      ↓
                                                                                 S3 (Failed)
```

### Resources Created

1. **Kinesis Data Stream** - Real-time log streaming
2. **Lambda Function** - Gzip decompression & RDS-specific JSON transformation
3. **Kinesis Firehose** - Delivery to OpenObserve with retry logic
4. **S3 Bucket** - Failed records backup (30-day retention)
5. **Subscription Filter** - Connects RDS log group to Kinesis
6. **IAM Roles** - CloudWatchLogsRole, LambdaExecutionRole, FirehoseDeliveryRole

**Note:** Does NOT modify RDS settings or create CloudWatch Log Groups - uses existing RDS CloudWatch Logs.

---

## RDS Log Types by Engine

### PostgreSQL / Aurora PostgreSQL
- `postgresql` - General logs (connections, queries, errors)

**Enable logs:**
```bash
aws rds modify-db-instance \
  --db-instance-identifier my-postgres-db \
  --cloudwatch-logs-export-configuration '{"LogTypesToEnable":["postgresql"]}' \
  --apply-immediately
```

**Common log groups:**
- `/aws/rds/instance/<db-name>/postgresql`
- `/aws/rds/cluster/<cluster-name>/postgresql`

### MySQL / Aurora MySQL / MariaDB
- `error` - Error logs (startup issues, critical errors)
- `general` - General query logs (all queries - high volume!)
- `slowquery` - Slow query logs (queries exceeding threshold)
- `audit` - Audit logs (requires audit plugin)

**Enable logs:**
```bash
# Recommended: error + slowquery only
aws rds modify-db-instance \
  --db-instance-identifier my-mysql-db \
  --cloudwatch-logs-export-configuration '{"LogTypesToEnable":["error","slowquery"]}' \
  --apply-immediately

# With general logs (warning: high volume/cost)
aws rds modify-db-instance \
  --db-instance-identifier my-mysql-db \
  --cloudwatch-logs-export-configuration '{"LogTypesToEnable":["error","slowquery","general"]}' \
  --apply-immediately
```

**Common log groups:**
- `/aws/rds/instance/<db-name>/error`
- `/aws/rds/instance/<db-name>/slowquery`
- `/aws/rds/instance/<db-name>/general`
- `/aws/rds/cluster/<cluster-name>/error`

### Oracle
- `alert` - Alert logs (database events)
- `audit` - Audit files
- `trace` - Trace files
- `listener` - Listener logs

**Enable logs:**
```bash
aws rds modify-db-instance \
  --db-instance-identifier my-oracle-db \
  --cloudwatch-logs-export-configuration '{"LogTypesToEnable":["alert","audit"]}' \
  --apply-immediately
```

### SQL Server
- `error` - Error logs
- `agent` - Agent logs

**Enable logs:**
```bash
aws rds modify-db-instance \
  --db-instance-identifier my-sqlserver-db \
  --cloudwatch-logs-export-configuration '{"LogTypesToEnable":["error","agent"]}' \
  --apply-immediately
```

---

## Features

- ✅ **Near real-time streaming** (seconds delay)
- ✅ **Automatic gzip decompression** from CloudWatch
- ✅ **RDS-specific transformation** (extracts DB engine, instance ID, log type)
- ✅ **Severity detection** (ERROR, WARNING, INFO from log messages)
- ✅ **Configurable log filtering** (stream specific severities only)
- ✅ **Failed records backup** to S3
- ✅ **Built-in retry logic** via Firehose
- ✅ **Multi-RDS support** (isolated stacks per RDS instance)
- ✅ **Works with existing RDS instances** (no RDS modifications required)

---

## Multiple RDS Instances Support

Deploy to multiple RDS instances with isolated resources:

```bash
# RDS Instance 1 - MySQL
./deploy.sh
# Enter: my-mysql-db
# Select: /aws/rds/instance/my-mysql-db/error
# Stack created: rds-logs-my-mysql-db

# RDS Instance 2 - PostgreSQL
./deploy.sh
# Enter: my-postgres-db
# Select: /aws/rds/instance/my-postgres-db/postgresql
# Stack created: rds-logs-my-postgres-db

# Aurora Cluster
./deploy.sh
# Enter: my-aurora-cluster
# Select: /aws/rds/cluster/my-aurora-cluster/error
# Stack created: rds-logs-my-aurora-cluster
```

### Stack Naming Convention

**Pattern:** `rds-logs-<RDS-INSTANCE-ID>`

**Examples:**
- RDS instance `production-mysql` → `rds-logs-production-mysql`
- RDS instance `staging-postgres` → `rds-logs-staging-postgres`
- Aurora cluster `app-db-cluster` → `rds-logs-app-db-cluster`

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
4. **RDS instance** with CloudWatch Logs export enabled
5. **AWS Permissions:**
   - CloudFormation (create/update/delete stacks)
   - RDS (describe instances/clusters)
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
STREAM_NAME="rds-logs"
LOG_GROUP_NAME=""  # Leave empty to prompt
RDS_INSTANCE_ID=""  # Leave empty to prompt
FILTER_PATTERN=""  # Leave empty to prompt
AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-us-east-2}"
```

### Option 2: Use Environment Variables

```bash
export OPENOBSERVE_ENDPOINT="https://api.openobserve.ai/api/YOUR-ORG/default/_kinesis_firehose"
export OPENOBSERVE_ACCESS_KEY="BASE64_ENCODED_CREDENTIALS"
export RDS_INSTANCE_ID="my-database"
export LOG_GROUP_NAME="/aws/rds/instance/my-database/error"
export FILTER_PATTERN=""
export STREAM_NAME="rds-logs"
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
| `StreamName` | OpenObserve stream name | `rds-logs` | No |
| `LogGroupName` | CloudWatch Log Group name for RDS | - | Yes |
| `RDSInstanceIdentifier` | RDS instance/cluster identifier | - | Yes |
| `BackupS3BucketName` | S3 bucket for failed records (unique) | Auto-generated | Yes |
| `ShardCount` | Number of Kinesis shards (1-10) | `1` | No |
| `FilterPattern` | CloudWatch filter pattern | `""` (all logs) | No |

---

## Filter Patterns

Stream specific logs using CloudWatch Logs filter patterns:

```bash
# All logs (default)
FilterPattern=""

# Error logs only
FilterPattern="ERROR"

# Fatal/critical errors
FilterPattern="FATAL"

# Warnings
FilterPattern="WARNING"

# Multiple keywords (OR)
FilterPattern="ERROR FATAL PANIC"

# Exclude specific patterns (requires advanced syntax)
# See AWS documentation for complex patterns
```

**Note:** RDS log formats vary by engine. Test filter patterns before deploying.

See [AWS Filter Pattern Syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html)

---

## Manual Deployment

```bash
aws cloudformation create-stack \
  --stack-name rds-logs-my-database \
  --template-body file://rds-logs-to-openobserve.yaml \
  --parameters \
    ParameterKey=OpenObserveEndpoint,ParameterValue="https://api.openobserve.ai/..." \
    ParameterKey=OpenObserveAccessKey,ParameterValue="BASE64_KEY" \
    ParameterKey=StreamName,ParameterValue="rds-logs" \
    ParameterKey=LogGroupName,ParameterValue="/aws/rds/instance/my-db/error" \
    ParameterKey=RDSInstanceIdentifier,ParameterValue="my-database" \
    ParameterKey=BackupS3BucketName,ParameterValue="rds-backup-12345" \
    ParameterKey=ShardCount,ParameterValue="1" \
    ParameterKey=FilterPattern,ParameterValue="" \
  --capabilities CAPABILITY_IAM \
  --region us-east-2
```

---

## Cost Breakdown

### Per RDS Instance (~1GB/day logs)

| Resource | Monthly Cost |
|----------|--------------|
| Kinesis Data Stream (1 shard) | ~$30 |
| Kinesis Firehose | ~$15 |
| Lambda invocations | ~$2 |
| S3 backup storage | ~$0.50 |
| **Total** | **~$47/month** |

### Multiple RDS Instances

| RDS Instances | Est. Monthly Cost |
|---------------|-------------------|
| 1 | ~$47 |
| 3 | ~$141 |
| 5 | ~$235 |
| 10 | ~$470 |

### Cost Optimization Tips

1. **Use filter patterns** - Stream only ERROR logs
2. **Disable general logs** - MySQL/MariaDB general logs are extremely high volume
3. **Stream error + slowquery only** - Most useful for troubleshooting
4. **Set log retention** - Reduce CloudWatch Logs storage costs:
   ```bash
   aws logs put-retention-policy \
     --log-group-name /aws/rds/instance/my-db/error \
     --retention-in-days 7
   ```
5. **Monitor slow query threshold** - Increase `long_query_time` to reduce slow query volume

---

## Common Use Cases

### MySQL Production Database - Error & Slow Queries

```bash
export RDS_INSTANCE_ID="prod-mysql-db"
export LOG_GROUP_NAME="/aws/rds/instance/prod-mysql-db/error"
export FILTER_PATTERN=""
./deploy.sh

# Deploy second stack for slow queries
export LOG_GROUP_NAME="/aws/rds/instance/prod-mysql-db/slowquery"
./deploy.sh
```

### PostgreSQL Database - All Logs

```bash
export RDS_INSTANCE_ID="prod-postgres-db"
export LOG_GROUP_NAME="/aws/rds/instance/prod-postgres-db/postgresql"
export FILTER_PATTERN=""
./deploy.sh
```

### Aurora MySQL Cluster - Errors Only

```bash
export RDS_INSTANCE_ID="aurora-cluster-prod"
export LOG_GROUP_NAME="/aws/rds/cluster/aurora-cluster-prod/error"
export FILTER_PATTERN="ERROR"
./deploy.sh
```

### Aurora PostgreSQL Cluster - Warnings & Errors

```bash
export RDS_INSTANCE_ID="aurora-postgres-cluster"
export LOG_GROUP_NAME="/aws/rds/cluster/aurora-postgres-cluster/postgresql"
export FILTER_PATTERN=""  # Filter in OpenObserve instead
./deploy.sh
```

---

## Lambda Transformation Details

The Lambda function automatically enriches RDS logs with metadata:

### Input (CloudWatch Logs format, gzipped):
```json
{
  "messageType": "DATA_MESSAGE",
  "logGroup": "/aws/rds/instance/my-mysql-db/error",
  "logStream": "2026.01.22/mysql-error.log",
  "logEvents": [
    {
      "id": "37...",
      "timestamp": 1737489600000,
      "message": "2026-01-22T10:00:00.123456Z 123 [ERROR] [MY-012345] Access denied for user 'app'@'10.0.1.5'"
    }
  ]
}
```

### Output (Transformed JSON):
```json
{
  "timestamp": 1737489600000,
  "message": "2026-01-22T10:00:00.123456Z 123 [ERROR] [MY-012345] Access denied for user 'app'@'10.0.1.5'",
  "logGroup": "/aws/rds/instance/my-mysql-db/error",
  "logStream": "2026.01.22/mysql-error.log",
  "id": "37...",
  "rds_log_type": "error",
  "rds_engine": "mysql",
  "rds_identifier": "my-mysql-db",
  "severity": "ERROR",
  "source": "aws-rds"
}
```

### Extracted Fields:
- `rds_log_type` - Log type (error, slowquery, postgresql, etc.)
- `rds_engine` - Database engine (mysql, postgresql, mariadb, oracle, sqlserver, aurora)
- `rds_identifier` - RDS instance or cluster identifier
- `severity` - Parsed severity (ERROR, WARNING, INFO, DEBUG)
- `source` - Always "aws-rds"

---

## Monitoring

### List All Deployed Stacks

```bash
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE \
  --query 'StackSummaries[?starts_with(StackName, `rds-logs-`)].{Name:StackName,Status:StackStatus,Created:CreationTime}' \
  --output table
```

### Check RDS CloudWatch Logs Status

```bash
# For RDS instance
aws rds describe-db-instances \
  --db-instance-identifier my-database \
  --query 'DBInstances[0].EnabledCloudwatchLogsExports'

# For Aurora cluster
aws rds describe-db-clusters \
  --db-cluster-identifier my-cluster \
  --query 'DBClusters[0].EnabledCloudwatchLogsExports'
```

### Check Lambda Transformation Logs

```bash
# Replace with your stack name
aws logs tail /aws/lambda/rds-logs-my-database-log-transformer --follow
```

### Check Subscription Filter Status

```bash
aws logs describe-subscription-filters \
  --log-group-name /aws/rds/instance/my-database/error
```

### Monitor Kinesis Stream

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name IncomingRecords \
  --dimensions Name=StreamName,Value=rds-logs-my-database-rds-logs \
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
  --dimensions Name=DeliveryStreamName,Value=rds-logs-my-database-to-openobserve \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

### Check Failed Records

```bash
# Get backup bucket name from stack
BACKUP_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name rds-logs-my-database \
  --query 'Stacks[0].Outputs[?OutputKey==`BackupS3BucketName`].OutputValue' \
  --output text)

# List failed records
aws s3 ls s3://$BACKUP_BUCKET/failed-logs/ --recursive
```

---

## Testing

### Trigger RDS Logs

RDS logs are generated by database activity. To test:

**MySQL/MariaDB:**
```sql
-- Generate error log entry (wrong credentials)
mysql -h my-db.rds.amazonaws.com -u wronguser -p

-- Generate slow query log entry
SET SESSION long_query_time = 0;
SELECT SLEEP(1);
```

**PostgreSQL:**
```sql
-- Generate error log entry
psql -h my-db.rds.amazonaws.com -U wronguser postgres

-- Generate log entry
SELECT pg_sleep(1);
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
1. Find all RDS Logs stacks (searches for `rds-logs-*`)
2. Display resources to be deleted
3. Prompt for confirmation
4. Remove subscription filters automatically
5. Empty S3 buckets
6. Delete CloudFormation stack
7. Note about RDS CloudWatch Logs (not deleted)

**Important:** RDS CloudWatch Logs are NOT deleted (they belong to RDS).

### Disable RDS CloudWatch Logs Export

```bash
# Disable all log types
aws rds modify-db-instance \
  --db-instance-identifier my-database \
  --cloudwatch-logs-export-configuration '{"LogTypesToDisable":["error","slowquery","general"]}' \
  --apply-immediately

# For clusters
aws rds modify-db-cluster \
  --db-cluster-identifier my-cluster \
  --cloudwatch-logs-export-configuration '{"LogTypesToDisable":["postgresql"]}' \
  --apply-immediately
```

### Manual Cleanup

```bash
# List stack resources
aws cloudformation describe-stack-resources \
  --stack-name rds-logs-my-database

# Empty S3 bucket
BACKUP_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name rds-logs-my-database \
  --query 'Stacks[0].Outputs[?OutputKey==`BackupS3BucketName`].OutputValue' \
  --output text)
aws s3 rm s3://$BACKUP_BUCKET --recursive

# Delete stack
aws cloudformation delete-stack --stack-name rds-logs-my-database

# Wait for completion
aws cloudformation wait stack-delete-complete --stack-name rds-logs-my-database
```

---

## Troubleshooting

### No Logs Appearing in OpenObserve

1. **Verify RDS CloudWatch Logs are enabled:**
   ```bash
   aws rds describe-db-instances \
     --db-instance-identifier my-database \
     --query 'DBInstances[0].EnabledCloudwatchLogsExports'
   ```

2. **Verify log group exists:**
   ```bash
   aws logs describe-log-groups \
     --log-group-name-prefix /aws/rds/instance/my-database
   ```

3. **Check subscription filter:**
   ```bash
   aws logs describe-subscription-filters \
     --log-group-name /aws/rds/instance/my-database/error
   ```

4. **Check Kinesis is receiving data:**
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/Kinesis \
     --metric-name IncomingRecords \
     --dimensions Name=StreamName,Value=rds-logs-my-database-rds-logs \
     --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 60 \
     --statistics Sum
   ```

5. **Check Lambda transformation logs:**
   ```bash
   aws logs tail /aws/lambda/rds-logs-my-database-log-transformer --since 30m
   ```

6. **Check failed records in S3:**
   ```bash
   aws s3 ls s3://<backup-bucket>/error-logs/ --recursive
   ```

### RDS CloudWatch Logs Not Enabled

**Error:** Log group doesn't exist or is empty.

**Solution:** Enable CloudWatch Logs export for your RDS instance:

```bash
# MySQL/MariaDB
aws rds modify-db-instance \
  --db-instance-identifier my-database \
  --cloudwatch-logs-export-configuration '{"LogTypesToEnable":["error","slowquery"]}' \
  --apply-immediately

# PostgreSQL
aws rds modify-db-instance \
  --db-instance-identifier my-database \
  --cloudwatch-logs-export-configuration '{"LogTypesToEnable":["postgresql"]}' \
  --apply-immediately
```

### High Costs

**Problem:** Unexpectedly high AWS bill.

**Solutions:**
1. **Disable general logs** - MySQL general logs log every query (extremely high volume)
2. **Use filter patterns** - Stream only ERROR/FATAL logs
3. **Increase slow query threshold:**
   ```sql
   -- MySQL/MariaDB
   SET GLOBAL long_query_time = 5;  -- Only log queries > 5 seconds
   ```
4. **Set log retention:**
   ```bash
   aws logs put-retention-policy \
     --log-group-name /aws/rds/instance/my-db/error \
     --retention-in-days 7
   ```
5. **Review RDS parameter groups** - Adjust logging verbosity

### Subscription Limit Exceeded

CloudWatch Log Groups can have **only 1 subscription filter**.

**Error:** `LimitExceededException: Resource limit exceeded`

**Solution:**
1. Check existing filters:
   ```bash
   aws logs describe-subscription-filters \
     --log-group-name /aws/rds/instance/my-database/error
   ```
2. Delete old filter:
   ```bash
   aws logs delete-subscription-filter \
     --log-group-name /aws/rds/instance/my-database/error \
     --filter-name <old-filter-name>
   ```
3. Redeploy with `./deploy.sh`

### Lambda Timeout Errors

If processing large batches of logs, increase Lambda timeout:

```yaml
# Edit rds-logs-to-openobserve.yaml
Timeout: 120  # Increase from 60
MemorySize: 512  # Increase from 256
```

Then update the stack:
```bash
aws cloudformation update-stack \
  --stack-name rds-logs-my-database \
  --template-body file://rds-logs-to-openobserve.yaml \
  --parameters ParameterKey=OpenObserveEndpoint,UsePreviousValue=true \
               ... (all other parameters with UsePreviousValue=true) \
  --capabilities CAPABILITY_IAM
```

---

## Advanced Configuration

### Custom Lambda Transformation

Edit the Lambda code in `rds-logs-to-openobserve.yaml` to add custom fields:

```python
transformed = {
    'timestamp': event.get('timestamp'),
    'message': message,
    'logGroup': log_group,
    'logStream': log_stream,
    'id': event.get('id'),
    'rds_log_type': log_type,
    'rds_engine': db_engine,
    'rds_identifier': db_identifier,
    'severity': severity,
    'source': 'aws-rds',
    # Add custom fields
    'environment': 'production',
    'team': 'database',
    'cost_center': '12345',
    'region': 'us-east-2'
}
```

### Multiple OpenObserve Streams

**Same stream (aggregated RDS logs):**
```bash
export STREAM_NAME="rds-logs"
./deploy.sh  # RDS instance 1
./deploy.sh  # RDS instance 2
# All RDS logs go to same OpenObserve stream
```

**Separate streams (isolated):**
```bash
export STREAM_NAME="rds-logs-prod"
export RDS_INSTANCE_ID="prod-mysql"
./deploy.sh

export STREAM_NAME="rds-logs-staging"
export RDS_INSTANCE_ID="staging-mysql"
./deploy.sh
```

### Query Logs in OpenObserve

When using the same stream for multiple RDS instances, filter by metadata fields:

```sql
-- All error logs from MySQL databases
SELECT * FROM "rds-logs"
WHERE rds_engine = 'mysql'
AND severity = 'ERROR'

-- Specific RDS instance
SELECT * FROM "rds-logs"
WHERE rds_identifier = 'prod-mysql-db'

-- Slow query logs across all databases
SELECT * FROM "rds-logs"
WHERE rds_log_type = 'slowquery'

-- Multiple RDS instances
SELECT * FROM "rds-logs"
WHERE rds_identifier IN ('db1', 'db2', 'db3')

-- Filter by log group
SELECT * FROM "rds-logs"
WHERE logGroup LIKE '/aws/rds/instance/prod-%'
```

---

## Engine-Specific Notes

### MySQL / Aurora MySQL / MariaDB

**Recommended log exports:**
- `error` - Always enable (low volume, critical errors)
- `slowquery` - Enable for performance troubleshooting

**Avoid:**
- `general` - Logs every query (extremely high volume and cost)

**Slow query configuration:**
```sql
-- View current settings
SHOW VARIABLES LIKE 'long_query_time';
SHOW VARIABLES LIKE 'log_queries_not_using_indexes';

-- Adjust slow query threshold (seconds)
SET GLOBAL long_query_time = 2;

-- Log queries without indexes
SET GLOBAL log_queries_not_using_indexes = ON;
```

**Common log formats:**
```
# Error log
2026-01-22T10:00:00.123456Z 0 [ERROR] [MY-012345] Access denied for user 'app'@'10.0.1.5'

# Slow query log
# Time: 2026-01-22T10:00:00.123456Z
# User@Host: app[app] @ 10.0.1.5 [10.0.1.5]
# Query_time: 5.123456  Lock_time: 0.000123 Rows_sent: 100  Rows_examined: 100000
SELECT * FROM large_table WHERE unindexed_column = 'value';
```

### PostgreSQL / Aurora PostgreSQL

**Recommended log exports:**
- `postgresql` - All PostgreSQL logs

**Log configuration (parameter group):**
```
log_min_duration_statement = 1000  # Log queries > 1 second
log_connections = 1
log_disconnections = 1
log_duration = 0
log_statement = 'ddl'  # Log DDL statements
```

**Common log formats:**
```
2026-01-22 10:00:00 UTC::@:[12345]:LOG:  connection received: host=10.0.1.5 port=54321
2026-01-22 10:00:00 UTC:app@mydb:[12345]:ERROR:  relation "nonexistent_table" does not exist at character 15
2026-01-22 10:00:00 UTC:app@mydb:[12345]:LOG:  duration: 1234.567 ms  statement: SELECT * FROM large_table;
```

### Oracle

**Available log types:**
- `alert` - Database alert log
- `audit` - Audit trail
- `trace` - Trace files
- `listener` - Listener logs

**Note:** Oracle RDS logs are less commonly used. Most Oracle monitoring is done via AWR/ADDM.

### SQL Server

**Available log types:**
- `error` - SQL Server error log
- `agent` - SQL Server Agent log

**Common log formats:**
```
2026-01-22 10:00:00.12 spid52    Error: 18456, Severity: 14, State: 8.
2026-01-22 10:00:00.12 spid52    Login failed for user 'app'.
```

---

## Security Best Practices

1. **Use AWS Secrets Manager** for OpenObserve credentials
2. **Enable S3 encryption** at rest (already configured in template)
3. **Enable CloudTrail** to audit access to RDS logs
4. **Restrict IAM roles** to least privilege
5. **Use VPC endpoints** for Kinesis/Firehose if running in VPC
6. **Rotate OpenObserve credentials** regularly
7. **Set appropriate log retention** to minimize data exposure
8. **Enable MFA** on AWS accounts with RDS/CloudFormation permissions
9. **Tag resources** for cost allocation and compliance
10. **Sanitize sensitive data** - Consider masking passwords/PII in logs

---

## Performance Tuning

### Kinesis Shard Count

**1 shard** (default):
- Throughput: 1 MB/s input, 2 MB/s output
- Suitable for: Most RDS instances (error + slow query logs)

**2+ shards:**
- Use if Kinesis throttling occurs
- Check metric: `WriteProvisionedThroughputExceeded`

### Lambda Memory/Timeout

**Default (256MB, 60s):**
- Handles most RDS log volumes

**Increase if:**
- Lambda timeouts occur
- Processing large batches
- Suggestion: 512MB, 120s timeout

### Firehose Buffering

**Default (1MB, 60s):**
- Fast delivery to OpenObserve
- Higher request count (higher cost)

**Optimize for cost:**
```yaml
BufferingHints:
  SizeInMBs: 5
  IntervalInSeconds: 300
```

---

## Files

- `rds-logs-to-openobserve.yaml` - CloudFormation template
- `deploy.sh` - Interactive deployment script with RDS detection
- `cleanup.sh` - Automated resource cleanup script
- `README.md` - This documentation

---

## Support

- [AWS RDS Documentation](https://docs.aws.amazon.com/rds/)
- [RDS CloudWatch Logs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.Concepts.html)
- [OpenObserve Documentation](https://openobserve.ai/docs)
- [CloudWatch Logs Guide](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/)
- [Filter Pattern Syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html)

---

## Summary

✅ **Near real-time streaming** - RDS logs appear in OpenObserve within seconds
✅ **RDS-specific enrichment** - Auto-detects engine, log type, severity
✅ **Automated deployment** - `deploy.sh` lists RDS instances and log groups
✅ **Multi-RDS support** - Unique stack per RDS instance
✅ **Engine-aware** - Supports MySQL, PostgreSQL, Oracle, SQL Server, Aurora
✅ **Easy cleanup** - `cleanup.sh` removes all resources safely
✅ **Production ready** - Security, monitoring, cost optimization included
✅ **Failed records backup** - S3 backup with 30-day retention
✅ **Scalable** - Deploy to unlimited RDS instances independently
✅ **No RDS modifications** - Works with existing RDS CloudWatch Logs

---

## License

This template is provided as-is for use with AWS CloudFormation and OpenObserve.
