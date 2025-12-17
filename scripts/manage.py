#!/usr/bin/env python3
import requests
import sys
import time
import base64
import os
import json

# --- CONFIGURATION ---
GRAFANA_URL = "http://localhost:3000"
ADMIN_USER = "admin"
OUTPUT_FILE = "bootstrap-results.json"

# --- DASHBOARD MAPPING ---
# Define which dashboards go to which teams
DASHBOARD_GROUPS = [
    {
        # 1. SHARED INFRASTRUCTURE (Kubernetes & ArgoCD)
        # Target: Everyone needs to see the platform status
        "target_orgs": ["platform-k8s", "platform-obs", "devteam-1"],
        "dashboards": [
            {"id": "315", "type": "id", "folder": "Kubernetes", "name": "K8s Nodes"},
            {"id": "13332", "type": "id", "folder": "Kubernetes", "name": "Kube State Metrics v2"},
            {"id": "15760", "type": "id", "folder": "Kubernetes", "name": "Kubernetes Overview"},
            {"id": "14584", "type": "id", "folder": "GitOps", "name": "ArgoCD"}
        ]
    },
    {
        # 2. OBSERVABILITY STACK (The LGTM Stack itself)
        # Target: Only the Observability Platform Team
        "target_orgs": ["platform-obs"],
        "dashboards": [
            {"id": "13639", "type": "id", "folder": "Observability", "name": "Loki Logs"},
            {"id": "15132", "type": "id", "folder": "Observability", "name": "Tempo Operational"},
            {"id": "16738", "type": "id", "folder": "Observability", "name": "Alloy Operational"},
            {"id": "3590", "type": "id", "folder": "Observability", "name": "Grafana Internals"}
        ]
    },
    {
        # 3. APPLICATIONS (The OTel Demo)
        # Target: The Application Developer Team
        "target_orgs": ["devteam-1"],
        "dashboards": [
            {
                "url": "https://raw.githubusercontent.com/open-telemetry/opentelemetry-demo/main/src/grafana/dashboards/opentelemetry-demo.json",
                "type": "url",
                "folder": "Applications",
                "name": "Astronomy Shop"
            }
        ]
    }
]

# Fetch password from K8s if not provided via env var
try:
    import subprocess
    cmd = "kubectl get secret -n observability-prd grafana-admin-creds -o jsonpath='{.data.admin-password}' | base64 -d"
    ADMIN_PASS = subprocess.check_output(cmd, shell=True).decode('utf-8').strip()
except:
    ADMIN_PASS = "admin" 

# Org Definitions
ORGS = [
    {"name": "platform-k8s", "tenant_id": "platform-k8s", "sa_name": "sa-platform-k8s"},
    {"name": "platform-obs", "tenant_id": "platform-obs", "sa_name": "sa-platform-obs"},
    {"name": "devteam-1", "tenant_id": "devteam-1", "sa_name": "sa-devteam-1"}
]

# --- HELPER FUNCTIONS ---
def get_auth():
    return (ADMIN_USER, ADMIN_PASS)

def get_org_id_by_name(name):
    """Finds the numeric ID of an Organization by its name."""
    try:
        # 1. Try to get specific org
        res = requests.get(f"{GRAFANA_URL}/api/orgs/name/{name}", auth=get_auth())
        if res.status_code == 200:
            return res.json()['id']
        
        # 2. Fallback: Search all orgs
        res = requests.get(f"{GRAFANA_URL}/api/orgs", auth=get_auth())
        if res.status_code == 200:
            for org in res.json():
                if org['name'] == name:
                    return org['id']
    except Exception as e:
        print(f"      Error finding org {name}: {e}")
    return None

def get_dashboard_json(source, is_url=False):
    if is_url:
        print(f"      ⬇️  Fetching from URL...")
        try:
            r = requests.get(source)
            if r.status_code == 200:
                return r.json()
        except Exception as e:
            print(f"      Error fetching: {e}")
            return None
    else:
        print(f"      ⬇️  Fetching ID {source} from Grafana.com...")
        try:
            r = requests.get(f"https://grafana.com/api/dashboards/{source}/revisions/latest/download")
            if r.status_code == 200:
                return r.json()
        except:
            pass
    return None

def import_dashboards():
    print("--- 📊 IMPORTING DASHBOARDS ---")
    headers_base = {"Content-Type": "application/json"}
    
    for group in DASHBOARD_GROUPS:
        # For every group of dashboards...
        for dashboard_def in group['dashboards']:
            print(f"📦 Preparing Dashboard: {dashboard_def['name']}")
            
            # 1. Download Content (Once)
            data = None
            if dashboard_def['type'] == 'url':
                data = get_dashboard_json(dashboard_def['url'], is_url=True)
            else:
                data = get_dashboard_json(dashboard_def['id'], is_url=False)
            
            if not data:
                print("      ❌ Failed to download definition. Skipping.")
                continue

            # 2. Distribute to Target Orgs
            for org_name in group['target_orgs']:
                org_id = get_org_id_by_name(org_name)
                
                if not org_id:
                    print(f"      ⚠️  Skipping import for '{org_name}' (Org not found). Run --bootstrap-orgs first.")
                    continue

                print(f"      ➡️  Importing to Org: {org_name} (ID: {org_id})...")
                
                # Prepare Request with Org Context
                headers = headers_base.copy()
                headers["X-Grafana-Org-Id"] = str(org_id)
                
                # Prepare Payload
                # We blindly inject the datasources we created in bootstrap
                payload = {
                    "dashboard": data,
                    "overwrite": True,
                    "folderUid": "", # Can use folderId if we created folders, but root is fine for now
                    "inputs": [
                        {"name": "DS_PROMETHEUS", "type": "datasource", "pluginId": "prometheus", "value": "Mimir"},
                        {"name": "DS_LOKI", "type": "datasource", "pluginId": "loki", "value": "Loki"},
                        {"name": "DS_TEMPO", "type": "datasource", "pluginId": "tempo", "value": "Tempo"}
                    ]
                }
                
                # Execute Import
                try:
                    res = requests.post(f"{GRAFANA_URL}/api/dashboards/import", json=payload, auth=get_auth(), headers=headers)
                    if res.status_code == 200:
                        print(f"          ✅ Success")
                    else:
                        print(f"          ❌ Failed: {res.text}")
                except Exception as e:
                    print(f"          ❌ Exception: {e}")

# --- EXISTING FUNCTIONS (bootstrap) ---
def create_org(name):
    res = requests.post(f"{GRAFANA_URL}/api/orgs", json={"name": name}, auth=get_auth())
    if res.status_code == 409:
        return get_org_id_by_name(name)
    elif res.status_code == 200:
        return res.json()['orgId']
    return None

def create_datasource(org_id, org_name, ds_type, name, url, tenant_id):
    headers = {"X-Grafana-Org-Id": str(org_id)}
    payload = {
        "name": name, "type": ds_type, "url": url, "access": "proxy", "isDefault": True,
        "jsonData": {}, "secureJsonData": {}
    }
    if ds_type in ["prometheus", "loki", "tempo"]:
        payload["jsonData"]["httpHeaderName1"] = "X-Scope-OrgID"
        payload["secureJsonData"]["httpHeaderValue1"] = tenant_id

    existing = requests.get(f"{GRAFANA_URL}/api/datasources/name/{name}", auth=get_auth(), headers=headers)
    if existing.status_code == 200:
        ds_id = existing.json()['id']
        requests.put(f"{GRAFANA_URL}/api/datasources/{ds_id}", json=payload, auth=get_auth(), headers=headers)
    else:
        requests.post(f"{GRAFANA_URL}/api/datasources", json=payload, auth=get_auth(), headers=headers)

def create_service_account_and_token(org_id, sa_name):
    headers = {"X-Grafana-Org-Id": str(org_id)}
    search = requests.get(f"{GRAFANA_URL}/api/serviceaccounts/search?name={sa_name}", auth=get_auth(), headers=headers)
    sa_id = None
    if search.status_code == 200 and len(search.json()['serviceAccounts']) > 0:
        sa_id = search.json()['serviceAccounts'][0]['id']
    else:
        create = requests.post(f"{GRAFANA_URL}/api/serviceaccounts", json={"name": sa_name, "role": "Editor"}, auth=get_auth(), headers=headers)
        if create.status_code == 201: sa_id = create.json()['id']
    
    if sa_id:
        token_name = f"bootstrap-token-{int(time.time())}"
        res = requests.post(f"{GRAFANA_URL}/api/serviceaccounts/{sa_id}/tokens", json={"name": token_name}, auth=get_auth(), headers=headers)
        if res.status_code == 200: return res.json()['key']
    return None

def bootstrap():
    print("--- 🚀 STARTING GRAFANA BOOTSTRAP ---")
    results = {}
    for org in ORGS:
        print(f"🏢 Processing Org: {org['name']}")
        org_id = create_org(org['name'])
        if org_id:
            create_datasource(org_id, org['name'], "prometheus", "Mimir", "http://mimir-nginx.observability-prd.svc:80/prometheus", org['tenant_id'])
            create_datasource(org_id, org['name'], "loki", "Loki", "http://loki-gateway.observability-prd.svc:80", org['tenant_id'])
            create_datasource(org_id, org['name'], "tempo", "Tempo", "http://tempo.observability-prd.svc:3100", org['tenant_id'])
            token = create_service_account_and_token(org_id, org['sa_name'])
            if token:
                results[org['name']] = {"org_id": org_id, "tenant_id": org['tenant_id'], "token": token}
    
    with open(OUTPUT_FILE, 'w') as f: json.dump(results, f, indent=4)
    print(f"\n✅ BOOTSTRAP COMPLETE! Credentials saved to {OUTPUT_FILE}")

# --- MAIN ---
if __name__ == "__main__":
    if len(sys.argv) > 1:
        if sys.argv[1] == "--bootstrap-orgs":
            bootstrap()
        elif sys.argv[1] == "--import-dashboards":
            import_dashboards()
    else:
        print("Usage: python3 scripts/manage.py [--bootstrap-orgs | --import-dashboards]")