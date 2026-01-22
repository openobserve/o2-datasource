#!/bin/bash

#######################################
# RDS Logs to OpenObserve Cleanup Script
# Safely removes all deployed resources
#######################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
AWS_PROFILE="${AWS_PROFILE:-mdmosaraf_o2_dev}"
REGION="${AWS_REGION:-us-east-2}"  # Will be updated if stacks found in different region

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
    echo "   RDS Logs to OpenObserve Cleanup"
    echo "================================================"
    echo -e "${NC}"
}

# Find all related CloudFormation stacks
find_stacks() {
    print_header "Finding CloudFormation Stacks" >&2

    # Search for rds-logs-* stacks
    STACKS=$(aws cloudformation list-stacks \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
        --query 'StackSummaries[?starts_with(StackName, `rds-logs-`)].StackName' \
        --output text)

    if [ -z "$STACKS" ]; then
        print_warning "No CloudFormation stacks found in $REGION" >&2

        # Check other common regions
        print_info "Checking us-east-1..." >&2
        STACKS=$(aws cloudformation list-stacks \
            --profile "$AWS_PROFILE" \
            --region us-east-1 \
            --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
            --query 'StackSummaries[?starts_with(StackName, `rds-logs-`)].StackName' \
            --output text)

        if [ -z "$STACKS" ]; then
            print_error "No stacks found in us-east-1 or $REGION" >&2
            exit 0
        else
            REGION="us-east-1"
        fi
    fi

    echo "$STACKS"
}

# Show what will be deleted
show_resources() {
    local STACK_NAME=$1
    local REGION=$2

    print_header "Resources in Stack: $STACK_NAME"

    aws cloudformation describe-stack-resources \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query 'StackResources[*].[ResourceType,LogicalResourceId,PhysicalResourceId]' \
        --output table
}

# Empty S3 buckets
empty_s3_buckets() {
    local STACK_NAME=$1
    local REGION=$2

    print_header "Emptying S3 Buckets"

    BUCKETS=$(aws cloudformation describe-stack-resources \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query 'StackResources[?ResourceType==`AWS::S3::Bucket`].PhysicalResourceId' \
        --output text)

    if [ -z "$BUCKETS" ]; then
        print_info "No S3 buckets found"
        return
    fi

    for bucket in $BUCKETS; do
        print_info "Emptying bucket: $bucket"

        # Check if bucket exists
        if aws s3 ls "s3://$bucket" --profile "$AWS_PROFILE" &> /dev/null; then
            # Delete all objects
            aws s3 rm "s3://$bucket" \
                --profile "$AWS_PROFILE" \
                --recursive \
                --quiet || print_warning "Failed to empty $bucket (might already be empty)"

            # Delete all versions if versioning is enabled
            aws s3api delete-objects \
                --profile "$AWS_PROFILE" \
                --bucket "$bucket" \
                --delete "$(aws s3api list-object-versions \
                    --profile "$AWS_PROFILE" \
                    --bucket "$bucket" \
                    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
                    --max-items 1000)" 2>/dev/null || true

            print_success "Bucket $bucket emptied"
        else
            print_warning "Bucket $bucket does not exist or is already deleted"
        fi
    done
}

# Offer to disable RDS CloudWatch Logs export
offer_disable_rds_logs() {
    local STACK_NAME=$1
    local REGION=$2

    # Extract RDS instance ID from stack name (format: rds-logs-<instance-id>)
    RDS_INSTANCE_ID=$(echo "$STACK_NAME" | sed 's/^rds-logs-//')

    print_header "RDS CloudWatch Logs Configuration"

    # Check if RDS instance/cluster exists and has logs enabled
    ENABLED_LOGS=""
    IS_CLUSTER=false

    if aws rds describe-db-instances --profile "$AWS_PROFILE" --region "$REGION" --db-instance-identifier "$RDS_INSTANCE_ID" &> /dev/null; then
        ENABLED_LOGS=$(aws rds describe-db-instances \
            --profile "$AWS_PROFILE" \
            --region "$REGION" \
            --db-instance-identifier "$RDS_INSTANCE_ID" \
            --query 'DBInstances[0].EnabledCloudwatchLogsExports' \
            --output text 2>/dev/null || echo "")
    elif aws rds describe-db-clusters --profile "$AWS_PROFILE" --region "$REGION" --db-cluster-identifier "$RDS_INSTANCE_ID" &> /dev/null; then
        IS_CLUSTER=true
        ENABLED_LOGS=$(aws rds describe-db-clusters \
            --profile "$AWS_PROFILE" \
            --region "$REGION" \
            --db-cluster-identifier "$RDS_INSTANCE_ID" \
            --query 'DBClusters[0].EnabledCloudwatchLogsExports' \
            --output text 2>/dev/null || echo "")
    else
        print_warning "RDS instance/cluster '$RDS_INSTANCE_ID' not found (may have been deleted)"
        return
    fi

    if [ -n "$ENABLED_LOGS" ] && [ "$ENABLED_LOGS" != "None" ]; then
        print_info "RDS instance '$RDS_INSTANCE_ID' has CloudWatch Logs enabled: $ENABLED_LOGS"
        echo ""
        read -p "Do you want to disable CloudWatch Logs export? (y/N): " -n 1 -r
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Disabling CloudWatch Logs export..."

            # Convert space-separated to JSON array
            LOG_TYPES_ARRAY=$(echo "$ENABLED_LOGS" | tr ' ' '\n' | jq -R . | jq -s .)

            if [ "$IS_CLUSTER" = true ]; then
                aws rds modify-db-cluster \
                    --profile "$AWS_PROFILE" \
                    --region "$REGION" \
                    --db-cluster-identifier "$RDS_INSTANCE_ID" \
                    --cloudwatch-logs-export-configuration "{\"DisableLogTypes\":$LOG_TYPES_ARRAY}" \
                    --apply-immediately &> /dev/null

                print_success "CloudWatch Logs export disabled for cluster"
            else
                aws rds modify-db-instance \
                    --profile "$AWS_PROFILE" \
                    --region "$REGION" \
                    --db-instance-identifier "$RDS_INSTANCE_ID" \
                    --cloudwatch-logs-export-configuration "{\"DisableLogTypes\":$LOG_TYPES_ARRAY}" \
                    --apply-immediately &> /dev/null

                print_success "CloudWatch Logs export disabled for instance"
            fi

            print_info "Note: Existing log data in CloudWatch Logs remains (not deleted)"
        else
            print_info "CloudWatch Logs will remain enabled on RDS instance"
        fi
    else
        print_info "No CloudWatch Logs enabled on RDS instance"
    fi
}

# Remove CloudWatch Logs subscription filters
remove_subscription_filters() {
    local STACK_NAME=$1
    local REGION=$2

    print_header "Removing CloudWatch Logs Subscription Filters"

    # Get log group name from stack outputs
    LOG_GROUP=$(aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`LogGroupName`].OutputValue' \
        --output text 2>/dev/null || echo "")

    if [ -n "$LOG_GROUP" ]; then
        print_info "Checking subscription filters for log group: $LOG_GROUP"

        # List subscription filters
        FILTERS=$(aws logs describe-subscription-filters \
            --profile "$AWS_PROFILE" \
            --region "$REGION" \
            --log-group-name "$LOG_GROUP" \
            --query 'subscriptionFilters[*].filterName' \
            --output text 2>/dev/null || echo "")

        if [ -n "$FILTERS" ]; then
            for filter in $FILTERS; do
                print_info "Deleting subscription filter: $filter"
                aws logs delete-subscription-filter \
                    --profile "$AWS_PROFILE" \
                    --region "$REGION" \
                    --log-group-name "$LOG_GROUP" \
                    --filter-name "$filter" 2>/dev/null || true
            done
            print_success "Subscription filters removed"
        else
            print_info "No subscription filters found"
        fi
    else
        print_info "No log group found in stack outputs"
    fi
}

# Delete CloudFormation stack
delete_stack() {
    local STACK_NAME=$1
    local REGION=$2

    print_header "Deleting CloudFormation Stack"

    print_info "Stack Name: $STACK_NAME"
    print_info "Region: $REGION"

    aws cloudformation delete-stack \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME"

    print_success "Stack deletion initiated"
    print_info "Waiting for stack deletion to complete (this may take 5-10 minutes)..."

    # Wait for deletion
    if aws cloudformation wait stack-delete-complete \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" 2>/dev/null; then

        print_success "Stack deleted successfully!"
    else
        print_error "Stack deletion failed or timed out"
        print_info "Check AWS Console for details"
        exit 1
    fi
}

# Show summary of what will be deleted
show_summary() {
    local STACK_NAME=$1
    local REGION=$2

    print_header "Cleanup Summary"

    echo -e "${CYAN}Stack:${NC} $STACK_NAME"
    echo -e "${CYAN}Region:${NC} $REGION"
    echo -e "${CYAN}AWS Profile:${NC} $AWS_PROFILE"
    echo ""
    echo -e "${YELLOW}The following resources will be deleted:${NC}"
    echo ""

    # Get RDS instance identifier
    RDS_INSTANCE=$(aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`RDSInstanceIdentifier`].OutputValue' \
        --output text 2>/dev/null || echo "")

    if [ -n "$RDS_INSTANCE" ]; then
        echo -e "${CYAN}RDS Instance:${NC} $RDS_INSTANCE"
        echo ""
    fi

    # Count resources
    RESOURCE_COUNT=$(aws cloudformation describe-stack-resources \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query 'length(StackResources)' \
        --output text)

    echo -e "${CYAN}Total Resources:${NC} $RESOURCE_COUNT"
    echo ""

    # List resource types
    aws cloudformation describe-stack-resources \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query 'StackResources[*].ResourceType' \
        --output text | tr '\t' '\n' | sort | uniq -c
}

# Main cleanup function
main() {
    show_banner

    # Find stacks
    STACKS=$(find_stacks)

    if [ -z "$STACKS" ]; then
        print_info "Nothing to clean up"
        exit 0
    fi

    # Convert to array
    STACK_ARRAY=($STACKS)

    # If multiple stacks, let user choose
    if [ ${#STACK_ARRAY[@]} -gt 1 ]; then
        print_info "Found ${#STACK_ARRAY[@]} stacks:"
        echo ""

        for i in "${!STACK_ARRAY[@]}"; do
            echo "  $((i+1))) ${STACK_ARRAY[$i]}"
        done

        echo ""
        read -p "Select stack to delete (1-${#STACK_ARRAY[@]}) or 'all' to delete all: " choice

        if [ "$choice" == "all" ]; then
            SELECTED_STACKS=("${STACK_ARRAY[@]}")
        else
            SELECTED_STACKS=("${STACK_ARRAY[$((choice-1))]}")
        fi
    else
        SELECTED_STACKS=("${STACK_ARRAY[@]}")
    fi

    # Process each selected stack
    for STACK_NAME in "${SELECTED_STACKS[@]}"; do
        echo ""
        show_summary "$STACK_NAME" "$REGION"
        echo ""
        show_resources "$STACK_NAME" "$REGION"
        echo ""

        print_warning "This action cannot be undone!"
        read -p "Are you sure you want to delete stack '$STACK_NAME'? (yes/no): " confirm

        if [[ $confirm != "yes" ]]; then
            print_info "Skipping $STACK_NAME"
            continue
        fi

        # Remove subscription filters
        remove_subscription_filters "$STACK_NAME" "$REGION"

        # Empty S3 buckets
        empty_s3_buckets "$STACK_NAME" "$REGION"

        # Offer to disable RDS CloudWatch Logs
        offer_disable_rds_logs "$STACK_NAME" "$REGION"

        # Delete stack
        delete_stack "$STACK_NAME" "$REGION"
    done

    print_header "Cleanup Complete!"
    print_success "All selected resources have been deleted"

    # Check for orphaned Lambda log groups
    print_info "Checking for orphaned Lambda log groups..."
    LAMBDA_LOGS=$(aws logs describe-log-groups \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --log-group-name-prefix "/aws/lambda/rds-logs" \
        --query 'logGroups[*].logGroupName' \
        --output text 2>/dev/null || echo "")

    if [ -n "$LAMBDA_LOGS" ]; then
        print_warning "Found orphaned Lambda log groups: $LAMBDA_LOGS"
        print_info "You may want to delete these manually from CloudWatch Logs console"
    fi

    # Note about CloudWatch Logs data
    echo ""
    print_header "Important Notes"
    print_info "CloudWatch Logs data is NOT deleted (it belongs to CloudWatch, not the stack)"
    print_info "To delete CloudWatch Log Groups manually:"
    echo ""
    echo "aws logs delete-log-group --log-group-name /aws/rds/instance/<instance-id>/<log-type>"
}

# Run main function
main
