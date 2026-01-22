# Kinesis Data Stream to OpenObserve

CloudFormation templates for consuming from existing Kinesis Data Streams and forwarding logs to OpenObserve for analysis and visualization.

## Overview

Kinesis Data Streams is a real-time streaming service used by many AWS services and applications. These templates help you consume from existing Kinesis streams and forward the data to OpenObserve for centralized logging and analysis.

## Architecture Options

### Option 1: Firehose Direct (Recommended)

```
Kinesis Data Stream → Kinesis Firehose → OpenObserve
                            ↓
                   Optional Lambda Transform
                            ↓
                   S3 Backup (Failed Records)
```

**Template**: `kinesis-to-openobserve-firehose.yaml`

**When to Use**:
- Standard log forwarding with minimal processing
- Cost-effective solution for high-throughput streams
- Simple JSON transformation needs
- Want managed scaling and delivery

**Benefits**:
- Fully managed by AWS
- Automatic scaling and retry logic
- Lower operational overhead
- Built-in buffering and batching

**Costs** (approximate):
- Firehose: $0.029 per GB ingested
- Lambda (if enabled): $0.20 per 1M requests + compute time
- S3 backup: $0.023 per GB stored
- Data transfer: Standard AWS rates

### Option 2: Lambda + Firehose (Advanced)

```
Kinesis Data Stream → Lambda Consumer → Firehose → OpenObserve
                            ↓                ↓
                          DLQ          S3 Backup
```

**Template**: `kinesis-to-openobserve-lambda.yaml`

**When to Use**:
- Complex data transformations or enrichment
- Custom business logic (filtering, aggregation)
- Need to lookup external data sources
- Require detailed processing control

**Benefits**:
- Full control over record processing
- Support for complex transformations
- Can aggregate or filter records
- Custom error handling with DLQ

**Costs** (approximate):
- Lambda: $0.20 per 1M requests + $0.0000166667 per GB-second
- Firehose: $0.029 per GB ingested
- S3 backup: $0.023 per GB stored
- SQS DLQ: $0.40 per 1M requests

## Common Kinesis Data Sources

Many AWS services can write to Kinesis Data Streams:

### 1. **DynamoDB Streams**
```bash
# DynamoDB table with Kinesis streaming
aws dynamodb enable-kinesis-streaming-destination \
  --table-name MyTable \
  --stream-arn arn:aws:kinesis:region:account:stream/my-stream
```

### 2. **CloudWatch Logs**
```bash
# Subscription filter to Kinesis
aws logs put-subscription-filter \
  --log-group-name /aws/lambda/my-function \
  --filter-name SendToKinesis \
  --filter-pattern "" \
  --destination-arn arn:aws:kinesis:region:account:stream/my-stream
```

### 3. **Amazon EventBridge**
EventBridge rules can target Kinesis streams for event routing.

### 4. **AWS IoT Core**
IoT rules can publish device telemetry to Kinesis streams.

### 5. **Custom Applications**
Application logs using AWS SDK or Kinesis Producer Library (KPL).

### 6. **Third-Party Services**
Many SaaS tools support Kinesis as a data destination.

### 7. **AWS Database Migration Service (DMS)**
CDC (Change Data Capture) from databases to Kinesis.

## Prerequisites

1. **AWS CLI** configured with appropriate credentials
2. **Existing Kinesis Data Stream** to consume from
3. **OpenObserve** instance with:
   - HTTP endpoint URL
   - Username and password for authentication
   - Organization and stream created

## Quick Start

### 1. Deploy a Consumer

```bash
# Make scripts executable
chmod +x deploy.sh cleanup.sh

# Run deployment script
./deploy.sh
```

The script will:
1. List all Kinesis Data Streams in your account
2. Let you select which stream to consume from
3. Ask which deployment option (Firehose or Lambda)
4. Prompt for OpenObserve configuration
5. Deploy the CloudFormation stack

### 2. Test the Integration

Send test data to your Kinesis stream:

```bash
# Simple text record
aws kinesis put-record \
  --stream-name my-stream \
  --partition-key test \
  --data "Hello from Kinesis" \
  --region us-east-1

# JSON record
aws kinesis put-record \
  --stream-name my-stream \
  --partition-key test \
  --data '{"message":"Test log","level":"info","timestamp":"2026-01-22T10:00:00Z"}' \
  --region us-east-1

# Multiple records
aws kinesis put-records \
  --stream-name my-stream \
  --records \
    Data=$(echo -n '{"event":"user_login"}' | base64),PartitionKey=user1 \
    Data=$(echo -n '{"event":"page_view"}' | base64),PartitionKey=user2 \
  --region us-east-1
```

### 3. Verify in OpenObserve

1. Log into your OpenObserve instance
2. Navigate to your organization/stream
3. Query for the test data
4. Set up dashboards and alerts

## Parameters

### Firehose Template Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `KinesisStreamArn` | ARN of existing Kinesis stream | Required |
| `StreamName` | OpenObserve stream name (org/stream) | `default/kinesis_logs` |
| `OpenObserveEndpoint` | OpenObserve API endpoint URL | Required |
| `OpenObserveAccessKey` | Base64 encoded credentials | Required |
| `EnableTransformation` | Enable Lambda transformation | `false` |
| `BufferIntervalSeconds` | Firehose buffer interval | `60` |
| `BufferSizeMB` | Firehose buffer size | `5` |

### Lambda Template Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `KinesisStreamArn` | ARN of existing Kinesis stream | Required |
| `StreamName` | OpenObserve stream name (org/stream) | `default/kinesis_logs` |
| `OpenObserveEndpoint` | OpenObserve API endpoint URL | Required |
| `OpenObserveAccessKey` | Base64 encoded credentials | Required |
| `BatchSize` | Records per Lambda invocation | `100` |
| `ParallelizationFactor` | Concurrent batches per shard | `1` |
| `MaximumBatchingWindowInSeconds` | Max wait time for batch | `10` |
| `BufferIntervalSeconds` | Firehose buffer interval | `60` |
| `BufferSizeMB` | Firehose buffer size | `5` |

## Data Transformation Examples

### Firehose Lambda Transformation

The built-in transformation function can be customized:

```python
def lambda_handler(event, context):
    output = []

    for record in event['records']:
        payload = base64.b64decode(record['data']).decode('utf-8')

        # Parse JSON
        data = json.loads(payload)

        # Add metadata
        data['_timestamp'] = record.get('approximateArrivalTimestamp', 0)
        data['_source'] = 'kinesis'

        # Filter out debug logs
        if data.get('level') == 'debug':
            output.append({
                'recordId': record['recordId'],
                'result': 'Dropped'
            })
            continue

        # Enrich with additional fields
        data['environment'] = os.environ.get('ENVIRONMENT', 'production')

        transformed = json.dumps(data) + '\n'

        output.append({
            'recordId': record['recordId'],
            'result': 'Ok',
            'data': base64.b64encode(transformed.encode('utf-8')).decode('utf-8')
        })

    return {'records': output}
```

### Lambda Consumer Transformation

For more complex processing:

```python
import requests

def lambda_handler(event, context):
    records_to_send = []

    for record in event['Records']:
        payload = base64.b64decode(record['kinesis']['data']).decode('utf-8')
        data = json.loads(payload)

        # Aggregate metrics
        if data.get('type') == 'metric':
            # Batch metrics together
            pass

        # Enrich with external API
        if 'user_id' in data:
            user_info = get_user_info(data['user_id'])
            data['user_metadata'] = user_info

        # Filter sensitive fields
        data.pop('password', None)
        data.pop('ssn', None)

        records_to_send.append({
            'Data': (json.dumps(data) + '\n').encode('utf-8')
        })

    # Send to Firehose
    firehose.put_record_batch(
        DeliveryStreamName=FIREHOSE_STREAM,
        Records=records_to_send
    )
```

## Cross-Account Stream Consumption

To consume from a Kinesis stream in another AWS account:

### 1. In the Source Account (Stream Owner)

Create a policy allowing cross-account access:

```bash
aws kinesis put-resource-policy \
  --resource-arn arn:aws:kinesis:region:SOURCE-ACCOUNT:stream/my-stream \
  --policy '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::CONSUMER-ACCOUNT:root"
      },
      "Action": [
        "kinesis:DescribeStream",
        "kinesis:GetRecords",
        "kinesis:GetShardIterator",
        "kinesis:ListShards"
      ],
      "Resource": "arn:aws:kinesis:region:SOURCE-ACCOUNT:stream/my-stream"
    }]
  }'
```

### 2. In the Consumer Account

Deploy the template using the cross-account stream ARN:

```bash
./deploy.sh
# When prompted, enter the ARN from the source account
```

### 3. IAM Role Trust Relationship

Ensure the consumer role can assume access:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Service": "firehose.amazonaws.com"
    },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {
        "sts:ExternalId": "CONSUMER-ACCOUNT-ID"
      }
    }
  }]
}
```

## Monitoring Consumer Lag

### Key Metrics to Monitor

1. **Iterator Age** (Kinesis)
   - How far behind the consumer is
   - Alert if > 1 minute for real-time processing
   - Alert if > 15 minutes for batch processing

2. **GetRecords.IteratorAgeMilliseconds** (Lambda)
   - Similar to Iterator Age
   - Specific to Lambda consumers

3. **Delivery to HttpEndpoint Success** (Firehose)
   - Percentage of successful deliveries
   - Should be close to 100%

4. **Lambda Errors** (if using Lambda)
   - Function errors
   - Throttles
   - Dead letter queue messages

### CloudWatch Alarms

Both templates include pre-configured alarms:

```bash
# View alarms
aws cloudwatch describe-alarms \
  --alarm-name-prefix "kinesis-firehose-" \
  --region us-east-1

# Get alarm history
aws cloudwatch describe-alarm-history \
  --alarm-name "kinesis-firehose-mystream-iterator-age-high" \
  --region us-east-1
```

### Custom Dashboard

Create a CloudWatch dashboard:

```bash
aws cloudwatch put-dashboard \
  --dashboard-name kinesis-to-openobserve \
  --dashboard-body file://dashboard.json
```

Example `dashboard.json`:

```json
{
  "widgets": [
    {
      "type": "metric",
      "properties": {
        "metrics": [
          ["AWS/Kinesis", "GetRecords.IteratorAgeMilliseconds", {"stat": "Maximum"}],
          ["AWS/Firehose", "DeliveryToHttpEndpoint.Success", {"stat": "Average"}],
          ["AWS/Lambda", "Errors", {"stat": "Sum"}]
        ],
        "period": 300,
        "stat": "Average",
        "region": "us-east-1",
        "title": "Kinesis to OpenObserve Health"
      }
    }
  ]
}
```

## Troubleshooting

### High Iterator Age

**Symptoms**: Data is delayed, iterator age metric is high

**Causes**:
1. Insufficient Firehose/Lambda throughput
2. Destination (OpenObserve) is slow or unavailable
3. Too much data transformation overhead

**Solutions**:

```bash
# For Firehose: Increase buffer size (processes larger batches)
aws cloudformation update-stack \
  --stack-name kinesis-firehose-mystream \
  --use-previous-template \
  --parameters ParameterKey=BufferSizeMB,ParameterValue=128 \
  --capabilities CAPABILITY_NAMED_IAM

# For Lambda: Increase parallelization
aws cloudformation update-stack \
  --stack-name kinesis-lambda-mystream \
  --use-previous-template \
  --parameters ParameterKey=ParallelizationFactor,ParameterValue=5 \
  --capabilities CAPABILITY_NAMED_IAM

# Increase Lambda memory (also increases CPU)
aws lambda update-function-configuration \
  --function-name kinesis-lambda-mystream-consumer \
  --memory-size 1024
```

### Delivery Failures

**Symptoms**: Data not appearing in OpenObserve, S3 backup bucket has files

**Causes**:
1. Incorrect OpenObserve endpoint or credentials
2. Network connectivity issues
3. OpenObserve rate limiting

**Solutions**:

```bash
# Check Firehose logs
aws logs tail /aws/kinesisfirehose/kinesis-firehose-mystream --follow

# Test OpenObserve connectivity
curl -X POST "https://your-instance.openobserve.ai/api/default/kinesis_logs/_json" \
  -H "Authorization: Basic $(echo -n 'user:pass' | base64)" \
  -d '{"test":"data"}'

# Check S3 backup bucket for failed records
aws s3 ls s3://kinesis-firehose-mystream-backup-ACCOUNT/failed/ --recursive

# Download and inspect failed records
aws s3 cp s3://kinesis-firehose-mystream-backup-ACCOUNT/failed/2026/01/22/file.gz - | gunzip
```

### Lambda Errors

**Symptoms**: DLQ has messages, Lambda errors in CloudWatch

**Solutions**:

```bash
# Check Lambda logs
aws logs tail /aws/lambda/kinesis-lambda-mystream-consumer --follow

# View DLQ messages
aws sqs receive-message \
  --queue-url https://sqs.us-east-1.amazonaws.com/ACCOUNT/kinesis-lambda-mystream-dlq \
  --max-number-of-messages 10

# Replay DLQ messages (after fixing issues)
# Create a script to re-process DLQ messages
```

### Permission Issues

**Symptoms**: Access denied errors in logs

**Solutions**:

```bash
# Verify Firehose role has Kinesis read permissions
aws iam simulate-principal-policy \
  --policy-source-arn $(aws iam get-role --role-name kinesis-firehose-mystream-firehose-role --query 'Role.Arn' --output text) \
  --action-names kinesis:GetRecords kinesis:DescribeStream \
  --resource-arns arn:aws:kinesis:us-east-1:ACCOUNT:stream/mystream

# Check Lambda execution role
aws iam get-role-policy \
  --role-name kinesis-lambda-mystream-consumer-role \
  --policy-name FirehoseWritePolicy
```

## Performance Tuning

### For High Throughput Streams (> 1 MB/s)

**Firehose Option**:
```yaml
BufferSizeMB: 128          # Max buffer size
BufferIntervalSeconds: 60  # Keep at 60 seconds
```

**Lambda Option**:
```yaml
BatchSize: 1000                        # Larger batches
ParallelizationFactor: 10              # Max parallelization
MemorySize: 1024                       # Increase Lambda memory
MaximumBatchingWindowInSeconds: 30     # Longer batching window
```

### For Low Latency Requirements

**Firehose Option**:
```yaml
BufferSizeMB: 1            # Minimum buffer
BufferIntervalSeconds: 60  # Cannot go lower than 60
```

**Lambda Option**:
```yaml
BatchSize: 10                          # Small batches
ParallelizationFactor: 5               # More parallelization
MaximumBatchingWindowInSeconds: 0      # No batching delay
```

### For Cost Optimization

**Firehose Option** (Recommended):
- Use Firehose Direct without Lambda transformation
- Larger buffers reduce costs
- Enable S3 lifecycle policies for backup

**Lambda Option**:
- Increase batch size to reduce invocations
- Use ARM64 architecture (Graviton2)
- Optimize Lambda memory allocation

```bash
# Update to ARM64 for ~20% cost savings
aws lambda update-function-configuration \
  --function-name kinesis-lambda-mystream-consumer \
  --architectures arm64
```

## Cost Estimation

### Example: 10 GB/day stream

**Option 1: Firehose Direct**
- Firehose: 10 GB × $0.029 = $0.29/day
- S3 backup (1% failed): 0.1 GB × $0.023 = $0.002/day
- **Total: ~$9/month**

**Option 2: Lambda + Firehose**
- Lambda: 1M requests × $0.20/M + compute = ~$0.30/day
- Firehose: 10 GB × $0.029 = $0.29/day
- S3 backup: $0.002/day
- **Total: ~$18/month**

**Recommendation**: Use Firehose Direct unless you need custom processing.

## Cleanup

Remove all deployed resources:

```bash
./cleanup.sh
```

The script will:
1. List all Kinesis to OpenObserve stacks
2. Let you select which to delete
3. Disable event source mappings (for Lambda stacks)
4. Empty S3 backup buckets
5. Delete CloudFormation stacks
6. Clean up all resources

**Note**: The source Kinesis Data Streams are NOT deleted.

## Advanced Use Cases

### Multi-Region Replication

Replicate Kinesis data across regions:

```bash
# Region 1: Consume and forward to OpenObserve
./deploy.sh  # Select stream in us-east-1

# Region 2: Consume same stream (if global)
AWS_DEFAULT_REGION=eu-west-1 ./deploy.sh
```

### Fan-Out to Multiple Destinations

Deploy multiple consumers for the same stream:

```bash
# Consumer 1: To OpenObserve
./deploy.sh  # Select Firehose option

# Consumer 2: To S3 Data Lake
# Deploy separate Firehose to S3

# Consumer 3: To ElasticSearch
# Deploy separate Lambda to ElasticSearch
```

### Data Enrichment Pipeline

```
Application → Kinesis Stream → Lambda (Enrich) → Kinesis Stream → Firehose → OpenObserve
```

## Security Best Practices

1. **Use Secrets Manager for credentials**:
   ```bash
   # Store OpenObserve credentials
   aws secretsmanager create-secret \
     --name openobserve/credentials \
     --secret-string '{"username":"admin","password":"secret"}'

   # Reference in Lambda
   secret = secretsmanager.get_secret_value(SecretId='openobserve/credentials')
   ```

2. **Enable encryption at rest**:
   - Kinesis streams support KMS encryption
   - S3 buckets use AES256 by default
   - Consider KMS for additional control

3. **Restrict IAM permissions**:
   - Use least privilege principle
   - Separate roles for different consumers
   - Enable CloudTrail for audit

4. **Network security**:
   - Use VPC endpoints for Kinesis
   - Deploy Lambda in VPC if needed
   - Use TLS for OpenObserve endpoint

## Support and Resources

- [AWS Kinesis Documentation](https://docs.aws.amazon.com/kinesis/)
- [AWS Firehose Documentation](https://docs.aws.amazon.com/firehose/)
- [OpenObserve Documentation](https://openobserve.ai/docs/)
- [Kinesis Producer Library](https://github.com/awslabs/amazon-kinesis-producer)

## License

MIT License - Feel free to modify and distribute.

## Contributing

Contributions welcome! Please submit pull requests or open issues for bugs and feature requests.
