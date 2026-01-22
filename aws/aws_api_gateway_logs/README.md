# API Gateway Access Logs to OpenObserve

Stream AWS API Gateway access logs to OpenObserve for real-time monitoring, analysis, and visualization.

## Overview

This CloudFormation template creates an automated pipeline to stream API Gateway access logs to OpenObserve:

```
API Gateway → CloudWatch Logs → Kinesis Data Stream → Lambda Transform → Firehose → OpenObserve
                                                                              ↓
                                                                         S3 (Backup)
```

### Key Features

- **Real-time log streaming**: Near real-time delivery of API access logs to OpenObserve
- **Structured parsing**: Lambda transforms raw logs into structured JSON with enriched fields
- **Performance monitoring**: Automatic categorization of response times and status codes
- **Flexible filtering**: Optional CloudWatch Logs filter patterns to stream only relevant logs
- **Automatic retry**: Failed deliveries are retried and backed up to S3
- **Cost-effective**: Pay only for what you use with configurable shard counts

## Architecture Components

1. **CloudWatch Log Group**: Stores API Gateway access logs (`/aws/apigateway/{api-id}/{stage}`)
2. **Kinesis Data Stream**: High-throughput log ingestion (24-hour retention)
3. **Lambda Function**: Transforms and enriches log data
4. **Kinesis Firehose**: Delivers logs to OpenObserve with retry logic
5. **S3 Bucket**: Backup storage for failed deliveries (30-day lifecycle)
6. **IAM Roles**: Secure permissions for each component

## Prerequisites

- AWS CLI configured with appropriate credentials
- API Gateway REST API deployed with at least one stage
- OpenObserve account and endpoint
- `jq` installed for JSON processing
- Bash shell (Linux/macOS or WSL on Windows)

## Quick Start

### 1. Enable API Gateway Access Logging

Before deploying the stack, access logging must be configured in API Gateway:

#### Option A: Using AWS Console

1. Go to **API Gateway Console**
2. Select your API
3. Click on **Stages** in the left navigation
4. Select your stage (e.g., `prod`)
5. Click **Logs/Tracing** tab
6. Under **CloudWatch Settings**:
   - Enable **Access Logging**
   - The script will provide the CloudWatch Log Group ARN after stack creation
   - Set the **Log Format** (see formats below)

#### Option B: Using AWS CLI

The deployment script can automatically enable access logging for you.

### 2. Deploy the Stack

```bash
cd /Users/mdmosaraf/Documents/cloudformation/aws_api_gateway_logs
chmod +x deploy.sh
./deploy.sh
```

The script will:
1. List your API Gateways
2. Prompt for API Gateway ID and Stage name
3. Check if access logging is enabled
4. Create the CloudFormation stack
5. Optionally enable access logging with recommended format

### 3. Verify Deployment

```bash
# Check stack status
aws cloudformation describe-stacks \
  --stack-name apigateway-logs-{api-id}-{stage} \
  --query 'Stacks[0].StackStatus'

# View stack outputs
aws cloudformation describe-stacks \
  --stack-name apigateway-logs-{api-id}-{stage} \
  --query 'Stacks[0].Outputs'
```

## API Gateway Log Formats

### Recommended JSON Format (Structured)

```json
{
  "requestId": "$context.requestId",
  "sourceIp": "$context.identity.sourceIp",
  "method": "$context.httpMethod",
  "resourcePath": "$context.resourcePath",
  "statusCode": "$context.status",
  "responseLength": "$context.responseLength",
  "requestTime": "$context.requestTime",
  "latency": "$context.responseLatency",
  "integrationLatency": "$context.integrationLatency",
  "userAgent": "$context.identity.userAgent",
  "protocol": "$context.protocol"
}
```

### Custom Key-Value Format

```
RequestId: $context.requestId, SourceIP: $context.identity.sourceIp, Method: $context.httpMethod, ResourcePath: $context.resourcePath, StatusCode: $context.status, ResponseLength: $context.responseLength, RequestTime: $context.requestTime, Latency: $context.responseLatency, IntegrationLatency: $context.integrationLatency
```

### CLF (Common Log Format)

```
$context.identity.sourceIp $context.identity.caller $context.identity.user [$context.requestTime] "$context.httpMethod $context.resourcePath $context.protocol" $context.status $context.responseLength
```

### CSV Format

```
$context.requestId,$context.identity.sourceIp,$context.httpMethod,$context.resourcePath,$context.status,$context.responseLength,$context.requestTime,$context.responseLatency
```

### XML Format

```xml
<request id="$context.requestId">
  <sourceIp>$context.identity.sourceIp</sourceIp>
  <method>$context.httpMethod</method>
  <path>$context.resourcePath</path>
  <status>$context.status</status>
  <responseLength>$context.responseLength</responseLength>
  <latency>$context.responseLatency</latency>
</request>
```

## Available Context Variables

| Variable | Description |
|----------|-------------|
| `$context.requestId` | Unique request identifier |
| `$context.identity.sourceIp` | Client IP address |
| `$context.httpMethod` | HTTP method (GET, POST, etc.) |
| `$context.resourcePath` | Resource path (e.g., /users/{id}) |
| `$context.status` | HTTP status code |
| `$context.responseLength` | Response size in bytes |
| `$context.requestTime` | Request timestamp |
| `$context.responseLatency` | Total latency in milliseconds |
| `$context.integrationLatency` | Backend integration latency |
| `$context.identity.userAgent` | Client user agent |
| `$context.protocol` | Request protocol (HTTP/1.1, HTTP/2) |
| `$context.error.message` | Error message (if any) |
| `$context.error.messageString` | Error details |
| `$context.authorizer.principalId` | Authorized principal ID |
| `$context.requestTimeEpoch` | Request time in epoch milliseconds |

Full list: https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-mapping-template-reference.html#context-variable-reference

## CloudWatch Logs Filter Patterns

### Stream All Logs (Default)

```
# Leave FilterPattern empty
```

### Errors Only (4xx and 5xx)

```
[statusCode >= 400]
```

### Server Errors Only (5xx)

```
[statusCode >= 500]
```

### Slow Requests (>1 second)

```
[latency > 1000]
```

### Specific Resource Path

```
[resourcePath = "/api/users*"]
```

### Specific HTTP Methods

```
[method = "POST" || method = "PUT" || method = "DELETE"]
```

### Combine Conditions

```
[statusCode >= 400 && latency > 500]
```

## Lambda Transformation

The Lambda function automatically:

1. **Decompresses** CloudWatch Logs gzip data
2. **Parses** logs (supports JSON and custom formats)
3. **Enriches** with additional fields:
   - `statusCategory`: Success, Redirect, ClientError, ServerError
   - `performanceIssue`: Normal, Warning, Slow
4. **Transforms** to structured JSON for OpenObserve
5. **Handles errors** gracefully with fallback to raw message

### Enriched Fields

- **statusCategory**: Categorizes HTTP status codes
  - `Success`: 2xx
  - `Redirect`: 3xx
  - `ClientError`: 4xx
  - `ServerError`: 5xx

- **performanceIssue**: Flags slow requests
  - `Normal`: < 1000ms
  - `Warning`: 1000-3000ms
  - `Slow`: > 3000ms

## OpenObserve Queries

### Error Rate Analysis

```sql
SELECT
  statusCategory,
  COUNT(*) as count
FROM apigateway_logs
WHERE timestamp > now() - interval '1 hour'
GROUP BY statusCategory
```

### Top Slow Endpoints

```sql
SELECT
  resourcePath,
  AVG(latency) as avg_latency,
  MAX(latency) as max_latency,
  COUNT(*) as count
FROM apigateway_logs
WHERE latency > 1000
GROUP BY resourcePath
ORDER BY avg_latency DESC
LIMIT 10
```

### Traffic by Source IP

```sql
SELECT
  sourceIp,
  COUNT(*) as requests,
  COUNT_IF(statusCode >= 400) as errors
FROM apigateway_logs
WHERE timestamp > now() - interval '1 hour'
GROUP BY sourceIp
ORDER BY requests DESC
LIMIT 20
```

### Request Rate Over Time

```sql
SELECT
  time_bucket('5 minutes', timestamp) as time_bucket,
  COUNT(*) as request_count,
  COUNT_IF(statusCode >= 400) as error_count
FROM apigateway_logs
GROUP BY time_bucket
ORDER BY time_bucket
```

### Latency Percentiles

```sql
SELECT
  resourcePath,
  percentile_cont(0.50) WITHIN GROUP (ORDER BY latency) as p50,
  percentile_cont(0.95) WITHIN GROUP (ORDER BY latency) as p95,
  percentile_cont(0.99) WITHIN GROUP (ORDER BY latency) as p99
FROM apigateway_logs
WHERE timestamp > now() - interval '1 hour'
GROUP BY resourcePath
```

### User Agent Analysis

```sql
SELECT
  userAgent,
  COUNT(*) as count,
  AVG(latency) as avg_latency
FROM apigateway_logs
WHERE timestamp > now() - interval '24 hours'
GROUP BY userAgent
ORDER BY count DESC
LIMIT 20
```

## Cost Breakdown

### Monthly Costs (Estimated)

| Component | Cost (per month) |
|-----------|------------------|
| Kinesis Data Stream (1 shard) | ~$30 |
| Kinesis Firehose | ~$0.029 per GB |
| Lambda (1M invocations) | ~$0.20 |
| CloudWatch Logs (1 GB ingestion) | ~$0.50 |
| S3 Storage (failed records) | ~$0.023 per GB |
| Data Transfer | ~$0.09 per GB |

**Total (Low Traffic)**: ~$35-45/month
**Total (Medium Traffic - 100GB/month)**: ~$65-85/month
**Total (High Traffic - 1TB/month)**: ~$200-250/month

### Cost Optimization Tips

1. **Use Filter Patterns**: Stream only necessary logs (errors, slow requests)
2. **Reduce Log Retention**: Set CloudWatch Logs retention to 3-7 days
3. **Optimize Log Format**: Use minimal fields, avoid verbose formats
4. **Shard Auto-scaling**: Adjust Kinesis shards based on traffic
5. **Compress Logs**: Enable GZIP compression (already configured)
6. **Monitor Failed Records**: Check S3 backup bucket regularly

## Monitoring

### Kinesis Stream Metrics

```bash
# Incoming records
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name IncomingRecords \
  --dimensions Name=StreamName,Value=apigateway-logs-{api-id}-{stage}-apigateway-logs \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum

# Write throughput exceeded
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name WriteProvisionedThroughputExceeded \
  --dimensions Name=StreamName,Value=apigateway-logs-{api-id}-{stage}-apigateway-logs \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

### Firehose Metrics

```bash
# Delivery success
aws cloudwatch get-metric-statistics \
  --namespace AWS/Firehose \
  --metric-name DeliveryToHttpEndpoint.Success \
  --dimensions Name=DeliveryStreamName,Value=apigateway-logs-{api-id}-{stage}-to-openobserve \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

### Lambda Metrics

```bash
# Lambda errors
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions Name=FunctionName,Value=apigateway-logs-{api-id}-{stage}-log-transformer \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

### View Lambda Logs

```bash
# Tail Lambda logs in real-time
aws logs tail /aws/lambda/apigateway-logs-{api-id}-{stage}-log-transformer --follow

# Get recent errors
aws logs filter-log-events \
  --log-group-name /aws/lambda/apigateway-logs-{api-id}-{stage}-log-transformer \
  --filter-pattern "ERROR" \
  --start-time $(date -u -d '1 hour ago' +%s)000
```

## Troubleshooting

### No Logs in OpenObserve

1. **Check API Gateway access logging is enabled**:
   ```bash
   aws apigateway get-stage \
     --rest-api-id {api-id} \
     --stage-name {stage} \
     --query 'accessLogSettings'
   ```

2. **Verify CloudWatch Logs are being written**:
   ```bash
   aws logs describe-log-streams \
     --log-group-name /aws/apigateway/{api-id}/{stage} \
     --order-by LastEventTime \
     --descending \
     --max-items 5
   ```

3. **Check subscription filter**:
   ```bash
   aws logs describe-subscription-filters \
     --log-group-name /aws/apigateway/{api-id}/{stage}
   ```

4. **Verify Kinesis stream is receiving data**:
   ```bash
   aws kinesis describe-stream-summary \
     --stream-name apigateway-logs-{api-id}-{stage}-apigateway-logs
   ```

5. **Check Lambda transformation errors**:
   ```bash
   aws logs tail /aws/lambda/apigateway-logs-{api-id}-{stage}-log-transformer \
     --since 1h \
     --filter-pattern "ERROR"
   ```

### Slow Delivery to OpenObserve

1. **Increase Kinesis shards**: Update stack with higher `ShardCount`
2. **Check Firehose buffer settings**: Reduce `IntervalInSeconds` (minimum 60s)
3. **Verify OpenObserve endpoint**: Test with curl
4. **Monitor Firehose metrics**: Check for throttling or errors

### High Costs

1. **Review CloudWatch Logs volume**:
   ```bash
   aws logs describe-log-groups \
     --log-group-name-prefix /aws/apigateway
   ```

2. **Implement filter patterns**: Stream only errors or slow requests
3. **Reduce log retention**: Set to 3-7 days instead of default
4. **Optimize log format**: Remove unnecessary fields

### Failed Record Delivery

1. **Check S3 backup bucket**:
   ```bash
   aws s3 ls s3://{backup-bucket}/failed-logs/ --recursive
   ```

2. **Download and inspect failed records**:
   ```bash
   aws s3 cp s3://{backup-bucket}/failed-logs/{file} - | gunzip
   ```

3. **Check OpenObserve endpoint health**: Verify authentication and endpoint URL
4. **Review Firehose error logs**: Check CloudWatch Logs for Firehose errors

### API Gateway Logging Not Enabled

If you get an error about missing permissions:

```bash
# Create account-level settings (one-time setup)
aws apigateway update-account \
  --patch-operations \
    op=replace,path=/cloudwatchRoleArn,value=arn:aws:iam::{account-id}:role/APIGatewayCloudWatchLogsRole
```

## Stack Management

### Update Existing Stack

```bash
# Update with new parameters
aws cloudformation update-stack \
  --stack-name apigateway-logs-{api-id}-{stage} \
  --template-body file://apigateway-logs-to-openobserve.yaml \
  --parameters \
    ParameterKey=ShardCount,ParameterValue=2 \
  --capabilities CAPABILITY_IAM
```

### Delete Stack

```bash
# Run cleanup script
./cleanup.sh

# Or manually
aws cloudformation delete-stack \
  --stack-name apigateway-logs-{api-id}-{stage}
```

### Deploy Multiple Stages

You can deploy separate stacks for each API Gateway stage:

```bash
# Deploy for production
./deploy.sh  # Select prod stage

# Deploy for development
./deploy.sh  # Select dev stage

# Deploy for staging
./deploy.sh  # Select staging stage
```

Each deployment creates a unique stack: `apigateway-logs-{api-id}-{stage}`

## Security Best Practices

1. **Use AWS Secrets Manager** for OpenObserve access keys (instead of parameters)
2. **Enable S3 bucket encryption** (enabled by default in template)
3. **Restrict IAM permissions** to least privilege
4. **Enable CloudTrail** to audit API calls
5. **Use VPC endpoints** for private connectivity (optional)
6. **Rotate OpenObserve credentials** regularly
7. **Monitor failed deliveries** in S3 for sensitive data exposure

## Advanced Configuration

### Custom Lambda Transformation

Edit the Lambda function code in the CloudFormation template to:
- Add custom field parsing
- Implement data masking for PII
- Add custom enrichment logic
- Integrate with external APIs

### VPC Deployment

To deploy Lambda in VPC for private connectivity:

1. Add VPC configuration to Lambda function
2. Create VPC endpoints for Kinesis and S3
3. Update security groups to allow outbound HTTPS

### Multi-Region Deployment

Deploy separate stacks in each region:

```bash
AWS_REGION=us-east-1 ./deploy.sh
AWS_REGION=us-west-2 ./deploy.sh
AWS_REGION=eu-west-1 ./deploy.sh
```

## References

- [API Gateway Access Logging](https://docs.aws.amazon.com/apigateway/latest/developerguide/set-up-logging.html)
- [CloudWatch Logs Filter Patterns](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html)
- [Kinesis Data Streams](https://docs.aws.amazon.com/streams/latest/dev/introduction.html)
- [Kinesis Firehose](https://docs.aws.amazon.com/firehose/latest/dev/what-is-this-service.html)
- [OpenObserve Documentation](https://openobserve.ai/docs)
- [API Gateway Context Variables](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-mapping-template-reference.html#context-variable-reference)

## Support

For issues or questions:
- Check [Troubleshooting](#troubleshooting) section
- Review CloudWatch Logs for errors
- Inspect failed records in S3 backup bucket
- Verify OpenObserve endpoint connectivity

## License

This project is provided as-is for use with AWS and OpenObserve.
