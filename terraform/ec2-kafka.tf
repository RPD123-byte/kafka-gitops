terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Get the default VPC
data "aws_vpc" "default" {
  default = true
}

# Get default subnets
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security Group for Kafka
resource "aws_security_group" "kafka_sg" {
  name        = "kafka-gitops-simple-sg"
  description = "Security group for simple Kafka setup"
  vpc_id      = data.aws_vpc.default.id

  # Kafka brokers
  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP for monitoring
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "kafka-gitops-simple-sg"
  }
}

# Create key pair from generated key
resource "aws_key_pair" "kafka_key" {
  key_name   = "kafka-gitops-key-${random_id.key_suffix.hex}"
  public_key = file("${path.module}/kafka-gitops-key.pub")
}

# Random suffix for unique key names
resource "random_id" "key_suffix" {
  byte_length = 4
}

# EC2 Instance for Kafka
resource "aws_instance" "kafka_server" {
  ami           = "ami-0c02fb55956c7d316" # Amazon Linux 2
  instance_type = "t3.medium"
  
  subnet_id              = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids = [aws_security_group.kafka_sg.id]
  
  # Use the generated key pair
  key_name = aws_key_pair.kafka_key.key_name
  
  associate_public_ip_address = true

  user_data = <<-EOF
  #!/bin/bash
  LOG_FILE="/var/log/user-data.log"
  echo "Starting user data script at $(date)" >> $LOG_FILE 2>&1

  # Install packages
  echo "Installing packages..." >> $LOG_FILE 2>&1
  yum update -y >> $LOG_FILE 2>&1
  yum install -y docker java-1.8.0-openjdk wget nc >> $LOG_FILE 2>&1

  # Start Docker
  echo "Starting Docker..." >> $LOG_FILE 2>&1
  service docker start >> $LOG_FILE 2>&1
  systemctl enable docker >> $LOG_FILE 2>&1
  usermod -a -G docker ec2-user >> $LOG_FILE 2>&1

  # Get public IP
  PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
  echo "Public IP: $PUBLIC_IP" >> $LOG_FILE 2>&1

  # Start Zookeeper with specific version
  echo "Starting Zookeeper..." >> $LOG_FILE 2>&1
  docker run -d --name zookeeper \
    --restart unless-stopped \
    -p 2181:2181 \
    -e ZOOKEEPER_CLIENT_PORT=2181 \
    -e ZOOKEEPER_TICK_TIME=2000 \
    confluentinc/cp-zookeeper:7.5.0 >> $LOG_FILE 2>&1

  # Wait for Zookeeper to be ready
  echo "Waiting for Zookeeper..." >> $LOG_FILE 2>&1
  sleep 30

  # Start Kafka with specific version
  echo "Starting Kafka..." >> $LOG_FILE 2>&1
  docker run -d --name kafka \
    --restart unless-stopped \
    -p 9092:9092 \
    -e KAFKA_BROKER_ID=1 \
    -e KAFKA_ZOOKEEPER_CONNECT=172.17.0.1:2181 \
    -e KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092 \
    -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://$PUBLIC_IP:9092 \
    -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=PLAINTEXT:PLAINTEXT \
    -e KAFKA_INTER_BROKER_LISTENER_NAME=PLAINTEXT \
    -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
    -e KAFKA_AUTO_CREATE_TOPICS_ENABLE=true \
    confluentinc/cp-kafka:7.5.0 >> $LOG_FILE 2>&1

  # Wait for Kafka to be ready
  echo "Waiting for Kafka..." >> $LOG_FILE 2>&1
  sleep 30

  # Create status script (using nc without -q flag for Amazon Linux 2 compatibility)
  echo "Creating status script..." >> $LOG_FILE 2>&1
  cat > /home/ec2-user/status.sh << 'STATUS_EOF'
  #!/bin/bash
  while true; do
      PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
      {
          echo -e "HTTP/1.1 200 OK\r"
          echo -e "Content-Type: text/plain\r"
          echo -e "Connection: close\r"
          echo -e "\r"
          echo "Kafka running at $PUBLIC_IP:9092"
      } | nc -l 8080
  done
  STATUS_EOF

  chmod +x /home/ec2-user/status.sh
  chown ec2-user:ec2-user /home/ec2-user/status.sh

  # Start status endpoint
  echo "Starting status endpoint..." >> $LOG_FILE 2>&1
  nohup /home/ec2-user/status.sh > /home/ec2-user/status.log 2>&1 &

  # Optional: Create test topic
  sleep 10
  docker exec kafka kafka-topics --create \
    --topic test-topic \
    --bootstrap-server localhost:9092 \
    --partitions 3 \
    --replication-factor 1 >> $LOG_FILE 2>&1 || echo "Topic creation failed or already exists" >> $LOG_FILE 2>&1

  echo "Kafka setup completed at $(date)" >> $LOG_FILE 2>&1
  EOF

  tags = {
    Name = "kafka-gitops-simple-server"
  }
}

# Outputs
output "kafka_server_ip" {
  description = "Public IP of the Kafka server"
  value       = aws_instance.kafka_server.public_ip
}

output "kafka_bootstrap_servers" {
  description = "Bootstrap servers for Kafka connection"
  value       = "${aws_instance.kafka_server.public_ip}:9092"
}

output "status_url" {
  description = "URL to check server status"
  value       = "http://${aws_instance.kafka_server.public_ip}:8080"
}

output "ssh_command" {
  description = "SSH command to connect to the server"
  value       = "ssh -i terraform/kafka-gitops-key ec2-user@${aws_instance.kafka_server.public_ip}"
}