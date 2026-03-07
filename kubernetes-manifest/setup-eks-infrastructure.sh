#!/bin/bash

# Variables
CLUSTER_NAME="emart-dev-app"
AWS_REGION="ap-south-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.resourcesVpcConfig.vpcId" --output text)

echo "=========================================="
echo "EKS Cluster Setup Script"
echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Account: $AWS_ACCOUNT_ID"
echo "VPC ID: $VPC_ID"
echo "=========================================="

# 1. Associate OIDC provider
echo ""
echo "[1/8] Associating OIDC provider..."
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --approve

# 2. Setup External Secrets
echo ""
echo "[2/8] Creating IAM policy for External Secrets..."
aws iam create-policy \
  --policy-name ExternalSecretsPolicy \
  --policy-document file://external-secrets-iam-policy.json 2>/dev/null || echo "Policy already exists"

echo ""
echo "[3/8] Creating IAM service account for External Secrets..."
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --namespace external-secrets-system \
  --name external-secrets \
  --attach-policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/ExternalSecretsPolicy \
  --approve

echo ""
echo "[4/8] Installing External Secrets Operator..."
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace \
  --set serviceAccount.create=false \
  --set serviceAccount.name=external-secrets

# 3. Setup AWS Load Balancer Controller
echo ""
echo "[5/8] Downloading IAM policy for ALB Controller..."
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

echo ""
echo "[6/8] Creating IAM policy for ALB Controller..."
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json 2>/dev/null || echo "Policy already exists"

echo ""
echo "[7/8] Creating IAM service account for ALB Controller..."
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

echo ""
echo "[8/8] Installing AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set vpcId=$VPC_ID

# 4. Apply Kubernetes manifests
echo ""
echo "Applying Kubernetes manifests..."
kubectl apply -f cluster-secret-yaml
kubectl apply -f external-secrets.yaml

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Checking status..."
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get deployment -n external-secrets-system
kubectl get clustersecretstore aws-secrets
kubectl get externalsecret -n emart
kubectl get ingress -n emart

echo ""
echo "To watch for ALB provisioning, run:"
echo "kubectl get ingress -n emart -w"
