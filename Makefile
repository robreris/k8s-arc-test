# ============
# Config
# ============
AWS_REGION            ?= us-east-1
CLUSTER_NAME          ?= arc-eks
EKSCTL_CONFIG         ?= eks/arc-eks.yaml

# Namespaces
ESO_NS                ?= external-secrets
ARC_SYS_NS            ?= arc-systems
ARC_RUNNERS_NS        ?= actions-runner-system
ARC_CONTROLLER_SA     ?= arc-ga-rs-controller

# ECR (pre-existing repo). Example: ECR_REPO=arc-runner-tools
ECR_REPO              ?= fortinetcloudcse-arc-runner-image
IMAGE_TAG             ?= latest
CONTEXT_DIR           ?= container
DOCKERFILE            ?= $(CONTEXT_DIR)/Dockerfile

# GitHub org + GitHub App identifiers (from your App)
GITHUB_ORG            ?= FortinetCloudCSE
GITHUB_APP_ID         := $(shell yq -r '.AppID' gh-app-info) 
GITHUB_APP_INSTALLATION_ID := $(shell yq -r '.InstallationID' gh-app-info)

# Runners
RUNNER_SET_NAME ?= org-runners
ARC_VALUES_FILE ?= eks/arc-runners.values.yaml

# Secrets Manager (single JSON secret with 3 keys)
ESO_SECRET_NAME       ?= arc/github-ftntcldcse-arc-runner-app
PEM_FILE              ?= arc-org-runners.2025-08-29.private-key.pem

# IAM for External Secrets Operator (IRSA)
IAM_ROLE_NAME         ?= ESOSecretsManagerRole
IAM_POLICY_NAME       ?= ESOSecretsManagerInline

# Files we’ll generate into eso/
ESO_POLICY_FILE       ?= eso/eso-secretsmanager-policy.json
ESO_TRUST_FILE        ?= eso/eso-trust.json
CLUSTER_SECRETSTORE   ?= clustersecretstore-aws.yaml
EXTERNALSECRET_FILE   ?= eso/externalsecret-arc-github-app.yaml

# Derived
ACCOUNT_ID            := $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
ECR_REGISTRY          := $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
IMAGE_URI             := $(ECR_REGISTRY)/$(ECR_REPO):$(IMAGE_TAG)
OIDC_ISSUER           := $(shell aws eks describe-cluster --name $(CLUSTER_NAME) --region $(AWS_REGION) --query "cluster.identity.oidc.issuer" --output text 2>/dev/null)
OIDC_PROVIDER         := $(shell echo $(OIDC_ISSUER) | sed -e 's~^https://~~')
SECRET_ARN_PREFIX     := arn:aws:secretsmanager:$(AWS_REGION):$(ACCOUNT_ID):secret:$(ESO_SECRET_NAME)

# Utility to guard required vars
define guard
	@ if [ -z "$($1)" ]; then echo ">>> Missing required variable: $1"; exit 1; fi
endef

# ============
# High-level
# ============
.PHONY: help up down cluster-create image-build image-push ecr-login \
        eso-install eso-iam-create eso-annotate-sa eso-apply-store \
        sm-upsert externalsecret-apply arc-install arc-crds-apply arc-runners-apply \
        prereqs

help:
	@echo "Targets:"
	@echo "  make up            - Create cluster, build/push image, install ESO + IRSA, store secrets, install ARC, apply runner set"
	@echo "  make down          - Delete cluster (leaves IAM + Secrets Manager intact)"
	@echo "  make cluster-create"
	@echo "  make image-build image-push"
	@echo "  make eso-install eso-iam-create eso-annotate-sa eso-apply-store"
	@echo "  make sm-upsert     - Create/Update Secrets Manager JSON for GitHub App"
	@echo "  make externalsecret-apply"
	@echo "  make arc-install arc-runners-apply"

up: prereqs cluster-create ecr-login image-build image-push \
    eso-install eso-iam-create eso-annotate-sa eso-apply-store \
    sm-upsert externalsecret-apply arc-install arc-runners-apply
	@echo "✓ All done. Your ARC runners should register to https://github.com/$(GITHUB_ORG)"

down:
	@for STACK_NAME in $(aws cloudformation describe-stacks --query "Stacks[?Tags[?Key=='alpha.eksctl.io/cluster-name' && Value=='$$CLUSTER_NAME']].StackName" --output text); do aws cloudformation delete-stack --stack-name "$$STACK_NAME" --region "$$AWS_REGION"; done
	eksctl delete cluster -f $(EKSCTL_CONFIG)

# ============
# Step: cluster
# ============
cluster-create:
	@test -f "$(EKSCTL_CONFIG)" || (echo "Missing $(EKSCTL_CONFIG)"; exit 1)
	eksctl create cluster -f $(EKSCTL_CONFIG)
	@echo "✓ Cluster created."
	@echo "OIDC issuer: $(OIDC_ISSUER)"
        
get-cluster-oidc:
	@echo "OIDC issuer: $(OIDC_ISSUER)"

# ============
# Step: image
# ============
ecr-login:
	$(call guard,ECR_REPO)
	@echo "Logging in to ECR: $(ECR_REGISTRY)"
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(ECR_REGISTRY)

image-build:
	$(call guard,ECR_REPO)
	@test -f "$(DOCKERFILE)" || (echo "Missing $(DOCKERFILE)"; exit 1)
	docker build -t $(IMAGE_URI) -f $(DOCKERFILE) $(CONTEXT_DIR)
	@echo "✓ Built image: $(IMAGE_URI)"

image-push:
	$(call guard,ECR_REPO)
	docker push $(IMAGE_URI)
	@echo "✓ Pushed image: $(IMAGE_URI)"

# ============
# Step: ESO (External Secrets Operator)
# ============
eso-install:
	helm repo add external-secrets https://charts.external-secrets.io >/dev/null
	helm repo update >/dev/null
	helm upgrade --install external-secrets external-secrets/external-secrets \
	  -n $(ESO_NS) --create-namespace --set installCRDs=true
	@echo "✓ ESO installed in namespace $(ESO_NS)."

# Create IAM role & inline policy for ESO via IRSA
eso-iam-create: eso-policy-file eso-trust-file
	$(call guard,ACCOUNT_ID)
	$(call guard,OIDC_PROVIDER)
	@echo "Creating/Updating IAM role $(IAM_ROLE_NAME) for ESO IRSA..."
	@aws iam get-role --role-name $(IAM_ROLE_NAME) >/dev/null 2>&1 || \
	  aws iam create-role --role-name $(IAM_ROLE_NAME) \
	    --assume-role-policy-document file://$(ESO_TRUST_FILE)
	@aws iam update-assume-role-policy --role-name $(IAM_ROLE_NAME) \
	    --policy-document file://$(ESO_TRUST_FILE) >/dev/null
	@aws iam put-role-policy --role-name $(IAM_ROLE_NAME) \
	  --policy-name $(IAM_POLICY_NAME) \
	  --policy-document file://$(ESO_POLICY_FILE)
	@echo "✓ IAM role ready: arn:aws:iam::$(ACCOUNT_ID):role/$(IAM_ROLE_NAME)"

eso-annotate-sa:
	@echo "Annotating ESO service account with IRSA role..."
	kubectl annotate sa external-secrets -n $(ESO_NS) \
	  eks.amazonaws.com/role-arn=arn:aws:iam::$(ACCOUNT_ID):role/$(IAM_ROLE_NAME) --overwrite
	@echo "✓ Annotated SA."

eso-apply-store:
	@test -f "$(CLUSTER_SECRETSTORE)" || (echo "Missing $(CLUSTER_SECRETSTORE)"; exit 1)
	kubectl apply -f $(CLUSTER_SECRETSTORE)
	@echo "✓ ClusterSecretStore applied."

# Files (policy & trust) used above
eso-policy-file:
	@mkdir -p eso
	@echo "Generating $(ESO_POLICY_FILE) for secret $(ESO_SECRET_NAME) in $(AWS_REGION)..."
	@printf '%s\n' \
	'{' \
	'  "Version": "2012-10-17",' \
	'  "Statement": [{' \
	'    "Effect": "Allow",' \
	'    "Action": ["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],' \
	'    "Resource": "$(SECRET_ARN_PREFIX)*"' \
	'  }]' \
	'}' > $(ESO_POLICY_FILE)
	@echo "✓ Wrote $(ESO_POLICY_FILE)"

eso-trust-file:
	$(call guard,OIDC_PROVIDER)
	@mkdir -p eso
	@echo "Generating $(ESO_TRUST_FILE) trusting $(OIDC_PROVIDER) for SA $(ESO_NS)/external-secrets..."
	@printf '%s\n' \
	'{' \
	'  "Version": "2012-10-17",' \
	'  "Statement": [{' \
	'    "Effect": "Allow",' \
	'    "Principal": { "Federated": "arn:aws:iam::$(ACCOUNT_ID):oidc-provider/$(OIDC_PROVIDER)" },' \
	'    "Action": "sts:AssumeRoleWithWebIdentity",' \
	'    "Condition": {' \
	'      "StringEquals": { "$(OIDC_PROVIDER):sub": "system:serviceaccount:$(ESO_NS):external-secrets" }' \
	'    }' \
	'  }]' \
	'}' > $(ESO_TRUST_FILE)
	@echo "✓ Wrote $(ESO_TRUST_FILE)"

# ============
# Step: Secrets Manager (store your GitHub App creds)
# ============
sm-upsert:
	$(call guard,GITHUB_APP_ID)
	$(call guard,GITHUB_APP_INSTALLATION_ID)
	@test -f "$(PEM_FILE)" || (echo "Missing $(PEM_FILE)"; exit 1)
	@echo "Preparing JSON payload for Secrets Manager..."
	@PEM_ESCAPED=$$(sed ':a;N;$$!ba;s/\n/\\n/g' $(PEM_FILE));
	@printf '%s\n' \
        '{' \
	'  "github_app_id": "$(GITHUB_APP_ID)",' \
	'  "github_app_installation_id": "$(GITHUB_APP_INSTALLATION_ID)",' \
	'  "github_app_private_key": "$$PEM_ESCAPED"' \
	'}' > /tmp/github-app.json 
	@echo "Upserting secret $(ESO_SECRET_NAME) in Secrets Manager..."
	@aws secretsmanager describe-secret --region $(AWS_REGION) --secret-id "$(ESO_SECRET_NAME)" >/dev/null 2>&1 && \
	  aws secretsmanager put-secret-value --region $(AWS_REGION) --secret-id "$(ESO_SECRET_NAME)" --secret-string file:///tmp/github-app.json >/dev/null || \
	  aws secretsmanager create-secret   --region $(AWS_REGION) --name "$(ESO_SECRET_NAME)" --secret-string file:///tmp/github-app.json >/dev/null
	@rm -f /tmp/github-app.json
	@echo "✓ Secrets Manager secret ready: $(ESO_SECRET_NAME)"

externalsecret-apply:
	@mkdir -p eso
	@echo "Creating $(EXTERNALSECRET_FILE) to materialize arc-github-app Secret in $(ARC_RUNNERS_NS)..."
	@printf '%s\n' \
	"apiVersion: external-secrets.io/v1" \
	"kind: ExternalSecret" \
	"metadata:" \
	"  name: arc-github-app" \
	"  namespace: $(ARC_RUNNERS_NS)" \
	"spec:" \
	"  refreshInterval: 24h" \
	"  secretStoreRef:" \
	"    kind: ClusterSecretStore" \
	"    name: aws-secrets" \
	"  dataFrom:" \
	"    - extract:" \
	"        key: $(ESO_SECRET_NAME)" \
	"  target:" \
	"    name: arc-github-app" \
	"    creationPolicy: Owner" \
	"    template:" \
	"      engineVersion: v2" \
	"      data:" \
	"        github_app_id: '{{ .github_app_id | toString }}'" \
	"        github_app_installation_id: '{{ .github_app_installation_id | toString }}'" \
	"        github_app_private_key: |-" \
	"          {{ .github_app_private_key | toString | replace \"\\n\" \"\n\" }}" \
	> $(EXTERNALSECRET_FILE)
	kubectl create ns $(ARC_RUNNERS_NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f $(EXTERNALSECRET_FILE)
	@echo "✓ ExternalSecret applied. ESO will sync arc-github-app in $(ARC_RUNNERS_NS)."

# ============
# Step: ARC (controller + your runner set)
# ============
arc-install:
	helm upgrade --install arc \
	  -n $(ARC_SYS_NS) --create-namespace \
	  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
	@echo "✓ ARC controller installed in $(ARC_SYS_NS)."

.PHONY: arc-crds-apply
arc-crds-apply:
	@echo "Installing ARC CRDs (RunnerScaleSet, etc.)..."
	# Controller CRDs
	helm show crds oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller | kubectl apply --server-side --force-conflicts -f -
	# Runner Scale Set chart CRDs (safe if already applied)
	helm show crds oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set | kubectl apply --server-side --force-conflicts -f -
	@echo "✓ ARC CRDs installed."

.PHONY: arc-values-file arc-runners-apply
arc-values-file:
	@mkdir -p $(dir $(ARC_VALUES_FILE))
	@echo "Writing $(ARC_VALUES_FILE)..."
	@printf '%s\n' \
	"githubConfigUrl: https://github.com/$(GITHUB_ORG)" \
	"githubConfigSecret: arc-github-app" \
	"runnerScaleSetName: $(RUNNER_SET_NAME)" \
	"minRunners: 0" \
	"maxRunners: 30" \
	"controllerServiceAccount:" \
	"  namespace: $(ARC_SYS_NS)" \
	"  name: $(ARC_CONTROLLER_SA)" \
	"containerMode:" \
	"  type: dind" \
	"template:" \
	"  spec:" \
	"    nodeSelector:" \
	"      node-role: runner" \
	"    containers:" \
	"      - name: runner" \
	"        image: $(IMAGE_URI)" \
	"        resources:" \
	"          requests:" \
	"            cpu: \"2\"" \
	"            memory: \"4Gi\"" \
	"          limits:" \
	"            cpu: \"4\"" \
	"            memory: \"8Gi\"" \
	> $(ARC_VALUES_FILE)
	@echo "✓ $(ARC_VALUES_FILE) updated."

arc-runners-apply: arc-values-file
	kubectl create ns $(ARC_RUNNERS_NS) --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install $(RUNNER_SET_NAME) \
	  -n $(ARC_RUNNERS_NS) \
	  -f $(ARC_VALUES_FILE) \
	  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
	@echo "✓ Runner scale set '$(RUNNER_SET_NAME)' applied. Use 'runs-on: $(RUNNER_SET_NAME)'."

# ============
# Sanity
# ============
prereqs:
	@command -v eksctl >/dev/null || (echo "Please install eksctl"; exit 1)
	@command -v kubectl >/dev/null || (echo "Please install kubectl"; exit 1)
	@command -v helm   >/dev/null || (echo "Please install helm"; exit 1)
	@command -v aws    >/dev/null || (echo "Please install AWS CLI v2"; exit 1)
	@command -v docker >/dev/null || (echo "Please install Docker"; exit 1)
