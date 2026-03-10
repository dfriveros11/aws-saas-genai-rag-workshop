# deploy.ps1 — Deploy SaaS GenAI RAG Workshop (Windows PowerShell)
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CdkDir = Join-Path $ScriptDir "..\..\cdk"
$RootDir = Join-Path $ScriptDir "..\.."

# ─────────────────────────────────────────────────────────────
# Load configuration from config.yaml or config.example.yaml
# ─────────────────────────────────────────────────────────────
$ConfigFile = Join-Path $RootDir "config.yaml"
if (-not (Test-Path $ConfigFile)) {
    $ConfigFile = Join-Path $RootDir "config.example.yaml"
    Write-Host "WARNING: config.yaml not found - using config.example.yaml"
    Write-Host "   Run: Copy-Item config.example.yaml config.yaml and fill in your values."
}

function Get-ConfigValue {
    param([string]$Key)
    $line = Get-Content $ConfigFile | Where-Object { $_ -match "^${Key}:" } | Select-Object -First 1
    if ($line -match '"([^"]*)"') { return $Matches[1] }
    return $null
}

$AwsRegion = Get-ConfigValue "aws_region"
$AwsAccount = Get-ConfigValue "aws_account_id"
$AwsProfileName = Get-ConfigValue "aws_profile"
$AdminEmail = Get-ConfigValue "system_admin_email"

$env:AWS_DEFAULT_REGION = if ($AwsRegion) { $AwsRegion } else { "us-west-2" }
$env:CDK_DEFAULT_REGION = $env:AWS_DEFAULT_REGION
$env:CDK_DEFAULT_ACCOUNT = $AwsAccount
$env:CDK_PARAM_SYSTEM_ADMIN_EMAIL = $AdminEmail

if ($AwsProfileName -and $AwsProfileName -notmatch "<") {
    $env:AWS_PROFILE = $AwsProfileName
}

Write-Host "Config: region=$env:AWS_DEFAULT_REGION account=$env:CDK_DEFAULT_ACCOUNT profile=$($env:AWS_PROFILE ?? 'default') email=$env:CDK_PARAM_SYSTEM_ADMIN_EMAIL"

$ControlPlaneStack = "ControlPlaneStack"
$BootstrapStack = "saas-genai-workshop-bootstrap-template"
$CoreUtilsStack = "saas-genai-workshop-core-utils-stack"

# ─────────────────────────────────────────────────────────────
# Helper: deploy a CDK stack
# ─────────────────────────────────────────────────────────────
function Deploy-Stack {
    param([string]$StackName)
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "Deploying: $StackName"
    Write-Host "=========================================="

    Push-Location $CdkDir
    npx cdk deploy $StackName --require-approval never --concurrency 10 --asset-parallelism true --exclusively
    $exitCode = $LASTEXITCODE
    Pop-Location

    if ($exitCode -ne 0) {
        Write-Host "ERROR: Failed to deploy $StackName. Aborting."
        exit $exitCode
    }
    Write-Host "OK $StackName deployed successfully."
}

# ─────────────────────────────────────────────────────────────
# Helper: delete a stack stuck in ROLLBACK_COMPLETE
# ─────────────────────────────────────────────────────────────
function Cleanup-Rollback {
    param([string]$StackName)
    try {
        $status = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].StackStatus" --output text 2>$null
    } catch {
        $status = "DOES_NOT_EXIST"
    }
    if ($status -eq "ROLLBACK_COMPLETE") {
        Write-Host "WARNING: $StackName is in ROLLBACK_COMPLETE. Deleting before redeployment..."
        aws cloudformation delete-stack --stack-name $StackName
        aws cloudformation wait stack-delete-complete --stack-name $StackName
        Write-Host "DELETED $StackName deleted."
    }
}

# ─────────────────────────────────────────────────────────────
# STEP 1: Deploy ControlPlaneStack
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "STEP 1: Checking ControlPlane export..."

$cpExport = aws cloudformation list-exports --query "Exports[?contains(Name, 'SbtEventBus')].Value" --output text 2>$null

if (-not $cpExport -or $cpExport -eq "None") {
    Write-Host "ControlPlane export not found. Deploying $ControlPlaneStack..."
    Cleanup-Rollback $ControlPlaneStack
    Deploy-Stack $ControlPlaneStack
} else {
    Write-Host "OK ControlPlane export already exists. Skipping."
}

# ─────────────────────────────────────────────────────────────
# STEP 2: Deploy Core Utils Stack
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "STEP 2: Deploying Core Utils Stack..."
Cleanup-Rollback $CoreUtilsStack
Deploy-Stack $CoreUtilsStack

# ─────────────────────────────────────────────────────────────
# STEP 3: Deploy Bootstrap Template
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "STEP 3: Deploying Bootstrap Template (S3 + OpenSearch)..."
Cleanup-Rollback $BootstrapStack
Deploy-Stack $BootstrapStack

# ─────────────────────────────────────────────────────────────
# STEP 4: Sync code to S3
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "STEP 4: Looking up TenantSourceCodeS3Bucket..."

$s3Bucket = aws cloudformation describe-stacks --stack-name $BootstrapStack --query "Stacks[0].Outputs[?OutputKey=='TenantSourceCodeS3Bucket'].OutputValue" --output text 2>$null

if (-not $s3Bucket -or $s3Bucket -eq "None") {
    Write-Host "Bootstrap stack bucket not found. Searching all stacks..."
    $allStacks = (aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query "StackSummaries[].StackName" --output text) -split "`t"
    foreach ($stack in $allStacks) {
        $bucket = aws cloudformation describe-stacks --stack-name $stack --query "Stacks[0].Outputs[?OutputKey=='TenantSourceCodeS3Bucket'].OutputValue" --output text 2>$null
        if ($bucket -and $bucket -ne "None") {
            Write-Host "Found TenantSourceCodeS3Bucket in stack: $stack"
            $s3Bucket = $bucket
            break
        }
    }
}

if (-not $s3Bucket -or $s3Bucket -eq "None") {
    Write-Host "WARNING: No S3 bucket found. Skipping code sync."
    Write-Host "OK All stacks deployed successfully."
    exit 0
}

Write-Host "S3 bucket: $s3Bucket"

Push-Location $RootDir
Write-Host "Uploading updated code..."
aws s3 sync "." "s3://$s3Bucket" --exclude "cdk/cdk.out/*" --exclude "cdk/node_modules/*" --exclude ".git/*"
Pop-Location

Write-Host ""
Write-Host "=========================================="
Write-Host "OK Full deployment completed successfully!"
Write-Host "=========================================="
