#!/bin/bash

# Foodle Unified Deployment Script
# Version: 3.0
# Date: 2025-09-02
# 
# This script combines all deployment functionality into one intelligent system:
# - Pre-deployment health checks
# - Resource-aware deployment strategies
# - All fixes and optimizations
# - State management and recovery
# - Interactive and non-interactive modes

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_VERSION="3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="/tmp/foodle-deployment.state"
LOG_FILE="/tmp/foodle-deployment-$(date +%Y%m%d-%H%M%S).log"
REPORT_FILE="deployment-report-$(date +%Y%m%d-%H%M%S).md"

# Resource thresholds
MIN_MEMORY_MB=400          # Absolute minimum
RECOMMENDED_MEMORY_MB=800  # Recommended minimum
LOW_MEMORY_THRESHOLD=1000  # Below this, use low-memory mode
DOCKER_PRUNE_THRESHOLD=500 # Prune if less than this MB available
MIN_DISK_GB=2              # Minimum disk space

# Deployment modes
MODE=""                    # Set by arguments or auto-detected
DEPLOYMENT_STRATEGY=""     # parallel or sequential
NON_INTERACTIVE=false
FORCE_MODE=false
DRY_RUN=false
VERBOSE=false

# State tracking
CURRENT_STEP=""
COMPLETED_STEPS=()
FAILED_STEPS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# Utility Functions
# ============================================================================

log() {
    local level="${2:-INFO}"
    local color="${3:-$NC}"
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $1"
    
    echo -e "${color}${message}${NC}"
    echo "$message" >> "$LOG_FILE"
}

log_info() {
    log "$1" "INFO" "$BLUE"
}

log_success() {
    log "$1" "SUCCESS" "$GREEN"
}

log_warning() {
    log "$1" "WARNING" "$YELLOW"
}

log_error() {
    log "$1" "ERROR" "$RED"
}

log_debug() {
    if [ "$VERBOSE" = true ]; then
        log "$1" "DEBUG" "$PURPLE"
    fi
}

# Header for sections
print_header() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# Error handler
error_exit() {
    log_error "$1"
    save_state "failed"
    generate_report
    exit 1
}

# Confirmation prompt
confirm() {
    if [ "$NON_INTERACTIVE" = true ] || [ "$FORCE_MODE" = true ]; then
        return 0
    fi
    
    local prompt="${1:-Continue?}"
    read -p "$prompt (y/n): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# ============================================================================
# State Management
# ============================================================================

save_state() {
    local status="${1:-in_progress}"
    cat > "$STATE_FILE" << EOF
STATUS=$status
MODE=$MODE
STRATEGY=$DEPLOYMENT_STRATEGY
CURRENT_STEP=$CURRENT_STEP
COMPLETED_STEPS=(${COMPLETED_STEPS[@]:-})
FAILED_STEPS=(${FAILED_STEPS[@]:-})
TIMESTAMP=$(date +%s)
EOF
    log_debug "State saved: $status"
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
        log_debug "State loaded from $STATE_FILE"
        return 0
    fi
    return 1
}

mark_step_completed() {
    COMPLETED_STEPS+=("$1")
    save_state
    log_debug "Step completed: $1"
}

mark_step_failed() {
    FAILED_STEPS+=("$1")
    save_state
    log_debug "Step failed: $1"
}

# ============================================================================
# System Checks
# ============================================================================

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" ]]; then
            log_success "OS: Ubuntu $VERSION_ID"
            return 0
        else
            log_warning "OS: $ID $VERSION_ID (Ubuntu recommended)"
            return 1
        fi
    else
        log_error "Cannot determine OS version"
        return 1
    fi
}

check_privileges() {
    if [ "$EUID" -eq 0 ]; then
        log_success "Running with root privileges"
        return 0
    else
        log_error "Not running as root (use sudo)"
        return 1
    fi
}

check_memory() {
    local available=$(free -m | awk 'NR==2{print $7}')
    local total=$(free -m | awk 'NR==2{print $2}')
    
    log_info "Memory: ${available}MB available of ${total}MB total"
    
    if [ "$available" -lt "$MIN_MEMORY_MB" ]; then
        log_error "Insufficient memory: ${available}MB (minimum ${MIN_MEMORY_MB}MB required)"
        return 1
    elif [ "$available" -lt "$RECOMMENDED_MEMORY_MB" ]; then
        log_warning "Low memory: ${available}MB (${RECOMMENDED_MEMORY_MB}MB recommended)"
        DEPLOYMENT_STRATEGY="sequential"
    elif [ "$available" -lt "$LOW_MEMORY_THRESHOLD" ]; then
        log_info "Moderate memory available, using optimized deployment"
        DEPLOYMENT_STRATEGY="sequential"
    else
        log_success "Sufficient memory available"
        DEPLOYMENT_STRATEGY="parallel"
    fi
    
    echo "$available"
}

check_disk() {
    local available=$(df / | awk 'NR==2{print int($4/1024/1024)}')
    local total=$(df / | awk 'NR==2{print int($2/1024/1024)}')
    
    log_info "Disk: ${available}GB available of ${total}GB total"
    
    if [ "$available" -lt "$MIN_DISK_GB" ]; then
        log_error "Insufficient disk space: ${available}GB (minimum ${MIN_DISK_GB}GB required)"
        return 1
    fi
    
    return 0
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        return 1
    fi
    
    local version=$(docker --version | awk '{print $3}' | sed 's/,//')
    log_success "Docker installed: version $version"
    
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        return 1
    fi
    
    log_success "Docker daemon is running"
    
    # Check Docker Compose
    if docker compose version &> /dev/null; then
        local dc_version=$(docker compose version | awk '{print $4}')
        log_success "Docker Compose v2: version $dc_version"
    elif command -v docker-compose &> /dev/null; then
        local dc_version=$(docker-compose --version | awk '{print $3}')
        log_success "Docker Compose v1: version $dc_version"
    else
        log_error "Docker Compose not installed"
        return 1
    fi
    
    return 0
}

check_ports() {
    local ports=(80 443 3306 5672 6379 8080 8081)
    local blocked_ports=()
    
    for port in "${ports[@]}"; do
        if netstat -tuln 2>/dev/null | grep -q ":$port "; then
            local service=$(netstat -tulpn 2>/dev/null | grep ":$port " | awk '{print $7}' | cut -d'/' -f2 | head -1)
            
            if [ "$port" -eq 80 ] && [[ "$service" == *"apache"* ]]; then
                log_warning "Port $port used by Apache2 (will be stopped)"
                if confirm "Stop Apache2?"; then
                    systemctl stop apache2
                    systemctl disable apache2
                    log_success "Apache2 stopped and disabled"
                fi
            else
                blocked_ports+=("$port:$service")
            fi
        fi
    done
    
    if [ ${#blocked_ports[@]} -gt 0 ]; then
        log_error "Ports in use: ${blocked_ports[*]}"
        return 1
    fi
    
    log_success "All required ports are available"
    return 0
}

check_existing_deployment() {
    local has_containers=false
    local has_networks=false
    
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "foodle"; then
        has_containers=true
        local count=$(docker ps -a --format '{{.Names}}' | grep -c "foodle")
        log_warning "Found $count existing Foodle containers"
    fi
    
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "foodle"; then
        has_networks=true
        local count=$(docker network ls --format '{{.Name}}' | grep -c "foodle")
        log_warning "Found $count existing Foodle networks"
    fi
    
    if [ "$has_containers" = true ] || [ "$has_networks" = true ]; then
        if confirm "Clean up existing deployment?"; then
            cleanup_deployment
        fi
    fi
    
    return 0
}

# ============================================================================
# Resource Management
# ============================================================================

optimize_memory() {
    local available=$(free -m | awk 'NR==2{print $7}')
    
    if [ "$available" -lt "$DOCKER_PRUNE_THRESHOLD" ]; then
        log_info "Optimizing memory (${available}MB available)..."
        
        # Clear page cache
        sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        
        # Prune Docker
        if command -v docker &> /dev/null && docker info &> /dev/null; then
            log_info "Pruning Docker resources..."
            docker system prune -af --volumes 2>/dev/null || true
            docker builder prune -af 2>/dev/null || true
        fi
        
        # Stop unnecessary services
        for service in snapd bluetooth cups avahi-daemon; do
            if systemctl is-active --quiet $service; then
                systemctl stop $service 2>/dev/null || true
                log_debug "Stopped $service"
            fi
        done
        
        available=$(free -m | awk 'NR==2{print $7}')
        log_info "Memory after optimization: ${available}MB"
    fi
    
    echo "$available"
}

# ============================================================================
# Deployment Functions
# ============================================================================

setup_directories() {
    CURRENT_STEP="setup_directories"
    log_info "Setting up directories..."
    
    # Ensure we're in the right directory
    if [ ! -f "docker-compose.yml" ]; then
        if [ -f "foodle/docker-compose.yml" ]; then
            cd foodle
        elif [ -f "../docker-compose.yml" ]; then
            cd ..
        else
            error_exit "Cannot find docker-compose.yml"
        fi
    fi
    
    mark_step_completed "setup_directories"
}

fix_panel_dockerfile() {
    CURRENT_STEP="fix_panel_dockerfile"
    log_info "Fixing panel Dockerfile..."
    
    if [ -f "panel/Dockerfile" ]; then
        # Backup
        cp panel/Dockerfile panel/Dockerfile.backup.$(date +%s)
        
        # Fix version constraints
        sed -i 's/nodejs=[0-9.]*/nodejs/g' panel/Dockerfile
        sed -i 's/npm=[0-9.]*/npm/g' panel/Dockerfile
        sed -i 's/--repository=[^ ]*//' panel/Dockerfile
        
        log_success "Panel Dockerfile fixed"
    else
        log_warning "panel/Dockerfile not found"
    fi
    
    mark_step_completed "fix_panel_dockerfile"
}

create_docker_networks() {
    CURRENT_STEP="create_networks"
    log_info "Creating Docker networks..."
    
    local networks=("foodle_proxy_network" "foodle_default" "foodle_backend" "foodle_frontend" "foodle_cache" "foodle_db")
    
    for network in "${networks[@]}"; do
        if ! docker network ls --format '{{.Name}}' | grep -q "^${network}$"; then
            docker network create "$network" || log_warning "Failed to create network: $network"
            log_success "Created network: $network"
        else
            log_debug "Network exists: $network"
        fi
    done
    
    mark_step_completed "create_networks"
}

build_containers() {
    CURRENT_STEP="build_containers"
    log_info "Building containers (strategy: $DEPLOYMENT_STRATEGY)..."
    
    local services=("foodle_proxy" "foodle_db" "foodle_cache" "foodle_rabbitmq" "foodle_api" "foodle_website" "foodle_panel")
    
    if [ "$DEPLOYMENT_STRATEGY" == "sequential" ]; then
        # Sequential build for low memory
        for service in "${services[@]}"; do
            log_info "Building $service..."
            
            # Optimize memory before each build
            local mem=$(optimize_memory)
            log_debug "Available memory: ${mem}MB"
            
            if [ "$mem" -lt 300 ]; then
                # Ultra-low memory build
                docker compose build --no-cache --progress plain --memory 256m "$service" || {
                    log_error "Failed to build $service"
                    mark_step_failed "build_$service"
                    return 1
                }
            else
                # Normal build
                docker compose build --no-cache "$service" || {
                    log_error "Failed to build $service"
                    mark_step_failed "build_$service"
                    return 1
                }
            fi
            
            log_success "Built $service"
            docker builder prune -f 2>/dev/null || true
        done
    else
        # Parallel build for sufficient memory
        log_info "Building all containers in parallel..."
        docker compose build --no-cache || {
            log_warning "Parallel build failed, trying sequential..."
            DEPLOYMENT_STRATEGY="sequential"
            build_containers
            return $?
        }
    fi
    
    mark_step_completed "build_containers"
}

start_containers() {
    CURRENT_STEP="start_containers"
    log_info "Starting containers..."
    
    local services=("foodle_db" "foodle_cache" "foodle_rabbitmq" "foodle_proxy" "foodle_api" "foodle_website" "foodle_panel")
    
    if [ "$DEPLOYMENT_STRATEGY" == "sequential" ]; then
        # Sequential start for low memory
        for service in "${services[@]}"; do
            log_info "Starting $service..."
            docker compose up -d "$service" || {
                log_error "Failed to start $service"
                mark_step_failed "start_$service"
                return 1
            }
            sleep 3  # Allow stabilization
            
            if docker ps --format '{{.Names}}' | grep -q "^${service}"; then
                log_success "$service is running"
            else
                log_error "$service failed to start"
                mark_step_failed "start_$service"
                return 1
            fi
        done
    else
        # Parallel start
        docker compose up -d || {
            log_error "Failed to start containers"
            mark_step_failed "start_containers"
            return 1
        }
    fi
    
    mark_step_completed "start_containers"
}

configure_api() {
    CURRENT_STEP="configure_api"
    log_info "Configuring API..."
    
    # Wait for API container to be ready
    sleep 5
    
    # Create comprehensive config.php
    docker exec foodle_api bash -c 'cat > /var/www/html/config.php << '\''EOF'\''
<?php
// Foodle API Configuration - Generated by unified deployment script

// Database Configuration
defined("FOODLE_DB_HOST") or define("FOODLE_DB_HOST", getenv("DB_HOST") ?: "foodle_db");
defined("FOODLE_DB_PORT") or define("FOODLE_DB_PORT", getenv("DB_PORT") ?: "3306");
defined("FOODLE_DB_NAME") or define("FOODLE_DB_NAME", getenv("DB_NAME") ?: "foodle");
defined("FOODLE_DB_USER") or define("FOODLE_DB_USER", getenv("DB_USER") ?: "foodle");
defined("FOODLE_DB_PASS") or define("FOODLE_DB_PASS", getenv("DB_PASS") ?: "MjNh00HdpS1yMoXzFjVHZGQQL");

// Database aliases for compatibility
defined("FOODLE_DB_PASSWORD") or define("FOODLE_DB_PASSWORD", FOODLE_DB_PASS);
defined("FOODLE_DB_DATABASE") or define("FOODLE_DB_DATABASE", FOODLE_DB_NAME);
defined("FOODLE_DB_USERNAME") or define("FOODLE_DB_USERNAME", FOODLE_DB_USER);
defined("FOODLE_DBNAME") or define("FOODLE_DBNAME", FOODLE_DB_NAME);

// Cache Configuration (Redis)
defined("FOODLE_CACHE_HOST") or define("FOODLE_CACHE_HOST", getenv("REDIS_HOST") ?: "foodle_cache");
defined("FOODLE_CACHE_PORT") or define("FOODLE_CACHE_PORT", getenv("REDIS_PORT") ?: "6379");
defined("FOODLE_CACHE_DB") or define("FOODLE_CACHE_DB", getenv("REDIS_DB") ?: "0");
defined("FOODLE_CACHE_PASSWORD") or define("FOODLE_CACHE_PASSWORD", getenv("REDIS_PASSWORD") ?: "");

// Redis aliases
defined("FOODLE_REDIS_HOST") or define("FOODLE_REDIS_HOST", FOODLE_CACHE_HOST);
defined("FOODLE_REDIS_PORT") or define("FOODLE_REDIS_PORT", FOODLE_CACHE_PORT);
defined("FOODLE_REDIS_DB") or define("FOODLE_REDIS_DB", FOODLE_CACHE_DB);
defined("FOODLE_REDIS_PASSWORD") or define("FOODLE_REDIS_PASSWORD", FOODLE_CACHE_PASSWORD);

// KeyDB Configuration
defined("FOODLE_KEYDB_HOST") or define("FOODLE_KEYDB_HOST", getenv("KEYDB_HOST") ?: "foodle_keydb");
defined("FOODLE_KEYDB_PORT") or define("FOODLE_KEYDB_PORT", getenv("KEYDB_PORT") ?: "6379");

// AMQP/RabbitMQ Configuration
defined("FOODLE_AMQP_HOST") or define("FOODLE_AMQP_HOST", getenv("RABBITMQ_HOST") ?: "foodle_rabbitmq");
defined("FOODLE_AMQP_PORT") or define("FOODLE_AMQP_PORT", getenv("RABBITMQ_PORT") ?: "5672");
defined("FOODLE_AMQP_USER") or define("FOODLE_AMQP_USER", getenv("RABBITMQ_USER") ?: "foodle");
defined("FOODLE_AMQP_PASSWORD") or define("FOODLE_AMQP_PASSWORD", getenv("RABBITMQ_PASS") ?: "K6m3UvclIRs5lNEz7sidDqXv0");
defined("FOODLE_AMQP_VHOST") or define("FOODLE_AMQP_VHOST", getenv("AMQP_VHOST") ?: "/");

// AMQP aliases
defined("FOODLE_AMQP_USERNAME") or define("FOODLE_AMQP_USERNAME", FOODLE_AMQP_USER);
defined("FOODLE_AMQP_PASS") or define("FOODLE_AMQP_PASS", FOODLE_AMQP_PASSWORD);

// RabbitMQ aliases
defined("FOODLE_RABBITMQ_HOST") or define("FOODLE_RABBITMQ_HOST", FOODLE_AMQP_HOST);
defined("FOODLE_RABBITMQ_PORT") or define("FOODLE_RABBITMQ_PORT", FOODLE_AMQP_PORT);
defined("FOODLE_RABBITMQ_USER") or define("FOODLE_RABBITMQ_USER", FOODLE_AMQP_USER);
defined("FOODLE_RABBITMQ_PASSWORD") or define("FOODLE_RABBITMQ_PASSWORD", FOODLE_AMQP_PASSWORD);

// Application Configuration
defined("FOODLE_JWT_SECRET") or define("FOODLE_JWT_SECRET", getenv("JWT_SECRET") ?: "your-secret-jwt-key-here");
defined("FOODLE_APP_NAME") or define("FOODLE_APP_NAME", getenv("APP_NAME") ?: "Foodle");
defined("FOODLE_APP_ENV") or define("FOODLE_APP_ENV", getenv("APP_ENV") ?: "production");
defined("FOODLE_APP_DEBUG") or define("FOODLE_APP_DEBUG", getenv("APP_DEBUG") ?: false);

// Domain Configuration
defined("FOODLE_DOMAIN") or define("FOODLE_DOMAIN", getenv("DOMAIN") ?: "foodle.ae");
defined("FOODLE_API_DOMAIN") or define("FOODLE_API_DOMAIN", getenv("API_DOMAIN") ?: "api.foodle.ae");
defined("FOODLE_ADMIN_DOMAIN") or define("FOODLE_ADMIN_DOMAIN", getenv("ADMIN_DOMAIN") ?: "admin.foodle.ae");

// Session Configuration
defined("FOODLE_SESSION_LIFETIME") or define("FOODLE_SESSION_LIFETIME", getenv("SESSION_LIFETIME") ?: 120);
defined("FOODLE_SESSION_DRIVER") or define("FOODLE_SESSION_DRIVER", getenv("SESSION_DRIVER") ?: "redis");

// Return configuration array for legacy compatibility
return [
    "db" => [
        "host" => FOODLE_DB_HOST,
        "port" => FOODLE_DB_PORT,
        "dbname" => FOODLE_DB_NAME,
        "username" => FOODLE_DB_USER,
        "password" => FOODLE_DB_PASS,
    ],
    "cache" => [
        "host" => FOODLE_CACHE_HOST,
        "port" => FOODLE_CACHE_PORT,
        "db" => FOODLE_CACHE_DB,
        "password" => FOODLE_CACHE_PASSWORD,
    ],
    "amqp" => [
        "host" => FOODLE_AMQP_HOST,
        "port" => FOODLE_AMQP_PORT,
        "user" => FOODLE_AMQP_USER,
        "password" => FOODLE_AMQP_PASSWORD,
        "vhost" => FOODLE_AMQP_VHOST,
    ],
    "app" => [
        "name" => FOODLE_APP_NAME,
        "env" => FOODLE_APP_ENV,
        "debug" => FOODLE_APP_DEBUG,
        "jwt_secret" => FOODLE_JWT_SECRET,
    ],
];
EOF'
    
    # Make config read-only to prevent overwriting
    docker exec foodle_api chmod 444 /var/www/html/config.php
    
    log_success "API configuration created"
    mark_step_completed "configure_api"
}

fix_supervisor() {
    CURRENT_STEP="fix_supervisor"
    log_info "Fixing supervisor configurations..."
    
    # Find Yii CLI location
    local yii_paths=("/var/www/html/yii" "/var/www/html/src/yii" "/var/www/html/vendor/bin/yii")
    local yii_path=""
    
    for path in "${yii_paths[@]}"; do
        if docker exec foodle_api test -f "$path" 2>/dev/null; then
            yii_path="$path"
            break
        fi
    done
    
    if [ -n "$yii_path" ]; then
        log_info "Found Yii CLI at: $yii_path"
        
        # Fix supervisor configs
        docker exec foodle_api bash -c "
            find /etc/supervisor/conf.d -name '*.conf' -exec \
                sed -i 's|/var/www/html/src/yii|$yii_path|g' {} \;
            supervisorctl reread
            supervisorctl update
        " 2>/dev/null || log_warning "Could not update supervisor configs"
    else
        log_warning "Yii CLI not found, supervisor daemons may not work"
    fi
    
    mark_step_completed "fix_supervisor"
}

import_database() {
    CURRENT_STEP="import_database"
    log_info "Importing database schema..."
    
    # Wait for database to be ready
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if docker exec foodle_api php -r "
            try {
                \$pdo = new PDO('mysql:host=foodle_db;dbname=foodle', 'foodle', 'MjNh00HdpS1yMoXzFjVHZGQQL');
                echo 'connected';
            } catch (Exception \$e) {
                exit(1);
            }
        " 2>/dev/null | grep -q "connected"; then
            log_success "Database is ready"
            break
        fi
        
        attempt=$((attempt + 1))
        log_debug "Waiting for database... ($attempt/$max_attempts)"
        sleep 2
    done
    
    if [ $attempt -eq $max_attempts ]; then
        log_error "Database not ready after $max_attempts attempts"
        mark_step_failed "import_database"
        return 1
    fi
    
    # Import schema if available
    if [ -f "sample_db/foodle_schema.sql" ]; then
        log_info "Importing database schema..."
        docker exec -i foodle_db mysql -ufoodle -pMjNh00HdpS1yMoXzFjVHZGQQL foodle < sample_db/foodle_schema.sql 2>/dev/null || {
            log_warning "Schema import had errors (may be normal for existing data)"
        }
    fi
    
    mark_step_completed "import_database"
}

# ============================================================================
# Health Checks
# ============================================================================

health_check_containers() {
    log_info "Checking container health..."
    
    local all_healthy=true
    local services=("foodle_db" "foodle_cache" "foodle_rabbitmq" "foodle_proxy" "foodle_api" "foodle_website" "foodle_panel")
    
    for service in "${services[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${service}"; then
            log_success "$service is running"
        else
            log_error "$service is not running"
            all_healthy=false
        fi
    done
    
    return $([ "$all_healthy" = true ] && echo 0 || echo 1)
}

health_check_api() {
    log_info "Checking API health..."
    
    local max_attempts=10
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -sf -o /dev/null -w "%{http_code}" http://localhost:8080/health 2>/dev/null | grep -q "200\|404"; then
            log_success "API is responding"
            return 0
        fi
        
        attempt=$((attempt + 1))
        log_debug "Waiting for API... ($attempt/$max_attempts)"
        sleep 3
    done
    
    log_error "API is not responding"
    return 1
}

health_check_database() {
    log_info "Checking database connection..."
    
    if docker exec foodle_api php -r "
        try {
            \$pdo = new PDO('mysql:host=foodle_db;dbname=foodle', 'foodle', 'MjNh00HdpS1yMoXzFjVHZGQQL');
            echo 'Database connection successful';
        } catch (Exception \$e) {
            echo 'Database connection failed: ' . \$e->getMessage();
            exit(1);
        }
    " 2>/dev/null | grep -q "successful"; then
        log_success "Database connection successful"
        return 0
    else
        log_error "Database connection failed"
        return 1
    fi
}

run_health_checks() {
    print_header "Health Checks"
    
    local all_healthy=true
    
    health_check_containers || all_healthy=false
    health_check_api || all_healthy=false
    health_check_database || all_healthy=false
    
    # Check memory
    local available_mem=$(free -m | awk 'NR==2{print $7}')
    log_info "Final available memory: ${available_mem}MB"
    
    if [ "$all_healthy" = true ]; then
        log_success "All health checks passed!"
        return 0
    else
        log_warning "Some health checks failed"
        return 1
    fi
}

# ============================================================================
# Cleanup Functions
# ============================================================================

cleanup_deployment() {
    log_info "Cleaning up deployment..."
    
    # Stop containers
    if docker ps -a --format '{{.Names}}' | grep -q "foodle"; then
        log_info "Stopping Foodle containers..."
        docker compose down 2>/dev/null || true
        docker ps -a --format '{{.Names}}' | grep "foodle" | xargs -r docker rm -f 2>/dev/null || true
    fi
    
    # Remove networks
    if docker network ls --format '{{.Name}}' | grep -q "foodle"; then
        log_info "Removing Foodle networks..."
        docker network ls --format '{{.Name}}' | grep "foodle" | xargs -r docker network rm 2>/dev/null || true
    fi
    
    # Remove volumes (optional)
    if confirm "Remove Docker volumes (data will be lost)?"; then
        docker volume ls --format '{{.Name}}' | grep "foodle" | xargs -r docker volume rm 2>/dev/null || true
    fi
    
    # Clean build cache
    docker builder prune -af 2>/dev/null || true
    
    log_success "Cleanup completed"
}

# ============================================================================
# Reporting
# ============================================================================

generate_report() {
    cat > "$REPORT_FILE" << EOF
# Foodle Deployment Report
**Date**: $(date)
**Version**: $SCRIPT_VERSION
**Mode**: ${MODE:-auto}
**Strategy**: ${DEPLOYMENT_STRATEGY:-not set}
**Status**: ${STATUS:-unknown}

## System Information
- **OS**: $(lsb_release -ds 2>/dev/null || echo "Unknown")
- **Memory**: $(free -m | awk 'NR==2{printf "%dMB / %dMB", $7, $2}')
- **Disk**: $(df -h / | awk 'NR==2{printf "%s / %s", $4, $2}')
- **CPU**: $(nproc) cores
- **Docker**: $(docker --version 2>/dev/null || echo "Not installed")

## Deployment Steps
### Completed Steps
$(printf '%s\n' "${COMPLETED_STEPS[@]:-None}")

### Failed Steps
$(printf '%s\n' "${FAILED_STEPS[@]:-None}")

## Container Status
\`\`\`
$(docker ps -a --format "table {{.Names}}\t{{.Status}}" | grep foodle 2>/dev/null || echo "No containers found")
\`\`\`

## Network Configuration
\`\`\`
$(docker network ls --format "table {{.Name}}\t{{.Driver}}" | grep foodle 2>/dev/null || echo "No networks found")
\`\`\`

## Logs
See full logs at: $LOG_FILE

## Access URLs
- Website: http://$(hostname -I | awk '{print $1}'):80
- API: http://$(hostname -I | awk '{print $1}'):8080
- Admin: http://$(hostname -I | awk '{print $1}'):8081
EOF
    
    log_info "Report saved to: $REPORT_FILE"
}

# ============================================================================
# Mode Selection
# ============================================================================

detect_mode() {
    # Check if it's a fresh system or existing deployment
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "foodle"; then
        MODE="fix"
        log_info "Detected existing deployment, using fix mode"
    else
        MODE="deploy"
        log_info "No existing deployment detected, using full deployment mode"
    fi
}

# ============================================================================
# Interactive Menu
# ============================================================================

show_menu() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           Foodle Unified Deployment System v${SCRIPT_VERSION}           ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo "Please select an option:"
    echo
    echo "  [1] 🚀 Full Deployment (fresh install)"
    echo "  [2] 🔧 Fix Mode (repair existing deployment)"
    echo "  [3] 📊 Status Check (validate deployment)"
    echo "  [4] 🧹 Cleanup (remove deployment)"
    echo "  [5] 🤖 Auto Mode (intelligent detection)"
    echo "  [6] ❌ Exit"
    echo
    read -p "Enter your choice (1-6): " choice
    
    case $choice in
        1) MODE="deploy" ;;
        2) MODE="fix" ;;
        3) MODE="status" ;;
        4) MODE="cleanup" ;;
        5) MODE="auto" ;;
        6) exit 0 ;;
        *) 
            log_error "Invalid choice"
            sleep 2
            show_menu
            ;;
    esac
}

# ============================================================================
# Main Execution Modes
# ============================================================================

run_deploy_mode() {
    print_header "Full Deployment Mode"
    
    # Pre-deployment checks
    check_memory
    check_disk
    check_docker || error_exit "Docker not properly installed"
    check_ports
    check_existing_deployment
    
    # Optimize resources
    optimize_memory
    
    # Deployment steps
    setup_directories
    fix_panel_dockerfile
    create_docker_networks
    build_containers || error_exit "Container build failed"
    start_containers || error_exit "Container start failed"
    configure_api
    fix_supervisor
    import_database
    
    # Health checks
    run_health_checks
    
    save_state "completed"
    generate_report
    
    log_success "Deployment completed successfully!"
}

run_fix_mode() {
    print_header "Fix Mode"
    
    # Check what needs fixing
    log_info "Analyzing existing deployment..."
    
    setup_directories
    fix_panel_dockerfile
    create_docker_networks
    
    # Fix configuration
    configure_api
    fix_supervisor
    
    # Restart containers if needed
    if confirm "Restart containers?"; then
        docker compose restart
    fi
    
    # Health checks
    run_health_checks
    
    save_state "fixed"
    generate_report
    
    log_success "Fixes applied successfully!"
}

run_status_mode() {
    print_header "Status Check Mode"
    
    check_os
    check_privileges
    check_memory
    check_disk
    check_docker
    check_ports
    
    if docker ps -a --format '{{.Names}}' | grep -q "foodle"; then
        run_health_checks
    else
        log_warning "No Foodle deployment found"
    fi
    
    generate_report
}

run_cleanup_mode() {
    print_header "Cleanup Mode"
    
    if confirm "This will remove all Foodle containers, networks, and optionally volumes. Continue?"; then
        cleanup_deployment
        rm -f "$STATE_FILE"
        log_success "Cleanup completed"
    else
        log_info "Cleanup cancelled"
    fi
}

run_auto_mode() {
    print_header "Auto Mode - Intelligent Detection"
    
    detect_mode
    
    case $MODE in
        deploy) run_deploy_mode ;;
        fix) run_fix_mode ;;
        *) error_exit "Could not determine appropriate mode" ;;
    esac
}

# ============================================================================
# Argument Parsing
# ============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --deploy|--full)
                MODE="deploy"
                shift
                ;;
            --fix|--repair)
                MODE="fix"
                shift
                ;;
            --status|--check)
                MODE="status"
                shift
                ;;
            --cleanup|--clean)
                MODE="cleanup"
                shift
                ;;
            --auto)
                MODE="auto"
                shift
                ;;
            --non-interactive|-n)
                NON_INTERACTIVE=true
                shift
                ;;
            --force|-f)
                FORCE_MODE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat << EOF
Foodle Unified Deployment System v${SCRIPT_VERSION}

Usage: $0 [OPTIONS]

OPTIONS:
    --deploy, --full       Run full deployment
    --fix, --repair        Fix existing deployment
    --status, --check      Check deployment status
    --cleanup, --clean     Remove deployment
    --auto                 Auto-detect mode
    --non-interactive, -n  Run without prompts
    --force, -f            Force actions without confirmation
    --dry-run              Preview actions without executing
    --verbose, -v          Enable verbose output
    --help, -h             Show this help message

EXAMPLES:
    $0                     # Interactive menu
    $0 --deploy            # Full deployment
    $0 --fix               # Fix existing deployment
    $0 --status            # Check status
    $0 --auto -n           # Auto mode, non-interactive

NOTES:
    - Requires sudo/root privileges
    - Automatically detects low-memory conditions
    - Creates deployment report after completion
    - Logs saved to: $LOG_FILE

EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    # Initial setup
    exec 2>&1  # Redirect stderr to stdout
    
    # Parse arguments
    parse_arguments "$@"
    
    # Check privileges early
    if ! check_privileges; then
        error_exit "Please run with sudo or as root"
    fi
    
    # Show header
    print_header "Foodle Unified Deployment System v${SCRIPT_VERSION}"
    
    # If no mode specified, show menu (unless non-interactive)
    if [ -z "$MODE" ]; then
        if [ "$NON_INTERACTIVE" = true ]; then
            MODE="auto"
        else
            show_menu
        fi
    fi
    
    # Check for resume
    if load_state && [ "$STATUS" = "in_progress" ]; then
        if confirm "Resume previous deployment?"; then
            log_info "Resuming from step: $CURRENT_STEP"
        else
            rm -f "$STATE_FILE"
        fi
    fi
    
    # Execute based on mode
    case $MODE in
        deploy) run_deploy_mode ;;
        fix) run_fix_mode ;;
        status) run_status_mode ;;
        cleanup) run_cleanup_mode ;;
        auto) run_auto_mode ;;
        *) error_exit "Invalid mode: $MODE" ;;
    esac
    
    # Final message
    echo
    log_success "Operation completed. Report saved to: $REPORT_FILE"
    log_info "Logs available at: $LOG_FILE"
}

# ============================================================================
# Script Execution
# ============================================================================

# Trap for cleanup on exit
trap 'save_state "interrupted"' INT TERM

# Run main function
main "$@"