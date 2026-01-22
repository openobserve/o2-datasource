#!/bin/bash

###############################################################################
# Cleanup script for Cognito Events to OpenObserve monitoring stacks
# This script searches for and deletes all cognito-* CloudFormation stacks
###############################################################################

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
        print_error "AWS credentials are not configured or invalid."
        exit 1
    fi

    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    CURRENT_REGION=$(aws configure get region || echo "us-east-1")
    print_info "AWS Account: $ACCOUNT_ID"
    print_info "Current Region: $CURRENT_REGION"
}

# Function to find cognito-* stacks
find_cognito_stacks() {
    print_info "Searching for cognito-* CloudFormation stacks..."

    # Get all stacks that start with 'cognito-'
    STACKS=$(aws cloudformation list-stacks \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
        --query 'StackSummaries[?starts_with(StackName, `cognito-`)].{Name:StackName,Status:StackStatus,Created:CreationTime}' \
        --output json)

    STACK_COUNT=$(echo "$STACKS" | jq -r 'length')

    if [ "$STACK_COUNT" -eq 0 ]; then
        print_warning "No cognito-* stacks found in region $CURRENT_REGION"
        return 1
    fi

    print_success "Found $STACK_COUNT cognito stack(s):"
    echo ""
    echo "$STACKS" | jq -r '.[] | "\(.Name) - Status: \(.Status) (Created: \(.Created))"' | nl -w2 -s'. '
    echo ""

    # Store stack names in array
    STACK_NAMES=($(echo "$STACKS" | jq -r '.[].Name'))

    return 0
}

# Function to get stack details
get_stack_details() {
    local stack_name=$1

    print_info "Details for stack: $stack_name"

    # Get stack outputs
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
        --output table 2>/dev/null || print_warning "Could not retrieve stack outputs"

    echo ""
}

# Function to empty S3 bucket before deletion
empty_s3_bucket() {
    local stack_name=$1

    print_info "Checking for S3 backup bucket..."

    # Get the backup bucket name from stack outputs
    BUCKET_NAME=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs[?OutputKey==`BackupBucketName`].OutputValue' \
        --output text 2>/dev/null)

    if [ -n "$BUCKET_NAME" ] && [ "$BUCKET_NAME" != "None" ]; then
        print_info "Found backup bucket: $BUCKET_NAME"

        # Check if bucket exists and has objects
        OBJECT_COUNT=$(aws s3 ls s3://"$BUCKET_NAME" --recursive --summarize 2>/dev/null | grep "Total Objects:" | awk '{print $3}' || echo "0")

        if [ "$OBJECT_COUNT" -gt 0 ]; then
            print_warning "Bucket contains $OBJECT_COUNT objects. Emptying bucket..."
            aws s3 rm s3://"$BUCKET_NAME" --recursive
            print_success "Bucket emptied successfully"
        else
            print_info "Bucket is already empty"
        fi
    fi
}

# Function to delete a single stack
delete_stack() {
    local stack_name=$1

    print_info "Deleting stack: $stack_name"

    # Empty S3 bucket first
    empty_s3_bucket "$stack_name"

    # Delete the stack
    aws cloudformation delete-stack --stack-name "$stack_name"

    print_info "Waiting for stack deletion to complete..."
    aws cloudformation wait stack-delete-complete --stack-name "$stack_name" 2>/dev/null || {
        print_error "Failed to delete stack: $stack_name"
        return 1
    }

    print_success "Stack deleted: $stack_name"
    return 0
}

# Function to delete all stacks
delete_all_stacks() {
    local success_count=0
    local fail_count=0

    for stack_name in "${STACK_NAMES[@]}"; do
        echo ""
        if delete_stack "$stack_name"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done

    echo ""
    print_success "Deletion Summary:"
    echo "  Successfully deleted: $success_count"
    if [ $fail_count -gt 0 ]; then
        print_warning "  Failed to delete: $fail_count"
    fi
}

# Function to delete selected stacks
delete_selected_stacks() {
    echo ""
    print_info "Select stacks to delete:"
    echo "  - Enter stack numbers separated by spaces (e.g., 1 3 5)"
    echo "  - Enter 'all' to delete all stacks"
    echo "  - Enter 'q' to quit"
    echo ""

    read -p "Your choice: " CHOICE

    if [ "$CHOICE" = "q" ]; then
        print_info "Cleanup cancelled"
        exit 0
    fi

    if [ "$CHOICE" = "all" ]; then
        print_warning "You are about to delete ALL ${#STACK_NAMES[@]} cognito stack(s)"
        read -p "Are you sure? Type 'yes' to confirm: " CONFIRM

        if [ "$CONFIRM" != "yes" ]; then
            print_info "Cleanup cancelled"
            exit 0
        fi

        delete_all_stacks
    else
        # Parse individual stack selections
        SELECTED_STACKS=()
        for num in $CHOICE; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#STACK_NAMES[@]}" ]; then
                SELECTED_STACKS+=("${STACK_NAMES[$((num-1))]}")
            else
                print_warning "Invalid selection: $num"
            fi
        done

        if [ ${#SELECTED_STACKS[@]} -eq 0 ]; then
            print_error "No valid stacks selected"
            exit 1
        fi

        echo ""
        print_warning "You are about to delete ${#SELECTED_STACKS[@]} stack(s):"
        for stack in "${SELECTED_STACKS[@]}"; do
            echo "  - $stack"
        done
        echo ""

        read -p "Proceed with deletion? (y/n): " CONFIRM

        if [ "$CONFIRM" != "y" ]; then
            print_info "Cleanup cancelled"
            exit 0
        fi

        # Delete selected stacks
        local success_count=0
        local fail_count=0

        for stack_name in "${SELECTED_STACKS[@]}"; do
            echo ""
            if delete_stack "$stack_name"; then
                ((success_count++))
            else
                ((fail_count++))
            fi
        done

        echo ""
        print_success "Deletion Summary:"
        echo "  Successfully deleted: $success_count"
        if [ $fail_count -gt 0 ]; then
            print_warning "  Failed to delete: $fail_count"
        fi
    fi
}

# Function to display stack resources
display_stack_resources() {
    local stack_name=$1

    print_info "Resources in stack: $stack_name"

    aws cloudformation list-stack-resources \
        --stack-name "$stack_name" \
        --query 'StackResourceSummaries[*].[ResourceType,LogicalResourceId,PhysicalResourceId]' \
        --output table

    echo ""
}

# Interactive mode - show details before deletion
interactive_cleanup() {
    while true; do
        echo ""
        print_info "Options:"
        echo "  1. View stack details"
        echo "  2. View stack resources"
        echo "  3. Delete selected stacks"
        echo "  4. Delete all stacks"
        echo "  5. Refresh stack list"
        echo "  q. Quit"
        echo ""

        read -p "Your choice: " OPTION

        case $OPTION in
            1)
                read -p "Enter stack number to view details: " STACK_NUM
                if [[ "$STACK_NUM" =~ ^[0-9]+$ ]] && [ "$STACK_NUM" -ge 1 ] && [ "$STACK_NUM" -le "${#STACK_NAMES[@]}" ]; then
                    get_stack_details "${STACK_NAMES[$((STACK_NUM-1))]}"
                else
                    print_error "Invalid stack number"
                fi
                ;;
            2)
                read -p "Enter stack number to view resources: " STACK_NUM
                if [[ "$STACK_NUM" =~ ^[0-9]+$ ]] && [ "$STACK_NUM" -ge 1 ] && [ "$STACK_NUM" -le "${#STACK_NAMES[@]}" ]; then
                    display_stack_resources "${STACK_NAMES[$((STACK_NUM-1))]}"
                else
                    print_error "Invalid stack number"
                fi
                ;;
            3)
                delete_selected_stacks
                break
                ;;
            4)
                print_warning "You are about to delete ALL ${#STACK_NAMES[@]} cognito stack(s)"
                read -p "Are you sure? Type 'yes' to confirm: " CONFIRM

                if [ "$CONFIRM" = "yes" ]; then
                    delete_all_stacks
                    break
                else
                    print_info "Deletion cancelled"
                fi
                ;;
            5)
                if find_cognito_stacks; then
                    continue
                else
                    break
                fi
                ;;
            q)
                print_info "Exiting cleanup"
                exit 0
                ;;
            *)
                print_error "Invalid option"
                ;;
        esac
    done
}

###############################################################################
# Main execution
###############################################################################

main() {
    echo ""
    print_info "=== Cognito Events to OpenObserve Cleanup ==="
    echo ""

    # Check prerequisites
    check_aws_cli
    check_aws_credentials

    # Find cognito stacks
    if ! find_cognito_stacks; then
        print_info "Nothing to clean up. Exiting."
        exit 0
    fi

    # Check for command line arguments
    if [ "$1" = "--all" ] || [ "$1" = "-a" ]; then
        print_warning "Deleting all cognito-* stacks without confirmation"
        delete_all_stacks
    elif [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --all, -a     Delete all cognito-* stacks without confirmation"
        echo "  --help, -h    Show this help message"
        echo ""
        echo "Without options, runs in interactive mode"
        exit 0
    else
        # Interactive mode
        interactive_cleanup
    fi

    echo ""
    print_success "Cleanup complete!"
}

# Run main function
main "$@"
