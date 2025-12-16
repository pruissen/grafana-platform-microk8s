#!/usr/bin/env python3
import requests
import sys
import time
import base64
import os

# --- CONFIGURATION ---
GRAFANA_URL = "http://localhost:3000"
ADMIN_USER = "admin"
# Fetch password from K8s if not provided env var
try:
    import subprocess
    cmd = "kubectl get secret -n observability-prd grafana-admin-creds -o jsonpath='{.data.admin-password}' | base64 -d"
    ADMIN_PASS = subprocess.check_output(cmd, shell=True).decode('utf-8').strip()
except:
    ADMIN_PASS = "admin" # Fallback

# Org Definitions
ORGS = [
    {
        "name": "platform-k8s",
        "tenant_id": "platform-k8s" 
    },
    {
        "name": "platform-obs",
        "tenant_id": "platform-obs"
    },
    {
        "name": "devteam-1",
        "tenant_id": "devteam-1"
    }
]

# --- FUNCTIONS ---
def get_auth():
    return (ADMIN_USER, ADMIN_PASS)

def create_org(name):
    print(f"🏢 Creating Org: {name}...")
    res = requests.post(f"{GRAFANA_URL}/api/orgs", json={"name": name}, auth=get_auth())
    if res.status_code == 409:
        print(f"   -> Already exists.")
        # Fetch ID
        orgs = requests.get(f"{GRAFANA_URL}/api/orgs/name/{name}", auth=get_auth()).json()
        return orgs['id']
    elif res.status_code == 200:
        print(f"   -> Created!")
        return res.json()['orgId']
    else:
        print(f"   -> Error: {res.text}")
        return None

def create_datasource(org_id, org_name, ds_type, name, url, tenant_id):
    # Switch Context to Org
    headers = {"X-Grafana-Org-Id": str(org_id)}
    
    # Define Payload
    payload = {
        "name": name,
        "type": ds_type,
        "url": url,
        "access": "proxy",
        "isDefault": True,
        "jsonData": {},
        "secureJsonData": {}
    }

    # Add Tenant Headers based on type
    if ds_type == "prometheus": # Mimir
        payload["jsonData"]["httpHeaderName1"] = "X-Scope-OrgID"
        payload["secureJsonData"]["httpHeaderValue1"] = tenant_id
    elif ds_type == "loki": # Loki
        payload["jsonData"]["httpHeaderName1"] = "X-Scope-OrgID"
        payload["secureJsonData"]["httpHeaderValue1"] = tenant_id
    elif ds_type == "tempo": # Tempo
        payload["jsonData"]["httpHeaderName1"] = "X-Scope-OrgID"
        payload["secureJsonData"]["httpHeaderValue1"] = tenant_id

    print(f"   🔌 Creating Datasource '{name}' (Tenant: {tenant_id}) in Org {org_name}...")
    
    # Delete existing to ensure update
    requests.delete(f"{GRAFANA_URL}/api/datasources/name/{name}", auth=get_auth(), headers=headers)
    
    res = requests.post(f"{GRAFANA_URL}/api/datasources", json=payload, auth=get_auth(), headers=headers)
    if res.status_code == 200:
        print("      -> Success!")
    else:
        print(f"      -> Failed: {res.text}")

def bootstrap():
    print("--- 🚀 STARTING GRAFANA BOOTSTRAP ---")
    
    # Check connection
    try:
        requests.get(f"{GRAFANA_URL}/api/health")
    except:
        print("❌ Could not connect to Grafana on localhost:3000. Please run './scripts/portforward-grafana.sh start' first.")
        sys.exit(1)

    for org in ORGS:
        org_id = create_org(org['name'])
        if org_id:
            # Create Mimir DS
            create_datasource(org_id, org['name'], "prometheus", "Mimir", "http://mimir-nginx.observability-prd.svc:80/prometheus", org['tenant_id'])
            # Create Loki DS
            create_datasource(org_id, org['name'], "loki", "Loki", "http://loki-gateway.observability-prd.svc:80", org['tenant_id'])
            # Create Tempo DS
            create_datasource(org_id, org['name'], "tempo", "Tempo", "http://tempo.observability-prd.svc:3100", org['tenant_id'])

    print("--- ✅ BOOTSTRAP COMPLETE ---")

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--bootstrap-orgs":
        bootstrap()
    else:
        print("Usage: python3 manage.py --bootstrap-orgs")