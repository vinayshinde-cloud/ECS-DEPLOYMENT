# PowerShell version of create-iam-roles.sh

$AWS_ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$AWS_REGION = "us-east-1"

Write-Host "🔐 Creating IAM roles for ECS..." -ForegroundColor Green

# 1. Create ECS Task Execution Role
$taskExecutionTrustPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
"@

Set-Content -Path "task-execution-trust-policy.json" -Value $taskExecutionTrustPolicy

aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document file://task-execution-trust-policy.json 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ecsTaskExecutionRole already exists" -ForegroundColor Cyan
}

aws iam attach-role-policy --role-name ecsTaskExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# 2. Create ECS Task Role
aws iam create-role --role-name ecsTaskRole --assume-role-policy-document file://task-execution-trust-policy.json 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ecsTaskRole already exists" -ForegroundColor Cyan
}

# 3. Create GitHub Actions User
$githubActionsPolicy = @"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ecr:GetAuthorizationToken",
                "ecr:BatchCheckLayerAvailability",
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchGetImage",
                "ecr:InitiateLayerUpload",
                "ecr:UploadLayerPart",
                "ecr:CompleteLayerUpload",
                "ecr:PutImage"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ecs:UpdateService",
                "ecs:DescribeServices",
                "ecs:DescribeTaskDefinition",
                "ecs:RegisterTaskDefinition"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "iam:PassRole"
            ],
            "Resource": [
                "arn:aws:iam::$AWS_ACCOUNT_ID:role/ecsTaskExecutionRole",
                "arn:aws:iam::$AWS_ACCOUNT_ID:role/ecsTaskRole"
            ]
        }
    ]
}
"@

Set-Content -Path "github-actions-policy.json" -Value $githubActionsPolicy

aws iam create-policy --policy-name GitHubActionsECSPolicy --policy-document file://github-actions-policy.json 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "GitHubActionsECSPolicy already exists" -ForegroundColor Cyan
}

aws iam create-user --user-name github-actions-user 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "github-actions-user already exists" -ForegroundColor Cyan
}

aws iam attach-user-policy --user-name github-actions-user --policy-arn "arn:aws:iam::$AWS_ACCOUNT_ID:policy/GitHubActionsECSPolicy"

# Create access keys
Write-Host "🔑 Creating access keys for GitHub Actions user..." -ForegroundColor Yellow
aws iam create-access-key --user-name github-actions-user --output table

Write-Host "✅ IAM roles and user created successfully!" -ForegroundColor Green

# Cleanup temporary files
Remove-Item -Path "task-execution-trust-policy.json" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "github-actions-policy.json" -Force -ErrorAction SilentlyContinue