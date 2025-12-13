# Secure Platform Engineering Lab: Grafana LGTM Stack + OnCall

This project creates a complete, local Observability Platform on MicroK8s using the **Grafana LGTM Stack** (Loki, Grafana, Tempo, Mimir) with **Grafana OnCall** embedded. It replaces the standard OpenTelemetry Collector with **Grafana Alloy**.

## Architecture
* **Orchestration**: MicroK8s (Local K8s)
* **GitOps**: ArgoCD
* **Metrics**: Mimir (Distributed)
* **Logs**: Loki (Distributed)
* **Traces**: Tempo (Distributed)
* **Incident Response**: Grafana OnCall
* **Visuals**: Grafana
* **Telemetry Collection**: Grafana Alloy
* **Demo App**: OpenTelemetry Astronomy Shop
* **Storage**: MinIO (S3 Compatible)

## Security
* All passwords (MinIO, Grafana, Databases) are **randomly generated** by Terraform at runtime.
* Secrets are injected directly into Kubernetes Secrets and Helm values.
* No sensitive data is stored in Git or on disk.

## Prerequisites
* Ubuntu/Linux environment
* `make`, `git`, `curl`, `screen`, `terraform` installed.

## Installation Guide

1.  **Install MicroK8s**:
    ```bash
    make install-microk8s
    ```
    *Installs MicroK8s, enables required addons (dns, helm3, hostpath-storage), and configures your user permissions.*

2.  **Install ArgoCD**:
    ```bash
    make install-argocd
    ```
    *Deploys ArgoCD to the `argocd-system` namespace.*

3.  **Install Observability Stack**:
    ```bash
    make install-observability
    ```
    * Generates secure random passwords.
    * Deploys MinIO and runs a Job to create required S3 buckets.
    * Deploys Mimir, Loki, Tempo, Grafana, and OnCall via the `lgtm-distributed` chart.

4.  **Install Alloy & Demo App**:
    ```bash
    make install-otel
    ```
    *Deploys Grafana Alloy (configured to send data to the LGTM stack) and the Astronomy Shop demo application.*

## Access & Credentials

Run the port-forward script to expose services and retrieve the generated passwords:

```bash
make forward