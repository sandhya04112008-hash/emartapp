#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# eks-bootstrap.sh - Production-grade EKS Cluster Bootstrap
# Idempotent: cleans up broken installs, creates IAM roles
# manually, waits for health before proceeding
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
echo "======================================================"
echo "       EKS BOOTSTRAP - FULL INSTALL/REINSTALL        "
echo "======================================================"
echo "  Cluster : $CLUSTER_NAME"
echo "  Region  : $REGION"
echo "  Account : $ACCOUNT_ID"
echo "  VPC     : $VPC_ID"
echo "  OIDC    : $OIDC_URL"
echo ""

# ─────────────────────────────────────────────
# HELPER FUNCTIONS
# NOTE: No emojis inside functions — they break kubectl/aws argument parsing
# ─────────────────────────────────────────────

log_step() { echo ""; echo "--------------------------------------------"; echo ">>> $1"; echo "--------------------------------------------"; }
log_ok()   { echo "  [OK]   $1"; }
log_info() { echo "  [INFO] $1"; }
log_warn() { echo "  [WARN] $1"; }
log_err()  { echo "  [ERR]  $1"; }

wait_for_deployment() {
  local NAMESPACE=$1
  local DEPLOYMENT=$2
  local TIMEOUT=${3:-180}
  echo "  [WAIT] $DEPLOYMENT in ns/$NAMESPACE (timeout: ${TIMEOUT}s)..."
  if kubectl rollout status deployment/$DEPLOYMENT -n $NAMESPACE --timeout=${TIMEOUT}s; then
    log_ok "$DEPLOYMENT is Running"
  else
    log_err "$DEPLOYMENT failed to become ready. Dumping info:"
    kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=$DEPLOYMENT --tail=30 2>/dev/null || true
    kubectl describe deployment $DEPLOYMENT -n $NAMESPACE | tail -20
    exit 1
  fi
}

ensure_namespace() {
  local NS=$1
  if kubectl get namespace $NS &>/dev/null; then
    log_info "Namespace $NS already exists"
  else
    kubectl create namespace $NS
    log_ok "Created namespace: $NS"
  fi
}

ensure_service_account() {
  local NAMESPACE=$1
  local SA_NAME=$2
  local ROLE_ARN=$3

  ensure_namespace "$NAMESPACE"

  if kubectl get serviceaccount $SA_NAME -n $NAMESPACE &>/dev/null; then
    log_info "ServiceAccount $SA_NAME already exists"
  else
    kubectl create serviceaccount $SA_NAME -n $NAMESPACE
    log_ok "Created ServiceAccount: $SA_NAME"
  fi

  # Force-apply annotation — this is the critical step
  kubectl annotate serviceaccount "$SA_NAME" \
    -n "$NAMESPACE" \
    "eks.amazonaws.com/role-arn=$ROLE_ARN" \
    --overwrite

  log_ok "Annotated $NAMESPACE/$SA_NAME with $ROLE_ARN"
}

# Creates IAM role with OIDC trust policy, attaches policy, returns ARN
# Usage: ROLE_ARN=$(create_iam_role_with_oidc ROLE_NAME NAMESPACE SA_NAME POLICY_ARN)
create_iam_role_with_oidc() {
  local ROLE_NAME=$1
  local NAMESPACE=$2
  local SA_NAME=$3
  local POLICY_ARN=$4

  # Write trust policy to temp file
  cat > /tmp/trust-${ROLE_NAME}.json <<TRUST
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
TRUST

  # Create role if missing, otherwise update trust policy
  if aws iam get-role --role-name "$ROLE_NAME" --no-cli-pager &>/dev/null; then
    log_info "IAM Role $ROLE_NAME exists — refreshing trust policy"
    aws iam update-assume-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-document file:///tmp/trust-${ROLE_NAME}.json \
      --no-cli-pager
  else
    log_info "Creating IAM Role: $ROLE_NAME"
    aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document file:///tmp/trust-${ROLE_NAME}.json \
      --no-cli-pager
  fi

  # Attach policy (safe if already attached)
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY_ARN" \
    --no-cli-pager 2>/dev/null || log_info "Policy already attached to $ROLE_NAME"

  # Fetch and return the ARN
  local ROLE_ARN
  ROLE_ARN=$(aws iam get-role \
    --role-name "$ROLE_NAME" \
    --query "Role.Arn" \
    --output text)

  log_ok "IAM Role ready: $ROLE_ARN"
  echo "$ROLE_ARN"
}

# ─────────────────────────────────────────────
# STEP 0: CLEANUP
# ─────────────────────────────────────────────
log_step "STEP 0: Cleanup Existing Installs"

# Uninstall Helm releases
for RELEASE_NS in \
  "aws-load-balancer-controller:kube-system" \
  "external-secrets:external-secrets" \
  "cluster-autoscaler:kube-system" \
  "metrics-server:kube-system"; do
  RELEASE=$(echo $RELEASE_NS | cut -d: -f1)
  NS=$(echo $RELEASE_NS | cut -d: -f2)
  if helm status "$RELEASE" -n "$NS" &>/dev/null; then
    log_info "Uninstalling Helm release: $RELEASE (ns: $NS)"
    helm uninstall "$RELEASE" -n "$NS" --wait 2>/dev/null || true
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
  echo "  [WAIT] EBS CSI addon deletion..."
  for i in $(seq 1 24); do
    STATUS=$(aws eks describe-addon \
      --cluster-name $CLUSTER_NAME \
      --region $REGION \
      --addon-name aws-ebs-csi-driver \
      --query "addon.status" \
      --output text 2>/dev/null || echo "DELETED")
    log_info "Delete status: $STATUS (attempt $i/24)"
    [ "$STATUS" = "DELETED" ] && break
    [ $i -eq 24 ] && log_warn "Addon deletion timed out — continuing"
    sleep 10
  done
  log_ok "EBS CSI addon deleted"
else
  log_info "EBS CSI addon not installed — skipping"
fi

# Delete stale webhooks — these cause ESO install to fail
for WEBHOOK in aws-load-balancer-webhook; do
  kubectl delete mutatingwebhookconfigurations "$WEBHOOK" 2>/dev/null \
    && log_ok "Deleted mutating webhook: $WEBHOOK" \
    || log_info "No mutating webhook $WEBHOOK found"
  kubectl delete validatingwebhookconfigurations "$WEBHOOK" 2>/dev/null \
    && log_ok "Deleted validating webhook: $WEBHOOK" \
    || log_info "No validating webhook $WEBHOOK found"
done

log_ok "Cleanup complete"

# ─────────────────────────────────────────────
# STEP 1: IAM OIDC Provider
# ─────────────────────────────────────────────
log_step "STEP 1: IAM OIDC Provider"

eksctl utils associate-iam-oidc-provider \
  --region $REGION \
  --cluster $CLUSTER_NAME \
  --approve

log_ok "OIDC Provider: $OIDC_URL"

# ─────────────────────────────────────────────
# STEP 2: AWS Load Balancer Controller
# ─────────────────────────────────────────────
log_step "STEP 2: AWS Load Balancer Controller"

# IAM Policy
curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json \
  --no-cli-pager 2>/dev/null || log_info "LBC IAM policy already exists"

# IAM Role
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

# MUST be healthy before ESO install — LBC webhook blocks it otherwise
wait_for_deployment "kube-system" "aws-load-balancer-controller" 180
log_ok "Load Balancer Controller healthy"

# ─────────────────────────────────────────────
# STEP 3: External Secrets Operator
# ─────────────────────────────────────────────
log_step "STEP 3: External Secrets Operator"

# IAM Policy
cat > /tmp/eso-policy.json <<POLICY
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
POLICY

aws iam create-policy \
  --policy-name ExternalSecretsPolicy \
  --policy-document file:///tmp/eso-policy.json \
  --no-cli-pager 2>/dev/null || log_info "ESO IAM policy already exists"

# IAM Role
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
log_ok "External Secrets Operator healthy"

# ─────────────────────────────────────────────
# STEP 4: EBS CSI Driver
# ─────────────────────────────────────────────
log_step "STEP 4: EBS CSI Driver"

# IAM Role — this was the root cause bug (role was never created by eksctl)
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
  --service-account-role-arn "$EBS_ROLE_ARN" \
  --no-cli-pager

echo "  [WAIT] EBS CSI addon to become ACTIVE (up to 9 mins)..."
for i in $(seq 1 36); do
  STATUS=$(aws eks describe-addon \
    --cluster-name $CLUSTER_NAME \
    --region $REGION \
    --addon-name aws-ebs-csi-driver \
    --query "addon.status" \
    --output text 2>/dev/null || echo "UNKNOWN")
  ISSUES=$(aws eks describe-addon \
    --cluster-name $CLUSTER_NAME \
    --region $REGION \
    --addon-name aws-ebs-csi-driver \
    --query "addon.health.issues" \
    --output json 2>/dev/null || echo "[]")
  log_info "Status: $STATUS (attempt $i/36)"
  [ "$STATUS" = "ACTIVE" ] && break
  if [ "$ISSUES" != "[]" ] && [ "$ISSUES" != "null" ]; then
    log_warn "Issues: $ISSUES"
  fi
  if [ $i -eq 36 ]; then
    log_err "EBS CSI addon did not become ACTIVE. Full details:"
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
log_step "STEP 5: Cluster Autoscaler"

# IAM Policy
cat > /tmp/cas-policy.json <<POLICY
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
POLICY

aws iam create-policy \
  --policy-name ClusterAutoscalerPolicy \
  --policy-document file:///tmp/cas-policy.json \
  --no-cli-pager 2>/dev/null || log_info "CAS IAM policy already exists"

# IAM Role
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
log_ok "Cluster Autoscaler healthy"

# ─────────────────────────────────────────────
# STEP 6: Metrics Server
# ─────────────────────────────────────────────
log_step "STEP 6: Metrics Server"

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo update metrics-server

helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --wait \
  --timeout 120s

wait_for_deployment "kube-system" "metrics-server" 120
log_ok "Metrics Server healthy"

# ─────────────────────────────────────────────
# FINAL VERIFICATION
# ─────────────────────────────────────────────
log_step "FINAL VERIFICATION"

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
echo "--- IAM Role annotations ---"
for SA_NS in \
  "kube-system:aws-load-balancer-controller" \
  "kube-system:ebs-csi-controller-sa" \
  "kube-system:cluster-autoscaler" \
  "external-secrets:external-secrets"; do
  NS=$(echo $SA_NS | cut -d: -f1)
  SA=$(echo $SA_NS | cut -d: -f2)
  ARN=$(kubectl get sa $SA -n $NS \
    -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null \
    || echo "MISSING")
  printf "  %-45s -> %s\n" "$NS/$SA" "$ARN"
done

echo ""
echo "--- EBS CSI Addon ---"
aws eks describe-addon \
  --cluster-name $CLUSTER_NAME \
  --region $REGION \
  --addon-name aws-ebs-csi-driver \
  --query "addon.{Status:status,Version:addonVersion}" \
  --output table

echo ""
echo "======================================================"
echo "              EKS BOOTSTRAP COMPLETE                 "
echo "======================================================"