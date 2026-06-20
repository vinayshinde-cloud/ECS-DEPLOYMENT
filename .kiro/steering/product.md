# CloudAge Education Portal

## Product Overview

CloudAge is a GenAI-powered education platform for teaching English language skills using Amazon Bedrock and AWS services. It enables teachers to create rich learning materials with AI-generated questions and images, and allows students to practice with immediate AI-based scoring and feedback.

## Core Features

**For Teachers (Pages 1-2):**
- Create assignments from sentences/learning context
- Auto-generate 5 Q&A pairs using Bedrock text models (Amazon Nova Pro)
- Auto-generate contextual images using Bedrock image models (Amazon Nova Canvas)
- Save assignments to DynamoDB with images on S3
- Browse and manage assignment library
- Edit and re-generate Q&A or images as needed

**For Students (Page 3 - Complete Assignments):**
- Select assignments from the teacher-created bank
- Answer questions with text input in Streamlit UI
- Receive AI-based scoring using embedding similarity (cosine distance)
- View top scores and leaderboards per question
- Get AI-generated suggestions for word/sentence improvements (future)
- Track personal progress across answered questions

## Data Flow

1. **Assignment Creation**: Teacher enters sentence → Bedrock generates 5 Q&A pairs + image → Saved to DynamoDB + S3
2. **Student Learning**: Student selects assignment and sees questions
3. **Answer Submission**: Student types answer → System embeds both answer and correct answer using Bedrock embeddings
4. **Scoring**: Cosine similarity between embeddings produces score (0-100) and persists in DynamoDB `answers` table
5. **Leaderboard**: GSI `assignment_question_id-index` enables top scores queries per question

## Key AWS Services

- **Amazon Bedrock**: Text-to-text (Nova Pro), text-to-image (Nova Canvas), and embeddings for Q&A generation and scoring
- **ECS Fargate**: Serverless container runtime for Streamlit app (512 CPU, 1024 MB memory)
- **DynamoDB**: Two tables (`assignments`, `answers`) with GSI for leaderboard queries; on-demand pricing
- **S3**: Image storage at `generated_images/{assignment_id}.png`
- **ECR**: Docker image registry at `992167236365.dkr.ecr.us-east-1.amazonaws.com/cloudage-app`
- **ALB**: Public load balancer exposing Streamlit on port 80/443
- **IAM**: Task execution and task roles with fine-grained policies (Bedrock, S3, DynamoDB, ECR, CloudWatch)
- **CloudWatch**: Logs streamed to `/ecs/cloudage-task` with automatic prefix

## Deployment Model

- **Container-based**: Streamlit runs in Docker on ECS Fargate; no EC2 server management
- **Serverless compute**: ECS handles auto-scaling and fault tolerance
- **Single-command deploy**: `.\quick-deploy.ps1` (Windows) or `./quick-deploy.sh` (Unix) handles full CI/CD pipeline
- **Infrastructure-as-Code**: PowerShell scripts auto-create ALB, VPC, security groups, IAM roles, ECS cluster on first run
- **Idempotent deploys**: Safe to run multiple times; scripts detect and skip existing resources

## Target Users

- **Teachers**: Non-technical educators using simple UI to create English learning materials
- **Students**: English learners receiving instant AI-scored feedback and suggestions
- **Administrators**: DevOps/Platform engineers deploying and maintaining via PowerShell/AWS CLI

## Bedrock Models Used

- **Text Generation**: `amazon.nova-pro-v1:0` (Q&A generation from context)
- **Image Generation**: `amazon.nova-2-lite-v1:0` (Contextual images)
- **Embeddings**: Default Bedrock embeddings model (for cosine similarity scoring)
