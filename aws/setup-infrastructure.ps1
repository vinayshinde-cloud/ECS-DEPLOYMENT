# PowerShell version of setup-infrastructure.sh

# Configuration - Update these values
$AWS_REGION = "us-east-1"
$CLUSTER_NAME = "cloudage-cluster"
$SERVICE_NAME = "cloudage-service"
$ECR_REPO_NAME = "cloudage-app"
$TASK_FAMILY = "cloudage-task"
$AWS_ACCOUNT_ID = aws sts get-caller-identity --query Account --output text

Write-Host "🚀 Setting up AWS infrastructure for CloudAge App..." -ForegroundColor Green

# 1. Create ECR Repository
Write-Host "📦 Creating ECR repository..." -ForegroundColor Yellow
aws ecr create-repository --repository-name $ECR_REPO_NAME --region $AWS_REGION --image-scanning-configuration scanOnPush=true 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ECR repository already exists" -ForegroundColor Cyan
}

# 2. Create CloudWatch Log Group
Write-Host "📝 Creating CloudWatch log group..." -ForegroundColor Yellow
aws logs create-log-group --log-group-name "/ecs/$TASK_FAMILY" --region $AWS_REGION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Log group already exists" -ForegroundColor Cyan
}

# 3. Create ECS Cluster
Write-Host "🏗️ Creating ECS cluster..." -ForegroundColor Yellow
aws ecs create-cluster --cluster-name $CLUSTER_NAME --capacity-providers FARGATE --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 --region $AWS_REGION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Cluster already exists" -ForegroundColor Cyan
}

# 4. Get default VPC and subnets
Write-Host "🌐 Getting VPC information..." -ForegroundColor Yellow
$VPC_ID = aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION
$SUBNET_IDS = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text --region $AWS_REGION
$SUBNET_ARRAY = $SUBNET_IDS -split "`t"

Write-Host "VPC ID: $VPC_ID" -ForegroundColor Cyan
Write-Host "Subnets: $($SUBNET_ARRAY -join ', ')" -ForegroundColor Cyan

# 5. Create Security Group
Write-Host "🔒 Creating security group..." -ForegroundColor Yellow
$SECURITY_GROUP_ID = aws ec2 create-security-group --group-name cloudage-sg --description "Security group for CloudAge app" --vpc-id $VPC_ID --region $AWS_REGION --query 'GroupId' --output text 2>$null
if ($LASTEXITCODE -ne 0) {
    $SECURITY_GROUP_ID = aws ec2 describe-security-groups --filters "Name=group-name,Values=cloudage-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION
}

# Add inbound rules to security group
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $AWS_REGION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Security group rule already exists" -ForegroundColor Cyan
}

Write-Host "Security Group ID: $SECURITY_GROUP_ID" -ForegroundColor Cyan

# 6. Create Application Load Balancer
Write-Host "⚖️ Creating Application Load Balancer..." -ForegroundColor Yellow
$ALB_ARN = aws elbv2 create-load-balancer --name cloudage-alb --subnets $SUBNET_ARRAY[0] $SUBNET_ARRAY[1] --security-groups $SECURITY_GROUP_ID --region $AWS_REGION --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>$null
if ($LASTEXITCODE -ne 0) {
    $ALB_ARN = aws elbv2 describe-load-balancers --names cloudage-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text --region $AWS_REGION
}

# Get ALB DNS name
$ALB_DNS = aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text --region $AWS_REGION

Write-Host "ALB ARN: $ALB_ARN" -ForegroundColor Cyan
Write-Host "ALB DNS: $ALB_DNS" -ForegroundColor Cyan

# 7. Create Target Group
Write-Host "🎯 Creating target group..." -ForegroundColor Yellow
$TARGET_GROUP_ARN = aws elbv2 create-target-group --name cloudage-targets --protocol HTTP --port 80 --vpc-id $VPC_ID --target-type ip --health-check-path / --health-check-interval-seconds 30 --health-check-timeout-seconds 10 --healthy-threshold-count 2 --unhealthy-threshold-count 3 --region $AWS_REGION --query 'TargetGroups[0].TargetGroupArn' --output text 2>$null
if ($LASTEXITCODE -ne 0) {
    $TARGET_GROUP_ARN = aws elbv2 describe-target-groups --names cloudage-targets --query 'TargetGroups[0].TargetGroupArn' --output text --region $AWS_REGION
}

Write-Host "Target Group ARN: $TARGET_GROUP_ARN" -ForegroundColor Cyan

# 8. Create ALB Listener
Write-Host "👂 Creating ALB listener..." -ForegroundColor Yellow
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN --region $AWS_REGION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Listener already exists" -ForegroundColor Cyan
}

Write-Host "✅ Infrastructure setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "📝 Save these values for your GitHub secrets:" -ForegroundColor Yellow
Write-Host "AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID" -ForegroundColor Cyan
Write-Host "VPC_ID=$VPC_ID" -ForegroundColor Cyan
Write-Host "SUBNET_1=$($SUBNET_ARRAY[0])" -ForegroundColor Cyan
Write-Host "SUBNET_2=$($SUBNET_ARRAY[1])" -ForegroundColor Cyan
Write-Host "SECURITY_GROUP_ID=$SECURITY_GROUP_ID" -ForegroundColor Cyan
Write-Host "TARGET_GROUP_ARN=$TARGET_GROUP_ARN" -ForegroundColor Cyan
Write-Host ""
Write-Host "🌐 Your app will be available at: http://$ALB_DNS" -ForegroundColor Green