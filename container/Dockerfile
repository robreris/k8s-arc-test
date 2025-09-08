# Start from GitHub Actions runner image (pin a specific tag in production)
FROM ghcr.io/actions/actions-runner:latest

# Install OS deps
USER root
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      curl unzip git jq python3 python3-pip ca-certificates gnupg lsb-release && \
    rm -rf /var/lib/apt/lists/*

# AWS CLI v2
RUN curl -L "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip && \
    unzip /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip

# Terraform (pin to your preferred version)
ARG TF_VERSION=1.9.5
RUN curl -L "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip && \
    unzip /tmp/terraform.zip -d /usr/local/bin && \
    rm -f /tmp/terraform.zip && \
    terraform -version

# Optional: cfn-lint, yq, etc.
RUN pip3 install --no-cache-dir cfn-lint && \
    curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# Docker CLI (for jobs using docker with containerMode: dind)
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce-cli docker-buildx-plugin && \
    rm -rf /var/lib/apt/lists/*

# The base image already includes the runner; ARC will handle registration.
# If you need custom certs or configs, add them here.

# Runner process runs as 'runner' in base image
USER runner
