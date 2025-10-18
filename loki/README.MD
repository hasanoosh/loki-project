# Local Loki Stack (MinIO + Loki + Promtail + Grafana)

This repo runs a full Loki logging stack on a single-node Kubernetes (Docker Desktop/kind) using:

- **MinIO** (object storage, small footprint)
- **Loki** in **SimpleScalable** mode (backend/read/write + gateway)
- **Promtail** (ships K8s logs)
- **Grafana** (Explore logs)

Loki is installed **from my GitHub Helm repo** (GitHub Pages) at:
`https://hasanoosh.github.io/loki-project`

## Requirements

- Kubernetes cluster reachable from WSL (Docker Desktop’s K8s or kind).
- `kubectl` and `helm` installed in WSL.
- Internet access to pull images/charts.

## Quick Start

```bash
# clone or cd into your working folder
chmod +x bootstrap-loki.sh

# Multi-tenant (send X-Scope-OrgID headers):
./bootstrap-loki.sh --install

# OR Single-tenant (no headers required):
SINGLE_TENANT=true ./bootstrap-loki.sh --install
