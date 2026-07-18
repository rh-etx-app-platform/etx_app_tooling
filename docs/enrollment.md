# Secondary Cluster Enrollment Guide

This guide explains how to enroll a secondary OpenShift cluster with the primary cluster's ArgoCD instance for multi-cluster deployment scenarios.

## Overview

In the ETX App Platform workshop, the promotion pipeline lab requires two clusters:

- **Factory Cluster (Primary)**: Where ArgoCD, GitLab, and development environment run
- **Runtime Cluster (Secondary)**: Where staging and production applications are deployed

ArgoCD on the factory cluster needs credentials to deploy applications to the runtime cluster. This process is called "cluster enrollment."

## Prerequisites

- Two OpenShift clusters provisioned and accessible
- `oc` CLI installed on your workstation
- cluster-admin access to both clusters
- Cluster credentials from RHDP provisioning emails

## Method 1: Automated Script

### Step 1: Download the Script

```bash
curl -o enroll-secondary-cluster.sh \
  https://raw.githubusercontent.com/rh-etx-app-platform/etx_app_tooling/main/scripts/enroll-secondary-cluster.sh

chmod +x enroll-secondary-cluster.sh
```

### Step 2: Edit Configuration

Open the script and update the CONFIGURATION section with your cluster details:

```bash
# Runtime cluster (from RHDP email for "App Platform Runtime")
export RUNTIME_API="https://api.cluster-xxxxx.dyn.redhatworkshops.io:6443"
export RUNTIME_USER="admin"
export RUNTIME_PASSWORD="your-runtime-password"

# Factory cluster (from RHDP email for "App Platform Software Factory")
export FACTORY_API="https://api.cluster-yyyyy.dyn.redhatworkshops.io:6443"
export FACTORY_USER="admin"
export FACTORY_PASSWORD="your-factory-password"

# ArgoCD settings (leave defaults)
export CLUSTER_NAME="staging"
export ARGOCD_NAMESPACE="etx-app-dev"
```

### Step 3: Run the Script

```bash
./enroll-secondary-cluster.sh
```

The script will:
1. Create ArgoCD manager account on runtime cluster
2. Generate authentication token
3. Create staging namespaces on runtime cluster
4. Register runtime cluster in factory ArgoCD
5. Validate the enrollment

### Step 4: Verify in ArgoCD UI

1. Open ArgoCD on factory cluster
2. Navigate to Settings > Clusters
3. Verify "staging" cluster appears in the list

## Method 2: Manual Steps

If you prefer to execute commands step-by-step for learning purposes:

### Step 1: Prepare Runtime Cluster

Login to your runtime cluster:

```bash
oc login https://api.cluster-YOUR-RUNTIME.dyn.redhatworkshops.io:6443 \
  -u admin -p YOUR_PASSWORD
```

Create ArgoCD manager ServiceAccount:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
EOF
```

Grant cluster-admin permissions:

```bash
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
EOF
```

Generate authentication token:

```bash
TOKEN=$(oc create token argocd-manager -n kube-system --duration=8760h)
echo $TOKEN
```

**IMPORTANT**: Save this token - you'll need it in the next step.

Create staging namespaces:

```bash
oc create namespace etx-app-staging
oc create namespace etx-app-prod
```

### Step 2: Register Runtime Cluster in Factory ArgoCD

Switch to factory cluster:

```bash
oc login https://api.cluster-YOUR-FACTORY.dyn.redhatworkshops.io:6443 \
  -u admin -p YOUR_PASSWORD
```

Set runtime cluster API URL:

```bash
RUNTIME_API="https://api.cluster-YOUR-RUNTIME.dyn.redhatworkshops.io:6443"
```

Create ArgoCD cluster secret:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cluster-staging
  namespace: etx-app-dev
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: staging
  server: ${RUNTIME_API}
  config: |
    {
      "bearerToken": "${TOKEN}",
      "tlsClientConfig": {
        "insecure": true
      }
    }
EOF
```

### Step 3: Verify Enrollment

Check cluster secret exists:

```bash
oc get secret cluster-staging -n etx-app-dev
```

Verify in ArgoCD UI:
1. Open ArgoCD: https://argocd-server-etx-app-dev.apps.cluster-YOUR-FACTORY.dyn.redhatworkshops.io
2. Login with Keycloak SSO
3. Go to Settings > Clusters
4. Verify "staging" cluster is listed

## What Was Created

### On Runtime Cluster

- **ServiceAccount**: `argocd-manager` in `kube-system` namespace
- **ClusterRoleBinding**: Grants cluster-admin to argocd-manager
- **Namespaces**: `etx-app-staging`, `etx-app-prod`

### On Factory Cluster

- **Secret**: `cluster-staging` in `etx-gitops` namespace containing:
  - Runtime cluster API URL
  - Authentication token (valid for 1 year)
  - TLS configuration

## Using the Enrolled Cluster

### Deploy Application to Runtime Cluster

Create an ArgoCD Application targeting the runtime cluster:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app-staging
  namespace: etx-app-dev
spec:
  project: default
  source:
    repoURL: https://gitlab.apps.cluster-factory.example.com/myapp/gitops.git
    path: environments/staging
    targetRevision: main
  destination:
    name: staging              # References enrolled cluster by name
    namespace: etx-app-staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Promotion Pipeline

The promotion pipeline in the workshop uses this enrollment to:

1. Build container image on factory cluster
2. Push image to Quay registry
3. Update GitOps repository
4. ArgoCD syncs Application to runtime cluster
5. Application runs on runtime cluster (staging environment)

## Troubleshooting

### Cluster Not Appearing in ArgoCD

Check cluster secret exists:
```bash
oc get secret cluster-staging -n etx-app-dev -o yaml
```

Check ArgoCD logs:
```bash
oc logs -n etx-app-dev deployment/etx-gitops-application-controller
```

### Connection Failed

Verify runtime cluster is accessible from factory:
```bash
curl -k https://api.cluster-runtime.example.com:6443/healthz
```

Check token is valid:
```bash
oc login --token="$TOKEN" --server="$RUNTIME_API"
```

### Permission Denied

Verify argocd-manager has cluster-admin:
```bash
oc get clusterrolebinding argocd-manager-binding -o yaml
```

## Security Considerations

### Token Expiration

The enrollment token is valid for 8760 hours (1 year). After expiration:
1. Generate new token on runtime cluster
2. Update cluster secret on factory cluster

### Permissions

The argocd-manager ServiceAccount has cluster-admin permissions on the runtime cluster. This is required for ArgoCD to deploy any type of resource. In production environments:

- Use more restrictive RBAC (namespace-scoped)
- Rotate tokens regularly
- Monitor ArgoCD audit logs

### TLS Verification

The script uses `insecure: true` for TLS to work with self-signed certificates in workshop environments. In production:

- Use valid certificates
- Set `insecure: false`
- Add CA certificate to cluster secret

## Additional Resources

- [ArgoCD Cluster Registration](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters)
- [Multi-Cluster Deployments](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters)
- [ETX App Platform Workshop](https://github.com/rh-etx-app-platform/etx_app_showroom_content)
