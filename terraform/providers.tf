terraform {
  required_version = ">= 1.0"
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

# 1. Kubernetes Provider (Auto-detects from ~/.kube/config)
provider "kubernetes" {
  config_path = "~/.kube/config"
}

# 2. Kubectl Provider (Auto-detects)
provider "kubectl" {
  config_path      = "~/.kube/config"
  load_config_file = true
}

# 3. Helm Provider (Auto-detects - No explicit block needed!)
provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}