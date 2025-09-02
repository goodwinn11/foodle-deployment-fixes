#!/bin/bash

# Foodle Optimized Deployment Script for Low-Resource Environments
# Based on deployment failures from 2025-09-02
# Designed for servers with limited memory (< 1GB)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REQUIRED_MEMORY_MB=800  # Minimum required memory in MB
DOCKER_PRUNE_THRESHOLD=500  # Prune if less than this MB available

# Logging function
log() {
    echo -e "${2:-$BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

# Check system resources
check_resources() {
    log "Checking system resources..."
    
    # Check available memory
    local available_mem=$(free -m | awk 'NR==2{print $7}')
    log "Available memory: ${available_mem}MB"
    
    if [ "$available_mem" -lt "$REQUIRED_MEMORY_MB" ]; then
        warning "Low memory detected: ${available_mem}MB available, ${REQUIRED_MEMORY_MB}MB recommended"
        
        # Try to free up memory
        log "Attempting to free up memory..."
        
        # Clear page cache
        sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        
        # Check Docker resources
        if command -v docker &> /dev/null; then
            log "Cleaning Docker resources..."
            docker system df
            
            if [ "$available_mem" -lt "$DOCKER_PRUNE_THRESHOLD" ]; then
                read -p "Would you like to prune Docker resources to free memory? (y/n): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    docker system prune -a --volumes -f
                    docker network prune -f
                fi
            fi
        fi
        
        # Check again
        available_mem=$(free -m | awk 'NR==2{print $7}')
        log "Available memory after cleanup: ${available_mem}MB"
        
        if [ "$available_mem" -lt 400 ]; then
            error "Insufficient memory. At least 400MB required, only ${available_mem}MB available"
        fi
    fi
    
    # Check disk space
    local available_disk=$(df / | awk 'NR==2{print int($4/1024)}')
    log "Available disk space: ${available_disk}MB"
    
    if [ "$available_disk" -lt 2000 ]; then
        warning "Low disk space: ${available_disk}MB available, 2000MB recommended"
    fi
    
    # Check for conflicting services
    if systemctl is-active --quiet apache2; then
        warning "Apache2 is running and may conflict with Docker containers"
        read -p "Would you like to stop Apache2? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo systemctl stop apache2
            sudo systemctl disable apache2
            success "Apache2 stopped and disabled"
        fi
    fi
}

# Fix panel Dockerfile
fix_panel_dockerfile() {
    log "Fixing panel Dockerfile version constraints..."
    
    if [ -f "panel/Dockerfile" ]; then
        # Backup original
        cp panel/Dockerfile panel/Dockerfile.backup
        
        # Remove specific version constraints for nodejs and npm
        sed -i 's/nodejs=[0-9.]*/nodejs/g' panel/Dockerfile
        sed -i 's/npm=[0-9.]*/npm/g' panel/Dockerfile
        
        # Alternative: Use more flexible version constraints
        sed -i 's/apk add --no-cache nodejs=.* npm=.*/apk add --no-cache nodejs npm/g' panel/Dockerfile
        
        success "Panel Dockerfile fixed to use available Node.js versions"
    else
        warning "panel/Dockerfile not found, skipping fix"
    fi
}

# Create required Docker networks
create_docker_networks() {
    log "Creating Docker networks..."
    
    local networks=("foodle_proxy_network" "foodle_default" "foodle_backend" "foodle_frontend" "foodle_cache" "foodle_db")
    
    for network in "${networks[@]}"; do
        if ! docker network ls | grep -q "$network"; then
            docker network create "$network" || warning "Failed to create network: $network"
            log "Created network: $network"
        else
            log "Network already exists: $network"
        fi
    done
}

# Build containers sequentially (not in parallel)
build_containers_sequential() {
    log "Building containers sequentially to conserve memory..."
    
    # Array of services to build in order
    local services=("foodle_proxy" "foodle_db" "foodle_cache" "foodle_rabbitmq" "foodle_api" "foodle_website" "foodle_panel")
    
    for service in "${services[@]}"; do
        log "Building $service..."
        
        # Free memory before each build
        sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        
        # Check available memory
        local available_mem=$(free -m | awk 'NR==2{print $7}')
        log "Available memory before building $service: ${available_mem}MB"
        
        if [ "$available_mem" -lt 300 ]; then
            warning "Very low memory, attempting minimal build..."
            # Build with minimal resources
            docker compose build --no-cache --progress plain --memory 256m "$service" || {
                error "Failed to build $service due to resource constraints"
            }
        else
            # Normal build
            docker compose build --no-cache "$service" || {
                warning "Failed to build $service, retrying with cleanup..."
                docker system prune -f
                docker compose build --no-cache "$service" || error "Failed to build $service after retry"
            }
        fi
        
        success "Built $service successfully"
        
        # Clean build cache after each container
        docker builder prune -f
    done
}

# Start containers one by one
start_containers_sequential() {
    log "Starting containers sequentially..."
    
    # Start in dependency order
    local services=("foodle_db" "foodle_cache" "foodle_rabbitmq" "foodle_proxy" "foodle_api" "foodle_website" "foodle_panel")
    
    for service in "${services[@]}"; do
        log "Starting $service..."
        
        docker compose up -d "$service" || {
            warning "Failed to start $service, checking logs..."
            docker compose logs --tail 50 "$service"
            error "Failed to start $service"
        }
        
        # Wait for service to stabilize
        sleep 5
        
        # Check if container is running
        if docker ps | grep -q "$service"; then
            success "$service is running"
        else
            error "$service failed to start"
        fi
    done
}

# Create comprehensive config.php for API
create_api_config() {
    log "Creating API configuration..."
    
    docker exec foodle_api bash -c 'cat > /var/www/html/config.php << EOF
<?php
// Foodle API Configuration - Generated by optimized deployment script

// Database Configuration
defined("FOODLE_DB_HOST") or define("FOODLE_DB_HOST", getenv("DB_HOST") ?: "foodle_db");
defined("FOODLE_DB_PORT") or define("FOODLE_DB_PORT", getenv("DB_PORT") ?: "3306");
defined("FOODLE_DB_NAME") or define("FOODLE_DB_NAME", getenv("DB_NAME") ?: "foodle");
defined("FOODLE_DB_USER") or define("FOODLE_DB_USER", getenv("DB_USER") ?: "foodle");
defined("FOODLE_DB_PASS") or define("FOODLE_DB_PASS", getenv("DB_PASS") ?: "MjNh00HdpS1yMoXzFjVHZGQQL");
defined("FOODLE_DB_PASSWORD") or define("FOODLE_DB_PASSWORD", FOODLE_DB_PASS);

// Cache Configuration
defined("FOODLE_CACHE_HOST") or define("FOODLE_CACHE_HOST", getenv("REDIS_HOST") ?: "foodle_cache");
defined("FOODLE_CACHE_PORT") or define("FOODLE_CACHE_PORT", getenv("REDIS_PORT") ?: "6379");
defined("FOODLE_REDIS_HOST") or define("FOODLE_REDIS_HOST", FOODLE_CACHE_HOST);
defined("FOODLE_REDIS_PORT") or define("FOODLE_REDIS_PORT", FOODLE_CACHE_PORT);

// RabbitMQ Configuration
defined("FOODLE_AMQP_HOST") or define("FOODLE_AMQP_HOST", getenv("RABBITMQ_HOST") ?: "foodle_rabbitmq");
defined("FOODLE_AMQP_PORT") or define("FOODLE_AMQP_PORT", getenv("RABBITMQ_PORT") ?: "5672");
defined("FOODLE_AMQP_USER") or define("FOODLE_AMQP_USER", getenv("RABBITMQ_USER") ?: "foodle");
defined("FOODLE_AMQP_PASSWORD") or define("FOODLE_AMQP_PASSWORD", getenv("RABBITMQ_PASS") ?: "K6m3UvclIRs5lNEz7sidDqXv0");

// Application Configuration
defined("FOODLE_JWT_SECRET") or define("FOODLE_JWT_SECRET", getenv("JWT_SECRET") ?: "foodle-jwt-secret-key");
defined("FOODLE_DOMAIN") or define("FOODLE_DOMAIN", getenv("DOMAIN") ?: "foodle.ae");

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
    ],
    "amqp" => [
        "host" => FOODLE_AMQP_HOST,
        "port" => FOODLE_AMQP_PORT,
        "user" => FOODLE_AMQP_USER,
        "password" => FOODLE_AMQP_PASSWORD,
    ],
];
EOF'
    
    success "API configuration created"
}

# Health check
health_check() {
    log "Running health checks..."
    
    local all_healthy=true
    
    # Check containers
    log "Checking container status..."
    docker ps --format "table {{.Names}}\t{{.Status}}" | grep foodle || {
        warning "Some containers may not be running"
        all_healthy=false
    }
    
    # Check API
    log "Checking API health..."
    if curl -f -s -o /dev/null -w "%{http_code}" http://localhost:8080/health | grep -q "200"; then
        success "API is responding"
    else
        warning "API is not responding correctly"
        all_healthy=false
    fi
    
    # Check database
    log "Checking database connection..."
    docker exec foodle_api php -r "
        try {
            \$pdo = new PDO('mysql:host=foodle_db;dbname=foodle', 'foodle', 'MjNh00HdpS1yMoXzFjVHZGQQL');
            echo 'Database connection successful';
        } catch (Exception \$e) {
            echo 'Database connection failed: ' . \$e->getMessage();
            exit(1);
        }
    " && success "Database connection successful" || {
        warning "Database connection failed"
        all_healthy=false
    }
    
    # Memory check
    local available_mem=$(free -m | awk 'NR==2{print $7}')
    log "Final available memory: ${available_mem}MB"
    
    if [ "$all_healthy" = true ]; then
        success "All health checks passed!"
        return 0
    else
        warning "Some health checks failed. Check the logs for details."
        return 1
    fi
}

# Main deployment function
main() {
    log "Starting Foodle optimized deployment for low-resource environments"
    
    # Check if running as root or with sudo
    if [ "$EUID" -ne 0 ]; then 
        error "Please run with sudo or as root"
    fi
    
    # Step 1: Check resources
    check_resources
    
    # Step 2: Fix panel Dockerfile
    fix_panel_dockerfile
    
    # Step 3: Create Docker networks
    create_docker_networks
    
    # Step 4: Build containers sequentially
    build_containers_sequential
    
    # Step 5: Start containers sequentially
    start_containers_sequential
    
    # Step 6: Configure API
    create_api_config
    
    # Step 7: Run health checks
    health_check
    
    success "Deployment completed!"
    log "Access the application at:"
    log "  - Website: http://$(hostname -I | awk '{print $1}'):80"
    log "  - API: http://$(hostname -I | awk '{print $1}'):8080"
    
    # Save deployment report
    {
        echo "# Foodle Deployment Report - $(date)"
        echo "## System Resources"
        echo "- Memory: $(free -m | awk 'NR==2{print $7}')MB available"
        echo "- Disk: $(df / | awk 'NR==2{print int($4/1024)}')MB available"
        echo ""
        echo "## Container Status"
        docker ps --format "table {{.Names}}\t{{.Status}}" | grep foodle
        echo ""
        echo "## Network Configuration"
        docker network ls | grep foodle
    } > deployment-report-$(date +%Y-%m-%d-%H%M%S).txt
    
    log "Deployment report saved to deployment-report-*.txt"
}

# Handle script interruption
trap 'error "Script interrupted"' INT TERM

# Run main function
main "$@"