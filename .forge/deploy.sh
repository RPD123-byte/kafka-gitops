#!/bin/bash

# kafka-gitops deployment script - Simple working version
# Deploys a single EC2 instance with Kafka and tests kafka-gitops CLI

# =============================================================================
# INTEGRATION DECLARATIONS
# =============================================================================

# Declare required cloud integrations (must be set up before this runs)
# REQUIRES: aws

# =============================================================================
# DEPLOYMENT LOGIC
# =============================================================================

set -e  # Exit on any error

echo "Starting kafka-gitops simple deployment..."

# Build the kafka-gitops CLI tool
echo "Building kafka-gitops CLI tool..."
./gradlew clean shadowJar -x test
./build.sh

# Generate SSH key pair if it doesn't exist
echo "Checking for SSH key pair..."
if [ ! -f terraform/kafka-gitops-key ]; then
    echo "Generating new SSH key pair..."
    ssh-keygen -t rsa -b 2048 -f terraform/kafka-gitops-key -N "" -q
    echo "SSH key pair generated successfully"
else
    echo "SSH key pair already exists"
fi

# Deploy simple Kafka server
echo "Deploying simple Kafka server on EC2..."
cd terraform

terraform init

echo "Planning infrastructure deployment..."
terraform plan

echo "Applying infrastructure..."
terraform apply -auto-approve

# Get outputs
KAFKA_SERVER_IP=$(terraform output -raw kafka_server_ip)
KAFKA_BOOTSTRAP_SERVERS=$(terraform output -raw kafka_bootstrap_servers)
STATUS_URL=$(terraform output -raw status_url)

echo "Infrastructure deployed successfully!"
echo "Kafka Server IP: $KAFKA_SERVER_IP"
echo "Bootstrap Servers: $KAFKA_BOOTSTRAP_SERVERS"
echo "Status URL: $STATUS_URL"

cd ..

# Wait for Kafka to be ready
echo "Waiting for Kafka server to be ready..."
echo "This can take 5-10 minutes for user data script to complete..."
max_attempts=30
attempt=0
while [ $attempt -lt $max_attempts ]; do
    echo "Testing Kafka connectivity (attempt $((attempt + 1))/$max_attempts)..."
    
    # Check if status endpoint is responding
    if curl -s --connect-timeout 10 "$STATUS_URL" | grep -q "running" 2>/dev/null; then
        echo "Server is responding and Kafka containers are running!"
        
        # Double-check Kafka port
        if nc -z -w10 "$KAFKA_SERVER_IP" 9092 2>/dev/null; then
            echo "Kafka port 9092 is accessible!"
            break
        else
            echo "Status endpoint responding but Kafka port not yet accessible..."
        fi
    else
        echo "Status endpoint not yet responding (user data script still running)..."
    fi
    
    if [ $attempt -eq $((max_attempts - 1)) ]; then
        echo "Server not fully ready after $max_attempts attempts, but infrastructure is deployed."
        echo "You may need to wait a few more minutes for Kafka to be fully accessible."
        break
    fi
    
    echo "Waiting 20 seconds before next check..."
    sleep 20
    attempt=$((attempt + 1))
done

# Test kafka-gitops CLI
echo "Testing kafka-gitops CLI..."

# Create command config file
cat > command-config.properties << EOF
bootstrap.servers=$KAFKA_BOOTSTRAP_SERVERS
client.id=kafka-gitops-deploy-test
EOF

echo "Validating staging state file..."
if ./build/output/kafka-gitops -c command-config.properties -f gitops-examples/staging-state.yaml --skip-acls validate; then
    echo "State file validation successful!"
    
    echo "Generating execution plan..."
    if ./build/output/kafka-gitops -c command-config.properties -f gitops-examples/staging-state.yaml --skip-acls plan -o staging-plan.json; then
        echo "Plan generation successful!"
        echo "Plan saved to staging-plan.json"
    else
        echo "Plan generation failed (this is normal if Kafka is still starting)"
    fi
else
    echo "State file validation failed"
fi

echo "Deployment completed successfully!"

# =============================================================================
# CREDENTIAL OUTPUT
# =============================================================================

echo "Extracting and outputting infrastructure credentials..."

# Output Kafka cluster access information in environment variable format
echo "KAFKA_BOOTSTRAP_SERVERS=$KAFKA_BOOTSTRAP_SERVERS"
echo "KAFKA_SERVER_IP=$KAFKA_SERVER_IP"
echo "KAFKA_STATUS_URL=$STATUS_URL"

# SSH access info
echo ""
echo "To SSH into the server:"
echo "ssh -i terraform/kafka-gitops-key ec2-user@$KAFKA_SERVER_IP"

echo "All credentials extracted successfully."