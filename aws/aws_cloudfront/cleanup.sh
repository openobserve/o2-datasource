#!/bin/bash

#######################################
# CloudFront to OpenObserve Cleanup Script
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
CLOUDFRONT_DISTRIBUTION_ID="E3AA0CQ1QW0NYO"
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
    echo "   CloudFront to OpenObserve Cleanup"
    echo "================================================"
    echo -e "${NC}"
}

# Find all related CloudFormation stacks
find_stacks() {
    print_header "Finding CloudFormation Stacks" >&2

    # Search for both new naming (cf-realtime-*, cf-s3-*) and old naming (cloudfront-*)
    STACKS=$(aws cloudformation list-stacks \
        --profile "$AWS_PROFILE" \
        --region us-east-2 \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
        --query 'StackSummaries[?starts_with(StackName, `cf-realtime-`) || starts_with(StackName, `cf-s3-`) || contains(StackName, `cloudfront-`)].StackName' \
        --output text)

    if [ -z "$STACKS" ]; then
        print_warning "No CloudFormation stacks found in us-east-2" >&2

        # Check other regions
        print_info "Checking us-east-1..." >&2
        STACKS=$(aws cloudformation list-stacks \
            --profile "$AWS_PROFILE" \
            --region us-east-1 \
            --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
            --query 'StackSummaries[?starts_with(StackName, `cf-realtime-`) || starts_with(StackName, `cf-s3-`) || contains(StackName, `cloudfront-`)].StackName' \
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

# Remove CloudFront real-time log config
remove_cloudfront_config() {
    local STACK_NAME=$1
    local REGION=$2

    print_header "Removing CloudFront Configuration"

    # Get real-time log config ARN from stack
    REALTIME_CONFIG_ARN=$(aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`RealtimeLogConfigArn`].OutputValue' \
        --output text 2>/dev/null || echo "")

    if [ -n "$REALTIME_CONFIG_ARN" ]; then
        print_info "Detaching real-time log config from CloudFront distribution..."

        # Get current distribution config
        DIST_CONFIG=$(aws cloudfront get-distribution-config \
            --profile "$AWS_PROFILE" \
            --id "$CLOUDFRONT_DISTRIBUTION_ID" 2>/dev/null || echo "")

        if [ -n "$DIST_CONFIG" ]; then
            ETAG=$(echo "$DIST_CONFIG" | jq -r '.ETag')

            # Remove RealtimeLogConfigArn from default cache behavior
            UPDATED_CONFIG=$(echo "$DIST_CONFIG" | jq 'del(.DistributionConfig.DefaultCacheBehavior.RealtimeLogConfigArn) | .DistributionConfig')

            # Save to temp file
            TEMP_CONFIG=$(mktemp)
            echo "$UPDATED_CONFIG" > "$TEMP_CONFIG"

            # Update distribution
            if aws cloudfront update-distribution \
                --profile "$AWS_PROFILE" \
                --id "$CLOUDFRONT_DISTRIBUTION_ID" \
                --distribution-config "file://$TEMP_CONFIG" \
                --if-match "$ETAG" &> /dev/null; then

                print_success "Real-time log config detached from CloudFront"
            else
                print_warning "Failed to detach real-time log config (may not be attached)"
            fi

            rm -f "$TEMP_CONFIG"
        else
            print_warning "CloudFront distribution not found or not accessible"
        fi
    fi

    # Check for S3 logging
    LOG_BUCKET=$(aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`LogS3BucketName`].OutputValue' \
        --output text 2>/dev/null || echo "")

    if [ -n "$LOG_BUCKET" ]; then
        print_info "Disabling S3 logging on CloudFront distribution..."

        DIST_CONFIG=$(aws cloudfront get-distribution-config \
            --profile "$AWS_PROFILE" \
            --id "$CLOUDFRONT_DISTRIBUTION_ID" 2>/dev/null || echo "")

        if [ -n "$DIST_CONFIG" ]; then
            ETAG=$(echo "$DIST_CONFIG" | jq -r '.ETag')

            # Disable logging
            UPDATED_CONFIG=$(echo "$DIST_CONFIG" | jq '.DistributionConfig.Logging.Enabled = false | .DistributionConfig')

            TEMP_CONFIG=$(mktemp)
            echo "$UPDATED_CONFIG" > "$TEMP_CONFIG"

            if aws cloudfront update-distribution \
                --profile "$AWS_PROFILE" \
                --id "$CLOUDFRONT_DISTRIBUTION_ID" \
                --distribution-config "file://$TEMP_CONFIG" \
                --if-match "$ETAG" &> /dev/null; then

                print_success "S3 logging disabled on CloudFront"
            else
                print_warning "Failed to disable S3 logging"
            fi

            rm -f "$TEMP_CONFIG"
        fi
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

        # Remove CloudFront configuration
        remove_cloudfront_config "$STACK_NAME" "$REGION"

        # Empty S3 buckets
        empty_s3_buckets "$STACK_NAME" "$REGION"

        # Delete stack
        delete_stack "$STACK_NAME" "$REGION"
    done

    print_header "Cleanup Complete!"
    print_success "All selected resources have been deleted"

    # Check for orphaned real-time log configs
    print_info "Checking for orphaned real-time log configs..."
    ORPHANED_CONFIGS=$(aws cloudfront list-realtime-log-configs \
        --profile "$AWS_PROFILE" \
        --query 'RealtimeLogConfigs.Items[?contains(Name, `cloudfront`)].Name' \
        --output text 2>/dev/null || echo "")

    if [ -n "$ORPHANED_CONFIGS" ]; then
        print_warning "Found orphaned real-time log configs: $ORPHANED_CONFIGS"
        print_info "You may want to delete these manually from CloudFront console"
    fi
}

# Run main function
main
