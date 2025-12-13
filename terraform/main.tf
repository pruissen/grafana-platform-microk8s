# -------------------------------------------------------------------
# 1. SECRETS GENERATION (All Secure, No Defaults)
# -------------------------------------------------------------------
resource "random_password" "minio_root_password" { length = 16; special = false }
resource "random_password" "grafana_admin_password" { length = 16; special = false }
resource "random_password" "oncall_db_password" { length = 16; special = false }
resource "random_password" "oncall_rabbitmq_password" { length = 16; special = false }
resource "random_password" "oncall_redis_password" { length = 16; special = false }

# Kubernetes Secret for MinIO
resource "kubernetes_secret_v1" "minio_creds" {
  metadata { name = "minio-creds"; namespace = "observability-prd" }
  data = { rootUser = "admin"; rootPassword = random_password.minio_root_password.result }
}

# Kubernetes Secret for Grafana
resource "kubernetes_secret_v1" "grafana_creds" {
  metadata { name = "grafana-admin-creds"; namespace = "observability-prd" }
  data = { admin-user = "admin"; admin-password = random_password.grafana_admin_password.result }
}

# -------------------------------------------------------------------
# 2. JOB: Bucket Creator (Ensures Mimir/Loki/Tempo don't crash)
# -------------------------------------------------------------------
resource "kubectl_manifest" "bucket_creator" {
  depends_on = [kubernetes_secret_v1.minio_creds]
  yaml_body = yamlencode({
    apiVersion = "batch/v1", kind = "Job", metadata = { name = "minio-bucket-creator-v6", namespace = "observability-prd" }
    spec = {
      ttlSecondsAfterFinished = 300
      template = {
        spec = {
          restartPolicy = "OnFailure"
          containers = [{
            name = "mc", image = "minio/mc:latest", command = ["/bin/sh", "-c"],
            env = [{ name = "MINIO_PASS", valueFrom = { secretKeyRef = { name = "minio-creds", key = "rootPassword" } } }],
            args = [<<-EOT
              until mc alias set myminio http://minio-storage.observability-prd.svc:9000 admin $MINIO_PASS; do echo "Waiting..."; sleep 5; done
              mc mb myminio/mimir-blocks --ignore-existing
              mc mb myminio/mimir-ruler  --ignore-existing
              mc mb myminio/tempo-traces --ignore-existing
              mc mb myminio/loki-data    --ignore-existing
              mc mb myminio/loki-ruler   --ignore-existing
              echo "Buckets Created."
            EOT
            ]
          }]
        }
      }
    }
  })
}

# -------------------------------------------------------------------
# 3. APPLICATIONS
# -------------------------------------------------------------------

# ArgoCD
resource "helm_release" "argocd" {
  name = "argocd"; repository = "https://argoproj.github.io/argo-helm"; chart = "argo-cd"; namespace = "argocd-system"; version = "7.7.16"
  values = [yamlencode({ server = { insecure = true }, configs = { cm = { "resource.customizations.ignoreDifferences.all" = "jsonPointers:\n  - /status" } } })]
}

# MinIO
resource "kubectl_manifest" "minio" {
  depends_on = [helm_release.argocd, kubernetes_secret_v1.minio_creds]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1", kind = "Application", metadata = { name = "minio-storage", namespace = "argocd-system" }
    spec = {
      project = "default", destination = { server = "https://kubernetes.default.svc", namespace = "observability-prd" }
      syncPolicy = { automated = { prune = true, selfHeal = true } }
      source = {
        repoURL = "https://charts.min.io/", chart = "minio", targetRevision = "5.0.14"
        helm = { parameters = [{ name = "mode", value = "standalone" }, { name = "existingSecret", value = "minio-creds" }] }
      }
    }
  })
}

# LGTM Distributed (Mimir + Tempo + Loki + Grafana + OnCall)
resource "kubectl_manifest" "lgtm" {
  depends_on = [kubectl_manifest.minio, kubectl_manifest.bucket_creator]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1", kind = "Application", metadata = { name = "lgtm", namespace = "argocd-system" }
    spec = {
      project = "default", destination = { server = "https://kubernetes.default.svc", namespace = "observability-prd" }
      syncPolicy = { automated = { prune = true, selfHeal = true } }
      source = {
        repoURL = "https://grafana.github.io/helm-charts"
        chart   = "lgtm-distributed"
        targetRevision = "2.0.0" # Bundle Version
        helm = {
          # Injecting all generated passwords into the template
          values = templatefile("${path.module}/../k8s/values/lgtm.yaml", {
            s3_secret_key            = random_password.minio_root_password.result
            oncall_db_password       = random_password.oncall_db_password.result
            oncall_rabbitmq_password = random_password.oncall_rabbitmq_password.result
            oncall_redis_password    = random_password.oncall_redis_password.result
          })
        }
      }
    }
  })
}

# Grafana Alloy
resource "kubectl_manifest" "alloy" {
  depends_on = [kubectl_manifest.lgtm]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1", kind = "Application", metadata = { name = "alloy", namespace = "argocd-system" }
    spec = {
      project = "default", destination = { server = "https://kubernetes.default.svc", namespace = "observability-prd" }
      syncPolicy = { automated = { prune = true, selfHeal = true } }
      source = {
        repoURL = "https://grafana.github.io/helm-charts", chart = "alloy", targetRevision = "0.9.1"
        helm = { values = file("${path.module}/../k8s/values/alloy.yaml") }
      }
    }
  })
}

# Astronomy Shop
resource "kubectl_manifest" "astronomy" {
  depends_on = [kubectl_manifest.alloy]
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1", kind = "Application", metadata = { name = "astronomy-shop", namespace = "argocd-system" }
    spec = {
      project = "default", destination = { server = "https://kubernetes.default.svc", namespace = "astronomy-shop" }
      syncPolicy = { automated = { prune = true, selfHeal = true } }
      source = {
        repoURL = "https://open-telemetry.github.io/opentelemetry-helm-charts", chart = "opentelemetry-demo", targetRevision = "0.26.0"
        helm = { parameters = [{ name = "opentelemetry-collector.enabled", value = "false" }, { name = "jaeger.enabled", value = "false" }, { name = "grafana.enabled", value = "false" }, { name = "default.env.OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://alloy.observability-prd.svc:4317" }] }
      }
    }
  })
}