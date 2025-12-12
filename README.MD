# Platform Engineering Lab: Grafana Enterprise Stack on MicroK8s

This project creates a local Multi-tenant Observability Platform using MicroK8s, ArgoCD, and the Grafana Stack (Mimir, Loki, Tempo, Grafana, Faro).

## Components
- **Orchestration**: MicroK8s (Local K8s)
- **GitOps**: ArgoCD
- **Observability**: Grafana LGTM Stack (Distributed Mode) + K6 + Faro
- **Telemetry**: OpenTelemetry Collectors (Gateway + DaemonSet)
- **Demo App**: OpenTelemetry Astronomy Shop

## Prerequisites
- Ubuntu/Linux environment
- `git`, `make`, `curl`, `screen` installed.
- **Important**: You must commit this folder to a Git repo for ArgoCD to sync.

## Quick Start

1. **Initialize Git**:
   ```bash
   git init
   git add .
   git commit -m "Initial commit"
   # Add your remote origin
   git remote add origin [https://github.com/YOUR_USER/YOUR_REPO.git](https://github.com/YOUR_USER/YOUR_REPO.git)
   git push -u origin master