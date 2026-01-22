#!/bin/bash

#######################################
# RDS Logs to OpenObserve Deployment Script
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
STREAM_NAME="rds-logs"
LOG_GROUP_NAME=""  # Will prompt if not set
RDS_INSTANCE_ID=""  # Will prompt if not set
FILTER_PATTERN=""
AWS_PROFILE="${AWS_PROFILE:-mdmosaraf_o2_dev}"
AWS_REGION="${AWS_REGION:-us-east-2}"

# Global variables
STACK_NAME=""  # Will be set based on RDS instance ID
TEMPLATE_FILE="rds-logs-to-openobserve.yaml"
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
    echo "   RDS Logs to OpenObserve Deployment"
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

# List RDS instances
list_rds_instances() {
    print_header "RDS Instances in $AWS_REGION"

    print_info "Fetching RDS instances..."
    echo ""

    # Get RDS instances
    INSTANCES=$(aws rds describe-db-instances \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'DBInstances[*].[DBInstanceIdentifier,Engine,DBInstanceStatus,EngineVersion]' \
        --output text 2>/dev/null || echo "")

    # Get RDS clusters
    CLUSTERS=$(aws rds describe-db-clusters \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'DBClusters[*].[DBClusterIdentifier,Engine,Status,EngineVersion]' \
        --output text 2>/dev/null || echo "")

    if [ -n "$INSTANCES" ]; then
        echo -e "${CYAN}DB Instances:${NC}"
        echo "$INSTANCES" | while IFS=$'\t' read -r id engine status version; do
            echo "  - $id (Engine: $engine $version, Status: $status)"
        done
        echo ""
    fi

    if [ -n "$CLUSTERS" ]; then
        echo -e "${CYAN}DB Clusters:${NC}"
        echo "$CLUSTERS" | while IFS=$'\t' read -r id engine status version; do
            echo "  - $id (Engine: $engine $version, Status: $status)"
        done
        echo ""
    fi

    if [ -z "$INSTANCES" ] && [ -z "$CLUSTERS" ]; then
        print_warning "No RDS instances or clusters found in $AWS_REGION"
        echo ""
    fi
}

# Get RDS instance identifier
get_rds_instance() {
    print_header "RDS Instance Configuration"

    if [ -n "$RDS_INSTANCE_ID" ]; then
        print_info "Using configured RDS instance: $RDS_INSTANCE_ID"
    else
        list_rds_instances

        echo "Enter the RDS instance or cluster identifier:"
        read -p "RDS Identifier: " input_rds_id

        if [ -z "$input_rds_id" ]; then
            print_error "RDS identifier cannot be empty"
            exit 1
        fi

        RDS_INSTANCE_ID="$input_rds_id"
    fi

    print_success "RDS Instance: $RDS_INSTANCE_ID"

    # Verify instance exists and get details
    if aws rds describe-db-instances \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --db-instance-identifier "$RDS_INSTANCE_ID" &> /dev/null; then

        ENGINE=$(aws rds describe-db-instances \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --db-instance-identifier "$RDS_INSTANCE_ID" \
            --query 'DBInstances[0].Engine' \
            --output text)

        ENABLED_LOGS=$(aws rds describe-db-instances \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --db-instance-identifier "$RDS_INSTANCE_ID" \
            --query 'DBInstances[0].EnabledCloudwatchLogsExports' \
            --output text)

        print_info "Engine: $ENGINE"
        print_info "Enabled CloudWatch Logs: ${ENABLED_LOGS:-None}"

    elif aws rds describe-db-clusters \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --db-cluster-identifier "$RDS_INSTANCE_ID" &> /dev/null; then

        ENGINE=$(aws rds describe-db-clusters \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --db-cluster-identifier "$RDS_INSTANCE_ID" \
            --query 'DBClusters[0].Engine' \
            --output text)

        ENABLED_LOGS=$(aws rds describe-db-clusters \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --db-cluster-identifier "$RDS_INSTANCE_ID" \
            --query 'DBClusters[0].EnabledCloudwatchLogsExports' \
            --output text)

        print_info "Engine: $ENGINE"
        print_info "Enabled CloudWatch Logs: ${ENABLED_LOGS:-None}"
    else
        print_error "RDS instance/cluster '$RDS_INSTANCE_ID' not found"
        exit 1
    fi
}

# Show available log types for the RDS engine
show_log_types() {
    print_header "Available RDS Log Types for $ENGINE"

    case "$ENGINE" in
        postgres|aurora-postgresql)
            echo "PostgreSQL/Aurora PostgreSQL log types:"
            echo "  - postgresql (general logs)"
            ;;
        mysql|aurora-mysql|aurora)
            echo "MySQL/Aurora MySQL log types:"
            echo "  - error (error logs)"
            echo "  - general (general query logs)"
            echo "  - slowquery (slow query logs)"
            echo "  - audit (audit logs - requires plugin)"
            ;;
        mariadb)
            echo "MariaDB log types:"
            echo "  - error (error logs)"
            echo "  - general (general query logs)"
            echo "  - slowquery (slow query logs)"
            echo "  - audit (audit logs)"
            ;;
        oracle-*)
            echo "Oracle log types:"
            echo "  - alert (alert logs)"
            echo "  - audit (audit files)"
            echo "  - trace (trace files)"
            echo "  - listener (listener logs)"
            ;;
        sqlserver-*)
            echo "SQL Server log types:"
            echo "  - error (error logs)"
            echo "  - agent (agent logs)"
            ;;
        *)
            echo "Unknown engine: $ENGINE"
            echo "Check RDS documentation for available log types"
            ;;
    esac
    echo ""

    if [ -z "$ENABLED_LOGS" ] || [ "$ENABLED_LOGS" = "None" ]; then
        print_warning "No CloudWatch Logs are currently enabled for this RDS instance"
        echo ""
        read -p "Do you want to enable CloudWatch Logs now? (Y/n): " -n 1 -r
        echo

        if [[ $REPLY =~ ^[Yy]?$ ]]; then
            print_info "Enabling CloudWatch Logs for $RDS_INSTANCE_ID..."

            # Determine log types to enable based on engine
            case "$ENGINE" in
                postgres|aurora-postgresql)
                    LOG_TYPES='["postgresql"]'
                    ;;
                mysql|aurora-mysql|aurora|mariadb)
                    LOG_TYPES='["error","slowquery"]'
                    ;;
                oracle*)
                    LOG_TYPES='["alert","audit"]'
                    ;;
                sqlserver*)
                    LOG_TYPES='["error","agent"]'
                    ;;
                *)
                    LOG_TYPES='["error"]'
                    ;;
            esac

            # Check if instance or cluster
            if aws rds describe-db-instances --profile "$AWS_PROFILE" --region "$AWS_REGION" --db-instance-identifier "$RDS_INSTANCE_ID" &> /dev/null; then
                # RDS Instance
                print_info "Enabling logs: $LOG_TYPES"
                aws rds modify-db-instance \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" \
                    --db-instance-identifier "$RDS_INSTANCE_ID" \
                    --cloudwatch-logs-export-configuration "{\"EnableLogTypes\":$LOG_TYPES}" \
                    --apply-immediately

                print_success "CloudWatch Logs export enabled"
            else
                # Aurora Cluster
                print_info "Enabling logs: $LOG_TYPES"
                aws rds modify-db-cluster \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" \
                    --db-cluster-identifier "$RDS_INSTANCE_ID" \
                    --cloudwatch-logs-export-configuration "{\"EnableLogTypes\":$LOG_TYPES}" \
                    --apply-immediately

                print_success "CloudWatch Logs export enabled"
            fi

            print_info "Waiting 30 seconds for log groups to be created..."
            sleep 30

            # Refresh enabled logs
            if aws rds describe-db-instances --profile "$AWS_PROFILE" --region "$AWS_REGION" --db-instance-identifier "$RDS_INSTANCE_ID" &> /dev/null; then
                ENABLED_LOGS=$(aws rds describe-db-instances \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" \
                    --db-instance-identifier "$RDS_INSTANCE_ID" \
                    --query 'DBInstances[0].EnabledCloudwatchLogsExports' \
                    --output text)
            else
                ENABLED_LOGS=$(aws rds describe-db-clusters \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" \
                    --db-cluster-identifier "$RDS_INSTANCE_ID" \
                    --query 'DBClusters[0].EnabledCloudwatchLogsExports' \
                    --output text)
            fi

            print_success "Enabled logs: $ENABLED_LOGS"
        else
            print_info "Deployment cancelled. Enable CloudWatch Logs and run this script again."
            exit 0
        fi
    fi
}

# List available log groups for this RDS instance
list_log_groups() {
    print_header "Available Log Groups for $RDS_INSTANCE_ID"

    print_info "Searching for log groups..."
    echo ""

    # Search for instance log groups
    INSTANCE_LOGS=$(aws logs describe-log-groups \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --log-group-name-prefix "/aws/rds/instance/$RDS_INSTANCE_ID" \
        --query 'logGroups[*].[logGroupName,storedBytes,retentionInDays]' \
        --output text 2>/dev/null || echo "")

    # Search for cluster log groups
    CLUSTER_LOGS=$(aws logs describe-log-groups \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --log-group-name-prefix "/aws/rds/cluster/$RDS_INSTANCE_ID" \
        --query 'logGroups[*].[logGroupName,storedBytes,retentionInDays]' \
        --output text 2>/dev/null || echo "")

    if [ -n "$INSTANCE_LOGS" ]; then
        echo -e "${CYAN}Instance Log Groups:${NC}"
        echo "$INSTANCE_LOGS" | while IFS=$'\t' read -r name size retention; do
            size_mb=$((size / 1024 / 1024))
            echo "  - $name (Size: ${size_mb}MB, Retention: ${retention:-Never expires})"
        done
        echo ""
    fi

    if [ -n "$CLUSTER_LOGS" ]; then
        echo -e "${CYAN}Cluster Log Groups:${NC}"
        echo "$CLUSTER_LOGS" | while IFS=$'\t' read -r name size retention; do
            size_mb=$((size / 1024 / 1024))
            echo "  - $name (Size: ${size_mb}MB, Retention: ${retention:-Never expires})"
        done
        echo ""
    fi

    if [ -z "$INSTANCE_LOGS" ] && [ -z "$CLUSTER_LOGS" ]; then
        print_warning "No log groups found for $RDS_INSTANCE_ID"
        echo ""
        print_info "This usually means CloudWatch Logs export is not enabled"
        echo ""
    fi
}

# Get log group name from user
get_log_group() {
    list_log_groups
    show_log_types

    if [ -n "$LOG_GROUP_NAME" ]; then
        print_info "Using configured log group: $LOG_GROUP_NAME"
    else
        # Determine default log group based on engine and instance type
        if aws rds describe-db-instances --profile "$AWS_PROFILE" --region "$AWS_REGION" --db-instance-identifier "$RDS_INSTANCE_ID" &> /dev/null; then
            # RDS Instance
            case "$ENGINE" in
                postgres|aurora-postgresql)
                    DEFAULT_LOG_GROUP="/aws/rds/instance/$RDS_INSTANCE_ID/postgresql"
                    ;;
                mysql|aurora-mysql|mariadb|aurora)
                    DEFAULT_LOG_GROUP="/aws/rds/instance/$RDS_INSTANCE_ID/error"
                    ;;
                oracle*)
                    DEFAULT_LOG_GROUP="/aws/rds/instance/$RDS_INSTANCE_ID/alert"
                    ;;
                sqlserver*)
                    DEFAULT_LOG_GROUP="/aws/rds/instance/$RDS_INSTANCE_ID/error"
                    ;;
                *)
                    DEFAULT_LOG_GROUP="/aws/rds/instance/$RDS_INSTANCE_ID/error"
                    ;;
            esac
        else
            # Aurora Cluster
            case "$ENGINE" in
                postgres|aurora-postgresql)
                    DEFAULT_LOG_GROUP="/aws/rds/cluster/$RDS_INSTANCE_ID/postgresql"
                    ;;
                *)
                    DEFAULT_LOG_GROUP="/aws/rds/cluster/$RDS_INSTANCE_ID/error"
                    ;;
            esac
        fi

        echo "Enter the CloudWatch Log Group name to stream logs from:"
        echo "Common patterns:"
        echo "  - /aws/rds/instance/$RDS_INSTANCE_ID/error"
        echo "  - /aws/rds/instance/$RDS_INSTANCE_ID/slowquery"
        echo "  - /aws/rds/cluster/$RDS_INSTANCE_ID/postgresql"
        echo ""
        read -p "Log Group Name (default: $DEFAULT_LOG_GROUP): " input_log_group

        # Use default if empty
        LOG_GROUP_NAME=${input_log_group:-$DEFAULT_LOG_GROUP}
    fi

    print_success "Log Group: $LOG_GROUP_NAME"

    # Check if log group exists
    if aws logs describe-log-groups \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --log-group-name-prefix "$LOG_GROUP_NAME" \
        --query "logGroups[?logGroupName=='$LOG_GROUP_NAME']" \
        --output text | grep -q "$LOG_GROUP_NAME"; then
        print_success "Log group '$LOG_GROUP_NAME' exists"
    else
        print_warning "Log group '$LOG_GROUP_NAME' does not exist yet"
        print_info "It will be created when RDS starts writing logs"
    fi

    # Generate stack name from RDS instance ID
    STACK_NAME_SUFFIX=$(echo "$RDS_INSTANCE_ID" | sed 's/[^a-zA-Z0-9-]/-/g' | tr '[:upper:]' '[:lower:]')
    STACK_NAME="rds-logs-${STACK_NAME_SUFFIX}"

    # Limit stack name to 128 characters
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
    echo "  - ERROR to match logs containing 'ERROR'"
    echo "  - FATAL to match logs containing 'FATAL'"
    echo "  - WARNING to match logs containing 'WARNING'"
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
    BACKUP_BUCKET="rds-logs-backup-${ACCOUNT_ID}-${TIMESTAMP}"

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

    if ! aws cloudformation validate-template \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --template-body file://"$TEMPLATE_FILE" &> /dev/null; then
        print_error "Template validation failed"
        aws cloudformation validate-template \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --template-body file://"$TEMPLATE_FILE"
        exit 1
    fi

    print_success "Template is valid"
}

# Check if stack already exists
check_existing_stack() {
    print_header "Checking Existing Stack"

    if aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" &> /dev/null; then

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

            aws cloudformation delete-stack \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --stack-name "$STACK_NAME"

            print_info "Waiting for stack deletion..."
            aws cloudformation wait stack-delete-complete \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --stack-name "$STACK_NAME"

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
    print_header "Creating RDS Logs Stack"

    print_info "Stack Name: $STACK_NAME"
    print_info "Template: $TEMPLATE_FILE"
    print_info "RDS Instance: $RDS_INSTANCE_ID"
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
            ParameterKey=RDSInstanceIdentifier,ParameterValue="$RDS_INSTANCE_ID" \
        --capabilities CAPABILITY_IAM

    print_success "Stack creation initiated"
}

# Monitor stack creation
monitor_stack() {
    print_header "Monitoring Stack Creation"
    print_info "This may take 5-10 minutes..."
    echo ""

    # Show progress indicator
    aws cloudformation wait stack-create-complete \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" &
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

    echo -e "${GREEN}1. Verify RDS CloudWatch Logs are enabled:${NC}"
    echo "   aws rds describe-db-instances \\"
    echo "     --db-instance-identifier $RDS_INSTANCE_ID \\"
    echo "     --query 'DBInstances[0].EnabledCloudwatchLogsExports'"
    echo ""
    echo -e "${GREEN}2. Monitor logs in OpenObserve:${NC}"
    echo "   Stream: $STREAM_NAME"
    echo "   Filter by: rds_identifier = '$RDS_INSTANCE_ID'"
    echo ""
    echo -e "${GREEN}3. Check subscription filter:${NC}"
    echo "   aws logs describe-subscription-filters \\"
    echo "     --log-group-name $LOG_GROUP_NAME"
    echo ""
    echo -e "${GREEN}4. Monitor Kinesis metrics:${NC}"
    echo "   aws cloudwatch get-metric-statistics \\"
    echo "     --namespace AWS/Kinesis \\"
    echo "     --metric-name IncomingRecords \\"
    echo "     --dimensions Name=StreamName,Value=${STACK_NAME}-rds-logs \\"
    echo "     --start-time \$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \\"
    echo "     --end-time \$(date -u +%Y-%m-%dT%H:%M:%S) \\"
    echo "     --period 300 --statistics Sum"
    echo ""
    echo -e "${GREEN}5. Check failed records:${NC}"
    echo "   aws s3 ls s3://$BACKUP_BUCKET/failed-logs/ --recursive"
    echo ""
    echo -e "${GREEN}6. View Lambda transformation logs:${NC}"
    echo "   aws logs tail /aws/lambda/${STACK_NAME}-log-transformer --follow"
}

# Print deployment summary
print_summary() {
    print_header "Deployment Summary"

    echo -e "${CYAN}Stack Name:${NC} $STACK_NAME"
    echo -e "${CYAN}RDS Instance:${NC} $RDS_INSTANCE_ID"
    echo -e "${CYAN}RDS Engine:${NC} $ENGINE"
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
    get_rds_instance
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
    print_success "RDS logs will be streamed to OpenObserve automatically"
    echo ""
    echo -e "${CYAN}To deploy for another RDS instance, run this script again${NC}"
}

# Run main function
main
