#!/bin/bash

# VPC Flow Logs to OpenObserve Cleanup Script
# This script removes CloudFormation stacks and associated VPC Flow Logs

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
    echo ""
}

# Function to check if AWS CLI is installed
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
}

# Function to check AWS credentials
check_aws_credentials() {
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured. Please run 'aws configure' first."
        exit 1
    fi
}

# Function to list VPC Flow Logs stacks
list_vpc_flowlog_stacks() {
    print_info "Searching for VPC Flow Logs CloudFormation stacks..."
    echo ""

    # Search for stacks with vpc-flowlogs prefix
    stacks=$(aws cloudformation list-stacks \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --query "StackSummaries[?starts_with(StackName, 'vpc-flowlogs-')].{Name:StackName,Status:StackStatus,Created:CreationTime}" \
        --output json)

    if [ "$stacks" = "[]" ]; then
        print_warning "No VPC Flow Logs stacks found."
        echo ""
        print_info "Stacks must be named with prefix 'vpc-flowlogs-' to be detected."
        exit 0
    fi

    echo "Found VPC Flow Logs stacks:"
    echo "=========================================="
    echo "$stacks" | jq -r '.[] | "\(.Name) - \(.Status) (Created: \(.Created))"'
    echo "=========================================="
    echo ""

    # Store stack names in array
    STACK_NAMES=($(echo "$stacks" | jq -r '.[].Name'))
}

# Function to get stack details
get_stack_details() {
    stack_name=$1

    print_info "Getting details for stack: $stack_name"

    # Get stack outputs
    outputs=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs' \
        --output json 2>/dev/null)

    if [ -n "$outputs" ] && [ "$outputs" != "null" ]; then
        vpc_id=$(echo "$outputs" | jq -r '.[] | select(.OutputKey=="VpcId") | .OutputValue // empty')
        flowlog_id=$(echo "$outputs" | jq -r '.[] | select(.OutputKey=="FlowLogId") | .OutputValue // empty')
        s3_bucket=$(echo "$outputs" | jq -r '.[] | select(.OutputKey=="BackupS3BucketName") | .OutputValue // empty')
        traffic_type=$(echo "$outputs" | jq -r '.[] | select(.OutputKey=="TrafficType") | .OutputValue // empty')

        echo "  VPC ID: ${vpc_id:-N/A}"
        echo "  Flow Log ID: ${flowlog_id:-N/A}"
        echo "  Traffic Type: ${traffic_type:-N/A}"
        echo "  S3 Bucket: ${s3_bucket:-N/A}"
    fi
    echo ""
}

# Function to empty S3 bucket
empty_s3_bucket() {
    bucket_name=$1

    if [ -z "$bucket_name" ]; then
        return
    fi

    print_info "Checking S3 bucket: $bucket_name"

    # Check if bucket exists
    if aws s3 ls "s3://$bucket_name" &> /dev/null; then
        # Check if bucket has objects
        object_count=$(aws s3 ls "s3://$bucket_name" --recursive --summarize 2>/dev/null | grep "Total Objects:" | awk '{print $3}')

        if [ -n "$object_count" ] && [ "$object_count" -gt 0 ]; then
            print_warning "S3 bucket $bucket_name contains $object_count objects"
            read -p "Do you want to delete all objects in this bucket? (yes/no): " delete_objects

            if [ "$delete_objects" = "yes" ]; then
                print_info "Emptying S3 bucket: $bucket_name"
                aws s3 rm "s3://$bucket_name" --recursive
                print_success "S3 bucket emptied successfully"
            else
                print_warning "S3 bucket not emptied. Stack deletion may fail."
                print_warning "You can manually empty the bucket later: aws s3 rm s3://$bucket_name --recursive"
            fi
        else
            print_info "S3 bucket is already empty"
        fi
    else
        print_info "S3 bucket $bucket_name not found (may have been deleted already)"
    fi
    echo ""
}

# Function to delete stack
delete_stack() {
    stack_name=$1

    print_info "Deleting CloudFormation stack: $stack_name"

    # Get VPC ID from stack outputs
    vpc_id=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' \
        --output text 2>/dev/null)

    # Get Flow Log ID from stack outputs
    flow_log_id=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs[?OutputKey==`FlowLogId`].OutputValue' \
        --output text 2>/dev/null)

    # Offer to delete VPC Flow Log configuration
    if [ -n "$flow_log_id" ] && [ "$flow_log_id" != "None" ]; then
        echo ""
        print_info "VPC Flow Log ID: $flow_log_id (VPC: $vpc_id)"
        read -p "Do you want to delete the VPC Flow Log configuration? (y/N): " -n 1 -r
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Deleting VPC Flow Log: $flow_log_id"
            if aws ec2 delete-flow-logs --flow-log-ids "$flow_log_id" --profile "$AWS_PROFILE" --region "$REGION" &> /dev/null; then
                print_success "VPC Flow Log deleted"
            else
                print_warning "Could not delete VPC Flow Log (may be managed by CloudFormation)"
            fi
        else
            print_info "VPC Flow Log will remain (will be deleted with stack)"
        fi
    fi

    # Get S3 bucket name before deletion
    s3_bucket=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs[?OutputKey==`BackupS3BucketName`].OutputValue' \
        --output text 2>/dev/null)

    # Empty S3 bucket if it exists
    if [ -n "$s3_bucket" ] && [ "$s3_bucket" != "None" ]; then
        empty_s3_bucket "$s3_bucket"
    fi

    # Delete the stack
    if aws cloudformation delete-stack --stack-name "$stack_name" --profile "$AWS_PROFILE" --region "$REGION"; then
        print_info "Stack deletion initiated. Waiting for completion..."

        # Wait for stack deletion
        if aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --profile "$AWS_PROFILE" --region "$REGION" 2>/dev/null; then
            print_success "Stack $stack_name deleted successfully!"
        else
            print_warning "Stack deletion may have failed or is taking longer than expected."
            print_info "Check stack status with: aws cloudformation describe-stacks --stack-name $stack_name"
        fi
    else
        print_error "Failed to delete stack $stack_name"
    fi
    echo ""
}

# Function to check for orphaned VPC flow logs
check_orphaned_flowlogs() {
    echo ""
    print_header "Checking for Orphaned VPC Flow Logs"

    flow_logs=$(aws ec2 describe-flow-logs \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --query 'FlowLogs[?LogDestinationType==`kinesis-data-firehose`].[FlowLogId,ResourceId,TrafficType]' \
        --output text 2>/dev/null || echo "")

    if [ -n "$flow_logs" ]; then
        echo ""
        echo "Found VPC Flow Logs with Firehose destination:"
        echo "$flow_logs" | awk '{printf "  - %s (VPC: %s, Traffic: %s)\n", $1, $2, $3}'
        echo ""
        print_info "These may be orphaned if their stacks were deleted outside this script"
        print_info "You can delete them manually using: aws ec2 delete-flow-logs --flow-log-ids <id>"
    else
        print_info "No orphaned VPC Flow Logs found"
    fi
}

# Function to delete selected stacks
delete_selected_stacks() {
    if [ ${#STACK_NAMES[@]} -eq 0 ]; then
        print_warning "No stacks to delete."
        return
    fi

    echo ""
    echo "Select stacks to delete:"
    echo "1) Delete all stacks"
    echo "2) Delete specific stack"
    echo "3) Cancel"
    echo ""
    read -p "Enter option [1-3]: " option

    case $option in
        1)
            # Delete all stacks
            echo ""
            print_warning "This will delete ALL VPC Flow Logs stacks!"
            read -p "Are you sure? (yes/no): " confirm

            if [ "$confirm" = "yes" ]; then
                for stack in "${STACK_NAMES[@]}"; do
                    get_stack_details "$stack"
                    delete_stack "$stack"
                done
            else
                print_info "Deletion cancelled."
            fi
            ;;
        2)
            # Delete specific stack
            echo ""
            echo "Available stacks:"
            for i in "${!STACK_NAMES[@]}"; do
                echo "$((i+1))) ${STACK_NAMES[$i]}"
            done
            echo ""
            read -p "Enter stack number to delete: " stack_num

            if [ "$stack_num" -ge 1 ] && [ "$stack_num" -le "${#STACK_NAMES[@]}" ]; then
                stack_name="${STACK_NAMES[$((stack_num-1))]}"
                get_stack_details "$stack_name"

                read -p "Delete stack $stack_name? (yes/no): " confirm
                if [ "$confirm" = "yes" ]; then
                    delete_stack "$stack_name"
                else
                    print_info "Deletion cancelled."
                fi
            else
                print_error "Invalid stack number."
            fi
            ;;
        3)
            print_info "Deletion cancelled."
            ;;
        *)
            print_error "Invalid option."
            ;;
    esac
}

# Main execution
main() {
    echo ""
    echo "============================================"
    echo "  VPC Flow Logs to OpenObserve Cleanup     "
    echo "============================================"
    echo ""

    # Check prerequisites
    check_aws_cli
    check_aws_credentials

    # Get current region
    REGION=$(aws configure get region --profile "$AWS_PROFILE" 2>/dev/null || echo "us-east-2")

    # If AWS_REGION env var is set, use it
    if [ -n "$AWS_REGION" ]; then
        REGION="$AWS_REGION"
    fi

    print_info "AWS Region: $REGION"
    echo ""

    # List and delete stacks
    list_vpc_flowlog_stacks
    delete_selected_stacks

    # Check for orphaned flow logs
    check_orphaned_flowlogs

    echo ""
    print_success "Cleanup process completed!"
    echo ""
    print_info "Remember to:"
    print_info "  1. Verify all resources are deleted in AWS Console"
    print_info "  2. Check for any orphaned S3 buckets"
    print_info "  3. Verify VPC Flow Logs are removed from VPCs"
    echo ""
}

# Run main function
main
