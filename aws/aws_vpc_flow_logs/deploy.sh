#!/bin/bash

# VPC Flow Logs to OpenObserve Deployment Script
# This script deploys CloudFormation stacks to stream VPC Flow Logs to OpenObserve

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

# Function to list VPCs
list_vpcs() {
    print_info "Fetching available VPCs..."
    echo ""

    vpcs=$(aws ec2 describe-vpcs \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --query 'Vpcs[*].[VpcId,Tags[?Key==`Name`].Value|[0],CidrBlock,IsDefault]' \
        --output text)

    if [ -z "$vpcs" ]; then
        print_error "No VPCs found in region $REGION."
        exit 1
    fi

    echo "Available VPCs:"
    echo "----------------------------------------"
    echo "$vpcs" | while IFS=$'\t' read -r vpc_id name cidr is_default; do
        default_marker=""
        if [ "$is_default" = "True" ]; then
            default_marker=" (Default VPC)"
        fi
        name_display="${name:-<No Name>}"
        echo "VPC ID: $vpc_id | Name: $name_display | CIDR: $cidr$default_marker"
    done
    echo "----------------------------------------"
    echo ""
}

# Function to prompt for deployment option
select_deployment_option() {
    echo ""
    print_info "Select deployment option:"
    echo "1) Direct Firehose (Recommended - VPC Flow Logs -> Firehose -> OpenObserve)"
    echo "2) CloudWatch Logs (Alternative - VPC Flow Logs -> CloudWatch -> Kinesis -> Firehose -> OpenObserve)"
    echo ""
    read -p "Enter option [1-2]: " option

    case $option in
        1)
            DEPLOYMENT_TYPE="firehose"
            TEMPLATE_FILE="vpc-flowlogs-to-openobserve-firehose.yaml"
            STACK_PREFIX="vpc-flowlogs-firehose"
            ;;
        2)
            DEPLOYMENT_TYPE="cloudwatch"
            TEMPLATE_FILE="vpc-flowlogs-to-openobserve-cloudwatch.yaml"
            STACK_PREFIX="vpc-flowlogs-cw"
            ;;
        *)
            print_error "Invalid option selected."
            exit 1
            ;;
    esac

    print_success "Selected: $DEPLOYMENT_TYPE deployment"
}

# Function to get VPC ID
get_vpc_id() {
    echo ""
    read -p "Enter VPC ID: " vpc_id

    # Validate VPC exists
    if ! aws ec2 describe-vpcs --vpc-ids "$vpc_id" &> /dev/null; then
        print_error "VPC $vpc_id not found or not accessible."
        exit 1
    fi

    VPC_ID="$vpc_id"
    print_success "VPC ID: $VPC_ID"
}

# Function to select traffic type
select_traffic_type() {
    echo ""
    print_info "Select traffic type to log:"
    echo "1) ALL - Log all traffic (accepted and rejected)"
    echo "2) ACCEPT - Log only accepted traffic"
    echo "3) REJECT - Log only rejected traffic"
    echo ""
    read -p "Enter option [1-3]: " traffic_option

    case $traffic_option in
        1) TRAFFIC_TYPE="ALL" ;;
        2) TRAFFIC_TYPE="ACCEPT" ;;
        3) TRAFFIC_TYPE="REJECT" ;;
        *)
            print_error "Invalid option selected."
            exit 1
            ;;
    esac

    print_success "Traffic type: $TRAFFIC_TYPE"
}

# Function to get OpenObserve details
get_openobserve_details() {
    echo ""
    print_info "Enter OpenObserve configuration details:"
    echo ""

    read -p "OpenObserve endpoint URL (e.g., https://api.openobserve.ai/api/your-org/default/_kinesis): " oo_endpoint
    read -p "OpenObserve access key (base64 encoded user:password): " oo_access_key
    read -p "Stream name (default: vpc-flow-logs-stream): " stream_name

    OPENOBSERVE_ENDPOINT="$oo_endpoint"
    OPENOBSERVE_ACCESS_KEY="$oo_access_key"
    STREAM_NAME="${stream_name:-vpc-flow-logs-stream}"

    print_success "OpenObserve configuration captured"
}

# Function to get S3 bucket name
get_s3_bucket() {
    echo ""
    # REGION is already set in main()
    ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)
    DEFAULT_BUCKET="vpc-flowlogs-backup-${ACCOUNT_ID}-${REGION}"

    read -p "S3 bucket name for failed records (default: $DEFAULT_BUCKET): " s3_bucket
    BACKUP_S3_BUCKET="${s3_bucket:-$DEFAULT_BUCKET}"

    print_success "S3 bucket: $BACKUP_S3_BUCKET"
}

# Function to get CloudWatch-specific parameters
get_cloudwatch_params() {
    if [ "$DEPLOYMENT_TYPE" = "cloudwatch" ]; then
        echo ""
        read -p "Kinesis shard count (default: 1): " shard_count
        read -p "CloudWatch Logs retention in days (default: 7): " retention_days

        SHARD_COUNT="${shard_count:-1}"
        RETENTION_DAYS="${retention_days:-7}"
    fi
}

# Function to deploy CloudFormation stack
deploy_stack() {
    # Extract VPC ID suffix for stack name
    VPC_SUFFIX=$(echo "$VPC_ID" | sed 's/vpc-//')
    STACK_NAME="${STACK_PREFIX}-${VPC_SUFFIX}"

    print_info "Deploying CloudFormation stack: $STACK_NAME"
    echo ""

    # Build parameters (format for 'cloudformation deploy')
    PARAMS="OpenObserveEndpoint=$OPENOBSERVE_ENDPOINT"
    PARAMS="$PARAMS OpenObserveAccessKey=$OPENOBSERVE_ACCESS_KEY"
    PARAMS="$PARAMS StreamName=$STREAM_NAME"
    PARAMS="$PARAMS VpcId=$VPC_ID"
    PARAMS="$PARAMS TrafficType=$TRAFFIC_TYPE"
    PARAMS="$PARAMS BackupS3BucketName=$BACKUP_S3_BUCKET"

    if [ "$DEPLOYMENT_TYPE" = "cloudwatch" ]; then
        PARAMS="$PARAMS ShardCount=$SHARD_COUNT"
        PARAMS="$PARAMS CloudWatchLogGroupRetention=$RETENTION_DAYS"
    fi

    # Get script directory
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

    # Deploy stack
    if aws cloudformation deploy \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --template-file "$SCRIPT_DIR/$TEMPLATE_FILE" \
        --stack-name "$STACK_NAME" \
        --parameter-overrides $PARAMS \
        --capabilities CAPABILITY_IAM \
        --no-fail-on-empty-changeset; then

        print_success "Stack deployment completed successfully!"
        echo ""

        # Get outputs
        print_info "Stack outputs:"
        aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
            --output table

        echo ""
        print_success "VPC Flow Logs are now streaming to OpenObserve!"
        print_info "Monitor your logs in OpenObserve dashboard using stream name: $STREAM_NAME"

    else
        print_error "Stack deployment failed!"
        exit 1
    fi
}

# Main execution
main() {
    echo ""
    echo "=========================================="
    echo "  VPC Flow Logs to OpenObserve Deployer  "
    echo "=========================================="
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

    # List available VPCs
    list_vpcs

    # Get deployment parameters
    select_deployment_option
    get_vpc_id
    select_traffic_type
    get_openobserve_details
    get_s3_bucket
    get_cloudwatch_params

    # Confirm deployment
    echo ""
    echo "=========================================="
    echo "Deployment Summary:"
    echo "=========================================="
    echo "Deployment Type: $DEPLOYMENT_TYPE"
    echo "Stack Name: ${STACK_PREFIX}-$(echo "$VPC_ID" | sed 's/vpc-//')"
    echo "VPC ID: $VPC_ID"
    echo "Traffic Type: $TRAFFIC_TYPE"
    echo "OpenObserve Endpoint: $OPENOBSERVE_ENDPOINT"
    echo "Stream Name: $STREAM_NAME"
    echo "S3 Backup Bucket: $BACKUP_S3_BUCKET"
    if [ "$DEPLOYMENT_TYPE" = "cloudwatch" ]; then
        echo "Kinesis Shards: $SHARD_COUNT"
        echo "CloudWatch Retention: $RETENTION_DAYS days"
    fi
    echo "=========================================="
    echo ""

    read -p "Do you want to proceed with deployment? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        print_warning "Deployment cancelled."
        exit 0
    fi

    # Deploy the stack
    deploy_stack
}

# Run main function
main
