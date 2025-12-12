#!/bin/bash
SESSION="grafana-lab"

start() {
    echo "Starting port-forwards in screen session '$SESSION'..."
    screen -dmS $SESSION
    
    # 1. ArgoCD (Port 8080)
    screen -S $SESSION -X screen -t argocd bash -c "kubectl port-forward svc/argocd-server -n argocd-system 8080:80; exec bash"
    
    # 2. Grafana (Port 3000)
    screen -S $SESSION -X screen -t grafana bash -c "kubectl port-forward svc/grafana -n observability-prd 3000:80; exec bash"

    # 3. Astronomy Shop (Port 8081)
    screen -S $SESSION -X screen -t webstore bash -c "kubectl port-forward svc/astronomy-shop-frontend -n astronomy-shop 8081:8080; exec bash"

    echo "=================================================="
    echo "ACCESS CREDENTIALS"
    echo "=================================================="
    echo "1. ArgoCD: https://localhost:8080"
    echo "   User: admin"
    echo "   Pass: $(kubectl -n argocd-system get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
    echo ""
    echo "2. Grafana: http://localhost:3000"
    echo "   User: admin"
    echo "   Pass: $(kubectl -n observability-prd get secret grafana -o jsonpath="{.data.admin-password}" | base64 -d)"
    echo ""
    echo "3. Astronomy Shop: http://localhost:8081"
    echo "=================================================="
    echo "To view logs/screens: screen -r $SESSION"
}

stop() {
    echo "Stopping session $SESSION..."
    screen -S $SESSION -X quit
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; sleep 2; start ;;
    *) echo "Usage: $0 {start|stop|restart}" ;;
esac