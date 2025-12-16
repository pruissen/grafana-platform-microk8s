#!/bin/bash

# List of scripts to manage
SCRIPTS=("portforward-argocd.sh" "portforward-minio.sh" "portforward-grafana.sh" "portforward-shop.sh")

# ---------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------

start_all() {
    echo "=================================================="
    echo "🚀 STARTING ALL PORT-FORWARDS"
    echo "=================================================="
    for script in "${SCRIPTS[@]}"; do
        if [ -f "scripts/$script" ]; then
            bash "scripts/$script" start
            echo ""
        else
            echo "⚠️  Skipping $script (File not found)"
        fi
    done
}

stop_all() {
    echo "=================================================="
    echo "🛑 STOPPING ALL PORT-FORWARDS"
    echo "=================================================="
    for script in "${SCRIPTS[@]}"; do
        if [ -f "scripts/$script" ]; then
            bash "scripts/$script" stop
        fi
    done
}

restart_all() {
    stop_all
    sleep 2
    start_all
}

show_all() {
    echo "=================================================="
    echo "👀 CLUSTER ACCESS OVERVIEW"
    echo "=================================================="
    for script in "${SCRIPTS[@]}"; do
        if [ -f "scripts/$script" ]; then
            bash "scripts/$script" show
            echo ""
        fi
    done
}

help() {
    echo "Usage: $0 {start|stop|restart|show}"
    echo "  start   : Start all port-forwards (Argo, MinIO, Grafana, Shop)"
    echo "  stop    : Stop all port-forwards"
    echo "  restart : Restart all"
    echo "  show    : Show URLs and Credentials for all services"
}

# ---------------------------------------------------------
# MENU LOGIC
# ---------------------------------------------------------

case "$1" in
    start)   start_all ;;
    stop)    stop_all ;;
    restart) restart_all ;;
    show)    show_all ;;
    *)       help ;;
esac