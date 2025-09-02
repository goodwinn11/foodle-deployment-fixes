#!/bin/bash
# Script to create secure secrets for Foodle deployment

set -e

SECRETS_DIR="./secrets"

echo "🔐 Creating secure secrets for Foodle deployment"
echo "================================================"

# Create secrets directory
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# Function to generate secure password
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# Generate secrets
echo "Generating database password..."
generate_password > "$SECRETS_DIR/db_password.txt"

echo "Generating database root password..."
generate_password > "$SECRETS_DIR/db_root_password.txt"

echo "Generating JWT secret..."
openssl rand -hex 32 > "$SECRETS_DIR/jwt_secret.txt"

echo "Generating RabbitMQ password..."
generate_password > "$SECRETS_DIR/rabbitmq_password.txt"

echo "Generating Redis password..."
generate_password > "$SECRETS_DIR/redis_password.txt"

# Set secure permissions
chmod 600 "$SECRETS_DIR"/*.txt

# Display summary (without showing actual secrets)
echo ""
echo "✅ Secrets created successfully in $SECRETS_DIR/"
echo ""
echo "Files created:"
ls -la "$SECRETS_DIR"/*.txt
echo ""
echo "⚠️  IMPORTANT: Keep these secrets secure!"
echo "   - Never commit them to version control"
echo "   - Add $SECRETS_DIR/ to .gitignore"
echo "   - Backup securely if needed"
echo ""
echo "To use with docker-compose-secure.yml:"
echo "  docker-compose -f docker-compose-secure.yml up -d"