#!/bin/bash

#######################################
# EC2 SSM Monitoring Cleanup Script
# Removes SSM-based monitoring deployments
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
AWS_PROFILE="${AWS_PROFILE:-mdmosaraf_o2_dev}"
REGION="${AWS_REGION:-us-east-2}"

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
    echo "   EC2 SSM Monitoring Cleanup"
    echo "================================================"
    echo -e "${NC}"
}

# Find SSM-based monitoring stacks
find_stacks() {
    print_header "Finding SSM Monitoring Stacks" >&2

    STACKS=$(aws cloudformation list-stacks \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
        --query 'StackSummaries[?starts_with(StackName, `ec2-otel-ssm`) || starts_with(StackName, `ec2-cw-ssm`)].StackName' \
        --output text)

    if [ -z "$STACKS" ]; then
        print_warning "No SSM monitoring stacks found in $REGION" >&2

        # Check other regions
        print_info "Checking us-east-1..." >&2
        STACKS=$(aws cloudformation list-stacks \
            --profile "$AWS_PROFILE" \
            --region us-east-1 \
            --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
            --query 'StackSummaries[?starts_with(StackName, `ec2-otel-ssm`) || starts_with(StackName, `ec2-cw-ssm`)].StackName' \
            --output text)

        if [ -z "$STACKS" ]; then
            print_error "No stacks found in us-east-1 or $REGION" >&2
            exit 0
        else
            REGION="us-east-1"
        fi
    fi

    echo "$STACKS"
}

# Show stack details
show_stack_details() {
    local STACK_NAME=$1
    local REGION=$2

    print_header "Stack Details: $STACK_NAME"

    # Get stack outputs
    aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`TargetTag` || OutputKey==`SSMAssociationId`].[OutputKey,OutputValue]' \
        --output table

    echo ""

    # Get SSM association details
    ASSOCIATION_ID=$(aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`SSMAssociationId`].OutputValue' \
        --output text 2>/dev/null || echo "")

    if [ -n "$ASSOCIATION_ID" ]; then
        print_info "SSM Association Status:"
        aws ssm describe-association \
            --profile "$AWS_PROFILE" \
            --region "$REGION" \
            --association-id "$ASSOCIATION_ID" \
            --query '{AssociationId:AssociationId,Name:Name,Status:Overview.Status,AssociationVersion:AssociationVersion}' \
            --output table 2>/dev/null || print_warning "Could not fetch association details"
    fi
}

# Show resources
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

# Show targeted instances
show_targeted_instances() {
    local STACK_NAME=$1
    local REGION=$2

    print_header "Currently Targeted Instances"

    # Get target tag from stack
    TARGET_TAG=$(aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`TargetTag`].OutputValue' \
        --output text 2>/dev/null || echo "")

    if [ -n "$TARGET_TAG" ]; then
        TAG_KEY=$(echo "$TARGET_TAG" | cut -d':' -f1)
        TAG_VALUE=$(echo "$TARGET_TAG" | cut -d':' -f2)

        print_info "Target Tag: ${TAG_KEY}=${TAG_VALUE}"
        echo ""

        # List instances with this tag
        INSTANCES=$(aws ec2 describe-instances \
            --profile "$AWS_PROFILE" \
            --region "$REGION" \
            --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
            --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name,InstanceType]' \
            --output text 2>/dev/null || echo "")

        if [ -n "$INSTANCES" ]; then
            echo "Instances with monitoring agent:"
            echo "$INSTANCES" | awk '{printf "  - %s (%s) - %s [%s]\n", $1, $2, $3, $4}'
            INSTANCE_COUNT=$(echo "$INSTANCES" | wc -l | tr -d ' ')
            echo ""
            print_info "Total: $INSTANCE_COUNT instance(s)"
        else
            print_warning "No instances found with tag ${TAG_KEY}=${TAG_VALUE}"
        fi
    fi
}

# Offer to uninstall agents
offer_agent_uninstall() {
    local STACK_NAME=$1
    local REGION=$2

    echo ""
    print_warning "Note: Deleting the stack removes SSM resources, but agents remain installed on instances"
    echo ""
    read -p "Do you want to uninstall agents from instances before deleting stack? (y/N): " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        uninstall_agents "$STACK_NAME" "$REGION"
    else
        print_info "Agents will remain installed. You can uninstall manually later."
    fi
}

# Uninstall agents from instances
uninstall_agents() {
    local STACK_NAME=$1
    local REGION=$2

    print_header "Uninstalling Agents from Instances"

    # Get target tag
    TARGET_TAG=$(aws cloudformation describe-stacks \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" \
        --query 'Stacks[0].Outputs[?OutputKey==`TargetTag`].OutputValue' \
        --output text)

    TAG_KEY=$(echo "$TARGET_TAG" | cut -d':' -f1)
    TAG_VALUE=$(echo "$TARGET_TAG" | cut -d':' -f2)

    # Get instance IDs
    INSTANCE_IDS=$(aws ec2 describe-instances \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=instance-state-name,Values=running" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text)

    if [ -z "$INSTANCE_IDS" ]; then
        print_warning "No running instances found to uninstall from"
        return
    fi

    print_info "Uninstalling from instances: $INSTANCE_IDS"

    # Determine uninstall command based on stack type
    if [[ "$STACK_NAME" == *"otel"* ]]; then
        UNINSTALL_COMMANDS='#!/bin/bash
sudo systemctl stop otelcol
sudo systemctl disable otelcol
sudo rm -f /etc/systemd/system/otelcol.service
sudo rm -f /usr/local/bin/otelcol
sudo rm -rf /etc/otelcol
sudo systemctl daemon-reload
echo "OpenTelemetry Collector uninstalled"'
    else
        UNINSTALL_COMMANDS='#!/bin/bash
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a stop -m ec2
if command -v rpm &> /dev/null; then
  sudo rpm -e amazon-cloudwatch-agent 2>/dev/null || echo "Already removed"
elif command -v dpkg &> /dev/null; then
  sudo dpkg -r amazon-cloudwatch-agent 2>/dev/null || echo "Already removed"
fi
echo "CloudWatch Agent uninstalled"'
    fi

    # Run uninstall via SSM
    COMMAND_ID=$(aws ssm send-command \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --instance-ids $INSTANCE_IDS \
        --document-name "AWS-RunShellScript" \
        --parameters commands="$UNINSTALL_COMMANDS" \
        --query 'Command.CommandId' \
        --output text)

    print_info "Uninstall command sent: $COMMAND_ID"
    print_info "Waiting for completion..."

    sleep 5
    aws ssm wait command-executed \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --command-id "$COMMAND_ID" \
        --instance-id $(echo $INSTANCE_IDS | awk '{print $1}') 2>/dev/null || true

    print_success "Agents uninstalled from instances"
}

# Delete stack
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
    print_info "Waiting for stack deletion (this may take 2-5 minutes)..."

    if aws cloudformation wait stack-delete-complete \
        --profile "$AWS_PROFILE" \
        --region "$REGION" \
        --stack-name "$STACK_NAME" 2>/dev/null; then

        print_success "Stack deleted successfully!"
    else
        print_error "Stack deletion failed or timed out"
        exit 1
    fi
}

# Show summary
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

# Main
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
        show_stack_details "$STACK_NAME" "$REGION"
        echo ""
        show_targeted_instances "$STACK_NAME" "$REGION"
        echo ""

        print_warning "This action cannot be undone!"
        read -p "Are you sure you want to delete stack '$STACK_NAME'? (yes/no): " confirm

        if [[ $confirm != "yes" ]]; then
            print_info "Skipping $STACK_NAME"
            continue
        fi

        # Offer to uninstall agents
        offer_agent_uninstall "$STACK_NAME" "$REGION"

        # Delete stack
        delete_stack "$STACK_NAME" "$REGION"
    done

    print_header "Cleanup Complete!"
    print_success "All selected SSM monitoring stacks have been deleted"

    echo ""
    print_info "Notes:"
    echo "- SSM Documents and Associations removed"
    echo "- If you chose not to uninstall agents, they remain running on instances"
    echo "- To manually uninstall agents, SSH to instances and run uninstall commands"
    echo ""
    echo "Manual uninstall commands:"
    echo ""
    echo "OpenTelemetry:"
    echo "  sudo systemctl stop otelcol && sudo systemctl disable otelcol"
    echo "  sudo rm /etc/systemd/system/otelcol.service /usr/local/bin/otelcol"
    echo "  sudo rm -rf /etc/otelcol"
    echo ""
    echo "CloudWatch Agent:"
    echo "  sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a stop -m ec2"
    echo "  sudo rpm -e amazon-cloudwatch-agent  # Amazon Linux/RHEL"
    echo "  sudo dpkg -r amazon-cloudwatch-agent  # Ubuntu/Debian"
}

# Run main
main
