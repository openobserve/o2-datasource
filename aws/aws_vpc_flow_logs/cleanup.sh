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
    if aws cloudformation delete-stack --stack-name "$stack_name"; then
        print_info "Stack deletion initiated. Waiting for completion..."

        # Wait for stack deletion
        if aws cloudformation wait stack-delete-complete --stack-name "$stack_name" 2>/dev/null; then
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

# Function to delete specific VPC flow logs
delete_vpc_flowlogs() {
    echo ""
    print_info "You can also manually delete VPC Flow Logs if needed."
    read -p "Do you want to search for and delete VPC Flow Logs? (yes/no): " delete_flowlogs

    if [ "$delete_flowlogs" != "yes" ]; then
        return
    fi

    echo ""
    print_info "Searching for VPC Flow Logs..."

    flow_logs=$(aws ec2 describe-flow-logs \
        --query 'FlowLogs[*].[FlowLogId,ResourceId,TrafficType,LogDestinationType,LogDestination]' \
        --output text)

    if [ -z "$flow_logs" ]; then
        print_info "No VPC Flow Logs found."
        return
    fi

    echo ""
    echo "Found VPC Flow Logs:"
    echo "=========================================="
    echo "$flow_logs"
    echo "=========================================="
    echo ""

    read -p "Enter Flow Log ID to delete (or 'skip' to continue): " flowlog_id

    if [ "$flowlog_id" != "skip" ] && [ -n "$flowlog_id" ]; then
        print_info "Deleting Flow Log: $flowlog_id"
        if aws ec2 delete-flow-logs --flow-log-ids "$flowlog_id"; then
            print_success "Flow Log deleted successfully!"
        else
            print_error "Failed to delete Flow Log"
        fi
    fi
    echo ""
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
    REGION=$(aws configure get region)
    print_info "AWS Region: $REGION"
    echo ""

    # List and delete stacks
    list_vpc_flowlog_stacks
    delete_selected_stacks

    # Option to delete orphaned flow logs
    delete_vpc_flowlogs

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
