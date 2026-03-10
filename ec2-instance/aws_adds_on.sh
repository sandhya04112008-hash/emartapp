#!/bin/bash
# eks-bootstrap.sh - Run this ONCE on fresh cluster

set -euo pipefail

CLUSTER_NAME="emart-dev-app"
REGION="ap-south-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "🚀 Bootstrapping EKS: $CLUSTER_NAME in $REGION"
echo "📋 Account ID: $ACCOUNT_ID"

# ─────────────────────────────────────────────
# STEP 1: IAM OIDC Provider
# ─────────────────────────────────────────────
echo "🔐 Setting up OIDC Provider..."
eksctl utils associate-iam-oidc-provider \
  --region $REGION \
  --cluster $CLUSTER_NAME \
  --approve

OIDC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --region $REGION \
  --query "cluster.identity.oidc.issuer" \
  --output text | cut -d '/' -f 5)
echo "✅ OIDC ID: $OIDC_ID"

# ─────────────────────────────────────────────
# STEP 2: AWS Load Balancer Controller
# ─────────────────────────────────────────────
echo "⚖️  Installing AWS Load Balancer Controller..."

# Download IAM policy
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/docs/install/iam_policy.json

# Create IAM Policy
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json \
  --no-cli-pager 2>/dev/null || echo "Policy already exists, skipping..."

# Create IAM Role + Service Account
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve \
  --override-existing-serviceaccounts

# Install via Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$REGION \
  --set vpcId=$(aws eks describe-cluster --name $CLUSTER_NAME \
    --region $REGION \
    --query "cluster.resourcesVpcConfig.vpcId" --output text) \
  --version 1.7.0

echo "✅ Load Balancer Controller installed"

# ─────────────────────────────────────────────
# STEP 3: External Secrets Operator
# ─────────────────────────────────────────────
echo "🔒 Installing External Secrets Operator..."

# IAM Policy for Secrets Manager
cat > eso-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "ssm:GetParameter",
        "ssm:GetParameters"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name ExternalSecretsPolicy \
  --policy-document file://eso-policy.json \
  --no-cli-pager 2>/dev/null || echo "Policy exists, skipping..."

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --namespace=external-secrets \
  --name=external-secrets \
  --role-name ExternalSecretsRole \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/ExternalSecretsPolicy \
  --approve \
  --override-existing-serviceaccounts

helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace \
  --set serviceAccount.create=false \
  --set serviceAccount.name=external-secrets \
  --version 0.9.0

echo "✅ External Secrets Operator installed"

# ─────────────────────────────────────────────
# STEP 4: EBS CSI Driver (EKS Managed Addon)
# ─────────────────────────────────────────────
echo "💾 Installing EBS CSI Driver..."

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --name=ebs-csi-controller-sa \
  --namespace=kube-system \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --attach-policy-arn=arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve \
  --override-existing-serviceaccounts

aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --region $REGION \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole \
  --no-cli-pager 2>/dev/null || \
aws eks update-addon \
  --cluster-name $CLUSTER_NAME \
  --region $REGION \
  --addon-name aws-ebs-csi-driver \
  --no-cli-pager

echo "✅ EBS CSI Driver installed"

# ─────────────────────────────────────────────
# STEP 5: Cluster Autoscaler
# ─────────────────────────────────────────────
echo "📈 Installing Cluster Autoscaler..."

cat > cas-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeInstanceTypes"
    ],
    "Resource": "*"
  }]
}
EOF

aws iam create-policy \
  --policy-name ClusterAutoscalerPolicy \
  --policy-document file://cas-policy.json \
  --no-cli-pager 2>/dev/null || echo "Policy exists, skipping..."

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --namespace=kube-system \
  --name=cluster-autoscaler \
  --role-name ClusterAutoscalerRole \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/ClusterAutoscalerPolicy \
  --approve \
  --override-existing-serviceaccounts

helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName=$CLUSTER_NAME \
  --set awsRegion=$REGION \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler

echo "✅ Cluster Autoscaler installed"

# ─────────────────────────────────────────────
# STEP 6: Metrics Server
# ─────────────────────────────────────────────
echo "📊 Installing Metrics Server..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system

echo "✅ Metrics Server installed"

# ─────────────────────────────────────────────
# FINAL: Verify Everything
# ─────────────────────────────────────────────
echo ""
echo "🔍 Verification..."
sleep 30  # Wait for pods to start

kubectl get pods -n kube-system | grep -E "aws-load-balancer|ebs-csi|cluster-autoscaler|metrics-server"
kubectl get pods -n external-secrets

echo ""
echo "✅ ✅ ✅  EKS Bootstrap Complete! ✅ ✅ ✅"