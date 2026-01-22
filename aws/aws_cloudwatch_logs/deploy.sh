#!/bin/bash

#######################################
# CloudWatch Logs to OpenObserve Deployment Script
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
STREAM_NAME="cloudwatch-logs"
LOG_GROUP_NAME=""  # Will prompt if not set
FILTER_PATTERN=""
AWS_PROFILE="${AWS_PROFILE:-mdmosaraf_o2_dev}"
AWS_REGION="${AWS_REGION:-us-east-2}"

# Global variables
STACK_NAME=""  # Will be set based on log group name
TEMPLATE_FILE="cloudwatch-logs-to-openobserve.yaml"
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
    echo "   CloudWatch Logs to OpenObserve Deployment"
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
        print_error "jq is not installed (required for JSON processing)"
        echo "Install it with: brew install jq (macOS) or apt-get install jq (Linux)"
        exit 1
    fi
    print_success "jq is installed"
}

# Check AWS credentials
check_credentials() {
    print_info "Checking AWS credentials..."

    if ! aws sts get-caller-identity --profile "$AWS_PROFILE" &> /dev/null; then
        print_error "AWS credentials not configured"
        echo ""
        echo "Run: aws configure"
        echo "Or set AWS_PROFILE environment variable"
        exit 1
    fi

    ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)
    USER_ARN=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Arn --output text)

    print_success "AWS credentials configured"
    print_info "Account ID: $ACCOUNT_ID"
    print_info "User/Role: $USER_ARN"
    print_info "Region: $AWS_REGION"
}

# Get log group name from user
get_log_group() {
    print_header "CloudWatch Log Group Configuration"

    # If log group name is already set, use it
    if [ -n "$LOG_GROUP_NAME" ]; then
        print_info "Using configured log group: $LOG_GROUP_NAME"
    else
        # List existing log groups
        print_info "Listing CloudWatch Log Groups..."
        echo ""
        aws logs describe-log-groups --profile "$AWS_PROFILE" --region "$AWS_REGION" \
            --query 'logGroups[*].logGroupName' --output text | tr '\t' '\n' | head -20
        echo ""

        echo "Enter the CloudWatch Log Group name to stream logs from:"
        read -p "Log Group Name: " input_log_group

        if [ -z "$input_log_group" ]; then
            print_error "Log group name cannot be empty"
            exit 1
        fi

        LOG_GROUP_NAME="$input_log_group"
    fi

    print_info "Using Log Group: $LOG_GROUP_NAME"

    # Check if log group exists
    if aws logs describe-log-groups --profile "$AWS_PROFILE" --region "$AWS_REGION" --log-group-name-prefix "$LOG_GROUP_NAME" --query "logGroups[?logGroupName=='$LOG_GROUP_NAME']" --output text | grep -q "$LOG_GROUP_NAME"; then
        print_success "Log group '$LOG_GROUP_NAME' exists"
    else
        print_info "Log group '$LOG_GROUP_NAME' will be created"
    fi

    # Generate unique stack name from log group name
    # Convert /aws/lambda/my-app to cw-logs-aws-lambda-my-app
    STACK_NAME_SUFFIX=$(echo "$LOG_GROUP_NAME" | sed 's/[^a-zA-Z0-9-]/-/g' | sed 's/^-//' | sed 's/-$//' | tr '[:upper:]' '[:lower:]')
    STACK_NAME="cw-logs-${STACK_NAME_SUFFIX}"

    # Limit stack name to 128 characters (CloudFormation limit)
    if [ ${#STACK_NAME} -gt 128 ]; then
        STACK_NAME="${STACK_NAME:0:128}"
    fi

    print_info "Stack Name: $STACK_NAME"
}

# Get filter pattern
get_filter_pattern() {
    print_header "Log Filter Configuration"

    echo "Enter a CloudWatch Logs filter pattern (optional):"
    echo "Examples:"
    echo "  - Leave empty to stream ALL logs"
    echo "  - [ERROR] to match logs containing 'ERROR'"
    echo "  - [report_type = \"REPORT\"] for Lambda REPORT lines"
    echo "  - See: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html"
    echo ""
    read -p "Filter Pattern (press Enter for none): " input_filter

    FILTER_PATTERN="$input_filter"

    if [ -z "$FILTER_PATTERN" ]; then
        print_info "No filter pattern - streaming ALL logs"
    else
        print_info "Filter Pattern: $FILTER_PATTERN"
    fi
}

# Generate unique S3 bucket name
generate_bucket_name() {
    print_header "Generating S3 Bucket Name"

    TIMESTAMP=$(date +%s)
    BACKUP_BUCKET="cw-logs-backup-${ACCOUNT_ID}-${TIMESTAMP}"

    print_success "Generated unique bucket name"
    print_info "Backup Bucket: $BACKUP_BUCKET"
}

# Configure Kinesis settings
configure_kinesis() {
    print_header "Kinesis Configuration"

    read -p "Enter Kinesis shard count (1-10, default 1): " shard_input
    SHARD_COUNT=${shard_input:-1}

    if [ "$SHARD_COUNT" -lt 1 ] || [ "$SHARD_COUNT" -gt 10 ]; then
        print_warning "Invalid shard count. Using default: 1"
        SHARD_COUNT=1
    fi

    print_info "Shard Count: $SHARD_COUNT"
    print_info "Estimated cost: ~\$$(( 30 * SHARD_COUNT + 15 ))/month"
}

# Validate CloudFormation template
validate_template() {
    print_header "Validating CloudFormation Template"

    if [ ! -f "$TEMPLATE_FILE" ]; then
        print_error "Template file not found: $TEMPLATE_FILE"
        exit 1
    fi

    if ! aws cloudformation validate-template --profile "$AWS_PROFILE" --region "$AWS_REGION" --template-body file://"$TEMPLATE_FILE" &> /dev/null; then
        print_error "Template validation failed"
        aws cloudformation validate-template --profile "$AWS_PROFILE" --region "$AWS_REGION" --template-body file://"$TEMPLATE_FILE"
        exit 1
    fi

    print_success "Template is valid"
}

# Check if stack already exists
check_existing_stack() {
    print_header "Checking Existing Stack"

    if aws cloudformation describe-stacks --profile "$AWS_PROFILE" --region "$AWS_REGION" --stack-name "$STACK_NAME" &> /dev/null; then
        print_warning "Stack '$STACK_NAME' already exists"
        read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Deleting existing stack..."

            # Get S3 buckets from existing stack
            BUCKETS=$(aws cloudformation describe-stack-resources \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --stack-name "$STACK_NAME" \
                --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
                --output text)

            # Empty buckets
            for bucket in $BUCKETS; do
                print_info "Emptying bucket: $bucket"
                aws s3 rm s3://$bucket --profile "$AWS_PROFILE" --recursive 2>/dev/null || true
            done

            aws cloudformation delete-stack --profile "$AWS_PROFILE" --region "$AWS_REGION" --stack-name "$STACK_NAME"
            print_info "Waiting for stack deletion..."
            aws cloudformation wait stack-delete-complete --profile "$AWS_PROFILE" --region "$AWS_REGION" --stack-name "$STACK_NAME"
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
    print_header "Creating CloudWatch Logs Stack"

    print_info "Stack Name: $STACK_NAME"
    print_info "Template: $TEMPLATE_FILE"
    print_info "Log Group: $LOG_GROUP_NAME"

    aws cloudformation create-stack \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --template-body file://"$TEMPLATE_FILE" \
        --parameters \
            ParameterKey=OpenObserveEndpoint,ParameterValue="$OPENOBSERVE_ENDPOINT" \
            ParameterKey=OpenObserveAccessKey,ParameterValue="$OPENOBSERVE_ACCESS_KEY" \
            ParameterKey=StreamName,ParameterValue="$STREAM_NAME" \
            ParameterKey=LogGroupName,ParameterValue="$LOG_GROUP_NAME" \
            ParameterKey=BackupS3BucketName,ParameterValue="$BACKUP_BUCKET" \
            ParameterKey=ShardCount,ParameterValue="$SHARD_COUNT" \
            ParameterKey=FilterPattern,ParameterValue="$FILTER_PATTERN" \
        --capabilities CAPABILITY_IAM

    print_success "Stack creation initiated"
}

# Monitor stack creation
monitor_stack() {
    print_header "Monitoring Stack Creation"
    print_info "This may take 5-10 minutes..."
    echo ""

    # Show progress indicator
    aws cloudformation wait stack-create-complete --profile "$AWS_PROFILE" --region "$AWS_REGION" --stack-name "$STACK_NAME" &
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
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
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
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs' \
        --output table
}

# Print next steps
print_next_steps() {
    print_header "Next Steps"

    echo -e "${GREEN}1. Monitor logs in OpenObserve:${NC}"
    echo "   Stream: $STREAM_NAME"
    echo "   Logs appear in: seconds (near real-time)"
    echo ""
    echo -e "${GREEN}2. Test by writing to CloudWatch Logs:${NC}"
    echo "   aws logs put-log-events \\"
    echo "     --log-group-name $LOG_GROUP_NAME \\"
    echo "     --log-stream-name test-stream \\"
    echo "     --log-events timestamp=\$(date +%s)000,message=\"Test log message\""
    echo ""
    echo -e "${GREEN}3. Monitor Kinesis metrics:${NC}"
    echo "   aws cloudwatch get-metric-statistics \\"
    echo "     --namespace AWS/Kinesis \\"
    echo "     --metric-name IncomingRecords \\"
    echo "     --dimensions Name=StreamName,Value=${STACK_NAME}-cloudwatch-logs \\"
    echo "     --start-time \$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \\"
    echo "     --end-time \$(date -u +%Y-%m-%dT%H:%M:%S) \\"
    echo "     --period 300 --statistics Sum"
    echo ""
    echo -e "${GREEN}4. Check failed records:${NC}"
    echo "   aws s3 ls s3://$BACKUP_BUCKET/failed-logs/ --recursive"
    echo ""
    echo -e "${GREEN}5. View Lambda transformation logs:${NC}"
    echo "   aws logs tail /aws/lambda/${STACK_NAME}-log-transformer --follow"
}

# Print deployment summary
print_summary() {
    print_header "Deployment Summary"

    echo -e "${CYAN}Stack Name:${NC} $STACK_NAME"
    echo -e "${CYAN}Log Group:${NC} $LOG_GROUP_NAME"
    echo -e "${CYAN}OpenObserve Stream:${NC} $STREAM_NAME"
    echo -e "${CYAN}Kinesis Shards:${NC} $SHARD_COUNT"
    echo -e "${CYAN}Backup Bucket:${NC} $BACKUP_BUCKET"
    echo -e "${CYAN}Filter Pattern:${NC} ${FILTER_PATTERN:-None (all logs)}"
    echo -e "${CYAN}Estimated Cost:${NC} ~\$$(( 30 * SHARD_COUNT + 15 ))/month (per log group)"
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
    get_log_group
    get_filter_pattern
    validate_template
    generate_bucket_name
    configure_kinesis
    check_existing_stack
    create_stack
    monitor_stack
    get_outputs
    print_summary
    print_next_steps

    print_header "Deployment Complete!"
    print_success "Stack '$STACK_NAME' is ready"
    print_success "CloudWatch Logs subscription filter configured automatically"
    echo ""
    echo -e "${CYAN}To deploy for another log group, run this script again${NC}"
}

# Run main function
main
