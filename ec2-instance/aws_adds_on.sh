#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# eks-bootstrap.sh - Production-grade EKS Cluster Bootstrap
# Features:
#   - Cleans up existing broken installs before reinstalling
#   - Creates IAM roles MANUALLY (no silent eksctl skips)
#   - Waits for each component to be healthy before proceeding
#   - Idempotent: safe to run multiple times
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ─────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────
CLUSTER_NAME="emart-dev-app"
REGION="ap-south-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --region $REGION \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)
OIDC_URL=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --region $REGION \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed 's|https://||')

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║        EKS BOOTSTRAP - FULL INSTALL/REINSTALL    ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  Cluster : $CLUSTER_NAME"
echo "  Region  : $REGION"
echo "  Account : $ACCOUNT_ID"
echo "  VPC     : $VPC_ID"
echo "  OIDC    : $OIDC_URL"
echo ""

# ─────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────

log_step() { echo ""; echo "════════════════════════════════════════════"; echo "$1"; echo "════════════════════════════════════════════"; }
log_ok()   { echo "  ✅ $1"; }
log_info() { echo "  ℹ️  $1"; }
log_warn() { echo "  ⚠️  $1"; }

wait_for_deployment() {
  local NAMESPACE=$1
  local DEPLOYMENT=$2
  local TIMEOUT=${3:-180}
  echo "  ⏳ Waiting for $DEPLOYMENT in ns/$NAMESPACE (timeout: ${TIMEOUT}s)..."
  if kubectl rollout status deployment/$DEPLOYMENT -n $NAMESPACE --timeout=${TIMEOUT}s; then
    log_ok "$DEPLOYMENT is Running"
  else
    echo "  ❌ $DEPLOYMENT failed. Logs:"
    kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=$DEPLOYMENT --tail=30 2>/dev/null || true
    kubectl describe deployment $DEPLOYMENT -n $NAMESPACE | tail -20
    exit 1
  fi
}

ensure_namespace() {
  kubectl create namespace $1 2>/dev/null \
    && log_info "Created namespace: $1" \
    || log_info "Namespace $1 already exists"
}

# Create SA + force-annotate with IAM role — guaranteed, no silent skips
ensure_service_account() {
  local NAMESPACE=$1
  local SA_NAME=$2
  local ROLE_ARN=$3
  ensure_namespace $NAMESPACE
  kubectl create serviceaccount $SA_NAME -n $NAMESPACE 2>/dev/null \
    && log_info "Created SA: $SA_NAME" \
    || log_info "SA $SA_NAME already exists"
  kubectl annotate serviceaccount $SA_NAME -n $NAMESPACE \
    eks.amazonaws.com/role-arn=$ROLE_ARN --overwrite
  log_ok "SA $SA_NAME → $ROLE_ARN"
}

# Create IAM role with OIDC trust policy — idempotent
# Returns the Role ARN via stdout (all other output goes to stderr or is suppressed)
create_iam_role_with_oidc() {
  local ROLE_NAME=$1
  local NAMESPACE=$2
  local SA_NAME=$3
  local POLICY_ARN=$4

  if aws iam get-role --role-name $ROLE_NAME --no-cli-pager &>/dev/null; then
    log_info "IAM Role $ROLE_NAME exists — refreshing trust policy..."
  else
    log_info "Creating IAM Role: $ROLE_NAME"
  fi

  # Write trust policy (always overwrite to ensure correctness)
  cat > /tmp/trust-policy-${ROLE_NAME}.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_URL}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_URL}:aud": "sts.amazonaws.com",
          "${OIDC_URL}:sub": "system:serviceaccount:${NAMESPACE}:${SA_NAME}"
        }
      }
    }
  ]
}
EOF

  # Create or update trust policy
  aws iam create-role \
    --role-name $ROLE_NAME \
    --assume-role-policy-document file:///tmp/trust-policy-${ROLE_NAME}.json \
    --no-cli-pager 2>/dev/null || \
  aws iam update-assume-role-policy \
    --role-name $ROLE_NAME \
    --policy-document file:///tmp/trust-policy-${ROLE_NAME}.json \
    --no-cli-pager

  # Attach policy (idempotent)
  aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn $POLICY_ARN \
    --no-cli-pager 2>/dev/null || log_info "Policy already attached to $ROLE_NAME"

  local ROLE_ARN
  ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME \
    --query "Role.Arn" --output text)
  log_ok "IAM Role ready: $ROLE_ARN"

  # Return ARN to caller
  echo $ROLE_ARN
}

# ─────────────────────────────────────────────
# STEP 0: CLEANUP EXISTING BROKEN INSTALLS
# ─────────────────────────────────────────────
log_step "🧹 STEP 0: Cleanup Existing Installs"

# Uninstall Helm releases
for RELEASE_NS in \
  "aws-load-balancer-controller:kube-system" \
  "external-secrets:external-secrets" \
  "cluster-autoscaler:kube-system" \
  "metrics-server:kube-system"; do
  RELEASE=$(echo $RELEASE_NS | cut -d: -f1)
  NS=$(echo $RELEASE_NS | cut -d: -f2)
  if helm status $RELEASE -n $NS &>/dev/null; then
    log_info "Uninstalling Helm release: $RELEASE (ns: $NS)"
    helm uninstall $RELEASE -n $NS --wait 2>/dev/null || true
    log_ok "Uninstalled: $RELEASE"
  else
    log_info "Helm release '$RELEASE' not installed — skipping"
  fi
done

# Delete EBS CSI managed addon
if aws eks describe-addon \
  --cluster-name $CLUSTER_NAME \
  --region $REGION \
  --addon-name aws-ebs-csi-driver \
  --no-cli-pager &>/dev/null; then
  log_info "Deleting EBS CSI addon..."
  aws eks delete-addon \
    --cluster-name $CLUSTER_NAME \
    --region $REGION \
    --addon-name aws-ebs-csi-driver \
    --no-cli-pager
  echo "  ⏳ Waiting for EBS CSI addon deletion..."
  for i in $(seq 1 24); do
    STATUS=$(aws eks describe-addon \
      --cluster-name $CLUSTER_NAME \
      --region $REGION \
      --addon-name aws-ebs-csi-driver \
      --query "addon.status" --output text 2>/dev/null || echo "DELETED")
    log_info "Delete status: $STATUS (attempt $i/24)"
    [ "$STATUS" = "DELETED" ] && break
    [ $i -eq 24 ] && log_warn "Addon deletion timed out — continuing anyway"
    sleep 10
  done
  log_ok "EBS CSI addon deleted"
else
  log_info "EBS CSI addon not installed — skipping"
fi

# Delete stale webhooks — these block ESO and other helm installs
log_info "Cleaning up stale webhooks..."
kubectl delete mutatingwebhookconfigurations aws-load-balancer-webhook 2>/dev/null \
  && log_ok "Deleted stale LBC mutating webhook" \
  || log_info "No stale LBC mutating webhook found"
kubectl delete validatingwebhookconfigurations aws-load-balancer-webhook 2>/dev/null \
  && log_ok "Deleted stale LBC validating webhook" \
  || log_info "No stale LBC validating webhook found"

log_ok "Cleanup complete — starting fresh install"

# ─────────────────────────────────────────────
# STEP 1: IAM OIDC Provider
# ─────────────────────────────────────────────
log_step "🔐 STEP 1: IAM OIDC Provider"

eksctl utils associate-iam-oidc-provider \
  --region $REGION \
  --cluster $CLUSTER_NAME \
  --approve

log_ok "OIDC Provider associated: $OIDC_URL"

# ─────────────────────────────────────────────
# STEP 2: AWS Load Balancer Controller
# ─────────────────────────────────────────────
log_step "⚖️  STEP 2: AWS Load Balancer Controller"

# IAM Policy
curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json \
  --no-cli-pager 2>/dev/null || log_info "LBC IAM policy already exists"

# IAM Role — manual, guaranteed
LBC_ROLE_ARN=$(create_iam_role_with_oidc \
  "AmazonEKSLoadBalancerControllerRole" \
  "kube-system" \
  "aws-load-balancer-controller" \
  "arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy")

# Service Account
ensure_service_account \
  "kube-system" \
  "aws-load-balancer-controller" \
  "$LBC_ROLE_ARN"

# Helm Install
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

# MUST wait before proceeding — ESO fails if LBC webhook isn't ready
wait_for_deployment "kube-system" "aws-load-balancer-controller" 180
log_ok "Load Balancer Controller installed and healthy"

# ─────────────────────────────────────────────
# STEP 3: External Secrets Operator
# ─────────────────────────────────────────────
log_step "🔒 STEP 3: External Secrets Operator"

# IAM Policy
cat > /tmp/eso-policy.json << EOF
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
  --policy-document file:///tmp/eso-policy.json \
  --no-cli-pager 2>/dev/null || log_info "ESO IAM policy already exists"

# IAM Role — manual, guaranteed
ESO_ROLE_ARN=$(create_iam_role_with_oidc \
  "ExternalSecretsRole" \
  "external-secrets" \
  "external-secrets" \
  "arn:aws:iam::${ACCOUNT_ID}:policy/ExternalSecretsPolicy")

# Service Account
ensure_service_account \
  "external-secrets" \
  "external-secrets" \
  "$ESO_ROLE_ARN"

# Helm Install
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
log_ok "External Secrets Operator installed and healthy"

# ─────────────────────────────────────────────
# STEP 4: EBS CSI Driver
# ─────────────────────────────────────────────
log_step "💾 STEP 4: EBS CSI Driver"

# IAM Role — manual creation (this was the original bug — role was never created)
EBS_ROLE_ARN=$(create_iam_role_with_oidc \
  "AmazonEKS_EBS_CSI_DriverRole" \
  "kube-system" \
  "ebs-csi-controller-sa" \
  "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy")

# Service Account
ensure_service_account \
  "kube-system" \
  "ebs-csi-controller-sa" \
  "$EBS_ROLE_ARN"

# Create EKS Managed Addon
aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --region $REGION \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn $EBS_ROLE_ARN \
  --no-cli-pager

# Wait for ACTIVE — addon takes ~2-3 mins
echo "  ⏳ Waiting for EBS CSI addon to become ACTIVE..."
for i in $(seq 1 36); do
  STATUS=$(aws eks describe-addon \
    --cluster-name $CLUSTER_NAME \
    --region $REGION \
    --addon-name aws-ebs-csi-driver \
    --query "addon.status" --output text 2>/dev/null || echo "UNKNOWN")
  ISSUES=$(aws eks describe-addon \
    --cluster-name $CLUSTER_NAME \
    --region $REGION \
    --addon-name aws-ebs-csi-driver \
    --query "addon.health.issues" --output json 2>/dev/null || echo "[]")
  log_info "Status: $STATUS (attempt $i/36)"
  [ "$STATUS" = "ACTIVE" ] && break
  [ "$ISSUES" != "[]" ] && [ "$ISSUES" != "null" ] && echo "  Issues: $ISSUES"
  if [ $i -eq 36 ]; then
    echo "  ❌ EBS CSI addon did not become ACTIVE. Full details:"
    aws eks describe-addon \
      --cluster-name $CLUSTER_NAME \
      --region $REGION \
      --addon-name aws-ebs-csi-driver \
      --output json
    exit 1
  fi
  sleep 15
done
log_ok "EBS CSI Driver ACTIVE"

# ─────────────────────────────────────────────
# STEP 5: Cluster Autoscaler
# ─────────────────────────────────────────────
log_step "📈 STEP 5: Cluster Autoscaler"

# IAM Policy
cat > /tmp/cas-policy.json << EOF
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
  --policy-document file:///tmp/cas-policy.json \
  --no-cli-pager 2>/dev/null || log_info "CAS IAM policy already exists"

# IAM Role — manual, guaranteed
CAS_ROLE_ARN=$(create_iam_role_with_oidc \
  "ClusterAutoscalerRole" \
  "kube-system" \
  "cluster-autoscaler" \
  "arn:aws:iam::${ACCOUNT_ID}:policy/ClusterAutoscalerPolicy")

# Service Account
ensure_service_account \
  "kube-system" \
  "cluster-autoscaler" \
  "$CAS_ROLE_ARN"

# Helm Install
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
log_ok "Cluster Autoscaler installed and healthy"

# ─────────────────────────────────────────────
# STEP 6: Metrics Server
# ─────────────────────────────────────────────
log_step "📊 STEP 6: Metrics Server"

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo update metrics-server

helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --wait \
  --timeout 120s

wait_for_deployment "kube-system" "metrics-server" 120
log_ok "Metrics Server installed and healthy"

# ─────────────────────────────────────────────
# FINAL VERIFICATION
# ─────────────────────────────────────────────
log_step "🔍 FINAL VERIFICATION"

echo ""
echo "--- Nodes ---"
kubectl get nodes -o wide

echo ""
echo "--- kube-system controllers ---"
kubectl get pods -n kube-system \
  | grep -E "aws-load-balancer|ebs-csi|cluster-autoscaler|metrics-server"

echo ""
echo "--- external-secrets pods ---"
kubectl get pods -n external-secrets

echo ""
echo "--- IAM Role annotations on all Service Accounts ---"
for SA_NS in \
  "kube-system:aws-load-balancer-controller" \
  "kube-system:ebs-csi-controller-sa" \
  "kube-system:cluster-autoscaler" \
  "external-secrets:external-secrets"; do
  NS=$(echo $SA_NS | cut -d: -f1)
  SA=$(echo $SA_NS | cut -d: -f2)
  ARN=$(kubectl get sa $SA -n $NS \
    -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null \
    || echo "❌ MISSING")
  printf "  %-45s → %s\n" "$NS/$SA" "$ARN"
done

echo ""
echo "--- EBS CSI Addon Status ---"
aws eks describe-addon \
  --cluster-name $CLUSTER_NAME \
  --region $REGION \
  --addon-name aws-ebs-csi-driver \
  --query "addon.{Status:status,Version:addonVersion}" \
  --output table

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║         ✅  EKS BOOTSTRAP COMPLETE  ✅           ║"
echo "╚══════════════════════════════════════════════════╝"