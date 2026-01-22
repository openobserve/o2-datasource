#!/bin/bash

#######################################
# EC2 Monitoring via SSM Deployment Script
# Deploys agents to existing EC2 instances using Systems Manager
#######################################

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
OPENOBSERVE_ENDPOINT="${OPENOBSERVE_ENDPOINT:-}"
OPENOBSERVE_ACCESS_KEY="${OPENOBSERVE_ACCESS_KEY:-}"
AWS_PROFILE="${AWS_PROFILE:-mdmosaraf_o2_dev}"
AWS_REGION="${AWS_REGION:-us-east-2}"

# Global variables
DEPLOYMENT_TYPE=""
STACK_NAME=""
TEMPLATE_FILE=""
TAG_KEY="monitoring"
TAG_VALUE="enabled"

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

show_banner() {
    echo -e "${CYAN}"
    echo "================================================"
    echo "  EC2 Monitoring via SSM Deployment"
    echo "================================================"
    echo -e "${NC}"
}

# Select deployment type
select_deployment_type() {
    print_header "Select Monitoring Agent"

    echo -e "${GREEN}1) OpenTelemetry Collector${NC} (Recommended)"
    echo "   • Direct to OpenObserve (no AWS streaming)"
    echo "   • Cost: ~\$3/month (data transfer only)"
    echo "   • Metrics + Logs + Traces"
    echo ""
    echo -e "${GREEN}2) CloudWatch Agent${NC}"
    echo "   • CloudWatch Logs → Stream to OpenObserve"
    echo "   • Cost: ~\$50/month (with streaming)"
    echo "   • AWS-native integration"
    echo ""

    while true; do
        read -p "Choose option (1 or 2): " choice
        case $choice in
            1)
                DEPLOYMENT_TYPE="otel"
                TEMPLATE_FILE="ec2-otel-via-ssm.yaml"
                STACK_NAME="ec2-otel-ssm"
                print_success "Selected: OpenTelemetry Collector"
                break
                ;;
            2)
                DEPLOYMENT_TYPE="cloudwatch"
                TEMPLATE_FILE="ec2-cloudwatch-via-ssm.yaml"
                STACK_NAME="ec2-cw-ssm"
                print_success "Selected: CloudWatch Agent"
                break
                ;;
            *)
                print_error "Invalid option. Please choose 1 or 2."
                ;;
        esac
    done
}

# Check prerequisites
check_aws_cli() {
    print_header "Checking Prerequisites"

    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed"
        exit 1
    fi
    print_success "AWS CLI is installed"
}

# Check credentials
check_credentials() {
    print_info "Checking AWS credentials..."

    if ! aws sts get-caller-identity --profile "$AWS_PROFILE" &> /dev/null; then
        print_error "AWS credentials not configured"
        exit 1
    fi

    ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)
    print_success "AWS credentials configured"
    print_info "Account ID: $ACCOUNT_ID"
    print_info "Region: $AWS_REGION"
}

# Get OpenObserve configuration
get_openobserve_config() {
    print_header "OpenObserve Configuration"

    if [ -z "$OPENOBSERVE_ENDPOINT" ]; then
        read -p "OpenObserve endpoint (e.g., https://api.openobserve.ai/api/org/default/): " OPENOBSERVE_ENDPOINT
    fi
    print_info "Endpoint: $OPENOBSERVE_ENDPOINT"

    if [ -z "$OPENOBSERVE_ACCESS_KEY" ]; then
        read -p "OpenObserve username/email: " OTEL_USER
        read -sp "OpenObserve password: " OTEL_PASS
        echo ""
        OPENOBSERVE_ACCESS_KEY=$(echo -n "${OTEL_USER}:${OTEL_PASS}" | base64)
    fi
    print_success "Credentials configured"
}

# Get tag configuration
get_tag_config() {
    print_header "EC2 Instance Targeting"

    echo "Which instances should be monitored?"
    echo "The deployment will target instances with a specific tag."
    echo ""
    read -p "Tag Key (default: monitoring): " input_key
    TAG_KEY=${input_key:-monitoring}

    read -p "Tag Value (default: enabled): " input_value
    TAG_VALUE=${input_value:-enabled}

    print_info "Will target instances with tag: ${TAG_KEY}=${TAG_VALUE}"

    # List matching instances
    INSTANCES=$(aws ec2 describe-instances \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=instance-state-name,Values=running" \
        --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name]' \
        --output text 2>/dev/null || echo "")

    if [ -n "$INSTANCES" ]; then
        echo ""
        print_success "Found matching instances:"
        echo "$INSTANCES" | awk '{printf "  - %s (%s) - %s\n", $1, $2, $3}'
        INSTANCE_COUNT=$(echo "$INSTANCES" | wc -l | tr -d ' ')
        print_info "Total: $INSTANCE_COUNT instance(s)"
    else
        print_warning "No running instances found with tag ${TAG_KEY}=${TAG_VALUE}"
        echo ""
        echo "To tag an instance:"
        echo "  aws ec2 create-tags --resources i-1234567890abcdef0 --tags Key=${TAG_KEY},Value=${TAG_VALUE}"
        echo ""
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Deployment cancelled"
            exit 1
        fi
    fi
}

# Check SSM prerequisites
check_ssm_readiness() {
    print_header "Checking SSM Readiness"

    # Check for SSM-managed instances
    MANAGED_INSTANCES=$(aws ssm describe-instance-information \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'InstanceInformationList[*].[InstanceId,PingStatus,PlatformName]' \
        --output text 2>/dev/null || echo "")

    if [ -n "$MANAGED_INSTANCES" ]; then
        MANAGED_COUNT=$(echo "$MANAGED_INSTANCES" | wc -l | tr -d ' ')
        print_success "Found $MANAGED_COUNT SSM-managed instance(s)"

        # Show online instances
        ONLINE=$(echo "$MANAGED_INSTANCES" | grep "Online" || echo "")
        if [ -n "$ONLINE" ]; then
            echo ""
            echo "Online instances:"
            echo "$ONLINE" | awk '{printf "  - %s (%s) - %s\n", $1, $2, $3}'
        fi
    else
        print_warning "No SSM-managed instances found"
        echo ""
        echo "Ensure your instances have:"
        echo "1. SSM agent installed (pre-installed on Amazon Linux 2/2023)"
        echo "2. IAM role with AmazonSSMManagedInstanceCore policy"
        echo "3. Network access to SSM endpoints"
        echo ""
    fi
}

# Deploy stack
deploy_stack() {
    print_header "Deploying CloudFormation Stack"

    print_info "Stack Name: $STACK_NAME"
    print_info "Template: $TEMPLATE_FILE"
    print_info "Target Tag: ${TAG_KEY}=${TAG_VALUE}"

    if [ "$DEPLOYMENT_TYPE" == "otel" ]; then
        aws cloudformation create-stack \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --stack-name "$STACK_NAME" \
            --template-body file://"$TEMPLATE_FILE" \
            --parameters \
                ParameterKey=OpenObserveEndpoint,ParameterValue="$OPENOBSERVE_ENDPOINT" \
                ParameterKey=OpenObserveAccessKey,ParameterValue="$OPENOBSERVE_ACCESS_KEY" \
                ParameterKey=StreamNameLogs,ParameterValue="ec2-otel-logs" \
                ParameterKey=StreamNameMetrics,ParameterValue="ec2-otel-metrics" \
                ParameterKey=TargetTagKey,ParameterValue="$TAG_KEY" \
                ParameterKey=TargetTagValue,ParameterValue="$TAG_VALUE" \
                ParameterKey=CollectionInterval,ParameterValue="30" \
            --capabilities CAPABILITY_IAM
    else
        aws cloudformation create-stack \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --stack-name "$STACK_NAME" \
            --template-body file://"$TEMPLATE_FILE" \
            --parameters \
                ParameterKey=TargetTagKey,ParameterValue="$TAG_KEY" \
                ParameterKey=TargetTagValue,ParameterValue="$TAG_VALUE" \
                ParameterKey=LogGroupPrefix,ParameterValue="/aws/ec2/instances" \
            --capabilities CAPABILITY_IAM
    fi

    print_success "Stack creation initiated"

    # Wait for completion
    print_info "Waiting for stack creation..."
    aws cloudformation wait stack-create-complete \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME"

    print_success "Stack created successfully!"
}

# Run SSM association
run_association() {
    print_header "Running SSM Association"

    ASSOCIATION_ID=$(aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`SSMAssociationId`].OutputValue' \
        --output text)

    print_info "Association ID: $ASSOCIATION_ID"
    print_info "Running association now..."

    aws ssm start-associations-once \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --association-ids "$ASSOCIATION_ID"

    print_success "Association triggered"
    print_info "Installation will run on all tagged instances"
}

# Show outputs
show_outputs() {
    print_header "Stack Outputs"

    aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs' \
        --output table
}

# Print next steps
print_next_steps() {
    print_header "Next Steps"

    if [ "$DEPLOYMENT_TYPE" == "otel" ]; then
        echo -e "${GREEN}1. Monitor installation on instances:${NC}"
        echo "   aws ssm list-commands --filters Key=DocumentName,Value=${STACK_NAME}-install-otel"
        echo ""
        echo -e "${GREEN}2. Check logs on instance:${NC}"
        echo "   ssh to instance and run: sudo journalctl -u otelcol -f"
        echo ""
        echo -e "${GREEN}3. View data in OpenObserve:${NC}"
        echo "   - Logs: ec2-otel-logs"
        echo "   - Metrics: ec2-otel-metrics"
    else
        echo -e "${GREEN}1. Monitor installation on instances:${NC}"
        echo "   aws ssm list-commands --filters Key=DocumentName,Value=${STACK_NAME}-install-cw-agent"
        echo ""
        echo -e "${GREEN}2. Verify CloudWatch Logs created:${NC}"
        echo "   aws logs describe-log-groups --log-group-name-prefix /aws/ec2/instances/"
        echo ""
        echo -e "${GREEN}3. Deploy CloudWatch streaming to OpenObserve:${NC}"
        echo "   cd ../aws_cloudwatch_logs && ./deploy.sh"
        echo "   Log Group: /aws/ec2/instances/<instance-id>/system"
    fi

    echo ""
    echo -e "${GREEN}4. Check association execution:${NC}"
    echo "   aws ssm describe-association-executions --association-id <association-id>"
}

# Main
main() {
    show_banner
    select_deployment_type
    check_aws_cli
    check_credentials
    get_openobserve_config
    get_tag_config
    check_ssm_readiness
    deploy_stack
    run_association
    show_outputs
    print_next_steps

    print_header "Deployment Complete!"
    print_success "SSM will install the agent on all tagged instances"
    print_info "Check SSM Command History to monitor installation progress"
}

main
