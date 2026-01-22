#!/bin/bash

#######################################
# S3 Access Logs to OpenObserve Deployment Script
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
STREAM_NAME="s3-access-logs"
LOG_PREFIX="s3-access-logs/"
AWS_PROFILE="${AWS_PROFILE:-mdmosaraf_o2_dev}"
TEMPLATE_FILE="s3-access-logs-to-openobserve.yaml"

# Global variables
SOURCE_BUCKET=""
LOG_DESTINATION_BUCKET=""
BACKUP_BUCKET=""
ACCOUNT_ID=""
STACK_NAME=""

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
    echo "   S3 Access Logs to OpenObserve Deployment"
    echo "================================================"
    echo -e "${NC}"
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
        print_warning "jq is not installed (recommended but not required)"
        echo "Install it with: brew install jq (macOS) or apt-get install jq (Linux)"
    else
        print_success "jq is installed"
    fi
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

# List S3 buckets and let user select
select_source_bucket() {
    print_header "Select Source S3 Bucket"

    print_info "Fetching available S3 buckets..."

    # Get list of buckets
    BUCKETS=$(aws s3 ls | awk '{print $3}' | sort)

    if [ -z "$BUCKETS" ]; then
        print_error "No S3 buckets found in this account"
        exit 1
    fi

    echo ""
    echo -e "${CYAN}Available S3 Buckets:${NC}"
    echo "$BUCKETS" | nl -w2 -s'. '
    echo ""

    # Prompt for bucket selection
    while true; do
        read -p "Select bucket number or enter bucket name: " input

        # Check if input is a number
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            SOURCE_BUCKET=$(echo "$BUCKETS" | sed -n "${input}p")
        else
            SOURCE_BUCKET="$input"
        fi

        if [ -n "$SOURCE_BUCKET" ]; then
            # Validate bucket exists
            if aws s3 ls "s3://$SOURCE_BUCKET" &> /dev/null; then
                break
            else
                print_error "Bucket '$SOURCE_BUCKET' does not exist or you don't have access"
            fi
        else
            print_error "Invalid selection"
        fi
    done

    print_success "Selected source bucket: $SOURCE_BUCKET"

    # Set unique stack name based on source bucket
    STACK_NAME="s3-access-logs-${SOURCE_BUCKET}"
    print_info "Stack Name: $STACK_NAME"
}

# Generate unique S3 bucket names
generate_bucket_names() {
    print_header "Generating S3 Bucket Names"

    TIMESTAMP=$(date +%s)

    # Clean bucket name (replace underscores with hyphens, convert to lowercase)
    CLEAN_BUCKET_NAME=$(echo "$SOURCE_BUCKET" | tr '_' '-' | tr '[:upper:]' '[:lower:]')

    LOG_DESTINATION_BUCKET="s3-access-logs-${CLEAN_BUCKET_NAME}-${TIMESTAMP}"
    BACKUP_BUCKET="s3-backup-${CLEAN_BUCKET_NAME}-${TIMESTAMP}"

    print_success "Generated unique bucket names"
    print_info "Log Destination Bucket: $LOG_DESTINATION_BUCKET"
    print_info "Backup Bucket: $BACKUP_BUCKET"
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

            # Disable S3 access logging on source bucket
            print_info "Disabling S3 access logging on source bucket..."
            aws s3api put-bucket-logging \
                --bucket "$SOURCE_BUCKET" \
                --bucket-logging-status {} 2>/dev/null || true

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

# Create CloudFormation stack
create_stack() {
    print_header "Creating CloudFormation Stack"

    print_info "Stack Name: $STACK_NAME"
    print_info "Template: $TEMPLATE_FILE"
    print_info "Source Bucket: $SOURCE_BUCKET"

    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body file://"$TEMPLATE_FILE" \
        --parameters \
            ParameterKey=OpenObserveEndpoint,ParameterValue="$OPENOBSERVE_ENDPOINT" \
            ParameterKey=OpenObserveAccessKey,ParameterValue="$OPENOBSERVE_ACCESS_KEY" \
            ParameterKey=StreamName,ParameterValue="$STREAM_NAME" \
            ParameterKey=SourceBucketName,ParameterValue="$SOURCE_BUCKET" \
            ParameterKey=LogDestinationBucketName,ParameterValue="$LOG_DESTINATION_BUCKET" \
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

# Enable S3 Access Logging on source bucket
enable_s3_access_logging() {
    print_header "Enabling S3 Access Logging"

    print_info "Configuring access logging for: $SOURCE_BUCKET"
    print_info "Logs will be delivered to: $LOG_DESTINATION_BUCKET"

    # Create logging configuration
    LOGGING_CONFIG=$(cat <<EOF
{
    "LoggingEnabled": {
        "TargetBucket": "$LOG_DESTINATION_BUCKET",
        "TargetPrefix": "$LOG_PREFIX"
    }
}
EOF
)

    # Apply logging configuration
    if echo "$LOGGING_CONFIG" | aws s3api put-bucket-logging \
        --bucket "$SOURCE_BUCKET" \
        --bucket-logging-status file:///dev/stdin; then

        print_success "S3 Access Logging enabled on source bucket"
        print_warning "Note: Logs may take several hours to appear due to eventual consistency"
    else
        print_error "Failed to enable S3 Access Logging"
        print_info "You can enable it manually:"
        print_info "aws s3api put-bucket-logging --bucket $SOURCE_BUCKET --bucket-logging-status '{\"LoggingEnabled\":{\"TargetBucket\":\"$LOG_DESTINATION_BUCKET\",\"TargetPrefix\":\"$LOG_PREFIX\"}}'"
    fi
}

# Print next steps
print_next_steps() {
    print_header "Next Steps"

    echo -e "${GREEN}1. Monitor logs in OpenObserve:${NC}"
    echo "   Stream: $STREAM_NAME"
    echo "   Logs appear in: Hours (S3 Access Logs have eventual consistency)"
    echo ""
    echo -e "${GREEN}2. Check Lambda processing:${NC}"
    echo "   aws logs tail /aws/lambda/${STACK_NAME}-log-processor --follow"
    echo ""
    echo -e "${GREEN}3. Verify S3 access logging configuration:${NC}"
    echo "   aws s3api get-bucket-logging --bucket $SOURCE_BUCKET"
    echo ""
    echo -e "${GREEN}4. Check failed records:${NC}"
    echo "   aws s3 ls s3://$BACKUP_BUCKET/failed-logs/ --recursive"
    echo ""
    echo -e "${GREEN}5. List access log files:${NC}"
    echo "   aws s3 ls s3://$LOG_DESTINATION_BUCKET/$LOG_PREFIX --recursive"
    echo ""
    echo -e "${YELLOW}Important Notes:${NC}"
    echo "   • S3 Access Logs are delivered with eventual consistency"
    echo "   • Logs may take hours to appear in the destination bucket"
    echo "   • Best-effort delivery (not guaranteed for all requests)"
    echo "   • Logs are written periodically (usually within a few hours)"
}

# Print deployment summary
print_summary() {
    print_header "Deployment Summary"

    echo -e "${CYAN}Stack Name:${NC} $STACK_NAME"
    echo -e "${CYAN}Source Bucket:${NC} $SOURCE_BUCKET"
    echo -e "${CYAN}Log Destination Bucket:${NC} $LOG_DESTINATION_BUCKET"
    echo -e "${CYAN}Backup Bucket:${NC} $BACKUP_BUCKET"
    echo -e "${CYAN}OpenObserve Stream:${NC} $STREAM_NAME"
    echo -e "${CYAN}Log Prefix:${NC} $LOG_PREFIX"
    echo -e "${CYAN}Lifecycle Policy:${NC} 90 days retention"
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
    check_aws_cli
    check_credentials
    select_source_bucket
    validate_template
    generate_bucket_names
    check_existing_stack
    create_stack
    monitor_stack
    get_outputs
    enable_s3_access_logging
    print_summary
    print_next_steps

    print_header "Deployment Complete!"
    print_success "Stack '$STACK_NAME' is ready"
    print_success "S3 Access Logging configured for: $SOURCE_BUCKET"
    echo ""
    echo -e "${CYAN}To deploy for another bucket, run this script again${NC}"
}

# Run main function
main
