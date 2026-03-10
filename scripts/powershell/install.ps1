# install.ps1 — Bootstrap and deploy all stacks (Windows PowerShell)
param(
    [Parameter(Mandatory=$true)]
    [string]$SystemAdminEmail
)

$ErrorActionPreference = "Stop"
$env:CDK_PARAM_SYSTEM_ADMIN_EMAIL = $SystemAdminEmail

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CdkDir = Join-Path $ScriptDir "..\..\cdk"

# Determine region
if ($env:AWS_REGION) {
    $Region = $env:AWS_REGION
} else {
    $Region = aws configure get region
    if (-not $Region) {
        Write-Host "Unable to determine AWS region. Set AWS_REGION or configure AWS CLI."
        exit 1
    }
}

# Deploy infrastructure
Push-Location $CdkDir
npm install

npx cdk bootstrap
npx cdk deploy --all --require-approval never --concurrency 10 --asset-parallelism true

$cpApiUrl = aws cloudformation describe-stacks --stack-name ControlPlaneStack --query "Stacks[0].Outputs[?OutputKey=='controlPlaneAPIEndpoint'].OutputValue" --output text
Write-Host "Control plane api gateway url: $cpApiUrl"

$s3Bucket = aws cloudformation describe-stacks --stack-name saas-genai-workshop-bootstrap-template --query "Stacks[0].Outputs[?OutputKey=='TenantSourceCodeS3Bucket'].OutputValue" --output text
Write-Host "S3 bucket url: $s3Bucket"
Pop-Location

# Upload source code to S3
$FolderPath = Join-Path $ScriptDir "..\.."
Write-Host "Uploading folder $FolderPath to S3 $s3Bucket"
aws s3 cp $FolderPath "s3://$s3Bucket" --recursive --exclude "cdk/cdk.out/*" --exclude "cdk/node_modules/*" --exclude ".git/*" --quiet

Write-Host "Installation completed successfully"
