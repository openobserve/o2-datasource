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

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

print_info "Kinesis Data Stream to OpenObserve Deployment"
echo "=============================================="
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

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region)
if [ -z "$REGION" ]; then
    REGION="us-east-1"
    print_warning "No default region configured, using us-east-1"
fi

print_info "AWS Account: $ACCOUNT_ID"
print_info "AWS Region: $REGION"
echo ""

# List available Kinesis Data Streams
print_info "Fetching available Kinesis Data Streams..."
STREAMS=$(aws kinesis list-streams --region "$REGION" --query 'StreamNames' --output json 2>/dev/null)

if [ -z "$STREAMS" ] || [ "$STREAMS" == "[]" ]; then
    print_error "No Kinesis Data Streams found in region $REGION"
    echo ""
    print_info "You can create a Kinesis stream with:"
    echo "  aws kinesis create-stream --stream-name my-stream --shard-count 1"
    exit 1
fi

# Parse stream names
STREAM_NAMES=($(echo "$STREAMS" | jq -r '.[]'))
STREAM_COUNT=${#STREAM_NAMES[@]}

echo ""
print_info "Found $STREAM_COUNT Kinesis Data Stream(s):"
echo ""
for i in "${!STREAM_NAMES[@]}"; do
    STREAM_NAME="${STREAM_NAMES[$i]}"

    # Get stream details
    STREAM_ARN=$(aws kinesis describe-stream-summary --stream-name "$STREAM_NAME" --region "$REGION" --query 'StreamDescriptionSummary.StreamARN' --output text)
    SHARD_COUNT=$(aws kinesis describe-stream-summary --stream-name "$STREAM_NAME" --region "$REGION" --query 'StreamDescriptionSummary.OpenShardCount' --output text)

    echo "  [$((i+1))] $STREAM_NAME"
    echo "      ARN: $STREAM_ARN"
    echo "      Open Shards: $SHARD_COUNT"
    echo ""
done

# Select stream
echo ""
read -p "Select stream number (1-$STREAM_COUNT): " STREAM_CHOICE

if ! [[ "$STREAM_CHOICE" =~ ^[0-9]+$ ]] || [ "$STREAM_CHOICE" -lt 1 ] || [ "$STREAM_CHOICE" -gt "$STREAM_COUNT" ]; then
    print_error "Invalid selection"
    exit 1
fi

SELECTED_STREAM="${STREAM_NAMES[$((STREAM_CHOICE-1))]}"
SELECTED_STREAM_ARN=$(aws kinesis describe-stream-summary --stream-name "$SELECTED_STREAM" --region "$REGION" --query 'StreamDescriptionSummary.StreamARN' --output text)

print_success "Selected stream: $SELECTED_STREAM"
echo ""

# Choose deployment option
echo ""
print_info "Deployment Options:"
echo ""
echo "  [1] Firehose Direct (Recommended)"
echo "      - Kinesis Stream → Firehose → OpenObserve"
echo "      - Simple, cost-effective"
echo "      - Optional Lambda transformation"
echo "      - Best for: Standard log forwarding, minimal processing"
echo ""
echo "  [2] Lambda + Firehose (Advanced)"
echo "      - Kinesis Stream → Lambda → Firehose → OpenObserve"
echo "      - Complex transformations and enrichment"
echo "      - Custom business logic"
echo "      - Best for: Complex filtering, aggregation, external lookups"
echo ""

read -p "Select deployment option (1-2): " DEPLOY_OPTION

if ! [[ "$DEPLOY_OPTION" =~ ^[1-2]$ ]]; then
    print_error "Invalid option"
    exit 1
fi

# Get OpenObserve configuration
echo ""
print_info "OpenObserve Configuration"
echo "========================="
echo ""

read -p "OpenObserve endpoint URL (e.g., https://api.openobserve.ai): " OPENOBSERVE_ENDPOINT
if [ -z "$OPENOBSERVE_ENDPOINT" ]; then
    print_error "OpenObserve endpoint is required"
    exit 1
fi

read -p "OpenObserve organization name [default]: " OPENOBSERVE_ORG
OPENOBSERVE_ORG=${OPENOBSERVE_ORG:-default}

read -p "OpenObserve stream name [kinesis_logs]: " OPENOBSERVE_STREAM
OPENOBSERVE_STREAM=${OPENOBSERVE_STREAM:-kinesis_logs}

STREAM_NAME_FULL="${OPENOBSERVE_ORG}/${OPENOBSERVE_STREAM}"

echo ""
print_info "OpenObserve credentials"
read -p "Username: " OPENOBSERVE_USER
read -sp "Password: " OPENOBSERVE_PASS
echo ""

# Encode credentials
OPENOBSERVE_ACCESS_KEY=$(echo -n "${OPENOBSERVE_USER}:${OPENOBSERVE_PASS}" | base64)

# Create stack name
if [ "$DEPLOY_OPTION" == "1" ]; then
    STACK_NAME="kinesis-firehose-${SELECTED_STREAM}"
    TEMPLATE_FILE="$SCRIPT_DIR/kinesis-to-openobserve-firehose.yaml"
else
    STACK_NAME="kinesis-lambda-${SELECTED_STREAM}"
    TEMPLATE_FILE="$SCRIPT_DIR/kinesis-to-openobserve-lambda.yaml"
fi

# Check if stack already exists
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &> /dev/null; then
    print_warning "Stack '$STACK_NAME' already exists"
    read -p "Do you want to update it? (y/n): " UPDATE_CHOICE
    if [[ ! "$UPDATE_CHOICE" =~ ^[Yy]$ ]]; then
        print_info "Deployment cancelled"
        exit 0
    fi
    OPERATION="update"
else
    OPERATION="create"
fi

# Additional parameters based on deployment option
PARAMS="ParameterKey=KinesisStreamArn,ParameterValue=$SELECTED_STREAM_ARN"
PARAMS="$PARAMS ParameterKey=StreamName,ParameterValue=$STREAM_NAME_FULL"
PARAMS="$PARAMS ParameterKey=OpenObserveEndpoint,ParameterValue=$OPENOBSERVE_ENDPOINT"
PARAMS="$PARAMS ParameterKey=OpenObserveAccessKey,ParameterValue=$OPENOBSERVE_ACCESS_KEY"

if [ "$DEPLOY_OPTION" == "1" ]; then
    echo ""
    read -p "Enable Lambda transformation? (y/n) [n]: " ENABLE_TRANSFORM
    if [[ "$ENABLE_TRANSFORM" =~ ^[Yy]$ ]]; then
        PARAMS="$PARAMS ParameterKey=EnableTransformation,ParameterValue=true"
    else
        PARAMS="$PARAMS ParameterKey=EnableTransformation,ParameterValue=false"
    fi

    read -p "Buffer interval in seconds [60]: " BUFFER_INTERVAL
    BUFFER_INTERVAL=${BUFFER_INTERVAL:-60}
    PARAMS="$PARAMS ParameterKey=BufferIntervalSeconds,ParameterValue=$BUFFER_INTERVAL"

    read -p "Buffer size in MB [5]: " BUFFER_SIZE
    BUFFER_SIZE=${BUFFER_SIZE:-5}
    PARAMS="$PARAMS ParameterKey=BufferSizeMB,ParameterValue=$BUFFER_SIZE"
else
    read -p "Lambda batch size (records per invocation) [100]: " BATCH_SIZE
    BATCH_SIZE=${BATCH_SIZE:-100}
    PARAMS="$PARAMS ParameterKey=BatchSize,ParameterValue=$BATCH_SIZE"

    read -p "Parallelization factor (concurrent batches per shard) [1]: " PARALLEL_FACTOR
    PARALLEL_FACTOR=${PARALLEL_FACTOR:-1}
    PARAMS="$PARAMS ParameterKey=ParallelizationFactor,ParameterValue=$PARALLEL_FACTOR"
fi

# Deploy stack
echo ""
print_info "Deploying CloudFormation stack..."
echo ""
print_info "Stack name: $STACK_NAME"
print_info "Template: $(basename $TEMPLATE_FILE)"
print_info "Operation: $OPERATION"
echo ""

if [ "$OPERATION" == "create" ]; then
    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body "file://$TEMPLATE_FILE" \
        --parameters $PARAMS \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION"

    print_info "Stack creation initiated. Waiting for completion..."
    aws cloudformation wait stack-create-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION"
else
    aws cloudformation update-stack \
        --stack-name "$STACK_NAME" \
        --template-body "file://$TEMPLATE_FILE" \
        --parameters $PARAMS \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" 2>&1 | grep -v "No updates are to be performed" || true

    print_info "Stack update initiated. Waiting for completion..."
    aws cloudformation wait stack-update-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION" 2>/dev/null || true
fi

# Get outputs
print_success "Deployment completed successfully!"
echo ""
print_info "Stack Outputs:"
aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
    --output table

echo ""
print_info "Next Steps:"
echo "  1. Send test data to Kinesis: aws kinesis put-record --stream-name $SELECTED_STREAM --partition-key test --data 'Hello OpenObserve'"
echo "  2. Monitor in OpenObserve: $OPENOBSERVE_ENDPOINT"
echo "  3. Check CloudWatch Logs for any issues"
echo "  4. View metrics in CloudWatch console"
echo ""
print_info "To delete this stack, run: ./cleanup.sh"
