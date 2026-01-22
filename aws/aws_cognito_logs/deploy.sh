#!/bin/bash

###############################################################################
# Deploy script for Cognito Events to OpenObserve monitoring
# This script lists available Cognito user pools and deploys a monitoring
# stack for the selected pool (or all pools)
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

# Function to list Cognito user pools
list_user_pools() {
    print_info "Fetching Cognito User Pools in region $CURRENT_REGION..."

    USER_POOLS=$(aws cognito-idp list-user-pools --max-results 60 --output json)

    POOL_COUNT=$(echo "$USER_POOLS" | jq -r '.UserPools | length')

    if [ "$POOL_COUNT" -eq 0 ]; then
        print_warning "No Cognito User Pools found in region $CURRENT_REGION"
        return 1
    fi

    print_success "Found $POOL_COUNT user pool(s):"
    echo ""
    echo "$USER_POOLS" | jq -r '.UserPools[] | "\(.Id) - \(.Name) (Created: \(.CreationDate))"' | nl -w2 -s'. '
    echo ""

    return 0
}

# Function to get user input
get_user_input() {
    echo ""
    print_info "Select a user pool to monitor:"
    echo "  - Enter the number corresponding to the user pool"
    echo "  - Enter '0' to monitor ALL user pools in the region"
    echo "  - Enter 'q' to quit"
    echo ""

    read -p "Your choice: " CHOICE

    if [ "$CHOICE" = "q" ]; then
        print_info "Exiting..."
        exit 0
    fi

    if [ "$CHOICE" = "0" ]; then
        USER_POOL_ID=""
        STACK_NAME="cognito-all-pools"
        print_info "Selected: Monitor ALL user pools"
    else
        USER_POOL_ID=$(echo "$USER_POOLS" | jq -r ".UserPools[$((CHOICE-1))].Id")
        USER_POOL_NAME=$(echo "$USER_POOLS" | jq -r ".UserPools[$((CHOICE-1))].Name")

        if [ "$USER_POOL_ID" = "null" ] || [ -z "$USER_POOL_ID" ]; then
            print_error "Invalid selection"
            exit 1
        fi

        # Create stack name from user pool ID (remove special characters)
        STACK_NAME="cognito-$(echo $USER_POOL_ID | tr '_' '-')"
        print_info "Selected: $USER_POOL_NAME ($USER_POOL_ID)"
    fi
}

# Function to get OpenObserve configuration
get_openobserve_config() {
    echo ""
    print_info "OpenObserve Configuration"
    echo ""

    # Get OpenObserve endpoint
    read -p "Enter OpenObserve endpoint URL (e.g., https://your-instance.com/api/default/cognito_logs/_json): " OPENOBSERVE_ENDPOINT

    if [[ ! "$OPENOBSERVE_ENDPOINT" =~ ^https:// ]]; then
        print_error "Endpoint must start with https://"
        exit 1
    fi

    # Get OpenObserve credentials
    read -p "Enter OpenObserve username: " OPENOBSERVE_USER
    read -s -p "Enter OpenObserve password: " OPENOBSERVE_PASSWORD
    echo ""

    # Base64 encode credentials
    OPENOBSERVE_ACCESS_KEY=$(echo -n "${OPENOBSERVE_USER}:${OPENOBSERVE_PASSWORD}" | base64)

    # Get stream name (with default)
    read -p "Enter Kinesis Firehose stream name [cognito-events-to-openobserve]: " STREAM_NAME
    STREAM_NAME=${STREAM_NAME:-cognito-events-to-openobserve}
}

# Function to validate stack name
validate_stack_name() {
    # Check if stack already exists
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" &> /dev/null; then
        print_warning "Stack '$STACK_NAME' already exists"
        read -p "Do you want to update the existing stack? (y/n): " UPDATE_CHOICE

        if [ "$UPDATE_CHOICE" != "y" ]; then
            print_info "Deployment cancelled"
            exit 0
        fi

        STACK_ACTION="update"
    else
        STACK_ACTION="create"
    fi
}

# Function to deploy CloudFormation stack
deploy_stack() {
    print_info "Deploying CloudFormation stack: $STACK_NAME"

    TEMPLATE_FILE="$(cd "$(dirname "$0")" && pwd)/cognito-events-to-openobserve.yaml"

    if [ ! -f "$TEMPLATE_FILE" ]; then
        print_error "Template file not found: $TEMPLATE_FILE"
        exit 1
    fi

    # Build parameters
    PARAMETERS=(
        "ParameterKey=OpenObserveEndpoint,ParameterValue=$OPENOBSERVE_ENDPOINT"
        "ParameterKey=OpenObserveAccessKey,ParameterValue=$OPENOBSERVE_ACCESS_KEY"
        "ParameterKey=StreamName,ParameterValue=$STREAM_NAME"
    )

    if [ -n "$USER_POOL_ID" ]; then
        PARAMETERS+=("ParameterKey=UserPoolId,ParameterValue=$USER_POOL_ID")
    else
        PARAMETERS+=("ParameterKey=UserPoolId,ParameterValue=")
    fi

    # Deploy or update stack
    if [ "$STACK_ACTION" = "create" ]; then
        print_info "Creating new stack..."
        aws cloudformation create-stack \
            --stack-name "$STACK_NAME" \
            --template-body file://"$TEMPLATE_FILE" \
            --parameters "${PARAMETERS[@]}" \
            --capabilities CAPABILITY_IAM \
            --tags Key=Purpose,Value=CognitoMonitoring Key=ManagedBy,Value=CloudFormation

        print_info "Waiting for stack creation to complete..."
        aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME"
    else
        print_info "Updating existing stack..."
        aws cloudformation update-stack \
            --stack-name "$STACK_NAME" \
            --template-body file://"$TEMPLATE_FILE" \
            --parameters "${PARAMETERS[@]}" \
            --capabilities CAPABILITY_IAM \
            --tags Key=Purpose,Value=CognitoMonitoring Key=ManagedBy,Value=CloudFormation

        print_info "Waiting for stack update to complete..."
        aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME" || {
            # Check if no updates were performed
            if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text | grep -q "UPDATE_COMPLETE"; then
                print_warning "No updates to be performed"
            else
                print_error "Stack update failed"
                exit 1
            fi
        }
    fi

    print_success "Stack deployment completed successfully!"
}

# Function to display stack outputs
display_outputs() {
    echo ""
    print_info "Stack Outputs:"
    echo ""

    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
        --output table

    echo ""
    print_success "Deployment Summary:"
    echo "  Stack Name: $STACK_NAME"
    echo "  Region: $CURRENT_REGION"
    echo "  User Pool: ${USER_POOL_ID:-ALL POOLS}"
    echo "  OpenObserve Endpoint: $OPENOBSERVE_ENDPOINT"
    echo ""
    print_info "Cognito events will now be captured and sent to OpenObserve"
    print_info "Check CloudWatch Logs for Firehose delivery status: /aws/kinesisfirehose/$STREAM_NAME"
}

###############################################################################
# Main execution
###############################################################################

main() {
    echo ""
    print_info "=== Cognito Events to OpenObserve Deployment ==="
    echo ""

    # Check prerequisites
    check_aws_cli
    check_aws_credentials

    # List user pools and get user selection
    if ! list_user_pools; then
        print_error "Cannot proceed without user pools. Exiting."
        exit 1
    fi

    get_user_input
    get_openobserve_config
    validate_stack_name

    # Confirm deployment
    echo ""
    print_warning "Ready to deploy with the following configuration:"
    echo "  Stack Name: $STACK_NAME"
    echo "  User Pool: ${USER_POOL_ID:-ALL POOLS}"
    echo "  OpenObserve Endpoint: $OPENOBSERVE_ENDPOINT"
    echo "  Stream Name: $STREAM_NAME"
    echo ""

    read -p "Proceed with deployment? (y/n): " CONFIRM

    if [ "$CONFIRM" != "y" ]; then
        print_info "Deployment cancelled"
        exit 0
    fi

    # Deploy stack
    deploy_stack
    display_outputs

    echo ""
    print_success "Deployment complete!"
}

# Run main function
main
