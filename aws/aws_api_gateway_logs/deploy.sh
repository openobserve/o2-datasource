#!/bin/bash

#######################################
# API Gateway Logs to OpenObserve Deployment Script
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
STREAM_NAME="apigateway-access-logs"
API_GATEWAY_ID=""  # Will prompt if not set
STAGE_NAME=""  # Will prompt if not set
FILTER_PATTERN=""
AWS_PROFILE="${AWS_PROFILE:-mdmosaraf_o2_dev}"
AWS_REGION="${AWS_REGION:-us-east-2}"

# Global variables
STACK_NAME=""  # Will be set based on API ID and stage
TEMPLATE_FILE="apigateway-logs-to-openobserve.yaml"
BACKUP_BUCKET=""
ACCOUNT_ID=""
SHARD_COUNT=1
LOG_GROUP_NAME=""
ENABLE_ACCESS_LOGGING="false"

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
    echo "  API Gateway Logs to OpenObserve Deployment"
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

# List API Gateways
list_api_gateways() {
    print_header "API Gateway Configuration"

    # List REST APIs
    print_info "Fetching REST API Gateways..."
    echo ""

    API_LIST=$(aws apigateway get-rest-apis \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'items[*].[id,name,createdDate]' \
        --output table 2>/dev/null || echo "")

    if [ -z "$API_LIST" ]; then
        print_warning "No REST API Gateways found in region $AWS_REGION"
        read -p "Do you want to enter API ID manually? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "No API Gateway selected"
            exit 1
        fi
    else
        echo "$API_LIST"
        echo ""
    fi

    # Get API Gateway ID
    if [ -n "$API_GATEWAY_ID" ]; then
        print_info "Using configured API Gateway ID: $API_GATEWAY_ID"
    else
        read -p "Enter API Gateway ID: " input_api_id
        if [ -z "$input_api_id" ]; then
            print_error "API Gateway ID cannot be empty"
            exit 1
        fi
        API_GATEWAY_ID="$input_api_id"
    fi

    # Verify API exists
    API_NAME=$(aws apigateway get-rest-api \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --rest-api-id "$API_GATEWAY_ID" \
        --query 'name' \
        --output text 2>/dev/null || echo "")

    if [ -z "$API_NAME" ]; then
        print_error "API Gateway '$API_GATEWAY_ID' not found"
        exit 1
    fi

    print_success "API Gateway found: $API_NAME (ID: $API_GATEWAY_ID)"
}

# Get stage information
get_stage() {
    print_header "Stage Configuration"

    # List stages for the API
    print_info "Fetching stages for API $API_GATEWAY_ID..."
    echo ""

    STAGES=$(aws apigateway get-stages \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --rest-api-id "$API_GATEWAY_ID" \
        --query 'item[*].[stageName,deploymentId,createdDate]' \
        --output table 2>/dev/null || echo "")

    if [ -z "$STAGES" ]; then
        print_warning "No stages found for API $API_GATEWAY_ID"
    else
        echo "$STAGES"
        echo ""
    fi

    # Get stage name
    if [ -n "$STAGE_NAME" ]; then
        print_info "Using configured stage: $STAGE_NAME"
    else
        read -p "Enter Stage Name (e.g., prod, dev, staging): " input_stage
        if [ -z "$input_stage" ]; then
            print_error "Stage name cannot be empty"
            exit 1
        fi
        STAGE_NAME="$input_stage"
    fi

    # Check if stage exists and if access logging is enabled
    STAGE_INFO=$(aws apigateway get-stage \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --rest-api-id "$API_GATEWAY_ID" \
        --stage-name "$STAGE_NAME" 2>/dev/null || echo "")

    if [ -z "$STAGE_INFO" ]; then
        print_warning "Stage '$STAGE_NAME' not found for API $API_GATEWAY_ID"
        print_info "The stage must exist before enabling logging"
        exit 1
    fi

    print_success "Stage found: $STAGE_NAME"

    # Check if access logging is enabled
    ACCESS_LOG_ARN=$(echo "$STAGE_INFO" | jq -r '.accessLogSettings.destinationArn // empty')

    if [ -z "$ACCESS_LOG_ARN" ]; then
        print_warning "Access logging is NOT currently enabled for this stage"
        echo ""
        echo "After stack deployment, you need to enable access logging with:"
        echo "1. Go to API Gateway Console"
        echo "2. Select your API: $API_GATEWAY_ID"
        echo "3. Select Stage: $STAGE_NAME"
        echo "4. Enable Access Logging"
        echo "5. Use CloudWatch Log Group ARN from stack outputs"
        echo "6. Set log format (see README.md for format options)"
        echo ""
        read -p "Continue with deployment? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        print_success "Access logging is already enabled"
        print_info "Current log destination: $ACCESS_LOG_ARN"
        echo ""
        print_warning "The existing access logging configuration will be replaced"
        read -p "Continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # Set log group name
    LOG_GROUP_NAME="/aws/apigateway/${API_GATEWAY_ID}/${STAGE_NAME}"
    print_info "Log Group: $LOG_GROUP_NAME"

    # Generate stack name
    STACK_NAME="apigateway-logs-${API_GATEWAY_ID}-${STAGE_NAME}"
    STACK_NAME=$(echo "$STACK_NAME" | tr '[:upper:]' '[:lower:]')
    print_info "Stack Name: $STACK_NAME"
}

# Get filter pattern
get_filter_pattern() {
    print_header "Log Filter Configuration"

    echo "Enter a CloudWatch Logs filter pattern (optional):"
    echo "Examples:"
    echo "  - Leave empty to stream ALL logs"
    echo "  - [statusCode >= 400] for errors only"
    echo "  - [latency > 1000] for slow requests (>1 second)"
    echo "  - [statusCode = 5*] for server errors"
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
    BACKUP_BUCKET="apigw-logs-backup-${ACCOUNT_ID}-${TIMESTAMP}"

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
    print_header "Creating API Gateway Logs Stack"

    print_info "Stack Name: $STACK_NAME"
    print_info "Template: $TEMPLATE_FILE"
    print_info "API Gateway: $API_GATEWAY_ID"
    print_info "Stage: $STAGE_NAME"

    aws cloudformation create-stack \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --template-body file://"$TEMPLATE_FILE" \
        --parameters \
            ParameterKey=OpenObserveEndpoint,ParameterValue="$OPENOBSERVE_ENDPOINT" \
            ParameterKey=OpenObserveAccessKey,ParameterValue="$OPENOBSERVE_ACCESS_KEY" \
            ParameterKey=StreamName,ParameterValue="$STREAM_NAME" \
            ParameterKey=ApiGatewayId,ParameterValue="$API_GATEWAY_ID" \
            ParameterKey=StageName,ParameterValue="$STAGE_NAME" \
            ParameterKey=BackupS3BucketName,ParameterValue="$BACKUP_BUCKET" \
            ParameterKey=ShardCount,ParameterValue="$SHARD_COUNT" \
            ParameterKey=FilterPattern,ParameterValue="$FILTER_PATTERN" \
            ParameterKey=EnableAccessLogging,ParameterValue="$ENABLE_ACCESS_LOGGING" \
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

# Enable API Gateway access logging
enable_access_logging() {
    print_header "Enabling API Gateway Access Logging"

    # Get the log group ARN from stack outputs
    LOG_GROUP_ARN=$(aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='LogGroupName'].OutputValue" \
        --output text)

    if [ -z "$LOG_GROUP_ARN" ]; then
        print_error "Could not get log group ARN from stack outputs"
        return
    fi

    # Construct full ARN
    FULL_LOG_GROUP_ARN="arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP_ARN}"

    print_info "Log Group ARN: $FULL_LOG_GROUP_ARN"

    # Recommended JSON log format for API Gateway
    LOG_FORMAT='{"requestId":"$context.requestId","sourceIp":"$context.identity.sourceIp","method":"$context.httpMethod","resourcePath":"$context.resourcePath","statusCode":"$context.status","responseLength":"$context.responseLength","requestTime":"$context.requestTime","latency":"$context.responseLatency","integrationLatency":"$context.integrationLatency","userAgent":"$context.identity.userAgent","protocol":"$context.protocol"}'

    echo ""
    print_info "To enable access logging, run this command:"
    echo ""
    echo "aws apigateway update-stage \\"
    echo "  --profile $AWS_PROFILE \\"
    echo "  --region $AWS_REGION \\"
    echo "  --rest-api-id $API_GATEWAY_ID \\"
    echo "  --stage-name $STAGE_NAME \\"
    echo "  --patch-operations \\"
    echo "    op=replace,path=/accessLogSettings/destinationArn,value=${FULL_LOG_GROUP_ARN} \\"
    echo "    op=replace,path=/accessLogSettings/format,value='${LOG_FORMAT}'"
    echo ""

    read -p "Do you want to enable access logging now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        aws apigateway update-stage \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --rest-api-id "$API_GATEWAY_ID" \
            --stage-name "$STAGE_NAME" \
            --patch-operations \
                "op=replace,path=/accessLogSettings/destinationArn,value=${FULL_LOG_GROUP_ARN}" \
                "op=replace,path=/accessLogSettings/format,value=${LOG_FORMAT}"

        print_success "Access logging enabled!"

        # Deploy the API to activate changes
        print_info "Deploying API to activate changes..."
        DEPLOYMENT_ID=$(aws apigateway create-deployment \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --rest-api-id "$API_GATEWAY_ID" \
            --stage-name "$STAGE_NAME" \
            --query 'id' \
            --output text)

        print_success "API deployed (Deployment ID: $DEPLOYMENT_ID)"
    else
        print_info "You can enable it later using the command above"
    fi
}

# Print next steps
print_next_steps() {
    print_header "Next Steps"

    echo -e "${GREEN}1. Monitor logs in OpenObserve:${NC}"
    echo "   Stream: $STREAM_NAME"
    echo "   API ID: $API_GATEWAY_ID"
    echo "   Stage: $STAGE_NAME"
    echo ""
    echo -e "${GREEN}2. Test by making API requests:${NC}"
    echo "   curl https://${API_GATEWAY_ID}.execute-api.${AWS_REGION}.amazonaws.com/${STAGE_NAME}/your-endpoint"
    echo ""
    echo -e "${GREEN}3. View API Gateway metrics:${NC}"
    echo "   aws cloudwatch get-metric-statistics \\"
    echo "     --namespace AWS/ApiGateway \\"
    echo "     --metric-name Count \\"
    echo "     --dimensions Name=ApiName,Value=${API_GATEWAY_ID} Name=Stage,Value=${STAGE_NAME} \\"
    echo "     --start-time \$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \\"
    echo "     --end-time \$(date -u +%Y-%m-%dT%H:%M:%S) \\"
    echo "     --period 300 --statistics Sum"
    echo ""
    echo -e "${GREEN}4. Check failed records:${NC}"
    echo "   aws s3 ls s3://$BACKUP_BUCKET/failed-logs/ --recursive"
    echo ""
    echo -e "${GREEN}5. View Lambda transformation logs:${NC}"
    echo "   aws logs tail /aws/lambda/${STACK_NAME}-log-transformer --follow"
    echo ""
    echo -e "${GREEN}6. Common OpenObserve queries:${NC}"
    echo "   - Error rate: statusCode >= 400"
    echo "   - Slow requests: latency > 1000"
    echo "   - Top endpoints: group by resourcePath"
    echo "   - Traffic by source: group by sourceIp"
}

# Print deployment summary
print_summary() {
    print_header "Deployment Summary"

    echo -e "${CYAN}Stack Name:${NC} $STACK_NAME"
    echo -e "${CYAN}API Gateway ID:${NC} $API_GATEWAY_ID"
    echo -e "${CYAN}Stage:${NC} $STAGE_NAME"
    echo -e "${CYAN}Log Group:${NC} $LOG_GROUP_NAME"
    echo -e "${CYAN}OpenObserve Stream:${NC} $STREAM_NAME"
    echo -e "${CYAN}Kinesis Shards:${NC} $SHARD_COUNT"
    echo -e "${CYAN}Backup Bucket:${NC} $BACKUP_BUCKET"
    echo -e "${CYAN}Filter Pattern:${NC} ${FILTER_PATTERN:-None (all logs)}"
    echo -e "${CYAN}Estimated Cost:${NC} ~\$$(( 30 * SHARD_COUNT + 15 ))/month"
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
    list_api_gateways
    get_stage
    get_filter_pattern
    validate_template
    generate_bucket_name
    configure_kinesis
    check_existing_stack
    create_stack
    monitor_stack
    get_outputs
    enable_access_logging
    print_summary
    print_next_steps

    print_header "Deployment Complete!"
    print_success "Stack '$STACK_NAME' is ready"
    print_success "API Gateway access logs will be streamed to OpenObserve"
    echo ""
    echo -e "${CYAN}To deploy for another API Gateway stage, run this script again${NC}"
}

# Run main function
main
