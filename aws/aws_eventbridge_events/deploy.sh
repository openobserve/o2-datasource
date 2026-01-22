#!/bin/bash

#######################################
# EventBridge to OpenObserve Deployment Script
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
STREAM_NAME="eventbridge-events"
RULE_NAME=""  # Will prompt if not set
EVENT_PATTERN=""  # Will prompt if not set
AWS_PROFILE="${AWS_PROFILE:-mdmosaraf_o2_dev}"
AWS_REGION="${AWS_REGION:-us-east-2}"

# Global variables
STACK_NAME=""  # Will be set based on rule name
TEMPLATE_FILE="eventbridge-to-openobserve.yaml"
BACKUP_BUCKET=""
ACCOUNT_ID=""

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
    echo "   EventBridge to OpenObserve Deployment"
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

# Show event pattern examples
show_event_pattern_examples() {
    echo -e "${CYAN}Common Event Pattern Examples:${NC}"
    echo ""
    echo -e "${GREEN}1) All EC2 state changes:${NC}"
    echo '{"source":["aws.ec2"],"detail-type":["EC2 Instance State-change Notification"]}'
    echo ""
    echo -e "${GREEN}2) All events (any AWS service):${NC}"
    echo '{"source":[{"prefix":"aws."}]}'
    echo ""
    echo -e "${GREEN}3) S3 object created events:${NC}"
    echo '{"source":["aws.s3"],"detail-type":["Object Created"]}'
    echo ""
    echo -e "${GREEN}4) Lambda function errors:${NC}"
    echo '{"source":["aws.lambda"],"detail-type":["Lambda Function Execution State Change"],"detail":{"status":["Failed"]}}'
    echo ""
    echo -e "${GREEN}5) Auto Scaling events:${NC}"
    echo '{"source":["aws.autoscaling"]}'
    echo ""
    echo -e "${GREEN}6) ECS task state changes:${NC}"
    echo '{"source":["aws.ecs"],"detail-type":["ECS Task State Change"]}'
    echo ""
    echo -e "${GREEN}7) CodePipeline state changes:${NC}"
    echo '{"source":["aws.codepipeline"],"detail-type":["CodePipeline Pipeline Execution State Change"]}'
    echo ""
    echo -e "${GREEN}8) CloudTrail API calls (requires CloudTrail setup):${NC}"
    echo '{"source":["aws.cloudtrail"],"detail-type":["AWS API Call via CloudTrail"]}'
    echo ""
    echo -e "${GREEN}9) RDS database events:${NC}"
    echo '{"source":["aws.rds"]}'
    echo ""
    echo -e "${GREEN}10) Custom application events:${NC}"
    echo '{"source":["custom.myapp"],"detail-type":["order.placed"]}'
    echo ""
}

# Get event pattern from user
get_event_pattern() {
    print_header "EventBridge Event Pattern Configuration"

    show_event_pattern_examples

    echo -e "${YELLOW}Enter the number for a common pattern (1-10) or paste your custom JSON:${NC}"
    read -p "Event Pattern: " pattern_input

    case "$pattern_input" in
        1)
            EVENT_PATTERN='{"source":["aws.ec2"],"detail-type":["EC2 Instance State-change Notification"]}'
            SUGGESTED_RULE_NAME="ec2-state-changes"
            ;;
        2)
            EVENT_PATTERN='{"source":[{"prefix":"aws."}]}'
            SUGGESTED_RULE_NAME="all-aws-events"
            ;;
        3)
            EVENT_PATTERN='{"source":["aws.s3"],"detail-type":["Object Created"]}'
            SUGGESTED_RULE_NAME="s3-object-created"
            ;;
        4)
            EVENT_PATTERN='{"source":["aws.lambda"],"detail-type":["Lambda Function Execution State Change"],"detail":{"status":["Failed"]}}'
            SUGGESTED_RULE_NAME="lambda-errors"
            ;;
        5)
            EVENT_PATTERN='{"source":["aws.autoscaling"]}'
            SUGGESTED_RULE_NAME="autoscaling-events"
            ;;
        6)
            EVENT_PATTERN='{"source":["aws.ecs"],"detail-type":["ECS Task State Change"]}'
            SUGGESTED_RULE_NAME="ecs-task-changes"
            ;;
        7)
            EVENT_PATTERN='{"source":["aws.codepipeline"],"detail-type":["CodePipeline Pipeline Execution State Change"]}'
            SUGGESTED_RULE_NAME="codepipeline-changes"
            ;;
        8)
            EVENT_PATTERN='{"source":["aws.cloudtrail"],"detail-type":["AWS API Call via CloudTrail"]}'
            SUGGESTED_RULE_NAME="cloudtrail-api-calls"
            ;;
        9)
            EVENT_PATTERN='{"source":["aws.rds"]}'
            SUGGESTED_RULE_NAME="rds-events"
            ;;
        10)
            EVENT_PATTERN='{"source":["custom.myapp"],"detail-type":["order.placed"]}'
            SUGGESTED_RULE_NAME="custom-app-events"
            ;;
        *)
            # Treat as custom JSON
            EVENT_PATTERN="$pattern_input"
            SUGGESTED_RULE_NAME="custom-rule"
            ;;
    esac

    # Validate JSON
    if ! echo "$EVENT_PATTERN" | jq . &> /dev/null; then
        print_error "Invalid JSON event pattern"
        exit 1
    fi

    print_success "Event pattern validated"
    print_info "Pattern: $EVENT_PATTERN"
}

# Get rule name from user
get_rule_name() {
    print_header "EventBridge Rule Name Configuration"

    if [ -n "$SUGGESTED_RULE_NAME" ]; then
        print_info "Suggested rule name: $SUGGESTED_RULE_NAME"
        read -p "Enter rule name (press Enter to use suggested): " input_rule_name

        if [ -z "$input_rule_name" ]; then
            RULE_NAME="$SUGGESTED_RULE_NAME"
        else
            RULE_NAME="$input_rule_name"
        fi
    else
        read -p "Enter EventBridge rule name: " input_rule_name

        if [ -z "$input_rule_name" ]; then
            print_error "Rule name cannot be empty"
            exit 1
        fi

        RULE_NAME="$input_rule_name"
    fi

    # Sanitize rule name (only alphanumeric, hyphens, underscores)
    RULE_NAME=$(echo "$RULE_NAME" | sed 's/[^a-zA-Z0-9-_]/-/g' | tr '[:upper:]' '[:lower:]')

    print_info "Using Rule Name: $RULE_NAME"

    # Generate stack name from rule name
    STACK_NAME="eventbridge-${RULE_NAME}"

    # Limit stack name to 128 characters (CloudFormation limit)
    if [ ${#STACK_NAME} -gt 128 ]; then
        STACK_NAME="${STACK_NAME:0:128}"
    fi

    print_info "Stack Name: $STACK_NAME"
}

# Generate unique S3 bucket name
generate_bucket_name() {
    print_header "Generating S3 Bucket Name"

    TIMESTAMP=$(date +%s)
    BACKUP_BUCKET="eventbridge-backup-${ACCOUNT_ID}-${TIMESTAMP}"

    print_success "Generated unique bucket name"
    print_info "Backup Bucket: $BACKUP_BUCKET"
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
    print_header "Creating EventBridge Stack"

    print_info "Stack Name: $STACK_NAME"
    print_info "Template: $TEMPLATE_FILE"
    print_info "Rule Name: $RULE_NAME"
    print_info "Event Pattern: $EVENT_PATTERN"

    aws cloudformation create-stack \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --template-body file://"$TEMPLATE_FILE" \
        --parameters \
            ParameterKey=OpenObserveEndpoint,ParameterValue="$OPENOBSERVE_ENDPOINT" \
            ParameterKey=OpenObserveAccessKey,ParameterValue="$OPENOBSERVE_ACCESS_KEY" \
            ParameterKey=StreamName,ParameterValue="$STREAM_NAME" \
            ParameterKey=RuleName,ParameterValue="$RULE_NAME" \
            ParameterKey=EventPattern,ParameterValue="$EVENT_PATTERN" \
            ParameterKey=BackupS3BucketName,ParameterValue="$BACKUP_BUCKET" \
        --capabilities CAPABILITY_IAM

    print_success "Stack creation initiated"
}

# Monitor stack creation
monitor_stack() {
    print_header "Monitoring Stack Creation"
    print_info "This may take 3-5 minutes..."
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

    echo -e "${GREEN}1. Monitor events in OpenObserve:${NC}"
    echo "   Stream: $STREAM_NAME"
    echo "   Events appear in: seconds (near real-time)"
    echo ""
    echo -e "${GREEN}2. Test by triggering a matching event:${NC}"

    # Show specific test command based on event pattern
    if echo "$EVENT_PATTERN" | grep -q "aws.ec2"; then
        echo "   # Trigger EC2 state change:"
        echo "   aws ec2 run-instances --image-id ami-xxxxx --instance-type t2.micro"
        echo "   aws ec2 terminate-instances --instance-ids i-xxxxx"
    elif echo "$EVENT_PATTERN" | grep -q "custom"; then
        echo "   # Send custom event:"
        echo "   aws events put-events --entries '["
        echo "     {"
        echo '       "Source": "custom.myapp",'
        echo '       "DetailType": "order.placed",'
        echo '       "Detail": "{\"orderId\":\"12345\",\"amount\":99.99}"'
        echo "     }"
        echo "   ]'"
    else
        echo "   # Send test event:"
        echo "   aws events put-events --entries '["
        echo "     {"
        echo "       \"Source\": \"aws.ec2\","
        echo "       \"DetailType\": \"EC2 Instance State-change Notification\","
        echo "       \"Detail\": \"{\\\"instance-id\\\":\\\"i-test123\\\",\\\"state\\\":\\\"running\\\"}\""
        echo "     }"
        echo "   ]'"
    fi
    echo ""
    echo -e "${GREEN}3. Monitor EventBridge rule:${NC}"
    echo "   aws events describe-rule --name $RULE_NAME"
    echo ""
    echo -e "${GREEN}4. Check Firehose delivery metrics:${NC}"
    echo "   aws cloudwatch get-metric-statistics \\"
    echo "     --namespace AWS/Firehose \\"
    echo "     --metric-name DeliveryToHttpEndpoint.Success \\"
    echo "     --dimensions Name=DeliveryStreamName,Value=${STACK_NAME}-to-openobserve \\"
    echo "     --start-time \$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \\"
    echo "     --end-time \$(date -u +%Y-%m-%dT%H:%M:%S) \\"
    echo "     --period 300 --statistics Sum"
    echo ""
    echo -e "${GREEN}5. Check failed records:${NC}"
    echo "   aws s3 ls s3://$BACKUP_BUCKET/failed-events/ --recursive"
}

# Print deployment summary
print_summary() {
    print_header "Deployment Summary"

    echo -e "${CYAN}Stack Name:${NC} $STACK_NAME"
    echo -e "${CYAN}Rule Name:${NC} $RULE_NAME"
    echo -e "${CYAN}OpenObserve Stream:${NC} $STREAM_NAME"
    echo -e "${CYAN}Backup Bucket:${NC} $BACKUP_BUCKET"
    echo -e "${CYAN}Event Pattern:${NC}"
    echo "$EVENT_PATTERN" | jq .
    echo -e "${CYAN}Estimated Cost:${NC} ~\$15-20/month (Firehose + S3)"
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
    get_event_pattern
    get_rule_name
    validate_template
    generate_bucket_name
    check_existing_stack
    create_stack
    monitor_stack
    get_outputs
    print_summary
    print_next_steps

    print_header "Deployment Complete!"
    print_success "Stack '$STACK_NAME' is ready"
    print_success "EventBridge rule '$RULE_NAME' is capturing events"
    echo ""
    echo -e "${CYAN}To deploy another rule, run this script again${NC}"
}

# Run main function
main
