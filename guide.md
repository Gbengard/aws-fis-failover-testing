---
title: Test failover in your CI/CD pipeline with AWS Fault Injection Service
published: false
tags: aws, devops, cicd, chaosengineering
---

## Introduction

When a task in an ECS service stops, ECS starts a new one by itself. You do not have to do anything. The load balancer then sends traffic to the new task when it is healthy.

That is the design. But a design is a claim until you test it. These things can still go wrong:

- The new task cannot start. For example, the image cannot be pulled or a setting is missing.
- The new task starts but never passes the load balancer health check.
- The service recovers, but it takes longer than you can accept.
- The service runs only one task, so users see an outage while the replacement starts.

Most teams find these problems during a real outage. In this guide, you find them on every release instead.

You build a pipeline that does this:

1. It deploys the service.
2. It uses AWS Fault Injection Service (FIS) to stop one running task on purpose.
3. It waits, then checks that the service is back to its desired task count and that the load balancer shows all targets healthy.
4. If recovery takes longer than the time you set, the stage fails.

You will build it twice. First by hand in the AWS console, so you see every part. Then with two CloudFormation stacks.

The demo service runs plain nginx, so the test will pass. The demo shows how the pieces work. The test becomes useful when you point it at a real service.

What this test proves: the service recovers from a lost task within a time limit that you choose. What it does not prove: zero failed requests during the failure. It does not send traffic while the task is down.

## Architecture

![Architecture diagram](./architecture/architecture.png)

- An S3 bucket holds `source.zip`. A change to this file starts the pipeline.
- CodePipeline has three stages: Source, Deploy, FailoverTest.
- The Deploy stage updates the ECS service.
- The FailoverTest stage runs a CodeBuild project. It starts the FIS experiment and checks recovery.
- The FIS experiment stops one task of `fis-demo-service`.
- A CloudWatch alarm watches the number of healthy targets. It is the experiment's stop condition.

The service runs 2 tasks. The experiment stops 1 of them, so one task stays up while ECS replaces the other.

## How the pieces fit

**Deploy and FailoverTest are two different jobs.** The Deploy stage is a normal release. It puts the new version on ECS. The FailoverTest stage runs after it and asks one question: does the service still recover if a task dies? It works like an integration test that runs after a deploy.

**What FIS does.** FIS is the tool that breaks the task. It stops one task and only one, because the target is set to select a count of 1. It uses its own IAM role, which can only stop tasks in this cluster, so the pipeline does not need broad ECS permissions to break things. It also keeps a record of each experiment.

You could stop a task with `aws ecs stop-task` and get the same failure. FIS adds the limited role, the record, and the stop condition. FIS is worth more with faults that run over time, such as CPU stress or network delay, because a stop condition can halt those. For this one action, the stop-condition alarm cannot undo a stopped task. The real safety control is the count of 1.

**Why CodeBuild is in the pipeline.** At the time of writing, I found no built-in CodePipeline action that starts a FIS experiment. So the FailoverTest stage runs a CodeBuild project, and CodeBuild runs a script. CodeBuild does not break anything itself. It gives the script a place to run, and it turns the result into pass or fail for the pipeline.

**What the script does.** CodeBuild reads `buildspec/run-fis-experiment.yml` from `source.zip`. That file runs `scripts/run-fis-experiment.sh`. The script has four steps. It exits with an error if any step fails.

1. Check before. It asks ECS how many tasks are running and asks the load balancer how many targets are healthy. Both must equal the desired count. If not, it stops. A service that was already broken should not be blamed on the test.
2. Start. It runs `aws fis start-experiment` with the experiment template ID. FIS stops one task.
3. Wait for the experiment. It checks the status every 10 seconds until the experiment is `completed`. If the status is `stopped`, `failed` or `cancelled`, or it takes more than 300 seconds, the script fails.
4. Wait for recovery. It keeps checking running tasks and healthy targets until both match the desired count again. If this takes longer than `RECOVERY_TIMEOUT` (300 seconds by default), the script fails. Otherwise it prints `The service recovered. Test passed.`

The script gets the template ID, cluster name, service name and target group ARN from environment variables on the CodeBuild project.

**When it runs.** The test runs on every pipeline run, after the Deploy stage succeeds. If Deploy fails, the test does not run. In this demo, a new `source.zip` in the S3 bucket starts the pipeline. In real use, point the test at a staging environment first. Stopping a task in production on every release is a decision your team should make on purpose.

## Before you start

You need:

- An AWS account and permission to create the resources below.
- AWS CLI v2 on your computer, signed in to your account.
- `zip` on your computer.
- A Region where FIS, ECS Fargate, CodePipeline and CodeBuild are available. Use the same Region for every step.

Cost: FIS charges per action-minute. At the time of writing, the price is $0.10 per action-minute. You also pay for the Fargate tasks, the load balancer and CodeBuild while they run. Delete everything when you finish (see Teardown).

Use these names exactly. The scripts and templates depend on them.

| Resource | Name |
|---|---|
| ECS cluster | `fis-demo-cluster` |
| ECS service | `fis-demo-service` |
| Task definition family | `fis-demo-task` |
| Container | `web` |
| Application Load Balancer | `fis-demo-alb` |
| Target group | `fis-demo-tg` |
| ALB security group | `fis-demo-alb-sg` |
| Task security group | `fis-demo-task-sg` |
| CloudWatch alarm | `fis-demo-no-healthy-hosts` |
| FIS IAM role | `fis-demo-experiment-role` |
| FIS experiment template name | `fis-demo-stop-one-task` |
| Source bucket | `fis-demo-source-<ACCOUNT_ID>-<REGION>` |
| CodeBuild project | `fis-demo-failover-test` |
| CodeBuild IAM role | `fis-demo-codebuild-role` |
| Pipeline | `fis-demo-pipeline` |

Get the code:

```bash
git clone https://github.com/Gbengard/aws-fis-failover-testing.git
cd aws-fis-failover-testing
```

## Manual approach in the AWS console

The manual path uses the default VPC. The CloudFormation path creates its own VPC.

### Part 1. Build the service

**Step 1. Create the security groups.**

1. Open the EC2 console. In the left menu, choose **Security Groups**, then choose **Create security group**.
2. Security group name: `fis-demo-alb-sg`. Description: `ALB for the FIS demo`. VPC: the default VPC.
3. Under **Inbound rules**, choose **Add rule**. Type: **HTTP**. Source: **Anywhere-IPv4**.
4. Choose **Create security group**.
5. Choose **Create security group** again. Name: `fis-demo-task-sg`. Description: `Tasks for the FIS demo`. VPC: the default VPC.
6. Under **Inbound rules**, choose **Add rule**. Type: **HTTP**. Source: **Custom**, then pick `fis-demo-alb-sg`.
7. Choose **Create security group**.

**Step 2. Create the target group.**

1. In the EC2 console, choose **Target Groups**, then **Create target group**.
2. Target type: **IP addresses**. Target group name: `fis-demo-tg`. Protocol: **HTTP**. Port: `80`. VPC: the default VPC.
3. Under **Health checks**, keep the path as `/`.
4. Choose **Next**. Do not register any targets. Choose **Create target group**.

**Step 3. Create the load balancer.**

1. In the EC2 console, choose **Load Balancers**, then **Create load balancer**.
2. Under **Application Load Balancer**, choose **Create**.
3. Load balancer name: `fis-demo-alb`. Scheme: **Internet-facing**. VPC: the default VPC.
4. Under **Mappings**, select at least two Availability Zones.
5. Under **Security groups**, remove the default group and select `fis-demo-alb-sg`.
6. Under **Listeners and routing**, keep **HTTP** and port `80`. For **Default action**, select `fis-demo-tg`.
7. Choose **Create load balancer**.

**Step 4. Create the cluster.**

1. Open the ECS console. Choose **Clusters**, then **Create cluster**.
2. Cluster name: `fis-demo-cluster`. Keep **AWS Fargate (serverless)** selected.
3. Choose **Create**.

**Step 5. Create the task definition.**

1. In the ECS console, choose **Task definitions**, then **Create new task definition**.
2. Task definition family: `fis-demo-task`. Launch type: **AWS Fargate**. CPU: **.25 vCPU**. Memory: **.5 GB**.
3. Task execution role: choose `ecsTaskExecutionRole`. If it is not in the list, choose **Create new role**.
4. Under **Container - 1**, set Name: `web`. Image URI: `public.ecr.aws/docker/library/nginx:latest`. Container port: `80`. Protocol: **TCP**.
5. Choose **Create**.

**Step 6. Create the service.**

1. Open `fis-demo-cluster`. On the **Services** tab, choose **Create**.
2. Under **Compute options**, choose **Launch type**, then **FARGATE**.
3. Under **Deployment configuration**, set Family: `fis-demo-task` (latest revision). Service name: `fis-demo-service`. Desired tasks: `2`.
4. Under **Networking**, keep the default VPC and subnets. Remove the default security group and select `fis-demo-task-sg`. Turn **Public IP** on.
5. Under **Load balancing**, choose **Application Load Balancer**. Choose **Use an existing load balancer** and select `fis-demo-alb`.
6. For the container, choose `web 80:80`. Choose **Use an existing listener** (`HTTP:80`) and **Use an existing target group** (`fis-demo-tg`).
7. Choose **Create**.

**Step 7. Check the service.**

1. Wait until the service shows 2 running tasks.
2. In the EC2 console, open `fis-demo-tg`. On the **Targets** tab, wait until both targets are **healthy**.
3. Open the ALB DNS name in your browser. You should see the nginx welcome page.

### Part 2. Add the FIS experiment

**Step 8. Create the CloudWatch alarm.**

1. Open the CloudWatch console. Choose **Alarms**, then **All alarms**, then **Create alarm**.
2. Choose **Select metric**. Choose **ApplicationELB**, then **Per AppELB, per TG Metrics**.
3. Select **HealthyHostCount** for `fis-demo-tg`. Choose **Select metric**.
4. Statistic: **Minimum**. Period: **1 minute**.
5. Conditions: **Static**, **Lower**, than `1`. Choose **Next**.
6. Remove any notification action. Choose **Next**.
7. Alarm name: `fis-demo-no-healthy-hosts`. Choose **Next**, then **Create alarm**.

**Step 9. Create the IAM role for FIS.**

1. Open the IAM console. Choose **Roles**, then **Create role**.
2. Trusted entity type: **Custom trust policy**. Paste this:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "fis.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

3. Choose **Next**. Do not attach any policy. Choose **Next**.
4. Role name: `fis-demo-experiment-role`. Choose **Create role**.
5. Open the role. Choose **Add permissions**, then **Create inline policy**. Choose the **JSON** tab and paste this. Replace `<ACCOUNT_ID>` and `<REGION>`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ecs:DescribeTasks", "ecs:ListTasks", "tag:GetResources"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "ecs:StopTask",
      "Resource": "*",
      "Condition": {
        "ArnEquals": {
          "ecs:cluster": "arn:aws:ecs:<REGION>:<ACCOUNT_ID>:cluster/fis-demo-cluster"
        }
      }
    }
  ]
}
```

6. Choose **Next**. Policy name: `fis-demo-stop-task`. Choose **Create policy**.

**Step 10. Create the experiment template.**

1. Open the FIS console. Choose **Experiment templates**, then **Create experiment template**.
2. Description: `Stop one running task of the demo ECS service`. Name: `fis-demo-stop-one-task`.
3. Under **Actions**, choose **Add action**. Name: `StopOneTask`. Action type: `aws:ecs:stop-task`. Choose **Save**.
4. Under **Targets**, edit the target that FIS created for the action. Name: `OneTask`. Resource type: `aws:ecs:task`.
5. Set the target to use resource parameters: `cluster` = `fis-demo-cluster` and `service` = `fis-demo-service`.
6. Selection mode: **Count**. Number of resources: `1`. Choose **Save**.
7. Under **Service access**, choose **Use an existing IAM role** and select `fis-demo-experiment-role`.
8. Under **Stop conditions**, select the alarm `fis-demo-no-healthy-hosts`.
9. Choose **Create experiment template**. Type `create` when asked, then choose **Create experiment template**.

**Step 11. Run the experiment by hand.**

1. Open the template. Choose **Start experiment**. Type `start` when asked, then choose **Start experiment**.
2. Watch the experiment state change until it shows **Completed**.
3. In the ECS console, open `fis-demo-service`. On the **Tasks** tab, you see one task stopped and a new task starting.
4. In the target group, wait until both targets are **healthy** again.

The service recovered. Now put this check into a pipeline.

### Part 3. Add the pipeline

**Step 12. Create the source bucket.**

1. Open the S3 console. Choose **Create bucket**.
2. Bucket name: `fis-demo-source-<ACCOUNT_ID>-<REGION>`.
3. Under **Bucket Versioning**, choose **Enable**.
4. Choose **Create bucket**.

**Step 13. Upload the source.**

From the repo folder, run:

```bash
./tools/package-source.sh fis-demo-source-<ACCOUNT_ID>-<REGION>
```

This builds `source.zip` and uploads it. The zip has three files: `imagedefinitions.json`, `buildspec/run-fis-experiment.yml` and `scripts/run-fis-experiment.sh`.

**Step 14. Create the CodeBuild project.**

1. Open the CodeBuild console. Choose **Create project**.
2. Project name: `fis-demo-failover-test`.
3. Source provider: **AWS CodePipeline**.
4. Environment: **Managed image**. Use the latest Standard image that the console offers for Ubuntu.
5. Service role: **New service role**. Role name: `fis-demo-codebuild-role`.
6. Under **Buildspec**, choose **Use a buildspec file**. Buildspec name: `buildspec/run-fis-experiment.yml`.
7. Under **Additional configuration**, add four environment variables (type **Plaintext**):
   - `TEMPLATE_ID`: the experiment template ID from the FIS console.
   - `CLUSTER_NAME`: `fis-demo-cluster`
   - `SERVICE_NAME`: `fis-demo-service`
   - `TARGET_GROUP_ARN`: the ARN of `fis-demo-tg`.
8. Choose **Create build project**.

**Step 15. Give CodeBuild permission to run FIS.**

1. In the IAM console, open `fis-demo-codebuild-role`. Choose **Add permissions**, then **Create inline policy**, then the **JSON** tab.
2. Paste this. Replace the placeholders.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "fis:StartExperiment",
      "Resource": [
        "arn:aws:fis:<REGION>:<ACCOUNT_ID>:experiment-template/<TEMPLATE_ID>",
        "arn:aws:fis:<REGION>:<ACCOUNT_ID>:experiment/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": "fis:GetExperiment",
      "Resource": "arn:aws:fis:<REGION>:<ACCOUNT_ID>:experiment/*"
    },
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/fis-demo-experiment-role",
      "Condition": {
        "StringEquals": { "iam:PassedToService": "fis.amazonaws.com" }
      }
    },
    {
      "Effect": "Allow",
      "Action": "ecs:DescribeServices",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "elasticloadbalancing:DescribeTargetHealth",
      "Resource": "*"
    }
  ]
}
```

3. Choose **Next**. Policy name: `fis-demo-fis-access`. Choose **Create policy**.

**Step 16. Create the pipeline.**

1. Open the CodePipeline console. Choose **Create pipeline**. Choose the option to build a custom pipeline, then **Next**.
2. Pipeline name: `fis-demo-pipeline`. Service role: **New service role**. Choose **Next**.
3. Source provider: **Amazon S3**. Bucket: your source bucket. S3 object key: `source.zip`. Output artifact format: **CodePipeline default**. Choose **Next**.
4. Skip the build stage. Choose **Skip build stage**.
5. Deploy provider: **Amazon ECS**. Cluster name: `fis-demo-cluster`. Service name: `fis-demo-service`. Image definitions file: `imagedefinitions.json`. Choose **Next**, then **Create pipeline**.
6. The new service role needs ECS and PassRole permissions. If the Deploy stage fails with access denied, add the permissions shown in `cloudformation/02-pipeline-stack.yaml` to the pipeline role.
7. Choose **Edit**. After the Deploy stage, choose **Add stage**. Stage name: `FailoverTest`. Choose **Add action group**.
8. Action name: `RunFisExperiment`. Action provider: **AWS CodeBuild**. Input artifacts: `SourceArtifact`. Project name: `fis-demo-failover-test`. Choose **Done**, then **Save**.

**Step 17. Run it.**

1. Choose **Release change** on the pipeline.
2. Watch the three stages. When FailoverTest succeeds, open the build logs. You should see the line `The service recovered. Test passed.`

## Teardown for the manual approach

Delete in this order:

1. CodePipeline: choose `fis-demo-pipeline`, then **Delete pipeline**.
2. CodeBuild: choose `fis-demo-failover-test`, then **Delete build project**.
3. ECS: open `fis-demo-cluster`, choose `fis-demo-service`, then **Delete service**. Turn on **Force delete** if asked. Then choose **Delete cluster**.
4. EC2: delete the load balancer `fis-demo-alb`, then the target group `fis-demo-tg`, then the security groups `fis-demo-task-sg` and `fis-demo-alb-sg`.
5. FIS: delete the experiment template `fis-demo-stop-one-task`.
6. CloudWatch: delete the alarm `fis-demo-no-healthy-hosts`.
7. IAM: delete `fis-demo-experiment-role`, `fis-demo-codebuild-role`, and the roles that the pipeline and the console created.
8. S3: empty and delete the source bucket and the pipeline artifact bucket. The source bucket is versioned, so use `./tools/empty-bucket.sh <bucket-name>` first.
9. ECS: deregister the task definition `fis-demo-task`.

Do this before you start the automated approach. Both approaches use the same resource names, so leftover resources will cause name conflicts.

## Automated approach with CloudFormation

The automated path uses two stacks. The pipeline stack must wait, because the pipeline needs `source.zip` in the source bucket when it is created. That upload is a manual step, so it sits between the two stacks.

Template `01-base-stack.yaml` creates the VPC, the ALB, the ECS service, the source bucket, and the FIS parts: the alarm, the IAM role and the experiment template.

Template `02-pipeline-stack.yaml` creates the artifact bucket, the CodeBuild project, the IAM roles and the pipeline.

**Step 1. Deploy the base stack.**

```bash
aws cloudformation deploy \
  --template-file cloudformation/01-base-stack.yaml \
  --stack-name fis-demo-base \
  --capabilities CAPABILITY_NAMED_IAM
```

When it finishes, print the outputs:

```bash
aws cloudformation describe-stacks --stack-name fis-demo-base \
  --query "Stacks[0].Outputs" --output table
```

Open `AlbUrl` in your browser. You should see the nginx welcome page.

**Step 2. Upload the source.**

```bash
BUCKET=$(aws cloudformation describe-stacks --stack-name fis-demo-base \
  --query "Stacks[0].Outputs[?OutputKey=='SourceBucketName'].OutputValue" --output text)
./tools/package-source.sh "$BUCKET"
```

**Step 3. Deploy the pipeline stack.**

```bash
aws cloudformation deploy \
  --template-file cloudformation/02-pipeline-stack.yaml \
  --stack-name fis-demo-pipeline \
  --capabilities CAPABILITY_NAMED_IAM
```

The pipeline starts by itself. In the CodePipeline console, open `fis-demo-pipeline` and watch the stages. When FailoverTest succeeds, open the CodeBuild logs. You should see `The service recovered. Test passed.`

**Step 4. See what the test does.**

In the CodeBuild log, find these lines in order: the health check before the test, the experiment ID, the experiment status changing to `completed`, and the `desired`, `running` and `healthy_targets` numbers rising back to match.

To change how long the test waits for recovery, set the environment variable `RECOVERY_TIMEOUT` (in seconds) on the CodeBuild project. The default is 300. This is your real pass or fail line.

## Teardown for the automated approach

Delete the pipeline stack first. The base stack exports values that it uses.

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region)

aws s3 rm "s3://fis-demo-artifacts-${ACCOUNT}-${REGION}" --recursive
aws cloudformation delete-stack --stack-name fis-demo-pipeline
aws cloudformation wait stack-delete-complete --stack-name fis-demo-pipeline

./tools/empty-bucket.sh "fis-demo-source-${ACCOUNT}-${REGION}"
aws cloudformation delete-stack --stack-name fis-demo-base
aws cloudformation wait stack-delete-complete --stack-name fis-demo-base
```

## Troubleshooting

**The experiment fails right after it starts.**
FIS picks targets when the experiment starts. If it finds no matching tasks, the experiment fails. Check that the service has running tasks and that the cluster and service names in the target are exact.

**The experiment stops with an access error on `ecs:StopTask`.**
The FIS role needs `ecs:StopTask`. In the policy, the `ecs:cluster` condition must match your cluster ARN. To check if the condition is the cause, remove it and run the experiment again.

**The Source stage fails.**
The pipeline reads `source.zip` from the source bucket. Check that the file is there and that versioning is on for the bucket.

**FailoverTest fails with "The service is not healthy before the test."**
The script checks the service before it breaks anything. Wait until the Deploy stage has finished and both targets are healthy, then run the stage again.

**FailoverTest fails with "did not recover".**
Recovery took longer than `RECOVERY_TIMEOUT`. Open the ECS service events and the target group health to see why. Raise the timeout only if the longer time is acceptable for your service.

**The stack delete fails with "bucket is not empty".**
Run `./tools/empty-bucket.sh <bucket-name>` for the source bucket, or `aws s3 rm --recursive` for the artifact bucket, and delete again.

**The base stack delete fails because an export is in use.**
Delete the `fis-demo-pipeline` stack first.

## Conclusion

You now have a pipeline that breaks one task on purpose and checks that the service comes back. The test is small, but it turns a design claim into a check that runs on every release.

The full code is in the repo: https://github.com/Gbengard/aws-fis-failover-testing
