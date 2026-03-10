#!/bin/bash
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CDK_DIR="$SCRIPT_DIR/../../cdk"
ROOT_DIR="$SCRIPT_DIR/../.."

# ─────────────────────────────────────────────────────────────
# Load configuration from config.yaml or config.example.yaml
# ─────────────────────────────────────────────────────────────
CONFIG_FILE="$ROOT_DIR/config.yaml"
if [[ ! -f "$CONFIG_FILE" ]]; then
    CONFIG_FILE="$ROOT_DIR/config.example.yaml"
    echo "⚠️  config.yaml not found — using config.example.yaml"
    echo "   Run: cp config.example.yaml config.yaml and fill in your values."
fi

# Parse a YAML value: get_value "key" → value (strips quotes)
get_value() {
    grep "^${1}:" "$CONFIG_FILE" | sed 's/^[^"]*"\([^"]*\)".*/\1/' | head -1
}

AWS_REGION=$(get_value "aws_region")
AWS_ACCOUNT=$(get_value "aws_account_id")
AWS_PROFILE_NAME=$(get_value "aws_profile")
ADMIN_EMAIL=$(get_value "system_admin_email")

export AWS_DEFAULT_REGION="${AWS_REGION:-us-west-2}"
export CDK_DEFAULT_REGION="${AWS_REGION:-us-west-2}"
export CDK_DEFAULT_ACCOUNT="${AWS_ACCOUNT}"
export CDK_PARAM_SYSTEM_ADMIN_EMAIL="${ADMIN_EMAIL}"

if [[ -n "$AWS_PROFILE_NAME" && "$AWS_PROFILE_NAME" != *"<"* ]]; then
    export AWS_PROFILE="$AWS_PROFILE_NAME"
fi

echo "Config: region=$AWS_DEFAULT_REGION account=$CDK_DEFAULT_ACCOUNT profile=${AWS_PROFILE:-default} email=$CDK_PARAM_SYSTEM_ADMIN_EMAIL"

CONTROL_PLANE_STACK="ControlPlaneStack"
BOOTSTRAP_STACK="saas-genai-workshop-bootstrap-template"
CORE_UTILS_STACK="saas-genai-workshop-core-utils-stack"

# ─────────────────────────────────────────────────────────────
# Helper: deploy a CDK stack
# ─────────────────────────────────────────────────────────────
deploy_stack() {
    local STACK_NAME="$1"
    echo ""
    echo "=========================================="
    echo "Deploying: $STACK_NAME"
    echo "=========================================="

    cd "$CDK_DIR"
    npx cdk deploy "$STACK_NAME" --require-approval never \
        --concurrency 10 --asset-parallelism true --exclusively

    local EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        echo "ERROR: Failed to deploy $STACK_NAME. Aborting."
        exit $EXIT_CODE
    fi

    echo "✅ $STACK_NAME deployed successfully."
}

# ─────────────────────────────────────────────────────────────
# Helper: delete a stack stuck in ROLLBACK_COMPLETE
# ─────────────────────────────────────────────────────────────
cleanup_rollback() {
    local STACK_NAME="$1"
    local STATUS
    STATUS=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].StackStatus" \
        --output text 2>/dev/null || echo "DOES_NOT_EXIST")

    if [ "$STATUS" == "ROLLBACK_COMPLETE" ]; then
        echo "⚠️  $STACK_NAME is in ROLLBACK_COMPLETE. Deleting before redeployment..."
        aws cloudformation delete-stack --stack-name "$STACK_NAME"
        aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
        echo "🗑️  $STACK_NAME deleted."
    fi
}

# ─────────────────────────────────────────────────────────────
# STEP 1: Deploy ControlPlaneStack (if not already deployed)
# ─────────────────────────────────────────────────────────────
echo ""
echo "STEP 1: Checking ControlPlane export..."

CONTROL_PLANE_EXPORT=$(aws cloudformation list-exports \
    --query "Exports[?contains(Name, 'SbtEventBus')].Value" \
    --output text 2>/dev/null)

if [ -z "$CONTROL_PLANE_EXPORT" ] || [ "$CONTROL_PLANE_EXPORT" == "None" ]; then
    echo "ControlPlane export not found. Deploying $CONTROL_PLANE_STACK..."
    cleanup_rollback "$CONTROL_PLANE_STACK"
    deploy_stack "$CONTROL_PLANE_STACK"
else
    echo "✅ ControlPlane export already exists. Skipping."
fi

# ─────────────────────────────────────────────────────────────
# STEP 2: Deploy saas-genai-workshop-core-utils-stack
# ─────────────────────────────────────────────────────────────
echo ""
echo "STEP 2: Deploying Core Utils Stack..."
cleanup_rollback "$CORE_UTILS_STACK"
deploy_stack "$CORE_UTILS_STACK"

# ─────────────────────────────────────────────────────────────
# STEP 3: Deploy saas-genai-workshop-bootstrap-template
# ─────────────────────────────────────────────────────────────
echo ""
echo "STEP 3: Deploying Bootstrap Template (S3 + OpenSearch)..."
cleanup_rollback "$BOOTSTRAP_STACK"
deploy_stack "$BOOTSTRAP_STACK"

# ─────────────────────────────────────────────────────────────
# STEP 4: Sync code to S3
# ─────────────────────────────────────────────────────────────
echo ""
echo "STEP 4: Looking up TenantSourceCodeS3Bucket..."

S3_BUCKET=$(aws cloudformation describe-stacks \
    --stack-name "$BOOTSTRAP_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='TenantSourceCodeS3Bucket'].OutputValue" \
    --output text 2>/dev/null)

if [ -z "$S3_BUCKET" ] || [ "$S3_BUCKET" == "None" ]; then
    echo "Bootstrap stack bucket not found. Searching all stacks..."
    ALL_STACKS=$(aws cloudformation list-stacks \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --query "StackSummaries[].StackName" \
        --output text)

    for STACK in $ALL_STACKS; do
        BUCKET=$(aws cloudformation describe-stacks \
            --stack-name "$STACK" \
            --query "Stacks[0].Outputs[?OutputKey=='TenantSourceCodeS3Bucket'].OutputValue" \
            --output text 2>/dev/null)
        if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
            echo "Found TenantSourceCodeS3Bucket in stack: $STACK"
            S3_BUCKET="$BUCKET"
            break
        fi
    done
fi

if [ -z "$S3_BUCKET" ] || [ "$S3_BUCKET" == "None" ]; then
    echo "⚠️  WARNING: No S3 bucket found. Skipping code sync."
    echo "✅ All stacks deployed successfully."
    exit 0
fi

echo "S3 bucket: $S3_BUCKET"

cd "$ROOT_DIR"
echo "Uploading updated code..."
aws s3 sync "." "s3://$S3_BUCKET" \
    --exclude "cdk/cdk.out/*" \
    --exclude "cdk/node_modules/*" \
    --exclude ".git/*"

echo ""
echo "=========================================="
echo "✅ Full deployment completed successfully!"
echo "=========================================="
