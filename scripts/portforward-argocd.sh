#!/bin/bash

# Configuration
PID_FILE="/tmp/argocd-portforward.pid"
LOG_FILE="/tmp/argocd-portforward.log"
NAMESPACE="argocd-system"
SERVICE="svc/argocd-server"
LOCAL_PORT="8081"
REMOTE_PORT="80" # Standard ArgoCD server port is usually 80 or 443

# ---------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------

show() {
    echo "------------------------------------------------------------------------"
    echo "🐙 ARGOCD (GITOPS)"
    echo "------------------------------------------------------------------------"
    
    if [ -f "$PID_FILE" ] && ps -p $(cat "$PID_FILE") > /dev/null; then
        echo "✅ Status:   RUNNING (PID: $(cat $PID_FILE))"
    else
        echo "⚠️  Status:   STOPPED"
    fi

    echo "🔗 URL:      http://localhost:${LOCAL_PORT}"
    
    # Retrieve Credentials
    USER="admin"
    PASS=$(kubectl get secret -n "$NAMESPACE" argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)

    if [ -z "$PASS" ]; then
        echo "👤 User:     admin"
        echo "🔑 Pass:     (Secret not found - maybe already changed?)"
    else
        echo "👤 User:     $USER"
        echo "🔑 Pass:     $PASS"
    fi
    echo "------------------------------------------------------------------------"
}

start() {
    if [ -f "$PID_FILE" ]; then
        if ps -p $(cat "$PID_FILE") > /dev/null; then
            echo "✅ ArgoCD port-forward is already running."
            show
            exit 0
        else
            rm "$PID_FILE"
        fi
    fi

    echo "🚀 Starting ArgoCD self-healing port-forward..."
    
    (
        while true; do
            echo "[$(date)] Connecting to $SERVICE..." >> "$LOG_FILE"
            # Try port 80 first, fallback to 443 if needed inside the loop
            kubectl port-forward -n "$NAMESPACE" "$SERVICE" "${LOCAL_PORT}:80" >> "$LOG_FILE" 2>&1
            if [ $? -ne 0 ]; then
                 echo "[$(date)] Port 80 failed, trying 443..." >> "$LOG_FILE"
                 kubectl port-forward -n "$NAMESPACE" "$SERVICE" "${LOCAL_PORT}:443" >> "$LOG_FILE" 2>&1
            fi
            echo "[$(date)] Connection died. Restarting in 2s..." >> "$LOG_FILE"
            sleep 2
        done
    ) &

    echo $! > "$PID_FILE"
    sleep 1
    show
}

stop() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        echo "🛑 Stopping ArgoCD port-forward (PID: $PID)..."
        kill "$PID" 2>/dev/null
        pkill -f "kubectl port-forward -n $NAMESPACE $SERVICE"
        rm "$PID_FILE"
        echo "✅ Stopped."
    else
        echo "⚠️  No PID file found. Cleaning up orphans..."
        pkill -f "kubectl port-forward -n $NAMESPACE $SERVICE"
        echo "✅ Cleanup complete."
    fi
}

help() {
    echo "Usage: $0 {start|stop|restart|show|help}"
}

# ---------------------------------------------------------
# MENU LOGIC
# ---------------------------------------------------------
case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    show)    show ;;
    *)       help ;;
esac