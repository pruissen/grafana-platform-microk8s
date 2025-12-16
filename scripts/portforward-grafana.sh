#!/bin/bash

# Configuration
PID_FILE="/tmp/grafana-portforward.pid"
LOG_FILE="/tmp/grafana-portforward.log"
NAMESPACE="observability-prd"
SERVICE="svc/grafana"
LOCAL_PORT="3000"
REMOTE_PORT="80"

# ---------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------

show() {
    echo "------------------------------------------------------------------------"
    echo "📊 GRAFANA DASHBOARD"
    echo "------------------------------------------------------------------------"
    
    if [ -f "$PID_FILE" ] && ps -p $(cat "$PID_FILE") > /dev/null; then
        echo "✅ Status:   RUNNING (PID: $(cat $PID_FILE))"
    else
        echo "⚠️  Status:   STOPPED"
    fi

    echo "🔗 URL:      http://localhost:${LOCAL_PORT}"
    
    # Retrieve Credentials
    USER=$(kubectl get secret -n "$NAMESPACE" grafana-admin-creds -o jsonpath="{.data.admin-user}" 2>/dev/null | base64 -d)
    PASS=$(kubectl get secret -n "$NAMESPACE" grafana-admin-creds -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d)

    if [ -z "$USER" ]; then
        echo "👤 User:     (Secret not found - is Grafana installed?)"
    else
        echo "👤 User:     $USER"
        echo "🔑 Pass:     $PASS"
    fi
    echo "------------------------------------------------------------------------"
}

start() {
    if [ -f "$PID_FILE" ]; then
        if ps -p $(cat "$PID_FILE") > /dev/null; then
            echo "✅ Grafana port-forward is already running."
            show
            exit 0
        else
            rm "$PID_FILE"
        fi
    fi

    echo "🚀 Starting Grafana self-healing port-forward..."
    
    (
        while true; do
            echo "[$(date)] Starting connection to $SERVICE..." >> "$LOG_FILE"
            kubectl port-forward -n "$NAMESPACE" "$SERVICE" "${LOCAL_PORT}:${REMOTE_PORT}" >> "$LOG_FILE" 2>&1
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
        echo "🛑 Stopping Grafana port-forward (PID: $PID)..."
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