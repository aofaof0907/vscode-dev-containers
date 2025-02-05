#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See https://go.microsoft.com/fwlink/?linkid=2090316 for license information.
#-------------------------------------------------------------------------------------------------------------
#
# Docs: https://github.com/microsoft/vscode-dev-containers/blob/main/script-library/docs/sshd.md
# Maintainer: The VS Code and Codespaces Teams
#
# Syntax: ./sshd-debian.sh [SSH Port (don't use 22)] [non-root user] [start sshd now flag] [new password for user] [fix environment flag]
#
# Note: You can change your user's password with "sudo passwd $(whoami)" (or just "passwd" if running as root).

SSHD_PORT=${1:-"2222"}
USERNAME=${2:-"automatic"}
START_SSHD=${3:-"false"}
NEW_PASSWORD=${4:-"skip"}
FIX_ENVIRONMENT=${5:-"true"}

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

# Install openssh-server openssh-client
if ! dpkg -s openssh-server openssh-client lsof jq > /dev/null 2>&1; then
    apt-get-update-if-needed
    apt-get -y install --no-install-recommends openssh-server openssh-client lsof jq
fi

# Generate password if new password set to the word "random"
if [ "${NEW_PASSWORD}" = "random" ]; then
    NEW_PASSWORD="$(openssl rand -hex 16)"
    EMIT_PASSWORD="true"
elif [ "${NEW_PASSWORD}" != "skip" ]; then
    # If new password not set to skip, set it for the specified user
    echo "${USERNAME}:${NEW_PASSWORD}" | chpasswd
fi

# Add user to ssh group
if [ "${USERNAME}" != "root" ]; then
    usermod -aG ssh ${USERNAME}
fi

# Setup sshd
mkdir -p /var/run/sshd
sed -i 's/session\s*required\s*pam_loginuid\.so/session optional pam_loginuid.so/g' /etc/pam.d/sshd
sed -i 's/#*PermitRootLogin prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config
sed -i -E "s/#*\s*Port\s+.+/Port ${SSHD_PORT}/g" /etc/ssh/sshd_config
# Need to UsePAM so /etc/environment is processed
sed -i -E "s/#?\s*UsePAM\s+.+/UsePAM yes/g" /etc/ssh/sshd_config

# Script to store variables that exist at the time the ENTRYPOINT is fired
STORE_ENV_SCRIPT="$(cat << 'EOF'
# Wire in codespaces secret processing to zsh if present (since may have been added to image after script was run)
if [ -f  /etc/zsh/zlogin ] && ! grep '/etc/profile.d/00-restore-secrets.sh' /etc/zsh/zlogin > /dev/null 2>&1; then
    echo -e "if [ -f /etc/profile.d/00-restore-secrets.sh ]; then . /etc/profile.d/00-restore-secrets.sh; fi\n$(cat /etc/zsh/zlogin 2>/dev/null || echo '')" | sudoIf tee /etc/zsh/zlogin > /dev/null
fi
EOF
)"

# Script to ensure login shells get the latest Codespaces secrets
RESTORE_SECRETS_SCRIPT="$(cat << 'EOF'
#!/bin/sh
if [ "${CODESPACES}" != "true" ] || [ "${VSCDC_FIXED_SECRETS}" = "true" ] || [ ! -z "${GITHUB_CODESPACES_TOKEN}" ]; then
    # Not codespaces, already run, or secrets already in environment, so return
    return
fi
if [ -f /workspaces/.codespaces/shared/.env ]; then
    set -o allexport
    . /workspaces/.codespaces/shared/.env
    set +o allexport
fi
export VSCDC_FIXED_SECRETS=true
EOF
)"

# Write out a scripts that can be referenced as an ENTRYPOINT to auto-start sshd and fix login environments
mkdir -p /usr/local/etc/devcontainer-entrypoint.d/
cat << 'EOF' > /usr/local/etc/devcontainer-entrypoint.d/ssh-init.sh
#!/usr/bin/env bash
# This script is intended to be run as root with a container that runs as root (even if you connect with a different user)
# However, it supports running as a user other than root if passwordless sudo is configured for that same user.

set -e 

sudoIf()
{
    if [ "$(id -u)" -ne 0 ]; then
        sudo "$@"
    else
        "$@"
    fi
}

EOF
if [ "${FIX_ENVIRONMENT}" = "true" ]; then
    echo "${STORE_ENV_SCRIPT}" >> /usr/local/etc/devcontainer-entrypoint.d/ssh-init.sh
    echo "${RESTORE_SECRETS_SCRIPT}" > /etc/profile.d/00-restore-secrets.sh
    chmod +x /etc/profile.d/00-restore-secrets.sh
    # Wire in zsh if present
    if type zsh > /dev/null 2>&1; then
        echo -e "if [ -f /etc/profile.d/00-restore-secrets.sh ]; then . /etc/profile.d/00-restore-secrets.sh; fi\n$(cat /etc/zsh/zlogin 2>/dev/null || echo '')" > /etc/zsh/zlogin
    fi
fi
cat << 'EOF' >> /usr/local/etc/devcontainer-entrypoint.d/ssh-init.sh

# ** Start SSH server **
sudoIf /etc/init.d/ssh start 2>&1 | sudoIf tee /tmp/sshd.log > /dev/null

set +e
exec "$@"
EOF
chmod +x /usr/local/etc/devcontainer-entrypoint.d/ssh-init.sh
# Symlink for backwards compatibility
ln -sf /usr/local/etc/devcontainer-entrypoint.d/ssh-init.sh /usr/local/share/ssh-init.sh

# If we should start sshd now, do so
if [ "${START_SSHD}" = "true" ]; then
    /usr/local/etc/devcontainer-entrypoint.d/ssh-init.sh
fi

# Output success details
echo -e "Done!\n\n- Port: ${SSHD_PORT}\n- User: ${USERNAME}"
if [ "${EMIT_PASSWORD}" = "true" ]; then
    echo "- Password: ${NEW_PASSWORD}"
fi
echo -e "\nForward port ${SSHD_PORT} to your local machine and run:\n\n  ssh -p ${SSHD_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null ${USERNAME}@localhost\n"
