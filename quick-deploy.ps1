# Quick Deploy Script - Single command to deploy changes
# Usage: .\quick-deploy.ps1

Write-Host "🚀 Quick Deploy - Deploying your changes..." -ForegroundColor Green

# Configuration
$AWS_REGION = "us-east-1"
$ECR_REPO = "992167236365.dkr.ecr.us-east-1.amazonaws.com/cloudage-app"
$CLUSTER_NAME = "cloudage-cluster"
$SERVICE_NAME = "cloudage-service"

# Step 0: Normalize proxy env (avoid proxying AWS ECR)
$env:http_proxy=""
$env:https_proxy=""
$env:HTTP_PROXY=""
$env:HTTPS_PROXY=""
$env:NO_PROXY="localhost,127.0.0.1,*.amazonaws.com,amazonaws.com,$ECR_REPO"
$env:no_proxy=$env:NO_PROXY
# Extend Docker timeouts and bypass proxy for public ECR
$env:DOCKER_CLIENT_TIMEOUT="300"
$env:COMPOSE_HTTP_TIMEOUT="300"
$env:NO_PROXY+=";*.ecr.aws;public.ecr.aws"
$env:no_proxy=$env:NO_PROXY

# Step 1: Login to ECR
Write-Host "🔑 Logging into ECR..." -ForegroundColor Yellow
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPO

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to login to ECR" -ForegroundColor Red
    exit 1
}

# Step 2: Build Docker image
Write-Host "📥 Pre-pulling base image (public.ecr.aws/docker/library/python:3.9.18)..." -ForegroundColor Yellow
$attempt = 1
$maxAttempts = 5
do {
  docker pull public.ecr.aws/docker/library/python:3.9.18
  $rc = $LASTEXITCODE
  if ($rc -eq 0) { break }
  if ($attempt -ge $maxAttempts) {
    Write-Host "❌ Failed to pull base image after $attempt attempts (rc=$rc)" -ForegroundColor Red
    exit $rc
  }
  $sleepSeconds = $attempt * 5
  Write-Host "⚠️ Pull failed (rc=$rc). Retrying in ${sleepSeconds}s... (attempt ${attempt}/${maxAttempts})" -ForegroundColor Yellow
  Start-Sleep -Seconds $sleepSeconds
  $attempt += 1
} while ($true)

Write-Host "🔨 Building Docker image..." -ForegroundColor Yellow
docker build --pull -t cloudage-app .

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to build Docker image" -ForegroundColor Red
    exit 1
}

# Step 3: Tag image
Write-Host "🏷️ Tagging image..." -ForegroundColor Yellow
docker tag cloudage-app:latest "$ECR_REPO`:latest"

# Step 4: Push to ECR (with retries/backoff)
Write-Host "📤 Pushing image to ECR..." -ForegroundColor Yellow
$attempt = 1
$maxAttempts = 5
do {
  docker push "$ECR_REPO`:latest"
  $rc = $LASTEXITCODE
  if ($rc -eq 0) { break }
  if ($attempt -ge $maxAttempts) {
    Write-Host "❌ Failed to push image to ECR after $attempt attempts (rc=$rc)" -ForegroundColor Red
    exit $rc
  }
  $sleepSeconds = $attempt * 5
  Write-Host "⚠️ Push failed (rc=$rc). Retrying in ${sleepSeconds}s... (attempt ${attempt}/${maxAttempts})" -ForegroundColor Yellow
  Start-Sleep -Seconds $sleepSeconds
  $attempt += 1
} while ($true)

# Step 5: Ensure ECS service exists (create if missing), then deploy
# Register task definition if ecs-task.json exists
if (Test-Path -Path "ecs-task.json") {
  Write-Host "📄 Registering task definition from ecs-task.json..." -ForegroundColor Yellow
  aws ecs register-task-definition --cli-input-json file://ecs-task.json --region $AWS_REGION | Out-Null
}

# Check if service exists
$serviceName = aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION --query 'services[0].serviceName' --output text 2>$null
if (-not $serviceName -or $serviceName -eq "None") {
  Write-Host "🆕 ECS service '$SERVICE_NAME' not found. Creating it..." -ForegroundColor Yellow

  # Discover networking resources
  $vpcId = aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION
  $subnets = aws ec2 describe-subnets --filters Name=vpc-id,Values=$vpcId --query 'Subnets[0:2].SubnetId' --output text --region $AWS_REGION
  $subnetArray = $subnets -split "`t"
  $sgId = aws ec2 describe-security-groups --filters Name=group-name,Values=cloudage-sg Name=vpc-id,Values=$vpcId --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION
  $tgArn = aws elbv2 describe-target-groups --names cloudage-targets --query 'TargetGroups[0].TargetGroupArn' --output text --region $AWS_REGION

  aws ecs create-service `
    --cluster $CLUSTER_NAME `
    --service-name $SERVICE_NAME `
    --task-definition cloudage-task `
    --desired-count 1 `
    --launch-type FARGATE `
    --network-configuration "awsvpcConfiguration={subnets=[$($subnetArray[0]),$($subnetArray[1])],securityGroups=[$sgId],assignPublicIp=ENABLED}" `
    --load-balancers "targetGroupArn=$tgArn,containerName=cloudage-container,containerPort=80" `
    --health-check-grace-period-seconds 60 `
    --region $AWS_REGION | Out-Null

  Write-Host "✅ ECS service created." -ForegroundColor Green
}

# Ensure DynamoDB 'answers' table with GSI exists
Write-Host "🧱 Ensuring DynamoDB table 'answers'..." -ForegroundColor Yellow
$answersExists = aws dynamodb describe-table --table-name answers --region $AWS_REGION 2>$null
if ($LASTEXITCODE -ne 0) {
  aws dynamodb create-table `
    --table-name answers `
    --attribute-definitions AttributeName=student_id,AttributeType=S AttributeName=assignment_question_id,AttributeType=S AttributeName=score,AttributeType=N `
    --key-schema AttributeName=student_id,KeyType=HASH AttributeName=assignment_question_id,KeyType=RANGE `
    --billing-mode PAY_PER_REQUEST `
    --global-secondary-indexes "IndexName=assignment_question_id-index,KeySchema=[{AttributeName=assignment_question_id,KeyType=HASH},{AttributeName=score,KeyType=RANGE}],Projection={ProjectionType=ALL}" `
    --region $AWS_REGION | Out-Null
  aws dynamodb wait table-exists --table-name answers --region $AWS_REGION
} else {
  $gsiCount = aws dynamodb describe-table --table-name answers --region $AWS_REGION --query "length(Table.GlobalSecondaryIndexes[?IndexName=='assignment_question_id-index'])" --output text
  if (-not $gsiCount -or $gsiCount -eq "0") {
    Write-Host "🔧 Adding missing GSI 'assignment_question_id-index'..." -ForegroundColor Yellow
    aws dynamodb update-table `
      --table-name answers `
      --attribute-definitions AttributeName=assignment_question_id,AttributeType=S AttributeName=score,AttributeType=N `
      --global-secondary-index-updates '{"Create":{"IndexName":"assignment_question_id-index","KeySchema":[{"AttributeName":"assignment_question_id","KeyType":"HASH"},{"AttributeName":"score","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}}' `
      --region $AWS_REGION | Out-Null
    aws dynamodb wait table-exists --table-name answers --region $AWS_REGION
  }
}

Write-Host "🔄 Deploying to ECS..." -ForegroundColor Yellow
aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --task-definition cloudage-task --force-new-deployment --region $AWS_REGION

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to update ECS service" -ForegroundColor Red
    exit 1
}

# Step 6: Wait for deployment
Write-Host "⏳ Waiting for deployment to complete..." -ForegroundColor Yellow
aws ecs wait services-stable --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION

# Step 7: Check deployment status
Write-Host "📊 Checking deployment status..." -ForegroundColor Yellow
$serviceStatus = aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION --query 'services[0].{Status:status,RunningCount:runningCount,DesiredCount:desiredCount}' --output json | ConvertFrom-Json

Write-Host "✅ Deployment Status:" -ForegroundColor Green
Write-Host "   Status: $($serviceStatus.Status)" -ForegroundColor Cyan
Write-Host "   Running Tasks: $($serviceStatus.RunningCount)/$($serviceStatus.DesiredCount)" -ForegroundColor Cyan

# Step 8: Get app URL
$albDns = aws elbv2 describe-load-balancers --names cloudage-alb --region $AWS_REGION --query 'LoadBalancers[0].DNSName' --output text

Write-Host ""
Write-Host "🎉 Deployment Complete!" -ForegroundColor Green
Write-Host "🌐 Your app is available at: http://$albDns" -ForegroundColor Cyan
Write-Host ""
Write-Host "📝 Next time you make changes, just run: .\quick-deploy.ps1" -ForegroundColor Yellow