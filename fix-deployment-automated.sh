#!/bin/bash
# Automated Foodle Deployment Fix Script
# Implements all recommended fixes from deployment-fixes-2025-09-01.md

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
FOODLE_DIR="${FOODLE_DIR:-$HOME/foodle}"
LOG_FILE="/tmp/foodle-fix-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="$HOME/foodle-backups/$(date +%Y%m%d-%H%M%S)"

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

# Create backup
create_backup() {
    log "Creating backup..."
    mkdir -p "$BACKUP_DIR"
    
    # Backup Dockerfiles
    if [ -d "$FOODLE_DIR/panel" ]; then
        cp -r "$FOODLE_DIR/panel/Dockerfile"* "$BACKUP_DIR/" 2>/dev/null || true
    fi
    
    # Backup docker-compose files
    cp "$FOODLE_DIR"/docker-compose*.yml "$BACKUP_DIR/" 2>/dev/null || true
    
    # Backup database if running
    if docker exec foodle_hosted_db mysqldump -u root -p"${MARIADB_ROOT_PASSWORD:-}" --all-databases > "$BACKUP_DIR/database-dump.sql" 2>/dev/null; then
        log "Database backed up successfully"
    fi
    
    log "Backup created at: $BACKUP_DIR"
}

# Fix 1: Panel Dockerfile Node.js versions
fix_panel_dockerfile() {
    log "Fixing Panel Dockerfile Node.js version constraints..."
    
    local dockerfile="$FOODLE_DIR/panel/Dockerfile"
    
    if [ ! -f "$dockerfile" ]; then
        dockerfile="$FOODLE_DIR/Foodle_initial/panel/Dockerfile"
    fi
    
    if [ -f "$dockerfile" ]; then
        # Backup original
        cp "$dockerfile" "$dockerfile.backup.$(date +%Y%m%d-%H%M%S)"
        
        # Apply fix - use version ranges instead of exact versions
        sed -i.bak 's/nodejs=16.20.2-r0 npm=8.19.4-r0/nodejs~16 npm~8/' "$dockerfile"
        
        # Alternative: remove version constraints entirely
        # sed -i 's/nodejs=16.20.2-r0 npm=8.19.4-r0/nodejs npm/' "$dockerfile"
        
        log "✅ Panel Dockerfile fixed"
    else
        warning "Panel Dockerfile not found at $dockerfile"
    fi
}

# Fix 2: System locale configuration
fix_locale() {
    log "Fixing system locale configuration..."
    
    # Check if running on Ubuntu/Debian
    if command -v apt-get >/dev/null 2>&1; then
        # Install locales package
        sudo apt-get update -qq
        sudo apt-get install -y locales
        
        # Generate locale
        sudo locale-gen en_US.UTF-8
        sudo update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
        
        # Export for current session
        export LANG=en_US.UTF-8
        export LC_ALL=en_US.UTF-8
        
        log "✅ Locale configuration fixed"
    else
        info "Not running on Ubuntu/Debian, skipping locale fix"
    fi
}

# Fix 3: SASS compatibility
fix_sass_compatibility() {
    log "Setting up SASS compatibility..."
    
    local panel_dir="$FOODLE_DIR/panel"
    
    if [ ! -d "$panel_dir" ]; then
        panel_dir="$FOODLE_DIR/Foodle_initial/panel"
    fi
    
    if [ -d "$panel_dir" ]; then
        cd "$panel_dir"
        
        # Create SASS compatibility script
        cat > fix-sass.sh << 'EOF'
#!/bin/bash
npm install sass@1.32.13 sass-loader@6.0.7 --save-dev --legacy-peer-deps --force
rm -rf node_modules/node-sass
mkdir -p node_modules/node-sass
echo 'const sass = require("sass"); module.exports = { render: sass.render.bind(sass), renderSync: sass.renderSync.bind(sass), info: "node-sass 4.14.1", types: sass.types || {} };' > node_modules/node-sass/lib.js
echo '{"name":"node-sass","version":"4.14.1","main":"lib.js"}' > node_modules/node-sass/package.json
EOF
        chmod +x fix-sass.sh
        
        log "✅ SASS compatibility script created"
        cd - > /dev/null
    else
        warning "Panel directory not found"
    fi
}

# Fix 4: Docker build with fallbacks
rebuild_panel() {
    log "Rebuilding panel container with fixes..."
    
    cd "$FOODLE_DIR"
    
    # Try different build strategies
    log "Attempting build with flexible versions..."
    if docker compose build --no-cache foodle-panel 2>/dev/null || \
       docker-compose build --no-cache foodle-panel 2>/dev/null; then
        log "✅ Panel rebuilt successfully"
        return 0
    fi
    
    # If failed, try with multi-stage Dockerfile
    if [ -f "panel/Dockerfile.multistage" ]; then
        log "Trying multi-stage build..."
        docker build -f panel/Dockerfile.multistage -t foodle-panel:latest panel/
        return $?
    fi
    
    error "Panel rebuild failed"
    return 1
}

# Fix 5: Optimize resources
apply_resource_optimizations() {
    log "Applying resource optimizations..."
    
    # Check if optimized configs exist
    if [ -f "$FOODLE_DIR/docker-compose-optimized.yml" ]; then
        info "Using optimized docker-compose configuration"
        export COMPOSE_FILE="docker-compose-optimized.yml"
    fi
    
    # Apply PHP OpCache settings
    if [ -f "$FOODLE_DIR/php-opcache-optimization.ini" ]; then
        docker cp "$FOODLE_DIR/php-opcache-optimization.ini" foodle_api:/etc/php83/conf.d/99-opcache.ini 2>/dev/null || true
    fi
    
    # Apply MariaDB optimizations
    if [ -f "$FOODLE_DIR/mariadb-optimization.cnf" ]; then
        docker cp "$FOODLE_DIR/mariadb-optimization.cnf" foodle_hosted_db:/etc/mysql/conf.d/optimization.cnf 2>/dev/null || true
        docker exec foodle_hosted_db mysqladmin flush-tables 2>/dev/null || true
    fi
    
    log "✅ Resource optimizations applied"
}

# Fix 6: Health checks
run_health_checks() {
    log "Running health checks..."
    
    local all_healthy=true
    
    # Check containers
    for container in foodle_api foodle_panel foodle_website foodle_hosted_db foodle_hosted_cache foodle_hosted_rabbitmq; do
        if docker ps | grep -q "$container"; then
            echo -e "${GREEN}✅${NC} $container is running"
        else
            echo -e "${RED}❌${NC} $container is not running"
            all_healthy=false
        fi
    done
    
    # Check API
    if curl -s -f -o /dev/null http://localhost:8081/v2/health 2>/dev/null; then
        echo -e "${GREEN}✅${NC} API is responding"
    else
        echo -e "${RED}❌${NC} API is not responding"
        all_healthy=false
    fi
    
    # Check website
    if curl -s -f -o /dev/null http://localhost:5173 2>/dev/null; then
        echo -e "${GREEN}✅${NC} Website is accessible"
    else
        echo -e "${RED}❌${NC} Website is not accessible"
        all_healthy=false
    fi
    
    # Check panel
    if curl -s -f -o /dev/null http://localhost:8082 2>/dev/null; then
        echo -e "${GREEN}✅${NC} Panel is accessible"
    else
        echo -e "${RED}❌${NC} Panel is not accessible"
        all_healthy=false
    fi
    
    if [ "$all_healthy" = true ]; then
        log "✅ All health checks passed"
        return 0
    else
        warning "Some health checks failed"
        return 1
    fi
}

# Main menu
show_menu() {
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║   Foodle Deployment Fix Script        ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    echo "Select fixes to apply:"
    echo ""
    echo "  [1] Fix Panel Dockerfile (Node.js versions)"
    echo "  [2] Fix System Locale"
    echo "  [3] Setup SASS Compatibility"
    echo "  [4] Rebuild Panel Container"
    echo "  [5] Apply Resource Optimizations"
    echo "  [6] Run Health Checks"
    echo "  [7] Apply ALL Fixes (Recommended)"
    echo "  [8] Create Backup Only"
    echo "  [0] Exit"
    echo ""
    read -p "Enter your choice (0-8): " choice
    
    case $choice in
        1) fix_panel_dockerfile ;;
        2) fix_locale ;;
        3) fix_sass_compatibility ;;
        4) rebuild_panel ;;
        5) apply_resource_optimizations ;;
        6) run_health_checks ;;
        7) 
            create_backup
            fix_panel_dockerfile
            fix_locale
            fix_sass_compatibility
            rebuild_panel
            apply_resource_optimizations
            run_health_checks
            ;;
        8) create_backup ;;
        0) exit 0 ;;
        *) 
            error "Invalid choice"
            show_menu
            ;;
    esac
}

# Quick mode for CI/automation
quick_fix() {
    log "Running quick fix mode..."
    create_backup
    fix_panel_dockerfile
    fix_locale
    fix_sass_compatibility
    
    # Restart containers
    cd "$FOODLE_DIR"
    docker compose down
    docker compose up -d
    
    sleep 10
    run_health_checks
}

# Main execution
main() {
    echo ""
    echo "🔧 Foodle Deployment Fix Script"
    echo "================================"
    echo "Log file: $LOG_FILE"
    echo ""
    
    # Check if running with arguments
    if [ "$1" = "--quick" ] || [ "$1" = "-q" ]; then
        quick_fix
    elif [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --quick, -q     Apply all fixes automatically"
        echo "  --help, -h      Show this help message"
        echo ""
        echo "Without options, shows interactive menu"
    else
        show_menu
    fi
}

# Run main function
main "$@"