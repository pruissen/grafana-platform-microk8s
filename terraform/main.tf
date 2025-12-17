# terraform/main.tf

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
# 3. ARGOCD (The GitOps Engine)
# -------------------------------------------------------------------
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "5.51.6" # Stable version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }
  
  # Disable HA/Redis HA for local dev to save resources
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
# 4. SHARED SECRETS & MINIO (Storage)
# -------------------------------------------------------------------

# A. Generate Random Password for MinIO Root
resource "random_password" "minio_root_password" {
  length  = 24
  special = false
}

# B. Create Secret for MinIO Server (Used by the MinIO Chart)
resource "kubernetes_secret_v1" "minio_creds" {
  metadata {
    name      = "minio-creds"
    namespace = "observability-prd"
  }
  data = {
    rootUser     = "admin"
    rootPassword = random_password.minio_root_password.result
  }
  type = "Opaque"
}

# C. Create AWS-Compatible Secret for Mimir (Used by Mimir to access MinIO)
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

# D. MinIO Application (Official Chart)
resource "kubectl_manifest" "minio" {
  depends_on = [helm_release.argocd, kubernetes_secret_v1.minio_creds]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "minio-enterprise"
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
        repoURL        = "https://charts.min.io/"
        chart          = "minio"
        targetRevision = "5.3.0"
        helm = {
          values = file("${path.module}/../k8s/values/minio-enterprise.yaml")
        }
      }
    }
  })
}

# E. Kube State Metrics (Prerequisite for Mimir/Prometheus Scraping)
resource "helm_release" "ksm" {
  name       = "kube-state-metrics"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-state-metrics"
  namespace  = "observability-prd"
  version    = "5.16.0"
}

# -------------------------------------------------------------------
# 5. MIMIR (Metrics)
# -------------------------------------------------------------------
resource "kubectl_manifest" "mimir" {
  depends_on = [
    helm_release.argocd, 
    kubectl_manifest.minio, 
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
        targetRevision = "5.6.0"
        helm = {
          values = file("${path.module}/../k8s/values/mimir.yaml")
        }
      }
    }
  })
}

# -------------------------------------------------------------------
# 6. LOKI (Logs)
# -------------------------------------------------------------------
# A. Generate S3 Credentials for Loki (Reusing MinIO Admin)
resource "kubernetes_secret_v1" "loki_s3_creds" {
  metadata {
    name      = "loki-s3-credentials"
    namespace = "observability-prd"
  }
  data = {
    # Using environment variables format if needed by chart, or just reuse MinIO secret
    LOKI_S3_ACCESS_KEY = "admin"
    LOKI_S3_SECRET_KEY = random_password.minio_root_password.result
  }
  type = "Opaque"
}

resource "kubectl_manifest" "loki" {
  depends_on = [helm_release.argocd, kubectl_manifest.minio]
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
        targetRevision = "6.24.0" # Stable Single Binary / Simple Scalable
        helm = {
          # Ensure you have k8s/values/loki.yaml created!
          values = file("${path.module}/../k8s/values/loki.yaml")
        }
      }
    }
  })
}

# -------------------------------------------------------------------
# 7. TEMPO (Traces)
# -------------------------------------------------------------------
# A. Generate S3 Credentials for Tempo
resource "kubernetes_secret_v1" "tempo_s3_creds" {
  metadata {
    name      = "tempo-s3-credentials"
    namespace = "observability-prd"
  }
  data = {
    TEMPO_S3_ACCESS_KEY = "admin"
    TEMPO_S3_SECRET_KEY = random_password.minio_root_password.result
  }
  type = "Opaque"
}

resource "kubectl_manifest" "tempo" {
  depends_on = [helm_release.argocd, kubectl_manifest.minio, kubernetes_secret_v1.tempo_s3_creds]
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
# 8. GRAFANA (Visualization)
# -------------------------------------------------------------------
# A. Generate Random Admin Password
resource "random_password" "grafana_admin_password" {
  length  = 16
  special = false
}

# B. Create Secret
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
        targetRevision = "8.0.0"
        helm = {
          values = file("${path.module}/../k8s/values/grafana.yaml")
        }
      }
    }
  })
}

# -------------------------------------------------------------------
# 9. ALLOY (Collector / Router)
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
        targetRevision = "0.9.0"
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
        targetRevision = "0.31.0"
        helm = {
          values = file("${path.module}/../k8s/values/astronomy-shop.yaml")
        }
      }
    }
  })
}