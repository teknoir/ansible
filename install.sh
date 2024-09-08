#!/usr/bin/env bash
set -e
#set -x

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

check_ansible() {
  if [ ! command -v ansible &> /dev/null ]; then
      fatal "Ansible could not be found, please install with ex. \"brew install ansible\" or \"pip install ansible\""
  fi
}

install_teknoir_ansible() {
  check_ansible

  cp ansible.cfg ${HOME}/.ansible.cfg
  cp -f inventory.py ${HOME}/.ansible/inventory.py
}

if [ "${TEKNOIR_FRONTEND}" = "noninteractive" ]; then
  install_teknoir_ansible
else
  warn "Do you want to setup Teknoir Ansible addons for \"${USER}\" in \"${HOME}/.ansible\"? [yY]"
  read REPLY

  case ${REPLY} in
    [Yy]* )
      install_teknoir_ansible
      ;;
    * )
      info "Skipping setup"
      ;;
  esac
fi
