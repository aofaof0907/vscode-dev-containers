#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See https://go.microsoft.com/fwlink/?linkid=2090316 for license information.
#-------------------------------------------------------------------------------------------------------------
#
# Docs: https://github.com/microsoft/vscode-dev-containers/blob/main/script-library/docs/docker-in-docker.md
# Maintainer: The VS Code and Codespaces Teams
#
# Syntax: ./docker-in-docker-debian.sh [enable non-root docker access flag] [non-root user] [use moby]

ENABLE_NONROOT_DOCKER=${1:-"true"}
USERNAME=${2:-"automatic"}
USE_MOBY=${3:-"true"}

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# Determine the appropriate non-root user
if [ "${USERNAME}" = "auto" ] || [ "${USERNAME}" = "automatic" ]; then
    USERNAME=""
    POSSIBLE_USERS=("vscode" "node" "codespace" "$(awk -v val=1000 -F ":" '$3==val{print $1}' /etc/passwd)")
    for CURRENT_USER in ${POSSIBLE_USERS[@]}; do
        if id -u ${CURRENT_USER} > /dev/null 2>&1; then
            USERNAME=${CURRENT_USER}
            break
        fi
    done
    if [ "${USERNAME}" = "" ]; then
        USERNAME=root
    fi
elif [ "${USERNAME}" = "none" ] || ! id -u ${USERNAME} > /dev/null 2>&1; then
    USERNAME=root
fi

# Function to run apt-get if needed
apt-get-update-if-needed()
{
    if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls /var/lib/apt/lists/ | wc -l)" = "0" ]; then
        echo "Running apt-get update..."
        apt-get update
    else
        echo "Skipping apt-get update."
    fi
}

# Ensure apt is in non-interactive to avoid prompts
export DEBIAN_FRONTEND=noninteractive

# Install docker/dockerd dependencies if missing
if ! dpkg -s apt-transport-https curl ca-certificates lxc pigz xz-utils iptables > /dev/null 2>&1 || ! type gpg > /dev/null 2>&1; then
    apt-get-update-if-needed
    apt-get -y install --no-install-recommends apt-transport-https curl ca-certificates lxc pigz xz-utils iptables gnupg2 
fi

# Swap to legacy iptables for compatibility
if type iptables-legacy > /dev/null 2>&1; then
    update-alternatives --set iptables /usr/sbin/iptables-legacy
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
fi

# Install Docker / Moby CLI if not already installed
if type docker > /dev/null 2>&1 && type dockerd > /dev/null 2>&1; then
    echo "Docker / Moby CLI and Engine already installed."
else
    # Source /etc/os-release to get OS info
    . /etc/os-release
    if [ "${USE_MOBY}" = "true" ]; then
        # Import key safely (new 'signed-by' method rather than deprecated apt-key approach) and install
        curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/microsoft-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/repos/microsoft-${ID}-${VERSION_CODENAME}-prod ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/microsoft.list
        apt-get update
        apt-get -y install --no-install-recommends moby-cli moby-buildx moby-compose moby-engine
    else
        # Import key safely (new 'signed-by' method rather than deprecated apt-key approach) and install
        curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor > /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
        apt-get update
        apt-get -y install --no-install-recommends docker-ce-cli docker-ce
    fi
fi

echo "Finished installing docker / moby"

# Install Docker Compose if not already installed  and is on a supported architecture
if type docker-compose > /dev/null 2>&1; then
    echo "Docker Compose already installed."
else
    TARGET_COMPOSE_ARCH="$(uname -m)"
    if [ "${TARGET_COMPOSE_ARCH}" = "amd64" ]; then
        TARGET_COMPOSE_ARCH="x86_64"
    fi
    if [ "${TARGET_COMPOSE_ARCH}" != "x86_64" ]; then
        # Use pip to get a version that runns on this architecture
        if ! dpkg -s python3-minimal python3-pip libffi-dev python3-venv pipx > /dev/null 2>&1; then
            apt-get-update-if-needed
            apt-get -y install python3-minimal python3-pip libffi-dev python3-venv pipx
        fi
        export PIPX_HOME=/usr/local/pipx
        mkdir -p ${PIPX_HOME}
        export PIPX_BIN_DIR=/usr/local/bin
        export PIP_CACHE_DIR=/tmp/pip-tmp/cache
        pipx install --system-site-packages --pip-args '--no-cache-dir --force-reinstall' docker-compose
        rm -rf /tmp/pip-tmp
    else 
        LATEST_COMPOSE_VERSION=$(basename "$(curl -fsSL -o /dev/null -w "%{url_effective}" https://github.com/docker/compose/releases/latest)")
        curl -fsSL "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-${TARGET_COMPOSE_ARCH}" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
fi

# Add user to the docker group
if [ "${ENABLE_NONROOT_DOCKER}" = "true" ]; then
    if ! getent group docker > /dev/null 2>&1; then
        groupadd docker
    fi
        usermod -aG docker ${USERNAME}
fi

# Add docker init script to entrypoint folder
mkdir -p /usr/local/etc/devcontainer-entrypoint.d/
cat << 'EOF' > /usr/local/etc/devcontainer-entrypoint.d/docker-init.sh
#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See https://go.microsoft.com/fwlink/?linkid=2090316 for license information.
#-------------------------------------------------------------------------------------------------------------

sudoIf()
{
    if [ "$(id -u)" -ne 0 ]; then
        sudo "$@"
    else
        "$@"
    fi
}

date > /tmp/dockerd.log

# explicitly remove dockerd and containerd PID file to ensure that it can start properly if it was stopped uncleanly
# ie: docker kill <ID>
sudoIf find /run /var/run -iname 'docker*.pid' -delete || :
sudoIf find /run /var/run -iname 'container*.pid' -delete || :

set -e

## Dind wrapper script from docker team
# Maintained: https://github.com/moby/moby/blob/master/hack/dind

export container=docker

if [ -d /sys/kernel/security ] && ! sudoIf mountpoint -q /sys/kernel/security; then
	sudoIf mount -t securityfs none /sys/kernel/security || {
		echo >&2 'Could not mount /sys/kernel/security.'
		echo >&2 'AppArmor detection and --privileged mode might break.'
	}
fi

# Mount /tmp (conditionally)
if ! sudoIf mountpoint -q /tmp; then
	sudoIf mount -t tmpfs none /tmp
fi

# cgroup v2: enable nesting
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
	# move the init process (PID 1) from the root group to the /init group,
	# otherwise writing subtree_control fails with EBUSY.
	sudoIf mkdir -p /sys/fs/cgroup/init
	sudoIf echo 1 > /sys/fs/cgroup/init/cgroup.procs
	# enable controllers
	sudoIf sed -e 's/ / +/g' -e 's/^/+/' < /sys/fs/cgroup/cgroup.controllers \
		> /sys/fs/cgroup/cgroup.subtree_control
fi
## Dind wrapper over.

# Handle DNS
set +e
cat /etc/resolv.conf | grep -i 'internal.cloudapp.net'
if [ $? -eq 0 ]
then
  echo "Setting dockerd Azure DNS." >> /tmp/dockerd.log
  CUSTOMDNS="--dns 168.63.129.16"
else
  echo "Not setting dockerd DNS manually." >> /tmp/dockerd.log
  CUSTOMDNS=""
fi
set -e

# Start docker/moby engine
( sudoIf dockerd $CUSTOMDNS >> /tmp/dockerd.log 2>&1 ) &

set +e

# Execute whatever commands were passed in (if any). This allows us 
# to set this script to ENTRYPOINT while still executing the default CMD.
exec "$@"
EOF
chmod +x /usr/local/etc/devcontainer-entrypoint.d/docker-init.sh
# Symlink for backwards compatibility
ln -sf /usr/local/etc/devcontainer-entrypoint.d/docker-init.sh /usr/local/share/docker-init.sh

echo "Done!"