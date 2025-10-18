#!/usr/bin/env bash
# bootstrap-loki.sh
# Local Loki stack on a single node with MinIO, Promtail, Grafana.
# Works in WSL/Ubuntu. Requires kubectl + helm installed and a working kube-context.

set -euo pipefail

### --------- CONFIG (change if you like) ---------
# Your public Helm repo (GitHub Pages) that serves the Loki chart index.yaml
HELM_REPO_URL="${HELM_REPO_URL:-https://hasanoosh.github.io/loki-project}"
HELM_REPO_NAME="${HELM_REPO_NAME:-mygithub}"     # name to add in 'helm repo add'
LOKI_CHART_NAME="${LOKI_CHART_NAME:-loki}"       # chart name inside that repo (usually 'loki')
LOKI_NS="${LOKI_NS:-loki}"
MINIO_NS="${MINIO_NS:-minio}"
# Choose tenant header (ignored in single-tenant mode)
TENANT_ID="${TENANT_ID:-tenant1}"
# Single-tenant mode? ("true" disables auth; "false" keeps multi-tenant)
SINGLE_TENANT="${SINGLE_TENANT:-false}"

# Where to write values files (defaults to current dir)
OUT_DIR="${OUT_DIR:-$(pwd)}"
### -----------------------------------------------

msg() { echo -e "\033[1;36m[+] $*\033[0m"; }
err() { echo -e "\033[1;31m[!] $*\033[0m" >&2; }

need() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing '$1'. Please install it and re-run."; exit 1; }
}

usage() {
  cat <<EOF
Usage: $0 [--install] [--uninstall] [--single-tenant] [--out DIR] [--repo-url URL]

Flags:
  --install           Install/upgrade MinIO, Loki, Promtail, Grafana (default if no flag).
  --uninstall         Remove Loki/Promtail/Grafana/MinIO and their namespaces.
  --single-tenant     Run Loki with auth_disabled (no X-Scope-OrgID needed).
  --out DIR           Directory to place values files (default: current dir).
  --repo-url URL      Your GitHub Pages Helm repo URL (default: $HELM_REPO_URL)

Env vars you can override:
  HELM_REPO_URL, HELM_REPO_NAME, LOKI_CHART_NAME, LOKI_NS, MINIO_NS, TENANT_ID, SINGLE_TENANT, OUT_DIR
EOF
}

INSTALL=1
UNINSTALL=0

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) INSTALL=1; shift;;
    --uninstall) UNINSTALL=1; INSTALL=0; shift;;
    --single-tenant) SINGLE_TENANT=true; shift;;
    --out) OUT_DIR="$2"; shift 2;;
    --repo-url) HELM_REPO_URL="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 1;;
  esac
done

need kubectl
need helm

if [[ $UNINSTALL -eq 1 ]]; then
  msg "Uninstalling Grafana, Promtail, Loki, and MinIO…"
  helm uninstall grafana -n "$LOKI_NS" 2>/dev/null || true
  helm uninstall promtail -n "$LOKI_NS" 2>/dev/null || true
  helm uninstall loki -n "$LOKI_NS" 2>/dev/null || true
  helm uninstall minio -n "$MINIO_NS" 2>/dev/null || true
  kubectl delete ns "$LOKI_NS" "$MINIO_NS" 2>/dev/null || true
  msg "Done."
  exit 0
fi

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

msg "Adding Helm repos…"
helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" >/dev/null 2>&1 || true
helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

msg "Ensuring namespaces exist…"
kubectl create ns "$LOKI_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create ns "$MINIO_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

msg "Installing/Upgrading MinIO (small, no persistence, with loki buckets)…"
helm upgrade --install minio minio/minio -n "$MINIO_NS" \
  --set accessKey=minioadmin \
  --set secretKey=minioadmin \
  --set mode=standalone \
  --set-json 'buckets=[{"name":"loki","policy":"none","purge":false},{"name":"loki-ruler","policy":"none","purge":false},{"name":"loki-admin","policy":"none","purge":false}]' \
  --set persistence.enabled=false \
  --set resources.requests.memory=256Mi \
  --set resources.requests.cpu=100m \
  --set resources.limits.memory=1Gi >/dev/null

msg "Waiting for MinIO pod to be Ready…"
kubectl -n "$MINIO_NS" wait --for=condition=Ready pod -l app=minio --timeout=180s

msg "Writing loki-values.yaml…"
cat > loki-values.yaml <<'YAML'
deploymentMode: SimpleScalable

loki:
  storage:
    type: s3
    use_thanos_objstore: false
    bucketNames:
      chunks: loki
      ruler: loki-ruler
      admin: loki-admin
    s3:
      s3: http://minio.minio.svc.cluster.local:9000
      endpoint: minio.minio.svc.cluster.local:9000
      access_key_id: minioadmin
      secret_access_key: minioadmin
      s3ForcePathStyle: true
      insecure: true

  commonConfig:
    replication_factor: 1

  limits_config:
    allow_structured_metadata: false

  schemaConfig:
    configs:
      - from: 2024-01-01
        store: boltdb-shipper
        object_store: s3
        schema: v13
        index:
          prefix: index_
          period: 24h

backend:
  replicas: 1
  resources:
    requests: { cpu: "100m", memory: "256Mi" }

read:
  replicas: 1
  resources:
    requests: { cpu: "100m", memory: "256Mi" }

write:
  replicas: 1
  resources:
    requests: { cpu: "100m", memory: "256Mi" }

resultsCache:
  enabled: false
chunksCache:
  enabled: false

gateway:
  enabled: true
  service:
    type: ClusterIP
YAML

if [[ "$SINGLE_TENANT" == "true" ]]; then
  msg "Enabling single-tenant mode (auth_disabled)…"
  # append
  awk '1; END{print "\nloki:\n  auth_enabled: false"}' loki-values.yaml > loki-values.tmp && mv loki-values.tmp loki-values.yaml
fi

msg "Installing/Upgrading Loki from your Helm repo: $HELM_REPO_URL"
helm upgrade --install loki "$HELM_REPO_NAME/$LOKI_CHART_NAME" -n "$LOKI_NS" -f loki-values.yaml >/dev/null

msg "Waiting for Loki targets to be Ready…"
kubectl -n "$LOKI_NS" rollout status sts/loki-backend --timeout=300s
kubectl -n "$LOKI_NS" rollout status sts/loki-write   --timeout=300s
kubectl -n "$LOKI_NS" rollout status deploy/loki-read --timeout=300s

msg "Writing promtail-values.yaml…"
cat > promtail-values.yaml <<'YAML'
config:
  clients:
    - url: http://loki-gateway.loki.svc.cluster.local/loki/api/v1/push
  snippets:
    pipelineStages:
      - cri: {}    # parse containerd/cri logs
resources:
  requests:
    cpu: 50m
    memory: 64Mi
YAML

msg "Installing/Upgrading Promtail…"
helm upgrade --install promtail grafana/promtail -n "$LOKI_NS" -f promtail-values.yaml >/dev/null
kubectl -n "$LOKI_NS" rollout status ds/promtail --timeout=300s

msg "Writing grafana-values.yaml…"
if [[ "$SINGLE_TENANT" == "true" ]]; then
cat > grafana-values.yaml <<'YAML'
adminUser: admin
adminPassword: admin123

datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        isDefault: true
        url: http://loki-gateway.loki.svc.cluster.local

service:
  type: ClusterIP

resources:
  requests:
    cpu: 100m
    memory: 128Mi
YAML
else
cat > grafana-values.yaml <<YAML
adminUser: admin
adminPassword: admin123

datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        isDefault: true
        url: http://loki-gateway.${LOKI_NS}.svc.cluster.local
        jsonData:
          timeout: 60
          httpHeaderName1: X-Scope-OrgID
        secureJsonData:
          httpHeaderValue1: ${TENANT_ID}

service:
  type: ClusterIP

resources:
  requests:
    cpu: 100m
    memory: 128Mi
YAML
fi

msg "Installing/Upgrading Grafana…"
helm upgrade --install grafana grafana/grafana -n "$LOKI_NS" -f grafana-values.yaml >/dev/null
kubectl -n "$LOKI_NS" rollout status deploy/grafana --timeout=300s

msg "All set! Next steps:"
echo "  1) Port-forward Loki gateway:  kubectl -n ${LOKI_NS} port-forward svc/loki-gateway 3100:80"
if [[ "$SINGLE_TENANT" == "true" ]]; then
  echo "  2) Test query (single-tenant, no header):"
  echo "     curl -s 'http://127.0.0.1:3100/loki/api/v1/query?query=%7Bnamespace%3D%22${LOKI_NS}%22%7D' | head"
else
  echo "  2) Test query (multi-tenant):"
  echo "     curl -s -H 'X-Scope-OrgID: ${TENANT_ID}' 'http://127.0.0.1:3100/loki/api/v1/query?query=%7Bnamespace%3D%22${LOKI_NS}%22%7D' | head"
fi
echo "  3) Port-forward Grafana:       kubectl -n ${LOKI_NS} port-forward svc/grafana 3000:80"
echo "     Open http://localhost:3000  (admin / admin123)"
