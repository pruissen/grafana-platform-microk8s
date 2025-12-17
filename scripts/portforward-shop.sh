#!/bin/bash

# Configuration
PID_FILE="/tmp/shop-portforward.pid"
LOG_FILE="/tmp/shop-portforward.log"
NAMESPACE="devteam-1"
SERVICE="svc/astronomy-shop-frontend" 
LOCAL_PORT="8080"
REMOTE_PORT="8080"

# ---------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------

show() {
    echo "------------------------------------------------------------------------"
    echo "🛍️  ASTRONOMY SHOP (DEMO APP)"
    echo "------------------------------------------------------------------------"
    
    if [ -f "$PID_FILE" ] && ps -p $(cat "$PID_FILE") > /dev/null; then
        echo "✅ Status:   RUNNING (PID: $(cat $PID_FILE))"
    else
        echo "⚠️  Status:   STOPPED"
    fi

    echo "🔗 URL:      http://localhost:${LOCAL_PORT}"
    echo "ℹ️  Note:     Data is sent to Alloy -> Tenant 'devteam-1'"
    echo "------------------------------------------------------------------------"
}

start() {
    if [ -f "$PID_FILE" ]; then
        if ps -p $(cat "$PID_FILE") > /dev/null; then
            echo "✅ Shop port-forward is already running."
            show
            exit 0
        else
            rm "$PID_FILE"
        fi
    fi

    echo "🚀 Starting Shop self-healing port-forward..."
    
    (
        while true; do
            echo "[$(date)] Connecting to $SERVICE..." >> "$LOG_FILE"
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
        echo "🛑 Stopping Shop port-forward (PID: $PID)..."
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