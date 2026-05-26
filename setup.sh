#!/bin/bash
set -euo pipefail

# Setup script for vLLM AWS deployment
# Deploys Qwen2.5-32B-Instruct-AWQ on g4dn.12xlarge (4x T4, ap-southeast-1)
# Usage: ./setup.sh [--region ap-southeast-1] [--instance-type g4dn.12xlarge]

REGION="${AWS_REGION:-ap-southeast-1}"
INSTANCE_TYPE="g4dn.12xlarge"
DESIRED_CAPACITY=1

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

# Find the Deep Learning AMI (GPU PyTorch, Ubuntu)
echo ""
echo "Looking up Deep Learning AMI in $REGION..."
AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners amazon \
    --filters \
        "Name=name,Values=Deep Learning OSS Nvidia Driver AMI GPU PyTorch*Ubuntu*" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text 2>/dev/null || echo "")

if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    echo "WARNING: Could not find Deep Learning AMI. Trying broader search..."
    AMI_ID=$(aws ec2 describe-images \
        --region "$REGION" \
        --owners amazon \
        --filters \
            "Name=name,Values=*Deep Learning*Ubuntu*" \
            "Name=state,Values=available" \
            "Name=architecture,Values=x86_64" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text)
fi
echo "AMI: $AMI_ID"

# Check/create key pair
KEY_NAME="vllm-deploy-${REGION}"
echo ""
echo "Checking EC2 key pair..."
if ! aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" &>/dev/null 2>&1; then
    echo "Creating key pair: $KEY_NAME"
    aws ec2 create-key-pair \
        --region "$REGION" \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text > "${HOME}/.ssh/${KEY_NAME}.pem"
    chmod 600 "${HOME}/.ssh/${KEY_NAME}.pem"
    echo "Key saved to ~/.ssh/${KEY_NAME}.pem"
else
    echo "Key pair '$KEY_NAME' already exists."
fi

# Check GPU instance quota
echo ""
echo "Checking GPU instance quota..."
VCPU_NEEDED=48  # g4dn.12xlarge = 48 vCPUs
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

# Ensure default VPC has subnets in at least 2 AZs (required for ALB)
echo ""
echo "Checking VPC subnets..."
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text)
SUBNET_COUNT=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'length(Subnets)' --output text)
if [[ "$SUBNET_COUNT" -lt 2 ]]; then
    echo "ALB requires subnets in at least 2 AZs. Creating additional subnets..."
    VPC_CIDR=$(aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text)
    AZS=($(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[*].ZoneName' --output text))
    EXISTING_AZ=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].AvailabilityZone' --output text)
    CIDR_BASE=16
    for AZ in "${AZS[@]}"; do
        if [[ "$AZ" != "$EXISTING_AZ" && "$SUBNET_COUNT" -lt 2 ]]; then
            CIDR="172.31.${CIDR_BASE}.0/20"
            aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" --cidr-block "$CIDR" --availability-zone "$AZ" --output text >/dev/null 2>&1 && {
                echo "  Created subnet in $AZ ($CIDR)"
                SUBNET_COUNT=$((SUBNET_COUNT + 1))
            } || true
            CIDR_BASE=$((CIDR_BASE + 16))
        fi
    done
fi
echo "VPC $VPC_ID has $SUBNET_COUNT subnets."

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
min_instances    = 1
max_instances    = 1

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
echo "  4. Wait ~5 minutes for model to load"
echo "  5. ./healthcheck.sh"
echo "  6. python3 perf-test.py http://<alb-dns>"
echo ""
echo "SSH: ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@<instance-ip>"
echo "Logs: ssh ... 'sudo cat /var/log/vllm-setup.log'"
echo ""
echo "Estimated cost: ~\$$(echo "$DESIRED_CAPACITY * 3.91 * 24" | bc | cut -d. -f1)/day ($DESIRED_CAPACITY x $INSTANCE_TYPE, on-demand)"
