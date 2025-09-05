# FortinetCloudCSE GitHub Actions ARC Runners in EKS

This repo provisions a complete GitHub Actions Runner Controller (ARC) setup on Amazon EKS, using External Secrets Operator (ESO) to source GitHub App credentials from AWS Secrets Manager. It also includes optional Cluster Autoscaler wiring and helpers to build/push a custom runner tools image.

## What’s Inside

- EKS cluster config and automation via `eksctl` and `Makefile`.
- External Secrets Operator (ESO) installed and configured with IRSA.
- AWS Secrets Manager used to store GitHub App credentials (App ID, Installation ID, PEM).
- ARC controller and an autoscaling runner scale set targeting a GitHub org.
- Optional Cluster Autoscaler IAM + deployment.

## Repo Layout

- `Makefile`: Orchestrates cluster creation, ESO/ARC install, IAM/IRSA, secrets, and runners.
- `eks/`: EKS cluster and ARC runners Helm values.
- `eso/`: Generated policy/trust and ExternalSecret templates (created/overwritten by `make`).
- `clustersecretstore-aws.yaml`: Generated reference for ESO store (also created by `make`).
- `container/`: Dockerfile and helper script for a runner image.

## Prerequisites

- CLI tools: `aws` (v2), `eksctl`, `kubectl`, `helm`, `docker`, `jq`, `yq`.
- AWS: An account with permissions for EKS, IAM (roles/policies), ECR, and Secrets Manager.
- Logged in to AWS (`aws sts get-caller-identity` works) and Docker.
- A GitHub App installed for your org with private key downloaded.

## Key Variables (overridable)

All variables have sensible defaults and can be overridden at invocation, for example: `make VAR=value target`.

- `AWS_REGION` (default `us-east-1`): Region for EKS/Secrets/ECR.
- `CLUSTER_NAME` (default `arc-eks`): EKS cluster name.
- `EKSCTL_CONFIG` (default `eks/arc-eks.yaml`): Cluster spec for `eksctl`.
- `ECR_REPO`: ECR repo name for the runner tools image.
- `IMAGE_TAG` (default `latest`): Tag for built image.
- `GITHUB_ORG`: GitHub organization to connect ARC to.
- `ESO_SECRET_NAME` (default `arc/github-ftntcldcse-arc-runner-app`): Name of the AWS Secrets Manager secret.
- `PEM_FILE`: Path to your GitHub App private key file.
- `IAM_ROLE_NAME`, `IAM_POLICY_NAME`: Names for ESO IRSA role and inline policy.
- `ARC_SYS_NS`, `ARC_RUNNERS_NS`: ARC controller and runners namespaces.
- `RUNNER_SET_NAME`, `RUNNER_GROUP_NAME`: Runner scale set name and group label.
- `ACCOUNT_ID`: AWS Account ID; defaults to `aws sts get-caller-identity` but can be overridden, e.g. `make ACCOUNT_ID=123456789012 ...`.

## Secrets Manager Data Model

The repo stores a single JSON secret in Secrets Manager with keys:

- `github_app_id`: GitHub App ID
- `github_app_installation_id`: Installation ID
- `github_app_private_key`: Entire PEM contents

The Makefile prepares this JSON using values from `gh-app-info` (for `AppID` and `InstallationID`) and your PEM file.

## Quick Start (Everything)

1) Prepare inputs

- Create a `gh-app-info` file with your GitHub App IDs:

  ```bash
  cat > gh-app-info <<'EOF'
  AppID: "123456"
  InstallationID: "7890123"
  EOF
  ```

- Place your GitHub App private key PEM file at the path used by `PEM_FILE` (default example: `arc-org-runners.2025-08-29.private-key.pem`).

2) Provision and deploy

- One-shot install of cluster, ESO + IRSA, secret, ARC, and runners:

  ```bash
  make ACCOUNT_ID=123456789012 up
  ```

This will:

- Create the EKS cluster from `eks/arc-eks.yaml`.
- Build and push the runner image to ECR.
- Install ESO and create IAM role/policy via IRSA.
- Upsert the GitHub App secret in Secrets Manager.
- Create an ExternalSecret that materializes a `arc-github-app` Kubernetes Secret.
- Install the ARC controller and apply runner scale set.

When complete, runners should register to your org `https://github.com/${GITHUB_ORG}`.

## Make Targets (Common)

- `up`: Full flow (cluster → image → ESO+IRSA → secret → ARC → runners).
- `down`: Delete the EKS cluster (leaves IAM and Secrets Manager intact).
- `cluster-create`: Create EKS cluster via `eksctl`.
- `ecr-login`, `image-build`, `image-push`: ECR auth + build and push image.
- `eso-install`: Install External Secrets Operator and wait for CRDs.
- `eso-iam-create`: Create/refresh IAM role + inline policy for ESO (IRSA).
- `eso-annotate-sa`: Annotate ESO service account with the IRSA role ARN.
- `eso-apply-store`: Apply the ClusterSecretStore and wait for ESO deployments.
- `sm-upsert`: Upsert the Secrets Manager JSON from `gh-app-info` + `PEM_FILE`.
- `sm-validate`: Validate the stored JSON and show PEM header/footer.
- `externalsecret-apply`: Generate/apply ExternalSecret to create `arc-github-app`.
- `arc-install`: Install ARC controller via Helm and wait for readiness.
- `arc-crds-apply`: Ensure ARC CRDs exist/are established.
- `wait-arc-secret`: Wait until `arc-github-app` Secret exists in runners namespace.
- `arc-runners-apply`: Apply runner scale set using `eks/arc-runners.values.yaml`.
- `ca-iam-create`: Optional Cluster Autoscaler policy + IRSA service account.
- `ca-deploy`: Deploy Cluster Autoscaler at the pinned version.

## Typical Step-By-Step (Manual)

If you prefer to run steps explicitly:

```bash
make prereqs
make cluster-create
make ecr-login image-build image-push
make ACCOUNT_ID=123456789012 eso-install eso-iam-create eso-annotate-sa eso-apply-store
make sm-upsert sm-validate
make externalsecret-apply
make arc-install arc-crds-apply wait-arc-secret arc-runners-apply
# Optional autoscaler
make ACCOUNT_ID=123456789012 ca-iam-create
make ca-deploy
```

## Clean Up

- Soft reset (remove ARC/ESO/runners, keep cluster):

  ```bash
  make cluster-reset-soft
  ```

- Full delete cluster (IAM and Secrets Manager left intact):

  ```bash
  make down
  ```

- Hard reset (delete + recreate cluster from `EKSCTL_CONFIG`):

  ```bash
  make cluster-reset CONFIRM=yes
  ```

## Notes & Tips

- Overriding `ACCOUNT_ID` ensures generated ESO IAM policy/trust and annotations target the intended account.
- Files under `eso/` and `clustersecretstore-aws.yaml` are generated or overwritten by Make targets.
- Ensure `aws` default region matches `AWS_REGION` or pass `AWS_REGION=...` to Make.
- If `sm-validate` complains about the PEM format, re-check the secret contents and quoting.
- The GitHub App needs **Repository** Actions:Read-only and Metadata:Read-only and **Organization** Self-hosted runners: Read and write permissions.
- When you configure GitHub Actions workflows, ensure 'runs-on' is set to whatever you've specified as **RUNNER_SET_NAME** in the Makefile. 

For day‑to‑day, `make up` is the fastest path from empty to functional ARC runners on EKS. Adjust variables as needed per environment.

