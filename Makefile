# ============
# Config
# ============
AWS_REGION            ?= us-east-1
CLUSTER_NAME          ?= arc-eks
EKSCTL_CONFIG         ?= eks/arc-eks.yaml

# Namespaces
ESO_NS                ?= external-secrets
ARC_SYS_NS            ?= arc-systems
ARC_RUNNERS_NS        ?= arc-runners
ARC_CONTROLLER_SA     ?= gha-runner-scale-set-controller

# ECR (pre-existing repo). Example: ECR_REPO=arc-runner-tools
ECR_REPO              ?= fortinetcloudcse-arc-runner-image
IMAGE_TAG             ?= latest
CONTEXT_DIR           ?= container
DOCKERFILE            ?= $(CONTEXT_DIR)/Dockerfile

# GitHub org + GitHub App identifiers (from your App)
GITHUB_ORG            ?= FortinetCloudCSE
GITHUB_REPO           ?=
GITHUB_URL            ?= https://github.com/$(GITHUB_ORG)$(if $(GITHUB_REPO),/$(GITHUB_REPO))
GITHUB_APP_ID         := $(shell yq -r '.AppID' gh-app-info) 
GITHUB_APP_INSTALLATION_ID := $(shell yq -r '.InstallationID' gh-app-info)

# Runners
RUNNER_SET_NAME ?= org-runners
RUNNER_GROUP_NAME ?= FortinetCloudCSEOrgRunners
ARC_VALUES_FILE ?= eks/arc-runners.values.yaml

# ARC chart version pins (optional)
ARC_CONTROLLER_CHART_VERSION ?=
ARC_RUNNERS_CHART_VERSION ?=
ARC_CONTROLLER_CHART_FLAGS := $(if $(ARC_CONTROLLER_CHART_VERSION),--version $(ARC_CONTROLLER_CHART_VERSION),)
ARC_RUNNERS_CHART_FLAGS := $(if $(ARC_RUNNERS_CHART_VERSION),--version $(ARC_RUNNERS_CHART_VERSION),)

# Cluster Autoscaler
CA_VERSION            ?= v1.33.0
CA_BRANCH            := $(shell echo $(CA_VERSION) | sed -E 's/^v([0-9]+\.[0-9]+).*/cluster-autoscaler-release-\1/')
CA_NAMESPACE          ?= kube-system
CA_SA_NAME            ?= cluster-autoscaler
CA_POLICY_NAME        ?= AmazonEKSClusterAutoscalerPolicy
CA_POLICY_FILE        ?= eks/cluster-autoscaler-policy.json

# Secrets Manager (single JSON secret with 3 keys)
ESO_SECRET_NAME       ?= arc/arc-runner-app
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
# Allow overriding the AWS account ID via make variable: `make ACCOUNT_ID=123456789012 <target>`
ACCOUNT_ID            ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
ECR_REGISTRY          := $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
IMAGE_URI             := $(ECR_REGISTRY)/$(ECR_REPO):$(IMAGE_TAG)
OIDC_ISSUER           ?= $(shell aws eks describe-cluster --name $(CLUSTER_NAME) --region $(AWS_REGION) --query "cluster.identity.oidc.issuer" --output text 2>/dev/null)
OIDC_PROVIDER         ?= $(shell echo $(OIDC_ISSUER) | sed -e 's~^https://~~')
SECRET_ARN_PREFIX     := arn:aws:secretsmanager:$(AWS_REGION):$(ACCOUNT_ID):secret:$(ESO_SECRET_NAME)

# Utility to guard required vars
define guard
	@ if [ -z "$($1)" ]; then echo ">>> Missing required variable: $1"; exit 1; fi
endef

# ============
# High-level
# ============
.PHONY: help up up-with-ca down cluster-create image-build image-push ecr-login \
        eso-install eso-iam-create eso-annotate-sa eso-apply-store \
        sm-upsert externalsecret-apply arc-install arc-crds-apply arc-runners-apply \
        ca-iam-create ca-deploy \
        prereqs cluster-reset-soft cluster-reset

help:
	@echo "Targets:"
	@echo "  make up            - Create cluster, build/push image, install ESO + IRSA, store secrets, install ARC, apply runner set"
	@echo "  make down          - Delete cluster (leaves IAM + Secrets Manager intact)"
	@echo "  make cluster-create"
	@echo "  make image-build image-push"
	@echo "  make eso-install eso-iam-create eso-annotate-sa eso-apply-store"
	@echo "  make sm-upsert     - Create/Update Secrets Manager JSON for GitHub App"
	@echo "  make externalsecret-apply"
	@echo "  make arc-install arc-crds-apply arc-runners-apply"
	@echo "  make ca-iam-create - Create CA IAM policy + IRSA service account"
	@echo "  make ca-deploy      - Deploy Cluster Autoscaler $(CA_VERSION)"
	@echo "  make cluster-reset-soft - Remove ARC/ESO/runner resources and CRDs; keep cluster"
	@echo "  make cluster-reset      - Delete and recreate the cluster from $(EKSCTL_CONFIG) (DESTRUCTIVE)"


up: prereqs cluster-create ecr-login image-build image-push \
    eso-install eso-iam-create eso-annotate-sa eso-apply-store \
    sm-upsert externalsecret-apply arc-install arc-crds-apply wait-arc-secret arc-runners-apply
	@echo "✓ All done. Your ARC runners should register to https://github.com/$(GITHUB_ORG)"

up-with-ca: up ca-iam-create ca-deploy

down:
	@for STACK_NAME in $$(aws cloudformation describe-stacks --region $(AWS_REGION) --query "Stacks[?Tags[?Key=='alpha.eksctl.io/cluster-name' && Value=='$(CLUSTER_NAME)']].StackName" --output text); do \
	  aws cloudformation delete-stack --stack-name $$STACK_NAME --region $(AWS_REGION); \
	done
	eksctl delete cluster -f $(EKSCTL_CONFIG)

# ============
# Reset helpers
# ============

.PHONY: cluster-reset-soft cluster-reset

# Soft reset: uninstall ARC, ESO, runner scale set, Cluster Autoscaler; delete CRDs and namespaces.
# Leaves the EKS cluster and managed nodegroups intact.
cluster-reset-soft:
	@echo "Uninstalling Helm releases (ignore errors if absent)..."
	-helm -n $(ARC_RUNNERS_NS) uninstall $(RUNNER_SET_NAME)
	-helm -n $(ARC_SYS_NS) uninstall arc
	-helm -n $(ESO_NS) uninstall external-secrets
	@echo "Deleting Cluster Autoscaler deployment if present..."
	-kubectl -n $(CA_NAMESPACE) delete deploy cluster-autoscaler --ignore-not-found
	@echo "Deleting ARC and ESO CRDs if present..."
	-kubectl get crd autoscalingrunnersets.actions.github.com -o json | jq 'del(.metadata.finalizers)' | kubectl replace --raw "/apis/apiextensions.k8s.io/v1/customresourcedefinitions/autoscalingrunnersets.actions.github.com" -f -
	-kubectl get crd autoscalinglisteners.actions.github.com -o json | jq 'del(.metadata.finalizers)' | kubectl replace --raw "/apis/apiextensions.k8s.io/v1/customresourcedefinitions/autoscalinglisteners.actions.github.com" -f -
	-kubectl get crd ephemeralrunners.actions.github.com -o json | jq 'del(.metadata.finalizers)' | kubectl replace --raw "/apis/apiextensions.k8s.io/v1/customresourcedefinitions/ephemeralrunners.actions.github.com" -f -
	-kubectl get crd ephemeralrunnersets.actions.github.com -o json | jq 'del(.metadata.finalizers)' | kubectl replace --raw "/apis/apiextensions.k8s.io/v1/customresourcedefinitions/ephemeralrunnersets.actions.github.com" -f -
	-kubectl delete crd autoscalingrunnersets.actions.github.com autoscalinglisteners.actions.github.com --ignore-not-found
	-kubectl delete crd ephemeralrunners.actions.github.com ephemeralrunnersets.actions.github.com --ignore-not-found
	-kubectl delete crd externalsecrets.external-secrets.io secretstores.external-secrets.io clustersecretstores.external-secrets.io --ignore-not-found
	@echo "Deleting namespaces used by ARC/ESO (ignore if already gone)..."
	-kubectl delete ns $(ARC_RUNNERS_NS) $(ARC_SYS_NS) $(ESO_NS) --ignore-not-found
	@echo "Delete cluster role and role bindings..."
	-kubectl delete clusterrole arc-gha-rs-controller
	-kubectl delete clusterrolebinding arc-gha-rs-controller
	@echo "✓ Soft reset complete. Cluster remains with only eksctl-managed components."

# Hard reset: fully delete and recreate the cluster from $(EKSCTL_CONFIG).
# Requires explicit confirmation: make cluster-reset CONFIRM=yes
cluster-reset: 
	$(call guard,CONFIRM)
	@echo "WARNING: This will DELETE and RECREATE the EKS cluster '$(CLUSTER_NAME)' in $(AWS_REGION)."
	@echo "Proceeding with hard reset..."
	$(MAKE) down
	$(MAKE) cluster-create
	@echo "✓ Cluster reset to match $(EKSCTL_CONFIG)."

# ============
# Step: cluster
# ============
cluster-create:
	@test -f "$(EKSCTL_CONFIG)" || (echo "Missing $(EKSCTL_CONFIG)"; exit 1)
	eksctl create cluster -f $(EKSCTL_CONFIG)
	@echo "✓ Cluster created."
	$(MAKE) --no-print-directory wait-oidc-issuer
        
get-cluster-oidc:
	@echo "OIDC issuer: $(OIDC_ISSUER)"

.PHONY: wait-oidc-issuer
wait-oidc-issuer:
	@echo "Waiting for OIDC_ISSUER to be available..."
	@until OIDC_ISSUER=$$(aws eks describe-cluster --name $(CLUSTER_NAME) --region $(AWS_REGION) --query "cluster.identity.oidc.issuer" --output text 2>/dev/null); \
	  [ -n "$$OIDC_ISSUER" ] && [ "$$OIDC_ISSUER" != "None" ]; do \
	  echo "Waiting for OIDC_ISSUER to be available..."; \
	  sleep 5; \
	done; \
	echo "OIDC Issuer: $$OIDC_ISSUER"
	echo "OIDC Provider: $$OIDC_PROVIDER"

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
	# Wait for specific ESO CRDs without relying on bash arrays
	required_crds="acraccesstokens.generators.external-secrets.io clusterexternalsecrets.external-secrets.io clustergenerators.generators.external-secrets.io clusterpushsecrets.external-secrets.io clustersecretstores.external-secrets.io ecrauthorizationtokens.generators.external-secrets.io externalsecrets.external-secrets.io fakes.generators.external-secrets.io gcraccesstokens.generators.external-secrets.io generatorstates.generators.external-secrets.io githubaccesstokens.generators.external-secrets.io grafanas.generators.external-secrets.io mfas.generators.external-secrets.io passwords.generators.external-secrets.io pushsecrets.external-secrets.io quayaccesstokens.generators.external-secrets.io secretstores.external-secrets.io sshkeys.generators.external-secrets.io stssessiontokens.generators.external-secrets.io uuids.generators.external-secrets.io vaultdynamicsecrets.generators.external-secrets.io webhooks.generators.external-secrets.io"
	for crd in $$required_crds; do \
	  until kubectl get crd $$crd >/dev/null 2>&1; do \
	    echo "Waiting for CRD $$crd..."; \
	    sleep 1; \
	  done; \
	done
	for crd in $$required_crds; do \
	  kubectl wait --for=condition=Established crd/$$crd --timeout=120s; \
	done
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

eso-apply-store: clustersecretstore-file
	@echo "Waiting on eso deployments..."
	kubectl wait --for=condition=available deployment/external-secrets -n $(ESO_NS) --timeout=5m
	kubectl wait --for=condition=available deployment/external-secrets-cert-controller -n $(ESO_NS) --timeout=5m
	kubectl wait --for=condition=available deployment/external-secrets-webhook -n $(ESO_NS) --timeout=5m
	until kubectl apply -f $(CLUSTER_SECRETSTORE); do \
	  echo "Failed applying manifest, still waiting for CRDs, trying again in 5s..."; \
	  sleep 5; \
	done
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
	'      "StringEquals": { "$(OIDC_PROVIDER):aud": "sts.amazonaws.com", "$(OIDC_PROVIDER):sub": "system:serviceaccount:$(ESO_NS):external-secrets" }' \
	'    }' \
	'  }]' \
	'}' > $(ESO_TRUST_FILE)
	@echo "✓ Wrote $(ESO_TRUST_FILE)"

# Generate ClusterSecretStore with current region and ESO namespace
clustersecretstore-file:
	@echo "Writing $(CLUSTER_SECRETSTORE) for ESO ns $(ESO_NS) in $(AWS_REGION)..."
	@printf '%s\n' \
	"apiVersion: external-secrets.io/v1" \
	"kind: ClusterSecretStore" \
	"metadata:" \
	"  name: aws-secrets" \
	"spec:" \
	"  provider:" \
	"    aws:" \
	"      service: SecretsManager" \
	"      region: $(AWS_REGION)" \
	"      auth:" \
	"        jwt:" \
	"          serviceAccountRef:" \
	"            name: external-secrets" \
	"            namespace: $(ESO_NS)" \
	> $(CLUSTER_SECRETSTORE)

# ============
# Step: Secrets Manager (store your GitHub App creds)
# ============
sm-upsert:
	$(call guard,GITHUB_APP_ID)
	$(call guard,GITHUB_APP_INSTALLATION_ID)
	@test -f "$(PEM_FILE)" || (echo "Missing $(PEM_FILE)"; exit 1)
	@echo "Preparing JSON payload for Secrets Manager..."
	@jq -n \
	  --arg app_id "$(GITHUB_APP_ID)" \
	  --arg app_inst_id "$(GITHUB_APP_INSTALLATION_ID)" \
	  --rawfile pem "$(PEM_FILE)" \
	  '{github_app_id:$$app_id, github_app_installation_id:$$app_inst_id, github_app_private_key:$$pem}' \
	  > /tmp/github-app.json
	@# Compact to single line to avoid any CLI paramfile ambiguity
	@jq -c . /tmp/github-app.json > /tmp/github-app.min.json
	@echo "Upserting secret $(ESO_SECRET_NAME) in Secrets Manager..."
	@json_payload=$$(cat /tmp/github-app.min.json) ; \
	  aws secretsmanager describe-secret --region $(AWS_REGION) --secret-id "$(ESO_SECRET_NAME)" >/dev/null 2>&1 && \
	  aws secretsmanager put-secret-value --region $(AWS_REGION) --secret-id "$(ESO_SECRET_NAME)" --secret-string "$$json_payload" >/dev/null || \
	  aws secretsmanager create-secret   --region $(AWS_REGION) --name "$(ESO_SECRET_NAME)" --secret-string "$$json_payload" >/dev/null
	@rm -f /tmp/github-app.json /tmp/github-app.min.json
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

.PHONY: wait-arc-secret
wait-arc-secret:
	@echo "Waiting for Secret arc-github-app in namespace $(ARC_RUNNERS_NS)..."
	@i=0; until kubectl -n $(ARC_RUNNERS_NS) get secret arc-github-app >/dev/null 2>&1; do \
	  i=$$((i+1)); \
	  if [ $$i -gt 120 ]; then echo "Timeout waiting for arc-github-app Secret"; exit 1; fi; \
	  echo "  - Secret not ready yet. Waiting..."; \
	  sleep 2; \
	done
	@echo "✓ Secret arc-github-app is present in $(ARC_RUNNERS_NS)."

# ============
# Step: ARC (controller + your runner set)
# ============
arc-install:
	helm upgrade --wait --install arc \
	  -n $(ARC_SYS_NS) --create-namespace \
	  --set serviceAccount.create=true \
	  --set serviceAccount.name=$(ARC_CONTROLLER_SA) \
	  $(ARC_CONTROLLER_CHART_FLAGS) \
	  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
	@echo "Waiting for ARC controller pods to be Ready..."
	kubectl -n $(ARC_SYS_NS) wait --for=condition=Ready pod -l app.kubernetes.io/name=gha-rs-controller --timeout=180s
	@echo "✓ ARC controller installed and Ready in $(ARC_SYS_NS)."

.PHONY: arc-values-file arc-runners-apply
arc-values-file:
	@mkdir -p $(dir $(ARC_VALUES_FILE))
	@echo "Writing $(ARC_VALUES_FILE)..."
	@printf '%s\n' \
	"githubConfigUrl: $(GITHUB_URL)" \
	"githubConfigSecret: arc-github-app" \
	"runnerScaleSetName: $(RUNNER_SET_NAME)" \
	"minRunners: 0" \
	"maxRunners: 30" \
	"runnerScaleSet:" \
	"  runners:" \
	"    labels:" \
	"      - $(RUNNER_SET_NAME)" \
	"controllerServiceAccount:" \
	"  namespace: $(ARC_SYS_NS)" \
	"  name: $(ARC_CONTROLLER_SA)" \
	"containerMode:" \
	"  type: dind" \
	"template:" \
	"  spec:" \
	"    nodeSelector:" \
	"      node-role: runner" > $(ARC_VALUES_FILE)
	@echo "✓ $(ARC_VALUES_FILE) updated."

arc-runners-apply: arc-values-file
	kubectl create ns $(ARC_RUNNERS_NS) --dry-run=client -o yaml | kubectl apply -f -
	echo "Ensuring AutoScalingRunnerSets api resource ready..."
	@until kubectl auth can-i create autoscalingrunnersets.actions.github.com -n $(ARC_RUNNERS_NS) >/dev/null 2>&1; do sleep 2; done
	@until helm upgrade --install $(RUNNER_SET_NAME) -n $(ARC_RUNNERS_NS) -f $(ARC_VALUES_FILE) $(ARC_RUNNERS_CHART_FLAGS) \
	  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set; do \
	  echo "Failed applying $(RUNNER_SET_NAME) helm chart waiting for CRDs, re-trying..."; \
	  sleep 2; \
	done
	@echo "✓ Runner scale set '$(RUNNER_SET_NAME)' applied. Use 'runs-on: $(RUNNER_SET_NAME)'."

# ============
# Step: Cluster Autoscaler (IAM + IRSA + deploy)
# ============
.PHONY: ca-iam-create ca-deploy

ca-iam-create:
	$(call guard,ACCOUNT_ID)
	@test -f "$(CA_POLICY_FILE)" || (echo "Missing $(CA_POLICY_FILE)"; exit 1)
	@echo "Ensuring IAM policy $(CA_POLICY_NAME) exists..."
	@aws iam get-policy --policy-arn arn:aws:iam::$(ACCOUNT_ID):policy/$(CA_POLICY_NAME) >/dev/null 2>&1 || \
	  aws iam create-policy --policy-name $(CA_POLICY_NAME) --policy-document file://$(CA_POLICY_FILE) >/dev/null
	@echo "✓ Policy ready: arn:aws:iam::$(ACCOUNT_ID):policy/$(CA_POLICY_NAME)"
	@echo "Creating/Updating IRSA service account $(CA_NAMESPACE)/$(CA_SA_NAME) via eksctl..."
	eksctl create iamserviceaccount \
	  --cluster $(CLUSTER_NAME) \
	  --namespace $(CA_NAMESPACE) \
	  --name $(CA_SA_NAME) \
	  --attach-policy-arn arn:aws:iam::$(ACCOUNT_ID):policy/$(CA_POLICY_NAME) \
	  --override-existing-serviceaccounts \
	  --approve
	@echo "✓ IRSA service account ready: $(CA_NAMESPACE)/$(CA_SA_NAME)"

ca-deploy:
	@echo "Applying Cluster Autoscaler manifest $(CA_VERSION)..."
	@branch="$(CA_BRANCH)"; \
	url="https://raw.githubusercontent.com/kubernetes/autoscaler/$${branch}/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml"; \
	echo "Using manifest: $$url"; \
	kubectl apply -f "$$url"
	@echo "Waiting for deployment/cluster-autoscaler to exist..."
	@i=0; until kubectl -n $(CA_NAMESPACE) get deploy cluster-autoscaler >/dev/null 2>&1; do \
	  i=$$((i+1)); if [ $$i -gt 60 ]; then echo "Timeout waiting for deployment/cluster-autoscaler"; exit 1; fi; \
	  sleep 2; \
	done
	kubectl -n $(CA_NAMESPACE) set image deploy/cluster-autoscaler cluster-autoscaler=registry.k8s.io/autoscaling/cluster-autoscaler:$(CA_VERSION)
	kubectl -n $(CA_NAMESPACE) set serviceaccount deploy/cluster-autoscaler $(CA_SA_NAME)
	@echo "Setting stable args on deployment..."
	@patch='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["--cloud-provider=aws","--node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled,k8s.io/cluster-autoscaler/$(CLUSTER_NAME)","--balance-similar-node-groups","--skip-nodes-with-local-storage=false","--skip-nodes-with-system-pods=false"]}]'; \
	kubectl -n $(CA_NAMESPACE) patch deploy cluster-autoscaler --type=json -p="$$patch" || \
	kubectl -n $(CA_NAMESPACE) patch deploy cluster-autoscaler --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args","value":["--cloud-provider=aws","--node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled,k8s.io/cluster-autoscaler/$(CLUSTER_NAME)","--balance-similar-node-groups","--skip-nodes-with-local-storage=false","--skip-nodes-with-system-pods=false"]}]'
	kubectl -n $(CA_NAMESPACE) annotate deploy/cluster-autoscaler cluster-autoscaler.kubernetes.io/safe-to-evict="false" --overwrite
	@echo "✓ Cluster Autoscaler $(CA_VERSION) deployed. Verify with: kubectl -n $(CA_NAMESPACE) get deploy cluster-autoscaler"

# ============
# Sanity
# ============
prereqs:
	@command -v eksctl >/dev/null || (echo "Please install eksctl"; exit 1)
	@command -v kubectl >/dev/null || (echo "Please install kubectl"; exit 1)
	@command -v helm   >/dev/null || (echo "Please install helm"; exit 1)
	@command -v aws    >/dev/null || (echo "Please install AWS CLI v2"; exit 1)
	@command -v docker >/dev/null || (echo "Please install Docker"; exit 1)
