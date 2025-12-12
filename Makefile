.PHONY: all install-microk8s create-namespaces install-argocd install-observability install-otel forward clean remove-microk8s

USER_NAME ?= $(shell whoami)

# 1. THE BIG BUTTON
all: install-microk8s create-namespaces install-argocd install-observability install-otel

# 2. MICROK8S SETUP
install-microk8s:
	@echo "--- Installing Microk8s ---"
	sudo snap install microk8s --classic
	@echo "--- Configuring Permissions ---"
	sudo usermod -a -G microk8s $(USER_NAME)
	sudo mkdir -p ~/.kube
	sudo chown -f -R $(USER_NAME) ~/.kube
	@echo "--- Waiting for Cluster ---"
	sudo microk8s status --wait-ready
	@echo "--- Enabling Addons ---"
	sudo microk8s enable dns helm3 hostpath-storage
	@echo "--- Exporting Kubeconfig ---"
	sudo microk8s config | cat > ~/.kube/config
	chmod 600 ~/.kube/config
	@echo "✅ Microk8s Ready."

# 3. IDEMPOTENT NAMESPACE CREATION (Fixes "Already Exists" error)
create-namespaces:
	@echo "--- Creating Namespaces (Skipping if exist) ---"
	@kubectl create namespace argocd-system --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create namespace k8s-platform-system --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create namespace observability-prd --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create namespace astronomy-shop --dry-run=client -o yaml | kubectl apply -f -

# 4. MODULAR INSTALLATION STEPS
# Note: We export KUBECONFIG to ensure Terraform finds the cluster

install-argocd: create-namespaces
	@echo "--- Installing ArgoCD ---"
	export KUBECONFIG=~/.kube/config && cd terraform && terraform init && terraform apply -target=helm_release.argocd

install-observability:
	@echo "--- Installing LGTM Stack (Loki, Grafana, Tempo, Mimir) ---"
	export KUBECONFIG=~/.kube/config && cd terraform && terraform apply \
		-target=random_password.minio_root_password \
		-target=random_password.grafana_admin_password \
		-target=kubernetes_secret_v1.minio_creds \
		-target=kubernetes_secret_v1.grafana_creds \
		-target=kubectl_manifest.minio \
		-target=kubectl_manifest.mimir \
		-target=kubectl_manifest.tempo \
		-target=kubectl_manifest.loki \
		-target=kubectl_manifest.grafana

install-otel:
	@echo "--- Installing Grafana Alloy & Demo ---"
	export KUBECONFIG=~/.kube/config && cd terraform && terraform apply \
		-target=kubectl_manifest.alloy \
		-target=kubectl_manifest.astronomy

# 5. UTILITIES
forward:
	@echo "--- Launching Port Forwards ---"
	@bash scripts/portforward.sh start

stop-forward:
	@bash scripts/portforward.sh stop

clean:
	@echo "--- Destroying Terraform Resources ---"
	export KUBECONFIG=~/.kube/config && cd terraform && terraform destroy -auto-approve

remove-microk8s:
	@echo "--- Completely Removing MicroK8s ---"
	sudo microk8s stop
	sudo snap remove microk8s --purge
	rm -f ~/.kube/config
	@echo "✅ Microk8s Removed."