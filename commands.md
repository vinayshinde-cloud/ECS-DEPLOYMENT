```
# One-command deploy (PowerShell)
.\quick-deploy.ps1

# One-command deploy (Git Bash / WSL)
chmod +x quick-deploy.sh
./quick-deploy.sh

# Register task definition (if ecs-task.json changed)
aws ecs register-task-definition --cli-input-json file://ecs-task.json --region us-east-1

# Roll out the new task definition
aws ecs update-service --cluster cloudage-cluster --service cloudage-service --task-definition cloudage-task --force-new-deployment --region us-east-1
aws ecs wait services-stable --cluster cloudage-cluster --services cloudage-service --region us-east-1

# Check ALB URL
Invoke-WebRequest -UseBasicParsing http://cloudage-alb-971379324.us-east-1.elb.amazonaws.com | Select -Expand Content | Out-Host
```

Proposed standard structure (non-breaking; migrate over time):

- app/
  - pages/
  - components/
  - assets/
- infra/
  - aws/
- docker/