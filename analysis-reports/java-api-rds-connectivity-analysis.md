# Java API to RDS Connectivity Analysis Report

## Executive Summary

As a Senior DevOps Architect, I've analyzed your complete Terraform infrastructure and Kubernetes manifests. The Java API service is failing to connect to RDS due to several critical networking, security, and configuration issues. This document outlines the root causes and recommended improvements.

## Critical Issues Identified

### 1. **Network Connectivity Problems**

#### Issue: DB Subnets Lack Internet/NAT Gateway Access
- **Problem**: DB private subnets (`10.0.48.0/24`, `10.0.49.0/24`) have route tables but no routes to NAT gateways
- **Impact**: RDS instance cannot resolve external dependencies or perform updates
- **Location**: `aws-eks-infra/modules/vpc/main.tf` lines 118-135

#### Issue: EKS Nodes Cannot Reach DB Subnets
- **Problem**: No explicit routing between EKS private subnets and DB subnets
- **Impact**: Java pods cannot establish TCP connections to RDS
- **Root Cause**: DB subnets are isolated without proper routing

### 2. **Security Group Configuration Issues**

#### Issue: Incorrect Security Group Reference in MongoDB SG
- **Problem**: MongoDB security group references `db-sg-ng` instead of `eks_node_sg`
- **Location**: `aws-eks-infra/modules/security-groups/main.tf` line 67
- **Impact**: Breaks security group chain for database access

#### Issue: Missing EKS Node Security Group Assignment
- **Problem**: EKS node groups don't have the custom security group attached
- **Location**: `aws-eks-infra/modules/eks/main.tf` - missing `remote_access` block
- **Impact**: Nodes use default security groups, breaking DB connectivity

### 3. **Kubernetes Configuration Problems**

#### Issue: External Secrets Service Account Mismatch
- **Problem**: ClusterSecretStore references `external-secrets` SA, but Java deployment uses `javaapi-sa`
- **Location**: `kubernetes-manifest/cluster-secret.yaml` vs `kubernetes-manifest/java-sa.yaml`
- **Impact**: External Secrets cannot authenticate to AWS Secrets Manager

#### Issue: Missing IRSA Role for External Secrets
- **Problem**: No IAM role created for External Secrets service account
- **Impact**: External Secrets operator cannot access AWS Secrets Manager

### 4. **Application Configuration Issues**

#### Issue: MySQL Connection String Parameters
- **Problem**: `useSSL=False` should be `useSSL=false` (lowercase)
- **Location**: `javaapi/src/main/resources/application.properties`
- **Impact**: Potential SSL configuration issues

#### Issue: Deprecated Hibernate Dialect
- **Problem**: Using `MySQL5InnoDBDialect` for MySQL 8.0
- **Location**: `javaapi/src/main/resources/application.properties`
- **Impact**: Compatibility issues with MySQL 8.0 features

## Recommended Improvements

### 1. **Fix Network Routing**

```hcl
# Add to vpc/main.tf - Route DB subnets through NAT gateways
resource "aws_route" "db_private_route" {
  count                  = length(var.availability_zones)
  route_table_id         = aws_route_table.db_private_rt[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.emart_nat_gw[count.index].id
}
```

### 2. **Fix Security Groups**

```hcl
# Fix MongoDB security group reference
resource "aws_security_group" "monogodb-sg-ng" {
  # ... existing config ...
  ingress {
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_node_sg.id]  # Fixed reference
  }
}
```

### 3. **Add Security Group to EKS Nodes**

```hcl
# Add to eks/main.tf
resource "aws_eks_node_group" "emart_node_group" {
  # ... existing config ...
  
  remote_access {
    ec2_ssh_key = var.ssh_key_name  # Add this variable
    source_security_group_ids = [var.additional_security_group_ids]
  }
}
```

### 4. **Create IRSA Role for External Secrets**

```hcl
# Add new module: modules/iam/external-secrets.tf
resource "aws_iam_role" "external_secrets_role" {
  name = "${var.cluster_name}-external-secrets-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Condition = {
        StringEquals = {
          "${var.oidc_provider}:sub" = "system:serviceaccount:external-secrets-system:external-secrets"
          "${var.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "external_secrets_policy" {
  name = "${var.cluster_name}-external-secrets-policy"
  role = aws_iam_role.external_secrets_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = var.secrets_arn
    }]
  })
}
```

### 5. **Fix Application Configuration**

```properties
# Update application.properties
server.port=9000
spring.datasource.url=jdbc:mysql://${DB_HOST}:3306/${DB_NAME}?allowPublicKeyRetrieval=true&useSSL=false&serverTimezone=UTC
spring.datasource.username=${DB_USERNAME}
spring.datasource.password=${DB_PASSWORD}

# Use correct dialect for MySQL 8.0
spring.jpa.properties.hibernate.dialect=org.hibernate.dialect.MySQL8Dialect
spring.jpa.hibernate.ddl-auto=update

# Add connection pool settings
spring.datasource.hikari.maximum-pool-size=10
spring.datasource.hikari.minimum-idle=5
spring.datasource.hikari.connection-timeout=20000
spring.datasource.hikari.idle-timeout=300000
```

### 6. **Fix Kubernetes Service Account**

```yaml
# Update cluster-secret.yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-south-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets  # Ensure this SA exists
            namespace: external-secrets-system
```

### 7. **Add Health Checks and Monitoring**

```yaml
# Add to javaapi-deploy.yaml
spec:
  template:
    spec:
      containers:
      - name: javaapi
        # ... existing config ...
        livenessProbe:
          httpGet:
            path: /actuator/health
            port: 9000
          initialDelaySeconds: 60
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /actuator/health/readiness
            port: 9000
          initialDelaySeconds: 30
          periodSeconds: 10
```

## Implementation Priority

### Phase 1 (Critical - Fix Immediately)
1. Fix DB subnet routing to NAT gateways
2. Correct security group references
3. Create and assign IRSA role for External Secrets
4. Fix application.properties configuration

### Phase 2 (High Priority)
1. Add security groups to EKS node groups
2. Implement proper health checks
3. Add connection pooling configuration
4. Set up monitoring and logging

### Phase 3 (Medium Priority)
1. Implement network policies
2. Add resource quotas and limits
3. Set up backup and disaster recovery
4. Implement secrets rotation

## Security Recommendations

1. **Enable VPC Flow Logs** for network troubleshooting
2. **Implement Network Policies** to restrict pod-to-pod communication
3. **Use AWS Systems Manager Session Manager** instead of SSH access
4. **Enable RDS encryption at rest and in transit**
5. **Implement least privilege IAM policies**

## Monitoring and Observability

1. **CloudWatch Container Insights** for EKS monitoring
2. **RDS Performance Insights** for database monitoring
3. **AWS X-Ray** for distributed tracing
4. **Prometheus and Grafana** for custom metrics

## Cost Optimization

1. **Use Spot instances** for non-critical workloads
2. **Implement cluster autoscaling**
3. **Right-size RDS instances** based on actual usage
4. **Use gp3 storage** for better cost/performance ratio

## Conclusion

The primary issue preventing Java API connectivity to RDS is the network isolation of DB subnets combined with security group misconfigurations. Implementing the Phase 1 fixes will resolve the immediate connectivity issues. The additional recommendations will improve security, reliability, and maintainability of the infrastructure.

---
*Generated by: Senior DevOps Architect Analysis*  
*Date: $(date)*  
*Status: Not for commit - Analysis only*