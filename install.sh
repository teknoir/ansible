#!/bin/sh
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
  if ! command -v ansible &> /dev/null; then
      fatal "Ansible could not be found, please install with ex. \"brew install ansible\" or \"pip install ansible\""
  fi
}

check_corkscrew() {
  if ! command -v corkscrew &> /dev/null; then
      fatal "Command corkscrew could not be found, please install with ex. \"brew install corkscrew\""
  fi
}


install_teknoir_ansible() {
  check_ansible
  check_corkscrew

  cp ansible.cfg ${HOME}/.ansible.cfg

  mkdir -p ${HOME}/.ansible/plugins/modules
  mkdir -p ${HOME}/.ansible/plugins/action
  mkdir -p ${HOME}/.ansible/plugins/connection

  cp -f inventory.py ${HOME}/.ansible/inventory.py
  cp -rf module_plugins/* ${HOME}/.ansible/plugins/modules/
  cp -rf action_plugins/* ${HOME}/.ansible/plugins/action/
  cp -rf connection_plugins/* ${HOME}/.ansible/plugins/connection/
}

if [ ${TEKNOIR_FRONTEND} == 'noninteractive' ]; then
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
