# Secure Platform Engineering Lab with Grafana Alloy

This setup creates a MicroK8s cluster with a complete Grafana Observability Stack (LGTM), replacing the OpenTelemetry Collector with **Grafana Alloy**.

## Components
* **Orchestration**: MicroK8s
* **GitOps**: ArgoCD
* **Metric Store**: Mimir (Distributed)
* **Log Store**: Loki
* **Trace Store**: Tempo (Distributed)
* **Visuals**: Grafana
* **Telemetry**: Grafana Alloy (Collector)
* **Demo App**: OTel Astronomy Shop

## Prerequisites
* Ubuntu/Linux
* `make`, `git`, `curl`, `screen`
* No existing MicroK8s installation (or run `make remove-microk8s` first)

## Installation Guide

1.  **Install MicroK8s**:
    ```bash
    make install-microk8s
    ```

2.  **Install ArgoCD**:
    ```bash
    make install-argocd
    ```

3.  **Install Observability Stack (Mimir/Tempo/Grafana)**:
    ```bash
    make install-observability
    ```
    *This will generate secure random passwords for MinIO and Grafana and inject them automatically.*

4.  **Install Alloy & Demo App**:
    ```bash
    make install-otel
    ```

5.  **Access the Environment**:
    ```bash
    make forward
    ```
    *This will display all URLs and generated passwords.*

## Cleanup
To destroy Terraform resources:
```bash
make clean