# provision-tenant.ps1 — Provision tenant resources (Windows PowerShell)
$ErrorActionPreference = "Stop"

$StackName = "saas-genai-workshop-bootstrap-template"

$s3Bucket = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='TenantSourceCodeS3Bucket'].OutputValue" --output text
$env:CDK_PARAM_CODE_REPOSITORY_NAME = "saas-genai-workshop"

# Download source from S3
Write-Host "Downloading folder from s3://$s3Bucket to $env:CDK_PARAM_CODE_REPOSITORY_NAME..."
aws s3 cp "s3://$s3Bucket" $env:CDK_PARAM_CODE_REPOSITORY_NAME --recursive --exclude "cdk/cdk.out/*" --exclude "cdk/node_modules/*" --exclude ".git/*" --quiet
Push-Location "$env:CDK_PARAM_CODE_REPOSITORY_NAME\cdk"

# Parse tenant details from step function input
$env:CDK_PARAM_TENANT_ID = $env:tenantId -replace '"', ''
$env:CDK_PARAM_TENANT_NAME = $env:tenantName -replace '"', ''
$TenantAdminEmail = $env:email -replace '"', ''

# Read stack outputs
$env:REGION = aws configure get region
$env:SAAS_APP_USERPOOL_ID = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='TenantUserpoolId'].OutputValue" --output text
$env:SAAS_APP_CLIENT_ID = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" --output text
$env:API_GATEWAY_URL = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='ApiGatewayUrl'].OutputValue" --output text
$env:API_GATEWAY_USAGE_PLAN_ID = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='ApiGatewayUsagePlan'].OutputValue" --output text
$env:S3_BUCKET = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='SaaSGenAIWorkshopS3Bucket'].OutputValue" --output text
$env:TRIGGER_PIPELINE_INGESTION_LAMBDA_ARN = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='SaaSGenAIWorkshopTriggerIngestionLambdaArn'].OutputValue" --output text
$env:OPENSEARCH_SERVERLESS_COLLECTION_ARN = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='SaaSGenAIWorkshopOSSCollectionArn'].OutputValue" --output text

# Generate API key
$TenantApiKey = "$(New-Guid)-sbt"

# Error handling helper
function Check-Error {
    param([string]$Name, [int]$ExitCode, [string]$Output)
    if ($ExitCode -ne 0) {
        Write-Host $Output
        Write-Host "ERROR: $Name failed. Exiting"
        exit 1
    }
    Write-Host "$Name completed successfully"
}

# Invoke tenant provisioning service
pip3 install -r lib\tenant-template\tenant-provisioning\requirements.txt

$provisionOutput = python3 lib\tenant-template\tenant-provisioning\tenant_provisioning_service.py --tenantid $env:CDK_PARAM_TENANT_ID 2>&1
Check-Error "Tenant Provisioning" $LASTEXITCODE $provisionOutput

$env:KNOWLEDGE_BASE_NAME = $env:CDK_PARAM_TENANT_ID
$kbList = aws bedrock-agent list-knowledge-bases | ConvertFrom-Json
$env:KNOWLEDGE_BASE_ID = ($kbList | ForEach-Object { $_ } | Where-Object { $_.name -eq $env:KNOWLEDGE_BASE_NAME } | Select-Object -First 1).knowledgeBaseId

# Create tenant admin user
$adminOutput = python3 lib\tenant-template\user-management\user_management_service.py --tenant-id $env:CDK_PARAM_TENANT_ID --email $TenantAdminEmail --user-role "TenantAdmin" 2>&1
Check-Error "Tenant Admin User Provisioning" $LASTEXITCODE $adminOutput

# Build tenant config JSON
$InputTokens = "10000"
$OutputTokens = "500"

$tenantConfig = @{
    tenantName = $env:CDK_PARAM_TENANT_NAME
    userPoolId = $env:SAAS_APP_USERPOOL_ID
    appClientId = $env:SAAS_APP_CLIENT_ID
    apiGatewayUrl = $env:API_GATEWAY_URL
    apiKey = $TenantApiKey
    knowledgeBaseId = $env:KNOWLEDGE_BASE_ID
    inputTokens = $InputTokens
    outputTokens = $OutputTokens
} | ConvertTo-Json -Compress

$env:tenantConfig = $tenantConfig
$env:tenantStatus = "Complete"

Pop-Location
