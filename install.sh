#!/usr/bin/env bash
set -e
#set -x

export TEKNOIR_ANSIBLE_INSTALL=${TEKNOIR_ANSIBLE_INSTALL:-"user"}

# --- helper functions for logs ---
info()
{
    echo '[INFO] ' "$@"
}
warn()
{
    echo '[WARN] ' "$@" >&2
}
fatal()
{
    echo '[ERROR] ' "$@" >&2
    exit 1
}

check_deps() {
  if ! command -v curl &> /dev/null; then
      fatal "curl is required but not installed."
  fi
  if ! command -v tar &> /dev/null; then
      fatal "tar is required but not installed."
  fi
}

check_ansible() {
  if ! command -v ansible &> /dev/null; then
      fatal "Ansible could not be found, please install with ex. \"brew install ansible\" or \"pip install ansible\""
  fi
}

download_bundle() {
  if [ ! -f "inventory.py" ] || [ ! -f "ansible.cfg" ]; then
    info "Local files missing, downloading latest release bundle..."
    GITHUB_REPO="teknoir/ansible"
    LATEST_URL=$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | grep "browser_download_url.*tar.gz" | cut -d '"' -f 4)
    if [ -z "$LATEST_URL" ]; then
      fatal "Failed to fetch latest release bundle URL. Ensure there is at least one release with teknoir-ansible.tar.gz"
    fi
    info "Fetching $LATEST_URL"
    INSTALL_TMP_DIR=$(mktemp -d)
    curl -sSL "$LATEST_URL" | tar -xz -C "$INSTALL_TMP_DIR"
    cd "$INSTALL_TMP_DIR"
    trap 'rm -rf "$INSTALL_TMP_DIR"' EXIT
  fi
}

install_teknoir_ansible_user() {
  mkdir -p ${HOME}/.ansible
  cp ansible.cfg ${HOME}/.ansible.cfg
  cp -f inventory.py ${HOME}/.ansible/inventory.py
  chmod +x ${HOME}/.ansible/inventory.py
}

install_teknoir_ansible_system() {
  mkdir -p /etc/ansible
  cp ansible_system.cfg /etc/ansible/ansible.cfg
  cp inventory_system.py /etc/ansible/inventory.py
  chmod +x /etc/ansible/inventory.py
}

install_teknoir_ansible() {
  check_deps
  download_bundle
  check_ansible

  if [ "${TEKNOIR_ANSIBLE_INSTALL}" = "user" ]; then
    install_teknoir_ansible_user
  else
    install_teknoir_ansible_system
  fi
}

if [ "${TEKNOIR_FRONTEND}" = "noninteractive" ]; then
    install_teknoir_ansible
else
  if [ "${TEKNOIR_ANSIBLE_INSTALL}" = "user" ]; then
    INSTALL_PATH="${HOME}/.ansible"
  else
    INSTALL_PATH="/etc/ansible"
  fi

  warn "Do you want to setup Teknoir Ansible addons for \"${USER}\" in \"${INSTALL_PATH}\"? [yY]"
  if [ -t 0 ]; then
    read REPLY
  else
    read REPLY < /dev/tty
  fi

  case ${REPLY} in
    [Yy]* )
      install_teknoir_ansible
      ;;
    * )
      info "Skipping setup"
      ;;
  esac
fi
