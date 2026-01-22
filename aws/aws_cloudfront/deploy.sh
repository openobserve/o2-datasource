#!/bin/bash

#######################################
# CloudFront to OpenObserve Deployment Script
# Supports both Real-time and S3-based logging
#######################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration (Edit these values or script will prompt)
OPENOBSERVE_ENDPOINT="${OPENOBSERVE_ENDPOINT:-https://api.openobserve.ai/aws/350aLCLtputyyPTVWccwodDZfsh/default/_kinesis_firehose}"
OPENOBSERVE_ACCESS_KEY="${OPENOBSERVE_ACCESS_KEY:-bW9zcmFmQG9wZW5vYnNlcnZlLmFpOmZIUFU2UThwM2VIZjVkM2M=}"
STREAM_NAME="cloudfront-logs"
CLOUDFRONT_DISTRIBUTION_ID=""  # Will prompt if not set
LOG_PREFIX="cloudfront-logs/"
AWS_PROFILE="${AWS_PROFILE:-mdmosaraf_o2_dev}"

# Global variables
DEPLOYMENT_TYPE=""
STACK_NAME=""
TEMPLATE_FILE=""
LOG_BUCKET=""
BACKUP_BUCKET=""
ACCOUNT_ID=""
SHARD_COUNT=1

# Functions
print_header() {
    echo -e "\n${CYAN}================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}================================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Display banner
show_banner() {
    echo -e "${CYAN}"
    echo "================================================"
    echo "   CloudFront to OpenObserve Deployment"
    echo "================================================"
    echo -e "${NC}"
}

# Select deployment type
select_deployment_type() {
    print_header "Select Deployment Type"

    echo -e "${GREEN}1) Real-time Logs${NC} (Recommended for Monitoring)"
    echo "   • Near real-time (seconds delay)"
    echo "   • Cost: ~\$50/month for 1TB traffic"
    echo "   • Best for: monitoring, alerts, security"
    echo ""
    echo -e "${GREEN}2) S3-based Standard Logs${NC} (Cost-effective)"
    echo "   • Delayed (5-60 minutes)"
    echo "   • Cost: ~\$17/month for 1TB traffic"
    echo "   • Best for: analytics, compliance, archival"
    echo ""

    while true; do
        read -p "Choose option (1 or 2): " choice
        case $choice in
            1)
                DEPLOYMENT_TYPE="realtime"
                TEMPLATE_FILE="cloudfront-to-openobserve.yaml"
                print_success "Selected: Real-time Logs"
                break
                ;;
            2)
                DEPLOYMENT_TYPE="s3"
                TEMPLATE_FILE="cloudfront-to-openobserve-s3.yaml"
                print_success "Selected: S3-based Standard Logs"
                break
                ;;
            *)
                print_error "Invalid option. Please choose 1 or 2."
                ;;
        esac
    done
}

# Get CloudFront Distribution ID
get_distribution_id() {
    print_header "CloudFront Distribution Configuration"

    # If distribution ID is already set, use it
    if [ -n "$CLOUDFRONT_DISTRIBUTION_ID" ]; then
        print_info "Using distribution ID: $CLOUDFRONT_DISTRIBUTION_ID"
        return
    fi

    # List available distributions
    print_info "Fetching available CloudFront distributions..."
    DISTRIBUTIONS=$(aws cloudfront list-distributions \
        --query 'DistributionList.Items[*].[Id,DomainName,Comment]' \
        --output text 2>/dev/null)

    if [ -n "$DISTRIBUTIONS" ]; then
        echo ""
        echo -e "${CYAN}Available CloudFront Distributions:${NC}"
        echo "$DISTRIBUTIONS" | nl -w2 -s'. '
        echo ""
    fi

    # Prompt for distribution ID
    while true; do
        read -p "Enter CloudFront Distribution ID: " input_dist_id
        if [ -n "$input_dist_id" ]; then
            CLOUDFRONT_DISTRIBUTION_ID="$input_dist_id"
            break
        else
            print_error "Distribution ID cannot be empty"
        fi
    done

    print_success "Distribution ID set: $CLOUDFRONT_DISTRIBUTION_ID"
}

# Check if AWS CLI is installed
check_aws_cli() {
    print_header "Checking Prerequisites"

    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed"
        echo "Install it from: https://aws.amazon.com/cli/"
        exit 1
    fi
    print_success "AWS CLI is installed"

    if ! command -v jq &> /dev/null; then
        print_error "jq is not installed (required for CloudFront automation)"
        echo "Install it with: brew install jq (macOS) or apt-get install jq (Linux)"
        exit 1
    fi
    print_success "jq is installed"
}

# Check AWS credentials
check_credentials() {
    print_info "Checking AWS credentials..."

    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured"
        echo ""
        echo "Run: aws configure"
        echo "Or set AWS_PROFILE environment variable"
        exit 1
    fi

    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    USER_ARN=$(aws sts get-caller-identity --query Arn --output text)

    print_success "AWS credentials configured"
    print_info "Account ID: $ACCOUNT_ID"
    print_info "User/Role: $USER_ARN"
}

# Validate CloudFront distribution
validate_cloudfront() {
    print_header "Validating CloudFront Distribution"
    print_info "Distribution ID: $CLOUDFRONT_DISTRIBUTION_ID"

    if ! aws cloudfront get-distribution --id "$CLOUDFRONT_DISTRIBUTION_ID" &> /dev/null; then
        print_error "CloudFront distribution not found or no access"
        echo "Check distribution ID: $CLOUDFRONT_DISTRIBUTION_ID"
        exit 1
    fi

    DISTRIBUTION_DOMAIN=$(aws cloudfront get-distribution --id "$CLOUDFRONT_DISTRIBUTION_ID" \
        --query 'Distribution.DomainName' --output text)

    print_success "CloudFront distribution exists"
    print_info "Domain: $DISTRIBUTION_DOMAIN"

    # Set unique stack name based on distribution ID and deployment type
    if [ "$DEPLOYMENT_TYPE" == "realtime" ]; then
        STACK_NAME="cf-realtime-${CLOUDFRONT_DISTRIBUTION_ID}"
    else
        STACK_NAME="cf-s3-${CLOUDFRONT_DISTRIBUTION_ID}"
    fi
    print_info "Stack Name: $STACK_NAME"
}

# Generate unique S3 bucket names
generate_bucket_names() {
    print_header "Generating S3 Bucket Names"

    TIMESTAMP=$(date +%s)

    if [ "$DEPLOYMENT_TYPE" == "realtime" ]; then
        BACKUP_BUCKET="cf-realtime-backup-${ACCOUNT_ID}-${TIMESTAMP}"
        print_success "Generated unique bucket name"
        print_info "Backup Bucket: $BACKUP_BUCKET"
    else
        LOG_BUCKET="cf-logs-${ACCOUNT_ID}-${TIMESTAMP}"
        BACKUP_BUCKET="cf-backup-${ACCOUNT_ID}-${TIMESTAMP}"
        print_success "Generated unique bucket names"
        print_info "Log Bucket: $LOG_BUCKET"
        print_info "Backup Bucket: $BACKUP_BUCKET"
    fi
}

# Configure real-time specific settings
configure_realtime() {
    print_header "Real-time Logs Configuration"

    read -p "Enter Kinesis shard count (1-10, default 1): " shard_input
    SHARD_COUNT=${shard_input:-1}

    if [ "$SHARD_COUNT" -lt 1 ] || [ "$SHARD_COUNT" -gt 10 ]; then
        print_warning "Invalid shard count. Using default: 1"
        SHARD_COUNT=1
    fi

    print_info "Shard Count: $SHARD_COUNT"
    print_info "Estimated cost: ~\$$(( 30 * SHARD_COUNT + 20 ))/month"
}

# Validate CloudFormation template
validate_template() {
    print_header "Validating CloudFormation Template"

    if [ ! -f "$TEMPLATE_FILE" ]; then
        print_error "Template file not found: $TEMPLATE_FILE"
        exit 1
    fi

    if ! aws cloudformation validate-template --template-body file://"$TEMPLATE_FILE" &> /dev/null; then
        print_error "Template validation failed"
        aws cloudformation validate-template --template-body file://"$TEMPLATE_FILE"
        exit 1
    fi

    print_success "Template is valid"
}

# Check if stack already exists
check_existing_stack() {
    print_header "Checking Existing Stack"

    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" &> /dev/null; then
        print_warning "Stack '$STACK_NAME' already exists"
        read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Deleting existing stack..."

            # Get S3 buckets from existing stack
            BUCKETS=$(aws cloudformation describe-stack-resources \
                --stack-name "$STACK_NAME" \
                --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
                --output text)

            # Empty buckets
            for bucket in $BUCKETS; do
                print_info "Emptying bucket: $bucket"
                aws s3 rm s3://$bucket --recursive 2>/dev/null || true
            done

            aws cloudformation delete-stack --stack-name "$STACK_NAME"
            print_info "Waiting for stack deletion..."
            aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
            print_success "Stack deleted"
        else
            print_error "Deployment cancelled"
            exit 1
        fi
    else
        print_success "No existing stack found"
    fi
}

# Create CloudFormation stack for real-time logs
create_realtime_stack() {
    print_header "Creating Real-time Logs Stack"

    print_info "Stack Name: $STACK_NAME"
    print_info "Template: $TEMPLATE_FILE"

    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body file://"$TEMPLATE_FILE" \
        --parameters \
            ParameterKey=OpenObserveEndpoint,ParameterValue="$OPENOBSERVE_ENDPOINT" \
            ParameterKey=OpenObserveAccessKey,ParameterValue="$OPENOBSERVE_ACCESS_KEY" \
            ParameterKey=StreamName,ParameterValue="$STREAM_NAME" \
            ParameterKey=CloudFrontDistributionId,ParameterValue="$CLOUDFRONT_DISTRIBUTION_ID" \
            ParameterKey=BackupS3BucketName,ParameterValue="$BACKUP_BUCKET" \
            ParameterKey=ShardCount,ParameterValue="$SHARD_COUNT" \
        --capabilities CAPABILITY_IAM

    print_success "Stack creation initiated"
}

# Create CloudFormation stack for S3-based logs
create_s3_stack() {
    print_header "Creating S3-based Logs Stack"

    print_info "Stack Name: $STACK_NAME"
    print_info "Template: $TEMPLATE_FILE"

    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body file://"$TEMPLATE_FILE" \
        --parameters \
            ParameterKey=OpenObserveEndpoint,ParameterValue="$OPENOBSERVE_ENDPOINT" \
            ParameterKey=OpenObserveAccessKey,ParameterValue="$OPENOBSERVE_ACCESS_KEY" \
            ParameterKey=StreamName,ParameterValue="$STREAM_NAME" \
            ParameterKey=CloudFrontDistributionId,ParameterValue="$CLOUDFRONT_DISTRIBUTION_ID" \
            ParameterKey=LogS3BucketName,ParameterValue="$LOG_BUCKET" \
            ParameterKey=BackupS3BucketName,ParameterValue="$BACKUP_BUCKET" \
            ParameterKey=LogPrefix,ParameterValue="$LOG_PREFIX" \
        --capabilities CAPABILITY_IAM

    print_success "Stack creation initiated"
}

# Monitor stack creation
monitor_stack() {
    print_header "Monitoring Stack Creation"
    print_info "This may take 5-10 minutes..."
    echo ""

    # Show progress indicator
    aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" &
    WAIT_PID=$!

    while kill -0 $WAIT_PID 2> /dev/null; do
        sleep 5
        echo -n "."
    done

    wait $WAIT_PID
    EXIT_CODE=$?

    echo ""

    if [ $EXIT_CODE -eq 0 ]; then
        print_success "Stack created successfully!"
    else
        print_error "Stack creation failed"
        echo ""
        echo "Recent failed events:"
        aws cloudformation describe-stack-events \
            --stack-name "$STACK_NAME" \
            --max-items 10 \
            --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
            --output table
        exit 1
    fi
}

# Get stack outputs
get_outputs() {
    print_header "Stack Outputs"

    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs' \
        --output table
}

# Attach real-time log config to CloudFront distribution
attach_realtime_config() {
    print_header "Attaching Real-time Log Config to CloudFront"

    REALTIME_CONFIG_ARN=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`RealtimeLogConfigArn`].OutputValue' \
        --output text)

    print_info "Getting current distribution configuration..."

    # Get current config and ETag
    DIST_CONFIG=$(aws cloudfront get-distribution-config --id "$CLOUDFRONT_DISTRIBUTION_ID")
    ETAG=$(echo "$DIST_CONFIG" | jq -r '.ETag')

    # Update the config to add RealtimeLogConfigArn to default cache behavior
    UPDATED_CONFIG=$(echo "$DIST_CONFIG" | jq --arg arn "$REALTIME_CONFIG_ARN" '
        .DistributionConfig.DefaultCacheBehavior.RealtimeLogConfigArn = $arn |
        .DistributionConfig
    ')

    # Also update all cache behaviors if they exist
    UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | jq --arg arn "$REALTIME_CONFIG_ARN" '
        if .CacheBehaviors.Items then
            .CacheBehaviors.Items |= map(.RealtimeLogConfigArn = $arn)
        else
            .
        end
    ')

    # Save to temp file
    TEMP_CONFIG=$(mktemp)
    echo "$UPDATED_CONFIG" > "$TEMP_CONFIG"

    print_info "Updating CloudFront distribution..."

    if aws cloudfront update-distribution \
        --id "$CLOUDFRONT_DISTRIBUTION_ID" \
        --distribution-config "file://$TEMP_CONFIG" \
        --if-match "$ETAG" &> /dev/null; then

        print_success "Real-time logging enabled on CloudFront distribution"
        print_info "Distribution is deploying (may take 5-10 minutes)"
    else
        print_warning "Failed to automatically attach real-time config"
        print_info "You can attach it manually:"
        print_info "RealtimeLogConfigArn: $REALTIME_CONFIG_ARN"
    fi

    # Cleanup
    rm -f "$TEMP_CONFIG"
}

# Enable S3 logging on CloudFront distribution
enable_s3_logging() {
    print_header "Enabling S3 Logging on CloudFront"

    print_info "Getting current distribution configuration..."

    # Get current config and ETag
    DIST_CONFIG=$(aws cloudfront get-distribution-config --id "$CLOUDFRONT_DISTRIBUTION_ID")
    ETAG=$(echo "$DIST_CONFIG" | jq -r '.ETag')

    # Update the config to enable logging
    UPDATED_CONFIG=$(echo "$DIST_CONFIG" | jq \
        --arg bucket "${LOG_BUCKET}.s3.amazonaws.com" \
        --arg prefix "$LOG_PREFIX" '
        .DistributionConfig.Logging = {
            "Enabled": true,
            "IncludeCookies": false,
            "Bucket": $bucket,
            "Prefix": $prefix
        } |
        .DistributionConfig
    ')

    # Save to temp file
    TEMP_CONFIG=$(mktemp)
    echo "$UPDATED_CONFIG" > "$TEMP_CONFIG"

    print_info "Updating CloudFront distribution..."

    if aws cloudfront update-distribution \
        --id "$CLOUDFRONT_DISTRIBUTION_ID" \
        --distribution-config "file://$TEMP_CONFIG" \
        --if-match "$ETAG" &> /dev/null; then

        print_success "S3 logging enabled on CloudFront distribution"
        print_info "Distribution is deploying (may take 5-10 minutes)"
    else
        print_warning "Failed to automatically enable S3 logging"
        print_info "You can enable it manually in the CloudFront console"
    fi

    # Cleanup
    rm -f "$TEMP_CONFIG"
}

# Print next steps for real-time logs
print_realtime_next_steps() {
    print_header "Next Steps - Real-time Logs"

    echo -e "${GREEN}1. Monitor logs in OpenObserve:${NC}"
    echo "   Stream: $STREAM_NAME"
    echo "   Logs appear in: seconds (near real-time)"
    echo ""
    echo -e "${GREEN}2. Monitor Kinesis metrics:${NC}"
    echo "   aws cloudwatch get-metric-statistics \\"
    echo "     --namespace AWS/Kinesis \\"
    echo "     --metric-name IncomingRecords \\"
    echo "     --dimensions Name=StreamName,Value=${STACK_NAME}-cloudfront-logs \\"
    echo "     --start-time \$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \\"
    echo "     --end-time \$(date -u +%Y-%m-%dT%H:%M:%S) \\"
    echo "     --period 300 --statistics Sum"
    echo ""
    echo -e "${GREEN}3. Check failed records:${NC}"
    echo "   aws s3 ls s3://$BACKUP_BUCKET/failed-logs/ --recursive"
    echo ""
    echo -e "${GREEN}4. Check distribution status:${NC}"
    echo "   aws cloudfront get-distribution --id $CLOUDFRONT_DISTRIBUTION_ID --query 'Distribution.Status'"
}

# Print next steps for S3-based logs
print_s3_next_steps() {
    print_header "Next Steps - S3-based Logs"

    echo -e "${GREEN}1. Monitor logs in OpenObserve:${NC}"
    echo "   Stream: $STREAM_NAME"
    echo "   Logs appear in: 5-60 minutes (after CloudFront generates them)"
    echo ""
    echo -e "${GREEN}2. Check Lambda processing:${NC}"
    echo "   aws logs tail /aws/lambda/${STACK_NAME}-log-processor --follow"
    echo ""
    echo -e "${GREEN}3. Check failed records:${NC}"
    echo "   aws s3 ls s3://$BACKUP_BUCKET/failed-logs/ --recursive"
    echo ""
    echo -e "${GREEN}4. Check distribution status:${NC}"
    echo "   aws cloudfront get-distribution --id $CLOUDFRONT_DISTRIBUTION_ID --query 'Distribution.Status'"
    echo ""
    echo -e "${YELLOW}Note: CloudFront logs may take 5-60 minutes to appear in S3${NC}"
}

# Print deployment summary
print_summary() {
    print_header "Deployment Summary"

    echo -e "${CYAN}Deployment Type:${NC} $DEPLOYMENT_TYPE"
    echo -e "${CYAN}Stack Name:${NC} $STACK_NAME"
    echo -e "${CYAN}CloudFront Distribution ID:${NC} $CLOUDFRONT_DISTRIBUTION_ID"
    echo -e "${CYAN}CloudFront Domain:${NC} ${DISTRIBUTION_DOMAIN:-N/A}"
    echo -e "${CYAN}OpenObserve Stream:${NC} $STREAM_NAME"

    if [ "$DEPLOYMENT_TYPE" == "realtime" ]; then
        echo -e "${CYAN}Kinesis Shards:${NC} $SHARD_COUNT"
        echo -e "${CYAN}Backup Bucket:${NC} $BACKUP_BUCKET"
        echo -e "${CYAN}Estimated Cost:${NC} ~\$$(( 30 * SHARD_COUNT + 20 ))/month (per distribution)"
    else
        echo -e "${CYAN}Log Bucket:${NC} $LOG_BUCKET"
        echo -e "${CYAN}Backup Bucket:${NC} $BACKUP_BUCKET"
        echo -e "${CYAN}Estimated Cost:${NC} ~\$17/month (per distribution)"
    fi
}

# Cleanup on error
cleanup_on_error() {
    if [ $? -ne 0 ]; then
        print_error "Script failed. Check errors above."
    fi
}

trap cleanup_on_error EXIT

# Main execution
main() {
    show_banner
    select_deployment_type
    check_aws_cli
    check_credentials
    get_distribution_id
    validate_cloudfront
    validate_template
    generate_bucket_names

    if [ "$DEPLOYMENT_TYPE" == "realtime" ]; then
        configure_realtime
    fi

    check_existing_stack

    if [ "$DEPLOYMENT_TYPE" == "realtime" ]; then
        create_realtime_stack
    else
        create_s3_stack
    fi

    monitor_stack
    get_outputs
    print_summary

    # Automatically configure CloudFront distribution
    if [ "$DEPLOYMENT_TYPE" == "realtime" ]; then
        attach_realtime_config
        print_realtime_next_steps
    else
        enable_s3_logging
        print_s3_next_steps
    fi

    print_header "Deployment Complete!"
    print_success "Stack '$STACK_NAME' is ready"
    print_success "CloudFront distribution configured automatically"
    echo ""
    echo -e "${CYAN}To deploy for another distribution, run this script again${NC}"
}

# Run main function
main
