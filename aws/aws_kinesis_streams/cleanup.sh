#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
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

print_info "Kinesis to OpenObserve Stack Cleanup"
echo "====================================="
echo ""

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is not installed. Please install it first."
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured. Please run 'aws configure'."
    exit 1
fi

REGION=$(aws configure get region)
if [ -z "$REGION" ]; then
    REGION="us-east-1"
    print_warning "No default region configured, using us-east-1"
fi

print_info "AWS Region: $REGION"
echo ""

# Find all relevant stacks
print_info "Searching for Kinesis to OpenObserve stacks..."
echo ""

FIREHOSE_STACKS=$(aws cloudformation list-stacks \
    --region "$REGION" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
    --query "StackSummaries[?starts_with(StackName, 'kinesis-firehose-')].StackName" \
    --output text)

LAMBDA_STACKS=$(aws cloudformation list-stacks \
    --region "$REGION" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
    --query "StackSummaries[?starts_with(StackName, 'kinesis-lambda-')].StackName" \
    --output text)

ALL_STACKS="$FIREHOSE_STACKS $LAMBDA_STACKS"

if [ -z "$ALL_STACKS" ] || [ "$ALL_STACKS" == " " ]; then
    print_warning "No Kinesis to OpenObserve stacks found"
    exit 0
fi

# Convert to array
STACK_ARRAY=($ALL_STACKS)
STACK_COUNT=${#STACK_ARRAY[@]}

print_info "Found $STACK_COUNT stack(s):"
echo ""

for i in "${!STACK_ARRAY[@]}"; do
    STACK_NAME="${STACK_ARRAY[$i]}"

    # Get stack details
    STACK_INFO=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].[StackStatus,CreationTime]' \
        --output text)

    STATUS=$(echo "$STACK_INFO" | awk '{print $1}')
    CREATED=$(echo "$STACK_INFO" | awk '{print $2}')

    # Get Kinesis stream source
    KINESIS_ARN=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Parameters[?ParameterKey=='KinesisStreamArn'].ParameterValue" \
        --output text 2>/dev/null || echo "N/A")

    STREAM_NAME=$(echo "$KINESIS_ARN" | awk -F'/' '{print $NF}')

    echo "  [$((i+1))] $STACK_NAME"
    echo "      Status: $STATUS"
    echo "      Created: $CREATED"
    echo "      Source Stream: $STREAM_NAME"
    echo ""
done

# Selection options
echo ""
print_info "Cleanup Options:"
echo "  [A] Delete ALL stacks"
echo "  [S] Select specific stack(s)"
echo "  [C] Cancel"
echo ""

read -p "Choose option (A/S/C): " CLEANUP_OPTION

case "$CLEANUP_OPTION" in
    [Aa])
        STACKS_TO_DELETE=("${STACK_ARRAY[@]}")
        ;;
    [Ss])
        read -p "Enter stack number(s) separated by space (e.g., 1 3 5): " SELECTIONS
        STACKS_TO_DELETE=()
        for SELECTION in $SELECTIONS; do
            if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "$STACK_COUNT" ]; then
                STACKS_TO_DELETE+=("${STACK_ARRAY[$((SELECTION-1))]}")
            else
                print_warning "Skipping invalid selection: $SELECTION"
            fi
        done
        ;;
    [Cc])
        print_info "Cleanup cancelled"
        exit 0
        ;;
    *)
        print_error "Invalid option"
        exit 1
        ;;
esac

if [ ${#STACKS_TO_DELETE[@]} -eq 0 ]; then
    print_warning "No stacks selected for deletion"
    exit 0
fi

# Confirm deletion
echo ""
print_warning "The following stacks will be DELETED:"
for STACK in "${STACKS_TO_DELETE[@]}"; do
    echo "  - $STACK"
done
echo ""
print_warning "This will delete:"
echo "  - Firehose delivery streams"
echo "  - Lambda functions (if any)"
echo "  - Event source mappings"
echo "  - S3 backup buckets (and their contents)"
echo "  - IAM roles and policies"
echo "  - CloudWatch log groups and alarms"
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    print_info "Cleanup cancelled"
    exit 0
fi

# Delete stacks
echo ""
print_info "Starting cleanup process..."

for STACK_NAME in "${STACKS_TO_DELETE[@]}"; do
    echo ""
    print_info "Processing stack: $STACK_NAME"

    # Check if it's a Lambda-based stack
    if [[ "$STACK_NAME" == kinesis-lambda-* ]]; then
        # Disable event source mapping first
        print_info "Looking for event source mappings..."

        EVENT_SOURCE_MAPPING=$(aws cloudformation describe-stack-resources \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query "StackResources[?ResourceType=='AWS::Lambda::EventSourceMapping'].PhysicalResourceId" \
            --output text 2>/dev/null || echo "")

        if [ -n "$EVENT_SOURCE_MAPPING" ] && [ "$EVENT_SOURCE_MAPPING" != "None" ]; then
            print_info "Disabling event source mapping: $EVENT_SOURCE_MAPPING"
            aws lambda update-event-source-mapping \
                --uuid "$EVENT_SOURCE_MAPPING" \
                --region "$REGION" \
                --no-enabled &> /dev/null || true
            print_success "Event source mapping disabled"
        fi
    fi

    # Empty S3 backup bucket before deletion
    BACKUP_BUCKET=$(aws cloudformation describe-stack-resources \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
        --output text 2>/dev/null || echo "")

    if [ -n "$BACKUP_BUCKET" ] && [ "$BACKUP_BUCKET" != "None" ]; then
        print_info "Emptying S3 backup bucket: $BACKUP_BUCKET"

        # Delete all objects
        aws s3 rm "s3://$BACKUP_BUCKET" --recursive --region "$REGION" &> /dev/null || true

        # Delete all versions if versioning is enabled
        aws s3api delete-objects \
            --bucket "$BACKUP_BUCKET" \
            --delete "$(aws s3api list-object-versions \
                --bucket "$BACKUP_BUCKET" \
                --region "$REGION" \
                --output=json \
                --query='{Objects: Versions[].{Key:Key,VersionId:VersionId}}')" \
            --region "$REGION" &> /dev/null || true

        print_success "S3 bucket emptied"
    fi

    # Delete the stack
    print_info "Deleting stack..."
    aws cloudformation delete-stack \
        --stack-name "$STACK_NAME" \
        --region "$REGION"

    print_info "Waiting for stack deletion to complete..."
    aws cloudformation wait stack-delete-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION" 2>&1 || {
        print_warning "Stack deletion may have failed or timed out. Check AWS Console for details."
        continue
    }

    print_success "Stack deleted: $STACK_NAME"
done

echo ""
print_success "Cleanup completed!"
echo ""
print_info "Summary:"
echo "  - Deleted ${#STACKS_TO_DELETE[@]} stack(s)"
echo "  - Removed event source mappings"
echo "  - Emptied and deleted S3 backup buckets"
echo "  - Deleted Lambda functions, Firehose streams, and IAM roles"
echo ""
print_info "Note: The source Kinesis Data Streams were NOT deleted."
