#!/bin/bash
# Comprehensive Health Check and Monitoring Script for Foodle Deployment

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
MONITORING_INTERVAL=${MONITORING_INTERVAL:-30}
LOG_DIR="/var/log/foodle-monitoring"
METRICS_FILE="$LOG_DIR/metrics-$(date +%Y%m%d).json"
ALERT_THRESHOLD_CPU=80
ALERT_THRESHOLD_MEMORY=90
ALERT_THRESHOLD_DISK=85

# Create log directory
mkdir -p "$LOG_DIR"

# Service endpoints
declare -A ENDPOINTS=(
    ["API"]="http://localhost:8081/v2/health"
    ["Website"]="http://localhost:5173"
    ["Panel"]="http://localhost:8082"
    ["Database"]="3306"
    ["Redis"]="6379"
    ["RabbitMQ"]="5672"
)

# Container names
CONTAINERS=(
    "foodle_api"
    "foodle_website"
    "foodle_panel"
    "foodle_hosted_db"
    "foodle_hosted_cache"
    "foodle_hosted_rabbitmq"
    "foodle_hosted_keydb"
    "foodle_proxy"
)

# Functions
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_metric() {
    local service=$1
    local metric=$2
    local value=$3
    local status=$4
    
    echo "{\"timestamp\":\"$(timestamp)\",\"service\":\"$service\",\"metric\":\"$metric\",\"value\":\"$value\",\"status\":\"$status\"}" >> "$METRICS_FILE"
}

# Check container status
check_container() {
    local container=$1
    local status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
    local running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo "false")
    local health=$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
    local restarts=$(docker inspect -f '{{.RestartCount}}' "$container" 2>/dev/null || echo "0")
    
    if [ "$status" = "running" ] && [ "$running" = "true" ]; then
        if [ "$health" = "healthy" ] || [ "$health" = "none" ]; then
            echo -e "${GREEN}✅${NC} $container: Running (Restarts: $restarts)"
            log_metric "$container" "status" "running" "healthy"
            return 0
        else
            echo -e "${YELLOW}⚠️${NC} $container: Running but $health (Restarts: $restarts)"
            log_metric "$container" "status" "running" "$health"
            return 1
        fi
    else
        echo -e "${RED}❌${NC} $container: $status"
        log_metric "$container" "status" "$status" "unhealthy"
        return 1
    fi
}

# Check HTTP endpoint
check_http_endpoint() {
    local name=$1
    local url=$2
    local response_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url" 2>/dev/null || echo "000")
    local response_time=$(curl -s -o /dev/null -w "%{time_total}" --connect-timeout 5 "$url" 2>/dev/null || echo "0")
    
    if [ "$response_code" = "200" ] || [ "$response_code" = "301" ] || [ "$response_code" = "302" ]; then
        echo -e "${GREEN}✅${NC} $name: HTTP $response_code (${response_time}s)"
        log_metric "$name" "http_status" "$response_code" "healthy"
        log_metric "$name" "response_time" "$response_time" "healthy"
        return 0
    else
        echo -e "${RED}❌${NC} $name: HTTP $response_code"
        log_metric "$name" "http_status" "$response_code" "unhealthy"
        return 1
    fi
}

# Check TCP port
check_tcp_port() {
    local name=$1
    local port=$2
    
    if nc -z localhost "$port" 2>/dev/null; then
        echo -e "${GREEN}✅${NC} $name: Port $port is open"
        log_metric "$name" "port_status" "open" "healthy"
        return 0
    else
        echo -e "${RED}❌${NC} $name: Port $port is closed"
        log_metric "$name" "port_status" "closed" "unhealthy"
        return 1
    fi
}

# Check database connectivity
check_database() {
    local db_host="localhost"
    local db_port="3306"
    local db_user="${DB_USER:-foodle}"
    local db_pass="${DB_PASS:-}"
    
    if docker exec foodle_hosted_db mysql -u root -e "SELECT 1" &>/dev/null; then
        # Get database stats
        local tables=$(docker exec foodle_hosted_db mysql -u root -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='foodle'" 2>/dev/null | tail -1 || echo "0")
        local connections=$(docker exec foodle_hosted_db mysql -u root -e "SHOW STATUS LIKE 'Threads_connected'" 2>/dev/null | awk '{print $2}' || echo "0")
        
        echo -e "${GREEN}✅${NC} Database: Connected (Tables: $tables, Connections: $connections)"
        log_metric "database" "tables" "$tables" "healthy"
        log_metric "database" "connections" "$connections" "healthy"
        return 0
    else
        echo -e "${RED}❌${NC} Database: Connection failed"
        log_metric "database" "status" "disconnected" "unhealthy"
        return 1
    fi
}

# Check Redis/Cache
check_cache() {
    if docker exec foodle_hosted_cache redis-cli ping 2>/dev/null | grep -q PONG; then
        local keys=$(docker exec foodle_hosted_cache redis-cli DBSIZE 2>/dev/null | awk '{print $2}' || echo "0")
        local memory=$(docker exec foodle_hosted_cache redis-cli INFO memory 2>/dev/null | grep used_memory_human | cut -d: -f2 | tr -d '\r' || echo "0")
        
        echo -e "${GREEN}✅${NC} Redis Cache: Connected (Keys: $keys, Memory: $memory)"
        log_metric "redis" "keys" "$keys" "healthy"
        log_metric "redis" "memory" "$memory" "healthy"
        return 0
    else
        echo -e "${RED}❌${NC} Redis Cache: Connection failed"
        log_metric "redis" "status" "disconnected" "unhealthy"
        return 1
    fi
}

# Check RabbitMQ
check_rabbitmq() {
    if docker exec foodle_hosted_rabbitmq rabbitmqctl status &>/dev/null; then
        local queues=$(docker exec foodle_hosted_rabbitmq rabbitmqctl list_queues 2>/dev/null | wc -l || echo "0")
        echo -e "${GREEN}✅${NC} RabbitMQ: Running (Queues: $queues)"
        log_metric "rabbitmq" "queues" "$queues" "healthy"
        return 0
    else
        echo -e "${RED}❌${NC} RabbitMQ: Not running"
        log_metric "rabbitmq" "status" "stopped" "unhealthy"
        return 1
    fi
}

# Check container resources
check_container_resources() {
    echo -e "\n${CYAN}Container Resource Usage:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" | while IFS= read -r line; do
        if [[ $line == *"CONTAINER"* ]]; then
            echo "$line"
        else
            # Parse CPU and Memory percentages for alerts
            cpu=$(echo "$line" | awk '{print $2}' | sed 's/%//')
            mem=$(echo "$line" | awk '{print $3}' | sed 's/.*(//' | sed 's/%)//')
            
            if (( $(echo "$cpu > $ALERT_THRESHOLD_CPU" | bc -l) )); then
                echo -e "${YELLOW}⚠️ High CPU: $line${NC}"
            elif (( $(echo "$mem > $ALERT_THRESHOLD_MEMORY" | bc -l) )); then
                echo -e "${YELLOW}⚠️ High Memory: $line${NC}"
            else
                echo "$line"
            fi
        fi
    done
}

# Check disk usage
check_disk_usage() {
    echo -e "\n${CYAN}Disk Usage:${NC}"
    
    local disk_usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    local disk_info=$(df -h / | awk 'NR==2')
    
    if [ "$disk_usage" -gt "$ALERT_THRESHOLD_DISK" ]; then
        echo -e "${RED}⚠️ High disk usage: $disk_info${NC}"
        log_metric "disk" "usage" "$disk_usage%" "warning"
    else
        echo -e "${GREEN}✅${NC} Disk usage: $disk_info"
        log_metric "disk" "usage" "$disk_usage%" "healthy"
    fi
    
    # Docker disk usage
    echo -e "\n${CYAN}Docker Disk Usage:${NC}"
    docker system df
}

# Check supervisor daemons
check_supervisor_daemons() {
    echo -e "\n${CYAN}Supervisor Daemons:${NC}"
    
    if docker exec foodle_api supervisorctl status 2>/dev/null; then
        docker exec foodle_api supervisorctl status | while IFS= read -r line; do
            if echo "$line" | grep -q "RUNNING"; then
                echo -e "${GREEN}✅${NC} $line"
            elif echo "$line" | grep -q "STOPPED"; then
                echo -e "${YELLOW}⚠️${NC} $line"
            else
                echo -e "${RED}❌${NC} $line"
            fi
        done
    else
        echo -e "${YELLOW}⚠️${NC} Could not check supervisor status"
    fi
}

# Generate summary report
generate_report() {
    local timestamp=$(timestamp)
    local report_file="$LOG_DIR/health-report-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "Foodle Health Check Report"
        echo "Generated: $timestamp"
        echo "════════════════════════════════════════════"
        echo ""
        
        echo "Container Status:"
        for container in "${CONTAINERS[@]}"; do
            check_container "$container"
        done
        
        echo ""
        echo "Service Endpoints:"
        check_http_endpoint "API" "${ENDPOINTS[API]}"
        check_http_endpoint "Website" "${ENDPOINTS[Website]}"
        check_http_endpoint "Panel" "${ENDPOINTS[Panel]}"
        
        echo ""
        echo "Backend Services:"
        check_database
        check_cache
        check_rabbitmq
        
        check_container_resources
        check_disk_usage
        check_supervisor_daemons
        
    } | tee "$report_file"
    
    echo -e "\n${BLUE}Report saved to: $report_file${NC}"
}

# Continuous monitoring mode
monitor_continuous() {
    echo -e "${CYAN}Starting continuous monitoring (interval: ${MONITORING_INTERVAL}s)${NC}"
    echo "Press Ctrl+C to stop"
    echo ""
    
    while true; do
        clear
        echo "═══════════════════════════════════════════════════════"
        echo "           Foodle Health Monitor - $(timestamp)"
        echo "═══════════════════════════════════════════════════════"
        
        generate_report
        
        echo -e "\n${CYAN}Next check in ${MONITORING_INTERVAL} seconds...${NC}"
        sleep "$MONITORING_INTERVAL"
    done
}

# Quick check mode
quick_check() {
    local all_healthy=true
    
    echo "Running quick health check..."
    
    # Check critical services only
    for container in foodle_api foodle_hosted_db foodle_hosted_cache; do
        if ! docker ps | grep -q "$container"; then
            echo -e "${RED}❌${NC} Critical service $container is down"
            all_healthy=false
        fi
    done
    
    # Check API endpoint
    if ! curl -s -f -o /dev/null http://localhost:8081/v2/health 2>/dev/null; then
        echo -e "${RED}❌${NC} API is not responding"
        all_healthy=false
    fi
    
    if [ "$all_healthy" = true ]; then
        echo -e "${GREEN}✅ All critical services are healthy${NC}"
        exit 0
    else
        echo -e "${RED}❌ Some services are unhealthy${NC}"
        exit 1
    fi
}

# Main menu
show_menu() {
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "║    Foodle Health Check & Monitoring       ║"
    echo "╚════════════════════════════════════════════╝"
    echo ""
    echo "Select an option:"
    echo ""
    echo "  [1] Full Health Check"
    echo "  [2] Quick Check (critical services only)"
    echo "  [3] Container Status"
    echo "  [4] Service Endpoints"
    echo "  [5] Resource Usage"
    echo "  [6] Supervisor Daemons"
    echo "  [7] Generate Report"
    echo "  [8] Continuous Monitoring"
    echo "  [0] Exit"
    echo ""
    read -p "Enter your choice (0-8): " choice
    
    case $choice in
        1) 
            generate_report
            ;;
        2) 
            quick_check
            ;;
        3) 
            for container in "${CONTAINERS[@]}"; do
                check_container "$container"
            done
            ;;
        4)
            check_http_endpoint "API" "${ENDPOINTS[API]}"
            check_http_endpoint "Website" "${ENDPOINTS[Website]}"
            check_http_endpoint "Panel" "${ENDPOINTS[Panel]}"
            check_database
            check_cache
            check_rabbitmq
            ;;
        5)
            check_container_resources
            check_disk_usage
            ;;
        6)
            check_supervisor_daemons
            ;;
        7)
            generate_report
            ;;
        8)
            monitor_continuous
            ;;
        0) 
            exit 0
            ;;
        *)
            echo "Invalid choice"
            show_menu
            ;;
    esac
}

# Main execution
main() {
    case "${1:-}" in
        --quick|-q)
            quick_check
            ;;
        --monitor|-m)
            monitor_continuous
            ;;
        --report|-r)
            generate_report
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --quick, -q     Quick health check"
            echo "  --monitor, -m   Continuous monitoring"
            echo "  --report, -r    Generate full report"
            echo "  --help, -h      Show this help"
            echo ""
            echo "Without options, shows interactive menu"
            ;;
        *)
            show_menu
            ;;
    esac
}

# Run main
main "$@"