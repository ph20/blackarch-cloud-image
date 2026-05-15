#!/usr/bin/env bash
# shellcheck disable=SC2154

function hetzner_default_user_sudo_policy() {
  case "${RESOLVED_IMAGE_PASSWORDLESS_SUDO}" in
    true)
      printf '%s\n' 'ALL=(ALL) NOPASSWD:ALL'
      ;;
    false)
      printf '%s\n' 'ALL=(ALL) ALL'
      ;;
  esac
}

function profile_hook() {
  local hook_name="${1}"
  local default_user_sudo=''
  local quoted_default_user=''
  local quoted_default_user_gecos=''
  local quoted_default_user_sudo=''

  case "${hook_name}" in
    finalize)
      default_user_sudo="$(hetzner_default_user_sudo_policy)"
      printf -v quoted_default_user '%q' "${RESOLVED_IMAGE_DEFAULT_USER}"
      printf -v quoted_default_user_gecos '%q' "${RESOLVED_IMAGE_DEFAULT_USER_GECOS}"
      printf -v quoted_default_user_sudo '%q' "${default_user_sudo}"

      run_logged install -d -m0755 "${TARGET_ROOT}/etc/ssh/sshd_config.d"
      cat <<'EOF' >"${TARGET_ROOT}/etc/ssh/sshd_config.d/00-hetzner-root-login.conf"
PermitRootLogin prohibit-password
EOF

      cat <<EOF >"${TARGET_ROOT}/etc/cloud/cloud.cfg.d/99-hetzner.cfg"
users:
  - default
  - name: ${RESOLVED_IMAGE_DEFAULT_USER}
    gecos: ${RESOLVED_IMAGE_DEFAULT_USER_GECOS}
    groups: [wheel, systemd-journal]
    sudo: ["${default_user_sudo}"]
    lock_passwd: true
    shell: /bin/bash
datasource_list: [ Hetzner, None ]
disable_root: false
ssh_pwauth: false
cloud_init_modules:
  - seed_random
  - bootcmd
  - write_files
  - [growpart, always]
  - [resizefs, always]
  - disk_setup
  - mounts
  - set_hostname
  - update_hostname
  - update_etc_hosts
  - ca_certs
  - rsyslog
  - users_groups
  - ssh
  - set_passwords
system_info:
  distro: arch
  default_user:
    name: ${RESOLVED_IMAGE_DEFAULT_USER}
    gecos: ${RESOLVED_IMAGE_DEFAULT_USER_GECOS}
    groups: [wheel, systemd-journal]
    sudo: ["${default_user_sudo}"]
    lock_passwd: true
    shell: /bin/bash
  network:
    renderers: [networkd]
    activators: [networkd]
EOF

      run_logged install -d -m0755 "${TARGET_ROOT}/usr/local/sbin" "${TARGET_ROOT}/etc/systemd/system"
      cat <<EOF >"${TARGET_ROOT}/usr/local/sbin/blackarch-hcloud-authorized-keys"
#!/usr/bin/env bash
set -o nounset
set -o errexit
set -o pipefail

readonly CLOUD_USER=${quoted_default_user}
readonly CLOUD_USER_GECOS=${quoted_default_user_gecos}
readonly CLOUD_USER_SUDO=${quoted_default_user_sudo}

function ensure_cloud_user() {
  if ! getent passwd "\${CLOUD_USER}" >/dev/null; then
    useradd -m -c "\${CLOUD_USER_GECOS}" -G wheel,systemd-journal -s /bin/bash "\${CLOUD_USER}"
  fi

  passwd -l "\${CLOUD_USER}" >/dev/null 2>&1 || true
}

function ensure_cloud_user_sudo() {
  install -d -m0750 /etc/sudoers.d
  printf '%s %s\n' "\${CLOUD_USER}" "\${CLOUD_USER_SUDO}" >/etc/sudoers.d/91-blackarch-cloud-user
  chmod 0440 /etc/sudoers.d/91-blackarch-cloud-user
}

function wait_for_cloud_init_instance_data() {
  local attempt=''

  # On Arch cloud-init, cloud-final is ordered after multi-user.target. Waiting
  # for full cloud-init completion here would block multi-user and deadlock boot;
  # Hetzner instance data is enough to query metadata SSH keys for blackarch.
  for attempt in {1..120}; do
    if [ -r /run/cloud-init/instance-data.json ] || [ -r /run/cloud-init/instance-data-sensitive.json ]; then
      return 0
    fi

    sleep 1
  done

  return 1
}

function install_hcloud_authorized_keys() {
  local group=''
  local home=''
  local key_file=''
  local tmp_keys=''

  home="\$(getent passwd "\${CLOUD_USER}" | cut -d: -f6)"
  group="\$(id -gn "\${CLOUD_USER}")"
  key_file="\${home}/.ssh/authorized_keys"
  tmp_keys="\$(mktemp)"
  trap 'rm -f "\${tmp_keys:-}"' EXIT

  wait_for_cloud_init_instance_data

  cloud-init query -f '{{ ds.meta_data["public-keys"] | join("\\n") }}' >"\${tmp_keys}"

  if ! grep -Eq '^[[:space:]]*ssh-(rsa|ed25519|ecdsa)[[:space:]]+' "\${tmp_keys}"; then
    exit 0
  fi

  install -d -m0700 -o "\${CLOUD_USER}" -g "\${group}" "\${home}/.ssh"
  install -m0600 -o "\${CLOUD_USER}" -g "\${group}" "\${tmp_keys}" "\${key_file}"
}

ensure_cloud_user
ensure_cloud_user_sudo
install_hcloud_authorized_keys
EOF
      run_logged chmod 0755 "${TARGET_ROOT}/usr/local/sbin/blackarch-hcloud-authorized-keys"

      cat <<'EOF' >"${TARGET_ROOT}/usr/local/sbin/blackarch-hcloud-volume-trigger"
#!/usr/bin/env bash
set -o nounset
set -o errexit
set -o pipefail

udevadm trigger -c add -s block -p ID_VENDOR=HC --verbose -p ID_MODEL=Volume
EOF
      run_logged chmod 0755 "${TARGET_ROOT}/usr/local/sbin/blackarch-hcloud-volume-trigger"

      cat <<'EOF' >"${TARGET_ROOT}/etc/systemd/system/blackarch-hcloud-authorized-keys.service"
[Unit]
Description=Install Hetzner SSH keys for the BlackArch cloud user
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/blackarch-hcloud-authorized-keys
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF
      cat <<'EOF' >"${TARGET_ROOT}/etc/systemd/system/blackarch-hcloud-volume-trigger.service"
[Unit]
Description=Trigger udev events for Hetzner Cloud Volumes
After=systemd-udevd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/blackarch-hcloud-volume-trigger

[Install]
WantedBy=multi-user.target
EOF
      run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/systemctl --quiet enable blackarch-hcloud-authorized-keys.service
      run_logged arch-chroot "${TARGET_ROOT}" /usr/bin/systemctl --quiet enable blackarch-hcloud-volume-trigger.service
      ;;
  esac
}
