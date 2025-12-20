# terraform/main.tf

# -------------------------------------------------------------------
# 1. PROVIDERS & CONFIG
# -------------------------------------------------------------------
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

provider "kubectl" {
  config_path = "~/.kube/config"
}

# -------------------------------------------------------------------
# 2. NAMESPACES
# -------------------------------------------------------------------
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd-system"
  }
}

resource "kubernetes_namespace" "observability" {
  metadata {
    name = "observability-prd"
  }
}

resource "kubernetes_namespace" "devteam_1" {
  metadata {
    name = "devteam-1"
  }
}

# -------------------------------------------------------------------
# 3. ARGOCD
# -------------------------------------------------------------------
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "5.51.6"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }
  set {
    name  = "redis-ha.enabled"
    value = "false"
  }
  set {
    name  = "controller.replicas"
    value = "1"
  }
  set {
    name  = "server.replicas"
    value = "1"
  }
  set {
    name  = "repoServer.replicas"
    value = "1"
  }
}

# -------------------------------------------------------------------
# 4. SHARED SECRETS & CREDENTIALS
# -------------------------------------------------------------------

# A. Generate Random Password (Shared by all components)
resource "random_password" "minio_root_password" {
  length  = 24
  special = false
}

# B. Secret for MinIO Server (Used by Loki's Embedded MinIO)
resource "kubernetes_secret_v1" "minio_creds" {
  metadata {
    name      = "minio-creds"
    namespace = "observability-prd"
  }
  data = {
    # Keys expected by the MinIO Helm Chart
    rootUser     = "admin"
    rootPassword = random_password.minio_root_password.result
  }
  type = "Opaque"
}

# C. Secrets for Clients (Mimir, Loki, Tempo) to access MinIO
# ⚠️ CRITICAL: Using AWS_... key names allows automatic detection by SDKs.

resource "kubernetes_secret_v1" "mimir_s3_creds" {
  metadata {
    name      = "mimir-s3-credentials"
    namespace = "observability-prd"
  }
  data = {
    AWS_ACCESS_KEY_ID     = "admin"
    AWS_SECRET_ACCESS_KEY = random_password.minio_root_password.result
  }
  type = "Opaque"
}

resource "kubernetes_secret_v1" "loki_s3_creds" {
  metadata {
    name      = "loki-s3-credentials"
    namespace = "observability-prd"
  }
  data = {
    AWS_ACCESS_KEY_ID     = "admin"
    AWS_SECRET_ACCESS_KEY = random_password.minio_root_password.result
  }
  type = "Opaque"
}

resource "kubernetes_secret_v1" "tempo_s3_creds" {
  metadata {
    name      = "tempo-s3-credentials"
    namespace = "observability-prd"
  }
  data = {
    AWS_ACCESS_KEY_ID     = "admin"
    AWS_SECRET_ACCESS_KEY = random_password.minio_root_password.result
  }
  type = "Opaque"
}

# D. Kube State Metrics
resource "helm_release" "ksm" {
  name       = "kube-state-metrics"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-state-metrics"
  namespace  = "observability-prd"
  version    = "5.16.0"
}

# -------------------------------------------------------------------
# 5. LOKI (Logs + Embedded MinIO)
# -------------------------------------------------------------------
resource "kubectl_manifest" "loki" {
  depends_on = [
    helm_release.argocd, 
    kubernetes_secret_v1.loki_s3_creds, 
    kubernetes_secret_v1.minio_creds
  ]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "loki"
      namespace  = "argocd-system"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "observability-prd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
      source = {
        repoURL        = "https://grafana.github.io/helm-charts"
        chart          = "loki"
        targetRevision = "6.24.0" # Stable single-binary version
        helm = {
          values = file("${path.module}/../k8s/values/loki.yaml")
        }
      }
    }
  })
}

# -------------------------------------------------------------------
# 6. MIMIR (Metrics - Distributed)
# -------------------------------------------------------------------
resource "kubectl_manifest" "mimir" {
  depends_on = [
    helm_release.argocd, 
    kubectl_manifest.loki, 
    kubernetes_secret_v1.mimir_s3_creds
  ]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "mimir"
      namespace  = "argocd-system"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "observability-prd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
      source = {
        repoURL        = "https://grafana.github.io/helm-charts"
        chart          = "mimir-distributed"
        # 🔙 REVERTED: Back to the rock-solid 5.x series
        targetRevision = "5.6.0"
        helm = {
          values = file("${path.module}/../k8s/values/mimir.yaml")
        }
      }
    }
  })
}

# -------------------------------------------------------------------
# 7. TEMPO (Traces - Monolithic)
# -------------------------------------------------------------------
resource "kubectl_manifest" "tempo" {
  depends_on = [
    helm_release.argocd, 
    kubectl_manifest.loki, # Loki provides S3
    kubernetes_secret_v1.tempo_s3_creds
  ]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "tempo"
      namespace  = "argocd-system"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "observability-prd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
      source = {
        repoURL        = "https://grafana.github.io/helm-charts"
        # ✅ CHANGED: Switched to Monolithic chart
        chart          = "tempo"
        targetRevision = "1.10.1" 
        helm = {
          values = file("${path.module}/../k8s/values/tempo.yaml")
        }
      }
    }
  })
}

# -------------------------------------------------------------------
# 8. GRAFANA
# -------------------------------------------------------------------
resource "random_password" "grafana_admin_password" {
  length  = 16
  special = false
}

resource "kubernetes_secret_v1" "grafana_creds" {
  metadata {
    name      = "grafana-admin-creds"
    namespace = "observability-prd"
  }
  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin_password.result
  }
  type = "Opaque"
}

resource "kubectl_manifest" "grafana" {
  depends_on = [
    helm_release.argocd, 
    kubernetes_secret_v1.grafana_creds,
    kubectl_manifest.mimir,
    kubectl_manifest.loki,
    kubectl_manifest.tempo
  ]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "grafana"
      namespace  = "argocd-system"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "observability-prd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
      source = {
        repoURL        = "https://grafana.github.io/helm-charts"
        chart          = "grafana"
        targetRevision = "8.5.1" # 🚀 Updated
        helm = {
          values = file("${path.module}/../k8s/values/grafana.yaml")
        }
      }
    }
  })
}

# -------------------------------------------------------------------
# 9. ALLOY
# -------------------------------------------------------------------
resource "kubectl_manifest" "alloy" {
  depends_on = [
    helm_release.argocd, 
    kubectl_manifest.mimir, 
    kubectl_manifest.loki, 
    kubectl_manifest.tempo
  ]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "alloy"
      namespace  = "argocd-system"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "observability-prd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
      source = {
        repoURL        = "https://grafana.github.io/helm-charts"
        chart          = "alloy"
        targetRevision = "1.5.1" # 🚀 Updated
        helm = {
          values = file("${path.module}/../k8s/values/alloy.yaml")
        }
      }
    }
  })
}

# -------------------------------------------------------------------
# 10. OTEL DEMO (Astronomy Shop)
# -------------------------------------------------------------------
resource "kubectl_manifest" "astronomy_shop" {
  depends_on = [
    kubectl_manifest.alloy,
    kubernetes_namespace.devteam_1
  ]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "astronomy-shop"
      namespace  = "argocd-system"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "devteam-1"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
      source = {
        repoURL        = "https://open-telemetry.github.io/opentelemetry-helm-charts"
        chart          = "opentelemetry-demo"
        # ⚠️ LOCKED: Version pinned to 0.31.0 for stability as requested
        targetRevision = "0.31.0"
        helm = {
          values = file("${path.module}/../k8s/values/astronomy-shop.yaml")
        }
      }
    }
  })
}