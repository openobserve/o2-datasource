#!/bin/bash

#######################################
# DynamoDB Streams to OpenObserve Cleanup Script
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
    echo "   DynamoDB Streams to OpenObserve Cleanup"
    echo "================================================"
    echo -e "${NC}"
}

# Find all related CloudFormation stacks
find_stacks() {
    print_header "Finding CloudFormation Stacks" >&2

    # Search for DynamoDB stacks (ddb-kinesis-*, ddb-lambda-*)
    STACKS=$(aws cloudformation list-stacks \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
        --query 'StackSummaries[?starts_with(StackName, `ddb-kinesis-`) || starts_with(StackName, `ddb-lambda-`)].StackName' \
        --output text)

    if [ -z "$STACKS" ]; then
        print_warning "No CloudFormation stacks found in $REGION" >&2

        # Check other common regions
        print_info "Checking us-east-1..." >&2
        STACKS=$(aws cloudformation list-stacks \
            --profile "$AWS_PROFILE" \
            --region us-east-1 \
            --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
            --query 'StackSummaries[?starts_with(StackName, `ddb-kinesis-`) || starts_with(StackName, `ddb-lambda-`)].StackName' \
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

# Remove DynamoDB Kinesis Streaming Destination
remove_dynamodb_kinesis_destination() {
    local STACK_NAME=$1
    local REGION=$2

    print_header "Removing DynamoDB Kinesis Streaming Destination"

    # Get table name from stack outputs
    TABLE_NAME=$(aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`DynamoDBTableName`].OutputValue' \
        --output text 2>/dev/null || echo "")

    if [ -n "$TABLE_NAME" ]; then
        # Get Kinesis stream ARN from stack
        KINESIS_ARN=$(aws cloudformation describe-stack-resources \
            --profile "$AWS_PROFILE" \
            --region "$REGION" \
            --stack-name "$STACK_NAME" \
            --query 'StackResources[?ResourceType==`AWS::Kinesis::Stream`].PhysicalResourceId' \
            --output text 2>/dev/null || echo "")

        if [ -n "$KINESIS_ARN" ]; then
            print_info "Disabling Kinesis streaming destination for table: $TABLE_NAME"

            # Try to remove Kinesis streaming destination
            aws dynamodb disable-kinesis-streaming-destination \
                --table-name "$TABLE_NAME" \
                --stream-arn "$KINESIS_ARN" \
                --profile "$AWS_PROFILE" \
                --region "$REGION" 2>/dev/null || print_info "No Kinesis destination to remove"

            print_success "Kinesis destination removed"
        fi
    else
        print_info "No table name found in stack outputs"
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

        # Remove Kinesis destination if Kinesis-based deployment
        if [[ $STACK_NAME == *"kinesis"* ]]; then
            remove_dynamodb_kinesis_destination "$STACK_NAME" "$REGION"
        fi

        # Empty S3 buckets
        empty_s3_buckets "$STACK_NAME" "$REGION"

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
        --log-group-name-prefix "/aws/lambda/ddb-" \
        --query 'logGroups[*].logGroupName' \
        --output text 2>/dev/null || echo "")

    if [ -n "$LAMBDA_LOGS" ]; then
        print_warning "Found orphaned Lambda log groups: $LAMBDA_LOGS"
        print_info "You may want to delete these manually from CloudWatch Logs console"
    fi
}

# Run main function
main
