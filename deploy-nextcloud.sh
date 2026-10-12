#!/usr/bin/env bash
# Nextcloud + Nginx + RFC2136 ACME + Talk/Janus/NATS/coturn.
# Target: a dedicated, clean Ubuntu Server 24.04 (amd64 or arm64), systemd.
# Usage: sudo bash deploy-nextcloud.sh [--config /root/nextcloud.env]
# Re-running resumes this deployment; it is NOT a Nextcloud upgrade tool.
# Configuration files passed to --config are trusted Bash code, owned by root.
# Reviewed against upstream documentation on 2026-10-12. See README.md.
set -Eeuo pipefail
shopt -s inherit_errexit
umask 077

STATE_DIR=/etc/nextcloud-deploy
NC_DIR=/var/www/nextcloud
DATA_DIR=/var/lib/nextcloud/data
LOG_FILE=/var/log/nextcloud-deploy.log
CERT_NAME=nextcloud-deploy
CERT_DIR=/etc/letsencrypt/live/nextcloud-deploy
CREDENTIALS=/etc/letsencrypt/rfc2136.ini
LIB_DIR=/usr/local/lib/nextcloud-deploy
HPB_NAME=nextcloud-talk-hpb
CURRENT_STEP=bootstrap
WORK_DIR=''
POLICY_CREATED=0
WARNINGS=0

# Print a timestamped message without logging secrets.
log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

# Report a nonfatal limitation and count it for the final summary.
warn() { WARNINGS=$((WARNINGS + 1)); log "WARNING: $*"; }

# Stop with an actionable message and preserve the failing step in the log.
die() { log "ERROR [$CURRENT_STEP]: $*" >&2; exit 1; }

# Report unexpected command failures; deliberately never echo BASH_COMMAND.
on_error() {
    local rc=$1 line=$2
    trap - ERR
    log "FAILED: step=$CURRENT_STEP line=$line exit=$rc; log=$LOG_FILE" >&2
    exit "$rc"
}

# Remove temporary files and restore only the package-start policy we created.
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ $POLICY_CREATED == 1 ]]; then rm -f /usr/sbin/policy-rc.d; fi
    if [[ -n $WORK_DIR && $WORK_DIR == /var/tmp/nextcloud-deploy.* ]]; then
        rm -rf -- "$WORK_DIR"
    fi
    if (( rc != 0 )); then
        printf 'Deployment incomplete at step: %s. Fix the error and rerun the same command.\n' "$CURRENT_STEP" >&2
    fi
    exit "$rc"
}

# Run a named deployment phase with normal errexit semantics.
run_step() { CURRENT_STEP=$1; log "=== $CURRENT_STEP ==="; "$@"; }

# Require a private root-owned regular file; configuration can contain secrets.
check_trusted_file() {
    local f=$1 perm
    [[ -f $f && ! -L $f ]] || die "Not a regular trusted file: $f"
    [[ $(stat -c %u "$f") == 0 ]] || die "Run: sudo chown root:root '$f'"
    perm=$(stat -c %a "$f")
    (( (8#$perm & 0077) == 0 )) || die "Run: sudo chmod 600 '$f'"
}

# Ask on the controlling terminal, so hidden values never enter tee/log output.
ask() {
    local name=$1 label=$2 default=${3:-} secret=${4:-0} answer=''
    [[ -z ${!name:-} ]] || return 0
    [[ -r /dev/tty && -w /dev/tty ]] || die "Missing $name; use --config /root/nextcloud.env"
    printf '%s%s: ' "$label" "${default:+ [$default]}" > /dev/tty
    if [[ $secret == 1 ]]; then
        IFS= read -r -s answer < /dev/tty || die "Cannot read $name"
        printf '\n' > /dev/tty
    else
        IFS= read -r answer < /dev/tty || die "Cannot read $name"
    fi
    printf -v "$name" '%s' "${answer:-$default}"
    [[ -n ${!name} ]] || die "$name cannot be empty"
}

# Atomically replace a managed file only when its contents actually changed.
write_file() {
    local path=$1 mode=${2:-644} owner=${3:-root} group=${4:-root} temp
    if [[ ! -d $(dirname "$path") ]]; then install -d -m 755 "$(dirname "$path")"; fi
    temp=$(mktemp "${path}.tmp.XXXXXX")
    cat > "$temp"
    chown "$owner:$group" "$temp"
    chmod "$mode" "$temp"
    if [[ -f $path ]] && cmp -s "$temp" "$path"; then
        rm -f "$temp"
        chown "$owner:$group" "$path"
        chmod "$mode" "$path"
    else
        if [[ -e $path && ! -e $STATE_DIR/backups${path} ]]; then
            install -d -m 700 "$STATE_DIR/backups$(dirname "$path")"
            cp -a "$path" "$STATE_DIR/backups${path}"
        fi
        mv -f -- "$temp" "$path"
    fi
}

# Enable a service; restart only after config changes or if it is not running.
ensure_service() {
    local service=$1 fingerprint previous=''
    shift
    fingerprint=$(sha256sum "$@" | sha256sum | cut -d ' ' -f 1)
    if [[ -f $STATE_DIR/service-${service}.sha256 ]]; then
        previous=$(cat "$STATE_DIR/service-${service}.sha256")
    fi
    systemctl enable "$service" >/dev/null
    if [[ $fingerprint != "$previous" ]] || ! systemctl is-active --quiet "$service"; then
        if [[ $service == nginx ]] && systemctl is-active --quiet nginx; then
            systemctl reload nginx
        else
            systemctl restart "$service"
        fi
        systemctl is-active --quiet "$service"
        printf '%s\n' "$fingerprint" > "$STATE_DIR/service-${service}.sha256"
    else
        log "$service: already configured and running"
    fi
}

# Check the host before changing services, acquire an exclusive deployment lock.
bootstrap() {
    [[ $EUID == 0 ]] || die 'Run with sudo bash deploy-nextcloud.sh'
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] || die 'Only Ubuntu 24.04 is supported.'
    case $(dpkg --print-architecture) in amd64|arm64) ;; *) die 'Use amd64 or arm64.' ;; esac
    [[ -d /run/systemd/system ]] || die 'A booted Ubuntu host with systemd is required, not an unprivileged container.'
    exec 9>/run/lock/nextcloud-deploy.lock
    flock -n 9 || die 'Another deployment is already running.'
    install -d -m 700 "$STATE_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    trap 'on_error "$?" "$LINENO"' ERR
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    WORK_DIR=$(mktemp -d /var/tmp/nextcloud-deploy.XXXXXX)
    if [[ ! -f $STATE_DIR/settings.env ]]; then
        [[ ! -e $NC_DIR ]] || die "$NC_DIR already exists; this script will not adopt or overwrite an existing instance."
        if systemctl is-active --quiet apache2; then die 'Apache is running; use a clean dedicated server.'; fi
        if [[ -d /etc/nginx/sites-enabled ]]; then
            local f
            for f in /etc/nginx/sites-enabled/*; do
                [[ ! -e $f || ${f##*/} == default ]] || die "Existing Nginx site: $f. Use a clean dedicated server."
            done
        fi
    fi
}

# Load a saved deployment or a private input file and collect required parameters.
load_configuration() {
    local input='' arg
    while (( $# )); do
        arg=$1; shift
        case "$arg" in
            --config) (( $# )) || die '--config needs a file'; input=$1; shift ;;
            *) die "Unknown argument: $arg" ;;
        esac
    done
    if [[ -f $STATE_DIR/settings.env ]]; then
        if [[ -n $input ]]; then
            log "Resuming saved settings; --config is only read for a new deployment: $STATE_DIR/settings.env"
        fi
        check_trusted_file "$STATE_DIR/settings.env"
        # shellcheck source=/dev/null
        source "$STATE_DIR/settings.env"
        # A failed first run may have saved settings before writing ACME credentials.
        # Recover ONLY the missing TSIG secret from the same trusted input file.
        if [[ -n $input && ! -s $CREDENTIALS ]]; then
            check_trusted_file "$input"
            DNS_KEY_SECRET=$(source "$input"; printf '%s' "${DNS_KEY_SECRET:-}")
        fi
    elif [[ -n $input ]]; then
        check_trusted_file "$input"
        # shellcheck source=/dev/null
        source "$input"
    fi
    NC_MAJOR=${NC_MAJOR:-35}
    NC_VERSION=${NC_VERSION:-}
    HPB_IMAGE=${HPB_IMAGE:-strukturag/nextcloud-spreed-signaling:2.1.1}
    ADMIN_USER=${ADMIN_USER:-ncadmin}
    DNS_PORT=${DNS_PORT:-53}
    DNS_ALGORITHM=${DNS_ALGORITHM:-HMAC-SHA256}
    DNS_SIGN_QUERY=${DNS_SIGN_QUERY:-false}
    DNS_PROPAGATION_SECONDS=${DNS_PROPAGATION_SECONDS:-120}
    DNS_CHECK_RESOLVER=${DNS_CHECK_RESOLVER:-1.1.1.1}
    MANAGE_UFW=${MANAGE_UFW:-1}
    SSH_PORT=${SSH_PORT:-}
    JANUS_MIN_PORT=${JANUS_MIN_PORT:-20000}
    JANUS_MAX_PORT=${JANUS_MAX_PORT:-20199}
    TURN_MIN_PORT=${TURN_MIN_PORT:-49160}
    TURN_MAX_PORT=${TURN_MAX_PORT:-49259}
    PHP_MAX_CHILDREN=${PHP_MAX_CHILDREN:-6}
    DEFAULT_PHONE_REGION=${DEFAULT_PHONE_REGION:-}
    ask NEXTCLOUD_DOMAIN 'Nextcloud DNS name (no scheme), e.g. cloud.example.com'
    ask TALK_DOMAIN 'Talk/HPB DNS name (no scheme), e.g. talk.example.com'
    TURN_DOMAIN=${TURN_DOMAIN:-$TALK_DOMAIN}
    ask EMAIL 'Email for ACME certificate notices'
    ask PUBLIC_IP 'Static public IPv4 of this server / NAT'
    if [[ -z ${LOCAL_IP:-} ]]; then
        LOCAL_IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    fi
    [[ -n $LOCAL_IP ]] || ask LOCAL_IP 'IPv4 assigned to the server network interface'
    ask DNS_SERVER 'RFC2136 authoritative DNS server IP (not a hostname)'
    ask DNS_KEY_NAME 'Existing TSIG key name, e.g. nextcloud-acme.'
    if [[ ! -s $CREDENTIALS ]]; then ask DNS_KEY_SECRET 'Existing TSIG secret (base64, hidden)' '' 1; fi
}

# Validate strings before interpolation into SQL, Nginx, INI and service files.
validate_configuration() {
    local domain var value
    for domain in "$NEXTCLOUD_DOMAIN" "$TALK_DOMAIN" "$TURN_DOMAIN"; do
        [[ ${#domain} -le 253 && $domain =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]([a-z0-9-]*[a-z0-9])?$ ]] || die "Invalid lowercase FQDN: $domain"
    done
    [[ $NEXTCLOUD_DOMAIN != "$TALK_DOMAIN" ]] || die 'Nextcloud and HPB need different hostnames.'
    [[ $EMAIL =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die 'Invalid email address.'
    [[ $ADMIN_USER =~ ^[a-zA-Z][a-zA-Z0-9_.-]{2,31}$ ]] || die 'Invalid administrator username.'
    [[ $DNS_KEY_NAME =~ ^[A-Za-z0-9_.-]+$ ]] || die 'Invalid TSIG key name.'
    case "$DNS_ALGORITHM" in HMAC-SHA256|HMAC-SHA384|HMAC-SHA512) ;; *) die 'Use HMAC-SHA256, HMAC-SHA384 or HMAC-SHA512.' ;; esac
    [[ $DNS_SIGN_QUERY == true || $DNS_SIGN_QUERY == false ]] || die 'DNS_SIGN_QUERY must be true or false.'
    [[ $MANAGE_UFW == 0 || $MANAGE_UFW == 1 ]] || die 'MANAGE_UFW must be 0 or 1.'
    [[ $NC_MAJOR =~ ^(33|34|35)$ ]] || die 'Select NC_MAJOR=33, 34 or 35; review compatibility before adding a newer major.'
    [[ -z $NC_VERSION || $NC_VERSION =~ ^${NC_MAJOR}\.[0-9]+\.[0-9]+$ ]] || die 'NC_VERSION must be a stable release in NC_MAJOR.'
    [[ $HPB_IMAGE =~ ^[A-Za-z0-9._/@:-]+$ ]] || die 'Invalid Docker image reference.'
    [[ -z $DEFAULT_PHONE_REGION || $DEFAULT_PHONE_REGION =~ ^[A-Z]{2}$ ]] || die 'Phone region must be an uppercase 2-letter country code.'
    for var in DNS_PORT JANUS_MIN_PORT JANUS_MAX_PORT TURN_MIN_PORT TURN_MAX_PORT; do
        value=${!var}
        [[ $value =~ ^[1-9][0-9]{0,4}$ ]] && (( value <= 65535 )) || die "Invalid port: $var"
    done
    [[ -z $SSH_PORT || $SSH_PORT =~ ^[1-9][0-9]{0,4}$ ]] || die 'Invalid SSH_PORT.'
    [[ -z $SSH_PORT ]] || (( SSH_PORT <= 65535 )) || die 'Invalid SSH_PORT.'
    [[ $DNS_PROPAGATION_SECONDS =~ ^[1-9][0-9]{0,3}$ ]] || die 'Invalid DNS propagation wait.'
    [[ $PHP_MAX_CHILDREN =~ ^[1-9][0-9]?$ ]] || die 'PHP_MAX_CHILDREN must be 1..99.'
    (( JANUS_MIN_PORT >= 10000 && JANUS_MIN_PORT < JANUS_MAX_PORT )) || die 'Invalid Janus range.'
    (( TURN_MIN_PORT >= 10000 && TURN_MIN_PORT < TURN_MAX_PORT )) || die 'Invalid TURN relay range.'
    (( JANUS_MAX_PORT < TURN_MIN_PORT || TURN_MAX_PORT < JANUS_MIN_PORT )) || die 'Media port ranges must not overlap.'
    if [[ -n ${DNS_KEY_SECRET:-} ]]; then
        [[ $DNS_KEY_SECRET =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || die 'TSIG secret must be base64 without spaces.'
    fi
}

# Persist only nonsecret parameters, using shell escaping; keep existing settings.
save_configuration() {
    if [[ ! -f $STATE_DIR/settings.env ]]; then
        local var
        for var in NEXTCLOUD_DOMAIN TALK_DOMAIN TURN_DOMAIN EMAIL PUBLIC_IP LOCAL_IP \
            DNS_SERVER DNS_PORT DNS_KEY_NAME DNS_ALGORITHM DNS_SIGN_QUERY DNS_PROPAGATION_SECONDS \
            DNS_CHECK_RESOLVER NC_MAJOR NC_VERSION HPB_IMAGE ADMIN_USER MANAGE_UFW SSH_PORT \
            JANUS_MIN_PORT JANUS_MAX_PORT TURN_MIN_PORT TURN_MAX_PORT PHP_MAX_CHILDREN DEFAULT_PHONE_REGION; do
            printf '%s=%q\n' "$var" "${!var}"
        done > "$STATE_DIR/settings.env"
        chmod 600 "$STATE_DIR/settings.env"
    fi
}

# Install distro packages without briefly exposing unconfigured default services.
install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    if [[ ! -e /usr/sbin/policy-rc.d ]]; then
        printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
        chmod 755 /usr/sbin/policy-rc.d
        POLICY_CREATED=1
    fi
    apt-get update
    apt-get install -y --no-install-recommends software-properties-common ca-certificates curl openssl python3
    add-apt-repository -y universe
    apt-get update
    apt-get install -y --no-install-recommends \
        nginx mariadb-server redis-server certbot python3-certbot-dns-rfc2136 \
        php8.3-cli php8.3-fpm php8.3-common php8.3-mysql php8.3-curl php8.3-gd \
        php8.3-mbstring php8.3-intl php8.3-xml php8.3-zip php8.3-bcmath php8.3-gmp \
        php8.3-bz2 php8.3-apcu php8.3-redis php8.3-imagick \
        coturn janus nats-server docker.io dnsutils bzip2 unzip jq ufw \
        python3-websocket logrotate
    if [[ $POLICY_CREATED == 1 ]]; then rm -f /usr/sbin/policy-rc.d; POLICY_CREATED=0; fi
    systemctl daemon-reload
}

# Check real interface addresses, public DNS and the IPv4-only media assumption.
check_network() {
    python3 - "$PUBLIC_IP" "$LOCAL_IP" "$DNS_SERVER" "$DNS_CHECK_RESOLVER" <<'PY'
import ipaddress, json, subprocess, sys
public, local, dns, resolver = sys.argv[1:]
p = ipaddress.ip_address(public)
assert p.version == 4 and p.is_global, 'PUBLIC_IP must be a globally routable IPv4 address, not a documentation/private address'
l = ipaddress.ip_address(local)
assert l.version == 4 and not l.is_loopback, 'LOCAL_IP must be the actual network-interface IPv4'
ipaddress.ip_address(dns)
ipaddress.ip_address(resolver)
interfaces = json.loads(subprocess.check_output(['ip', '-j', '-4', 'address', 'show']))
assert any(a.get('local') == local for i in interfaces for a in i['addr_info']), 'LOCAL_IP is not assigned to this server'
PY
    local domain a aaaa
    for domain in $(printf '%s\n' "$NEXTCLOUD_DOMAIN" "$TALK_DOMAIN" "$TURN_DOMAIN" | sort -u); do
        a=$(dig @"$DNS_CHECK_RESOLVER" "$domain" A +short +time=5 +tries=2 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
        [[ $a == "$PUBLIC_IP" ]] || die "Public A record for $domain must be exactly $PUBLIC_IP (got: ${a:-none}). Disable CDN proxying / fix DNS or DNS_CHECK_RESOLVER."
        aaaa=$(dig @"$DNS_CHECK_RESOLVER" "$domain" AAAA +short +time=5 +tries=2 | grep ':' || true)
        [[ -z $aaaa ]] || die "$domain has AAAA records. This installer configures IPv4 media only; remove AAAA or implement IPv6 separately."
    done
    if [[ $PUBLIC_IP != "$LOCAL_IP" ]]; then
        warn "NAT detected: forward all documented ports without remapping. Host-to-public-domain routing (hairpin NAT) and local TURN-to-Janus routing must work."
    fi
    local mem_kb
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    if (( mem_kb < 3800000 )); then warn 'Less than 4 GiB RAM. This is not a recommended size for Nextcloud plus group calling.'; fi
}

# Generate stable secrets once. A missing secret store on an installed host is fatal.
ensure_secrets() {
    if [[ -f $STATE_DIR/secrets.env ]]; then
        check_trusted_file "$STATE_DIR/secrets.env"
        # shellcheck source=/dev/null
        source "$STATE_DIR/secrets.env"
    else
        [[ ! -e $NC_DIR/config/config.php ]] || die 'Existing Nextcloud but no deployment secrets; restore secrets from backup.'
        DB_PASSWORD=$(openssl rand -hex 32)
        SIGNALING_SECRET=$(openssl rand -hex 32)
        INTERNAL_SECRET=$(openssl rand -hex 32)
        TURN_SECRET=$(openssl rand -hex 32)
        SESSION_HASH_KEY=$(openssl rand -hex 32)
        SESSION_BLOCK_KEY=$(openssl rand -hex 16)
        ADMIN_PASSWORD="Nc9-$(openssl rand -hex 16)"
        local var
        for var in DB_PASSWORD SIGNALING_SECRET INTERNAL_SECRET TURN_SECRET SESSION_HASH_KEY SESSION_BLOCK_KEY ADMIN_PASSWORD; do
            printf '%s=%q\n' "$var" "${!var}"
        done > "$STATE_DIR/secrets.env"
        chmod 600 "$STATE_DIR/secrets.env"
    fi
    local var
    for var in DB_PASSWORD SIGNALING_SECRET INTERNAL_SECRET TURN_SECRET SESSION_HASH_KEY; do
        [[ ${!var:-} =~ ^[a-f0-9]{64}$ ]] || die "Missing or invalid secret: $var"
    done
    [[ ${SESSION_BLOCK_KEY:-} =~ ^[a-f0-9]{32}$ && -n ${ADMIN_PASSWORD:-} ]] || die 'Invalid session/admin secret store.'
    if [[ ! -f $STATE_DIR/credentials.txt ]]; then
        {
            printf 'Nextcloud: https://%s\nAdministrator: %s\nInitial password: %s\n' "$NEXTCLOUD_DOMAIN" "$ADMIN_USER" "$ADMIN_PASSWORD"
            printf '\nInitial password is not reset on reruns. Change it after first login.\n'
            printf 'HPB URL: https://%s/standalone-signaling/\nHPB secret: %s\n' "$TALK_DOMAIN" "$SIGNALING_SECRET"
            printf 'TURN: %s:3478 (UDP/TCP); %s:5349 (TLS/TCP)\nTURN secret: %s\n' "$TURN_DOMAIN" "$TURN_DOMAIN" "$TURN_SECRET"
        } > "$STATE_DIR/credentials.txt"
        chmod 600 "$STATE_DIR/credentials.txt"
    fi
}

# Write protected RFC2136 credentials and get/reuse a publicly trusted certificate.
obtain_certificate() {
    install -d -m 700 /etc/letsencrypt
    if [[ ! -s $CREDENTIALS ]]; then
        [[ -n ${DNS_KEY_SECRET:-} ]] || die 'Missing DNS_KEY_SECRET.'
        write_file "$CREDENTIALS" 600 <<EOF
dns_rfc2136_server = $DNS_SERVER
dns_rfc2136_port = $DNS_PORT
dns_rfc2136_name = $DNS_KEY_NAME
dns_rfc2136_secret = $DNS_KEY_SECRET
dns_rfc2136_algorithm = $DNS_ALGORITHM
dns_rfc2136_sign_query = $DNS_SIGN_QUERY
EOF
    fi
    chmod 600 "$CREDENTIALS"
    unset DNS_KEY_SECRET
    local valid=1 domain
    local -a args=()
    while IFS= read -r domain; do
        args+=(-d "$domain")
        if [[ ! -s $CERT_DIR/cert.pem ]] || ! openssl x509 -in "$CERT_DIR/cert.pem" -noout -checkhost "$domain" >/dev/null 2>&1; then valid=0; fi
    done < <(printf '%s\n' "$NEXTCLOUD_DOMAIN" "$TALK_DOMAIN" "$TURN_DOMAIN" | sort -u)
    if (( valid )) && openssl x509 -in "$CERT_DIR/cert.pem" -noout -checkend 2592000 >/dev/null; then
        log 'Certificate already exists, covers all names and has more than 30 days remaining.'
    else
        certbot certonly --non-interactive --agree-tos --email "$EMAIL" \
            --server https://acme-v02.api.letsencrypt.org/directory \
            --authenticator dns-rfc2136 --dns-rfc2136-credentials "$CREDENTIALS" \
            --dns-rfc2136-propagation-seconds "$DNS_PROPAGATION_SECONDS" \
            --cert-name "$CERT_NAME" --keep-until-expiring "${args[@]}"
    fi
    [[ -s $CERT_DIR/fullchain.pem && -s $CERT_DIR/privkey.pem ]] || die 'Certificate files were not created.'
    systemctl enable --now certbot.timer
}

# Prepare MariaDB and a dedicated UTF-8 database; do not rotate existing passwords.
configure_database() {
    write_file /etc/mysql/mariadb.conf.d/60-nextcloud.cnf 644 <<'EOF'
[mysqld]
bind-address = 127.0.0.1
transaction-isolation = READ-COMMITTED
binlog_format = ROW
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
innodb_file_per_table = 1
max_allowed_packet = 64M
EOF
    ensure_service mariadb /etc/mysql/mariadb.conf.d/60-nextcloud.cnf
    if [[ ! -e $STATE_DIR/database-created && ! -e $NC_DIR/config/config.php ]]; then
        local tables
        tables=$(mariadb --protocol=socket -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='nextcloud';")
        [[ $tables == 0 ]] || die 'Database nextcloud has tables but is not managed by this deployment.'
    fi
    mariadb --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'nextcloud'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';
SQL
    touch "$STATE_DIR/database-created"
}

# Bind Redis to a Unix socket only and give PHP workers access through its group.
configure_redis() {
    usermod -a -G redis www-data
    write_file /etc/redis/redis.conf 640 redis redis <<'EOF'
bind 127.0.0.1
protected-mode yes
port 0
unixsocket /run/redis/redis-server.sock
unixsocketperm 770
timeout 0
tcp-keepalive 300
daemonize no
supervised systemd
pidfile /run/redis/redis-server.pid
loglevel notice
logfile ""
dir /var/lib/redis
save ""
appendonly no
EOF
    ensure_service redis-server /etc/redis/redis.conf
    redis-cli -s /run/redis/redis-server.sock ping | grep -qx PONG
}

# Configure the dedicated PHP 8.3 pool and consistent CLI/FPM settings.
configure_php() {
    local target
    for target in cli fpm; do
        write_file "/etc/php/8.3/$target/conf.d/99-nextcloud.ini" 644 <<'EOF'
memory_limit=512M
upload_max_filesize=10G
post_max_size=10G
max_execution_time=3600
max_input_time=3600
output_buffering=0
expose_php=Off
date.timezone=UTC
cgi.fix_pathinfo=1
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=100000
opcache.save_comments=1
opcache.revalidate_freq=60
apc.enable_cli=1
EOF
    done
    write_file /etc/php/8.3/fpm/pool.d/nextcloud.conf 644 <<EOF
[nextcloud]
user = www-data
group = www-data
listen = /run/php/php8.3-nextcloud.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = $PHP_MAX_CHILDREN
pm.process_idle_timeout = 20s
pm.max_requests = 500
request_terminate_timeout = 3600s
clear_env = yes
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp
catch_workers_output = yes
EOF
    php-fpm8.3 -t
    ensure_service php8.3-fpm /etc/php/8.3/fpm/conf.d/99-nextcloud.ini /etc/php/8.3/fpm/pool.d/nextcloud.conf
}

# Download one stable release in the selected major and verify its SHA-256 digest.
install_nextcloud_files() {
    install -d -m 750 -o www-data -g www-data /var/lib/nextcloud "$DATA_DIR"
    if [[ -f $NC_DIR/occ && -f $NC_DIR/version.php ]]; then
        log 'Nextcloud code already exists; no overwrite or automatic upgrade.'
        return
    fi
    [[ ! -e $NC_DIR ]] || die "$NC_DIR is incomplete; inspect it rather than overwriting it."
    local version=$NC_VERSION archive checksum url expected
    if [[ -z $version ]]; then
        curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
            --retry 3 --connect-timeout 20 --max-time 90 \
            https://download.nextcloud.com/server/releases/ -o "$WORK_DIR/releases.html"
        version=$(grep -oE "nextcloud-${NC_MAJOR}\\.[0-9]+\\.[0-9]+\\.tar\\.bz2" "$WORK_DIR/releases.html" \
            | sort -Vu | tail -n 1 | sed -E 's/^nextcloud-//; s/\.tar\.bz2$//')
    fi
    [[ $version =~ ^${NC_MAJOR}\.[0-9]+\.[0-9]+$ ]] || die 'Could not resolve a stable Nextcloud release.'
    archive="nextcloud-$version.tar.bz2"
    url="https://download.nextcloud.com/server/releases/$archive"
    checksum="$WORK_DIR/$archive.sha256"
    curl -fSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 20 --max-time 120 "$url.sha256" -o "$checksum"
    expected=$(awk 'NR==1 {print $1}' "$checksum")
    [[ $expected =~ ^[a-fA-F0-9]{64}$ ]] || die 'Invalid upstream SHA-256 file.'
    curl -fSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 20 --max-time 1800 "$url" -o "$WORK_DIR/$archive"
    printf '%s  %s\n' "$expected" "$WORK_DIR/$archive" | sha256sum -c -
    install -d -m 755 /var/www
    tar --extract --bzip2 --file "$WORK_DIR/$archive" --directory "$WORK_DIR" --no-same-owner
    [[ -f $WORK_DIR/nextcloud/occ ]] || die 'Invalid Nextcloud archive.'
    chown -R www-data:www-data "$WORK_DIR/nextcloud"
    mv "$WORK_DIR/nextcloud" "$NC_DIR"
    printf '%s\n' "$version" > "$STATE_DIR/installed-version.txt"
}

# Install an OCC stdin bridge so passwords are never exposed in process arguments.
install_occ_runner() {
    install -d -m 755 "$LIB_DIR"
    write_file "$LIB_DIR/occ-stdin.php" 644 <<'PHP'
<?php
declare(strict_types=1);
$raw = stream_get_contents(STDIN);
if ($raw === false || $raw === '') { fwrite(STDERR, "No OCC arguments on stdin\n"); exit(2); }
$args = explode("\0", $raw);
if (end($args) === '') { array_pop($args); }
$_SERVER['argv'] = array_merge(['occ'], $args);
$_SERVER['argc'] = count($_SERVER['argv']);
$argv = $_SERVER['argv'];
$argc = $_SERVER['argc'];
chdir('/var/www/nextcloud');
require '/var/www/nextcloud/console.php';
PHP
    write_file /usr/local/bin/nextcloud-occ 755 <<'EOF'
#!/bin/sh
# Administrative helper: sudo nextcloud-occ status --output=json
exec runuser -u www-data -- /usr/bin/php8.3 -d apc.enable_cli=1 /var/www/nextcloud/occ "$@"
EOF
    php8.3 -l "$LIB_DIR/occ-stdin.php"
}

# Invoke OCC as www-data, transporting arguments over stdin rather than argv.
occ() { printf '%s\0' "$@" | runuser -u www-data -- php8.3 -d apc.enable_cli=1 "$LIB_DIR/occ-stdin.php"; }

# Install Nextcloud once and set its HTTPS, cache, file-locking and cron options.
configure_nextcloud() {
    local installed=false
    if [[ -s $NC_DIR/config/config.php ]]; then
        installed=$(php8.3 -r 'include $argv[1]; echo !empty($CONFIG["installed"]) ? "true" : "false";' "$NC_DIR/config/config.php")
    fi
    if [[ $installed != true ]]; then
        occ maintenance:install --database mysql --database-host localhost --database-name nextcloud \
            --database-user nextcloud --database-pass "$DB_PASSWORD" \
            --admin-user "$ADMIN_USER" --admin-pass "$ADMIN_PASSWORD" --data-dir "$DATA_DIR" --no-interaction
    else
        log 'Nextcloud already installed; administrator password and data are preserved.'
    fi
    occ status --output=json | jq -e '.installed == true and .maintenance == false and .needsDbUpgrade == false' >/dev/null
    occ config:system:set trusted_domains 0 --value="$NEXTCLOUD_DOMAIN" >/dev/null
    occ config:system:set overwrite.cli.url --value="https://$NEXTCLOUD_DOMAIN" >/dev/null
    occ config:system:set overwriteprotocol --value=https >/dev/null
    occ config:system:set memcache.local --value='\OC\Memcache\APCu' >/dev/null
    # Set the socket before enabling Redis: every subsequent OCC call boots Nextcloud.
    occ config:system:set redis host --value=/run/redis/redis-server.sock >/dev/null
    occ config:system:set redis port --value=0 --type=integer >/dev/null
    occ config:system:set memcache.locking --value='\OC\Memcache\Redis' >/dev/null
    occ config:system:set memcache.distributed --value='\OC\Memcache\Redis' >/dev/null
    occ config:system:set maintenance_window_start --value=1 --type=integer >/dev/null
    occ config:system:set loglevel --value=2 --type=integer >/dev/null
    occ config:system:set log_rotate_size --value=104857600 --type=integer >/dev/null
    if [[ -n $DEFAULT_PHONE_REGION ]]; then occ config:system:set default_phone_region --value="$DEFAULT_PHONE_REGION" >/dev/null; fi
    occ background:cron
    chmod 640 "$NC_DIR/config/config.php"
}

# Generate the complete webroot config and the separate HPB WebSocket reverse proxy.
configure_nginx() {
    write_file /etc/nginx/snippets/nextcloud-security.conf 644 <<'EOF'
add_header Strict-Transport-Security "max-age=15552000" always;
add_header Referrer-Policy "no-referrer" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Permitted-Cross-Domain-Policies "none" always;
add_header X-Robots-Tag "noindex, nofollow" always;
EOF
    write_file /etc/nginx/sites-available/nextcloud-deploy.conf 644 <<EOF
map \$http_upgrade \$nc_connection_upgrade { default upgrade; '' close; }
map \$arg_v \$nc_asset_immutable { '' ''; default ', immutable'; }
server {
    listen 80;
    server_name $NEXTCLOUD_DOMAIN $TALK_DOMAIN;
    server_tokens off;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $NEXTCLOUD_DOMAIN;
    root $NC_DIR;
    server_tokens off;
    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:NCSSL:10m;
    ssl_session_tickets off;
    ssl_stapling off;
    ssl_stapling_verify off;
    include /etc/nginx/snippets/nextcloud-security.conf;
    client_max_body_size 10G;
    client_body_timeout 300s;
    client_body_buffer_size 512k;
    fastcgi_buffers 64 4k;
    fastcgi_hide_header X-Powered-By;
    gzip on;
    gzip_vary on;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_types text/css text/javascript application/javascript application/json application/wasm image/svg+xml;
    include /etc/nginx/mime.types;
    types { text/javascript mjs; }
    index index.php index.html /index.php\$request_uri;
    location = / {
        if (\$http_user_agent ~ ^DavClnt) { return 302 /remote.php/webdav/\$is_args\$args; }
    }
    location = /robots.txt { allow all; log_not_found off; access_log off; }
    location ^~ /.well-known {
        location = /.well-known/carddav { return 301 /remote.php/dav/; }
        location = /.well-known/caldav { return 301 /remote.php/dav/; }
        location /.well-known/acme-challenge { try_files \$uri \$uri/ =404; }
        location /.well-known/pki-validation { try_files \$uri \$uri/ =404; }
        return 301 /index.php\$request_uri;
    }
    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:\$|/) { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) { return 404; }
    location ~ ^/(?:composer\.(?:json|lock)|package(?:-lock)?\.json|core/shipped\.json)\$ { return 404; }
    location ~ \.php(?:\$|/) {
        rewrite ^/(?!index|remote|public|cron|status|ocs\\/v[12]|ocs-provider\\/.+|core\\/ajax\\/update|updater\\/.+|.+\\/richdocumentscode(_arm64)?\\/proxy) /index.php\$request_uri;
        fastcgi_split_path_info ^(.+?\.php)(/.*)\$;
        set \$path_info \$fastcgi_path_info;
        try_files \$fastcgi_script_name =404;
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$path_info;
        fastcgi_param HTTPS on;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass unix:/run/php/php8.3-nextcloud.sock;
        fastcgi_intercept_errors on;
        fastcgi_request_buffering on;
        fastcgi_read_timeout 3600s;
        fastcgi_send_timeout 3600s;
        fastcgi_max_temp_file_size 0;
    }
    location ~ \.(?:css|js|mjs|svg|gif|ico|jpg|jpeg|png|webp|wasm|tflite|map|ogg|flac|mp4|webm)\$ {
        try_files \$uri /index.php\$request_uri;
        add_header Cache-Control "public, max-age=15778463\$nc_asset_immutable";
        include /etc/nginx/snippets/nextcloud-security.conf;
        access_log off;
    }
    location ~ \.(?:otf|woff2?)\$ { try_files \$uri /index.php\$request_uri; expires 7d; access_log off; }
    location /remote { return 301 /remote.php\$request_uri; }
    location / { try_files \$uri \$uri/ /index.php\$request_uri; }
}
server {
    listen 443 ssl http2;
    server_name $TALK_DOMAIN;
    server_tokens off;
    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_tickets off;
    include /etc/nginx/snippets/nextcloud-security.conf;
    location = /standalone-signaling { return 301 /standalone-signaling/; }
    location ^~ /standalone-signaling/ {
        proxy_pass http://127.0.0.1:8081/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$nc_connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }
    location = / { return 302 /standalone-signaling/api/v1/welcome; }
    location / { return 404; }
}
EOF
    rm -f /etc/nginx/sites-enabled/default
    ln -sfn /etc/nginx/sites-available/nextcloud-deploy.conf /etc/nginx/sites-enabled/nextcloud-deploy.conf
    nginx -t
    ensure_service nginx /etc/nginx/sites-available/nextcloud-deploy.conf /etc/nginx/snippets/nextcloud-security.conf "$CERT_DIR/fullchain.pem"
}

# Install a safe renewal hook which gives coturn its own restricted certificate copies.
configure_certificate_renewal() {
    install -d -m 750 -o root -g turnserver /etc/coturn /etc/coturn/certs
    write_file /etc/letsencrypt/renewal-hooks/deploy/50-nextcloud-deploy 750 <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
lineage=/etc/letsencrypt/live/nextcloud-deploy
[[ ${RENEWED_LINEAGE:-$lineage} == "$lineage" ]] || exit 0
install -m 640 -o root -g turnserver "$lineage/fullchain.pem" /etc/coturn/certs/fullchain.pem.new
install -m 640 -o root -g turnserver "$lineage/privkey.pem" /etc/coturn/certs/privkey.pem.new
mv -f /etc/coturn/certs/fullchain.pem.new /etc/coturn/certs/fullchain.pem
mv -f /etc/coturn/certs/privkey.pem.new /etc/coturn/certs/privkey.pem
if systemctl is-active --quiet nginx; then nginx -t; systemctl reload nginx; fi
# Restart is intentional: no dependency on version-specific TLS reload behavior.
# Existing relayed calls can be interrupted once per certificate renewal.
if systemctl is-active --quiet coturn; then systemctl restart coturn; fi
EOF
    if [[ ! -f /etc/coturn/certs/fullchain.pem ]] || ! cmp -s "$CERT_DIR/fullchain.pem" /etc/coturn/certs/fullchain.pem; then
        /etc/letsencrypt/renewal-hooks/deploy/50-nextcloud-deploy
    fi
}

# Configure an authenticated IPv4 TURN relay, including TLS and bounded media ports.
configure_coturn() {
    local external=$PUBLIC_IP
    if [[ $PUBLIC_IP != "$LOCAL_IP" ]]; then external="$PUBLIC_IP/$LOCAL_IP"; fi
    write_file /etc/turnserver.conf 640 root turnserver <<EOF
listening-port=3478
tls-listening-port=5349
listening-ip=$LOCAL_IP
relay-ip=$LOCAL_IP
external-ip=$external
min-port=$TURN_MIN_PORT
max-port=$TURN_MAX_PORT
fingerprint
use-auth-secret
static-auth-secret=$TURN_SECRET
realm=$TURN_DOMAIN
server-name=$TURN_DOMAIN
cert=/etc/coturn/certs/fullchain.pem
pkey=/etc/coturn/certs/privkey.pem
no-tlsv1
no-tlsv1_1
no-dtls
no-tcp-relay
no-cli
no-multicast-peers
stale-nonce=600
user-quota=12
total-quota=1200
no-software-attribute
syslog
# Prevent relaying to sensitive/reserved networks. Our own Janus IPs are exceptions.
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=224.0.0.0-255.255.255.255
allowed-peer-ip=$LOCAL_IP
allowed-peer-ip=$PUBLIC_IP
EOF
    # The systemd unit in Ubuntu 24.04 does not require TURNSERVER_ENABLED.
    ensure_service coturn /etc/turnserver.conf /etc/coturn/certs/fullchain.pem /etc/coturn/certs/privkey.pem
}

# Build module-only directories so Janus cannot expose its demo/HTTP/admin modules.
link_janus_module() {
    local pattern=$1 target=$2 source
    source=$(dpkg -L janus | grep -E "/${pattern}\.so$" | head -n 1)
    [[ -f $source ]] || die "Janus package lacks module: $pattern"
    install -d -m 755 "$target"
    ln -sfn "$source" "$target/$(basename "$source")"
}

# Configure native NATS and Janus, with only the signaling API bound to loopback.
configure_media_backend() {
    systemctl disable --now janus.service nats-server.service >/dev/null 2>&1 || true
    if ! id nextcloud-media >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin nextcloud-media
    fi
    install -d -m 750 -o root -g nextcloud-media /etc/nextcloud-janus
    install -d -m 750 -o nextcloud-media -g nextcloud-media /var/lib/nextcloud-janus
    link_janus_module libjanus_videoroom /usr/local/lib/nextcloud-janus/plugins
    link_janus_module libjanus_websockets /usr/local/lib/nextcloud-janus/transports
    link_janus_module libjanus_wsevh /usr/local/lib/nextcloud-janus/events
    write_file /etc/nextcloud-janus/janus.jcfg 640 root nextcloud-media <<EOF
general: {
    configs_folder = "/etc/nextcloud-janus"
    plugins_folder = "/usr/local/lib/nextcloud-janus/plugins"
    transports_folder = "/usr/local/lib/nextcloud-janus/transports"
    events_folder = "/usr/local/lib/nextcloud-janus/events"
    log_to_stdout = true
    debug_level = 4
    debug_timestamps = true
    debug_colors = false
}
media: {
    rtp_port_range = "$JANUS_MIN_PORT-$JANUS_MAX_PORT"
    ipv6 = false
}
nat: {
    nat_1_1_mapping = "$PUBLIC_IP"
    keep_private_host = true
    ice_enforce_list = "$LOCAL_IP"
    ice_tcp = false
}
events: {
    broadcast = true
}
EOF
    write_file /etc/nextcloud-janus/janus.transport.websockets.jcfg 640 root nextcloud-media <<'EOF'
general: {
    json = "compact"
    ws = true
    ws_ip = "127.0.0.1"
    ws_port = 8188
    wss = false
}
admin: { admin_ws = false; admin_wss = false; }
EOF
    write_file /etc/nextcloud-janus/janus.plugin.videoroom.jcfg 640 root nextcloud-media <<'EOF'
general: { }
EOF
    write_file /etc/nextcloud-janus/janus.eventhandler.wsevh.jcfg 640 root nextcloud-media <<'EOF'
general: {
    enabled = true
    events = "handles,media,webrtc"
    grouping = true
    json = "compact"
    backend = "ws://127.0.0.1:8081/spreed"
    subprotocol = "janus-events"
    events_cap_on_reconnect = 1000
}
EOF
    local nats_binary
    nats_binary=$(command -v nats-server)
    write_file /etc/nextcloud-nats.conf 644 <<'EOF'
listen: 127.0.0.1:4222
max_payload: 8388608
write_deadline: "10s"
EOF
    write_file /etc/systemd/system/nextcloud-nats.service 644 <<EOF
[Unit]
Description=NATS for Nextcloud Talk
After=network.target
[Service]
Type=simple
User=nextcloud-media
Group=nextcloud-media
ExecStart=$nats_binary --config /etc/nextcloud-nats.conf
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
[Install]
WantedBy=multi-user.target
EOF
    write_file /etc/systemd/system/nextcloud-janus.service 644 <<'EOF'
[Unit]
Description=Janus media gateway for Nextcloud Talk
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
User=nextcloud-media
Group=nextcloud-media
WorkingDirectory=/var/lib/nextcloud-janus
ExecStart=/usr/bin/janus --configs-folder=/etc/nextcloud-janus --disable-colors
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    ensure_service nextcloud-nats /etc/nextcloud-nats.conf /etc/systemd/system/nextcloud-nats.service
    ensure_service nextcloud-janus /etc/nextcloud-janus/*.jcfg /etc/systemd/system/nextcloud-janus.service
}

# Start the official standalone signaling image with a fixed local configuration.
configure_hpb() {
    systemctl enable --now docker
    write_file "$STATE_DIR/signaling.conf" 640 root 850 <<EOF
[http]
listen = 127.0.0.1:8081
[app]
debug = false
trustedproxies = 127.0.0.1
[sessions]
hashkey = $SESSION_HASH_KEY
blockkey = $SESSION_BLOCK_KEY
[clients]
internalsecret = $INTERNAL_SECRET
[backend]
backends = nextcloud
allowall = false
timeout = 10
connectionsperhost = 32
skipverify = false
[nextcloud]
urls = https://$NEXTCLOUD_DOMAIN
secret = $SIGNALING_SECRET
[nats]
url = nats://127.0.0.1:4222
[mcu]
type = janus
url = ws://127.0.0.1:8188
maxstreambitrate = 1048576
maxscreenbitrate = 2097152
EOF
    local image_id fingerprint existing_label existing_hash
    if [[ -s $STATE_DIR/hpb-image-id ]]; then
        image_id=$(cat "$STATE_DIR/hpb-image-id")
        docker image inspect "$image_id" >/dev/null 2>&1 || die 'Pinned HPB image is missing. Restore/pull the recorded digest from hpb-image-digest.txt before rerunning.'
    else
        docker pull "$HPB_IMAGE"
        image_id=$(docker image inspect --format '{{.Id}}' "$HPB_IMAGE")
        printf '%s\n' "$image_id" > "$STATE_DIR/hpb-image-id"
        docker image inspect --format '{{join .RepoDigests "\n"}}' "$HPB_IMAGE" > "$STATE_DIR/hpb-image-digest.txt"
    fi
    fingerprint=$( { sha256sum "$STATE_DIR/signaling.conf"; printf '%s\n' "$image_id" "$NEXTCLOUD_DOMAIN" 'container-v1'; } | sha256sum | cut -d ' ' -f 1)
    if docker container inspect "$HPB_NAME" >/dev/null 2>&1; then
        existing_label=$(docker inspect --format '{{index .Config.Labels "org.nextcloud-deploy.managed"}}' "$HPB_NAME")
        [[ $existing_label == true ]] || die "Container $HPB_NAME belongs to another deployment."
        existing_hash=$(docker inspect --format '{{index .Config.Labels "org.nextcloud-deploy.config"}}' "$HPB_NAME")
        if [[ $fingerprint == "$existing_hash" ]]; then
            docker start "$HPB_NAME" >/dev/null
            log 'HPB container configuration unchanged.'
            return
        fi
        warn 'HPB configuration changed; recreating its stateless container may interrupt calls.'
        docker rm -f "$HPB_NAME" >/dev/null
    fi
    docker run -d --name "$HPB_NAME" --restart unless-stopped \
        --network host --user 850:850 --read-only --cap-drop ALL \
        --security-opt no-new-privileges:true --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
        --add-host "$NEXTCLOUD_DOMAIN:127.0.0.1" \
        --mount "type=bind,src=$STATE_DIR/signaling.conf,dst=/config/server.conf,readonly" \
        --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
        --label org.nextcloud-deploy.managed=true --label "org.nextcloud-deploy.config=$fingerprint" \
        --entrypoint /usr/bin/nextcloud-spreed-signaling "$image_id" --config /config/server.conf >/dev/null
}

# Install and configure the compatible Talk app via supported OCC commands.
configure_talk() {
    local apps signaling turn stun url count current_secret scheme port protocols entry
    apps=$(occ app:list --output=json)
    if jq -e '.enabled.spreed // .disabled.spreed' <<< "$apps" >/dev/null; then
        occ app:enable spreed
    else
        occ app:install spreed --no-interaction
    fi
    # Use the supported JSON list commands: current Talk also stores typed arrays.
    # Adding a signaling endpoint APPENDS; delete that URL first when repairing it.
    url="https://$TALK_DOMAIN/standalone-signaling/"
    signaling=$(occ talk:signaling:list --output=json)
    current_secret=$(jq -r 'if type == "object" then .secret // "" else "" end' <<< "$signaling")
    entry=$(jq -c --arg url "$url" '[. | objects | .servers[]? | select(.server == $url)]' <<< "$signaling")
    count=$(jq 'length' <<< "$entry")
    if [[ $count != 1 || $(jq -r '.[0].verify // false' <<< "$entry") != true || $current_secret != "$SIGNALING_SECRET" ]]; then
        occ talk:signaling:delete "$url" >/dev/null
        occ talk:signaling:add --verify "$url" "$SIGNALING_SECRET" >/dev/null
    fi
    for scheme in turn turns; do
        if [[ $scheme == turn ]]; then port=3478; protocols=udp,tcp; else port=5349; protocols=tcp; fi
        turn=$(occ talk:turn:list --output=json)
        entry=$(jq -c --arg server "$TURN_DOMAIN:$port" --arg scheme "$scheme" --arg protocols "$protocols" \
            '[.[]? | select(.server == $server and .schemes == $scheme and .protocols == $protocols)]' <<< "$turn")
        count=$(jq 'length' <<< "$entry")
        current_secret=$(jq -r '.[0].secret // ""' <<< "$entry")
        if [[ $count != 1 || $current_secret != "$TURN_SECRET" ]]; then
            occ talk:turn:delete "$scheme" "$TURN_DOMAIN:$port" "$protocols" >/dev/null
            occ talk:turn:add --secret "$TURN_SECRET" "$scheme" "$TURN_DOMAIN:$port" "$protocols" >/dev/null
        fi
    done
    stun=$(occ talk:stun:list --output=json)
    if ! jq -e --arg server "$TURN_DOMAIN:3478" 'index($server) != null' <<< "$stun" >/dev/null; then
        occ talk:stun:add "$TURN_DOMAIN:3478" >/dev/null
    fi
}

# Schedule Nextcloud's background work using systemd instead of web/AJAX jobs.
configure_background_jobs() {
    write_file /etc/systemd/system/nextcloud-cron.service 644 <<'EOF'
[Unit]
Description=Nextcloud background jobs
After=mariadb.service redis-server.service
[Service]
Type=oneshot
User=www-data
Group=www-data
ExecStart=/usr/bin/php8.3 -d apc.enable_cli=1 -f /var/www/nextcloud/cron.php
TimeoutStartSec=3600
Nice=10
EOF
    write_file /etc/systemd/system/nextcloud-cron.timer 644 <<'EOF'
[Unit]
Description=Run Nextcloud background jobs every five minutes
[Timer]
OnCalendar=*-*-* *:0/5:00
RandomizedDelaySec=20
Persistent=true
[Install]
WantedBy=timers.target
EOF
    write_file /etc/logrotate.d/nextcloud-deploy 644 <<'EOF'
/var/log/nextcloud-deploy.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
    create 0600 root root
}
EOF
    systemctl daemon-reload
    systemctl enable --now nextcloud-cron.timer
    systemctl start nextcloud-cron.service
}

# Add firewall rules, preserve discovered SSH listeners, and never reset existing rules.
configure_firewall() {
    if [[ $MANAGE_UFW == 0 ]]; then
        warn 'UFW management disabled. Configure host and provider firewalls according to README.md.'
        return
    fi
    local -a ssh_ports=()
    local port
    if [[ -n $SSH_PORT ]]; then ssh_ports+=("$SSH_PORT"); fi
    if [[ -x /usr/sbin/sshd ]]; then
        while read -r port; do
            [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ssh_ports+=("$port")
        done < <(/usr/sbin/sshd -T 2>/dev/null | awk '$1=="port" {print $2}')
    fi
    # Preserve ports owned by OpenSSH's systemd socket, even when sshd is idle.
    while read -r port; do
        [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ssh_ports+=("$port")
    done < <(systemctl show ssh.socket --property=Listen --value 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i ~ /:[0-9]+$/) {n=split($i,a,":"); print a[n]}}')
    # Covers custom SSH listeners and the current SSH connection.
    while read -r port; do
        [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ssh_ports+=("$port")
    done < <(ss -Hltnp | awk '/sshd/ {n=split($4,a,":"); print a[n]}')
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        port=${SSH_CONNECTION##* }
        [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ssh_ports+=("$port")
    fi
    if (( ${#ssh_ports[@]} == 0 )); then
        die 'Cannot determine SSH port safely. Set SSH_PORT in the saved settings or use MANAGE_UFW=0.'
    fi
    for port in "${ssh_ports[@]}"; do ufw allow "$port/tcp" comment 'Preserve SSH'; done
    ufw allow 80/tcp comment 'Nextcloud HTTPS redirect'
    ufw allow 443/tcp comment 'Nextcloud and Talk signaling'
    ufw allow 3478/tcp comment 'Talk TURN TCP'
    ufw allow 3478/udp comment 'Talk TURN UDP and STUN'
    ufw allow 5349/tcp comment 'Talk TURN TLS'
    ufw allow "$JANUS_MIN_PORT:$JANUS_MAX_PORT/udp" comment 'Talk Janus media'
    ufw allow "$TURN_MIN_PORT:$TURN_MAX_PORT/udp" comment 'Talk TURN relay media'
    if ! ufw status | grep -q '^Status: active'; then
        ufw default deny incoming
        ufw default allow outgoing
        ufw --force enable
    fi
    ufw status
}

# Wait for the signaling welcome endpoint without suppressing the final failure.
wait_for_hpb() {
    local i
    for i in {1..45}; do
        if curl -fsS --max-time 3 http://127.0.0.1:8081/api/v1/welcome > "$WORK_DIR/hpb-welcome.json" 2>/dev/null \
            && jq -e 'has("nextcloud-spreed-signaling")' "$WORK_DIR/hpb-welcome.json" >/dev/null; then
            return
        fi
        sleep 2
    done
    die "HPB did not start; inspect: sudo docker logs --tail 100 $HPB_NAME"
}

# Check service status, real TLS, WebSocket upgrades, Janus and authenticated TURN.
verify_installation() {
    nginx -t
    systemctl reload nginx
    local service
    for service in nginx php8.3-fpm mariadb redis-server coturn docker nextcloud-nats nextcloud-janus certbot.timer nextcloud-cron.timer; do
        systemctl is-active --quiet "$service" || die "Service is not active: $service"
        log "OK service: $service"
    done
    [[ $(docker inspect --format '{{.State.Running}}' "$HPB_NAME") == true ]] || die 'HPB container is not running.'
    wait_for_hpb
    curl -fsS --max-time 30 --resolve "$NEXTCLOUD_DOMAIN:443:127.0.0.1" "https://$NEXTCLOUD_DOMAIN/status.php" \
        | jq -e '.installed == true and .maintenance == false and .needsDbUpgrade == false' >/dev/null
    curl -fsS --max-time 30 --resolve "$TALK_DOMAIN:443:127.0.0.1" "https://$TALK_DOMAIN/standalone-signaling/api/v1/welcome" \
        | jq -e 'has("nextcloud-spreed-signaling")' >/dev/null
    # No --resolve here: the host must reach the advertised URL using real DNS.
    curl -fsS --max-time 30 "https://$TALK_DOMAIN/standalone-signaling/api/v1/welcome" \
        | jq -e 'has("nextcloud-spreed-signaling")' >/dev/null
    python3 "$LIB_DIR/probe.py" websocket "$TALK_DOMAIN" "$NEXTCLOUD_DOMAIN"
    python3 "$LIB_DIR/probe.py" janus
    printf '%s' "$TURN_SECRET" | python3 "$LIB_DIR/probe.py" turn "$LOCAL_IP" "$TURN_DOMAIN"
    occ app:list --output=json | jq -e '.enabled.spreed' >/dev/null
    occ status
    log 'OK: local HTTPS, advertised HPB URL, WebSocket, Janus VideoRoom, and TURN allocations.'
    warn 'A local allocation check is not an external media test. Test a two-user call across two different networks.'
}

# Print URLs and secret locations, but never print passwords into the deployment log.
print_summary() {
    log 'DEPLOYMENT COMPLETED; server-side checks passed.'
    printf '\nNextcloud: https://%s\nTalk application: https://%s/apps/spreed/\n' "$NEXTCLOUD_DOMAIN" "$NEXTCLOUD_DOMAIN"
    printf 'HPB: https://%s/standalone-signaling/\n' "$TALK_DOMAIN"
    printf 'TURN: %s:3478 UDP/TCP; %s:5349 TLS/TCP\n' "$TURN_DOMAIN" "$TURN_DOMAIN"
    printf 'Administrator credentials: sudo cat %s/credentials.txt\n' "$STATE_DIR"
    printf 'Deployment log: %s\nNextcloud log: %s/nextcloud.log\n' "$LOG_FILE" "$DATA_DIR"
    printf 'Settings/secrets: %s (keep a protected backup)\n' "$STATE_DIR"
    printf 'Warnings/remaining checks: %s. See README.md; test a real call before production use.\n' "$WARNINGS"
}

# Install self-contained verification helpers; only standard Python + distro websocket.
install_probe() {
    write_file "$LIB_DIR/probe.py" 644 <<'PY'
#!/usr/bin/env python3
"""Non-destructive local WebSocket, Janus and TURN Allocate/Refresh checks."""
import base64
import hashlib
import hmac
import json
import os
import socket
import ssl
import struct
import sys
import time

COOKIE = 0x2112A442


def attribute(kind, value):
    return struct.pack('!HH', kind, len(value)) + value + b'\0' * ((-len(value)) % 4)


def packet(kind, attrs, key=None):
    txid = os.urandom(12)
    body = b''.join(attrs)
    size = len(body) + (24 if key is not None else 0)
    head = struct.pack('!HHI12s', kind, size, COOKIE, txid)
    if key is not None:
        body += attribute(0x0008, hmac.new(key, head + body, hashlib.sha1).digest())
    return head + body, txid


def read_exact(sock, length):
    data = bytearray()
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise RuntimeError('Connection closed during a STUN response')
        data.extend(part)
    return bytes(data)


def exchange(sock, datagram, kind, attrs, key=None):
    request, txid = packet(kind, attrs, key)
    sock.sendall(request)
    if datagram:
        data = sock.recv(65535)
    else:
        head = read_exact(sock, 20)
        data = head + read_exact(sock, struct.unpack('!H', head[2:4])[0])
    if len(data) < 20:
        raise RuntimeError('Truncated STUN response')
    response, length, cookie, response_id = struct.unpack('!HHI12s', data[:20])
    if cookie != COOKIE or response_id != txid or len(data) != 20 + length:
        raise RuntimeError('Unexpected STUN transaction/length')
    result = {}
    pos = 20
    while pos + 4 <= len(data):
        attr_type, attr_len = struct.unpack('!HH', data[pos:pos + 4])
        end = pos + 4 + attr_len
        if end > len(data):
            raise RuntimeError('Invalid STUN attribute length')
        result[attr_type] = data[pos + 4:end]
        pos = end + ((-attr_len) % 4)
    return response, result


def turn_one(ip, domain, secret, mode):
    datagram = mode == 'udp'
    port = 5349 if mode == 'tls' else 3478
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM if datagram else socket.SOCK_STREAM)
    sock.settimeout(10)
    try:
        sock.connect((ip, port))
        if mode == 'tls':
            sock = ssl.create_default_context().wrap_socket(sock, server_hostname=domain)
        requested = [attribute(0x0019, b'\x11\0\0\0')]
        response, challenge = exchange(sock, datagram, 0x0003, requested)
        error = challenge.get(0x0009, b'')
        if response != 0x0113 or len(error) < 4 or error[2] * 100 + error[3] != 401:
            raise RuntimeError('TURN must reject an unauthenticated Allocate with 401')
        realm, nonce = challenge[0x0014], challenge[0x0015]
        user = f'{int(time.time()) + 600}:deploy-check'.encode()
        password = base64.b64encode(hmac.new(secret.encode(), user, hashlib.sha1).digest())
        key = hashlib.md5(user + b':' + realm + b':' + password).digest()
        auth = [attribute(0x0006, user), attribute(0x0014, realm), attribute(0x0015, nonce)]
        response, result = exchange(sock, datagram, 0x0003,
            requested + [attribute(0x000D, struct.pack('!I', 60))] + auth, key)
        if response != 0x0103 or 0x0016 not in result:
            raise RuntimeError(f'Authenticated TURN allocation failed ({response:#x})')
        relay = result[0x0016]
        if len(relay) < 8 or relay[1] != 1:
            raise RuntimeError('Expected an IPv4 TURN relay address')
        relay_port = struct.unpack('!H', relay[2:4])[0] ^ (COOKIE >> 16)
        relay_ip = socket.inet_ntoa(bytes(a ^ b for a, b in zip(relay[4:8], struct.pack('!I', COOKIE))))
        # Release the allocation immediately instead of leaving a test session behind.
        response, _ = exchange(sock, datagram, 0x0004,
            [attribute(0x000D, struct.pack('!I', 0))] + auth, key)
        if response != 0x0104:
            raise RuntimeError('TURN allocation succeeded but cleanup failed')
        print(f'OK TURN {mode}: authenticated allocation at {relay_ip}:{relay_port}; released')
    finally:
        sock.close()


def websocket_check(domain, origin_domain):
    # This intentionally checks the public advertised name, with certificate validation.
    import websocket
    conn = websocket.create_connection(
        f'wss://{domain}/standalone-signaling/spreed', timeout=12,
        origin=f'https://{origin_domain}', sslopt={'cert_reqs': ssl.CERT_REQUIRED},
    )
    conn.close()
    print('OK HPB: HTTPS WebSocket upgrade')


def janus_check():
    import websocket
    conn = websocket.create_connection('ws://127.0.0.1:8188', timeout=10,
        subprotocols=['janus-protocol'], http_no_proxy=['127.0.0.1', 'localhost'])
    try:
        conn.send(json.dumps({'janus': 'info', 'transaction': 'deploy-check'}))
        info = json.loads(conn.recv())
        if info.get('janus') != 'server_info' or 'janus.plugin.videoroom' not in info.get('plugins', {}):
            raise RuntimeError('Janus VideoRoom plugin is unavailable')
    finally:
        conn.close()
    print('OK Janus: WebSocket API and VideoRoom plugin')


def main():
    mode = sys.argv[1]
    if mode == 'websocket':
        websocket_check(sys.argv[2], sys.argv[3])
    elif mode == 'janus':
        janus_check()
    elif mode == 'turn':
        secret = sys.stdin.read().strip()
        if not secret:
            raise RuntimeError('TURN secret must be supplied on stdin')
        for transport in ('udp', 'tcp', 'tls'):
            turn_one(sys.argv[2], sys.argv[3], secret, transport)
    else:
        raise RuntimeError('Unknown probe')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'CHECK FAILED: {exc}', file=sys.stderr)
        sys.exit(1)
PY
}

# Perform an ordered, resumable deployment. No destructive database/data operations.
main() {
    bootstrap
    run_step load_configuration "$@"
    run_step validate_configuration
    run_step save_configuration
    run_step install_packages
    run_step check_network
    run_step ensure_secrets
    run_step obtain_certificate
    run_step configure_database
    run_step configure_redis
    run_step configure_php
    run_step install_nextcloud_files
    run_step install_occ_runner
    run_step configure_nextcloud
    run_step configure_nginx
    run_step configure_certificate_renewal
    run_step configure_coturn
    run_step configure_media_backend
    run_step configure_hpb
    run_step configure_talk
    run_step configure_background_jobs
    run_step configure_firewall
    run_step install_probe
    run_step verify_installation
    run_step print_summary
}

# Sourcing is supported solely for isolated lint/unit tests; it does not deploy.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
