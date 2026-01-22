# Route53 Query Logs to OpenObserve

Stream AWS Route53 DNS query logs to OpenObserve for real-time DNS monitoring, analytics, and security insights.

## Architecture

```
Route53 → CloudWatch Logs → Kinesis Data Stream → Lambda Transform → Firehose → OpenObserve
                                                                              ↓
                                                                         S3 Backup (failures)
```

### Components

1. **Route53 Query Logging**: Captures all DNS queries for a hosted zone
2. **CloudWatch Logs**: Receives query logs in `/aws/route53/<hosted-zone-id>`
3. **Kinesis Data Stream**: Ingests logs from CloudWatch subscription filter
4. **Lambda Transform**: Parses Route53 log format and converts to JSON
5. **Kinesis Firehose**: Delivers transformed logs to OpenObserve
6. **S3 Backup**: Stores failed deliveries for recovery

## Route53 Query Log Format

Route53 query logs are space-delimited with the following fields:

```
version account-id hosted-zone-id query-timestamp query-name query-type response-code protocol edge-location resolver-ip edns-client-subnet
```

### Example Log Entry

```
1.0 123456789012 Z1234567890ABC 2024-01-15T12:34:56.789Z example.com A NOERROR UDP IAD12-C1 192.0.2.1 192.0.2.0/24
```

### Field Descriptions

| Field | Description | Example |
|-------|-------------|---------|
| **version** | Log format version | `1.0` |
| **account-id** | AWS account ID | `123456789012` |
| **hosted-zone-id** | Route53 hosted zone ID | `Z1234567890ABC` |
| **query-timestamp** | Query timestamp (ISO 8601) | `2024-01-15T12:34:56.789Z` |
| **query-name** | Domain queried | `example.com` |
| **query-type** | DNS record type | `A`, `AAAA`, `CNAME`, `MX`, `TXT` |
| **response-code** | DNS response code | `NOERROR`, `NXDOMAIN`, `SERVFAIL` |
| **protocol** | Query protocol | `UDP`, `TCP` |
| **edge-location** | CloudFront edge location | `IAD12-C1` |
| **resolver-ip** | IP of DNS resolver | `192.0.2.1` |
| **edns-client-subnet** | EDNS client subnet | `192.0.2.0/24` or `-` |

### DNS Query Types

Common DNS query types captured:

- **A**: IPv4 address
- **AAAA**: IPv6 address
- **CNAME**: Canonical name (alias)
- **MX**: Mail exchange server
- **TXT**: Text records (SPF, DKIM, etc.)
- **NS**: Name server
- **SOA**: Start of authority
- **PTR**: Pointer (reverse DNS)
- **SRV**: Service locator
- **CAA**: Certificate authority authorization

### DNS Response Codes

- **NOERROR**: Successful query
- **NXDOMAIN**: Domain does not exist
- **SERVFAIL**: Server failure
- **REFUSED**: Query refused
- **FORMERR**: Format error
- **NOTIMP**: Not implemented

## Prerequisites

- AWS CLI configured with appropriate credentials
- `jq` installed for JSON processing
- Route53 hosted zone (public or private)
- OpenObserve account and API credentials
- Permissions:
  - Route53: `route53:CreateQueryLoggingConfig`, `route53:DeleteQueryLoggingConfig`
  - CloudWatch Logs: `logs:CreateLogGroup`, `logs:PutSubscriptionFilter`
  - CloudFormation: Full stack management
  - Kinesis: Stream and Firehose management
  - Lambda: Function creation and execution
  - S3: Bucket creation and management
  - IAM: Role and policy creation

## Quick Start

### 1. Deploy Stack

```bash
./deploy.sh
```

The script will:
1. List all Route53 hosted zones
2. Prompt you to select a hosted zone
3. Create CloudWatch log group (`/aws/route53/<zone-id>`)
4. Enable Route53 query logging
5. Set up Kinesis stream and Firehose
6. Deploy Lambda transformation function
7. Configure subscription filter

### 2. Configure OpenObserve Credentials

Edit `deploy.sh` to set your OpenObserve endpoint and access key:

```bash
OPENOBSERVE_ENDPOINT="https://api.openobserve.ai/aws/your-org/default/_kinesis_firehose"
OPENOBSERVE_ACCESS_KEY="base64-encoded-credentials"
```

Or set as environment variables:

```bash
export OPENOBSERVE_ENDPOINT="https://..."
export OPENOBSERVE_ACCESS_KEY="..."
./deploy.sh
```

### 3. Monitor Logs

Query logs will appear in OpenObserve within seconds of DNS queries being made.

## Stack Naming Convention

Stacks are named based on the hosted zone ID:

```
route53-<HOSTED-ZONE-ID>
```

Example: `route53-Z1234567890ABC`

This allows multiple stacks (one per hosted zone) to coexist.

## Deployment Details

### Stack Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| **OpenObserveEndpoint** | OpenObserve Kinesis endpoint URL | Required |
| **OpenObserveAccessKey** | Base64 encoded credentials | Required |
| **StreamName** | OpenObserve stream name | `route53-query-logs` |
| **HostedZoneId** | Route53 hosted zone ID | Prompted |
| **ShardCount** | Kinesis stream shards | `1` |
| **BackupS3BucketName** | S3 bucket for failures | Auto-generated |

### Resources Created

- **AWS::Logs::LogGroup**: CloudWatch log group for Route53
- **AWS::Route53::QueryLoggingConfig**: Query logging configuration
- **AWS::Kinesis::Stream**: Data stream for log ingestion
- **AWS::Lambda::Function**: Log transformation function
- **AWS::KinesisFirehose::DeliveryStream**: Firehose to OpenObserve
- **AWS::S3::Bucket**: Backup bucket for failed deliveries
- **AWS::Logs::SubscriptionFilter**: CloudWatch to Kinesis subscription
- **AWS::IAM::Role** (x3): Permissions for Lambda, Firehose, CloudWatch

## Log Transformation

The Lambda function transforms Route53 logs from space-delimited format to JSON:

### Input (Raw Log)

```
1.0 123456789012 Z1234567890ABC 2024-01-15T12:34:56.789Z api.example.com A NOERROR UDP IAD12-C1 192.0.2.1 192.0.2.0/24
```

### Output (JSON)

```json
{
  "timestamp": 1705322096789,
  "logGroup": "/aws/route53/Z1234567890ABC",
  "logStream": "stream-name",
  "id": "event-id",
  "service": "route53",
  "log_type": "query_log",
  "version": "1.0",
  "account_id": "123456789012",
  "hosted_zone_id": "Z1234567890ABC",
  "query_timestamp": "2024-01-15T12:34:56.789Z",
  "query_name": "api.example.com",
  "query_type": "A",
  "response_code": "NOERROR",
  "protocol": "UDP",
  "edge_location": "IAD12-C1",
  "resolver_ip": "192.0.2.1",
  "edns_client_subnet": "192.0.2.0/24",
  "is_error": false,
  "is_tcp": false,
  "has_edns": true,
  "apex_domain": "example.com",
  "subdomain": "api",
  "query_type_category": "common"
}
```

### Enhanced Fields

The Lambda function adds analytics fields:

- **is_error**: `true` if response code is not `NOERROR`
- **is_tcp**: `true` if protocol is TCP (often indicates large responses or zone transfers)
- **has_edns**: `true` if EDNS client subnet is present
- **apex_domain**: Root domain (e.g., `example.com`)
- **subdomain**: Subdomain portion (e.g., `api` from `api.example.com`)
- **query_type_category**: `common` for A/AAAA/CNAME/MX/TXT/NS/SOA/PTR/SRV, `other` otherwise

## DNS Analytics Use Cases

### 1. Query Volume Analysis

Track DNS query rates by domain, type, and location:

```sql
SELECT
  query_name,
  COUNT(*) as query_count,
  query_type
FROM route53_logs
WHERE timestamp > NOW() - INTERVAL '1 hour'
GROUP BY query_name, query_type
ORDER BY query_count DESC
LIMIT 20
```

### 2. Error Detection

Monitor DNS failures and NXDOMAIN responses:

```sql
SELECT
  query_name,
  response_code,
  COUNT(*) as error_count
FROM route53_logs
WHERE is_error = true
  AND timestamp > NOW() - INTERVAL '24 hours'
GROUP BY query_name, response_code
ORDER BY error_count DESC
```

### 3. Geographic Distribution

Analyze query sources by edge location:

```sql
SELECT
  edge_location,
  COUNT(*) as queries,
  COUNT(DISTINCT resolver_ip) as unique_resolvers
FROM route53_logs
WHERE timestamp > NOW() - INTERVAL '1 hour'
GROUP BY edge_location
ORDER BY queries DESC
```

### 4. Protocol Analysis

Identify TCP queries (may indicate zone transfers or large responses):

```sql
SELECT
  query_name,
  query_type,
  COUNT(*) as tcp_queries
FROM route53_logs
WHERE is_tcp = true
  AND timestamp > NOW() - INTERVAL '24 hours'
GROUP BY query_name, query_type
ORDER BY tcp_queries DESC
```

### 5. Subdomain Discovery

Find all subdomains being queried:

```sql
SELECT DISTINCT
  subdomain,
  apex_domain,
  query_type
FROM route53_logs
WHERE subdomain IS NOT NULL
  AND timestamp > NOW() - INTERVAL '7 days'
ORDER BY apex_domain, subdomain
```

### 6. Security Monitoring

Detect potential DNS tunneling or DGA (Domain Generation Algorithm) attacks:

```sql
-- Find unusually long domain names
SELECT
  query_name,
  LENGTH(query_name) as name_length,
  query_type,
  COUNT(*) as query_count
FROM route53_logs
WHERE LENGTH(query_name) > 50
  AND timestamp > NOW() - INTERVAL '1 hour'
GROUP BY query_name, query_type
ORDER BY name_length DESC
```

### 7. Resolver Analysis

Identify top DNS resolvers querying your domains:

```sql
SELECT
  resolver_ip,
  COUNT(*) as query_count,
  COUNT(DISTINCT query_name) as unique_domains
FROM route53_logs
WHERE timestamp > NOW() - INTERVAL '1 hour'
GROUP BY resolver_ip
ORDER BY query_count DESC
LIMIT 10
```

## Geolocation Enrichment

Enhance analytics by enriching resolver IPs with geolocation data:

### Option 1: MaxMind GeoIP (Recommended)

Use MaxMind GeoIP database to map resolver IPs to countries/cities:

```python
import geoip2.database

reader = geoip2.database.Reader('/path/to/GeoLite2-City.mmdb')

def enrich_log(log_entry):
    try:
        response = reader.city(log_entry['resolver_ip'])
        log_entry['resolver_country'] = response.country.iso_code
        log_entry['resolver_city'] = response.city.name
        log_entry['resolver_lat'] = response.location.latitude
        log_entry['resolver_lon'] = response.location.longitude
    except:
        pass
    return log_entry
```

### Option 2: AWS Lambda Enrichment

Modify the Lambda transformation function to include GeoIP lookups:

1. Deploy GeoIP database to Lambda layer
2. Add enrichment logic in transformation function
3. Include geographic fields in output JSON

### Geographic Queries

With geolocation enrichment:

```sql
SELECT
  resolver_country,
  resolver_city,
  COUNT(*) as queries
FROM route53_logs
WHERE timestamp > NOW() - INTERVAL '24 hours'
GROUP BY resolver_country, resolver_city
ORDER BY queries DESC
```

## Testing

### Generate Test Queries

Perform DNS lookups to generate query logs:

```bash
# Get your hosted zone's nameservers
NAMESERVER=$(aws route53 get-hosted-zone \
  --id Z1234567890ABC \
  --query 'DelegationSet.NameServers[0]' \
  --output text)

# Perform DNS queries
dig @$NAMESERVER example.com A
dig @$NAMESERVER www.example.com AAAA
nslookup example.com $NAMESERVER
```

### View CloudWatch Logs

```bash
aws logs tail /aws/route53/Z1234567890ABC --follow
```

### Check Kinesis Metrics

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name IncomingRecords \
  --dimensions Name=StreamName,Value=route53-Z1234567890ABC-route53-logs \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

### Monitor Lambda

```bash
aws logs tail /aws/lambda/route53-Z1234567890ABC-route53-transformer --follow
```

## Cost Estimation

### Route53 Query Logging

- **$0.50 per million queries logged**
- First 1 billion queries/month: $0.50/million
- Example: 10 million queries/month = **$5/month**

### CloudWatch Logs

- **$0.50 per GB ingested**
- **$0.03 per GB stored**
- Average log size: ~200 bytes per query
- Example: 10 million queries = 2 GB = **$1/month ingestion + $0.06/month storage**

### Kinesis Data Streams

- **$0.015 per shard-hour**
- 1 shard = 1 MB/s or 1,000 records/s
- Example: 1 shard = 24 hours × 30 days × $0.015 = **$10.80/month**

### Kinesis Firehose

- **$0.029 per GB ingested**
- Example: 2 GB/month = **$0.06/month**

### Lambda

- **$0.20 per 1 million requests**
- **$0.0000166667 per GB-second**
- Example: 10 million invocations × 256 MB × 100 ms = **$2 + $0.42 = $2.42/month**

### S3 (Backup)

- **$0.023 per GB stored**
- Minimal cost for failed records (typically < 100 MB)
- Example: **$0.01/month**

### Total Estimated Cost

For **10 million DNS queries per month**:

| Component | Monthly Cost |
|-----------|--------------|
| Route53 Query Logging | $5.00 |
| CloudWatch Logs | $1.06 |
| Kinesis Stream (1 shard) | $10.80 |
| Kinesis Firehose | $0.06 |
| Lambda | $2.42 |
| S3 Backup | $0.01 |
| **Total** | **~$19.35/month** |

### Cost Optimization

1. **Adjust shard count**: Use on-demand mode for variable traffic
2. **Filter logs**: Only log specific query types or domains (requires custom setup)
3. **Reduce retention**: Lower CloudWatch Logs retention from 7 to 1 day
4. **Batch processing**: Increase Firehose buffer size to reduce Lambda invocations

## Cleanup

Remove all resources for a hosted zone:

```bash
./cleanup.sh
```

The script will:
1. List all Route53 stacks
2. Prompt for selection
3. Delete query logging configuration
4. Remove subscription filters
5. Empty and delete S3 buckets
6. Delete CloudFormation stack

## Troubleshooting

### No Logs Appearing

1. **Check query logging config**:
   ```bash
   aws route53 list-query-logging-configs --hosted-zone-id Z1234567890ABC
   ```

2. **Verify CloudWatch log group**:
   ```bash
   aws logs describe-log-groups --log-group-name-prefix /aws/route53/
   ```

3. **Check subscription filter**:
   ```bash
   aws logs describe-subscription-filters --log-group-name /aws/route53/Z1234567890ABC
   ```

### Lambda Errors

View Lambda logs:
```bash
aws logs tail /aws/lambda/route53-Z1234567890ABC-route53-transformer --follow
```

### Firehose Failures

Check S3 backup bucket for failed records:
```bash
aws s3 ls s3://route53-logs-backup-123456789012-1234567890/failed-logs/ --recursive
```

### Stack Creation Fails

View CloudFormation events:
```bash
aws cloudformation describe-stack-events \
  --stack-name route53-Z1234567890ABC \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`]' \
  --output table
```

## Security Considerations

### IAM Permissions

The stack creates minimal IAM roles with least-privilege access:

- **Lambda**: Read from Kinesis, write CloudWatch Logs
- **Firehose**: Read from Kinesis, write to S3 and OpenObserve
- **CloudWatch Logs**: Write to Kinesis

### Data Privacy

Route53 query logs contain:
- Domain names queried
- Resolver IP addresses (may be PII in some jurisdictions)
- Query timestamps

Ensure compliance with:
- GDPR (EU)
- CCPA (California)
- Your organization's data retention policies

### Encryption

- **CloudWatch Logs**: Encrypted at rest (AWS managed keys)
- **Kinesis Stream**: Encryption available (modify template to add)
- **S3 Backup**: AES-256 encryption enabled
- **Firehose**: GZIP compression in transit

### Network Security

- All AWS resources use VPC endpoints where applicable
- S3 bucket blocks public access
- OpenObserve connection uses HTTPS

## Advanced Configuration

### Multi-Region Deployment

Deploy stacks in multiple regions for global DNS monitoring:

```bash
AWS_REGION=us-east-1 ./deploy.sh
AWS_REGION=eu-west-1 ./deploy.sh
AWS_REGION=ap-southeast-1 ./deploy.sh
```

### Custom Log Retention

Modify CloudWatch log retention:

```yaml
Route53LogGroup:
  Type: AWS::Logs::LogGroup
  Properties:
    LogGroupName: !Sub '/aws/route53/${HostedZoneId}'
    RetentionInDays: 30  # Change from 7 to 30 days
```

### Kinesis On-Demand Mode

For variable traffic, use on-demand scaling:

```yaml
Route53LogStream:
  Type: AWS::Kinesis::Stream
  Properties:
    Name: !Sub '${AWS::StackName}-route53-logs'
    StreamModeDetails:
      StreamMode: ON_DEMAND  # Changed from PROVISIONED
```

### Additional Lambda Enrichment

Enhance the Lambda function to add custom fields:

```python
# Add custom categorization
def categorize_query(query_name, query_type):
    if query_type in ['MX', 'TXT'] and 'dkim' in query_name.lower():
        return 'email_security'
    elif query_type == 'CAA':
        return 'certificate_validation'
    elif query_name.endswith('.internal'):
        return 'internal_dns'
    else:
        return 'standard'

parsed['query_category'] = categorize_query(
    parsed['query_name'],
    parsed['query_type']
)
```

## References

- [AWS Route53 Query Logging Documentation](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/query-logs.html)
- [Route53 Query Log Format](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/query-logs-format.html)
- [OpenObserve Route53 Logging Guide](https://openobserve.ai/blog/configure-route53-query-logging/)
- [DNS Response Codes](https://www.iana.org/assignments/dns-parameters/dns-parameters.xhtml)
- [CloudWatch Logs Subscription Filters](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/SubscriptionFilters.html)

## Support

For issues or questions:
- Check CloudFormation events for deployment errors
- Review Lambda logs for transformation issues
- Verify IAM permissions and resource limits
- Consult AWS Route53 and CloudWatch Logs documentation

## License

MIT License - See LICENSE file for details
