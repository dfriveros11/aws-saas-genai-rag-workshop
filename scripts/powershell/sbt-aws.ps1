# sbt-aws.ps1 — SBT CLI for SaaS GenAI RAG Workshop (Windows PowerShell)
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [switch]$Debug,
    [Parameter(Position=0)]
    [string]$Operation,
    [Parameter(Position=1, ValueFromRemainingArguments=$true)]
    [string[]]$Args
)

$ErrorActionPreference = "Stop"
$ConfigFile = Join-Path $env:USERPROFILE ".sbt-aws-config"

function Show-Help {
    Write-Host "Usage: .\sbt-aws.ps1 [-Debug] <operation> [additional args]"
    Write-Host "Operations:"
    Write-Host "  configure <control_plane_stack> <user_email>"
    Write-Host "  refresh-tokens"
    Write-Host "  create-tenant <tenant_name>"
    Write-Host "  get-tenant-registration <tenant_registration_id>"
    Write-Host "  get-all-tenant-registrations [limit] [next_token]"
    Write-Host "  update-tenant-registration <tenant_registration_id> <key> <value>"
    Write-Host "  delete-tenant-registration <tenant_registration_id>"
    Write-Host "  get-tenant <tenant_id>"
    Write-Host "  get-all-tenants [limit] [next_token]"
    Write-Host "  update-token-limit <tenant_name> <input_tokens> <output_tokens>"
    Write-Host "  create-user"
    Write-Host "  get-user <user_id>"
    Write-Host "  get-all-users [limit] [next_token]"
    Write-Host "  update-user <user_id> <user_role> <user_email>"
    Write-Host "  delete-user <user_id>"
    Write-Host "  invoke <user_name> <password> <query> <requests>"
    Write-Host "  upload-file <user_name> <password> <file_location>"
    Write-Host "  execute-query <user_name> <password> <knowledge_base_query>"
    Write-Host "  help"
}

function Generate-Credentials {
    param([string]$Password, [string]$StackName)
    if ($Debug) { Write-Host "Generating credentials..." }

    $User = "admin@example.com"
    $script:ClientId = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?contains(OutputKey,'ControlPlaneIdpClientId')].OutputValue" --output text
    $script:UserPoolId = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?contains(OutputKey,'ControlPlaneIdpUserPoolId')].OutputValue" --output text

    if ($Debug) { Write-Host "CLIENT_ID: $script:ClientId"; Write-Host "USER_POOL_ID: $script:UserPoolId" }

    aws cognito-idp update-user-pool-client --user-pool-id $script:UserPoolId --client-id $script:ClientId --id-token-validity 3 --access-token-validity 3 --explicit-auth-flows USER_PASSWORD_AUTH --output text | Out-Null
    aws cognito-idp admin-set-user-password --user-pool-id $script:UserPoolId --username $User --password $Password --permanent --output text | Out-Null

    $authResult = aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id $script:ClientId --auth-parameters "USERNAME='$User',PASSWORD='$Password'" --query "AuthenticationResult" | ConvertFrom-Json
    $script:AccessToken = $authResult.AccessToken

    if ($Debug) { Write-Host "ACCESS_TOKEN: $script:AccessToken" }
}

function Invoke-Configure {
    param([string]$StackName, [string]$UserEmail)
    $EmailUsername = $UserEmail
    $EmailDomain = ($UserEmail -split "@")[1]

    if ($Debug) { Write-Host "Configuring: STACK=$StackName EMAIL=$EmailUsername DOMAIN=$EmailDomain" }

    $securePass = Read-Host "Enter admin password" -AsSecureString
    $AdminPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass))

    Generate-Credentials $AdminPassword $StackName
    $ApiEndpoint = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?contains(OutputKey,'controlPlaneAPIEndpoint')].OutputValue" --output text

    @"
CONTROL_PLANE_STACK_NAME=$StackName
CONTROL_PLANE_API_ENDPOINT=$ApiEndpoint
ADMIN_USER_PASSWORD=$AdminPassword
EMAIL_USERNAME=$EmailUsername
EMAIL_DOMAIN=$EmailDomain
ACCESS_TOKEN=$script:AccessToken
"@ | Set-Content $ConfigFile

    Write-Host "Successfully configured SaaS admin credentials"
}

function Import-Config {
    Get-Content $ConfigFile | ForEach-Object {
        if ($_ -match "^(\w+)=(.*)$") {
            Set-Variable -Name $Matches[1] -Value $Matches[2] -Scope Script
        }
    }
}

function Invoke-RefreshTokens {
    Import-Config
    if ($Debug) { Write-Host "Refreshing tokens..." }
    Generate-Credentials $script:ADMIN_USER_PASSWORD $script:CONTROL_PLANE_STACK_NAME
    $ApiEndpoint = aws cloudformation describe-stacks --stack-name $script:CONTROL_PLANE_STACK_NAME --query "Stacks[0].Outputs[?contains(OutputKey,'controlPlaneAPIEndpoint')].OutputValue" --output text

    @"
CONTROL_PLANE_STACK_NAME=$script:CONTROL_PLANE_STACK_NAME
CONTROL_PLANE_API_ENDPOINT=$ApiEndpoint
ADMIN_USER_PASSWORD=$script:ADMIN_USER_PASSWORD
EMAIL_USERNAME=$script:EMAIL_USERNAME
EMAIL_DOMAIN=$script:EMAIL_DOMAIN
ACCESS_TOKEN=$script:AccessToken
"@ | Set-Content $ConfigFile
}

function Invoke-CreateTenant {
    param([string]$TenantName)
    Import-Config
    $TenantEmail = "$TenantName@example.com"
    if ($Debug) { Write-Host "Creating tenant: $TenantName ($TenantEmail)" }

    $data = @{
        tenantData = @{
            tenantName = $TenantName
            email = $TenantEmail
            tier = "basic"
            prices = @(
                @{ id = "price_123456789Example"; metricName = "productsSold" }
                @{ id = "price_123456789AnotherExample"; metricName = "plusProductsSold" }
            )
        }
        tenantRegistrationData = @{
            registrationStatus = "In progress"
            tenantRegistrationData1 = "test"
        }
    } | ConvertTo-Json -Depth 5

    $response = Invoke-RestMethod -Method Post -Uri "$($script:CONTROL_PLANE_API_ENDPOINT)tenant-registrations" -Headers @{ Authorization = "Bearer $script:ACCESS_TOKEN" } -ContentType "application/json" -Body $data
    $response | ConvertTo-Json -Depth 5
}

function Get-TenantRegistration {
    param([string]$Id)
    Import-Config
    $response = Invoke-RestMethod -Method Get -Uri "$($script:CONTROL_PLANE_API_ENDPOINT)tenant-registrations/$Id" -Headers @{ Authorization = "Bearer $script:ACCESS_TOKEN" }
    $response | ConvertTo-Json -Depth 5
}

function Get-AllTenantRegistrations {
    param([int]$Limit = 10, [string]$NextToken = "")
    Import-Config
    $url = "$($script:CONTROL_PLANE_API_ENDPOINT)tenant-registrations?limit=$Limit"
    if ($NextToken) { $url += "&next_token=$NextToken" }
    $response = Invoke-RestMethod -Method Get -Uri $url -Headers @{ Authorization = "Bearer $script:ACCESS_TOKEN" }
    $response | ConvertTo-Json -Depth 5
}

function Update-TenantRegistration {
    param([string]$Id, [string]$Key, [string]$Value)
    Import-Config
    $data = @{
        tenantRegistrationData = @{ $Key = $Value }
        tenantData = @{ $Key = $Value }
    } | ConvertTo-Json -Depth 3

    $response = Invoke-RestMethod -Method Patch -Uri "$($script:CONTROL_PLANE_API_ENDPOINT)tenant-registrations/$Id" -Headers @{ Authorization = "Bearer $script:ACCESS_TOKEN" } -ContentType "application/json" -Body $data
    $response | ConvertTo-Json -Depth 5
}

function Remove-TenantRegistration {
    param([string]$Id)
    Import-Config
    $response = Invoke-RestMethod -Method Delete -Uri "$($script:CONTROL_PLANE_API_ENDPOINT)tenant-registrations/$Id" -Headers @{ Authorization = "Bearer $script:ACCESS_TOKEN" } -ContentType "application/json"
    $response | ConvertTo-Json -Depth 5
}

function Get-Tenant {
    param([string]$TenantId)
    Import-Config
    $response = Invoke-RestMethod -Method Get -Uri "$($script:CONTROL_PLANE_API_ENDPOINT)tenants/$TenantId" -Headers @{ Authorization = "Bearer $script:ACCESS_TOKEN" }
    $response | ConvertTo-Json -Depth 5
}

function Get-AllTenants {
    param([int]$Limit = 10, [string]$NextToken = "")
    Import-Config
    $url = "$($script:CONTROL_PLANE_API_ENDPOINT)tenants?limit=$Limit"
    if ($NextToken) { $url += "&next_token=$NextToken" }
    $response = Invoke-RestMethod -Method Get -Uri $url -Headers @{ Authorization = "Bearer $script:ACCESS_TOKEN" }
    $response | ConvertTo-Json -Depth 5
}

function Invoke-CreateUser {
    Import-Config
    $UserName = "user$(Get-Random)"
    $UserEmail = "$($script:EMAIL_USERNAME)+$UserName@$($script:EMAIL_DOMAIN)"
    if ($Debug) { Write-Host "Creating user: $UserName ($UserEmail)" }

    $data = @{
        userName = $UserName
        email = $UserEmail
        userRole = "basicUser"
    } | ConvertTo-Json

    $response = Invoke-RestMethod -Method Post -Uri "$($script:CONTROL_PLANE_API_ENDPOINT)users" -Headers @{ Authorization = "Bearer $script:ACCESS_TOKEN" } -ContentType "application/json" -Body $data
    $response | ConvertTo-Json -Depth 5
}

function Get-AllUsers {
    param([int]$Limit = 10, [string]$NextToken = "")
    Import-Config
    $url = "$($script:CONTROL_PLANE_API_ENDPOINT)users?limit=$Limit"
    if ($NextToken) { $url += "&next_token=$NextToken" }
    $response = Invoke-RestMethod -Method Get -Uri $url -Headers @{ Authorization = "Bearer $script:ACCESS_TOKEN" }
    $response | ConvertTo-Json -Depth 5
}

function Get-User {
    param([string]$UserId)
    Import-Config
    $response = Invoke-RestMethod -Method Get -Uri "$($script:CONTROL_PLANE_API_ENDPOINT)users/$UserId" -Headers @{ Authorization = "Bearer $script:ACCESS_TOKEN" }
    $response | ConvertTo-Json -Depth 5
}

function Update-User {
    param([string]$UserId, [string]$UserRole, [string]$UserEmail)
    Import-Config
    $data = @{}
    if ($UserRole) { $data.userRole = $UserRole }
    if ($UserEmail) { $data.email = $UserEmail }
    $json = $data | ConvertTo-Json

    $response = Invoke-RestMethod -Method Put -Uri "$($script:CONTROL_PLANE_API_ENDPOINT)users/$UserId" -Headers @{ Authorization = "Bearer $script:ACCESS_TOKEN" } -ContentType "application/json" -Body $json
    $response | ConvertTo-Json -Depth 5
}

function Remove-User {
    param([string]$UserId)
    Import-Config
    $response = Invoke-RestMethod -Method Delete -Uri "$($script:CONTROL_PLANE_API_ENDPOINT)users/$UserId" -Headers @{ Authorization = "Bearer $script:ACCESS_TOKEN" }
    $response | ConvertTo-Json -Depth 5
}

function Update-TokenLimit {
    param([string]$TenantName, [string]$InputTokens, [string]$OutputTokens)
    Import-Config

    $tenantsJson = Get-AllTenants
    $tenants = $tenantsJson | ConvertFrom-Json
    $tenant = $tenants.data | Where-Object { $_.tenantName -eq $TenantName }

    if (-not $tenant) {
        Write-Host "Error: Could not find tenant: $TenantName"
        return
    }

    $TenantId = $tenant.tenantId
    $TenantRegId = $tenant.tenantRegistrationId

    $currentConfig = (Invoke-RestMethod -Method Get -Uri "$($script:CONTROL_PLANE_API_ENDPOINT)tenants/$TenantId" -Headers @{ Authorization = "Bearer $script:ACCESS_TOKEN" }).data.tenantConfig | ConvertFrom-Json
    $currentConfig.inputTokens = $InputTokens
    $currentConfig.outputTokens = $OutputTokens
    $updatedConfig = $currentConfig | ConvertTo-Json -Compress

    $data = @{ tenantData = @{ tenantConfig = $updatedConfig } } | ConvertTo-Json -Depth 3

    $response = Invoke-WebRequest -Method Patch -Uri "$($script:CONTROL_PLANE_API_ENDPOINT)tenant-registrations/$TenantRegId" -Headers @{ Authorization = "Bearer $script:ACCESS_TOKEN" } -ContentType "application/json" -Body $data
    if ($response.StatusCode -eq 200) {
        Write-Host "Tenant $TenantName updated to $InputTokens input tokens and $OutputTokens output tokens"
    } else {
        Write-Host "Error updating tenant $TenantName: HTTP $($response.StatusCode)"
    }
}

function Get-TenantAuth {
    param([string]$UserName, [string]$Password)
    $StackName = "saas-genai-workshop-bootstrap-template"
    $clientId = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" --output text
    $apiUrl = aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs[?OutputKey=='ApiGatewayUrl'].OutputValue" --output text

    $authResult = aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id $clientId --auth-parameters "USERNAME='$UserName',PASSWORD='$Password'" --query "AuthenticationResult" | ConvertFrom-Json

    return @{
        AccessToken = $authResult.AccessToken
        IdToken = $authResult.IdToken
        ApiUrl = $apiUrl
    }
}

function Invoke-UploadFile {
    param([string]$UserName, [string]$Password, [string]$FileLocation)
    $auth = Get-TenantAuth $UserName $Password
    $content = Get-Content $FileLocation -Raw
    $data = @{ fileContent = $content } | ConvertTo-Json

    $response = Invoke-RestMethod -Method Post -Uri "$($auth.ApiUrl)upload" -Headers @{ Authorization = "Bearer $($auth.IdToken)" } -ContentType "application/json" -Body $data
    $response | ConvertTo-Json -Depth 5
}

function Invoke-Query {
    param([string]$UserName, [string]$Password, [string]$Query, [int]$Requests)
    $auth = Get-TenantAuth $UserName $Password

    Write-Host "Sending request and waiting for response..."
    for ($i = 1; $i -le $Requests; $i++) {
        $response = Invoke-WebRequest -Method Post -Uri "$($auth.ApiUrl)invoke" -Headers @{ Authorization = "Bearer $($auth.IdToken)" } -ContentType "application/json" -Body $Query
        Write-Host "Request $i - HTTP Status Code: $($response.StatusCode), Output Text: $($response.Content)"
        Start-Sleep -Seconds 12
    }
    Write-Host "All done"
}

function Invoke-ExecuteQuery {
    param([string]$UserName, [string]$Password, [string]$Query)
    $auth = Get-TenantAuth $UserName $Password

    Write-Host "Sending request and waiting for response..."
    $response = Invoke-RestMethod -Method Post -Uri "$($auth.ApiUrl)invoke" -Headers @{ Authorization = "Bearer $($auth.IdToken)" } -ContentType "application/json" -Body $Query
    $response | ConvertTo-Json -Depth 5
}

function Get-KnowledgeBaseId {
    param([string]$TenantName)
    $tenantsJson = Get-AllTenants
    $tenants = $tenantsJson | ConvertFrom-Json
    $tenant = $tenants.data | Where-Object { $_.tenantName -eq $TenantName }
    if (-not $tenant) { Write-Host "Error: Tenant '$TenantName' not found"; return }
    $config = $tenant.tenantConfig | ConvertFrom-Json
    Write-Host "Knowledge Base id for $TenantName is: $($config.knowledgeBaseId)"
}

# ─────────────────────────────────────────────────────────────
# Main dispatcher
# ─────────────────────────────────────────────────────────────
if (-not $Operation) { Show-Help; exit 1 }

switch ($Operation) {
    "configure" {
        if ($Args.Count -lt 2) { Write-Host "Error: configure requires <control_plane_stack> <user_email>"; exit 1 }
        Invoke-Configure $Args[0] $Args[1]
    }
    "refresh-tokens" { Invoke-RefreshTokens }
    "create-tenant" {
        if ($Args.Count -lt 1) { Write-Host "Error: create-tenant requires tenant name"; exit 1 }
        Invoke-CreateTenant $Args[0]
    }
    "get-tenant-registration" {
        if ($Args.Count -lt 1) { Write-Host "Error: requires tenant registration id"; exit 1 }
        Get-TenantRegistration $Args[0]
    }
    "get-all-tenant-registrations" {
        $limit = if ($Args.Count -ge 1) { [int]$Args[0] } else { 10 }
        $token = if ($Args.Count -ge 2) { $Args[1] } else { "" }
        Get-AllTenantRegistrations $limit $token
    }
    "update-tenant-registration" {
        if ($Args.Count -lt 3) { Write-Host "Error: requires id, key, and value"; exit 1 }
        Update-TenantRegistration $Args[0] $Args[1] $Args[2]
    }
    "delete-tenant-registration" {
        if ($Args.Count -lt 1) { Write-Host "Error: requires tenant registration id"; exit 1 }
        Remove-TenantRegistration $Args[0]
    }
    "get-tenant" {
        if ($Args.Count -lt 1) { Write-Host "Error: requires tenant id"; exit 1 }
        Get-Tenant $Args[0]
    }
    "get-all-tenants" {
        $limit = if ($Args.Count -ge 1) { [int]$Args[0] } else { 10 }
        $token = if ($Args.Count -ge 2) { $Args[1] } else { "" }
        Get-AllTenants $limit $token
    }
    "get-knowledge-base-id" {
        if ($Args.Count -lt 1) { Write-Host "Error: requires tenant name"; exit 1 }
        Get-KnowledgeBaseId $Args[0]
    }
    "update-token-limit" {
        if ($Args.Count -lt 3) { Write-Host "Error: requires tenant name, input tokens, output tokens"; exit 1 }
        Update-TokenLimit $Args[0] $Args[1] $Args[2]
    }
    "upload-file" {
        if ($Args.Count -lt 3) { Write-Host "Error: requires username, password, file_location"; exit 1 }
        Invoke-UploadFile $Args[0] $Args[1] $Args[2]
    }
    "invoke" {
        if ($Args.Count -lt 4) { Write-Host "Error: requires username, password, query, requests"; exit 1 }
        Invoke-Query $Args[0] $Args[1] $Args[2] ([int]$Args[3])
    }
    "execute-query" {
        if ($Args.Count -lt 3) { Write-Host "Error: requires username, password, query"; exit 1 }
        Invoke-ExecuteQuery $Args[0] $Args[1] $Args[2]
    }
    "create-user" { Invoke-CreateUser }
    "get-all-users" {
        $limit = if ($Args.Count -ge 1) { [int]$Args[0] } else { 10 }
        $token = if ($Args.Count -ge 2) { $Args[1] } else { "" }
        Get-AllUsers $limit $token
    }
    "get-user" {
        if ($Args.Count -lt 1) { Write-Host "Error: requires user id"; exit 1 }
        Get-User $Args[0]
    }
    "update-user" {
        if ($Args.Count -lt 3) { Write-Host "Error: requires user id, role, email"; exit 1 }
        Update-User $Args[0] $Args[1] $Args[2]
    }
    "delete-user" {
        if ($Args.Count -lt 1) { Write-Host "Error: requires user id"; exit 1 }
        Remove-User $Args[0]
    }
    "help" { Show-Help }
    default {
        Write-Host "Invalid operation: $Operation"
        Show-Help
        exit 1
    }
}
