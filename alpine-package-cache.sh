#!/bin/bash
# Alpine Package Cache Manager
# Creates and maintains a local cache of Alpine packages for resilient builds

set -e

CACHE_DIR="${ALPINE_CACHE_DIR:-/var/cache/alpine-packages}"
ALPINE_VERSION="${ALPINE_VERSION:-3.16}"
ALPINE_ARCH="${ALPINE_ARCH:-x86_64}"

echo "🗄️ Alpine Package Cache Manager"
echo "================================"

# Function to create cache directory
init_cache() {
    echo "📁 Initializing cache directory at $CACHE_DIR..."
    mkdir -p "$CACHE_DIR"/{v$ALPINE_VERSION,APKINDEX}
    echo "✅ Cache directory initialized"
}

# Function to download packages
cache_packages() {
    local packages="$@"
    
    echo "📦 Caching packages: $packages"
    
    # Create temporary Alpine container for package download
    docker run --rm \
        -v "$CACHE_DIR:/cache" \
        alpine:$ALPINE_VERSION \
        sh -c "
            # Update package index
            apk update
            
            # Download packages and dependencies
            cd /cache/v$ALPINE_VERSION
            apk fetch --recursive $packages
            
            # Copy APKINDEX files
            cp /var/cache/apk/APKINDEX.* /cache/APKINDEX/ 2>/dev/null || true
            
            # List cached packages
            echo '📋 Cached packages:'
            ls -la *.apk 2>/dev/null | head -20
        "
    
    echo "✅ Packages cached successfully"
}

# Function to create Dockerfile with cache
create_cached_dockerfile() {
    local output_file="${1:-Dockerfile.cached}"
    
    echo "📝 Creating cached Dockerfile: $output_file"
    
    cat > "$output_file" << 'EOF'
# syntax=docker/dockerfile:1.4
FROM alpine:3.16

# Use BuildKit cache mount for APK packages
RUN --mount=type=cache,target=/var/cache/apk \
    --mount=type=bind,source=/var/cache/alpine-packages/v3.16,target=/cache/packages \
    --mount=type=bind,source=/var/cache/alpine-packages/APKINDEX,target=/cache/apkindex \
    apk add --no-cache \
        --allow-untrusted \
        --repository file:///cache/packages \
        nodejs npm python3 make g++ || \
    # Fallback to network if cache fails
    apk add --no-cache \
        --repository http://dl-cdn.alpinelinux.org/alpine/v3.16/main \
        --repository http://dl-cdn.alpinelinux.org/alpine/v3.16/community \
        nodejs npm python3 make g++

# Your application setup continues here...
WORKDIR /app
EOF
    
    echo "✅ Cached Dockerfile created"
}

# Function to build with cache
build_with_cache() {
    local dockerfile="${1:-Dockerfile.cached}"
    local image_name="${2:-foodle-panel}"
    
    echo "🔨 Building with package cache..."
    
    # Enable BuildKit
    export DOCKER_BUILDKIT=1
    
    # Build with cache mounts
    docker build \
        --progress=plain \
        -f "$dockerfile" \
        -t "$image_name" \
        --build-arg BUILDKIT_INLINE_CACHE=1 \
        .
    
    echo "✅ Build completed with cache"
}

# Function to setup mirror fallbacks
setup_mirrors() {
    echo "🌐 Setting up mirror fallbacks..."
    
    cat > alpine-mirrors.txt << 'EOF'
http://dl-cdn.alpinelinux.org/alpine
http://dl-2.alpinelinux.org/alpine
http://dl-3.alpinelinux.org/alpine
http://dl-4.alpinelinux.org/alpine
http://dl-5.alpinelinux.org/alpine
http://uk.alpinelinux.org/alpine
http://mirror.leaseweb.com/alpine
http://mirror.aarnet.edu.au/alpine
EOF
    
    echo "✅ Mirror list created"
}

# Function to test mirrors
test_mirrors() {
    echo "🧪 Testing Alpine mirrors..."
    
    while IFS= read -r mirror; do
        if curl -s --connect-timeout 2 "$mirror/v$ALPINE_VERSION/main/x86_64/APKINDEX.tar.gz" > /dev/null; then
            echo "✅ $mirror - Available"
        else
            echo "❌ $mirror - Unavailable"
        fi
    done < alpine-mirrors.txt
}

# Function to create resilient Dockerfile
create_resilient_dockerfile() {
    echo "📝 Creating resilient Dockerfile with mirror fallbacks..."
    
    cat > Dockerfile.resilient << 'EOF'
FROM alpine:3.16

# Try multiple mirrors with fallbacks
RUN for mirror in \
        http://dl-cdn.alpinelinux.org/alpine \
        http://dl-2.alpinelinux.org/alpine \
        http://dl-4.alpinelinux.org/alpine \
        http://uk.alpinelinux.org/alpine; do \
    echo "Trying mirror: $mirror" && \
    if apk add --no-cache \
        --repository $mirror/v3.16/main \
        --repository $mirror/v3.16/community \
        nodejs npm python3 make g++ git; then \
        echo "Success with mirror: $mirror" && \
        break; \
    else \
        echo "Failed with mirror: $mirror, trying next..."; \
    fi; \
done

WORKDIR /app
# Rest of your Dockerfile...
EOF
    
    echo "✅ Resilient Dockerfile created"
}

# Main menu
show_menu() {
    echo ""
    echo "Select an option:"
    echo "1) Initialize cache directory"
    echo "2) Cache specific packages"
    echo "3) Cache Node.js build dependencies"
    echo "4) Create cached Dockerfile"
    echo "5) Build with cache"
    echo "6) Setup mirror fallbacks"
    echo "7) Test mirrors"
    echo "8) Create resilient Dockerfile"
    echo "9) Full setup (all of the above)"
    echo "0) Exit"
    echo ""
    read -p "Enter choice: " choice
    
    case $choice in
        1) init_cache ;;
        2) 
            read -p "Enter packages to cache (space-separated): " packages
            cache_packages $packages
            ;;
        3) cache_packages "nodejs npm python3 make g++ git ca-certificates" ;;
        4) create_cached_dockerfile ;;
        5) build_with_cache ;;
        6) setup_mirrors ;;
        7) test_mirrors ;;
        8) create_resilient_dockerfile ;;
        9) 
            init_cache
            cache_packages "nodejs npm python3 make g++ git ca-certificates"
            create_cached_dockerfile
            setup_mirrors
            create_resilient_dockerfile
            echo "🎉 Full setup complete!"
            ;;
        0) exit 0 ;;
        *) echo "Invalid option" ;;
    esac
}

# Check if running with arguments
if [ $# -eq 0 ]; then
    show_menu
else
    case "$1" in
        init) init_cache ;;
        cache) shift; cache_packages "$@" ;;
        build) shift; build_with_cache "$@" ;;
        mirrors) test_mirrors ;;
        resilient) create_resilient_dockerfile ;;
        --help|-h)
            echo "Usage: $0 [command] [options]"
            echo ""
            echo "Commands:"
            echo "  init                Initialize cache directory"
            echo "  cache <packages>    Cache specific packages"
            echo "  build [dockerfile]  Build with cache"
            echo "  mirrors            Test available mirrors"
            echo "  resilient          Create resilient Dockerfile"
            echo ""
            ;;
        *) echo "Unknown command: $1" ;;
    esac
fi