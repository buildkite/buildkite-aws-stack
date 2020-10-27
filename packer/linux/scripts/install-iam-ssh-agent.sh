#!/bin/bash
set -eu -o pipefail

IAM_SSH_AGENT_VERSION="0.3.1"

echo "Installing iam-ssh-agent ${IAM_SSH_AGENT_VERSION}..."

sudo curl --location --fail --output /tmp/iam-ssh-agent.rpm \
	"https://github.com/keithduncan/iam-ssh-agent/releases/download/v${IAM_SSH_AGENT_VERSION}/iam-ssh-agent_${IAM_SSH_AGENT_VERSION}_amd64.rpm"
sudo yum install --assumeyes /tmp/iam-ssh-agent.rpm
sudo rm /tmp/iam-ssh-agent.rpm

sudo cp /tmp/conf/iam-ssh-agent/systemd/ssh-agent.service  /etc/systemd/system/ssh-agent.service