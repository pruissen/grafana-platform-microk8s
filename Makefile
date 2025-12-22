.PHONY: all install-k3s install-argocd install-prereqs install-mimir install-loki install-tempo install-grafana \
        install-alloy-node install-alloy-cluster install-alloy-app-gateway install-demo \
        install-all uninstall-all remove-all clean \
        clean-mimir clean-loki clean-tempo clean-grafana clean-alloy clean-demo \
        uninstall-alloy-node uninstall-alloy-cluster uninstall-alloy-app-gateway \
        bootstrap forward nuke clean-legacy-alloy

USER_NAME ?= $(shell whoami)
NODE_IFACE ?= $(shell ip route get 1.1.1.1 | awk '{print $$5;exit}')
NODE_IP ?= $(shell ip route get 1.1.1.1 | awk '{print $$7;exit}')

# --- HELPER FUNCTIONS ---
# Macro to wait for all pods in a namespace to be ready
# Usage: $(call wait_for_pods,namespace,label-selector)
define wait_for_pods
    @echo "⏳ Waiting for pods in '$(1)' to be ready..."
    @timeout=300; \
    until kubectl get pods -n $(1) -l $(2) -o jsonpath='{.items[*].status.phase}' | grep -v "Pending" | grep -v "ContainerCreating" | grep -q "Running\|Succeeded"; do \
        echo "   ...waiting for $(1) pods ($(2))..."; \
        sleep 5; \
        timeout=$$((timeout-5)); \
        if [ $$timeout -le 0 ]; then echo "❌ Timeout waiting for $(1)"; exit 1; fi; \
    done
    @# Double check readiness probes
    @kubectl wait --for=condition=ready pod -n $(1) -l $(2) --timeout=300s >/dev/null 2>&1 || true
    @echo "✅ Pods in '$(1)' are ready."
endef

# ---------------------------------------------------------
# MASTER FLOW
# ---------------------------------------------------------
all: install-k3s install-argocd install-all

install-all: install-prereqs install-loki install-mimir install-tempo install-grafana bootstrap install-alloy-node install-alloy-cluster install-alloy-app-gateway install-demo 

uninstall-all: uninstall-demo uninstall-alloy-app-gateway uninstall-alloy-cluster uninstall-alloy-node uninstall-grafana uninstall-tempo uninstall-mimir uninstall-loki uninstall-prereqs

remove-all: uninstall-all nuke

# ---------------------------------------------------------
# 1. INFRASTRUCTURE
# ---------------------------------------------------------
install-k3s:
	@echo "--- 0. Checking Filesystem Type ---"
	@if df -T / | grep -q "ext4"; then \
		echo "✅ Filesystem is ext4. Skipping virtual disk setup."; \
	else \
		echo "⚠️  Filesystem is NOT ext4. Setting up Virtual Disk for K3s compatibility..."; \
		chmod +x scripts/setup-virtual-disk.sh; \
		sudo bash scripts/setup-virtual-disk.sh; \
	fi
	@echo "--- 1. Detected Network ---"
	@echo "   Interface: $(NODE_IFACE)"
	@echo "   IP:        $(NODE_IP)"
	@echo "---------------------------"
	@echo "--- 2. Installing K3s ---"
	curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --node-ip=$(NODE_IP) --flannel-iface=$(NODE_IFACE) --bind-address=$(NODE_IP) --advertise-address=$(NODE_IP) --disable=traefik" sh -
	@echo "--- 3. Configuring Permissions ---"
	sudo mkdir -p ~/.kube
	sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
	sudo chown $(USER_NAME):$(USER_NAME) ~/.kube/config
	chmod 600 ~/.kube/config
	@echo "--- 4. Waiting for Cluster ---"
	@timeout=120; until kubectl get nodes | grep -q "Ready"; do echo "Waiting for node..."; sleep 2; done
	@echo "✅ K3s Ready on $(NODE_IP)."

install-argocd:
	@echo "--- Installing ArgoCD ---"
	# Explicitly target namespace first to avoid dependency errors
	cd terraform && terraform init && terraform apply -auto-approve \
		-target=kubernetes_namespace.argocd \
		-target=helm_release.argocd
	@$(call wait_for_pods,argocd-system,app.kubernetes.io/name=argocd-server)
	@bash scripts/portforward-argocd.sh start

# ---------------------------------------------------------
# 2. SEPARATE COMPONENTS & CLEANUP
# ---------------------------------------------------------

# --- PRE-REQUISITES (Secrets & KSM) ---
install-prereqs:
	@echo "--- Installing Secrets & KSM ---"
	# ⚠️ Added kubernetes_namespace.observability to fix "not found" error
	cd terraform && terraform apply -auto-approve \
		-target=kubernetes_namespace.observability \
		-target=random_password.minio_root_password \
		-target=kubernetes_secret_v1.minio_creds \
		-target=kubernetes_secret_v1.mimir_s3_creds \
		-target=kubernetes_secret_v1.loki_s3_creds \
		-target=kubernetes_secret_v1.tempo_s3_creds \
		-target=helm_release.ksm
	@echo "✅ Secrets & KSM Installed."

uninstall-prereqs:
	@echo "--- Uninstalling Secrets & KSM ---"
	cd terraform && terraform destroy -auto-approve \
		-target=helm_release.ksm \
		-target=kubernetes_secret_v1.minio_creds \
		-target=kubernetes_secret_v1.mimir_s3_creds \
		-target=kubernetes_secret_v1.loki_s3_creds \
		-target=kubernetes_secret_v1.tempo_s3_creds

# --- LOKI (Hosts MinIO - Critical Dependency) ---
install-loki:
	@echo "--- Installing Loki (with Embedded MinIO) ---"
	cd terraform && terraform apply -auto-approve -target=kubectl_manifest.loki
	@echo "⏳ Waiting for Loki & MinIO to initialize..."
	@$(call wait_for_pods,observability-prd,app.kubernetes.io/name=loki)
	@# Wait specifically for the 0th pod to be fully up (MinIO host)
	@kubectl wait --for=condition=ready pod -n observability-prd loki-0 --timeout=300s
	@echo "✅ Loki (Storage Backend) is Ready."

uninstall-loki:
	@echo "--- Uninstalling Loki ---"
	cd terraform && terraform destroy -auto-approve -target=kubectl_manifest.loki
	@make clean-loki

clean-loki:
	@echo "🧹 Cleaning up Loki & MinIO Resources..."
	@kubectl delete all -n observability-prd -l app.kubernetes.io/name=loki --force --grace-period=0 2>/dev/null || true
	@kubectl delete pvc -n observability-prd -l app.kubernetes.io/name=loki --force --grace-period=0 2>/dev/null || true
	@kubectl delete pvc -n observability-prd -l app.kubernetes.io/name=minio --force --grace-period=0 2>/dev/null || true

# --- MIMIR ---
install-mimir:
	@echo "--- Installing Mimir ---"
	cd terraform && terraform apply -auto-approve -target=kubectl_manifest.mimir
	@$(call wait_for_pods,observability-prd,app.kubernetes.io/name=mimir)

uninstall-mimir:
	@echo "--- Uninstalling Mimir ---"
	cd terraform && terraform destroy -auto-approve -target=kubectl_manifest.mimir
	@make clean-mimir

clean-mimir:
	@echo "🧹 Cleaning up Mimir Resources..."
	@kubectl delete all -n observability-prd -l app.kubernetes.io/name=mimir --force --grace-period=0 2>/dev/null || true
	@kubectl delete pvc -n observability-prd -l app.kubernetes.io/name=mimir --force --grace-period=0 2>/dev/null || true

# --- TEMPO ---
install-tempo:
	@echo "--- Installing Tempo ---"
	cd terraform && terraform apply -auto-approve -target=kubectl_manifest.tempo
	@$(call wait_for_pods,observability-prd,app.kubernetes.io/name=tempo)

uninstall-tempo:
	@echo "--- Uninstalling Tempo ---"
	cd terraform && terraform destroy -auto-approve -target=kubectl_manifest.tempo
	@make clean-tempo

clean-tempo:
	@echo "🧹 Cleaning up Tempo Resources..."
	@kubectl delete all -n observability-prd -l app.kubernetes.io/name=tempo --force --grace-period=0 2>/dev/null || true
	@kubectl delete pvc -n observability-prd -l app.kubernetes.io/name=tempo --force --grace-period=0 2>/dev/null || true

# --- GRAFANA ---
install-grafana:
	@echo "--- Installing Grafana ---"
	cd terraform && terraform apply -auto-approve \
		-target=random_password.grafana_admin_password \
		-target=kubernetes_secret_v1.grafana_creds \
		-target=kubectl_manifest.grafana
	@$(call wait_for_pods,observability-prd,app.kubernetes.io/name=grafana)

uninstall-grafana:
	@echo "--- Uninstalling Grafana ---"
	cd terraform && terraform destroy -auto-approve -target=kubectl_manifest.grafana
	@make clean-grafana

clean-grafana:
	@echo "🧹 Cleaning up Grafana Resources..."
	@kubectl delete all -n observability-prd -l app.kubernetes.io/name=grafana --force --grace-period=0 2>/dev/null || true
	@kubectl delete pvc -n observability-prd -l app.kubernetes.io/name=grafana --force --grace-period=0 2>/dev/null || true
	@kubectl delete secret -n observability-prd grafana-admin-creds --force --grace-period=0 2>/dev/null || true

# ---------------------------------------------------------
# 📡 ALLOY COMPONENTS (Split Architecture)
# ---------------------------------------------------------

# Helper to remove the old conflicting monolithic application
clean-legacy-alloy:
	@echo "🧹 Checking for legacy 'alloy' application..."
	@kubectl delete application alloy -n argocd-system --ignore-not-found --wait=true
	@# Double check resources are gone before proceeding
	@kubectl delete daemonset alloy -n observability-prd --ignore-not-found --wait=true
	@echo "✅ Legacy Alloy cleaned."

# 1. Alloy Node (DaemonSet)
install-alloy-node: clean-legacy-alloy
	@echo "--- Installing Alloy Node (DaemonSet) ---"
	cd terraform && terraform apply -auto-approve -target=kubectl_manifest.alloy_node
	@echo "⏳ Waiting for Alloy Node definition..."
	@# Wait loop to ensure ArgoCD creates the DaemonSet before we check status
	@timeout=60; until kubectl get daemonset alloy-node -n observability-prd >/dev/null 2>&1; do \
		echo "   ...waiting for ArgoCD to create resource..."; \
		sleep 2; \
	done
	@echo "⏳ Waiting for Alloy Node rollout..."
	@kubectl rollout status daemonset/alloy-node -n observability-prd --timeout=120s
	@echo "✅ Alloy Node Ready."

uninstall-alloy-node:
	@echo "--- Uninstalling Alloy Node ---"
	cd terraform && terraform destroy -auto-approve -target=kubectl_manifest.alloy_node || true

# 2. Alloy Cluster (Deployment)
install-alloy-cluster: clean-legacy-alloy
	@echo "--- Installing Alloy Cluster (Deployment) ---"
	cd terraform && terraform apply -auto-approve -target=kubectl_manifest.alloy_cluster
	@echo "⏳ Waiting for Alloy Cluster definition..."
	@timeout=60; until kubectl get deployment alloy-cluster -n observability-prd >/dev/null 2>&1; do \
		echo "   ...waiting for ArgoCD to create resource..."; \
		sleep 2; \
	done
	@echo "⏳ Waiting for Alloy Cluster rollout..."
	@kubectl rollout status deployment/alloy-cluster -n observability-prd --timeout=120s
	@echo "✅ Alloy Cluster Ready."

uninstall-alloy-cluster:
	@echo "--- Uninstalling Alloy Cluster ---"
	cd terraform && terraform destroy -auto-approve -target=kubectl_manifest.alloy_cluster || true

# 3. Alloy App Gateway (Deployment)
install-alloy-app-gateway: clean-legacy-alloy
	@echo "--- Installing Alloy App Gateway (OTLP) ---"
	cd terraform && terraform apply -auto-approve -target=kubectl_manifest.alloy_app_gateway
	@echo "⏳ Waiting for Alloy App Gateway definition..."
	@timeout=60; until kubectl get deployment alloy-app-gateway -n observability-prd >/dev/null 2>&1; do \
		echo "   ...waiting for ArgoCD to create resource..."; \
		sleep 2; \
	done
	@echo "⏳ Waiting for Alloy App Gateway rollout..."
	@kubectl rollout status deployment/alloy-app-gateway -n observability-prd --timeout=120s
	@echo "✅ Alloy App Gateway Ready."

uninstall-alloy-app-gateway:
	@echo "--- Uninstalling Alloy App Gateway ---"
	cd terraform && terraform destroy -auto-approve -target=kubectl_manifest.alloy_app_gateway || true

clean-alloy:
	@echo "🧹 Cleaning up ALL Alloy Resources..."
	# Clean Node
	@kubectl delete all -n observability-prd -l app.kubernetes.io/instance=alloy-node --force --grace-period=0 2>/dev/null || true
	# Clean Cluster
	@kubectl delete all -n observability-prd -l app.kubernetes.io/instance=alloy-cluster --force --grace-period=0 2>/dev/null || true
	# Clean Gateway
	@kubectl delete all -n observability-prd -l app.kubernetes.io/instance=alloy-app-gateway --force --grace-period=0 2>/dev/null || true
	# Safety cleanup for old/monolithic deployments
	@kubectl delete daemonset -n observability-prd alloy --force --grace-period=0 2>/dev/null || true
	@kubectl delete deployment -n observability-prd alloy --force --grace-period=0 2>/dev/null || true
	@kubectl delete pvc -n observability-prd -l app.kubernetes.io/name=alloy --force --grace-period=0 2>/dev/null || true

# --- DEMO ---
install-demo:
	@echo "--- Installing Astronomy Shop ---"
	cd terraform && terraform apply -auto-approve \
		-target=kubernetes_namespace.devteam_1 \
		-target=kubectl_manifest.astronomy_shop
	@# Wait removed as requested

uninstall-demo:
	@echo "--- Removing Astronomy Shop ---"
	cd terraform && terraform destroy -auto-approve -target=kubectl_manifest.astronomy_shop
	@make clean-demo

clean-demo:
	@echo "🧹 Cleaning up Shop Resources..."
	@kubectl delete namespace devteam-1 --force --grace-period=0 2>/dev/null || true

# ---------------------------------------------------------
# 3. UTILITIES
# ---------------------------------------------------------
bootstrap:
	@echo "--- 🚀 Bootstrapping Grafana Orgs & Dashboards ---"
	@echo "🔌 Establishing connection to Grafana..."
	@# Ensure Grafana is actually ready before checking port forward
	@kubectl wait --for=condition=ready pod -n observability-prd -l app.kubernetes.io/name=grafana --timeout=60s
	@bash scripts/portforward-grafana.sh restart
	@echo "⏳ Waiting 10s for API..."
	@sleep 10
	@pip3 install requests >/dev/null 2>&1 || true
	@python3 scripts/manage.py --bootstrap-orgs
	@python3 scripts/manage.py --import-dashboards

forward:
	@bash scripts/portforward-all.sh start

clean:
	@echo "--- Destroying ALL Terraform Resources ---"
	cd terraform && terraform destroy -auto-approve

nuke:
	@echo "--- ☢️  NUKING CLUSTER ☢️  ---"
	@chmod +x scripts/nuke-microk8s.sh 2>/dev/null || true
	@bash scripts/nuke-microk8s.sh 2>/dev/null || true
	/usr/local/bin/k3s-uninstall.sh || true
	sudo umount /var/lib/rancher 2>/dev/null || true
	sudo rm -rf /etc/rancher /var/lib/rancher ~/.kube
	@echo "✅ System Completely Cleaned."