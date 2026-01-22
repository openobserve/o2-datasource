# AWS Cognito Events to OpenObserve Monitoring

This CloudFormation solution captures AWS Cognito authentication events in real-time and streams them to OpenObserve for monitoring, analysis, and alerting.

## Architecture

```
AWS Cognito User Pools
         |
         | (Events)
         v
   EventBridge Rule
         |
         | (Trigger)
         v
  Kinesis Firehose
         |
         | (Transform)
         v
   Lambda Function
         |
         | (HTTP POST)
         v
    OpenObserve

   S3 Bucket (Failed records backup)
```

## Components

### 1. EventBridge Rule
- Captures all Cognito events from the `aws.cognito-idp` source
- Can be filtered to monitor specific User Pool(s) or all pools in the region
- Sends events to Kinesis Firehose for processing

### 2. Kinesis Firehose Delivery Stream
- Receives events from EventBridge
- Buffers and batches events for efficient delivery
- Invokes Lambda transformation function
- Delivers to OpenObserve HTTP endpoint
- Backs up failed records to S3

### 3. Lambda Transformation Function
- Transforms raw Cognito events into structured format
- Extracts key authentication information
- Enriches events with metadata
- Returns transformed JSON for OpenObserve ingestion

### 4. S3 Backup Bucket
- Stores failed delivery attempts
- Automatically expires old backups after 30 days
- Encrypted at rest (AES256)

## Cognito Event Types Captured

The solution captures the following Cognito events:

### Authentication Events
- **Sign In Success**: User successfully authenticated
- **Sign In Failure**: Failed authentication attempt
- **Token Refresh**: User session token refreshed
- **Token Refresh Failure**: Failed token refresh

### User Registration Events
- **Sign Up**: New user registration
- **Sign Up Confirmation**: User confirmed their account
- **Resend Confirmation Code**: Confirmation code resent

### Password Management Events
- **Forgot Password**: Password reset initiated
- **Confirm Forgot Password**: Password reset completed
- **Change Password**: User changed password

### Account Management Events
- **Delete User**: User account deleted
- **Update User Attributes**: User profile updated
- **Verify User Attribute**: User attribute verified

### Administrative Events
- **Admin Create User**: Administrator created a user
- **Admin Delete User**: Administrator deleted a user
- **Admin Set User Password**: Administrator set user password

## Event Structure

Transformed events sent to OpenObserve have the following structure:

```json
{
  "timestamp": "2026-01-22T10:30:45.123Z",
  "event_type": "Sign In",
  "region": "us-east-1",
  "account_id": "123456789012",
  "user_pool_id": "us-east-1_ABC123XYZ",
  "event_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "source": "aws.cognito-idp",
  "detail": {
    "username": "user@example.com",
    "user_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "success": true,
    "ip_address": "203.0.113.42",
    "user_agent": "Mozilla/5.0...",
    "device_key": "us-east-1_abc123",
    "error_message": "",
    "event_context_data": {
      "city": "Seattle",
      "country": "US"
    }
  },
  "processed_at": "2026-01-22T10:30:45.500Z"
}
```

## Prerequisites

1. **AWS Account** with appropriate permissions
2. **AWS CLI** installed and configured
3. **OpenObserve** instance (cloud or self-hosted)
4. **Cognito User Pool(s)** already created
5. **jq** installed (for parsing JSON in scripts)

## Installation

### 1. Clone or Download the Repository

```bash
cd /Users/mdmosaraf/Documents/cloudformation/aws_cognito_logs
```

### 2. Make Scripts Executable

```bash
chmod +x deploy.sh cleanup.sh
```

### 3. Prepare OpenObserve

1. Create a stream in OpenObserve (e.g., `cognito_logs`)
2. Get your OpenObserve credentials (username and password)
3. Note your OpenObserve endpoint URL:
   ```
   https://your-instance.openobserve.ai/api/default/cognito_logs/_json
   ```

### 4. Deploy the Stack

Run the deployment script:

```bash
./deploy.sh
```

The script will:
1. List all Cognito User Pools in your current region
2. Prompt you to select a pool (or monitor all pools)
3. Request OpenObserve configuration
4. Deploy the CloudFormation stack
5. Display the stack outputs

#### Example Deployment

```bash
$ ./deploy.sh

[INFO] === Cognito Events to OpenObserve Deployment ===

[INFO] AWS Account: 123456789012
[INFO] Current Region: us-east-1
[INFO] Fetching Cognito User Pools in region us-east-1...
[SUCCESS] Found 2 user pool(s):

 1. us-east-1_ABC123XYZ - Production Pool (Created: 2025-06-15T10:30:00Z)
 2. us-east-1_DEF456UVW - Development Pool (Created: 2025-08-20T14:20:00Z)

[INFO] Select a user pool to monitor:
  - Enter the number corresponding to the user pool
  - Enter '0' to monitor ALL user pools in the region
  - Enter 'q' to quit

Your choice: 1

[INFO] Selected: Production Pool (us-east-1_ABC123XYZ)

[INFO] OpenObserve Configuration

Enter OpenObserve endpoint URL: https://my-instance.openobserve.ai/api/default/cognito_logs/_json
Enter OpenObserve username: admin
Enter OpenObserve password: ********
Enter Kinesis Firehose stream name [cognito-events-to-openobserve]:

[WARNING] Ready to deploy with the following configuration:
  Stack Name: cognito-us-east-1-ABC123XYZ
  User Pool: us-east-1_ABC123XYZ
  OpenObserve Endpoint: https://my-instance.openobserve.ai/api/default/cognito_logs/_json
  Stream Name: cognito-events-to-openobserve

Proceed with deployment? (y/n): y

[INFO] Deploying CloudFormation stack: cognito-us-east-1-ABC123XYZ
[INFO] Creating new stack...
[INFO] Waiting for stack creation to complete...
[SUCCESS] Stack deployment completed successfully!

[INFO] Stack Outputs:
...
[SUCCESS] Deployment complete!
```

## Stack Parameters

| Parameter | Description | Required | Default |
|-----------|-------------|----------|---------|
| `OpenObserveEndpoint` | OpenObserve HTTP endpoint URL | Yes | - |
| `OpenObserveAccessKey` | Base64 encoded credentials (user:password) | Yes | - |
| `UserPoolId` | Specific User Pool ID to monitor | No | "" (all pools) |
| `StreamName` | Kinesis Firehose stream name | No | cognito-events-to-openobserve |
| `BackupS3Prefix` | S3 prefix for failed records | No | cognito-events-backup/ |

## Monitoring and Troubleshooting

### CloudWatch Logs

Monitor the Firehose delivery status:

```bash
aws logs tail /aws/kinesisfirehose/cognito-events-to-openobserve --follow
```

Monitor Lambda transformation errors:

```bash
aws logs tail /aws/lambda/<stack-name>-transform --follow
```

### Check Firehose Metrics

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Firehose \
  --metric-name DeliveryToHttpEndpoint.Success \
  --dimensions Name=DeliveryStreamName,Value=cognito-events-to-openobserve \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

### Common Issues

#### 1. Events Not Appearing in OpenObserve

**Check:**
- Verify OpenObserve endpoint URL is correct
- Verify credentials are valid
- Check CloudWatch Logs for delivery errors
- Confirm EventBridge rule is enabled
- Verify Cognito events are being generated (test with sign-in)

**Solution:**
```bash
# Check EventBridge rule status
aws events describe-rule --name <stack-name>-cognito-events

# Test Cognito authentication to generate events
# Check Firehose metrics
aws firehose describe-delivery-stream --delivery-stream-name cognito-events-to-openobserve
```

#### 2. High Lambda Errors

**Check:**
- Review Lambda CloudWatch Logs for transformation errors
- Verify event structure hasn't changed

**Solution:**
```bash
# View recent Lambda errors
aws logs filter-log-events \
  --log-group-name /aws/lambda/<stack-name>-transform \
  --filter-pattern "ERROR"
```

#### 3. S3 Backup Bucket Filling Up

**Check:**
- Review failed records in S3
- Check OpenObserve availability
- Verify network connectivity

**Solution:**
```bash
# List failed records
aws s3 ls s3://<stack-name>-backup-<account-id>/cognito-events-backup/ --recursive

# Download a failed record for inspection
aws s3 cp s3://<stack-name>-backup-<account-id>/cognito-events-backup/<file> ./failed-record.gz
gunzip failed-record.gz
cat failed-record
```

#### 4. EventBridge Not Capturing Events

**Check:**
- Verify User Pool ID is correct (if filtering)
- Confirm Cognito events are enabled
- Check EventBridge rule event pattern

**Solution:**
```bash
# View EventBridge rule details
aws events describe-rule --name <stack-name>-cognito-events

# Test event pattern
aws events test-event-pattern \
  --event-pattern file://event-pattern.json \
  --event file://sample-event.json
```

### Testing the Pipeline

Generate test Cognito events:

1. **Sign In Event**: Authenticate a user
2. **Sign Up Event**: Register a new user
3. **Failed Sign In**: Attempt with wrong password
4. **Password Reset**: Initiate password recovery

```bash
# Use AWS CLI to trigger test authentication
aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id <app-client-id> \
  --auth-parameters USERNAME=testuser,PASSWORD=testpass

# Check if events appear in OpenObserve (wait 1-2 minutes for buffering)
```

## Querying Logs in OpenObserve

### Example Queries

**Failed Sign-In Attempts:**
```sql
SELECT timestamp, detail.username, detail.ip_address, detail.error_message
FROM cognito_logs
WHERE event_type LIKE '%Sign In%' AND detail.success = false
ORDER BY timestamp DESC
LIMIT 100
```

**Sign-Ins by User:**
```sql
SELECT detail.username, COUNT(*) as login_count
FROM cognito_logs
WHERE event_type = 'Sign In' AND detail.success = true
GROUP BY detail.username
ORDER BY login_count DESC
```

**Authentication Failures by IP:**
```sql
SELECT detail.ip_address, COUNT(*) as failure_count
FROM cognito_logs
WHERE detail.success = false
GROUP BY detail.ip_address
HAVING failure_count > 5
ORDER BY failure_count DESC
```

**Recent Password Resets:**
```sql
SELECT timestamp, detail.username, detail.success
FROM cognito_logs
WHERE event_type LIKE '%Password%'
ORDER BY timestamp DESC
LIMIT 50
```

**User Activity Timeline:**
```sql
SELECT timestamp, event_type, detail.username, detail.success
FROM cognito_logs
WHERE detail.username = 'user@example.com'
ORDER BY timestamp DESC
```

## Cleanup

To remove all monitoring resources:

```bash
./cleanup.sh
```

The cleanup script will:
1. Find all `cognito-*` CloudFormation stacks
2. Display stack details
3. Prompt for confirmation
4. Empty S3 backup buckets
5. Delete CloudFormation stacks
6. Remove all associated resources

### Interactive Cleanup

```bash
$ ./cleanup.sh

[INFO] === Cognito Events to OpenObserve Cleanup ===

[INFO] AWS Account: 123456789012
[INFO] Current Region: us-east-1
[INFO] Searching for cognito-* CloudFormation stacks...
[SUCCESS] Found 2 cognito stack(s):

 1. cognito-us-east-1-ABC123XYZ - Status: CREATE_COMPLETE (Created: 2026-01-22T09:00:00Z)
 2. cognito-all-pools - Status: UPDATE_COMPLETE (Created: 2026-01-20T14:30:00Z)

[INFO] Options:
  1. View stack details
  2. View stack resources
  3. Delete selected stacks
  4. Delete all stacks
  5. Refresh stack list
  q. Quit

Your choice: 3

[INFO] Select stacks to delete:
  - Enter stack numbers separated by spaces (e.g., 1 3 5)
  - Enter 'all' to delete all stacks
  - Enter 'q' to quit

Your choice: 1

[WARNING] You are about to delete 1 stack(s):
  - cognito-us-east-1-ABC123XYZ

Proceed with deletion? (y/n): y

[INFO] Deleting stack: cognito-us-east-1-ABC123XYZ
[INFO] Checking for S3 backup bucket...
[INFO] Found backup bucket: cognito-us-east-1-abc123xyz-backup-123456789012
[INFO] Bucket is already empty
[INFO] Waiting for stack deletion to complete...
[SUCCESS] Stack deleted: cognito-us-east-1-ABC123XYZ

[SUCCESS] Deletion Summary:
  Successfully deleted: 1

[SUCCESS] Cleanup complete!
```

### Non-Interactive Cleanup

Delete all stacks without confirmation:

```bash
./cleanup.sh --all
```

## Cost Considerations

### Estimated Monthly Costs (US East 1)

Assuming 1 million Cognito events per month:

| Service | Usage | Estimated Cost |
|---------|-------|----------------|
| EventBridge | 1M events | $1.00 |
| Kinesis Firehose | 1GB data ingested | $0.03 |
| Lambda | 1M invocations, 256MB, 100ms avg | $0.20 |
| S3 (backup) | 1GB storage, minimal requests | $0.05 |
| **Total** | | **~$1.28/month** |

**Note:** Costs may vary based on:
- Event volume and frequency
- Lambda execution time
- S3 storage (failed records)
- Data transfer costs to OpenObserve

## Security Best Practices

1. **Credentials Management**
   - Use AWS Secrets Manager for OpenObserve credentials
   - Rotate credentials regularly
   - Use least-privilege IAM roles

2. **Network Security**
   - Use HTTPS endpoints only
   - Consider VPC endpoints for Firehose
   - Implement network ACLs

3. **Data Protection**
   - Enable S3 bucket encryption
   - Use CloudWatch Logs encryption
   - Implement data retention policies

4. **Monitoring**
   - Set up CloudWatch alarms for failures
   - Monitor unauthorized access attempts
   - Review CloudTrail logs regularly

## Advanced Configuration

### Multi-Region Deployment

Deploy to multiple regions to capture events from all regions:

```bash
# Set region
export AWS_DEFAULT_REGION=us-west-2

# Deploy
./deploy.sh
```

### Custom Event Filtering

Modify the EventBridge rule pattern to filter specific event types:

```json
{
  "source": ["aws.cognito-idp"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventName": [
      "InitiateAuth",
      "RespondToAuthChallenge",
      "SignUp"
    ]
  }
}
```

### Lambda Transformation Customization

Edit the Lambda function code in the CloudFormation template to:
- Add custom fields
- Filter sensitive data
- Enrich with external data sources
- Change output format

## Support and Contributing

For issues, questions, or contributions:
- Review AWS Cognito EventBridge documentation
- Check OpenObserve integration guides
- Review CloudWatch Logs for troubleshooting

## References

- [AWS Cognito User Pools Documentation](https://docs.aws.amazon.com/cognito/latest/developerguide/cognito-user-identity-pools.html)
- [Amazon EventBridge Documentation](https://docs.aws.amazon.com/eventbridge/latest/userguide/what-is-amazon-eventbridge.html)
- [Amazon Kinesis Firehose Documentation](https://docs.aws.amazon.com/firehose/latest/dev/what-is-this-service.html)
- [OpenObserve Documentation](https://openobserve.ai/docs/)
- [Monitor AWS Cognito Logs with Firehose, EventBridge, Lambda](https://openobserve.ai/blog/monitor-aws-cognito-logs-firehose-eventbridge-lambda/)

## License

This solution is provided as-is for monitoring AWS Cognito events with OpenObserve.
