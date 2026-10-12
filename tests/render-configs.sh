#!/usr/bin/env bash
# Isolated rendering only: no package installs, system services or host config changes.
set -Eeuo pipefail
SCRIPT=$(cd -- "$(dirname -- "$0")/.." && pwd)/deploy-nextcloud.sh
QA=${1:?Usage: render-configs.sh /absolute/output-directory}
[[ $QA == /* ]] || exit 2
mkdir -p "$QA"
source "$SCRIPT"
STATE_DIR="$QA/state"
LIB_DIR="$QA/lib"
CERT_DIR="$QA/certs"
NC_DIR="$QA/nextcloud"
WORK_DIR="$QA/work"
mkdir -p "$STATE_DIR" "$LIB_DIR" "$CERT_DIR" "$NC_DIR" "$WORK_DIR"
NEXTCLOUD_DOMAIN=cloud.example.com TALK_DOMAIN=talk.example.com TURN_DOMAIN=talk.example.com
PUBLIC_IP=8.8.4.4 LOCAL_IP=10.0.0.2
SESSION_HASH_KEY=$(printf 'a%.0s' {1..64})
SESSION_BLOCK_KEY=$(printf 'b%.0s' {1..32})
SIGNALING_SECRET=$(printf 'c%.0s' {1..64})
INTERNAL_SECRET=$(printf 'd%.0s' {1..64})
TURN_SECRET=$(printf 'e%.0s' {1..64})
JANUS_MIN_PORT=20000 JANUS_MAX_PORT=20199 TURN_MIN_PORT=49160 TURN_MAX_PORT=49259
PHP_MAX_CHILDREN=6 HPB_IMAGE=strukturag/nextcloud-spreed-signaling:2.1.1
write_file() {
    local path=$1
    if [[ $path != "$QA"/* ]]; then path="$QA/root$path"; fi
    mkdir -p "$(dirname "$path")"
    cat > "$path"
}
ensure_service() { :; }
systemctl() { :; }
install() { :; }
rm() { :; }
ln() { :; }
id() { :; }
nginx() { :; }
php-fpm8.3() { :; }
php8.3() { command php "$@"; }
link_janus_module() { :; }
nats-server() { :; }
docker() {
    if [[ $1 == container && $2 == inspect ]]; then return 1; fi
    if [[ $1 == image && $2 == inspect ]]; then printf 'sha256:test-image-id\n'; fi
}
configure_nginx
configure_php
configure_coturn
configure_media_backend
configure_hpb
configure_background_jobs
install_occ_runner
install_probe
printf 'Isolated render complete: %s\n' "$QA"
