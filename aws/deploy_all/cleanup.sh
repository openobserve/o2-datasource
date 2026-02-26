#!/bin/bash

# Cleanup All OpenObserve AWS Integrations
# Deletes the master nested stack and all child stacks.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_header()  { echo -e "\n${CYAN}══════════════════════════════════════════════${NC}\n  $1\n${CYAN}══════════════════════════════════════════════${NC}\n"; }

check_prerequisites() {
    if ! command -v aws &>/dev/null; then
        print_error "AWS CLI is not installed."
        exit 1
    fi
    if ! aws sts get-caller-identity &>/dev/null; then
        print_error "AWS credentials not configured."
        exit 1
    fi
}

# ============================================================
# Find deploy_all stacks
# ============================================================
list_stacks() {
    print_info "Searching for OpenObserve master stacks..."
    echo ""

    stacks=$(aws cloudformation list-stacks \
        --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
        --query "StackSummaries[?!contains(StackName, 'NESTED')].{Name:StackName,Status:StackStatus,Created:CreationTime}" \
        --output json 2>/dev/null)

    if [ "$stacks" = "[]" ] || [ -z "$stacks" ]; then
        print_warning "No active CloudFormation stacks found in region $REGION."
        exit 0
    fi

    echo "Active stacks:"
    echo "──────────────────────────────────────────────────"
    echo "$stacks" | python3 -c "
import json, sys
stacks = json.load(sys.stdin)
for i, s in enumerate(stacks, 1):
    print(f'  {i}) {s[\"Name\"]}  [{s[\"Status\"]}]  (Created: {s[\"Created\"][:10]})')
" 2>/dev/null || echo "$stacks" | grep -o '"Name":"[^"]*"' | sed 's/"Name":"//;s/"//'
    echo "──────────────────────────────────────────────────"
    echo ""

    STACK_LIST=($(echo "$stacks" | python3 -c "
import json, sys
stacks = json.load(sys.stdin)
for s in stacks:
    print(s['Name'])
" 2>/dev/null))
}

select_stack() {
    read -p "Enter the master stack name to delete: " STACK_TO_DELETE

    if [ -z "$STACK_TO_DELETE" ]; then
        print_error "No stack name provided."
        exit 1
    fi

    # Verify stack exists
    if ! aws cloudformation describe-stacks --stack-name "$STACK_TO_DELETE" --region "$REGION" &>/dev/null; then
        print_error "Stack '$STACK_TO_DELETE' not found in region $REGION."
        exit 1
    fi

    print_info "Found stack: $STACK_TO_DELETE"
}

# ============================================================
# List all S3 buckets created by the stack and offer to empty them
# ============================================================
handle_s3_buckets() {
    print_header "S3 Bucket Cleanup"
    print_info "Checking for S3 buckets created by this stack and its nested stacks..."

    # Get all nested stack names
    nested_stacks=$(aws cloudformation list-stack-resources \
        --stack-name "$STACK_TO_DELETE" \
        --region "$REGION" \
        --query "StackResourceSummaries[?ResourceType=='AWS::CloudFormation::Stack'].PhysicalResourceId" \
        --output text 2>/dev/null || echo "")

    all_stacks="$STACK_TO_DELETE $nested_stacks"

    s3_buckets=()
    for stack in $all_stacks; do
        # Extract just the stack name from ARN if needed
        stack_name=$(echo "$stack" | sed 's/.*stack\///' | sed 's/\/.*//')

        buckets=$(aws cloudformation describe-stack-resources \
            --stack-name "$stack_name" \
            --region "$REGION" \
            --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
            --output text 2>/dev/null || echo "")

        for b in $buckets; do
            if [ -n "$b" ] && [ "$b" != "None" ]; then
                s3_buckets+=("$b")
            fi
        done
    done

    if [ ${#s3_buckets[@]} -gt 0 ]; then
        echo ""
        echo "Found S3 buckets (must be emptied before stack deletion):"
        for b in "${s3_buckets[@]}"; do
            echo "  - $b"
        done
        echo ""

        read -p "Empty ALL listed S3 buckets before deletion? (yes/no): " EMPTY_CONFIRM
        if [ "$EMPTY_CONFIRM" = "yes" ]; then
            for b in "${s3_buckets[@]}"; do
                if aws s3 ls "s3://$b" --region "$REGION" &>/dev/null; then
                    print_info "Emptying s3://$b ..."
                    aws s3 rm "s3://$b" --recursive --region "$REGION" 2>/dev/null || true
                    print_success "Emptied: $b"
                else
                    print_warning "Bucket not found or already empty: $b"
                fi
            done
        else
            print_warning "Skipping S3 bucket cleanup. Stack deletion may fail if buckets are non-empty."
        fi
    else
        print_info "No S3 buckets found (or already empty)."
    fi
}

# ============================================================
# Delete the master stack
# ============================================================
delete_stack() {
    print_header "Deleting Master Stack"
    print_warning "Deleting '$STACK_TO_DELETE' will ALSO delete all nested service stacks."
    echo ""
    read -p "Are you sure? Type the stack name to confirm: " DOUBLE_CONFIRM

    if [ "$DOUBLE_CONFIRM" != "$STACK_TO_DELETE" ]; then
        print_warning "Confirmation did not match. Deletion cancelled."
        exit 0
    fi

    print_info "Initiating deletion of stack: $STACK_TO_DELETE"
    aws cloudformation delete-stack \
        --stack-name "$STACK_TO_DELETE" \
        --region "$REGION"

    print_info "Waiting for stack deletion to complete (this may take 10–20 minutes)..."
    if aws cloudformation wait stack-delete-complete \
        --stack-name "$STACK_TO_DELETE" \
        --region "$REGION" 2>/dev/null; then
        print_success "Stack '$STACK_TO_DELETE' and all nested stacks deleted successfully!"
    else
        print_warning "Stack deletion may still be in progress or encountered an error."
        print_info "Check: aws cloudformation describe-stacks --stack-name $STACK_TO_DELETE --region $REGION"
    fi
}

# ============================================================
# Main
# ============================================================
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  OpenObserve — Cleanup All AWS Integrations  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    print_warning "This will delete the master stack AND all nested service stacks."
    echo ""

    check_prerequisites

    # Region
    DEFAULT_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
    if [ -n "$AWS_REGION" ]; then DEFAULT_REGION="$AWS_REGION"; fi
    read -p "AWS Region [$DEFAULT_REGION]: " input_region
    REGION="${input_region:-$DEFAULT_REGION}"

    list_stacks
    select_stack
    handle_s3_buckets
    delete_stack

    echo ""
    print_success "Cleanup complete!"
    print_info "Verify remaining resources in the AWS Console:"
    print_info "  CloudFormation: https://console.aws.amazon.com/cloudformation/home?region=$REGION"
    echo ""
}

main
