#!/bin/bash

set -e

echo "Starting kafka-gitops infrastructure destruction..."

# AWS credentials should be set in environment or via AWS CLI configure

# Destroy simple infrastructure
if [ -d "terraform" ]; then
    echo "Destroying infrastructure..."
    cd terraform
    
    # Check if terraform state exists
    if [ -f "terraform.tfstate" ]; then
        echo "Destroying EC2 instance and security group..."
        terraform destroy -auto-approve
        
        # Clean up Terraform state and files
        echo "Cleaning up Terraform state..."
        rm -f terraform.tfstate*
        rm -f .terraform.lock.hcl
        rm -rf .terraform/
        
        # Clean up SSH keys
        echo "Cleaning up SSH keys..."
        rm -f kafka-gitops-key kafka-gitops-key.pub
        
        echo "Infrastructure destroyed successfully!"
    else
        echo "No Terraform state found, skipping infrastructure cleanup"
    fi
    
    cd ..
else
    echo "No terraform directory found, skipping infrastructure cleanup"
fi

# Clean up local build artifacts
echo "Cleaning up build artifacts..."
./gradlew clean
rm -rf build/

# Clean up generated plans and state files
echo "Cleaning up generated files..."
rm -f *.json
rm -f command-config.properties

echo "kafka-gitops destruction completed successfully!"
echo ""
echo "Destroyed resources:"
echo "- EC2 Kafka server"
echo "- Security group"
echo "- SSH key pair"
echo "- Local build artifacts and temporary files"
echo ""
echo "All infrastructure and local artifacts have been removed."