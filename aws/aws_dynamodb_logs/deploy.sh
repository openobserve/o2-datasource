#!/bin/bash

#######################################
# DynamoDB Streams to OpenObserve Deployment Script
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
STREAM_NAME="dynamodb-streams"
DYNAMODB_TABLE_NAME=""  # Will prompt if not set
AWS_PROFILE="${AWS_PROFILE:-mdmosaraf_o2_dev}"
AWS_REGION="${AWS_REGION:-us-east-2}"

# Global variables
DEPLOYMENT_TYPE=""
STACK_NAME=""
TEMPLATE_FILE=""
BACKUP_BUCKET=""
ACCOUNT_ID=""
SHARD_COUNT=1
BATCH_SIZE=100

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
    echo "   DynamoDB Streams to OpenObserve Deployment"
    echo "================================================"
    echo -e "${NC}"
}

# Select deployment type
select_deployment_type() {
    print_header "Select Deployment Type"

    echo -e "${GREEN}1) Kinesis-based${NC} (Recommended)"
    echo "   • DynamoDB → Kinesis Stream → Firehose → OpenObserve"
    echo "   • Higher throughput and scalability"
    echo "   • Cost: ~\$50/month for 1M writes/day"
    echo "   • Best for: high-volume tables, production"
    echo ""
    echo -e "${GREEN}2) Lambda-based${NC} (Cost-effective)"
    echo "   • DynamoDB → Lambda → Firehose → OpenObserve"
    echo "   • Simpler setup, lower cost"
    echo "   • Cost: ~\$25/month for 1M writes/day"
    echo "   • Best for: low-volume tables, development"
    echo ""

    while true; do
        read -p "Choose option (1 or 2): " choice
        case $choice in
            1)
                DEPLOYMENT_TYPE="kinesis"
                TEMPLATE_FILE="dynamodb-streams-to-openobserve.yaml"
                print_success "Selected: Kinesis-based"
                break
                ;;
            2)
                DEPLOYMENT_TYPE="lambda"
                TEMPLATE_FILE="dynamodb-streams-to-openobserve-lambda.yaml"
                print_success "Selected: Lambda-based"
                break
                ;;
            *)
                print_error "Invalid option. Please choose 1 or 2."
                ;;
        esac
    done
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

# Get DynamoDB table name from user
get_dynamodb_table() {
    print_header "DynamoDB Table Configuration"

    # If table name is already set, use it
    if [ -n "$DYNAMODB_TABLE_NAME" ]; then
        print_info "Using configured table: $DYNAMODB_TABLE_NAME"
    else
        # List existing DynamoDB tables
        print_info "Listing DynamoDB tables..."
        echo ""
        TABLES=$(aws dynamodb list-tables --profile "$AWS_PROFILE" --region "$AWS_REGION" \
            --query 'TableNames[*]' --output text 2>/dev/null)

        if [ -n "$TABLES" ]; then
            echo "$TABLES" | tr '\t' '\n' | nl -w2 -s'. '
        else
            print_warning "No DynamoDB tables found"
        fi
        echo ""

        echo "Enter the DynamoDB table name to monitor:"
        read -p "Table Name: " input_table

        if [ -z "$input_table" ]; then
            print_error "Table name cannot be empty"
            exit 1
        fi

        DYNAMODB_TABLE_NAME="$input_table"
    fi

    print_info "Using DynamoDB Table: $DYNAMODB_TABLE_NAME"

    # Validate table exists
    if ! aws dynamodb describe-table --table-name "$DYNAMODB_TABLE_NAME" --profile "$AWS_PROFILE" --region "$AWS_REGION" &> /dev/null; then
        print_error "DynamoDB table '$DYNAMODB_TABLE_NAME' not found"
        exit 1
    fi

    # Check if streams are enabled
    STREAM_ENABLED=$(aws dynamodb describe-table --table-name "$DYNAMODB_TABLE_NAME" --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --query 'Table.StreamSpecification.StreamEnabled' --output text 2>/dev/null || echo "false")

    if [ "$STREAM_ENABLED" == "true" ]; then
        STREAM_ARN=$(aws dynamodb describe-table --table-name "$DYNAMODB_TABLE_NAME" --profile "$AWS_PROFILE" --region "$AWS_REGION" \
            --query 'Table.LatestStreamArn' --output text)
        print_success "DynamoDB Streams enabled"
        print_info "Stream ARN: $STREAM_ARN"
    else
        print_warning "DynamoDB Streams NOT enabled on table"
        print_info "Streams will be enabled automatically during deployment"
    fi

    # Generate unique stack name from table name
    STACK_NAME_SUFFIX=$(echo "$DYNAMODB_TABLE_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    if [ "$DEPLOYMENT_TYPE" == "kinesis" ]; then
        STACK_NAME="ddb-kinesis-${STACK_NAME_SUFFIX}"
    else
        STACK_NAME="ddb-lambda-${STACK_NAME_SUFFIX}"
    fi

    # Limit stack name to 128 characters
    if [ ${#STACK_NAME} -gt 128 ]; then
        STACK_NAME="${STACK_NAME:0:128}"
    fi

    print_info "Stack Name: $STACK_NAME"
}

# Generate unique S3 bucket name
generate_bucket_name() {
    print_header "Generating S3 Bucket Name"

    TIMESTAMP=$(date +%s)
    BACKUP_BUCKET="ddb-backup-${ACCOUNT_ID}-${TIMESTAMP}"

    print_success "Generated unique bucket name"
    print_info "Backup Bucket: $BACKUP_BUCKET"
}

# Configure Kinesis settings (for Kinesis-based option)
configure_kinesis() {
    print_header "Kinesis Configuration"

    read -p "Enter Kinesis shard count (1-10, default 1): " shard_input
    SHARD_COUNT=${shard_input:-1}

    if [ "$SHARD_COUNT" -lt 1 ] || [ "$SHARD_COUNT" -gt 10 ]; then
        print_warning "Invalid shard count. Using default: 1"
        SHARD_COUNT=1
    fi

    print_info "Shard Count: $SHARD_COUNT"
    print_info "Estimated cost: ~\$$(( 30 * SHARD_COUNT + 20 ))/month"
}

# Configure Lambda settings (for Lambda-based option)
configure_lambda() {
    print_header "Lambda Configuration"

    read -p "Enter DynamoDB Stream batch size (1-10000, default 100): " batch_input
    BATCH_SIZE=${batch_input:-100}

    if [ "$BATCH_SIZE" -lt 1 ] || [ "$BATCH_SIZE" -gt 10000 ]; then
        print_warning "Invalid batch size. Using default: 100"
        BATCH_SIZE=100
    fi

    print_info "Batch Size: $BATCH_SIZE"
    print_info "Estimated cost: ~\$25/month"
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

# Create CloudFormation stack for Kinesis-based option
create_kinesis_stack() {
    print_header "Creating Kinesis-based Stack"

    print_info "Stack Name: $STACK_NAME"
    print_info "Template: $TEMPLATE_FILE"
    print_info "DynamoDB Table: $DYNAMODB_TABLE_NAME"

    aws cloudformation create-stack \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --template-body file://"$TEMPLATE_FILE" \
        --parameters \
            ParameterKey=OpenObserveEndpoint,ParameterValue="$OPENOBSERVE_ENDPOINT" \
            ParameterKey=OpenObserveAccessKey,ParameterValue="$OPENOBSERVE_ACCESS_KEY" \
            ParameterKey=StreamName,ParameterValue="$STREAM_NAME" \
            ParameterKey=DynamoDBTableName,ParameterValue="$DYNAMODB_TABLE_NAME" \
            ParameterKey=BackupS3BucketName,ParameterValue="$BACKUP_BUCKET" \
            ParameterKey=ShardCount,ParameterValue="$SHARD_COUNT" \
        --capabilities CAPABILITY_IAM

    print_success "Stack creation initiated"
}

# Create CloudFormation stack for Lambda-based option
create_lambda_stack() {
    print_header "Creating Lambda-based Stack"

    print_info "Stack Name: $STACK_NAME"
    print_info "Template: $TEMPLATE_FILE"
    print_info "DynamoDB Table: $DYNAMODB_TABLE_NAME"

    # Enable DynamoDB Streams if not already enabled
    STREAM_ENABLED=$(aws dynamodb describe-table --table-name "$DYNAMODB_TABLE_NAME" --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --query 'Table.StreamSpecification.StreamEnabled' --output text 2>/dev/null || echo "false")

    if [ "$STREAM_ENABLED" != "true" ]; then
        print_info "Enabling DynamoDB Streams on table..."
        aws dynamodb update-table \
            --table-name "$DYNAMODB_TABLE_NAME" \
            --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" > /dev/null

        print_success "DynamoDB Streams enabled"
        print_info "Waiting 10 seconds for stream to be ready..."
        sleep 10
    fi

    # Get stream ARN
    STREAM_ARN=$(aws dynamodb describe-table --table-name "$DYNAMODB_TABLE_NAME" --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --query 'Table.LatestStreamArn' --output text)

    print_info "Stream ARN: $STREAM_ARN"

    # Create stack with stream ARN
    aws cloudformation create-stack \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --template-body file://"$TEMPLATE_FILE" \
        --parameters \
            ParameterKey=OpenObserveEndpoint,ParameterValue="$OPENOBSERVE_ENDPOINT" \
            ParameterKey=OpenObserveAccessKey,ParameterValue="$OPENOBSERVE_ACCESS_KEY" \
            ParameterKey=StreamName,ParameterValue="$STREAM_NAME" \
            ParameterKey=DynamoDBTableName,ParameterValue="$DYNAMODB_TABLE_NAME" \
            ParameterKey=DynamoDBStreamArn,ParameterValue="$STREAM_ARN" \
            ParameterKey=BackupS3BucketName,ParameterValue="$BACKUP_BUCKET" \
            ParameterKey=BatchSize,ParameterValue="$BATCH_SIZE" \
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

# Enable Kinesis streaming destination (for Kinesis-based option)
enable_kinesis_destination() {
    print_header "Enabling Kinesis Streaming Destination"

    # Get Kinesis stream ARN from stack
    KINESIS_ARN=$(aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`KinesisStreamArn`].OutputValue' \
        --output text)

    print_info "Table: $DYNAMODB_TABLE_NAME"
    print_info "Kinesis Stream: $KINESIS_ARN"

    # Enable Kinesis streaming destination
    if aws dynamodb enable-kinesis-streaming-destination \
        --table-name "$DYNAMODB_TABLE_NAME" \
        --stream-arn "$KINESIS_ARN" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" &> /dev/null; then

        print_success "Kinesis streaming destination enabled"
        print_info "DynamoDB changes will now stream to Kinesis"
    else
        print_warning "Failed to enable Kinesis streaming destination automatically"
        print_info "You can enable it manually:"
        print_info "aws dynamodb enable-kinesis-streaming-destination \\"
        print_info "  --table-name $DYNAMODB_TABLE_NAME \\"
        print_info "  --stream-arn $KINESIS_ARN"
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

    echo -e "${GREEN}1. Monitor data in OpenObserve:${NC}"
    echo "   Stream: $STREAM_NAME"
    echo "   Data appears in: seconds (near real-time)"
    echo ""
    echo -e "${GREEN}2. Test by writing to DynamoDB:${NC}"
    echo "   aws dynamodb put-item \\"
    echo "     --table-name $DYNAMODB_TABLE_NAME \\"
    echo "     --item '{\"id\": {\"S\": \"test-123\"}, \"data\": {\"S\": \"test value\"}}'"
    echo ""

    if [ "$DEPLOYMENT_TYPE" == "kinesis" ]; then
        echo -e "${GREEN}3. Monitor Kinesis metrics:${NC}"
        echo "   aws cloudwatch get-metric-statistics \\"
        echo "     --namespace AWS/Kinesis \\"
        echo "     --metric-name IncomingRecords \\"
        echo "     --dimensions Name=StreamName,Value=${STACK_NAME}-dynamodb-stream \\"
        echo "     --start-time \$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \\"
        echo "     --end-time \$(date -u +%Y-%m-%dT%H:%M:%S) \\"
        echo "     --period 300 --statistics Sum"
    else
        echo -e "${GREEN}3. Monitor Lambda execution:${NC}"
        echo "   aws logs tail /aws/lambda/${STACK_NAME}-stream-processor --follow"
    fi

    echo ""
    echo -e "${GREEN}4. Check failed records:${NC}"
    echo "   aws s3 ls s3://$BACKUP_BUCKET/failed-logs/ --recursive"
}

# Print deployment summary
print_summary() {
    print_header "Deployment Summary"

    echo -e "${CYAN}Deployment Type:${NC} $DEPLOYMENT_TYPE"
    echo -e "${CYAN}Stack Name:${NC} $STACK_NAME"
    echo -e "${CYAN}DynamoDB Table:${NC} $DYNAMODB_TABLE_NAME"
    echo -e "${CYAN}OpenObserve Stream:${NC} $STREAM_NAME"
    echo -e "${CYAN}Backup Bucket:${NC} $BACKUP_BUCKET"

    if [ "$DEPLOYMENT_TYPE" == "kinesis" ]; then
        echo -e "${CYAN}Kinesis Shards:${NC} $SHARD_COUNT"
        echo -e "${CYAN}Estimated Cost:${NC} ~\$$(( 30 * SHARD_COUNT + 20 ))/month (per table)"
    else
        echo -e "${CYAN}Batch Size:${NC} $BATCH_SIZE"
        echo -e "${CYAN}Estimated Cost:${NC} ~\$25/month (per table)"
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
    get_dynamodb_table
    validate_template
    generate_bucket_name

    if [ "$DEPLOYMENT_TYPE" == "kinesis" ]; then
        configure_kinesis
    else
        configure_lambda
    fi

    check_existing_stack

    if [ "$DEPLOYMENT_TYPE" == "kinesis" ]; then
        create_kinesis_stack
    else
        create_lambda_stack
    fi

    monitor_stack
    get_outputs

    # Enable Kinesis destination for Kinesis-based option
    if [ "$DEPLOYMENT_TYPE" == "kinesis" ]; then
        enable_kinesis_destination
    fi

    print_summary
    print_next_steps

    print_header "Deployment Complete!"
    print_success "Stack '$STACK_NAME' is ready"
    print_success "DynamoDB Streams configured automatically"
    echo ""
    echo -e "${CYAN}To deploy for another DynamoDB table, run this script again${NC}"
}

# Run main function
main
