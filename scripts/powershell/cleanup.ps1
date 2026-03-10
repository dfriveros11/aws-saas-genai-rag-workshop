# cleanup.ps1 — Clean up SaaS GenAI RAG Workshop resources (Windows PowerShell)
param(
    [Parameter(Mandatory=$true)]
    [string]$SystemAdminEmail
)

$ErrorActionPreference = "Stop"
$env:CDK_PARAM_SYSTEM_ADMIN_EMAIL = $SystemAdminEmail

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CdkDir = Join-Path $ScriptDir "..\..\cdk"

# ─────────────────────────────────────────────────────────────
# Empty S3 buckets
# ─────────────────────────────────────────────────────────────
Write-Host "$(Get-Date) emptying out buckets..."
$buckets = (aws s3 ls) | ForEach-Object {
    if ($_ -match '\S+\s+\S+\s+(\S+)') { $Matches[1] }
} | Where-Object { $_ -match "^saas-genai-workshop-" }

foreach ($bucket in $buckets) {
    Write-Host "$(Get-Date) emptying out s3 bucket s3://$bucket..."
    aws s3 rm --recursive "s3://$bucket"
}

# ─────────────────────────────────────────────────────────────
# Verify required tools
# ─────────────────────────────────────────────────────────────
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Host "Error: AWS CLI is not installed."; exit 1
}
if (-not (Get-Command cdk -ErrorAction SilentlyContinue)) {
    Write-Host "Error: AWS CDK is not installed. Run: npm install -g aws-cdk"; exit 1
}

# ─────────────────────────────────────────────────────────────
# Destroy CDK stacks
# ─────────────────────────────────────────────────────────────
Push-Location $CdkDir
Write-Host "Destroying CDK stacks..."
cdk destroy --all --force

Write-Host "Removing CDK context file..."
Remove-Item -Force cdk.context.json -ErrorAction SilentlyContinue

Write-Host "Removing CDK output directory..."
Remove-Item -Recurse -Force cdk.out -ErrorAction SilentlyContinue
Pop-Location

# ─────────────────────────────────────────────────────────────
# Clean up DynamoDB tables
# ─────────────────────────────────────────────────────────────
Write-Host "Cleaning up DynamoDB tables..."
$tables = (aws dynamodb list-tables --query "TableNames[?contains(@, ``TenantCostAndUsageAttribution``)]" --output text) -split "`t"
foreach ($table in $tables) {
    if ($table) {
        Write-Host "Deleting DynamoDB table: $table"
        aws dynamodb delete-table --table-name $table --no-cli-pager
    }
}

# ─────────────────────────────────────────────────────────────
# Clean up CodeCommit repository
# ─────────────────────────────────────────────────────────────
Write-Host "Cleaning up CodeCommit repository..."
$repoName = "saas-genai-workshop"
try {
    aws codecommit get-repository --repository-name $repoName 2>$null | Out-Null
    Write-Host "Deleting CodeCommit repository: $repoName"
    aws codecommit delete-repository --repository-name $repoName --no-cli-pager
    Write-Host "CodeCommit repository deleted successfully."
} catch {
    Write-Host "CodeCommit repository $repoName does not exist. Skipping."
}

# ─────────────────────────────────────────────────────────────
# Clean up CloudWatch log groups
# ─────────────────────────────────────────────────────────────
Write-Host "$(Get-Date) cleaning up log groups..."
$nextToken = $null
do {
    if ($nextToken) {
        $response = aws logs describe-log-groups --starting-token $nextToken | ConvertFrom-Json
    } else {
        $response = aws logs describe-log-groups | ConvertFrom-Json
    }

    foreach ($lg in $response.logGroups) {
        $name = $lg.logGroupName
        if ($name -match "^/aws/lambda/ControlPlaneStack-|saas-genai-workshop-|provisioningJobRunner|^/aws/lambda/TenantCostCalculatorService|^/aws/bedrock/SaaSGenAIWorkshopBedrockLogGroup") {
            $confirm = Read-Host "Delete log group $name [Y/n]"
            if ($confirm -ne "n") {
                Write-Host "$(Get-Date) deleting log group $name..."
                aws logs delete-log-group --log-group-name $name
            }
        }
    }
    $nextToken = $response.NextToken
} while ($nextToken)

# ─────────────────────────────────────────────────────────────
# Clean up Cognito user pools
# ─────────────────────────────────────────────────────────────
Write-Host "$(Get-Date) cleaning up user pools..."
$nextToken = $null
do {
    if ($nextToken) {
        $response = aws cognito-idp list-user-pools --max-results 10 --next-token $nextToken | ConvertFrom-Json
    } else {
        $response = aws cognito-idp list-user-pools --max-results 10 | ConvertFrom-Json
    }

    foreach ($pool in $response.UserPools) {
        if ($pool.Name -match "^IdentityProvidertenantUserPool|^CognitoAuthUserPool") {
            $poolId = $pool.Id
            Write-Host "$(Get-Date) deleting user pool $poolId..."
            $poolDetail = aws cognito-idp describe-user-pool --user-pool-id $poolId | ConvertFrom-Json
            $domain = $poolDetail.UserPool.Domain
            if ($domain) {
                Write-Host "deleting pool domain $domain..."
                aws cognito-idp delete-user-pool-domain --user-pool-id $poolId --domain $domain
            }
            aws cognito-idp delete-user-pool --user-pool-id $poolId --no-cli-pager
        }
    }
    $nextToken = $response.NextToken
} while ($nextToken)

Write-Host "Cleanup process completed."
