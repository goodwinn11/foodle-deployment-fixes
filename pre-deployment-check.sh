#!/bin/bash

# Foodle Pre-Deployment Health Check Script
# Validates system readiness before deployment

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Requirements
MIN_MEMORY_MB=800
MIN_DISK_GB=5
REQUIRED_PORTS=(80 443 3306 5672 6379 8080 8081)

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# Functions
check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASSED++))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAILED++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    ((WARNINGS++))
}

header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# System checks
check_system() {
    header "System Requirements"
    
    # Check OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" ]]; then
            check_pass "Operating System: Ubuntu $VERSION"
        else
            check_warn "Operating System: $ID $VERSION (Ubuntu recommended)"
        fi
    else
        check_fail "Cannot determine OS version"
    fi
    
    # Check architecture
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]] || [[ "$ARCH" == "aarch64" ]]; then
        check_pass "Architecture: $ARCH"
    else
        check_warn "Architecture: $ARCH (x86_64 or aarch64 recommended)"
    fi
    
    # Check if running as root/sudo
    if [ "$EUID" -eq 0 ]; then
        check_pass "Running with root privileges"
    else
        check_fail "Not running as root (use sudo)"
    fi
}

check_resources() {
    header "Resource Availability"
    
    # Memory check
    AVAILABLE_MEM=$(free -m | awk 'NR==2{print $7}')
    TOTAL_MEM=$(free -m | awk 'NR==2{print $2}')
    
    if [ "$AVAILABLE_MEM" -ge "$MIN_MEMORY_MB" ]; then
        check_pass "Memory: ${AVAILABLE_MEM}MB available of ${TOTAL_MEM}MB total"
    elif [ "$AVAILABLE_MEM" -ge 400 ]; then
        check_warn "Memory: ${AVAILABLE_MEM}MB available (${MIN_MEMORY_MB}MB recommended)"
    else
        check_fail "Memory: Only ${AVAILABLE_MEM}MB available (minimum 400MB required)"
    fi
    
    # Disk space check
    AVAILABLE_DISK=$(df / | awk 'NR==2{print int($4/1024/1024)}')
    TOTAL_DISK=$(df / | awk 'NR==2{print int($2/1024/1024)}')
    
    if [ "$AVAILABLE_DISK" -ge "$MIN_DISK_GB" ]; then
        check_pass "Disk Space: ${AVAILABLE_DISK}GB available of ${TOTAL_DISK}GB total"
    elif [ "$AVAILABLE_DISK" -ge 2 ]; then
        check_warn "Disk Space: ${AVAILABLE_DISK}GB available (${MIN_DISK_GB}GB recommended)"
    else
        check_fail "Disk Space: Only ${AVAILABLE_DISK}GB available (minimum 2GB required)"
    fi
    
    # CPU check
    CPU_CORES=$(nproc)
    if [ "$CPU_CORES" -ge 2 ]; then
        check_pass "CPU Cores: $CPU_CORES"
    else
        check_warn "CPU Cores: $CPU_CORES (2+ recommended)"
    fi
}

check_docker() {
    header "Docker Environment"
    
    # Check Docker installation
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version | awk '{print $3}' | sed 's/,//')
        check_pass "Docker installed: version $DOCKER_VERSION"
        
        # Check Docker daemon
        if docker info &> /dev/null; then
            check_pass "Docker daemon is running"
        else
            check_fail "Docker daemon is not running"
        fi
        
        # Check Docker Compose
        if command -v docker-compose &> /dev/null; then
            DC_VERSION=$(docker-compose --version | awk '{print $3}' | sed 's/,//')
            check_pass "Docker Compose v1 installed: version $DC_VERSION"
        fi
        
        # Check Docker Compose v2
        if docker compose version &> /dev/null; then
            DC2_VERSION=$(docker compose version | awk '{print $4}')
            check_pass "Docker Compose v2 installed: version $DC2_VERSION"
        elif ! command -v docker-compose &> /dev/null; then
            check_fail "Docker Compose not installed"
        fi
        
        # Check Docker resources
        DOCKER_IMAGES=$(docker images -q | wc -l)
        DOCKER_CONTAINERS=$(docker ps -aq | wc -l)
        DOCKER_VOLUMES=$(docker volume ls -q | wc -l)
        
        echo "  Docker resources: $DOCKER_IMAGES images, $DOCKER_CONTAINERS containers, $DOCKER_VOLUMES volumes"
        
        # Check if cleanup might help
        if [ "$AVAILABLE_MEM" -lt "$MIN_MEMORY_MB" ] && [ "$DOCKER_CONTAINERS" -gt 0 ]; then
            check_warn "Low memory: Consider running 'docker system prune -a' to free resources"
        fi
    else
        check_fail "Docker is not installed"
    fi
}

check_ports() {
    header "Port Availability"
    
    for PORT in "${REQUIRED_PORTS[@]}"; do
        if ! netstat -tuln 2>/dev/null | grep -q ":$PORT "; then
            check_pass "Port $PORT is available"
        else
            SERVICE=$(netstat -tulpn 2>/dev/null | grep ":$PORT " | awk '{print $7}' | cut -d'/' -f2 | head -1)
            if [ -z "$SERVICE" ]; then
                SERVICE="unknown"
            fi
            
            if [ "$PORT" -eq 80 ] && [[ "$SERVICE" == *"apache"* ]]; then
                check_warn "Port $PORT is used by Apache2 (will be stopped during deployment)"
            else
                check_fail "Port $PORT is in use by: $SERVICE"
            fi
        fi
    done
}

check_network() {
    header "Network Connectivity"
    
    # Check internet connectivity
    if ping -c 1 google.com &> /dev/null; then
        check_pass "Internet connectivity confirmed"
    else
        check_fail "No internet connectivity"
    fi
    
    # Check DNS resolution
    if nslookup google.com &> /dev/null; then
        check_pass "DNS resolution working"
    else
        check_warn "DNS resolution issues detected"
    fi
    
    # Check Docker Hub access
    if curl -s https://hub.docker.com &> /dev/null; then
        check_pass "Docker Hub accessible"
    else
        check_warn "Cannot reach Docker Hub (may affect image pulls)"
    fi
}

check_existing_deployment() {
    header "Existing Deployment"
    
    # Check for existing Foodle containers
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "foodle"; then
        FOODLE_CONTAINERS=$(docker ps -a --format '{{.Names}}' | grep "foodle" | wc -l)
        check_warn "Found $FOODLE_CONTAINERS existing Foodle containers"
        echo "  Run 'docker ps -a | grep foodle' to see details"
    else
        check_pass "No existing Foodle containers found"
    fi
    
    # Check for existing Foodle networks
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "foodle"; then
        FOODLE_NETWORKS=$(docker network ls --format '{{.Name}}' | grep "foodle" | wc -l)
        check_warn "Found $FOODLE_NETWORKS existing Foodle networks"
    else
        check_pass "No existing Foodle networks found"
    fi
    
    # Check for repository
    if [ -d "./foodle" ] || [ -d "../foodle" ]; then
        check_pass "Foodle repository found"
    else
        check_warn "Foodle repository not found in current or parent directory"
    fi
}

generate_recommendations() {
    header "Recommendations"
    
    if [ "$FAILED" -gt 0 ]; then
        echo -e "${RED}Critical issues found that must be resolved:${NC}"
        
        if [ "$AVAILABLE_MEM" -lt 400 ]; then
            echo "  • Free up memory by stopping unnecessary services"
            echo "  • Run: sudo docker system prune -a --volumes"
            echo "  • Run: sudo systemctl stop snapd (if not needed)"
        fi
        
        if [ "$AVAILABLE_DISK" -lt 2 ]; then
            echo "  • Free up disk space"
            echo "  • Run: sudo apt autoremove && sudo apt clean"
            echo "  • Run: sudo docker system prune -a --volumes"
        fi
        
        if ! command -v docker &> /dev/null; then
            echo "  • Install Docker:"
            echo "    curl -fsSL https://get.docker.com | sudo sh"
        fi
    fi
    
    if [ "$WARNINGS" -gt 0 ]; then
        echo -e "${YELLOW}Warnings that should be addressed:${NC}"
        
        if [ "$AVAILABLE_MEM" -lt "$MIN_MEMORY_MB" ]; then
            echo "  • Low memory may cause deployment issues"
            echo "  • Consider using deploy-optimized-low-memory.sh script"
        fi
        
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "foodle"; then
            echo "  • Existing containers may conflict"
            echo "  • Run: docker compose down (in foodle directory)"
        fi
    fi
    
    if [ "$FAILED" -eq 0 ]; then
        echo -e "${GREEN}System is ready for deployment!${NC}"
        echo "Next steps:"
        echo "  1. cd to the foodle repository directory"
        echo "  2. Run: sudo ./deploy-optimized-low-memory.sh"
    fi
}

# Main execution
main() {
    echo -e "${BLUE}════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}     Foodle Pre-Deployment Health Check${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════${NC}"
    
    check_system
    check_resources
    check_docker
    check_ports
    check_network
    check_existing_deployment
    
    echo -e "\n${BLUE}════════════════════════════════════════════════${NC}"
    echo -e "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}, ${YELLOW}$WARNINGS warnings${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════${NC}"
    
    generate_recommendations
    
    # Exit with appropriate code
    if [ "$FAILED" -gt 0 ]; then
        exit 1
    elif [ "$WARNINGS" -gt 0 ]; then
        exit 0  # Warnings don't fail the check
    else
        exit 0
    fi
}

# Run main function
main "$@"