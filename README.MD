
######### FILE BEGIN
# 🔭 Local Observability Stack (LGTM + MinIO + Alloy)

A production-ready, multi-tenant observability platform running locally on **K3s**. It uses **Terraform** for Infrastructure-as-Code and **ArgoCD** for GitOps deployment.

## 🏗 Architecture

| Component | Role | Details |
| :--- | :--- | :--- |
| **K3s** | Cluster | Lightweight Kubernetes distribution. |
| **ArgoCD** | GitOps | Manages all application deployments. |
| **MinIO** | Storage | S3-compatible backend for Mimir, Loki, and Tempo. |
| **Mimir** | Metrics | Multi-tenant Prometheus-compatible storage. |
| **Loki** | Logs | Multi-tenant Log aggregation (Single Binary). |
| **Tempo** | Traces | Multi-tenant Distributed Tracing. |
| **Alloy** | Collector | "Traffic Cop" router that tags data with Tenant IDs. |
| **Grafana** | Visuals | Multi-org setup with automated datasource provisioning. |

---

## 🚀 Quick Start

### 1. Prerequisites
* Linux/WSL2
* `make`, `curl`, `kubectl`
* `terraform`, `python3`

### 2. Installation
Run the master command to provision the cluster, install storage, and deploy the full stack:

```bash
make all
```

**What happens?**
1.  Installs **K3s**.
2.  Deploys **ArgoCD**.
3.  Provisions **MinIO** (S3) & generates credentials.
4.  Deploys **Mimir, Loki, Tempo** (configured for S3 & Multi-tenancy).
5.  Deploys **Grafana Alloy** (Configured as a multi-tenant router).
6.  Deploys **Grafana**.
7.  **Bootstraps Multi-tenancy:** Runs `scripts/manage.py` to create Organizations and Datasources automatically.

---

## 🔐 Multi-Tenancy & Access

This stack enforces strict multi-tenancy. Data is isolated by the `X-Scope-OrgID` header.

### Organizations
| Org Name | Tenant ID | Description |
| :--- | :--- | :--- |
| **Main Org** | `anonymous` | Admin view. |
| **platform-k8s** | `platform-k8s` | K8s System metrics (Nodes, Kubelet) & Pod logs. |
| **devteam-1** | `devteam-1` | Application data (Traces/Metrics) from the Demo Shop. |

### Routing Logic (Alloy)
* **System Data:** Alloy scrapes `kube-system` & `observability-prd` -> tags as `platform-k8s`.
* **App Data:** Alloy listens on OTLP ports -> tags as `devteam-1`.

---

## 🛠️ Usage & Utilities

### 📊 Access Dashboards
We provide a "Fancy" master script to manage access:

```bash
make forward
# OR
./scripts/portforward-all.sh start
```

| Service | Local URL | User | Password |
| :--- | :--- | :--- | :--- |
| **Grafana** | http://localhost:3000 | `admin` | *(Auto-fetched)* |
| **ArgoCD** | http://localhost:8081 | `admin` | *(Auto-fetched)* |
| **MinIO** | http://localhost:9001 | `admin` | *(Auto-fetched)* |
| **Shop App**| http://localhost:8080 | - | - |

### 🔄 Admin Tasks

**Bootstrap Organizations / Reset Tokens:**
If you need to regenerate Service Accounts or Datasources:
```bash
make bootstrap
```
*Results saved to `bootstrap-results.json`.*

**Clean Re-install of specific component:**
```bash
make uninstall-loki
make install-loki
```

**Uninstall Alloy (Collector):**
```bash
make uninstall-alloy
```

---

## 📁 Directory Structure

```text
.
├── k8s/
│   └── values/              # Helm Chart Values (Mimir, Loki, Tempo, Alloy, etc.)
├── scripts/
│   ├── manage.py            # Python script for Grafana API automation
│   ├── portforward-*.sh     # Auto-healing access scripts
│   └── setup-virtual-disk.sh
├── terraform/
│   └── main.tf              # Complete Infrastructure definition
├── Makefile                 # Master control plane
└── README.md
```

---

## ⚠️ Troubleshooting

**"Too many unhealthy instances" in Grafana?**
* Mimir/Loki/Tempo are configured with `replication_factor: 1` for this local single-node setup.
* Ensure pods are running: `kubectl get pods -n observability-prd`.
* If stuck, restart the component: `kubectl delete pod -n observability-prd -l app.kubernetes.io/name=mimir`.

**"Request signature does not match" (MinIO)?**
* MinIO credentials on disk don't match the Secret (likely due to Terraform regenerating the password while MinIO kept old data).
* Fix: `make uninstall-prereqs` (wipes PVC data) -> `make install-prereqs`.

**Alloy Error "illegal character U+0023"?**
* Use `//` for comments in Alloy configuration files (River syntax), not `#`.

**"Unable to connect with Loki"?**
* Ensure `auth_enabled: true` is set in Loki values and that Grafana Datasources are injecting the `X-Scope-OrgID` header (handled by `manage.py`).

---

## 🧨 Nuclear Option

To completely wipe the cluster and start fresh:

```bash
make nuke
```
######### FILE END