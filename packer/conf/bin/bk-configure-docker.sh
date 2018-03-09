#!/bin/bash
set -euo pipefail

## Configures docker before system starts

# Write to system console and to our log file
# See https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee -a /var/log/elastic-stack.log|logger -t user-data -s 2>/dev/console) 2>&1

DOCKER_RELEASE="${DOCKER_RELEASE:-stable}"
DOCKER_VERSION="${DOCKER_VERSION?must be set}"
DOCKER_COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION?must be set}"

# This performs a manual install of Docker. The init.d script is from the 1.11 yum package
echo "Installing docker ${DOCKER_VERSION} (${DOCKER_RELEASE})..."

# Only dep to install (found by doing a yum install of 1.11)
yum install -y xfsprogs

# Add docker group
groupadd docker
usermod -a -G docker ec2-user

# Manual install ala https://docs.docker.com/engine/installation/binaries/
curl -Lsf https://download.docker.com/linux/static/${DOCKER_RELEASE}/x86_64/docker-${DOCKER_VERSION}.tgz > docker.tgz
tar -xvzf docker.tgz
mv docker/* /usr/bin
rm docker.tgz
rm -rf docker/

cp /tmp/conf/docker/init.d/docker /etc/init.d/docker
cp /tmp/conf/docker/docker.conf /etc/sysconfig/docker.root
cp /tmp/conf/docker/docker.conf /etc/sysconfig/docker
cp /tmp/conf/docker/subuid /etc/subuid
cp /tmp/conf/docker/subgid /etc/subgid
chkconfig docker on


echo "Downloading docker-compose ${DOCKER_COMPOSE_VERSION}..."
curl -Lsf -o /usr/bin/docker-compose https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-Linux-x86_64
chmod +x /usr/bin/docker-compose
docker-compose --version
