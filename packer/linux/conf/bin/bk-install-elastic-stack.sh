#!/bin/bash
set -euxo pipefail

## Installs the Buildkite Agent, run from the CloudFormation template

# Write to system console and to our log file
# See https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee -a /var/log/elastic-stack.log|logger -t user-data -s 2>/dev/console) 2>&1

on_error() {
	local exitCode="$?"
	local errorLine="$1"

	if [[ $exitCode != 0 ]] ; then
	  TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
		aws autoscaling set-instance-health \
			--instance-id "$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)" \
			--health-status Unhealthy || true
	fi

	/opt/aws/bin/cfn-signal \
		--region "$AWS_REGION" \
		--stack "$BUILDKITE_STACK_NAME" \
		--reason "Error on line $errorLine: $(tail -n 1 /var/log/elastic-stack.log)" \
		--resource "AgentAutoScaleGroup" \
		--exit-code "$exitCode"
}

trap 'on_error $LINENO' ERR

INSTANCE_ID=$(/opt/aws/bin/ec2-metadata --instance-id | cut -d " " -f 2)
DOCKER_VERSION=$(docker --version | cut -f3 -d' ' | sed 's/,//')

PLUGINS_ENABLED=()
[[ $SECRETS_PLUGIN_ENABLED == "true" ]] && PLUGINS_ENABLED+=("secrets")
[[ $ECR_PLUGIN_ENABLED == "true" ]] && PLUGINS_ENABLED+=("ecr")
[[ $DOCKER_LOGIN_PLUGIN_ENABLED == "true" ]] && PLUGINS_ENABLED+=("docker-login")

# cfn-env is sourced by the environment hook in builds
cat << EOF > /var/lib/buildkite-agent/cfn-env
export DOCKER_VERSION=$DOCKER_VERSION
export BUILDKITE_STACK_NAME=$BUILDKITE_STACK_NAME
export BUILDKITE_STACK_VERSION=$BUILDKITE_STACK_VERSION
export BUILDKITE_AGENTS_PER_INSTANCE=$BUILDKITE_AGENTS_PER_INSTANCE
export BUILDKITE_SECRETS_BUCKET=$BUILDKITE_SECRETS_BUCKET
export AWS_DEFAULT_REGION=$AWS_REGION
export AWS_REGION=$AWS_REGION
export PLUGINS_ENABLED="${PLUGINS_ENABLED[*]-}"
export BUILDKITE_ECR_POLICY=${BUILDKITE_ECR_POLICY:-none}
EOF

if [[ "${BUILDKITE_AGENT_RELEASE}" == "edge" ]] ; then
	if [[ "$(uname -m)" == "aarch64" ]] ; then
	  AGENT_ARCH="arm64"
	else
	  AGENT_ARCH="amd64"
	fi
	echo "Downloading buildkite-agent edge..."
	curl -Lsf -o /usr/bin/buildkite-agent-edge \
		"https://download.buildkite.com/agent/experimental/latest/buildkite-agent-linux-${AGENT_ARCH}"
	chmod +x /usr/bin/buildkite-agent-edge
	buildkite-agent-edge --version
fi

if [[ "${BUILDKITE_ADDITIONAL_SUDO_PERMISSIONS}" != "" ]] ; then
  echo "buildkite-agent ALL=NOPASSWD: ${BUILDKITE_ADDITIONAL_SUDO_PERMISSIONS}" > /etc/sudoers.d/buildkite-agent-additional
  chmod 440 /etc/sudoers.d/buildkite-agent-additional
fi

# Choose the right agent binary
ln -s "/usr/bin/buildkite-agent-${BUILDKITE_AGENT_RELEASE}" /usr/bin/buildkite-agent

agent_metadata=(
	"queue=${BUILDKITE_QUEUE}"
	"docker=${DOCKER_VERSION}"
	"stack=${BUILDKITE_STACK_NAME}"
	"buildkite-aws-stack=${BUILDKITE_STACK_VERSION}"
)

# Split on commas
if [[ -n "${BUILDKITE_AGENT_TAGS:-}" ]] ; then
	IFS=',' read -r -a extra_agent_metadata <<< "${BUILDKITE_AGENT_TAGS:-}"
	agent_metadata=("${agent_metadata[@]}" "${extra_agent_metadata[@]}")
fi

# Enable git-mirrors
if [[ "${BUILDKITE_AGENT_ENABLE_GIT_MIRRORS_EXPERIMENT}" == "true" ]] ; then
  if [[ -z "$BUILDKITE_AGENT_EXPERIMENTS" ]] ; then
    BUILDKITE_AGENT_EXPERIMENTS="git-mirrors"
  else
    BUILDKITE_AGENT_EXPERIMENTS+=",git-mirrors"
  fi
  BUILDKITE_AGENT_GIT_MIRRORS_PATH="/var/lib/buildkite-agent/git-mirrors"
else
  BUILDKITE_AGENT_GIT_MIRRORS_PATH=""
fi

BUILDKITE_AGENT_TOKEN="$(aws ssm get-parameter --name "${BUILDKITE_AGENT_TOKEN_PATH}" --with-decryption --query Parameter.Value --output text)"

cat << EOF > /etc/buildkite-agent/buildkite-agent.cfg
name="${BUILDKITE_STACK_NAME}-${INSTANCE_ID}-%spawn"
token="${BUILDKITE_AGENT_TOKEN}"
tags=$(IFS=, ; echo "${agent_metadata[*]}")
tags-from-ec2-meta-data=true
timestamp-lines=${BUILDKITE_AGENT_TIMESTAMP_LINES}
hooks-path=/etc/buildkite-agent/hooks
build-path=/var/lib/buildkite-agent/builds
plugins-path=/var/lib/buildkite-agent/plugins
git-mirrors-path="${BUILDKITE_AGENT_GIT_MIRRORS_PATH}"
experiment="${BUILDKITE_AGENT_EXPERIMENTS}"
priority=%n
spawn=${BUILDKITE_AGENTS_PER_INSTANCE}
no-color=true
disconnect-after-idle-timeout=${BUILDKITE_SCALE_IN_IDLE_PERIOD}
disconnect-after-job=${BUILDKITE_TERMINATE_INSTANCE_AFTER_JOB}
EOF

chown buildkite-agent: /etc/buildkite-agent/buildkite-agent.cfg

if [[ -n "${BUILDKITE_AUTHORIZED_USERS_URL}" ]] ; then
	cat <<- EOF > /etc/cron.hourly/authorized_keys
	/usr/local/bin/bk-fetch.sh "${BUILDKITE_AUTHORIZED_USERS_URL}" /tmp/authorized_keys
	mv /tmp/authorized_keys /home/ec2-user/.ssh/authorized_keys
	chmod 600 /home/ec2-user/.ssh/authorized_keys
	chown ec2-user: /home/ec2-user/.ssh/authorized_keys
	EOF

	chmod +x /etc/cron.hourly/authorized_keys
	/etc/cron.hourly/authorized_keys
fi

if [[ -n "${BUILDKITE_ELASTIC_BOOTSTRAP_SCRIPT}" ]] ; then
	/usr/local/bin/bk-fetch.sh "${BUILDKITE_ELASTIC_BOOTSTRAP_SCRIPT}" /tmp/elastic_bootstrap
	bash < /tmp/elastic_bootstrap
	rm /tmp/elastic_bootstrap
fi

cat << EOF > /etc/lifecycled
AWS_REGION=${AWS_REGION}
LIFECYCLED_HANDLER=/usr/local/bin/stop-agent-gracefully
LIFECYCLED_CLOUDWATCH_GROUP=/buildkite/lifecycled
EOF

systemctl enable lifecycled.service
systemctl start lifecycled

# wait for docker to start
next_wait_time=0
until docker ps || [ $next_wait_time -eq 5 ]; do
	sleep $(( next_wait_time++ ))
done

if ! docker ps ; then
  echo "Failed to contact docker"
  exit 1
fi

systemctl enable "buildkite-agent"
systemctl start "buildkite-agent"

# let the stack know that this host has been initialized successfully
/opt/aws/bin/cfn-signal \
	--region "$AWS_REGION" \
	--stack "$BUILDKITE_STACK_NAME" \
	--resource "AgentAutoScaleGroup" \
	--exit-code 0 || (
		# This will fail if the stack has already completed, for instance if there is a min size
		# of 1 and this is the 2nd instance. This is ok, so we just ignore the erro
		echo "Signal failed"
	)
