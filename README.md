# AWS FIS failover testing in a CI/CD pipeline

A CodePipeline pipeline deploys an ECS Fargate service, then uses AWS Fault Injection Service (FIS) to stop one task and checks that the service recovers.

Read `guide.md` for the full walkthrough (console first, then CloudFormation).

## Layout

```
guide.md                      the full walkthrough
cloudformation/
  01-base-stack.yaml          VPC, ALB, ECS service, source bucket, FIS experiment
  02-pipeline-stack.yaml      CodeBuild project, IAM roles, pipeline
pipeline-source/              the files that go inside source.zip
  imagedefinitions.json       image the Deploy stage rolls out
  buildspec/run-fis-experiment.yml
  scripts/run-fis-experiment.sh   starts the experiment and checks recovery
tools/                        helper scripts you run on your computer
  package-source.sh           builds source.zip and uploads it
  empty-bucket.sh             empties a versioned bucket before teardown
architecture/
  architecture.drawio         architecture diagram (open in draw.io)
```

## Deploy

```bash
aws cloudformation deploy --template-file cloudformation/01-base-stack.yaml \
  --stack-name fis-demo-base --capabilities CAPABILITY_NAMED_IAM

BUCKET=$(aws cloudformation describe-stacks --stack-name fis-demo-base \
  --query "Stacks[0].Outputs[?OutputKey=='SourceBucketName'].OutputValue" --output text)
./tools/package-source.sh "$BUCKET"

aws cloudformation deploy --template-file cloudformation/02-pipeline-stack.yaml \
  --stack-name fis-demo-pipeline --capabilities CAPABILITY_NAMED_IAM
```

## Tear down

See "Teardown for the automated approach" in `guide.md`. Delete the pipeline stack first.

## Cost

FIS is billed per action-minute. The Fargate tasks, the ALB and CodeBuild are billed while they run. Delete the stacks when you finish.
