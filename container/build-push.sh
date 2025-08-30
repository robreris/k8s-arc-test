#/bin/sh
export DOCKER_REGISTRY=ghcr.io/your-org   # or your ECR
export IMAGE_NAME=arc-runner-tools
export IMAGE_TAG=v0.1.0

docker build -t $DOCKER_REGISTRY/$IMAGE_NAME:$IMAGE_TAG .
docker push $DOCKER_REGISTRY/$IMAGE_NAME:$IMAGE_TAG
