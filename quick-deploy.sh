#!/bin/bash

# Quick Deploy Script - Single command to deploy changes
# Usage: ./quick-deploy.sh

echo "🚀 Quick Deploy - Deploying your changes..."

# Configuration
AWS_REGION="us-east-1"
ECR_REPO="992167236365.dkr.ecr.us-east-1.amazonaws.com/cloudage-app"
CLUSTER_NAME="cloudage-cluster"
SERVICE_NAME="cloudage-service"
TASK_FAMILY="cloudage-task"
DDb_TABLE="assignments"
S3_BUCKET="mcq-project"

# Step 0: Normalize proxy env (avoid proxying AWS ECR)
export http_proxy=
export https_proxy=
export HTTP_PROXY=
export HTTPS_PROXY=
export NO_PROXY="localhost,127.0.0.1,*.amazonaws.com,amazonaws.com,$ECR_REPO"
export no_proxy="$NO_PROXY"
# Improve Docker client timeouts to better handle slow registries
export DOCKER_CLIENT_TIMEOUT=300
export COMPOSE_HTTP_TIMEOUT=300
# Ensure public ECR bypasses proxies
export NO_PROXY="$NO_PROXY,*.ecr.aws,public.ecr.aws"
export no_proxy="$NO_PROXY"

# Step 1: Login to ECR
echo "🔑 Logging into ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPO

if [ $? -ne 0 ]; then
    echo "❌ Failed to login to ECR"
    exit 1
fi

# Step 2: Build Docker image
echo "📥 Pre-pulling base image (public.ecr.aws/docker/library/python:3.9.18)..."
set +e
attempt=1
max_attempts=5
until docker pull public.ecr.aws/docker/library/python:3.9.18; do
  rc=$?
  if [ $attempt -ge $max_attempts ]; then
    echo "❌ Failed to pull base image after $attempt attempts (rc=$rc)"
    exit $rc
  fi
  sleep_seconds=$((attempt * 5))
  echo "⚠️ Pull failed (rc=$rc). Retrying in ${sleep_seconds}s... (attempt ${attempt}/${max_attempts})"
  sleep $sleep_seconds
  attempt=$((attempt + 1))
done
set -e

echo "🔨 Building Docker image..."
docker build --pull -t cloudage-app .

if [ $? -ne 0 ]; then
    echo "❌ Failed to build Docker image"
    exit 1
fi

# Step 3: Tag image
echo "🏷️ Tagging image..."
docker tag cloudage-app:latest $ECR_REPO:latest

# Step 4: Push to ECR (with retries and backoff)
echo "📤 Pushing image to ECR..."
set +e
attempt=1
max_attempts=5
until docker push $ECR_REPO:latest; do
  rc=$?
  if [ $attempt -ge $max_attempts ]; then
    echo "❌ Failed to push image to ECR after $attempt attempts (rc=$rc)"
    exit $rc
  fi
  sleep_seconds=$((attempt * 5))
  echo "⚠️ Push failed (rc=$rc). Retrying in ${sleep_seconds}s... (attempt ${attempt}/${max_attempts})"
  sleep $sleep_seconds
  attempt=$((attempt + 1))
done
set -e

# Step 5: IAM + Infra + TaskDef + Deploy
# 5a: Ensure IAM policies on ecsTaskRole
echo "🔐 Ensuring IAM policies on ecsTaskRole..."
aws iam attach-role-policy --role-name ecsTaskRole --policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess 2>/dev/null || true
cat > bedrock-inline-policy.json <<EOF
{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],"Resource":["arn:aws:bedrock:us-east-1::foundation-model/*"]}]
}
EOF
aws iam put-role-policy --role-name ecsTaskRole --policy-name EcsTaskBedrockInvokePolicy --policy-document file://bedrock-inline-policy.json 2>/dev/null || true
cat > ecs-s3-policy.json <<EOF
{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Action":["s3:ListBucket"],"Resource":"arn:aws:s3:::$S3_BUCKET"},{"Effect":"Allow","Action":["s3:PutObject","s3:GetObject","s3:DeleteObject"],"Resource":"arn:aws:s3:::$S3_BUCKET/*"}]
}
EOF
aws iam put-role-policy --role-name ecsTaskRole --policy-name EcsTaskS3Policy --policy-document file://ecs-s3-policy.json 2>/dev/null || true

# 5b: Ensure DynamoDB table and S3 bucket
echo "🧱 Ensuring DynamoDB table '$DDb_TABLE'..."
if ! aws dynamodb describe-table --table-name "$DDb_TABLE" --region $AWS_REGION >/dev/null 2>&1; then
  aws dynamodb create-table --table-name "$DDb_TABLE" --attribute-definitions AttributeName=id,AttributeType=S --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST --region $AWS_REGION
  aws dynamodb wait table-exists --table-name "$DDb_TABLE" --region $AWS_REGION
fi
echo "🪣 Ensuring S3 bucket '$S3_BUCKET'..."
if ! aws s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null; then
  aws s3api create-bucket --bucket "$S3_BUCKET" --region $AWS_REGION --create-bucket-configuration LocationConstraint=$AWS_REGION 2>/dev/null || true
fi

# 5b-2: Ensure DynamoDB table 'answers' with required GSI exists
echo "🧱 Ensuring DynamoDB table 'answers'..."
if ! aws dynamodb describe-table --table-name "answers" --region $AWS_REGION >/dev/null 2>&1; then
  aws dynamodb create-table \
    --table-name answers \
    --attribute-definitions AttributeName=student_id,AttributeType=S AttributeName=assignment_question_id,AttributeType=S AttributeName=score,AttributeType=N \
    --key-schema AttributeName=student_id,KeyType=HASH AttributeName=assignment_question_id,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --global-secondary-indexes 'IndexName=assignment_question_id-index,KeySchema=[{AttributeName=assignment_question_id,KeyType=HASH},{AttributeName=score,KeyType=RANGE}],Projection={ProjectionType=ALL}' \
    --region $AWS_REGION
  aws dynamodb wait table-exists --table-name "answers" --region $AWS_REGION
else
  # Ensure GSI exists; if not, add it
  GSI_EXISTS=$(aws dynamodb describe-table --table-name answers --region $AWS_REGION --query "Table.GlobalSecondaryIndexes[?IndexName=='assignment_question_id-index'] | length(@)" --output text)
  if [ "$GSI_EXISTS" = "0" ] || [ -z "$GSI_EXISTS" ]; then
    echo "🔧 Adding missing GSI 'assignment_question_id-index' to 'answers' table..."
    aws dynamodb update-table \
      --table-name answers \
      --attribute-definitions AttributeName=assignment_question_id,AttributeType=S AttributeName=score,AttributeType=N \
      --global-secondary-index-updates '{"Create":{"IndexName":"assignment_question_id-index","KeySchema":[{"AttributeName":"assignment_question_id","KeyType":"HASH"},{"AttributeName":"score","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}}' \
      --region $AWS_REGION
    aws dynamodb wait table-exists --table-name "answers" --region $AWS_REGION
  fi
fi

# 5c: Register task definition if file exists
if [ -f ecs-task.json ]; then
  echo "📄 Registering task definition from ecs-task.json..."
  aws ecs register-task-definition --cli-input-json file://ecs-task.json --region $AWS_REGION >/dev/null
fi

# 5d: Ensure ECS service exists (create if missing)
SERVICE_FOUND=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION --query 'services[0].serviceName' --output text 2>/dev/null || echo "None")
if [ "$SERVICE_FOUND" = "None" ] || [ -z "$SERVICE_FOUND" ] || [ "$SERVICE_FOUND" = "NoneType" ]; then
  echo "🆕 ECS service '$SERVICE_NAME' not found. Creating it..."

  # Discover networking resources (default VPC, two subnets, SG, and Target Group)
  VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text --region $AWS_REGION)
  read SUBNET1 SUBNET2 <<<"$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --query 'Subnets[0:2].SubnetId' --output text --region $AWS_REGION)"
  SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=cloudage-sg Name=vpc-id,Values=$VPC_ID --query 'SecurityGroups[0].GroupId' --output text --region $AWS_REGION)
  TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups --names cloudage-targets --query 'TargetGroups[0].TargetGroupArn' --output text --region $AWS_REGION)

  aws ecs create-service \
    --cluster $CLUSTER_NAME \
    --service-name $SERVICE_NAME \
    --task-definition $TASK_FAMILY \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET1,$SUBNET2],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$TARGET_GROUP_ARN,containerName=cloudage-container,containerPort=80" \
    --health-check-grace-period-seconds 60 \
    --region $AWS_REGION >/dev/null

  echo "✅ ECS service created."
fi

echo "🔄 Deploying to ECS..."
aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --task-definition $TASK_FAMILY --force-new-deployment --region $AWS_REGION

if [ $? -ne 0 ]; then
    echo "❌ Failed to update ECS service"
    exit 1
fi

# Step 6: Wait for deployment
echo "⏳ Waiting for deployment to complete..."
aws ecs wait services-stable --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION

# Step 7: Check deployment status
echo "📊 Checking deployment status..."
aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION --query 'services[0].{Status:status,RunningCount:runningCount,DesiredCount:desiredCount}' --output table

# Step 8: Get app URL
ALB_DNS=$(aws elbv2 describe-load-balancers --names cloudage-alb --region $AWS_REGION --query 'LoadBalancers[0].DNSName' --output text)

echo ""
echo "🎉 Deployment Complete!"
echo "🌐 Your app is available at: http://$ALB_DNS"
echo ""
echo "📝 Next time you make changes, just run: ./quick-deploy.sh"