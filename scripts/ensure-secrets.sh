#!/bin/bash
set -e

SECRET_DIR="secrets"
SECRET_FILE="$SECRET_DIR/minio_password.txt"

# Create directory if it doesn't exist
mkdir -p "$SECRET_DIR"

# Check if the password file exists
if [ ! -f "$SECRET_FILE" ]; then
    echo "🔐 Generating new persistent MinIO password..."
    # Generate a 24-char alphanumeric password (no special chars to avoid connection string parsing issues)
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24 > "$SECRET_FILE"
    echo "✅ Password saved to $SECRET_FILE"
else
    echo "✅ Existing MinIO password found in $SECRET_FILE. Reusing."
fi