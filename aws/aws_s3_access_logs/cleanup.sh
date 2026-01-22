#!/bin/bash

#######################################
# S3 Access Logs to OpenObserve Cleanup Script
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
REGION="us-east-2"  # Default region

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
    echo "   S3 Access Logs to OpenObserve Cleanup"
    echo "================================================"
    echo -e "${NC}"
}

# Find all related CloudFormation stacks
find_stacks() {
    print_header "Finding CloudFormation Stacks" >&2

    # Search for s3-access-logs-* stacks
    STACKS=$(aws cloudformation list-stacks \
        --profile "$AWS_PROFILE" \
        --region us-east-2 \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
        --query 'StackSummaries[?starts_with(StackName, `s3-access-logs-`)].StackName' \
        --output text)

    if [ -z "$STACKS" ]; then
        print_warning "No CloudFormation stacks found in us-east-2" >&2

        # Check other regions
        print_info "Checking us-east-1..." >&2
        STACKS=$(aws cloudformation list-stacks \
            --profile "$AWS_PROFILE" \
            --region us-east-1 \
            --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
            --query 'StackSummaries[?starts_with(StackName, `s3-access-logs-`)].StackName' \
            --output text)

        if [ -z "$STACKS" ]; then
            print_error "No stacks found in us-east-1 or us-east-2" >&2
            exit 0
        else
            REGION="us-east-1"
        fi
    else
        REGION="us-east-2"
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

# Get source bucket name from stack
get_source_bucket() {
    local STACK_NAME=$1
    local REGION=$2

    aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Parameters[?ParameterKey==`SourceBucketName`].ParameterValue' \
        --output text 2>/dev/null || echo ""
}

# Disable S3 access logging on source bucket
disable_s3_access_logging() {
    local STACK_NAME=$1
    local REGION=$2

    print_header "Disabling S3 Access Logging"

    SOURCE_BUCKET=$(get_source_bucket "$STACK_NAME" "$REGION")

    if [ -z "$SOURCE_BUCKET" ]; then
        print_warning "Could not determine source bucket from stack"
        return
    fi

    print_info "Source bucket: $SOURCE_BUCKET"

    # Ask if user wants to disable access logging
    read -p "Disable S3 access logging on source bucket '$SOURCE_BUCKET'? (y/N): " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Disabling S3 access logging..."

        if aws s3api put-bucket-logging \
            --profile "$AWS_PROFILE" \
            --bucket "$SOURCE_BUCKET" \
            --bucket-logging-status {} 2>/dev/null; then

            print_success "S3 access logging disabled on: $SOURCE_BUCKET"
        else
            print_warning "Failed to disable access logging (bucket may not exist or no permissions)"
        fi
    else
        print_info "Skipping - access logging will remain enabled on source bucket"
    fi
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

    SOURCE_BUCKET=$(get_source_bucket "$STACK_NAME" "$REGION")

    echo -e "${CYAN}Stack:${NC} $STACK_NAME"
    echo -e "${CYAN}Region:${NC} $REGION"
    echo -e "${CYAN}AWS Profile:${NC} $AWS_PROFILE"
    if [ -n "$SOURCE_BUCKET" ]; then
        echo -e "${CYAN}Source Bucket:${NC} $SOURCE_BUCKET"
    fi
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

        # Disable S3 access logging (optional)
        disable_s3_access_logging "$STACK_NAME" "$REGION"

        # Empty S3 buckets
        empty_s3_buckets "$STACK_NAME" "$REGION"

        # Delete stack
        delete_stack "$STACK_NAME" "$REGION"
    done

    print_header "Cleanup Complete!"
    print_success "All selected resources have been deleted"
}

# Run main function
main
