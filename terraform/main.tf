variable "repo_url" { type = string }

# 1. Install ArgoCD
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd-system"
  create_namespace = true
  version          = "5.46.0"

  # FIX: Use 'values' with yamlencode instead of 'set' blocks
  values = [
    yamlencode({
      server = {
        insecure = true
      }
    })
  ]
}

# 2. Create Teams/Namespaces (Platform vs Observability)
resource "kubernetes_namespace" "teams" {
  for_each = toset(["k8s-platform-system", "observability-prd", "astronomy-shop"])
  metadata { name = each.key }
}

# 3. Bootstrap the Root Application (The "App of Apps")
resource "kubernetes_manifest" "argocd_root" {
  depends_on = [helm_release.argocd]
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "bootstrap-root"
      namespace = "argocd-system"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.repo_url
        targetRevision = "HEAD"
        path           = "k8s/apps"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd-system"
      }
      syncPolicy = {
        automated = { prune = true, selfHeal = true }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }
}