#!/usr/bin/env bash
# SweatLobby server bootstrap for a fresh Ubuntu 24.04 VPS.
#
#   Part 1:  bash bootstrap.sh            (as root)
#            Creates the "deploy" user, firewall, automatic security updates,
#            Docker, a swap file and the folders from deploy/README.md.
#            It does NOT touch the SSH login rules, so you cannot lock yourself out.
#
#   Part 2:  bash bootstrap.sh lock-ssh   (as root, only after Part 1 and a proven deploy login)
#            Turns off root login and password login over SSH.
#
# Safe to re-run: every step checks before it changes anything.

set -Eeuo pipefail

DEPLOY_USER="deploy"
SWAP_SIZE="2G"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'echo "Stopped at line $LINENO. Nothing after that line ran." >&2' ERR

[ "$(id -u)" -eq 0 ] || die "Run this as root."
. /etc/os-release
if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "24.04" ]; then
  die "This script is written for Ubuntu 24.04 (found: ${PRETTY_NAME:-unknown})."
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

apt_get() {
  apt-get -y -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold "$@"
}

# ---------------------------------------------------------------- Part 2
lock_ssh() {
  local keys="/home/${DEPLOY_USER}/.ssh/authorized_keys"
  [ -s "$keys" ] || die "$keys is missing or empty. Run Part 1 first."

  echo
  echo "Before continuing you must have opened a SECOND window on your PC,"
  echo "logged in as ${DEPLOY_USER} with your key, and run:  sudo whoami"
  echo "It must print: root"
  echo "Keep THIS window open until the end."
  read -r -p "Did that work? Type yes to continue: " ans
  [ "$ans" = "yes" ] || die "Aborted. Nothing was changed."

  cat > /etc/ssh/sshd_config.d/00-sweatlobby.conf <<'EOF'
# Written by bootstrap.sh. Named 00- so it is read before other files and wins.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
X11Forwarding no
EOF

  if ! sshd -t; then
    rm -f /etc/ssh/sshd_config.d/00-sweatlobby.conf
    die "sshd rejected the new settings. They were removed and nothing changed."
  fi

  systemctl restart ssh
  log "SSH is now locked down. Effective settings:"
  sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication) '
  echo
  echo "Now, in your SECOND window, confirm that you can still log in as ${DEPLOY_USER}."
  echo "If you ever get locked out: Vultr dashboard -> your server -> View Console."
}

case "${1:-}" in
  lock-ssh) lock_ssh; exit 0 ;;
  "")       ;;
  *)        die "Unknown option '$1'. Use no option (Part 1) or: lock-ssh" ;;
esac

# ---------------------------------------------------------------- Part 1
log "Waiting for the first-boot setup (cloud-init) to finish"
cloud-init status --wait >/dev/null 2>&1 || true

log "Updating the package list and installing pending updates"
apt_get update
apt_get upgrade

log "Installing base packages"
apt_get install ca-certificates curl gnupg ufw unattended-upgrades sqlite3

log "Creating the ${DEPLOY_USER} user"
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi
usermod -aG sudo "$DEPLOY_USER"

# The deploy user has no password, so sudo must not ask for one.
# Anyone who holds the deploy SSH key already has full control, so this adds no new risk.
echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${DEPLOY_USER}"
chmod 440 "/etc/sudoers.d/90-${DEPLOY_USER}"
if ! visudo -cf "/etc/sudoers.d/90-${DEPLOY_USER}" >/dev/null; then
  rm -f "/etc/sudoers.d/90-${DEPLOY_USER}"
  die "sudoers file was invalid and was removed."
fi

log "Copying your SSH key to ${DEPLOY_USER}"
[ -s /root/.ssh/authorized_keys ] || die "/root/.ssh/authorized_keys is empty. Your key is not on the server."
grep -q '^ssh-' /root/.ssh/authorized_keys || die "No SSH public key found in /root/.ssh/authorized_keys."
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/${DEPLOY_USER}/.ssh"
cp /root/.ssh/authorized_keys "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chown "$DEPLOY_USER:$DEPLOY_USER" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"

log "Turning on the firewall (SSH, web and secure web only)"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

log "Turning on automatic security updates (no automatic reboots)"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

log "Installing Docker from Docker's official repository"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt_get update
apt_get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
# Keep container logs from slowly filling the disk.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl enable docker
systemctl restart docker
# Note: members of the docker group can control Docker, which is effectively root.
usermod -aG docker "$DEPLOY_USER"

log "Adding a ${SWAP_SIZE} swap file"
if ! swapon --show=NAME --noheadings | grep -q '^/swapfile$'; then
  if [ ! -f /swapfile ]; then
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo 'vm.swappiness=10' > /etc/sysctl.d/99-sweatlobby.conf
sysctl -p /etc/sysctl.d/99-sweatlobby.conf >/dev/null

log "Creating the folders the runbook expects"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 755 /opt/arenaos
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 700 /var/backups/arenaos
touch /var/log/arenaos-backup.log
chown "$DEPLOY_USER:$DEPLOY_USER" /var/log/arenaos-backup.log
chmod 640 /var/log/arenaos-backup.log

log "Summary"
echo "User:      $(id "$DEPLOY_USER")"
echo "Firewall:  $(ufw status | head -n 1)"
echo "Docker:    $(docker --version)"
echo "Compose:   $(docker compose version)"
echo "Swap:      $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
echo "Folders:   $(ls -ld /opt/arenaos /var/backups/arenaos | awk '{print $1, $3, $9}' | tr '\n' ';')"
if [ -f /var/run/reboot-required ]; then
  echo "A reboot is recommended (a kernel update was installed). Do it after the deploy login test."
fi

cat <<EOF

PART 1 DONE. SSH login rules are UNCHANGED (root login still works).

Next:
  1. Open a SECOND window on your PC and log in as ${DEPLOY_USER}.
  2. In that window run:  sudo whoami   (must print: root)   and   docker ps   (must not error).
  3. Only then, back in THIS window, run:  bash bootstrap.sh lock-ssh
EOF
