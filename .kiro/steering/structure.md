# Project Structure

## Directory Layout

```
ECS-Deployment/
├── .github/
│   └── workflows/
│       └── deploy.yaml              # GitHub Actions CI/CD pipeline
├── .kiro/
│   └── steering/                    # AI steering documents (this directory)
├── aws/
│   ├── create-iam-roles.ps1         # PowerShell script to create IAM roles
│   ├── setup-infrastructure.ps1     # PowerShell script to create ALB, ECS cluster, etc.
│   ├── task-defination.json         # Backup ECS task definition
│   └── [other AWS config files]
├── components/
│   ├── Parameter_store.py           # Configuration helpers (S3 bucket name)
│   └── ui_template.py               # Shared Streamlit UI utilities
├── pages/
│   ├── 1_Create_Assignments.py      # Teacher page: create assignments (Q&A + image)
│   ├── 2_Show_Assignments.py        # Teacher page: browse assignments
│   └── 3_Complete_Assignments.py    # Student page: answer and get scores
├── streamlit/
│   └── config.toml                  # Streamlit theme and UI config
├── .dockerignore                    # Files excluded from Docker build
├── Dockerfile                       # Container build definition
├── Home.py                          # Streamlit home/landing page
├── nginx.conf                       # Nginx reverse proxy config (optional)
├── quick-deploy.ps1                 # One-command deploy script (Windows/PowerShell)
├── quick-deploy.sh                  # One-command deploy script (Bash/Linux/Mac)
├── requirements.txt                 # Python dependencies
├── ecs-task.json                    # ECS task definition (CPU, memory, logging)
├── [policy files]                   # IAM policy JSONs (ecs-*.json, bedrock-*.json)
├── Readme.md                        # Project documentation
├── commands.md                      # Common CLI commands reference
└── Build and Test Locally.md        # Local development guide
```

## Core Application Files

### Entry Points

- **`Home.py`**: Main Streamlit app entry point (landing page)
  - Configures page metadata
  - Displays welcome message and app description
  - Hides Streamlit chrome (menu, footer)
  - Acts as navigation hub to other pages

### Pages (Multi-page App)

Streamlit automatically discovers pages in the `pages/` directory and creates sidebar navigation.

- **`pages/1_Create_Assignments.py`** (Teacher workflow)
  - Input: Sentence/context text
  - Flow: Generate Q&A → Generate image → Save to DynamoDB + S3
  - Uses Bedrock models (text-to-text, text-to-image)
  - Stores to `assignments` table

- **`pages/2_Show_Assignments.py`** (Browse assignments)
  - Display existing assignments
  - View generated questions and images
  - Teacher management interface

- **`pages/3_Complete_Assignments.py`** (Student workflow)
  - Display assignments from DynamoDB
  - Student selects and answers questions
  - Calls Bedrock for embedding-based scoring (cosine similarity)
  - Saves scores to `answers` table with GSI for leaderboards

### Components

Reusable Python modules imported across pages.

- **`components/Parameter_store.py`**
  - Centralizes configuration (S3 bucket name, AWS region)
  - Single source of truth for app settings
  - Currently reads from hardcoded values; can be extended to fetch from AWS Parameter Store

- **`components/ui_template.py`**
  - Shared Streamlit UI helpers
  - `setup_page()`: Configures page metadata (title, icon, layout)
  - `hide_streamlit_chrome()`: Hides default Streamlit UI elements
  - `render_header()`: Renders consistent page headers
  - Used across all pages for consistent styling

## Configuration & Infrastructure Files

- **`Dockerfile`**: Container build recipe
  - Base: Python 3.9.18
  - Copies source files, installs dependencies
  - Runs Streamlit in headless mode on port 80

- **`requirements.txt`**: Python package dependencies
  - Pinned versions for reproducibility
  - Core: Streamlit, boto3, Pillow, scipy
  - Optional: SageMaker, AI21

- **`ecs-task.json`**: ECS Fargate task definition
  - Defines CPU (256), memory (512 MB)
  - Sets environment variables for runtime
  - Configures CloudWatch logging
  - Health check via curl to localhost

- **`streamlit/config.toml`**: Streamlit theme configuration
  - Color scheme, font, layout settings
  - Applied automatically to all pages

- **`.github/workflows/deploy.yaml`**: CI/CD pipeline
  - Triggered on push to main
  - Builds, pushes to ECR, deploys to ECS
  - Can be replaced with `quick-deploy.ps1` for manual deployments

## AWS & Deployment Scripts

- **`aws/setup-infrastructure.ps1`**: One-time infrastructure setup
  - Creates VPC, subnets, security groups
  - Creates ECR repository
  - Creates ECS cluster
  - Creates ALB and target groups
  - Outputs values for manual setup

- **`aws/create-iam-roles.ps1`**: IAM role and policy creation
  - Creates `ecsTaskExecutionRole` (for ECS agent)
  - Creates `ecsTaskRole` (for app code)
  - Attaches Bedrock, S3, DynamoDB policies

- **`quick-deploy.ps1`** / **`quick-deploy.sh`**: Deployment scripts
  - Build Docker image locally
  - Push to ECR
  - Register ECS task definition
  - Force new ECS deployment
  - Idempotent and safe to run multiple times

- **Policy files** (e.g., `ecs-s3-policy.json`, `bedrock-ecs-policy.json`)
  - Define IAM permissions for ECS tasks
  - Scoped to specific services (S3, Bedrock, DynamoDB)

## Data Storage

### DynamoDB Tables

- **`assignments`** (Teacher-created content)
  - PK: `id` (assignment ID)
  - Attributes: `teacher_id`, `prompt`, `question_answers`, `s3_image_name`
  - GSI: By teacher for quick retrieval

- **`answers`** (Student responses)
  - PK: `student_id` (partition key)
  - SK: `assignment_question_id` (sort key)
  - Attributes: `score`, timestamp, answer text
  - GSI: `assignment_question_id-index` for leaderboard queries

### S3 Bucket

- **Path**: `generated_images/{assignment_id}.png`
- Stores images generated by text-to-image model
- Referenced in `assignments` table as `s3_image_name`

## Naming Conventions

### Python Files
- **Main modules**: lowercase with underscores (e.g., `ui_template.py`, `Parameter_store.py`)
- **Page files**: Numbered for sort order (e.g., `1_Create_Assignments.py`)
- Consistent with Streamlit multi-page app conventions

### AWS Resources
- **Cluster**: `cloudage-cluster`
- **Service**: `cloudage-service`
- **Task family**: `cloudage-task`
- **Container name**: `cloudage-container`
- **ECR repo**: `cloudage-app`
- **ALB**: `cloudage-alb`
- **Security group**: `cloudage-sg`
- **Log group**: `/ecs/cloudage-task`

### Variables & Functions
- Bedrock model IDs: Stored in code, can be extracted to config
- Session state keys: Descriptive (e.g., `question_answers`, `generated_image_bytes`)
- Logger: Standard Python `logging` module

## Code Style & Patterns

### Streamlit Patterns
- `st.set_page_config()` always first (before other Streamlit calls)
- Session state for inter-page communication and persistence
- Callbacks for button handlers
- Error handling via `st.error()` and `st.stop()`

### AWS Integration
- boto3 clients initialized at module level (not inside functions)
- Error handling with `botocore.exceptions.ClientError`
- Logging with standard Python `logging` module

### Image Handling
- Images stored as bytes in session state (`BytesIO` objects)
- Conversion to/from base64 for API transport
- Cleanup of temporary files after S3 upload

## Dependencies & Imports

- **AWS**: `boto3`, `botocore`
- **UI**: `streamlit`
- **Image**: `PIL` (Pillow)
- **Math**: `numpy`, `scipy`
- **Standard library**: `json`, `logging`, `os`, `time`, `base64`

## Deployment Topology

```
Local Developer Machine
    ↓
    └─→ Docker build (./quick-deploy.ps1)
        ↓
        └─→ AWS ECR (push image)
            ↓
            └─→ AWS ECS Cluster
                ├─→ Fargate Task (Streamlit container)
                ├─→ DynamoDB (assignments, answers)
                ├─→ S3 (images)
                ├─→ Bedrock (AI models)
                └─→ ALB (public DNS) → Students/Teachers
```

## File Ownership & Responsibilities

| Component | Primary Owner | Purpose |
|-----------|---------------|---------|
| `Home.py`, `pages/*` | Frontend/Product | User-facing features |
| `components/*` | Shared Libraries | Reusable UI and config |
| `requirements.txt` | DevOps/Backend | Dependency management |
| `Dockerfile`, `quick-deploy.ps1` | DevOps | CI/CD and deployment |
| `aws/*` | DevOps/Infra | Infrastructure automation |
| `ecs-task.json` | DevOps | Container runtime config |
| `.github/workflows/` | DevOps | Automated pipeline |

## Extension Points

- **Add new pages**: Create `pages/N_PageName.py`
- **Add shared UI helpers**: Extend `components/ui_template.py`
- **Add configuration**: Extend `components/Parameter_store.py`
- **Change models**: Update model IDs in page files or config
- **Add AWS resources**: Extend `aws/setup-infrastructure.ps1`
