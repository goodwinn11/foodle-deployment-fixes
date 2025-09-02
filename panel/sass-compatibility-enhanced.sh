#!/bin/bash
# Enhanced SASS Compatibility Wrapper Script
# Handles multiple SASS compilation scenarios and fallbacks

set -e

echo "🔧 Enhanced SASS Compatibility Setup"
echo "===================================="

# Function to create node-sass compatibility wrapper
create_node_sass_wrapper() {
    echo "📦 Creating node-sass compatibility wrapper for Dart Sass..."
    
    # Remove existing node-sass if present
    rm -rf node_modules/node-sass
    
    # Create wrapper directory
    mkdir -p node_modules/node-sass
    
    # Create the compatibility wrapper
    cat > node_modules/node-sass/lib.js << 'EOF'
// Node-sass compatibility wrapper for Dart Sass
const sass = require("sass");

// Ensure compatibility with sass-loader expectations
module.exports = {
    render: function(options, callback) {
        try {
            const result = sass.renderSync(options);
            callback(null, result);
        } catch (error) {
            callback(error);
        }
    },
    renderSync: function(options) {
        return sass.renderSync(options);
    },
    info: "node-sass 4.14.1 (Wrapper for Dart Sass)",
    types: sass.types || {},
    // Additional compatibility methods
    TRUE: sass.TRUE,
    FALSE: sass.FALSE,
    NULL: sass.NULL
};
EOF

    # Create package.json for the wrapper
    cat > node_modules/node-sass/package.json << 'EOF'
{
    "name": "node-sass",
    "version": "4.14.1",
    "main": "lib.js",
    "description": "Dart Sass compatibility wrapper for legacy webpack configurations"
}
EOF

    echo "✅ Node-sass wrapper created successfully"
}

# Function to test SASS compilation
test_sass_compilation() {
    echo "🧪 Testing SASS compilation..."
    
    # Create a test SASS file
    cat > test.scss << 'EOF'
$primary-color: #e74c3c;
$secondary-color: #3498db;

.test {
    color: $primary-color;
    background: $secondary-color;
    
    &:hover {
        opacity: 0.8;
    }
    
    @media (max-width: 768px) {
        display: none;
    }
}
EOF

    # Test with Node.js
    node -e "
        try {
            const sass = require('node-sass');
            const result = sass.renderSync({
                data: require('fs').readFileSync('test.scss', 'utf8')
            });
            console.log('✅ SASS compilation test passed');
            console.log('Generated CSS length:', result.css.length, 'bytes');
        } catch (error) {
            console.error('❌ SASS compilation test failed:', error.message);
            process.exit(1);
        }
    "
    
    # Clean up test file
    rm -f test.scss
}

# Function to fix package.json
fix_package_json() {
    echo "📝 Fixing package.json dependencies..."
    
    if [ ! -f package.json ]; then
        echo "⚠️ No package.json found, skipping..."
        return
    fi
    
    # Backup original
    cp package.json package.json.backup.$(date +%Y%m%d-%H%M%S)
    
    # Use Node.js to modify package.json
    node -e "
        const fs = require('fs');
        const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
        
        // Remove node-sass if present
        if (pkg.dependencies && pkg.dependencies['node-sass']) {
            delete pkg.dependencies['node-sass'];
        }
        if (pkg.devDependencies && pkg.devDependencies['node-sass']) {
            delete pkg.devDependencies['node-sass'];
        }
        
        // Ensure sass is present
        if (!pkg.devDependencies) pkg.devDependencies = {};
        pkg.devDependencies['sass'] = '^1.32.13';
        pkg.devDependencies['sass-loader'] = '^6.0.7';
        
        fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2));
        console.log('✅ package.json updated');
    "
}

# Function to install dependencies with multiple fallbacks
install_dependencies() {
    echo "📦 Installing dependencies..."
    
    # Try npm ci first (faster, uses lock file)
    if [ -f package-lock.json ]; then
        echo "Using npm ci for faster installation..."
        if npm ci --no-audit --no-fund --legacy-peer-deps; then
            echo "✅ Dependencies installed with npm ci"
            return 0
        fi
    fi
    
    # Fallback to npm install
    echo "Using npm install..."
    if npm install --no-audit --no-fund --legacy-peer-deps; then
        echo "✅ Dependencies installed with npm install"
        return 0
    fi
    
    # Final fallback with force
    echo "⚠️ Standard install failed, trying with --force..."
    npm install --force --no-audit --no-fund --legacy-peer-deps
}

# Main execution
main() {
    # Check if we're in the right directory
    if [ ! -f package.json ] && [ -f ../package.json ]; then
        echo "📁 Moving to parent directory..."
        cd ..
    fi
    
    # Fix package.json
    fix_package_json
    
    # Install dependencies
    install_dependencies
    
    # Install specific SASS packages
    echo "📦 Installing SASS packages..."
    npm install sass@1.32.13 sass-loader@6.0.7 sass-resources-loader@1.3.5 --save-dev --legacy-peer-deps --force
    
    # Create compatibility wrapper
    create_node_sass_wrapper
    
    # Test the setup
    test_sass_compilation
    
    echo ""
    echo "🎉 SASS compatibility setup complete!"
    echo "You can now run: npm run build"
}

# Run main function
main "$@"