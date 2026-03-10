#!/bin/bash
# eks-bootstrap.sh - Fixed version with proper SA creation & health checks
# Fixes: race conditions, silent SA skips, missing SA bug

set -euo pipefail

CLUSTER_NAME="emart-dev-app"
REGION="ap-south-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "🚀 Bootstrapping EKS: $CLUSTER_NAME in $REGION"
echo "📋 Account ID: $ACCOUNT_ID"

# ─────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────

# Wait for a deployment to be fully ready before proceeding
wait_for_deployment() {
  local NAMESPACE=$1
  local DEPLOYMENT=$2
  local TIMEOUT=${3:-180}

  echo "⏳ Waiting for $DEPLOYMENT in $NAMESPACE to be ready (timeout: ${TIMEOUT}s)..."
  if kubectl rollout status deployment/$DEPLOYMENT -n $NAMESPACE --timeout=${TIMEOUT}s; then
    echo "✅ $DEPLOYMENT is ready"
  else
    echo "❌ $DEPLOYMENT failed to become ready. Dumping logs..."
    kubectl describe deployment $DEPLOYMENT -n $NAMESPACE
    kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=$DEPLOYMENT --tail=50 2>/dev/null || true
    exit 1
  fi
}

# Create SA + annotate it — guaranteed, no silent skips
create_service_account() {
  local NAMESPACE=$1
  local SA_NAME=$2
  local ROLE_ARN=$3

  echo "🔑 Ensuring ServiceAccount: $SA_NAME in $NAMESPACE..."

  # Create namespace if it doesn't exist
  kubectl create namespace $NAMESPACE 2>/dev/null || echo "  Namespace $NAMESPACE already exists"

  # Create SA if it doesn't exist
  kubectl create serviceaccount $SA_NAME -n $NAMESPACE 2>/dev/null \
    || echo "  ServiceAccount $SA_NAME already exists"

  # Always force-apply the annotation (this is the critical fix)
  kubectl annotate serviceaccount $SA_NAME \
    -n $NAMESPACE \
    eks.amazonaws.com/role-arn=$ROLE_ARN \
    --overwrite

  echo "  ✅ SA $SA_NAME annotated with $ROLE_ARN"
}

# ─────────────────────────────────────────────
# STEP 1: IAM OIDC Provider
# ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo "🔐 STEP 1: IAM OIDC Provider"
echo "════════════════════════════════════════════"

eksctl utils associate-iam-oidc-provider \
  --region $REGION \
  --cluster $CLUSTER_NAME \
  --approve

OIDC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --region $REGION \
  --query "cluster.identity.oidc.issuer" \
  --output text | cut -d '/' -f 5)
echo "✅ OIDC ID: $OIDC_ID"

# Get VPC ID once and reuse
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --region $REGION \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)
echo "✅ VPC ID: $VPC_ID"

# ─────────────────────────────────────────────
# STEP 2: AWS Load Balancer Controller
# ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo "⚖️  STEP 2: AWS Load Balancer Controller"
echo "════════════════════════════════════════════"

# Download & create IAM policy
curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json \
  --no-cli-pager 2>/dev/null || echo "  Policy already exists, skipping..."

LBC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKSLoadBalancerControllerRole"

# Create IAM role via eksctl (for the trust policy)
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve \
  --override-existing-serviceaccounts 2>/dev/null || true

# ✅ FIX: Always explicitly create + annotate SA (don't trust eksctl skip logic)
create_service_account "kube-system" "aws-load-balancer-controller" "$LBC_ROLE_ARN"

# Install via Helm
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update eks

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$REGION \
  --set vpcId=$VPC_ID \
  --version 1.7.0 \
  --wait \
  --timeout 120s

# ✅ FIX: Wait for LBC to be fully healthy before any other helm install
# (ESO install fails if LBC webhook isn't ready)
wait_for_deployment "kube-system" "aws-load-balancer-controller" 180

echo "✅ Load Balancer Controller installed and healthy"

# ─────────────────────────────────────────────
# STEP 3: External Secrets Operator
# ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo "🔒 STEP 3: External Secrets Operator"
echo "════════════════════════════════════════════"

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
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name ExternalSecretsPolicy \
  --policy-document file://eso-policy.json \
  --no-cli-pager 2>/dev/null || echo "  Policy already exists, skipping..."

ESO_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/ExternalSecretsRole"

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --namespace=external-secrets \
  --name=external-secrets \
  --role-name ExternalSecretsRole \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/ExternalSecretsPolicy \
  --approve \
  --override-existing-serviceaccounts 2>/dev/null || true

# ✅ FIX: Explicitly ensure SA exists with correct annotation
create_service_account "external-secrets" "external-secrets" "$ESO_ROLE_ARN"

helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo update external-secrets

helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace \
  --set serviceAccount.create=false \
  --set serviceAccount.name=external-secrets \
  --version 0.9.0 \
  --wait \
  --timeout 120s

wait_for_deployment "external-secrets" "external-secrets" 180
echo "✅ External Secrets Operator installed and healthy"

# ─────────────────────────────────────────────
# STEP 4: EBS CSI Driver
# ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo "💾 STEP 4: EBS CSI Driver"
echo "════════════════════════════════════════════"

EBS_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole"

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --name=ebs-csi-controller-sa \
  --namespace=kube-system \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --attach-policy-arn=arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve \
  --override-existing-serviceaccounts 2>/dev/null || true

# ✅ FIX: Explicitly ensure SA exists
create_service_account "kube-system" "ebs-csi-controller-sa" "$EBS_ROLE_ARN"

# Install as EKS managed addon (preferred over helm for CSI drivers)
aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --region $REGION \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn $EBS_ROLE_ARN \
  --no-cli-pager 2>/dev/null || \
aws eks update-addon \
  --cluster-name $CLUSTER_NAME \
  --region $REGION \
  --addon-name aws-ebs-csi-driver \
  --no-cli-pager

# Wait for EBS CSI addon to be active
echo "⏳ Waiting for EBS CSI addon to become ACTIVE..."
for i in $(seq 1 20); do
  STATUS=$(aws eks describe-addon \
    --cluster-name $CLUSTER_NAME \
    --region $REGION \
    --addon-name aws-ebs-csi-driver \
    --query "addon.status" --output text 2>/dev/null || echo "UNKNOWN")
  echo "  Status: $STATUS (attempt $i/20)"
  [ "$STATUS" = "ACTIVE" ] && break
  [ $i -eq 20 ] && echo "❌ EBS CSI addon did not become ACTIVE" && exit 1
  sleep 15
done
echo "✅ EBS CSI Driver installed and active"

# ─────────────────────────────────────────────
# STEP 5: Cluster Autoscaler
# ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo "📈 STEP 5: Cluster Autoscaler"
echo "════════════════════════════════════════════"

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
  --no-cli-pager 2>/dev/null || echo "  Policy already exists, skipping..."

CAS_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/ClusterAutoscalerRole"

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --namespace=kube-system \
  --name=cluster-autoscaler \
  --role-name ClusterAutoscalerRole \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/ClusterAutoscalerPolicy \
  --approve \
  --override-existing-serviceaccounts 2>/dev/null || true

# ✅ FIX: Explicitly ensure SA exists
create_service_account "kube-system" "cluster-autoscaler" "$CAS_ROLE_ARN"

helm repo add autoscaler https://kubernetes.github.io/autoscaler 2>/dev/null || true
helm repo update autoscaler

helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName=$CLUSTER_NAME \
  --set awsRegion=$REGION \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --wait \
  --timeout 120s

wait_for_deployment "kube-system" "cluster-autoscaler" 180
echo "✅ Cluster Autoscaler installed and healthy"

# ─────────────────────────────────────────────
# STEP 6: Metrics Server
# ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo "📊 STEP 6: Metrics Server"
echo "════════════════════════════════════════════"

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo update metrics-server

helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --wait \
  --timeout 120s

wait_for_deployment "kube-system" "metrics-server" 120
echo "✅ Metrics Server installed and healthy"

# ─────────────────────────────────────────────
# FINAL VERIFICATION
# ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo "🔍 FINAL VERIFICATION"
echo "════════════════════════════════════════════"

echo ""
echo "--- Nodes ---"
kubectl get nodes -o wide

echo ""
echo "--- kube-system pods ---"
kubectl get pods -n kube-system | grep -E "aws-load-balancer|ebs-csi|cluster-autoscaler|metrics-server"

echo ""
echo "--- external-secrets pods ---"
kubectl get pods -n external-secrets

echo ""
echo "--- Service Account IAM annotations ---"
for SA in "kube-system/aws-load-balancer-controller" "kube-system/ebs-csi-controller-sa" "kube-system/cluster-autoscaler" "external-secrets/external-secrets"; do
  NS=$(echo $SA | cut -d'/' -f1)
  NAME=$(echo $SA | cut -d'/' -f2)
  ANNOTATION=$(kubectl get sa $NAME -n $NS \
    -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "MISSING")
  echo "  $SA → $ANNOTATION"
done

echo ""
echo "✅ ✅ ✅  EKS Bootstrap Complete! ✅ ✅ ✅"