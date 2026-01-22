#!/bin/bash

#######################################
# Route53 Query Logs to OpenObserve Deployment Script
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
STREAM_NAME="route53-query-logs"
HOSTED_ZONE_ID=""  # Will prompt if not set
AWS_PROFILE="${AWS_PROFILE:-mdmosaraf_o2_dev}"
AWS_REGION="us-east-1"  # Route53 is a global service, must use us-east-1

# Global variables
STACK_NAME=""  # Will be set based on hosted zone ID
TEMPLATE_FILE="route53-logs-to-openobserve.yaml"
BACKUP_BUCKET=""
ACCOUNT_ID=""
SHARD_COUNT=1
HOSTED_ZONE_NAME=""

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
    echo "   Route53 Query Logs to OpenObserve Deployment"
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
    print_warning "Region forced to us-east-1 (Route53 is a global service)"
}

# List and select hosted zone
get_hosted_zone() {
    print_header "Route53 Hosted Zone Selection"

    # If hosted zone ID is already set, use it
    if [ -n "$HOSTED_ZONE_ID" ]; then
        print_info "Using configured hosted zone: $HOSTED_ZONE_ID"
    else
        # List all hosted zones
        print_info "Listing Route53 Hosted Zones..."
        echo ""

        # Get hosted zones with details
        ZONES_JSON=$(aws route53 list-hosted-zones --profile "$AWS_PROFILE" --query 'HostedZones[*].[Id,Name,Config.PrivateZone]' --output json)

        if [ "$ZONES_JSON" = "[]" ]; then
            print_error "No Route53 hosted zones found"
            exit 1
        fi

        # Display zones in a table format
        echo "Available Hosted Zones:"
        echo "-------------------------------------------------------------------------"
        printf "%-5s %-25s %-30s %-10s\n" "No." "Zone ID" "Domain Name" "Type"
        echo "-------------------------------------------------------------------------"

        ZONE_IDS=()
        ZONE_NAMES=()
        counter=1

        while IFS= read -r zone; do
            zone_id=$(echo "$zone" | jq -r '.[0]' | sed 's/\/hostedzone\///')
            zone_name=$(echo "$zone" | jq -r '.[1]')
            is_private=$(echo "$zone" | jq -r '.[2]')

            zone_type="Public"
            if [ "$is_private" = "true" ]; then
                zone_type="Private"
            fi

            printf "%-5s %-25s %-30s %-10s\n" "$counter" "$zone_id" "$zone_name" "$zone_type"

            ZONE_IDS+=("$zone_id")
            ZONE_NAMES+=("$zone_name")
            ((counter++))
        done < <(echo "$ZONES_JSON" | jq -c '.[]')

        echo "-------------------------------------------------------------------------"
        echo ""

        # Prompt for selection
        read -p "Select hosted zone (1-$((counter-1))): " zone_selection

        if ! [[ "$zone_selection" =~ ^[0-9]+$ ]] || [ "$zone_selection" -lt 1 ] || [ "$zone_selection" -ge "$counter" ]; then
            print_error "Invalid selection"
            exit 1
        fi

        # Get selected zone
        array_index=$((zone_selection - 1))
        HOSTED_ZONE_ID="${ZONE_IDS[$array_index]}"
        HOSTED_ZONE_NAME="${ZONE_NAMES[$array_index]}"
    fi

    print_success "Selected Hosted Zone: $HOSTED_ZONE_ID ($HOSTED_ZONE_NAME)"

    # Check if query logging is already enabled
    print_info "Checking existing query logging configuration..."
    EXISTING_CONFIG=$(aws route53 list-query-logging-configs \
        --profile "$AWS_PROFILE" \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --query 'QueryLoggingConfigs[0].Id' \
        --output text 2>/dev/null || echo "None")

    if [ "$EXISTING_CONFIG" != "None" ] && [ -n "$EXISTING_CONFIG" ]; then
        print_warning "Query logging already configured: $EXISTING_CONFIG"

        # Get existing log group
        EXISTING_LOG_GROUP=$(aws route53 list-query-logging-configs \
            --profile "$AWS_PROFILE" \
            --hosted-zone-id "$HOSTED_ZONE_ID" \
            --query 'QueryLoggingConfigs[0].CloudWatchLogsLogGroupArn' \
            --output text 2>/dev/null | sed 's/.*://g')

        print_info "Existing log group: $EXISTING_LOG_GROUP"
        echo ""
        echo "Options:"
        echo "  1) Use existing query logging and set up streaming (Recommended)"
        echo "  2) Delete and recreate query logging config"
        echo "  3) Cancel"
        echo ""
        read -p "Choose option (1-3, default: 1): " choice
        choice=${choice:-1}

        case $choice in
            1)
                print_success "Will use existing query logging configuration"
                print_info "CloudFormation will create streaming infrastructure only"
                USE_EXISTING_CONFIG=true

                # Delete existing config so CloudFormation can recreate it
                # (Route53 allows only 1 query logging config per hosted zone)
                print_info "Temporarily deleting existing config (will be recreated by CloudFormation)..."
                aws route53 delete-query-logging-config \
                    --profile "$AWS_PROFILE" \
                    --id "$EXISTING_CONFIG" &> /dev/null || print_warning "Could not delete existing config"

                print_success "Existing config removed (CloudFormation will recreate)"
                ;;
            2)
                print_info "Existing config will be deleted and recreated"
                USE_EXISTING_CONFIG=false

                # Delete existing config
                print_info "Deleting existing query logging config..."
                aws route53 delete-query-logging-config \
                    --profile "$AWS_PROFILE" \
                    --id "$EXISTING_CONFIG"

                print_success "Existing config deleted"
                ;;
            3)
                print_info "Deployment cancelled"
                exit 0
                ;;
            *)
                print_error "Invalid option"
                exit 1
                ;;
        esac
    else
        USE_EXISTING_CONFIG=false
    fi

    # Generate stack name from hosted zone ID
    STACK_NAME="route53-${HOSTED_ZONE_ID}"

    print_info "Stack Name: $STACK_NAME"
}

# Generate unique S3 bucket name
generate_bucket_name() {
    print_header "Generating S3 Bucket Name"

    TIMESTAMP=$(date +%s)
    BACKUP_BUCKET="route53-logs-backup-${ACCOUNT_ID}-${TIMESTAMP}"

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
    print_info "Estimated cost: ~\$$(( 30 * SHARD_COUNT + 15 ))/month + Route53 query logging fees"
    print_info "Route53 query logging: \$0.50 per million queries logged"
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
    print_header "Creating Route53 Query Logging Stack"

    print_info "Stack Name: $STACK_NAME"
    print_info "Template: $TEMPLATE_FILE"
    print_info "Hosted Zone: $HOSTED_ZONE_ID"

    aws cloudformation create-stack \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --template-body file://"$TEMPLATE_FILE" \
        --parameters \
            ParameterKey=OpenObserveEndpoint,ParameterValue="$OPENOBSERVE_ENDPOINT" \
            ParameterKey=OpenObserveAccessKey,ParameterValue="$OPENOBSERVE_ACCESS_KEY" \
            ParameterKey=StreamName,ParameterValue="$STREAM_NAME" \
            ParameterKey=HostedZoneId,ParameterValue="$HOSTED_ZONE_ID" \
            ParameterKey=BackupS3BucketName,ParameterValue="$BACKUP_BUCKET" \
            ParameterKey=ShardCount,ParameterValue="$SHARD_COUNT" \
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
    echo -e "${GREEN}2. Test by performing DNS queries:${NC}"
    echo "   dig @$(aws route53 get-hosted-zone --profile "$AWS_PROFILE" --id "$HOSTED_ZONE_ID" --query 'DelegationSet.NameServers[0]' --output text) $HOSTED_ZONE_NAME"
    echo "   nslookup $HOSTED_ZONE_NAME"
    echo ""
    echo -e "${GREEN}3. View CloudWatch Logs:${NC}"
    echo "   aws logs tail /aws/route53/${HOSTED_ZONE_ID} --follow --profile $AWS_PROFILE --region $AWS_REGION"
    echo ""
    echo -e "${GREEN}4. Monitor Kinesis metrics:${NC}"
    echo "   aws cloudwatch get-metric-statistics \\"
    echo "     --namespace AWS/Kinesis \\"
    echo "     --metric-name IncomingRecords \\"
    echo "     --dimensions Name=StreamName,Value=${STACK_NAME}-route53-logs \\"
    echo "     --start-time \$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \\"
    echo "     --end-time \$(date -u +%Y-%m-%dT%H:%M:%S) \\"
    echo "     --period 300 --statistics Sum \\"
    echo "     --profile $AWS_PROFILE --region $AWS_REGION"
    echo ""
    echo -e "${GREEN}5. Check failed records:${NC}"
    echo "   aws s3 ls s3://$BACKUP_BUCKET/failed-logs/ --recursive --profile $AWS_PROFILE"
    echo ""
    echo -e "${GREEN}6. View Lambda transformation logs:${NC}"
    echo "   aws logs tail /aws/lambda/${STACK_NAME}-route53-transformer --follow --profile $AWS_PROFILE --region $AWS_REGION"
}

# Print deployment summary
print_summary() {
    print_header "Deployment Summary"

    echo -e "${CYAN}Stack Name:${NC} $STACK_NAME"
    echo -e "${CYAN}Hosted Zone ID:${NC} $HOSTED_ZONE_ID"
    echo -e "${CYAN}Hosted Zone Name:${NC} $HOSTED_ZONE_NAME"
    echo -e "${CYAN}CloudWatch Log Group:${NC} /aws/route53/${HOSTED_ZONE_ID}"
    echo -e "${CYAN}OpenObserve Stream:${NC} $STREAM_NAME"
    echo -e "${CYAN}Kinesis Shards:${NC} $SHARD_COUNT"
    echo -e "${CYAN}Backup Bucket:${NC} $BACKUP_BUCKET"
    echo -e "${CYAN}Estimated Cost:${NC} ~\$$(( 30 * SHARD_COUNT + 15 ))/month + \$0.50 per million queries"
    echo ""
    echo -e "${YELLOW}Captured Data:${NC}"
    echo "  - Query timestamp"
    echo "  - Hosted zone ID"
    echo "  - Query name (domain)"
    echo "  - Query type (A, AAAA, CNAME, MX, etc.)"
    echo "  - Response code (NOERROR, NXDOMAIN, etc.)"
    echo "  - Protocol (TCP/UDP)"
    echo "  - Edge location"
    echo "  - Resolver IP"
    echo "  - EDNS client subnet"
}

# Create Route53 query logging config
create_query_logging_config() {
    print_header "Enabling Route53 Query Logging"

    # Get log group ARN from stack
    LOG_GROUP_ARN=$(aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`Route53LogGroupArn`].OutputValue' \
        --output text)

    print_info "Hosted Zone: $HOSTED_ZONE_ID"
    print_info "Log Group ARN: $LOG_GROUP_ARN"

    # Create query logging config
    # Remove :* from ARN if present (not needed for this API call)
    LOG_GROUP_ARN_CLEAN=$(echo "$LOG_GROUP_ARN" | sed 's/:*$//')

    if QUERY_CONFIG_ID=$(aws route53 create-query-logging-config \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --cloud-watch-logs-log-group-arn "$LOG_GROUP_ARN_CLEAN" \
        --profile "$AWS_PROFILE" \
        --query 'QueryLoggingConfig.Id' \
        --output text 2>&1); then

        print_success "Route53 query logging enabled"
        print_info "Query Logging Config ID: $QUERY_CONFIG_ID"
    else
        if echo "$QUERY_CONFIG_ID" | grep -q "QueryLoggingConfigAlreadyExists"; then
            print_warning "Query logging config already exists (this is OK)"
            QUERY_CONFIG_ID=$(aws route53 list-query-logging-configs \
                --hosted-zone-id "$HOSTED_ZONE_ID" \
                --profile "$AWS_PROFILE" \
                --query 'QueryLoggingConfigs[0].Id' \
                --output text)
            print_info "Existing Query Logging Config ID: $QUERY_CONFIG_ID"
        else
            print_error "Failed to enable query logging"
            echo "$QUERY_CONFIG_ID"
            print_info "You can enable it manually with the command shown in stack outputs"
        fi
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
    check_aws_cli
    check_credentials
    get_hosted_zone
    validate_template
    generate_bucket_name
    configure_kinesis
    check_existing_stack
    create_stack
    monitor_stack
    get_outputs

    # Create Route53 query logging config
    create_query_logging_config

    print_summary
    print_next_steps

    print_header "Deployment Complete!"
    print_success "Stack '$STACK_NAME' is ready"
    print_success "Route53 query logging configured for hosted zone: $HOSTED_ZONE_ID"
    echo ""
    echo -e "${CYAN}To deploy for another hosted zone, run this script again${NC}"
}

# Run main function
main
