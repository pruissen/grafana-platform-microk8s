# -------------------------------------------------------------------
# 1. SECRET GENERATION
# -------------------------------------------------------------------
resource "random_password" "minio_root_password" {
  length  = 16
  special = false
}

resource "random_password" "grafana_admin_password" {
  length  = 16
  special = false
}

# -------------------------------------------------------------------
# 2. BASE INFRASTRUCTURE
# -------------------------------------------------------------------

# ArgoCD Installation
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd-system"
  create_namespace = false # Handled by Makefile
  version          = "7.7.16"

  values = [
    yamlencode({
      server = { insecure = true }
      configs = {
        cm = { "resource.customizations.ignoreDifferences.all" = "jsonPointers:\n  - /status" }
      }
    })
  ]
}

# -------------------------------------------------------------------
# 3. KUBERNETES SECRETS
# -------------------------------------------------------------------

# Secret for MinIO
resource "kubernetes_secret_v1" "minio_creds" {
  metadata {
    name      = "minio-creds"
    namespace = "observability-prd"
  }
  data = {
    rootUser     = "admin"
    rootPassword = random_password.minio_root_password.result
  }
}

# Secret for Grafana
resource "kubernetes_secret_v1" "grafana_creds" {
  metadata {
    name      = "grafana-admin-creds"
    namespace = "observability-prd"
  }
  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin_password.result
  }
}

# -------------------------------------------------------------------
# 4. ARGO CD APPLICATIONS
# -------------------------------------------------------------------

# APP 1: MinIO
resource "kubectl_manifest" "minio" {
  depends_on = [helm_release.argocd, kubernetes_secret_v1.minio_creds]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1", kind = "Application"
    metadata = { name = "minio-storage", namespace = "argocd-system" }
    spec = {
      project = "default"
      source = {
        repoURL = "https://charts.min.io/"
        chart   = "minio"
        targetRevision = "5.0.14"
        helm = {
          parameters = [
            { name = "mode", value = "standalone" },
            { name = "persistence.size", value = "10Gi" },
            { name = "existingSecret", value = "minio-creds" }
          ]
        }
      }
      destination = { server = "https://kubernetes.default.svc", namespace = "observability-prd" }
      syncPolicy = { automated = { prune = true, selfHeal = true } }
    }
  })
}

# APP 2: Mimir
resource "kubectl_manifest" "mimir" {
  depends_on = [kubectl_manifest.minio]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1", kind = "Application"
    metadata = { name = "mimir", namespace = "argocd-system" }
    spec = {
      project = "default"
      source = {
        repoURL = "https://grafana.github.io/helm-charts"
        chart   = "mimir-distributed"
        targetRevision = "5.1.0"
        helm = {
          values = templatefile("${path.module}/../k8s/values/mimir.yaml", {
            s3_secret_key = random_password.minio_root_password.result
          })
        }
      }
      destination = { server = "https://kubernetes.default.svc", namespace = "observability-prd" }
      syncPolicy = { automated = { prune = true, selfHeal = true } }
    }
  })
}

# APP 3: Tempo
resource "kubectl_manifest" "tempo" {
  depends_on = [kubectl_manifest.minio]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1", kind = "Application"
    metadata = { name = "tempo", namespace = "argocd-system" }
    spec = {
      project = "default"
      source = {
        repoURL = "https://grafana.github.io/helm-charts"
        chart   = "tempo-distributed"
        targetRevision = "1.7.0"
        helm = {
          values = templatefile("${path.module}/../k8s/values/tempo.yaml", {
            s3_secret_key = random_password.minio_root_password.result
          })
        }
      }
      destination = { server = "https://kubernetes.default.svc", namespace = "observability-prd" }
      syncPolicy = { automated = { prune = true, selfHeal = true } }
    }
  })
}

# APP 4: Loki
resource "kubectl_manifest" "loki" {
  depends_on = [helm_release.argocd]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1", kind = "Application"
    metadata = { name = "loki", namespace = "argocd-system" }
    spec = {
      project = "default"
      source = {
        repoURL = "https://grafana.github.io/helm-charts"
        chart   = "loki-stack"
        targetRevision = "2.9.11"
      }
      destination = { server = "https://kubernetes.default.svc", namespace = "observability-prd" }
      syncPolicy = { automated = { prune = true, selfHeal = true } }
    }
  })
}

# APP 5: Grafana
resource "kubectl_manifest" "grafana" {
  depends_on = [kubectl_manifest.mimir, kubectl_manifest.tempo, kubernetes_secret_v1.grafana_creds]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1", kind = "Application"
    metadata = { name = "grafana", namespace = "argocd-system" }
    spec = {
      project = "default"
      source = {
        repoURL = "https://grafana.github.io/helm-charts"
        chart   = "grafana"
        targetRevision = "8.5.1"
        helm = {
          parameters = [
            { name = "admin.existingSecret", value = "grafana-admin-creds" },
            { name = "admin.userKey", value = "admin-user" },
            { name = "admin.passwordKey", value = "admin-password" }
          ]
          values = file("${path.module}/../k8s/values/grafana.yaml")
        }
      }
      destination = { server = "https://kubernetes.default.svc", namespace = "observability-prd" }
      syncPolicy = { automated = { prune = true, selfHeal = true } }
    }
  })
}

# APP 6: Grafana Alloy (Replaces OTel Collector)
resource "kubectl_manifest" "alloy" {
  depends_on = [kubectl_manifest.mimir, kubectl_manifest.tempo]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1", kind = "Application"
    metadata = { name = "alloy", namespace = "argocd-system" }
    spec = {
      project = "default"
      source = {
        repoURL = "https://grafana.github.io/helm-charts"
        chart   = "alloy"
        targetRevision = "0.9.1"
        helm = {
          values = file("${path.module}/../k8s/values/alloy.yaml")
        }
      }
      destination = { server = "https://kubernetes.default.svc", namespace = "observability-prd" }
      syncPolicy = { automated = { prune = true, selfHeal = true } }
    }
  })
}

# APP 7: Astronomy Shop Demo
resource "kubectl_manifest" "astronomy" {
  depends_on = [kubectl_manifest.alloy]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1", kind = "Application"
    metadata = { name = "astronomy-shop", namespace = "argocd-system" }
    spec = {
      project = "default"
      source = {
        repoURL = "https://open-telemetry.github.io/opentelemetry-helm-charts"
        chart   = "opentelemetry-demo"
        targetRevision = "0.26.0"
        helm = {
          parameters = [
            { name = "opentelemetry-collector.enabled", value = "false" },
            { name = "jaeger.enabled", value = "false" },
            { name = "prometheus.enabled", value = "false" },
            { name = "grafana.enabled", value = "false" },
            { name = "default.env.OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://alloy.observability-prd.svc:4317" }
          ]
        }
      }
      destination = { server = "https://kubernetes.default.svc", namespace = "astronomy-shop" }
      syncPolicy = { automated = { prune = true, selfHeal = true } }
    }
  })
}