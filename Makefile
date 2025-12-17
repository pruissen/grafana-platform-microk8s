.PHONY: all install-k3s install-argocd install-prereqs install-mimir install-loki install-tempo install-grafana install-alloy install-demo install-all uninstall-all clean clean-minio clean-mimir clean-loki clean-tempo clean-grafana clean-alloy clean-demo bootstrap forward nuke

USER_NAME ?= $(shell whoami)
NODE_IFACE ?= $(shell ip route get 1.1.1.1 | awk '{print $$5;exit}')
NODE_IP ?= $(shell ip route get 1.1.1.1 | awk '{print $$7;exit}')

# ---------------------------------------------------------
# MASTER FLOW
# ---------------------------------------------------------
all: install-k3s install-argocd install-all

install-all: install-prereqs install-mimir install-loki install-tempo install-grafana install-alloy install-demo bootstrap

uninstall-all: uninstall-demo uninstall-alloy uninstall-grafana uninstall-tempo uninstall-loki uninstall-mimir uninstall-prereqs

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
	cd terraform && terraform init && terraform apply -auto-approve -target=helm_release.argocd
	@sleep 10
	@bash scripts/portforward-argocd.sh start

# ---------------------------------------------------------
# 2. SEPARATE COMPONENTS & CLEANUP
# ---------------------------------------------------------

# --- MINIO ---
install-prereqs:
	@echo "--- Installing Enterprise MinIO & Secrets ---"
	cd terraform && terraform apply -auto-approve \
		-target=random_password.minio_root_password \
		-target=kubernetes_secret_v1.minio_creds \
		-target=kubernetes_secret_v1.mimir_s3_creds \
		-target=helm_release.ksm \
		-target=kubectl_manifest.minio
	@echo "⏳ Waiting for MinIO to initialize buckets..."
	@sleep 15

uninstall-prereqs:
	@echo "--- Uninstalling MinIO ---"
	cd terraform && terraform destroy -auto-approve \
		-target=kubectl_manifest.minio \
		-target=helm_release.ksm
	@make clean-minio

clean-minio:
	@echo "🧹 Cleaning up MinIO Resources..."
	@kubectl delete all -n observability-prd -l app.kubernetes.io/name=minio --force --grace-period=0 2>/dev/null || true
	@kubectl delete pvc -n observability-prd -l app.kubernetes.io/name=minio --force --grace-period=0 2>/dev/null || true
	@kubectl delete secret -n observability-prd minio-creds mimir-s3-credentials --force --grace-period=0 2>/dev/null || true

# --- MIMIR ---
install-mimir:
	@echo "--- Installing Mimir ---"
	cd terraform && terraform apply -auto-approve -target=kubectl_manifest.mimir

uninstall-mimir:
	@echo "--- Uninstalling Mimir ---"
	cd terraform && terraform destroy -auto-approve -target=kubectl_manifest.mimir
	@make clean-mimir

clean-mimir:
	@echo "🧹 Cleaning up Mimir Resources..."
	@kubectl delete all -n observability-prd -l app.kubernetes.io/name=mimir --force --grace-period=0 2>/dev/null || true
	@kubectl delete pvc -n observability-prd -l app.kubernetes.io/name=mimir --force --grace-period=0 2>/dev/null || true
	@kubectl delete cm -n observability-prd -l app.kubernetes.io/name=mimir --force --grace-period=0 2>/dev/null || true

# --- LOKI ---
install-loki:
	@echo "--- Installing Loki ---"
	cd terraform && terraform apply -auto-approve -target=kubectl_manifest.loki

uninstall-loki:
	@echo "--- Uninstalling Loki ---"
	cd terraform && terraform destroy -auto-approve -target=kubectl_manifest.loki
	@make clean-loki

clean-loki:
	@echo "🧹 Cleaning up Loki Resources..."
	@kubectl delete all -n observability-prd -l app.kubernetes.io/name=loki --force --grace-period=0 2>/dev/null || true
	@kubectl delete pvc -n observability-prd -l app.kubernetes.io/name=loki --force --grace-period=0 2>/dev/null || true
	@kubectl delete cm -n observability-prd -l app.kubernetes.io/name=loki --force --grace-period=0 2>/dev/null || true

# --- TEMPO ---
install-tempo:
	@echo "--- Installing Tempo ---"
	cd terraform && terraform apply -auto-approve -target=kubectl_manifest.tempo

uninstall-tempo:
	@echo "--- Uninstalling Tempo ---"
	cd terraform && terraform destroy -auto-approve -target=kubectl_manifest.tempo
	@make clean-tempo

clean-tempo:
	@echo "🧹 Cleaning up Tempo Resources..."
	@kubectl delete all -n observability-prd -l app.kubernetes.io/name=tempo --force --grace-period=0 2>/dev/null || true
	@kubectl delete pvc -n observability-prd -l app.kubernetes.io/name=tempo --force --grace-period=0 2>/dev/null || true
	@kubectl delete cm -n observability-prd -l app.kubernetes.io/name=tempo --force --grace-period=0 2>/dev/null || true

# --- GRAFANA ---
install-grafana:
	@echo "--- Installing Grafana ---"
	cd terraform && terraform apply -auto-approve \
		-target=random_password.grafana_admin_password \
		-target=kubernetes_secret_v1.grafana_creds \
		-target=kubectl_manifest.grafana

uninstall-grafana:
	@echo "--- Uninstalling Grafana ---"
	cd terraform && terraform destroy -auto-approve -target=kubectl_manifest.grafana
	@make clean-grafana

clean-grafana:
	@echo "🧹 Cleaning up Grafana Resources..."
	@kubectl delete all -n observability-prd -l app.kubernetes.io/name=grafana --force --grace-period=0 2>/dev/null || true
	@kubectl delete pvc -n observability-prd -l app.kubernetes.io/name=grafana --force --grace-period=0 2>/dev/null || true
	@kubectl delete secret -n observability-prd grafana-admin-creds --force --grace-period=0 2>/dev/null || true

# --- ALLOY (Collector/Router) ---
install-alloy:
	@echo "--- Installing Grafana Alloy ---"
	cd terraform && terraform apply -auto-approve -target=kubectl_manifest.alloy

uninstall-alloy: remove-alloy
	@echo "✅ Alloy Uninstalled."

remove-alloy:
	@echo "--- Removing Grafana Alloy ---"
	cd terraform && terraform destroy -auto-approve -target=kubectl_manifest.alloy
	@make clean-alloy

clean-alloy:
	@echo "🧹 Cleaning up Alloy Resources..."
	@kubectl delete all -n observability-prd -l app.kubernetes.io/name=alloy --force --grace-period=0 2>/dev/null || true
	@kubectl delete pvc -n observability-prd -l app.kubernetes.io/name=alloy --force --grace-period=0 2>/dev/null || true
	@kubectl delete daemonset -n observability-prd alloy --force --grace-period=0 2>/dev/null || true

# --- OTEL DEMO (Astronomy Shop) ---
install-demo:
	@echo "--- Installing Astronomy Shop (DevTeam-1) ---"
	cd terraform && terraform apply -auto-approve -target=kubectl_manifest.astronomy_shop

uninstall-demo:
	@echo "--- Removing Astronomy Shop ---"
	cd terraform && terraform destroy -auto-approve -target=kubectl_manifest.astronomy_shop
	@make clean-demo

clean-demo:
	@echo "🧹 Cleaning up Shop Resources..."
	@kubectl delete namespace devteam-1 --force --grace-period=0 2>/dev/null || true

# ---------------------------------------------------------
# 3. UTILITIES & BOOTSTRAP
# ---------------------------------------------------------
bootstrap:
	@echo "--- 🚀 Bootstrapping Grafana Orgs & Dashboards ---"
	@# Ensure dependencies (requests) are installed for the python script
	@pip3 install requests >/dev/null 2>&1 || true
	@# 1. Create Orgs & Datasources
	@python3 scripts/manage.py --bootstrap-orgs
	@# 2. Import Dashboards
	@python3 scripts/manage.py --import-dashboards

forward:
	@bash scripts/portforward-all.sh start

clean:
	@echo "--- Destroying ALL Terraform Resources ---"
	cd terraform && terraform destroy -auto-approve

# ---------------------------------------------------------
# 4. NUCLEAR OPTION
# ---------------------------------------------------------
nuke:
	@echo "--- ☢️  NUKING CLUSTER ☢️  ---"
	@chmod +x scripts/nuke-microk8s.sh 2>/dev/null || true
	@bash scripts/nuke-microk8s.sh 2>/dev/null || true
	/usr/local/bin/k3s-uninstall.sh || true
	sudo umount /var/lib/rancher 2>/dev/null || true
	sudo rm -rf /etc/rancher /var/lib/rancher ~/.kube
	@echo "✅ System Completely Cleaned."