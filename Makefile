.PHONY: all install-microk8s setup-git terraform-apply forward clean

REPO_URL ?= $(shell git config --get remote.origin.url)

all: install-microk8s setup-git terraform-apply

install-microk8s:
	@echo "--- Installing MicroK8s ---"
	sudo snap install microk8s --classic
	sudo microk8s status --wait-ready
	sudo microk8s enable dns helm3 storage ingress
	sudo microk8s config > ~/.kube/config
	sudo chmod 600 ~/.kube/config

setup-git:
	@echo "--- Checking Git Setup ---"
	@if [ -z "$(REPO_URL)" ]; then echo "Error: No remote git URL found. Please 'git init' and 'git remote add origin ...' and push your code."; exit 1; fi

terraform-apply:
	@echo "--- Bootstrapping with Terraform ---"
	cd terraform && terraform init && terraform apply -var="repo_url=$(REPO_URL)" -auto-approve

forward:
	@echo "--- Launching Port Forwards ---"
	@bash scripts/portforward.sh start

stop-forward:
	@bash scripts/portforward.sh stop

clean:
	@echo "--- Destroying Environment ---"
	cd terraform && terraform destroy -auto-approve
	sudo snap remove microk8s