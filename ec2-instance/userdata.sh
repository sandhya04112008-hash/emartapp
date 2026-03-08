#!/bin/bash
set -e

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker ubuntu
systemctl enable docker
systemctl start docker

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl



#Instal aws cli
sudo install unzip 
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
sudo unzip awscliv2.zip
sudo ./aws/install -i /usr/local/aws-cli -b /usr/local/bin

#Install eksctl
  
curl -L -o eksctl https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64
chmod +x eksctl
mv eksctl /usr/local/bin/eksctl



# Download latest release
curl -L https://get.helm.sh/helm-v3.14.0-linux-amd64.tar.gz -o helm.tar.gz

# Extract
tar -zxvf helm.tar.gz

# Move to PATH
sudo mv linux-amd64/helm /usr/local/bin/

# Verify
helm version


