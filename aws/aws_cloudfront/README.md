# CloudFront Logs to OpenObserve - CloudFormation Templates

Send CloudFront logs to OpenObserve using AWS CloudFormation templates with automated deployment scripts.

## Quick Start

### Using the Deploy Script (Recommended)

```bash
chmod +x deploy.sh
./deploy.sh
```

The script will:
1. Prompt for deployment type (Real-time or S3-based)
2. List available CloudFront distributions
3. Validate prerequisites and AWS credentials
4. Create unique stack with isolated resources
5. Configure CloudFront logging automatically

---

## Deployment Options

### Option 1: Real-time Logs (Monitoring)

**Architecture:**
```
CloudFront → Kinesis Stream → Lambda → Firehose → OpenObserve
                                           ↓
                                      S3 (Failed)
```

**Template:** `cloudfront-to-openobserve.yaml`

**Features:**
- ✅ Near real-time (seconds delay)
- ✅ TSV to JSON transformation
- ✅ Field selection available
- ✅ Built-in retry logic
- ❌ Higher cost (~$50/month per distribution)

**Best for:** Production monitoring, security analysis, real-time dashboards, alerting

---

### Option 2: S3-based Logs (Cost-effective)

**Architecture:**
```
CloudFront → S3 → Lambda → Firehose → OpenObserve
                              ↓
                         S3 (Failed)
```

**Template:** `cloudfront-to-openobserve-s3.yaml`

**Features:**
- ✅ Lower cost (~$18/month per distribution)
- ✅ W3C to JSON transformation
- ✅ All fields included
- ✅ S3 archival included
- ❌ Delayed (5-60 minutes)

**Best for:** Analytics, compliance, cost-sensitive environments, historical analysis

---

## Multiple Distributions Support

Deploy to multiple CloudFront distributions with isolated resources:

```bash
# Distribution 1
./deploy.sh  # Enter E1234EXAMPLE1

# Distribution 2
./deploy.sh  # Enter E5678EXAMPLE2

# Distribution 3
./deploy.sh  # Enter E9012EXAMPLE3
```

**Stack naming:**
- Real-time: `cf-realtime-<DISTRIBUTION-ID>`
- S3-based: `cf-s3-<DISTRIBUTION-ID>`

**Each deployment creates:**
- Dedicated CloudFormation stack
- Separate Kinesis/Firehose streams
- Independent Lambda functions
- Isolated S3 buckets
- Unique IAM roles

---

## Prerequisites

1. **AWS CLI** installed and configured
2. **jq** for JSON processing
3. **OpenObserve** account (cloud or self-hosted)
4. **AWS Permissions:**
   - CloudFormation (create/update/delete stacks)
   - S3 (bucket operations)
   - Lambda (create/update functions)
   - IAM (create/attach roles)
   - Kinesis (create streams/firehose)
   - CloudFront (get/update distributions)

---

## Configuration

Edit `deploy.sh` or set environment variables:

```bash
# Required
export OPENOBSERVE_ENDPOINT="https://api.openobserve.ai/api/YOUR-ORG/default/_kinesis_firehose"
export OPENOBSERVE_ACCESS_KEY="BASE64_ENCODED_CREDENTIALS"

# Optional
export STREAM_NAME="cloudfront-logs"
export AWS_PROFILE="your-profile"
export AWS_REGION="us-east-2"
```

### Get OpenObserve Credentials

```bash
# Generate base64 access key
echo -n "your-email@example.com:your-password" | base64
```

---

## Manual Deployment

### Real-time Logs

```bash
aws cloudformation create-stack \
  --stack-name cf-realtime-E1234EXAMPLE \
  --template-body file://cloudfront-to-openobserve.yaml \
  --parameters \
    ParameterKey=OpenObserveEndpoint,ParameterValue="https://api.openobserve.ai/..." \
    ParameterKey=OpenObserveAccessKey,ParameterValue="BASE64_KEY" \
    ParameterKey=StreamName,ParameterValue="cloudfront-logs" \
    ParameterKey=CloudFrontDistributionId,ParameterValue="E1234EXAMPLE" \
    ParameterKey=BackupS3BucketName,ParameterValue="cf-backup-12345" \
    ParameterKey=ShardCount,ParameterValue="1" \
  --capabilities CAPABILITY_IAM
```

### S3-based Logs

```bash
aws cloudformation create-stack \
  --stack-name cf-s3-E1234EXAMPLE \
  --template-body file://cloudfront-to-openobserve-s3.yaml \
  --parameters \
    ParameterKey=OpenObserveEndpoint,ParameterValue="https://api.openobserve.ai/..." \
    ParameterKey=OpenObserveAccessKey,ParameterValue="BASE64_KEY" \
    ParameterKey=StreamName,ParameterValue="cloudfront-logs" \
    ParameterKey=CloudFrontDistributionId,ParameterValue="E1234EXAMPLE" \
    ParameterKey=LogS3BucketName,ParameterValue="cf-logs-12345" \
    ParameterKey=BackupS3BucketName,ParameterValue="cf-backup-12345" \
    ParameterKey=LogPrefix,ParameterValue="cloudfront-logs/" \
  --capabilities CAPABILITY_IAM
```

---

## Cost Breakdown

### Per Distribution (Real-time)

| Resource | Monthly Cost |
|----------|--------------|
| Kinesis Data Stream (1 shard) | ~$30 |
| Kinesis Firehose | ~$15 |
| Lambda | ~$5 |
| S3 Storage | ~$0.50 |
| **Total** | **~$50** |

**Examples:**
- 3 distributions = ~$150/month
- 5 distributions = ~$250/month
- 10 distributions = ~$500/month

### Per Distribution (S3-based)

| Resource | Monthly Cost |
|----------|--------------|
| S3 Storage (logs) | ~$1 |
| Lambda | ~$2 |
| Kinesis Firehose | ~$15 |
| **Total** | **~$18** |

**Examples:**
- 3 distributions = ~$54/month
- 5 distributions = ~$90/month
- 10 distributions = ~$180/month

---

## Monitoring

### List All Stacks

```bash
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE \
  --query 'StackSummaries[?starts_with(StackName, `cf-`)].{Name:StackName,Status:StackStatus}' \
  --output table
```

### Check Lambda Logs

```bash
# Real-time
aws logs tail /aws/lambda/cf-realtime-E1234EXAMPLE-log-transformer --follow

# S3-based
aws logs tail /aws/lambda/cf-s3-E1234EXAMPLE-log-processor --follow
```

### Check Failed Records

```bash
BACKUP_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name cf-realtime-E1234EXAMPLE \
  --query 'Stacks[0].Outputs[?OutputKey==`BackupS3BucketName`].OutputValue' \
  --output text)

aws s3 ls s3://$BACKUP_BUCKET/failed-logs/ --recursive
```

### Firehose Metrics

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Firehose \
  --metric-name DeliveryToHttpEndpoint.Success \
  --dimensions Name=DeliveryStreamName,Value=cf-realtime-E1234EXAMPLE-to-openobserve \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

---

## Cleanup

### Using Cleanup Script

```bash
chmod +x cleanup.sh
./cleanup.sh
```

The script will:
1. Find all CloudFront-related stacks
2. Show resources to be deleted
3. Empty S3 buckets automatically
4. Remove CloudFront logging configuration
5. Delete CloudFormation stack

### Manual Cleanup

```bash
# Get stack resources
aws cloudformation describe-stack-resources \
  --stack-name cf-realtime-E1234EXAMPLE

# Empty S3 buckets
aws s3 rm s3://cf-backup-12345 --recursive

# Delete stack
aws cloudformation delete-stack --stack-name cf-realtime-E1234EXAMPLE

# Wait for completion
aws cloudformation wait stack-delete-complete --stack-name cf-realtime-E1234EXAMPLE
```

---

## Troubleshooting

### No Logs Appearing

**Real-time:**
- Verify real-time log config is attached to distribution
- Check Kinesis stream metrics
- Ensure traffic is flowing through CloudFront
- Check Firehose delivery success rate

**S3-based:**
- Verify S3 logging is enabled on distribution
- Wait 5-60 minutes for first logs
- Check Lambda execution logs
- Verify S3 bucket ACL settings (`BucketOwnerPreferred`)

### Lambda Processing Errors

**Real-time (TSV parsing):**
- Lambda expects tab-separated values from Kinesis
- Check logs for parsing errors
- Verify field order matches CloudFront config

**S3-based (W3C parsing):**
- Lambda expects gzipped w3c format from S3
- Check logs for decompression errors
- Verify S3 notification is triggering Lambda

### Permission Errors

```bash
# Check IAM role policies
aws iam get-role --role-name cf-realtime-E1234EXAMPLE-LambdaExecutionRole
aws iam list-attached-role-policies --role-name cf-realtime-E1234EXAMPLE-LambdaExecutionRole
```

### Circular Dependency (S3 template)

The S3 template has been fixed to avoid circular dependencies by:
- Using bucket name instead of ARN in IAM policies
- Adding `DependsOn` directives
- Enabling ACL support for CloudFront

---

## Advanced Configuration

### Custom Lambda Transformation

Edit the Lambda code in the template to add custom fields:

```python
transformed = {
    'timestamp': ...,
    'c-ip': ...,
    'sc-status': ...,
    # Add custom fields
    'environment': 'production',
    'team': 'platform',
    'cost_center': '12345'
}
```

### Log Sampling (Real-time only)

Reduce costs by sampling:

```yaml
SamplingRate: 50  # 50% of requests (default: 100)
```

### Multiple OpenObserve Streams

**Same stream (aggregated):**
```bash
export STREAM_NAME="cloudfront-logs"
./deploy.sh  # All distributions use same stream
```

**Separate streams:**
```bash
export STREAM_NAME="cloudfront-logs-prod"
./deploy.sh

export STREAM_NAME="cloudfront-logs-staging"
./deploy.sh
```

### Update Existing Stack

```bash
aws cloudformation update-stack \
  --stack-name cf-realtime-E1234EXAMPLE \
  --template-body file://cloudfront-to-openobserve.yaml \
  --parameters \
    ParameterKey=ShardCount,ParameterValue=2 \
    ParameterKey=OpenObserveEndpoint,UsePreviousValue=true \
    ParameterKey=OpenObserveAccessKey,UsePreviousValue=true \
    ParameterKey=StreamName,UsePreviousValue=true \
    ParameterKey=CloudFrontDistributionId,UsePreviousValue=true \
    ParameterKey=BackupS3BucketName,UsePreviousValue=true \
  --capabilities CAPABILITY_IAM
```

---

## Security Best Practices

1. **Use AWS Secrets Manager** for OpenObserve credentials
2. **Enable S3 encryption** at rest (already configured)
3. **Enable CloudTrail** for audit logging
4. **Restrict IAM roles** to least privilege
5. **Use VPC endpoints** for Kinesis/Firehose
6. **Rotate credentials** regularly
7. **Enable S3 versioning** on log buckets

---

## FAQ

**Q: Can logs be in JSON format?**
A: Yes! Lambda automatically converts TSV (real-time) or w3c (S3) to JSON before sending to OpenObserve.

**Q: Why "Selected fields: Unsupported" for S3 logs?**
A: CloudFront S3 logs are always in w3c format. Field selection only works with real-time logs. Lambda converts to JSON automatically.

**Q: Can I share resources across distributions?**
A: Not recommended. Each distribution gets isolated resources for easier management and troubleshooting.

**Q: What's the maximum number of distributions?**
A: AWS allows 200 CloudFormation stacks per region. Cost and management complexity are the practical limits.

**Q: Can I mix real-time and S3-based?**
A: Yes! Each distribution can use different deployment types.

**Q: How do I query multiple distributions in OpenObserve?**
A: Use the same stream name for all distributions, then filter by fields in OpenObserve queries.

---

## Files

- `cloudfront-to-openobserve.yaml` - Real-time logs template
- `cloudfront-to-openobserve-s3.yaml` - S3-based logs template
- `deploy.sh` - Interactive deployment script
- `cleanup.sh` - Resource cleanup script
- `README.md` - This file

---

## Support

- [AWS CloudFormation Docs](https://docs.aws.amazon.com/cloudformation/)
- [OpenObserve Docs](https://openobserve.ai/docs)
- [CloudFront Logging Guide](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/logging.html)

---

## Summary

✅ **Two deployment options:** Real-time ($50/mo) or S3-based ($18/mo)
✅ **Automated scripts:** `deploy.sh` and `cleanup.sh`
✅ **Multi-distribution support:** Isolated stacks per distribution
✅ **Auto JSON conversion:** Lambda transforms logs automatically
✅ **Easy management:** List, update, delete individual stacks
✅ **Production ready:** Security, monitoring, cost optimization included
