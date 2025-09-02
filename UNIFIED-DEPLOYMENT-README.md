# Foodle Unified Deployment System

## Overview

The `deploy-foodle-unified.sh` script is a comprehensive, intelligent deployment system that combines all deployment functionality into a single, powerful tool. It automatically adapts to system resources, applies all necessary fixes, and provides complete deployment management.

## Key Features

### 🧠 Intelligent Mode Detection
- Automatically detects if it's a fresh install or existing deployment
- Adapts strategy based on available system resources
- Chooses between parallel or sequential container building

### 💾 Adaptive Resource Management
- Detects available memory and adjusts deployment strategy
- **< 400MB**: Fails with clear error
- **400-800MB**: Ultra-low memory mode with aggressive optimization
- **800-1000MB**: Low memory mode with sequential building
- **> 1000MB**: Normal mode with parallel building
- Automatic memory optimization and Docker cleanup

### 🔧 All Fixes Integrated
- Panel Dockerfile version constraints fixed automatically
- Comprehensive config.php with all environment mappings
- Supervisor daemon path corrections
- Database import and schema fixes
- AMQP/RabbitMQ constants properly defined
- All known deployment issues addressed

### 📊 State Management & Recovery
- Tracks deployment progress in state file
- Can resume from interruption points
- Rollback capabilities for failed steps
- Atomic operations with proper error handling

### 📝 Comprehensive Reporting
- Detailed deployment reports with:
  - System information
  - Completed/failed steps
  - Container status
  - Network configuration
  - Access URLs
- Timestamped logs for debugging
- Color-coded console output

## Usage

### Interactive Mode (Default)
```bash
sudo ./deploy-foodle-unified.sh
```
Shows an interactive menu with options:
1. Full Deployment (fresh install)
2. Fix Mode (repair existing)
3. Status Check (validate)
4. Cleanup (remove)
5. Auto Mode (intelligent detection)
6. Exit

### Command Line Options
```bash
# Full deployment
sudo ./deploy-foodle-unified.sh --deploy

# Fix existing deployment
sudo ./deploy-foodle-unified.sh --fix

# Check status
sudo ./deploy-foodle-unified.sh --status

# Cleanup deployment
sudo ./deploy-foodle-unified.sh --cleanup

# Auto mode (detects what's needed)
sudo ./deploy-foodle-unified.sh --auto

# Non-interactive mode
sudo ./deploy-foodle-unified.sh --deploy --non-interactive

# Force mode (skip confirmations)
sudo ./deploy-foodle-unified.sh --deploy --force

# Verbose output
sudo ./deploy-foodle-unified.sh --deploy --verbose
```

## Deployment Strategies

### Sequential Strategy (Low Memory)
Used when available memory < 1GB:
- Builds containers one at a time
- Clears memory before each build
- Uses minimal resources
- Takes longer but more reliable on constrained systems

### Parallel Strategy (Normal)
Used when available memory >= 1GB:
- Builds all containers simultaneously
- Faster deployment
- Requires more resources

## How It Works

### 1. Pre-Deployment Phase
```
✓ Check OS compatibility (Ubuntu recommended)
✓ Verify root/sudo privileges
✓ Analyze available memory and disk space
✓ Check Docker installation and daemon
✓ Verify port availability
✓ Detect existing deployments
```

### 2. Resource Optimization
```
✓ Clear page cache if needed
✓ Prune Docker resources if low memory
✓ Stop unnecessary services
✓ Calculate optimal deployment strategy
```

### 3. Deployment Phase
```
✓ Setup directories and paths
✓ Fix panel Dockerfile versions
✓ Create Docker networks
✓ Build containers (sequential or parallel)
✓ Start containers in dependency order
✓ Configure API with comprehensive config.php
✓ Fix supervisor daemon paths
✓ Import database schema
```

### 4. Post-Deployment Phase
```
✓ Run health checks on all services
✓ Validate API endpoints
✓ Test database connectivity
✓ Generate deployment report
✓ Save state for recovery
```

## Memory Management

The script actively manages memory throughout deployment:

### Optimization Triggers
- Before each container build (sequential mode)
- When available memory < 500MB
- After failed operations

### Optimization Actions
- Clear Linux page cache: `sync && echo 3 > /proc/sys/vm/drop_caches`
- Prune Docker system: `docker system prune -af --volumes`
- Stop unnecessary services: snapd, bluetooth, cups, avahi-daemon
- Clean builder cache: `docker builder prune -f`

## Configuration Generated

The script creates a comprehensive `config.php` with:
- Database settings (with all aliases)
- Cache/Redis configuration
- KeyDB settings
- AMQP/RabbitMQ configuration
- JWT and application settings
- Domain configuration
- Session management

## Error Handling

### Automatic Recovery
- Retries failed operations with cleanup
- Falls back from parallel to sequential on failure
- Provides clear error messages with solutions

### Manual Recovery
- State file allows resuming interrupted deployments
- Can run fix mode on partial deployments
- Cleanup mode for complete removal

## Reports and Logs

### Deployment Report
Location: `deployment-report-YYYYMMDD-HHMMSS.md`
Contains:
- System information
- Deployment steps status
- Container and network status
- Access URLs

### Deployment Log
Location: `/tmp/foodle-deployment-YYYYMMDD-HHMMSS.log`
Contains:
- Timestamped detailed logs
- Debug information (if verbose mode)
- Error traces

### State File
Location: `/tmp/foodle-deployment.state`
Contains:
- Current deployment status
- Completed and failed steps
- Recovery information

## Troubleshooting

### "Insufficient memory" Error
```bash
# Free up memory
docker system prune -a --volumes
sudo systemctl stop snapd
sync && echo 3 > /proc/sys/vm/drop_caches
```

### Container Build Failures
- Script automatically retries with cleanup
- Falls back to sequential mode
- Uses minimal memory builds when < 300MB

### API Not Responding
- Script creates comprehensive config.php
- All AMQP constants included
- Check logs: `docker logs foodle_api`

### Port Conflicts
- Script detects and offers to stop Apache2
- Shows which service uses each port
- Can proceed after manual resolution

## Best Practices

### For Production
1. Ensure at least 1GB RAM available
2. Run status check first: `sudo ./deploy-foodle-unified.sh --status`
3. Use verbose mode for detailed output
4. Keep deployment reports for reference
5. Test on staging environment first

### For Development
1. Use cleanup mode to reset: `sudo ./deploy-foodle-unified.sh --cleanup`
2. Use fix mode for quick repairs
3. Monitor logs during deployment
4. Use auto mode for convenience

### For CI/CD
```bash
# Non-interactive deployment
sudo ./deploy-foodle-unified.sh --deploy --non-interactive --force

# Check deployment status
sudo ./deploy-foodle-unified.sh --status --non-interactive
```

## System Requirements

### Minimum Requirements
- Ubuntu 20.04+ (recommended)
- 400MB RAM (absolute minimum)
- 2GB disk space
- Docker 20.10+
- Docker Compose v2

### Recommended Requirements
- Ubuntu 22.04 LTS
- 1GB+ RAM
- 5GB+ disk space
- Fast network connection

## Advanced Features

### State Management
```bash
# State file location
/tmp/foodle-deployment.state

# Resume interrupted deployment
sudo ./deploy-foodle-unified.sh
# Will prompt: "Resume previous deployment?"
```

### Custom Strategies
The script automatically selects strategy based on resources:
- Ultra-low memory: < 400MB (fails)
- Low memory: 400-1000MB (sequential)
- Normal: > 1000MB (parallel)

### Dry Run Mode
```bash
# Preview actions without executing
sudo ./deploy-foodle-unified.sh --deploy --dry-run
```

## Exit Codes
- 0: Success
- 1: General failure
- 2: Insufficient resources
- 3: Docker not installed
- 130: User interruption (Ctrl+C)

## Version History
- v3.0: Unified system with all features
- v2.0: Added resource optimization
- v1.0: Basic deployment

## Support

For issues or questions:
1. Check the deployment report
2. Review the deployment log
3. Run status check: `sudo ./deploy-foodle-unified.sh --status`
4. Check container logs: `docker logs [container_name]`

## Summary

This unified deployment system represents the culmination of all deployment improvements, providing:
- ✅ One script for all deployment needs
- ✅ Intelligent adaptation to system resources
- ✅ Comprehensive error handling and recovery
- ✅ All known fixes integrated
- ✅ Professional reporting and logging
- ✅ Both interactive and automated modes
- ✅ Production-ready reliability

The script transforms Foodle deployment from a complex, error-prone process into a simple, reliable operation that works on systems with as little as 400MB RAM.