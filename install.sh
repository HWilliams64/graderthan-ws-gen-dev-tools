#!/bin/bash

set -u
IFS=$'\n\t'

# ===== Versions & URLs =====
AWSCLI_VERSION="2.21.3"
AWSCLI_ZIP_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip"

NVM_VERSION="v0.40.3"
NVM_INSTALL_URL="https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh"
NODE_MAJOR="24"

UBUNTU_CODENAME="focal"
DOCKER_REPO_ARCH="$(dpkg --print-architecture)"
DOCKER_CE_VERSION="5:27.3.1-1~ubuntu.20.04~${UBUNTU_CODENAME}"
DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
DOCKER_APT_REPO="deb [arch=${DOCKER_REPO_ARCH}] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable"

DOCKER_COMPOSE_VERSION="1.29.2"
DOCKER_COMPOSE_URL="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)"

GH_KEYRING_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"

# ===== Work dirs & logs =====
WORK_DIR="/tmp/setup_work"
LOG_DIR="/tmp/install_logs"
APT_LOCK="/tmp/apt-seq.lock"   # Serialize all apt operations across parallel tasks
mkdir -p "$WORK_DIR" "$LOG_DIR"

declare -A PID_NAME
declare -A NAME_OUT
declare -A NAME_ERR
PIDS=()

aws_cli_install() {
  set -e
  cd "$WORK_DIR"
  curl -sSLo awscliv2.zip "$AWSCLI_ZIP_URL"
  unzip -q -o awscliv2.zip
  ./aws/install
  rm -rf aws awscliv2.zip
  aws --version >/dev/null 2>&1 || true
}

nvm_node_install() {
  set -e

  # Ensure any apt-provided npm/nodejs are removed to avoid conflicts
  if dpkg -l | awk '{print $2}' | grep -qx "npm"; then
    flock -w 1200 "$APT_LOCK" bash -lc 'apt-get remove -y npm || true; apt-get autoremove -y || true'
  fi
  if dpkg -l | awk '{print $2}' | grep -qx "nodejs"; then
    flock -w 1200 "$APT_LOCK" bash -lc 'apt-get remove -y nodejs || true; apt-get autoremove -y || true'
  fi

  # If a non-apt npm exists, we’ll proceed; nvm will manage its own npm on PATH.
  # Install NVM and Node
  curl -fsSL "$NVM_INSTALL_URL" | bash
  bash -lc 'export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm install '"$NODE_MAJOR"'; node -v >/dev/null; npm -v >/dev/null'
}

docker_install() {
  set -e
  # Run ALL apt operations for Docker under a single serialized lock to avoid concurrency
  flock -w 1200 "$APT_LOCK" bash -lc '
    apt-get update -y
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release
    curl -fsSL "'"$DOCKER_GPG_URL"'" | apt-key add - >/dev/null
    add-apt-repository -y "'"$DOCKER_APT_REPO"'"
    apt-get install -y docker-ce="'"$DOCKER_CE_VERSION"'" docker-ce-cli="'"$DOCKER_CE_VERSION"'" containerd.io docker-buildx-plugin docker-compose-plugin
  '
  update-alternatives --set iptables /usr/sbin/iptables-legacy
  update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
  curl -fsSL "$DOCKER_COMPOSE_URL" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  docker --version >/dev/null 2>&1 || true
  /usr/local/bin/docker-compose --version >/dev/null 2>&1 || true
}

gh_cli_install() {
  set -e
  # Serialize apt work (wget install, repo setup, update, gh install)
  flock -w 1200 "$APT_LOCK" bash -lc '
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y wget
  '
  mkdir -p -m 755 /etc/apt/keyrings
  out="$(mktemp)"
  wget -nv -O "$out" "$GH_KEYRING_URL" >/dev/null 2>&1
  cat "$out" > /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  rm -f "$out"
  mkdir -p -m 755 /etc/apt/sources.list.d
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  flock -w 1200 "$APT_LOCK" bash -lc '
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y gh
  '
  gh --version >/dev/null 2>&1 || true
}

run_bg() {
  local name="$1"; shift
  local out="$LOG_DIR/${name}.out"
  local err="$LOG_DIR/${name}.err"
  NAME_OUT["$name"]="$out"
  NAME_ERR["$name"]="$err"

  (
    {
      "$@" 2> >(while IFS= read -r line; do printf "[%s][stderr] %s\n" "$name" "$line"; done | tee -a "$err" >&2)
    } | while IFS= read -r line; do printf "[%s][stdout] %s\n" "$name" "$line"; done | tee -a "$out"
  ) &
  local pid=$!
  PID_NAME[$pid]="$name"
  PIDS+=("$pid")
  echo "[${name}] started (pid $pid). Logs: $out | $err"
}

run_bg "aws_cli" aws_cli_install
run_bg "nvm_node" nvm_node_install
run_bg "docker"  docker_install
run_bg "gh_cli"  gh_cli_install

FAILURES=0
for pid in "${PIDS[@]}"; do
  name="${PID_NAME[$pid]}"
  if wait "$pid"; then
    echo "[${name}] ✅ completed successfully."
  else
    rc=$?
    ((FAILURES++))
    echo "[${name}] ❌ failed with exit code ${rc}."
    echo "----- [${name}] last 40 lines of stderr -----"
    tail -n 40 "${NAME_ERR[$name]}" || true
    echo "----- [${name}] end stderr -----"
    echo "Full logs: ${NAME_OUT[$name]} (stdout), ${NAME_ERR[$name]} (stderr)"
  fi
done

if (( FAILURES == 0 )); then
  echo "[all] All tasks completed."
  dockerd &
else
  echo "[all] ${FAILURES} task(s) failed. See logs in ${LOG_DIR}"
  exit 1
fi
