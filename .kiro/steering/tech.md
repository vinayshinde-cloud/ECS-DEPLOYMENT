# Tech Stack & Build System

## Language & Framework

- **Language**: Python 3.9+
- **Web Framework**: Streamlit (~1.23.1)
  - Server runs on port 80 (inside container, configurable)
  - No manual backend needed — Streamlit handles UI and basic server logic
  - Uses session state for client-side persistence
  - Headless mode for production (no browser UI)

## Key Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| streamlit | ~1.23.1 | Web UI framework |
| boto3 | ~1.28.63 | AWS SDK (DynamoDB, S3, Bedrock) |
| PIL (Pillow) | ~9.5.0 | Image processing |
| numpy | ~1.24.3 | Numerical operations |
| scipy | ~1.10.1 | Scientific computing (cosine similarity) |
| requests | ~2.31.0 | HTTP client |
| sagemaker | ~2.165.0 | AWS SageMaker integration (optional) |
| ai21 | ~1.1.4 | AI21 Labs integration (optional) |
| matplotlib, altair, pydeck | Latest | Visualization libraries |

## Build & Deployment

### Local Development

```bash
# Install dependencies
pip install -r requirements.txt

# Run locally
streamlit run Home.py
# App accessible at http://localhost:8501
```

### Docker Build

```bash
# Build image (automatic via deploy script)
docker build --pull -t cloudage-app .

# Run container locally
docker run -p 80:80 cloudage-app
# App accessible at http://localhost
```

**Dockerfile Key Points:**
- Base: `public.ecr.aws/docker/library/python:3.9.18`
- Installs dependencies with `pip install`
- Exposes port 80
- CMD: Runs Streamlit in headless mode with CORS disabled
- Network proxy environment variables stripped for AWS ECR access

### Deployment to AWS

**One-Command Deploy (Windows):**
```powershell
.\quick-deploy.ps1
```

**One-Command Deploy (Linux/Mac):**
```bash
chmod +x quick-deploy.sh
./quick-deploy.sh
```

**What the deploy script does:**
1. Logs into ECR
2. Pre-pulls base image with retries (resilient to slow networks)
3. Builds Docker image locally
4. Tags image with ECR registry URL
5. Pushes image to ECR with retries/backoff
6. Registers ECS task definition from `ecs-task.json`
7. Creates or updates ECS service
8. Ensures DynamoDB tables exist (`assignments`, `answers`)
9. Ensures S3 bucket exists
10. Forces new deployment and waits for stability
11. Outputs ALB DNS name for app access

**Deploy Configuration (in `quick-deploy.ps1`):**
- AWS Region: `us-east-1`
- ECR Repo: `992167236365.dkr.ecr.us-east-1.amazonaws.com/cloudage-app`
- Cluster: `cloudage-cluster`
- Service: `cloudage-service`
- Task Family: `cloudage-task`

## Environment Variables

### Runtime (set in `ecs-task.json`)

```env
AWS_REGION=us-east-1
ASSIGNMENTS_TABLE=assignments
BEDROCK_MODEL_ID=amazon.nova-canvas-v1:0
S3_BUCKET=mcq-project
```

### For Bedrock Models

- **Text (Q&A generation)**: `amazon.nova-pro-v1:0`
- **Image generation**: `amazon.nova-2-lite-v1:0`
- **Embeddings/Scoring**: Bedrock embedding model (used for cosine similarity)

## Key Configuration Files

| File | Purpose |
|------|---------|
| `requirements.txt` | Python dependencies (pinned versions) |
| `Dockerfile` | Container build definition |
| `ecs-task.json` | ECS task definition (CPU, memory, logging, env vars) |
| `aws/task-defination.json` | Backup task definition |
| `streamlit/config.toml` | Streamlit theme and UI settings |
| `.dockerignore` | Files excluded from Docker build |
| `.github/workflows/deploy.yaml` | CI/CD pipeline (GitHub Actions) |

## Logging

- **Local**: Streamlit logs to stdout (visible in terminal)
- **Production**: CloudWatch log group `/ecs/cloudage-task`
  - Log retention and filtering can be configured in `ecs-task.json`

## Common Commands

### Development

```bash
# Install/update dependencies
pip install -r requirements.txt

# Run app locally
streamlit run Home.py

# Format code (if using black)
black *.py pages/ components/
```

### Deployment

```powershell
# Deploy to AWS (idempotent, safe to run multiple times)
.\quick-deploy.ps1

# Check deployment status (CloudWatch logs)
aws logs tail /ecs/cloudage-task --follow

# View ECS service status
aws ecs describe-services --cluster cloudage-cluster --services cloudage-service
```

### Infrastructure

```powershell
# First-time infrastructure setup (creates ALB, ECS cluster, IAM roles, etc.)
.\aws\setup-infrastructure.ps1

# Create IAM roles if not present
.\aws\create-iam-roles.ps1
```

## Performance Considerations

- **Embedding calls**: Bedrock embeddings are cached where possible to reduce latency
- **Image generation**: Runs asynchronously in Streamlit; user sees progress feedback
- **DynamoDB throughput**: Set to `PAY_PER_REQUEST` for auto-scaling
- **Container resources**: Task defined with 256 CPU, 512 MB memory (configurable in `ecs-task.json`)

## Testing & Quality

- No automated test framework currently in place
- Manual testing via local Streamlit run or deployed ALB URL
- Bedrock API calls include error handling with user-friendly messages
- Image generation failures gracefully degrade (continue without image)

## Versioning & Releases

- **Image versioning**: Always tagged as `:latest` in ECR (no semantic versioning currently)
- **Task definition versioning**: ECS auto-increments on each new registration
- **Python version lock**: 3.9.18 (specified in Dockerfile base image)
- **Dependency pinning**: All versions pinned to specific numbers in `requirements.txt`
