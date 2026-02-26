#!/bin/bash

# Deploy All OpenObserve AWS Integrations
# This script uploads all CloudFormation templates to S3 and deploys the master nested stack.

set -e

# Color codes
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
print_step()    { echo -e "${CYAN}▶${NC} $1"; }

# Script directory (aws/deploy_all/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Parent directory (aws/)
AWS_DIR="$(dirname "$SCRIPT_DIR")"

# ============================================================
# Prerequisites
# ============================================================
check_prerequisites() {
    if ! command -v aws &>/dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    if ! aws sts get-caller-identity &>/dev/null; then
        print_error "AWS credentials not configured. Please run 'aws configure' or set env vars."
        exit 1
    fi
}

# ============================================================
# Collect common configuration
# ============================================================
collect_common_config() {
    print_header "Step 1: Common Configuration"

    # AWS Region
    DEFAULT_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
    if [ -n "$AWS_REGION" ]; then DEFAULT_REGION="$AWS_REGION"; fi
    read -p "AWS Region [$DEFAULT_REGION]: " input_region
    REGION="${input_region:-$DEFAULT_REGION}"
    print_info "Region: $REGION"

    # Stack name
    read -p "Master stack name [openobserve-all-aws-sources]: " input_stack
    STACK_NAME="${input_stack:-openobserve-all-aws-sources}"

    # S3 bucket for templates
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    DEFAULT_BUCKET="o2-cfn-templates-${ACCOUNT_ID}-${REGION}"
    read -p "S3 bucket for templates [$DEFAULT_BUCKET]: " input_bucket
    TEMPLATE_BUCKET="${input_bucket:-$DEFAULT_BUCKET}"

    # S3 prefix
    read -p "S3 key prefix [aws-cfn-templates]: " input_prefix
    TEMPLATE_PREFIX="${input_prefix:-aws-cfn-templates}"

    echo ""
    # OpenObserve endpoint
    read -p "OpenObserve endpoint URL (e.g., https://api.openobserve.ai/api/org/default/_kinesis): " OO_ENDPOINT
    if [ -z "$OO_ENDPOINT" ]; then
        print_error "OpenObserve endpoint is required."
        exit 1
    fi

    read -p "OpenObserve access key (base64 encoded user:password): " OO_ACCESS_KEY
    if [ -z "$OO_ACCESS_KEY" ]; then
        print_error "OpenObserve access key is required."
        exit 1
    fi
}

# ============================================================
# Upload templates to S3
# ============================================================
upload_templates() {
    print_header "Step 2: Upload Templates to S3"

    # Create bucket if it doesn't exist
    if ! aws s3 ls "s3://$TEMPLATE_BUCKET" --region "$REGION" &>/dev/null; then
        print_info "Creating S3 bucket: $TEMPLATE_BUCKET"
        if [ "$REGION" = "us-east-1" ]; then
            aws s3api create-bucket --bucket "$TEMPLATE_BUCKET" --region "$REGION"
        else
            aws s3api create-bucket --bucket "$TEMPLATE_BUCKET" --region "$REGION" \
                --create-bucket-configuration LocationConstraint="$REGION"
        fi
        # Block public access
        aws s3api put-public-access-block \
            --bucket "$TEMPLATE_BUCKET" \
            --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
        print_success "Bucket created: $TEMPLATE_BUCKET"
    else
        print_info "Using existing bucket: $TEMPLATE_BUCKET"
    fi

    # Sync all yaml files from aws/ directory (excluding deploy_all/deploy.sh, cleanup.sh)
    print_info "Uploading templates from $AWS_DIR → s3://$TEMPLATE_BUCKET/$TEMPLATE_PREFIX/"
    aws s3 sync "$AWS_DIR" "s3://$TEMPLATE_BUCKET/$TEMPLATE_PREFIX/" \
        --region "$REGION" \
        --include "*.yaml" \
        --exclude "*.sh" \
        --exclude "*.md" \
        --exclude "*.txt" \
        --exclude ".git/*"

    print_success "All templates uploaded to s3://$TEMPLATE_BUCKET/$TEMPLATE_PREFIX/"
}

# ============================================================
# Service selection
# ============================================================
ask_yes_no() {
    local prompt="$1"
    local var_name="$2"
    read -p "$prompt [y/N]: " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        eval "$var_name=true"
    else
        eval "$var_name=false"
    fi
}

collect_service_params() {
    print_header "Step 3: Select Services to Deploy"
    print_info "Answer y/N for each service. You will be prompted for required parameters."
    echo ""

    ask_yes_no "Enable API Gateway logs?" ENABLE_API_GW
    ask_yes_no "Enable CloudFront real-time logs?" ENABLE_CF
    ask_yes_no "Enable CloudWatch Logs?" ENABLE_CWL
    ask_yes_no "Enable Cognito events?" ENABLE_COGNITO
    ask_yes_no "Enable DynamoDB streams?" ENABLE_DYNAMO
    ask_yes_no "Enable EC2 CloudWatch Agent (via SSM)?" ENABLE_EC2
    ask_yes_no "Enable EventBridge events?" ENABLE_EB
    ask_yes_no "Enable existing Kinesis Stream?" ENABLE_KINESIS
    ask_yes_no "Enable RDS logs?" ENABLE_RDS
    ask_yes_no "Enable Route53 query logs?" ENABLE_R53
    ask_yes_no "Enable S3 access logs?" ENABLE_S3
    ask_yes_no "Enable VPC Flow Logs?" ENABLE_VPC
    ask_yes_no "Enable ALB logs?" ENABLE_ALB
    ask_yes_no "Enable CloudTrail logs?" ENABLE_CT
    ask_yes_no "Enable CloudWatch All Metrics?" ENABLE_CW_METRICS
    ask_yes_no "Enable WAF logs?" ENABLE_WAF

    # Collect service-specific parameters
    collect_service_specific_params
}

collect_service_specific_params() {
    # API Gateway
    if [ "$ENABLE_API_GW" = "true" ]; then
        print_header "API Gateway Parameters"
        read -p "  API Gateway ID: " APIGW_ID
        read -p "  Stage name (e.g., prod): " APIGW_STAGE
        read -p "  Backup S3 bucket name (globally unique): " APIGW_BACKUP_BUCKET
        APIGW_STREAM="${APIGW_STREAM:-apigateway-logs-stream}"
    fi

    # CloudFront
    if [ "$ENABLE_CF" = "true" ]; then
        print_header "CloudFront Parameters"
        read -p "  CloudFront Distribution ID: " CF_DIST_ID
        read -p "  Backup S3 bucket name (globally unique): " CF_BACKUP_BUCKET
        CF_STREAM="${CF_STREAM:-cloudfront_access_logs}"
    fi

    # CloudWatch Logs
    if [ "$ENABLE_CWL" = "true" ]; then
        print_header "CloudWatch Logs Parameters"
        read -p "  Log Group name (e.g., /aws/lambda/my-function): " CWL_LOG_GROUP
        read -p "  Backup S3 bucket name (globally unique): " CWL_BACKUP_BUCKET
        CWL_STREAM="${CWL_STREAM:-cloudwatch-logs-stream}"
    fi

    # Cognito
    if [ "$ENABLE_COGNITO" = "true" ]; then
        print_header "Cognito Parameters"
        read -p "  User Pool ID (leave empty to monitor all pools): " COGNITO_POOL_ID
        COGNITO_STREAM="${COGNITO_STREAM:-cognito-events-to-openobserve}"
    fi

    # DynamoDB
    if [ "$ENABLE_DYNAMO" = "true" ]; then
        print_header "DynamoDB Parameters"
        read -p "  DynamoDB table name: " DYNAMO_TABLE
        read -p "  Backup S3 bucket name (globally unique): " DYNAMO_BACKUP_BUCKET
        DYNAMO_STREAM="${DYNAMO_STREAM:-dynamodb-streams}"
    fi

    # EC2
    if [ "$ENABLE_EC2" = "true" ]; then
        print_header "EC2 Parameters"
        read -p "  Target EC2 tag key [monitoring]: " EC2_TAG_KEY
        EC2_TAG_KEY="${EC2_TAG_KEY:-monitoring}"
        read -p "  Target EC2 tag value [enabled]: " EC2_TAG_VAL
        EC2_TAG_VAL="${EC2_TAG_VAL:-enabled}"
        EC2_LOG_PREFIX="${EC2_LOG_PREFIX:-/aws/ec2/instances}"
    fi

    # EventBridge
    if [ "$ENABLE_EB" = "true" ]; then
        print_header "EventBridge Parameters"
        read -p "  Rule name (e.g., my-ec2-state-changes): " EB_RULE_NAME
        read -p "  Event pattern JSON (e.g., {\"source\":[\"aws.ec2\"]}): " EB_PATTERN
        read -p "  Backup S3 bucket name (globally unique): " EB_BACKUP_BUCKET
        EB_STREAM="${EB_STREAM:-eventbridge-events}"
    fi

    # Kinesis
    if [ "$ENABLE_KINESIS" = "true" ]; then
        print_header "Kinesis Stream Parameters"
        read -p "  Kinesis Stream ARN: " KINESIS_ARN
        KINESIS_STREAM="${KINESIS_STREAM:-default/kinesis_logs}"
    fi

    # RDS
    if [ "$ENABLE_RDS" = "true" ]; then
        print_header "RDS Parameters"
        read -p "  CloudWatch Log Group (e.g., /aws/rds/instance/my-db/error): " RDS_LOG_GROUP
        read -p "  Backup S3 bucket name (globally unique): " RDS_BACKUP_BUCKET
        read -p "  RDS instance identifier (optional): " RDS_INSTANCE_ID
        RDS_STREAM="${RDS_STREAM:-rds-logs}"
    fi

    # Route53
    if [ "$ENABLE_R53" = "true" ]; then
        print_header "Route53 Parameters"
        read -p "  Hosted Zone ID (starts with Z): " R53_HZ_ID
        read -p "  Backup S3 bucket name (globally unique): " R53_BACKUP_BUCKET
        R53_STREAM="${R53_STREAM:-route53-query-logs}"
    fi

    # S3 Access Logs
    if [ "$ENABLE_S3" = "true" ]; then
        print_header "S3 Access Logs Parameters"
        read -p "  Source bucket to monitor: " S3_SOURCE_BUCKET
        read -p "  Log destination bucket name (globally unique, for access log files): " S3_LOG_DEST_BUCKET
        read -p "  Backup S3 bucket name (globally unique, for Firehose failures): " S3_BACKUP_BUCKET
        S3_STREAM="${S3_STREAM:-s3-access-logs-stream}"
    fi

    # VPC Flow Logs
    if [ "$ENABLE_VPC" = "true" ]; then
        print_header "VPC Flow Logs Parameters"
        read -p "  VPC ID (e.g., vpc-xxxxxxxx): " VPC_ID
        read -p "  Backup S3 bucket name (globally unique): " VPC_BACKUP_BUCKET
        VPC_STREAM="${VPC_STREAM:-vpc-flow-logs-stream}"
        VPC_TRAFFIC_TYPE="${VPC_TRAFFIC_TYPE:-ALL}"
    fi

    # ALB
    if [ "$ENABLE_ALB" = "true" ]; then
        print_header "ALB Parameters"
        read -p "  S3 bucket name for ALB logs: " ALB_BUCKET
        read -p "  AWS Account ID: " ALB_ACCOUNT_ID
        read -p "  ELB Account ID for your region (see AWS docs): " ALB_ELB_ACCOUNT_ID
        read -p "  Access logs prefix [access-logs]: " ALB_ACCESS_PREFIX
        ALB_ACCESS_PREFIX="${ALB_ACCESS_PREFIX:-access-logs}"
        read -p "  Connection logs prefix [connection-logs]: " ALB_CONN_PREFIX
        ALB_CONN_PREFIX="${ALB_CONN_PREFIX:-connection-logs}"
        read -p "  OpenObserve username: " ALB_USER
        read -p "  OpenObserve password: " ALB_PASS
    fi

    # CloudTrail
    if [ "$ENABLE_CT" = "true" ]; then
        print_header "CloudTrail Parameters"
        read -p "  Existing CloudTrail S3 bucket name: " CT_BUCKET
        read -p "  Backup S3 bucket name (can be same as CloudTrail bucket): " CT_BACKUP_BUCKET
    fi

    # CloudWatch Metrics
    if [ "$ENABLE_CW_METRICS" = "true" ]; then
        print_header "CloudWatch All Metrics Parameters"
        read -p "  Backup S3 bucket name (globally unique): " CW_METRICS_BUCKET
    fi

    # WAF
    if [ "$ENABLE_WAF" = "true" ]; then
        print_header "WAF Parameters"
        read -p "  Existing WAF S3 bucket name: " WAF_BUCKET
        read -p "  Backup S3 bucket name (can be same as WAF bucket): " WAF_BACKUP_BUCKET
    fi
}

# ============================================================
# Build parameter overrides string
# ============================================================
build_parameters() {
    PARAMS="TemplateS3Bucket=${TEMPLATE_BUCKET}"
    PARAMS="$PARAMS TemplateS3Prefix=${TEMPLATE_PREFIX}"
    PARAMS="$PARAMS OpenObserveEndpoint=${OO_ENDPOINT}"
    PARAMS="$PARAMS OpenObserveAccessKey=${OO_ACCESS_KEY}"

    # Service flags
    PARAMS="$PARAMS EnableApiGateway=${ENABLE_API_GW}"
    PARAMS="$PARAMS EnableCloudFront=${ENABLE_CF}"
    PARAMS="$PARAMS EnableCloudWatchLogs=${ENABLE_CWL}"
    PARAMS="$PARAMS EnableCognito=${ENABLE_COGNITO}"
    PARAMS="$PARAMS EnableDynamoDB=${ENABLE_DYNAMO}"
    PARAMS="$PARAMS EnableEC2=${ENABLE_EC2}"
    PARAMS="$PARAMS EnableEventBridge=${ENABLE_EB}"
    PARAMS="$PARAMS EnableKinesisStream=${ENABLE_KINESIS}"
    PARAMS="$PARAMS EnableRDS=${ENABLE_RDS}"
    PARAMS="$PARAMS EnableRoute53=${ENABLE_R53}"
    PARAMS="$PARAMS EnableS3AccessLogs=${ENABLE_S3}"
    PARAMS="$PARAMS EnableVPCFlowLogs=${ENABLE_VPC}"
    PARAMS="$PARAMS EnableALB=${ENABLE_ALB}"
    PARAMS="$PARAMS EnableCloudTrail=${ENABLE_CT}"
    PARAMS="$PARAMS EnableCloudWatchMetrics=${ENABLE_CW_METRICS}"
    PARAMS="$PARAMS EnableWAF=${ENABLE_WAF}"

    # Service-specific
    [ -n "$APIGW_ID" ]            && PARAMS="$PARAMS ApiGatewayId=${APIGW_ID}"
    [ -n "$APIGW_STAGE" ]         && PARAMS="$PARAMS ApiGatewayStageName=${APIGW_STAGE}"
    [ -n "$APIGW_BACKUP_BUCKET" ] && PARAMS="$PARAMS ApiGatewayBackupBucket=${APIGW_BACKUP_BUCKET}"
    [ -n "$APIGW_STREAM" ]        && PARAMS="$PARAMS ApiGatewayStreamName=${APIGW_STREAM}"

    [ -n "$CF_DIST_ID" ]          && PARAMS="$PARAMS CloudFrontDistributionId=${CF_DIST_ID}"
    [ -n "$CF_BACKUP_BUCKET" ]    && PARAMS="$PARAMS CloudFrontBackupBucket=${CF_BACKUP_BUCKET}"
    [ -n "$CF_STREAM" ]           && PARAMS="$PARAMS CloudFrontStreamName=${CF_STREAM}"

    [ -n "$CWL_LOG_GROUP" ]       && PARAMS="$PARAMS CloudWatchLogGroupName=${CWL_LOG_GROUP}"
    [ -n "$CWL_BACKUP_BUCKET" ]   && PARAMS="$PARAMS CloudWatchBackupBucket=${CWL_BACKUP_BUCKET}"
    [ -n "$CWL_STREAM" ]          && PARAMS="$PARAMS CloudWatchStreamName=${CWL_STREAM}"

    [ -n "$COGNITO_POOL_ID" ]     && PARAMS="$PARAMS CognitoUserPoolId=${COGNITO_POOL_ID}"
    [ -n "$COGNITO_STREAM" ]      && PARAMS="$PARAMS CognitoStreamName=${COGNITO_STREAM}"

    [ -n "$DYNAMO_TABLE" ]        && PARAMS="$PARAMS DynamoDBTableName=${DYNAMO_TABLE}"
    [ -n "$DYNAMO_BACKUP_BUCKET" ]&& PARAMS="$PARAMS DynamoDBBackupBucket=${DYNAMO_BACKUP_BUCKET}"
    [ -n "$DYNAMO_STREAM" ]       && PARAMS="$PARAMS DynamoDBStreamName=${DYNAMO_STREAM}"

    [ -n "$EC2_TAG_KEY" ]         && PARAMS="$PARAMS EC2TargetTagKey=${EC2_TAG_KEY}"
    [ -n "$EC2_TAG_VAL" ]         && PARAMS="$PARAMS EC2TargetTagValue=${EC2_TAG_VAL}"
    [ -n "$EC2_LOG_PREFIX" ]      && PARAMS="$PARAMS EC2LogGroupPrefix=${EC2_LOG_PREFIX}"

    [ -n "$EB_RULE_NAME" ]        && PARAMS="$PARAMS EventBridgeRuleName=${EB_RULE_NAME}"
    [ -n "$EB_PATTERN" ]          && PARAMS="$PARAMS EventBridgeEventPattern=${EB_PATTERN}"
    [ -n "$EB_BACKUP_BUCKET" ]    && PARAMS="$PARAMS EventBridgeBackupBucket=${EB_BACKUP_BUCKET}"
    [ -n "$EB_STREAM" ]           && PARAMS="$PARAMS EventBridgeStreamName=${EB_STREAM}"

    [ -n "$KINESIS_ARN" ]         && PARAMS="$PARAMS KinesisStreamArn=${KINESIS_ARN}"
    [ -n "$KINESIS_STREAM" ]      && PARAMS="$PARAMS KinesisStreamName=${KINESIS_STREAM}"

    [ -n "$RDS_LOG_GROUP" ]       && PARAMS="$PARAMS RDSLogGroupName=${RDS_LOG_GROUP}"
    [ -n "$RDS_BACKUP_BUCKET" ]   && PARAMS="$PARAMS RDSBackupBucket=${RDS_BACKUP_BUCKET}"
    [ -n "$RDS_STREAM" ]          && PARAMS="$PARAMS RDSStreamName=${RDS_STREAM}"
    [ -n "$RDS_INSTANCE_ID" ]     && PARAMS="$PARAMS RDSInstanceIdentifier=${RDS_INSTANCE_ID}"

    [ -n "$R53_HZ_ID" ]           && PARAMS="$PARAMS Route53HostedZoneId=${R53_HZ_ID}"
    [ -n "$R53_BACKUP_BUCKET" ]   && PARAMS="$PARAMS Route53BackupBucket=${R53_BACKUP_BUCKET}"
    [ -n "$R53_STREAM" ]          && PARAMS="$PARAMS Route53StreamName=${R53_STREAM}"

    [ -n "$S3_SOURCE_BUCKET" ]    && PARAMS="$PARAMS S3SourceBucketName=${S3_SOURCE_BUCKET}"
    [ -n "$S3_LOG_DEST_BUCKET" ]  && PARAMS="$PARAMS S3LogDestinationBucket=${S3_LOG_DEST_BUCKET}"
    [ -n "$S3_BACKUP_BUCKET" ]    && PARAMS="$PARAMS S3AccessLogsBackupBucket=${S3_BACKUP_BUCKET}"
    [ -n "$S3_STREAM" ]           && PARAMS="$PARAMS S3StreamName=${S3_STREAM}"

    [ -n "$VPC_ID" ]              && PARAMS="$PARAMS VpcId=${VPC_ID}"
    [ -n "$VPC_BACKUP_BUCKET" ]   && PARAMS="$PARAMS VPCBackupBucket=${VPC_BACKUP_BUCKET}"
    [ -n "$VPC_STREAM" ]          && PARAMS="$PARAMS VPCStreamName=${VPC_STREAM}"
    [ -n "$VPC_TRAFFIC_TYPE" ]    && PARAMS="$PARAMS VPCTrafficType=${VPC_TRAFFIC_TYPE}"

    [ -n "$ALB_BUCKET" ]          && PARAMS="$PARAMS ALBS3BucketName=${ALB_BUCKET}"
    [ -n "$ALB_ACCOUNT_ID" ]      && PARAMS="$PARAMS ALBAWSAccountId=${ALB_ACCOUNT_ID}"
    [ -n "$ALB_ELB_ACCOUNT_ID" ]  && PARAMS="$PARAMS ALBELBAccountId=${ALB_ELB_ACCOUNT_ID}"
    [ -n "$ALB_ACCESS_PREFIX" ]   && PARAMS="$PARAMS ALBAccessLogsPrefix=${ALB_ACCESS_PREFIX}"
    [ -n "$ALB_CONN_PREFIX" ]     && PARAMS="$PARAMS ALBConnectionLogsPrefix=${ALB_CONN_PREFIX}"
    [ -n "$ALB_USER" ]            && PARAMS="$PARAMS ALBBasicAuthUsername=${ALB_USER}"
    [ -n "$ALB_PASS" ]            && PARAMS="$PARAMS ALBBasicAuthPassword=${ALB_PASS}"

    [ -n "$CT_BUCKET" ]           && PARAMS="$PARAMS CloudTrailS3BucketName=${CT_BUCKET}"
    [ -n "$CT_BACKUP_BUCKET" ]    && PARAMS="$PARAMS CloudTrailS3BackupBucket=${CT_BACKUP_BUCKET}"

    [ -n "$CW_METRICS_BUCKET" ]   && PARAMS="$PARAMS CloudWatchMetricsS3BackupBucket=${CW_METRICS_BUCKET}"

    [ -n "$WAF_BUCKET" ]          && PARAMS="$PARAMS WAFS3BucketName=${WAF_BUCKET}"
    [ -n "$WAF_BACKUP_BUCKET" ]   && PARAMS="$PARAMS WAFS3BackupBucket=${WAF_BACKUP_BUCKET}"
}

# ============================================================
# Show deployment summary and confirm
# ============================================================
show_summary() {
    print_header "Deployment Summary"
    echo "  Stack Name:        $STACK_NAME"
    echo "  Region:            $REGION"
    echo "  Template Bucket:   s3://$TEMPLATE_BUCKET/$TEMPLATE_PREFIX/"
    echo "  OpenObserve URL:   $OO_ENDPOINT"
    echo ""
    echo "  Services:"
    [ "$ENABLE_API_GW"     = "true" ] && echo "    ✓ API Gateway"
    [ "$ENABLE_CF"         = "true" ] && echo "    ✓ CloudFront"
    [ "$ENABLE_CWL"        = "true" ] && echo "    ✓ CloudWatch Logs"
    [ "$ENABLE_COGNITO"    = "true" ] && echo "    ✓ Cognito"
    [ "$ENABLE_DYNAMO"     = "true" ] && echo "    ✓ DynamoDB"
    [ "$ENABLE_EC2"        = "true" ] && echo "    ✓ EC2 (CloudWatch Agent)"
    [ "$ENABLE_EB"         = "true" ] && echo "    ✓ EventBridge"
    [ "$ENABLE_KINESIS"    = "true" ] && echo "    ✓ Kinesis Stream"
    [ "$ENABLE_RDS"        = "true" ] && echo "    ✓ RDS"
    [ "$ENABLE_R53"        = "true" ] && echo "    ✓ Route53"
    [ "$ENABLE_S3"         = "true" ] && echo "    ✓ S3 Access Logs"
    [ "$ENABLE_VPC"        = "true" ] && echo "    ✓ VPC Flow Logs"
    [ "$ENABLE_ALB"        = "true" ] && echo "    ✓ ALB"
    [ "$ENABLE_CT"         = "true" ] && echo "    ✓ CloudTrail"
    [ "$ENABLE_CW_METRICS" = "true" ] && echo "    ✓ CloudWatch All Metrics"
    [ "$ENABLE_WAF"        = "true" ] && echo "    ✓ WAF"
    echo ""

    read -p "Proceed with deployment? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        print_warning "Deployment cancelled."
        exit 0
    fi
}

# ============================================================
# Deploy the master stack
# ============================================================
deploy_stack() {
    print_header "Step 4: Deploying Master Stack"
    print_info "Deploying stack: $STACK_NAME in $REGION"
    print_info "This may take 10–30 minutes depending on how many services are enabled."
    echo ""

    if aws cloudformation deploy \
        --region "$REGION" \
        --template-file "$SCRIPT_DIR/deploy_all.yaml" \
        --stack-name "$STACK_NAME" \
        --parameter-overrides $PARAMS \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
        --no-fail-on-empty-changeset; then

        print_success "Master stack deployed successfully!"
        echo ""
        print_info "Stack outputs:"
        aws cloudformation describe-stacks \
            --region "$REGION" \
            --stack-name "$STACK_NAME" \
            --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
            --output table
    else
        print_error "Deployment failed. Check CloudFormation console for details."
        exit 1
    fi
}

# ============================================================
# Main
# ============================================================
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  OpenObserve — Deploy All AWS Integrations   ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    print_info "This script will upload all CloudFormation templates to S3"
    print_info "and deploy them as a single nested CloudFormation stack."
    echo ""

    check_prerequisites
    collect_common_config
    upload_templates
    collect_service_params
    build_parameters
    show_summary
    deploy_stack
}

main
