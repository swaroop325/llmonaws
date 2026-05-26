#!/bin/bash
set -euo pipefail

# Setup script for vLLM AWS deployment
# Usage: ./setup.sh [--region us-east-1] [--instance-type g5.12xlarge]

REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="g5.12xlarge"
DESIRED_CAPACITY=2

while [[ $# -gt 0 ]]; do
    case $1 in
        --region) REGION="$2"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --replicas) DESIRED_CAPACITY="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "=== vLLM AWS Deployment Setup ==="
echo "Region: $REGION"
echo "Instance type: $INSTANCE_TYPE"
echo "Desired replicas: $DESIRED_CAPACITY"
echo ""

# Check prerequisites
check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: $1 is required but not installed."
        exit 1
    fi
}

check_cmd aws
check_cmd terraform
check_cmd jq

# Verify AWS credentials
echo "Checking AWS credentials..."
if ! aws sts get-caller-identity &>/dev/null; then
    echo "ERROR: AWS credentials not configured. Run 'aws configure' first."
    exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account: $ACCOUNT_ID"

# Find the Deep Learning AMI
echo ""
echo "Looking up Deep Learning AMI in $REGION..."
AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners amazon \
    --filters \
        "Name=name,Values=Deep Learning AMI (Ubuntu 22.04)*" \
        "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text 2>/dev/null || echo "")

if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    echo "WARNING: Could not find Deep Learning AMI. Using generic Ubuntu 22.04."
    AMI_ID=$(aws ec2 describe-images \
        --region "$REGION" \
        --owners 099720109477 \
        --filters \
            "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text)
fi
echo "AMI: $AMI_ID"

# Check/create key pair
KEY_NAME="vllm-deploy-${REGION}"
echo ""
echo "Checking EC2 key pair..."
if ! aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" &>/dev/null; then
    echo "Creating key pair: $KEY_NAME"
    aws ec2 create-key-pair \
        --region "$REGION" \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text > "${KEY_NAME}.pem"
    chmod 600 "${KEY_NAME}.pem"
    echo "Key saved to ${KEY_NAME}.pem"
else
    echo "Key pair '$KEY_NAME' already exists."
fi

# Check GPU instance quota
echo ""
echo "Checking GPU instance quota..."
VCPU_NEEDED=48  # g5.12xlarge = 48 vCPUs
QUOTA=$(aws service-quotas get-service-quota \
    --region "$REGION" \
    --service-code ec2 \
    --quota-code L-DB2E81BA \
    --query 'Quota.Value' \
    --output text 2>/dev/null || echo "0")
TOTAL_NEEDED=$((VCPU_NEEDED * DESIRED_CAPACITY))
echo "G/VT instance vCPU quota: $QUOTA (need: $TOTAL_NEEDED)"
if (( $(echo "$QUOTA < $TOTAL_NEEDED" | bc -l) )); then
    echo "WARNING: Your quota ($QUOTA vCPUs) may be insufficient for $DESIRED_CAPACITY x $INSTANCE_TYPE ($TOTAL_NEEDED vCPUs)."
    echo "Request a quota increase at: https://console.aws.amazon.com/servicequotas/"
fi

# Check HuggingFace token
echo ""
if [[ ! -f .env ]]; then
    echo "No .env file found."
    read -rp "Enter your HuggingFace token (or press Enter to skip): " HF_TOKEN
    if [[ -n "$HF_TOKEN" ]]; then
        echo "HF_TOKEN=$HF_TOKEN" > .env
        echo "Saved to .env"
    else
        echo "WARNING: No HF_TOKEN set. Model download may fail for gated models."
        cp env.example .env
    fi
else
    echo ".env file exists."
fi

# Generate terraform.tfvars
echo ""
echo "Generating terraform/terraform.tfvars..."
cat > terraform/terraform.tfvars <<EOF
aws_region       = "$REGION"
instance_type    = "$INSTANCE_TYPE"
ami_id           = "$AMI_ID"
key_name         = "$KEY_NAME"
desired_capacity = $DESIRED_CAPACITY
min_instances    = 2
max_instances    = 8

allowed_cidr_blocks = ["0.0.0.0/0"]
ssh_cidr_blocks     = ["0.0.0.0/0"]
EOF

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Review terraform/terraform.tfvars (restrict CIDR blocks for production)"
echo "  2. cd terraform && terraform init && terraform plan"
echo "  3. terraform apply"
echo "  4. SSH into instances and verify: ssh -i ${KEY_NAME}.pem ubuntu@<ip>"
echo ""
echo "Estimated cost: ~\$$(echo "$DESIRED_CAPACITY * 5.67 * 24 * 30" | bc | cut -d. -f1)/month ($DESIRED_CAPACITY x $INSTANCE_TYPE, on-demand)"
