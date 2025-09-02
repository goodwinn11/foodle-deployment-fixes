#!/bin/bash
# Emergency Recovery System for Foodle
# Comprehensive disaster recovery with multiple fallback strategies

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly RECOVERY_DIR="/var/recovery/foodle"
readonly BACKUP_DIR="/var/backups/foodle"
readonly EMERGENCY_LOG="/var/log/foodle-emergency.log"
readonly STATE_FILE="/var/lib/foodle/recovery.state"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Recovery levels
readonly RECOVERY_LEVELS=(
    "LEVEL_1_RESTART"
    "LEVEL_2_REBUILD"
    "LEVEL_3_RESTORE"
    "LEVEL_4_ROLLBACK"
    "LEVEL_5_EMERGENCY"
)

# ============================================================================
# LOGGING
# ============================================================================

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    case $level in
        CRITICAL)
            echo -e "${RED}[CRITICAL]${NC} $message" | tee -a "$EMERGENCY_LOG"
            send_alert "CRITICAL" "$message"
            ;;
        ERROR)
            echo -e "${RED}[ERROR]${NC} $message" | tee -a "$EMERGENCY_LOG"
            ;;
        WARNING)
            echo -e "${YELLOW}[WARNING]${NC} $message" | tee -a "$EMERGENCY_LOG"
            ;;
        INFO)
            echo -e "${BLUE}[INFO]${NC} $message" | tee -a "$EMERGENCY_LOG"
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${NC} $message" | tee -a "$EMERGENCY_LOG"
            ;;
    esac
    
    echo "[$timestamp] [$level] $message" >> "$EMERGENCY_LOG"
}

send_alert() {
    local severity=$1
    local message=$2
    
    # Send to multiple channels
    # Slack
    if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
        curl -X POST "$SLACK_WEBHOOK" \
            -H 'Content-Type: application/json' \
            -d "{\"text\":\"🚨 [$severity] $message\"}" 2>/dev/null || true
    fi
    
    # Email
    if command -v mail &>/dev/null && [[ -n "${ALERT_EMAIL:-}" ]]; then
        echo "$message" | mail -s "Foodle Emergency: $severity" "$ALERT_EMAIL" 2>/dev/null || true
    fi
    
    # PagerDuty
    if [[ -n "${PAGERDUTY_KEY:-}" ]]; then
        curl -X POST "https://events.pagerduty.com/v2/enqueue" \
            -H 'Content-Type: application/json' \
            -d "{
                \"routing_key\": \"$PAGERDUTY_KEY\",
                \"event_action\": \"trigger\",
                \"payload\": {
                    \"summary\": \"$message\",
                    \"severity\": \"error\",
                    \"source\": \"foodle-recovery\"
                }
            }" 2>/dev/null || true
    fi
}

# ============================================================================
# SYSTEM DIAGNOSTICS
# ============================================================================

diagnose_system() {
    log INFO "Running comprehensive system diagnostics..."
    
    local issues=()
    
    # Check Docker
    if ! docker info &>/dev/null; then
        issues+=("Docker daemon not running")
    fi
    
    # Check disk space
    local disk_usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    if [[ $disk_usage -gt 90 ]]; then
        issues+=("Critical disk space: ${disk_usage}%")
    fi
    
    # Check memory
    local mem_available=$(free -m | awk 'NR==2 {print $7}')
    if [[ $mem_available -lt 500 ]]; then
        issues+=("Low memory: ${mem_available}MB available")
    fi
    
    # Check network
    if ! ping -c 1 8.8.8.8 &>/dev/null; then
        issues+=("No internet connectivity")
    fi
    
    # Check critical services
    for service in docker mariadb redis rabbitmq; do
        if ! systemctl is-active --quiet "$service" 2>/dev/null; then
            if ! docker ps | grep -q "$service" 2>/dev/null; then
                issues+=("Service $service not running")
            fi
        fi
    done
    
    # Check containers
    local failed_containers=$(docker ps -a --filter "status=exited" --format "{{.Names}}" | grep foodle || true)
    if [[ -n "$failed_containers" ]]; then
        issues+=("Failed containers: $failed_containers")
    fi
    
    if [[ ${#issues[@]} -eq 0 ]]; then
        log SUCCESS "No critical issues detected"
        return 0
    else
        log ERROR "Critical issues detected:"
        for issue in "${issues[@]}"; do
            log ERROR "  - $issue"
        done
        return 1
    fi
}

# ============================================================================
# RECOVERY LEVEL 1: RESTART SERVICES
# ============================================================================

recovery_level_1_restart() {
    log INFO "LEVEL 1: Attempting service restart..."
    
    local success=true
    
    # Try docker-compose restart
    if [[ -f docker-compose.yml ]]; then
        log INFO "Restarting services with docker-compose..."
        if docker compose restart; then
            sleep 30
            if verify_services; then
                log SUCCESS "Services restarted successfully"
                return 0
            fi
        fi
    fi
    
    # Try individual container restarts
    log INFO "Restarting individual containers..."
    for container in $(docker ps -a --format "{{.Names}}" | grep foodle); do
        log INFO "Restarting $container..."
        docker restart "$container" || success=false
    done
    
    if [[ "$success" == true ]]; then
        sleep 30
        if verify_services; then
            log SUCCESS "Individual container restart successful"
            return 0
        fi
    fi
    
    log ERROR "Level 1 recovery failed"
    return 1
}

# ============================================================================
# RECOVERY LEVEL 2: REBUILD CONTAINERS
# ============================================================================

recovery_level_2_rebuild() {
    log INFO "LEVEL 2: Rebuilding containers..."
    
    # Stop all containers
    log INFO "Stopping all containers..."
    docker compose down 2>/dev/null || docker stop $(docker ps -aq) 2>/dev/null || true
    
    # Clean up
    log INFO "Cleaning up Docker resources..."
    docker system prune -f --volumes 2>/dev/null || true
    
    # Rebuild with fallback strategies
    log INFO "Rebuilding containers..."
    
    # Try multi-stage build
    if [[ -f panel/Dockerfile.multistage ]]; then
        docker build -f panel/Dockerfile.multistage -t foodle-panel:recovery panel/ || \
        docker build -f panel/Dockerfile -t foodle-panel:recovery panel/ || \
        create_emergency_container "panel"
    fi
    
    if [[ -f foodle-api/Dockerfile.multistage ]]; then
        docker build -f foodle-api/Dockerfile.multistage -t foodle-api:recovery foodle-api/ || \
        docker build -f foodle-api/Dockerfile -t foodle-api:recovery foodle-api/ || \
        create_emergency_container "api"
    fi
    
    # Start with recovery images
    log INFO "Starting rebuilt containers..."
    docker compose up -d
    
    sleep 60
    if verify_services; then
        log SUCCESS "Level 2 recovery successful"
        return 0
    fi
    
    log ERROR "Level 2 recovery failed"
    return 1
}

# ============================================================================
# RECOVERY LEVEL 3: RESTORE FROM BACKUP
# ============================================================================

recovery_level_3_restore() {
    log INFO "LEVEL 3: Restoring from backup..."
    
    # Find latest backup
    local latest_backup=$(ls -dt "$BACKUP_DIR"/* 2>/dev/null | head -1)
    
    if [[ -z "$latest_backup" ]]; then
        log ERROR "No backup found"
        return 1
    fi
    
    log INFO "Restoring from: $latest_backup"
    
    # Stop services
    docker compose down 2>/dev/null || true
    
    # Restore database
    if [[ -f "$latest_backup/database.sql" ]]; then
        log INFO "Restoring database..."
        docker run --rm -i \
            -v "$latest_backup:/backup:ro" \
            mariadb:latest \
            mysql -h "$DB_HOST" -u root -p"$DB_ROOT_PASSWORD" < /backup/database.sql
    fi
    
    # Restore volumes
    for volume_backup in "$latest_backup"/volumes/*.tar.gz; do
        if [[ -f "$volume_backup" ]]; then
            local volume_name=$(basename "$volume_backup" .tar.gz)
            log INFO "Restoring volume: $volume_name"
            
            docker volume create "$volume_name" 2>/dev/null || true
            docker run --rm \
                -v "$volume_name:/target" \
                -v "$volume_backup:/backup.tar.gz:ro" \
                alpine tar xzf /backup.tar.gz -C /target
        fi
    done
    
    # Restore configurations
    if [[ -d "$latest_backup/configs" ]]; then
        cp -r "$latest_backup/configs"/* . 2>/dev/null || true
    fi
    
    # Start services
    docker compose up -d
    
    sleep 60
    if verify_services; then
        log SUCCESS "Level 3 recovery successful"
        return 0
    fi
    
    log ERROR "Level 3 recovery failed"
    return 1
}

# ============================================================================
# RECOVERY LEVEL 4: ROLLBACK TO PREVIOUS VERSION
# ============================================================================

recovery_level_4_rollback() {
    log INFO "LEVEL 4: Rolling back to previous version..."
    
    # Check for git repository
    if [[ ! -d .git ]]; then
        log ERROR "Not a git repository"
        return 1
    fi
    
    # Get previous commit
    local previous_commit=$(git rev-parse HEAD~1)
    log INFO "Rolling back to commit: $previous_commit"
    
    # Create backup of current state
    create_emergency_backup
    
    # Rollback code
    git reset --hard "$previous_commit"
    
    # Rebuild and deploy
    docker compose build --no-cache
    docker compose up -d
    
    sleep 60
    if verify_services; then
        log SUCCESS "Level 4 recovery successful"
        return 0
    fi
    
    # If failed, try to restore
    git reset --hard HEAD@{1}
    log ERROR "Level 4 recovery failed"
    return 1
}

# ============================================================================
# RECOVERY LEVEL 5: EMERGENCY MODE
# ============================================================================

recovery_level_5_emergency() {
    log CRITICAL "LEVEL 5: Entering EMERGENCY MODE..."
    
    # Send critical alerts
    send_alert "CRITICAL" "Foodle entering emergency mode - all recovery attempts failed"
    
    # Create emergency containers with minimal requirements
    log INFO "Creating emergency containers..."
    
    # Emergency API
    cat > docker-compose.emergency.yml << 'EOF'
version: '3'

services:
  emergency-api:
    image: php:8.3-apache
    ports:
      - "8081:80"
    volumes:
      - ./foodle-api/src:/var/www/html
    environment:
      - EMERGENCY_MODE=true
    restart: always
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/health"]
      interval: 30s
      
  emergency-db:
    image: mariadb:latest
    ports:
      - "3306:3306"
    environment:
      - MARIADB_ROOT_PASSWORD=emergency
      - MARIADB_DATABASE=foodle_emergency
    volumes:
      - emergency_db:/var/lib/mysql
    restart: always
    
  emergency-cache:
    image: redis:alpine
    ports:
      - "6379:6379"
    command: redis-server --maxmemory 100mb --maxmemory-policy allkeys-lru
    restart: always
    
  emergency-web:
    image: nginx:alpine
    ports:
      - "80:80"
    volumes:
      - ./emergency-static:/usr/share/nginx/html
    restart: always

volumes:
  emergency_db:
EOF
    
    # Create emergency static page
    mkdir -p emergency-static
    cat > emergency-static/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Foodle - Maintenance Mode</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        }
        .container {
            text-align: center;
            background: white;
            padding: 60px;
            border-radius: 20px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            max-width: 500px;
        }
        h1 {
            color: #333;
            margin-bottom: 20px;
            font-size: 2.5em;
        }
        p {
            color: #666;
            font-size: 1.2em;
            line-height: 1.6;
        }
        .emoji {
            font-size: 4em;
            margin-bottom: 20px;
        }
        .status {
            margin-top: 30px;
            padding: 15px;
            background: #f0f0f0;
            border-radius: 10px;
            font-family: monospace;
        }
    </style>
    <script>
        // Auto-refresh every 30 seconds
        setTimeout(() => location.reload(), 30000);
        
        // Check API status
        fetch('/api/health')
            .then(r => r.json())
            .then(data => {
                document.getElementById('api-status').textContent = 'API: Online (Emergency Mode)';
                document.getElementById('api-status').style.color = 'orange';
            })
            .catch(e => {
                document.getElementById('api-status').textContent = 'API: Offline';
                document.getElementById('api-status').style.color = 'red';
            });
    </script>
</head>
<body>
    <div class="container">
        <div class="emoji">🔧</div>
        <h1>We'll Be Right Back!</h1>
        <p>Foodle is currently undergoing emergency maintenance. Our team is working hard to restore service as quickly as possible.</p>
        <div class="status">
            <div id="api-status">Checking system status...</div>
            <div>Estimated recovery: 30-60 minutes</div>
        </div>
    </div>
</body>
</html>
EOF
    
    # Start emergency containers
    docker compose -f docker-compose.emergency.yml up -d
    
    # Create recovery snapshot
    create_recovery_snapshot
    
    # Start recovery monitor
    start_recovery_monitor
    
    log CRITICAL "Emergency mode activated - minimal services running"
    log INFO "Access emergency status at: http://localhost"
    
    return 0
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

create_emergency_container() {
    local service=$1
    
    log INFO "Creating emergency container for $service..."
    
    case $service in
        api)
            docker run -d \
                --name "foodle-$service-emergency" \
                -p 8081:80 \
                -v "$(pwd)/foodle-api/src:/var/www/html" \
                php:8.3-apache
            ;;
        panel)
            docker run -d \
                --name "foodle-$service-emergency" \
                -p 8082:80 \
                nginx:alpine
            ;;
        website)
            docker run -d \
                --name "foodle-$service-emergency" \
                -p 5173:80 \
                nginx:alpine
            ;;
    esac
}

verify_services() {
    log INFO "Verifying services..."
    
    local all_healthy=true
    
    # Check containers
    for container in foodle_api foodle_website foodle_panel foodle_hosted_db foodle_hosted_cache; do
        if ! docker ps | grep -q "$container"; then
            log ERROR "Container not running: $container"
            all_healthy=false
        fi
    done
    
    # Check endpoints
    if ! curl -sf http://localhost:8081/v2/health &>/dev/null; then
        log ERROR "API health check failed"
        all_healthy=false
    fi
    
    if ! curl -sf http://localhost:5173 &>/dev/null; then
        log ERROR "Website not accessible"
        all_healthy=false
    fi
    
    if [[ "$all_healthy" == true ]]; then
        log SUCCESS "All services verified"
        return 0
    else
        log ERROR "Service verification failed"
        return 1
    fi
}

create_emergency_backup() {
    log INFO "Creating emergency backup..."
    
    local backup_path="$BACKUP_DIR/emergency-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_path"
    
    # Backup database
    docker exec foodle_hosted_db mysqldump --all-databases > "$backup_path/database.sql" 2>/dev/null || true
    
    # Backup volumes
    for volume in $(docker volume ls -q | grep foodle); do
        docker run --rm \
            -v "$volume:/source:ro" \
            -v "$backup_path:/backup" \
            alpine tar czf "/backup/${volume}.tar.gz" -C /source . 2>/dev/null || true
    done
    
    # Backup configs
    cp -r *.yml *.env "$backup_path/" 2>/dev/null || true
    
    log INFO "Emergency backup created at: $backup_path"
}

create_recovery_snapshot() {
    log INFO "Creating recovery snapshot..."
    
    local snapshot_file="$RECOVERY_DIR/snapshot-$(date +%Y%m%d-%H%M%S).json"
    mkdir -p "$RECOVERY_DIR"
    
    cat > "$snapshot_file" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "recovery_level": "5",
    "system_state": {
        "containers": $(docker ps -a --format json | jq -s '.'),
        "disk_usage": "$(df -h /)",
        "memory": "$(free -h)",
        "load": "$(uptime)"
    },
    "errors": $(tail -100 "$EMERGENCY_LOG" | jq -Rs '.')
}
EOF
    
    log INFO "Snapshot saved to: $snapshot_file"
}

start_recovery_monitor() {
    log INFO "Starting recovery monitor..."
    
    # Create monitoring script
    cat > /tmp/recovery-monitor.sh << 'EOF'
#!/bin/bash
while true; do
    # Check if normal services are back
    if curl -sf http://localhost:8081/v2/health &>/dev/null; then
        echo "$(date): Services recovered" >> /var/log/foodle-recovery-monitor.log
        
        # Transition from emergency to normal
        docker compose -f docker-compose.emergency.yml down
        
        # Send recovery notification
        curl -X POST "$SLACK_WEBHOOK" \
            -H 'Content-Type: application/json' \
            -d '{"text":"✅ Foodle services recovered from emergency mode"}' 2>/dev/null || true
        
        exit 0
    fi
    
    sleep 60
done
EOF
    
    chmod +x /tmp/recovery-monitor.sh
    nohup /tmp/recovery-monitor.sh &>/dev/null &
    
    log INFO "Recovery monitor started (PID: $!)"
}

# ============================================================================
# AUTOMATED RECOVERY ORCHESTRATION
# ============================================================================

automated_recovery() {
    log INFO "Starting automated recovery process..."
    
    # Save initial state
    echo "recovery_start=$(date +%s)" > "$STATE_FILE"
    echo "recovery_attempt=0" >> "$STATE_FILE"
    
    # Run diagnostics
    diagnose_system
    
    # Try each recovery level
    for level in "${RECOVERY_LEVELS[@]}"; do
        log INFO "Attempting recovery: $level"
        echo "current_level=$level" >> "$STATE_FILE"
        
        case $level in
            LEVEL_1_RESTART)
                recovery_level_1_restart && return 0
                ;;
            LEVEL_2_REBUILD)
                recovery_level_2_rebuild && return 0
                ;;
            LEVEL_3_RESTORE)
                recovery_level_3_restore && return 0
                ;;
            LEVEL_4_ROLLBACK)
                recovery_level_4_rollback && return 0
                ;;
            LEVEL_5_EMERGENCY)
                recovery_level_5_emergency
                return $?
                ;;
        esac
        
        # Wait before next attempt
        sleep 30
    done
    
    log CRITICAL "All recovery attempts failed"
    return 1
}

# ============================================================================
# MAIN MENU
# ============================================================================

show_menu() {
    clear
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║          FOODLE EMERGENCY RECOVERY SYSTEM                 ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  [1] 🔍 Run System Diagnostics"
    echo "  [2] 🔄 Level 1: Restart Services"
    echo "  [3] 🔨 Level 2: Rebuild Containers"
    echo "  [4] 💾 Level 3: Restore from Backup"
    echo "  [5] ⏮️  Level 4: Rollback Version"
    echo "  [6] 🚨 Level 5: Emergency Mode"
    echo "  [7] 🤖 Automated Recovery (All Levels)"
    echo "  [8] 📊 View Recovery Status"
    echo "  [9] 📸 Create Recovery Snapshot"
    echo "  [0] ❌ Exit"
    echo ""
    read -p "Select option (0-9): " choice
    
    case $choice in
        1) diagnose_system ;;
        2) recovery_level_1_restart ;;
        3) recovery_level_2_rebuild ;;
        4) recovery_level_3_restore ;;
        5) recovery_level_4_rollback ;;
        6) recovery_level_5_emergency ;;
        7) automated_recovery ;;
        8) cat "$STATE_FILE" 2>/dev/null || echo "No recovery in progress" ;;
        9) create_recovery_snapshot ;;
        0) exit 0 ;;
        *) log ERROR "Invalid option" ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
    show_menu
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    # Create required directories
    mkdir -p "$RECOVERY_DIR" "$BACKUP_DIR" "$(dirname "$EMERGENCY_LOG")"
    
    # Parse arguments
    case "${1:-}" in
        --auto|-a)
            automated_recovery
            ;;
        --diagnose|-d)
            diagnose_system
            ;;
        --level|-l)
            shift
            case "${1:-}" in
                1) recovery_level_1_restart ;;
                2) recovery_level_2_rebuild ;;
                3) recovery_level_3_restore ;;
                4) recovery_level_4_rollback ;;
                5) recovery_level_5_emergency ;;
                *) log ERROR "Invalid level" ;;
            esac
            ;;
        --help|-h)
            cat << EOF
Foodle Emergency Recovery System

Usage: $0 [OPTIONS]

OPTIONS:
    --auto, -a          Run automated recovery (tries all levels)
    --diagnose, -d      Run system diagnostics only
    --level N, -l N     Run specific recovery level (1-5)
    --help, -h          Show this help message

RECOVERY LEVELS:
    1 - Restart:  Simple service restart
    2 - Rebuild:  Rebuild and restart containers
    3 - Restore:  Restore from backup
    4 - Rollback: Rollback to previous version
    5 - Emergency: Activate emergency mode

Without options, shows interactive menu.

EXAMPLES:
    $0 --auto           # Automated recovery
    $0 --level 3        # Restore from backup
    $0 --diagnose       # Check system status

EOF
            ;;
        "")
            show_menu
            ;;
        *)
            log ERROR "Unknown option: $1"
            exit 1
            ;;
    esac
}

# Handle signals
trap 'log WARNING "Recovery interrupted"; exit 130' INT TERM

# Run main
main "$@"