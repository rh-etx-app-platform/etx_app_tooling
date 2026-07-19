#!/bin/bash
# enroll-secondary-cluster.sh
#
# Enrolls a secondary OpenShift cluster with the primary cluster's ArgoCD instance.
# This enables multi-cluster deployments where ArgoCD on the factory cluster can
# deploy applications to the runtime cluster.
#
# Prerequisites:
# - oc CLI installed and authenticated
# - Access to both factory and runtime clusters
# - cluster-admin permissions on both clusters
#
# Usage:
#   1. Edit the CONFIGURATION section below with your cluster details
#   2. Run: ./scripts/enroll-secondary-cluster.sh
#
# For step-by-step manual instructions, see: docs/enrollment.md

set -euo pipefail

# CONFIGURATION - Edit these values before running
# =================================================

# Runtime cluster (secondary - where staging/prod apps will run)
RUNTIME_API="${RUNTIME_API:-https://api.cluster-runtime.example.com:6443}"
RUNTIME_USER="${RUNTIME_USER:-admin}"
RUNTIME_PASSWORD="${RUNTIME_PASSWORD:-changeme}"

# Factory cluster (primary - where ArgoCD runs)
FACTORY_API="${FACTORY_API:-https://api.cluster-factory.example.com:6443}"
FACTORY_USER="${FACTORY_USER:-admin}"
FACTORY_PASSWORD="${FACTORY_PASSWORD:-changeme}"

# ArgoCD cluster registration settings
CLUSTER_NAME="${CLUSTER_NAME:-staging}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-etx-app-dev}"
TOKEN_DURATION="${TOKEN_DURATION:-8760h}"

# =================================================

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Validate oc CLI is installed
if ! command -v oc >/dev/null 2>&1; then
    log_error "oc CLI not found. Please install OpenShift CLI."
    exit 1
fi

# Step 1: Prepare runtime cluster
log_step "Step 1: Preparing runtime cluster for ArgoCD management"

log_info "Logging into runtime cluster: ${RUNTIME_API}"
oc login "$RUNTIME_API" -u "$RUNTIME_USER" -p "$RUNTIME_PASSWORD" --insecure-skip-tls-verify=true >/dev/null

log_info "Creating ArgoCD manager ServiceAccount..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
  annotations:
    description: "ArgoCD service account for remote cluster management"
EOF

log_info "Granting cluster-admin permissions to ArgoCD manager..."
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-binding
  annotations:
    description: "Allows ArgoCD from factory cluster to manage resources on this cluster"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
EOF

log_info "Generating registration token (valid for ${TOKEN_DURATION})..."
TOKEN=$(oc create token argocd-manager -n kube-system --duration="$TOKEN_DURATION")

if [ -z "$TOKEN" ]; then
    log_error "Failed to generate token"
    exit 1
fi

log_info "Creating staging namespaces on runtime cluster..."
oc create namespace etx-app-staging 2>/dev/null || log_warn "Namespace etx-app-staging already exists"
oc create namespace etx-app-prod 2>/dev/null || log_warn "Namespace etx-app-prod already exists"

# Step 1.5: Deploy supporting services
log_step "Step 1.5: Deploying supporting services on runtime cluster"

log_info "Installing AMQ Streams (Kafka) operator..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: amq-streams
  namespace: openshift-operators
spec:
  channel: stable
  name: amq-streams
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

log_info "Installing OpenShift Pipelines (Tekton) operator..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

log_info "Waiting for operators to be ready (60s)..."
sleep 60

log_info "Deploying PostgreSQL database in etx-app-staging..."
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: parasol-db-secret
  namespace: etx-app-staging
type: Opaque
stringData:
  database-name: parasol
  database-user: parasol
  database-password: parasol
---
apiVersion: v1
kind: Service
metadata:
  name: parasol-db
  namespace: etx-app-staging
spec:
  ports:
    - name: postgresql
      port: 5432
      targetPort: 5432
  selector:
    app: parasol-db
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: parasol-db
  namespace: etx-app-staging
spec:
  replicas: 1
  selector:
    matchLabels:
      app: parasol-db
  template:
    metadata:
      labels:
        app: parasol-db
    spec:
      containers:
        - name: postgresql
          image: registry.redhat.io/rhel9/postgresql-16:latest
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRESQL_USER
              valueFrom:
                secretKeyRef:
                  name: parasol-db-secret
                  key: database-user
            - name: POSTGRESQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: parasol-db-secret
                  key: database-password
            - name: POSTGRESQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: parasol-db-secret
                  key: database-name
          volumeMounts:
            - name: postgresql-data
              mountPath: /var/lib/pgsql/data
          livenessProbe:
            exec:
              command:
                - /usr/libexec/check-container
                - --live
            initialDelaySeconds: 120
            timeoutSeconds: 10
          readinessProbe:
            exec:
              command:
                - /usr/libexec/check-container
            initialDelaySeconds: 5
            timeoutSeconds: 1
          resources:
            limits:
              memory: 512Mi
              cpu: 500m
            requests:
              memory: 256Mi
              cpu: 100m
      volumes:
        - name: postgresql-data
          emptyDir: {}
EOF

log_info "Deploying Kafka cluster in etx-app-staging..."
cat <<'EOF' | oc apply -f -
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: kafka
  namespace: etx-app-staging
  labels:
    strimzi.io/cluster: parasol-kafka
spec:
  replicas: 1
  roles:
    - controller
    - broker
  storage:
    type: ephemeral
---
apiVersion: kafka.strimzi.io/v1
kind: Kafka
metadata:
  name: parasol-kafka
  namespace: etx-app-staging
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 4.2.0
    metadataVersion: 4.2-IV0
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
  entityOperator:
    topicOperator: {}
    userOperator: {}
EOF

log_info "Creating Kafka topic 'intake' in etx-app-staging..."
cat <<'EOF' | oc apply -f -
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: intake
  namespace: etx-app-staging
  labels:
    strimzi.io/cluster: parasol-kafka
spec:
  partitions: 1
  replicas: 1
  config:
    retention.ms: 604800000
    segment.bytes: 1073741824
EOF

log_info "Supporting services deployment initiated (will take 2-3 minutes to be fully ready)"

# Step 2: Register runtime cluster in factory ArgoCD
log_step "Step 2: Registering runtime cluster in factory ArgoCD"

log_info "Logging into factory cluster: ${FACTORY_API}"
oc login "$FACTORY_API" -u "$FACTORY_USER" -p "$FACTORY_PASSWORD" --insecure-skip-tls-verify=true >/dev/null

log_info "Creating ArgoCD cluster secret..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${CLUSTER_NAME}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: cluster
  annotations:
    description: "Runtime cluster connection for multi-cluster deployments"
type: Opaque
stringData:
  name: ${CLUSTER_NAME}
  server: ${RUNTIME_API}
  config: |
    {
      "bearerToken": "${TOKEN}",
      "tlsClientConfig": {
        "insecure": true
      }
    }
EOF

# Step 3: Validate enrollment
log_step "Step 3: Validating enrollment"

if oc get secret "cluster-${CLUSTER_NAME}" -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
    log_info "Cluster secret verified: cluster-${CLUSTER_NAME}"
else
    log_error "Cluster secret not found"
    exit 1
fi

# Print summary
cat <<EOF

${GREEN}========================================
Enrollment Complete
========================================${NC}

Factory cluster:  ${FACTORY_API}
Runtime cluster:  ${RUNTIME_API}
ArgoCD namespace: ${ARGOCD_NAMESPACE}
Cluster name:     ${CLUSTER_NAME}

Supporting services deployed:
- PostgreSQL (parasol-db) in etx-app-staging
- Kafka cluster (parasol-kafka) in etx-app-staging
- Kafka topic (intake)
- AMQ Streams operator
- OpenShift Pipelines operator

Next steps:
1. Verify cluster in ArgoCD UI:
   - Navigate to Settings > Clusters
   - Look for '${CLUSTER_NAME}' cluster

2. Verify supporting services are ready:
   oc get pods -n etx-app-staging
   oc get kafka -n etx-app-staging
   oc get kafkatopic -n etx-app-staging

3. Create Applications targeting runtime cluster:
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   spec:
     destination:
       name: ${CLUSTER_NAME}
       namespace: etx-app-staging

4. Test deployment to runtime cluster

Documentation: https://github.com/rh-etx-app-platform/etx_app_tooling/blob/main/docs/enrollment.md
EOF
