# Nextcloud + Nginx + RFC2136 certificates + Talk

Prepared 2026-10-12. Target: a **dedicated, clean Ubuntu Server 24.04**, amd64 or arm64, booted with systemd. This is a self-contained installation script, not a pre-tested appliance, an upgrade utility, or an adoption/migration tool for an existing server.

## Start

Copy `deploy-nextcloud.sh` to your server, review it, and run:

```bash
sudo bash deploy-nextcloud.sh
```

The installer asks for Nextcloud and Talk DNS names, email, public IPv4, and existing RFC2136/TSIG credentials. The TSIG secret is entered without terminal echo. The server interface IPv4 is auto-detected. Prompts and operational logs are in English.

For a noninteractive installation, use the supplied example:

```bash
sudo install -o root -g root -m 600 nextcloud.env.example /root/nextcloud.env
sudo nano /root/nextcloud.env
sudo bash deploy-nextcloud.sh --config /root/nextcloud.env
```

Replace **all** example domains, IP addresses and the TSIG secret. `203.0.113.10` is a documentation address, not a usable public IP; the installer deliberately rejects it. The input file is sourced as trusted Bash code and must be root-owned with no group/other access. Never run the installer with `bash -x`: tracing can expose secrets.

Before enabling UFW, the script preserves the configured `SSH_PORT`, detected SSH listeners and the current SSH connection where available. Still set `SSH_PORT` explicitly for nonstandard SSH, and retain provider-console access during installation. To keep firewall management external, set `MANAGE_UFW=0` in the input file.

## What is installed

| Component | Placement / purpose |
|---|---|
| Nginx | Native Ubuntu package; HTTPS Nextcloud site and separate Talk reverse proxy |
| PHP 8.3-FPM | Dedicated Nextcloud pool with APCu and OPcache |
| MariaDB | Native package; database `nextcloud`, local access only |
| Redis | Unix socket only; Nextcloud cache and transactional file locking |
| Nextcloud | `/var/www/nextcloud`; stable patch in major 35 by default |
| Nextcloud data | `/var/lib/nextcloud/data`, outside the web root |
| Talk (`spreed`) | Installed from the Nextcloud app store and configured through OCC |
| Standalone signaling | Official `strukturag/nextcloud-spreed-signaling:2.1.1` container, named `nextcloud-talk-hpb` |
| Janus | Native package; VideoRoom, WebSocket transport and WebSocket event handler only |
| NATS | Native package; loopback-only service for signaling |
| coturn | Native package; authenticated STUN/TURN, including TLS |
| Certbot RFC2136 plugin | ACME DNS-01 validation against your authoritative DNS server |

The HPB consists of the signaling container **plus** native Janus and NATS; the image is not Nextcloud AIO. Only signaling runs in Docker. Its HTTP listener is `127.0.0.1:8081`, Janus WebSocket API is `127.0.0.1:8188`, and NATS is `127.0.0.1:4222`. None should be exposed publicly.

Nginx advertises `https://TALK_DOMAIN/standalone-signaling/` and preserves WebSocket upgrades. The signaling container resolves the Nextcloud domain to host loopback so backend HTTPS does not depend on NAT reflection; certificate validation remains enabled. Nextcloud obtains Talk signaling, STUN and TURN settings automatically; you do not need to copy shared secrets into the admin UI after a successful run.

For initial capacity planning, start with 4 vCPU and 8 GiB RAM for a small installation, then measure real concurrency, storage and bandwidth. This is a planning assumption, not a supported-concurrency guarantee. The bounded media port ranges are intentionally modest and are not a sizing formula.

## DNS and TSIG prerequisites

For the usual two-name layout, create public DNS records:

```text
cloud.example.com.  A  YOUR_PUBLIC_IPV4
talk.example.com.   A  YOUR_PUBLIC_IPV4
```

Use DNS-only records, not a CDN/reverse-proxy mode. This implementation is **IPv4-only**: remove AAAA records for these names or extend the deployment for IPv6 separately. When `TURN_DOMAIN` differs, create its public A record too. The script checks that each name has exactly the configured public IPv4.

Your DNS administrator must already provide an RFC2136-capable authoritative update endpoint and a TSIG key authorized to create and delete the public ACME TXT records. The installer does not take over or reconfigure an external DNS server. DNS-01 does not require an inbound HTTP challenge; port 80 is used only for normal HTTPS redirects in this deployment.

For BIND, the following is a **zone-policy fragment**, not a replacement for your whole BIND configuration:

```bind
update-policy {
    grant nextcloud-acme. name _acme-challenge.cloud.example.com. TXT;
    grant nextcloud-acme. name _acme-challenge.talk.example.com. TXT;
};
```

The matching key declaration must exist on that DNS server, with exactly the same key name, secret and algorithm. A separate TURN name needs one more corresponding TXT rule. Limit permissions to these exact challenge names rather than granting zone-wide updates. For names in different zones, apply permissions in each relevant zone. The DNS update endpoint must answer authoritatively for the public validation view, and secondary servers must receive updates before the propagation wait expires. DNSSEC errors or restrictive CAA policy can also prevent issuance.

RFC2136 credentials are stored in `/etc/letsencrypt/rfc2136.ini`, mode 600. They are retained because unattended renewal needs them. ACME is directed to the production Let's Encrypt endpoint, not a staging CA. A valid existing certificate with all names and more than 30 days remaining is reused.

## Firewall and NAT

Open these **inbound** ports at the provider/security-group firewall as well as on the server:

| Port | Protocol | Purpose |
|---|---|---|
| Your actual SSH port | TCP | Administration |
| 80 | TCP | HTTP-to-HTTPS redirect |
| 443 | TCP | Nextcloud and Talk signaling/WebSocket |
| 3478 | UDP and TCP | STUN / TURN |
| 5349 | TCP | TURN over TLS |
| 20000-20199 | UDP | Janus WebRTC media, configurable |
| 49160-49259 | UDP | TURN relay allocation range, configurable |

UFW rules are added without `ufw reset`; existing rules are not removed. Provider firewalls and routers cannot be configured by this script. Outbound DNS, HTTPS, package repositories, the Docker registry, RFC2136 updates to `DNS_SERVER:DNS_PORT`, and media traffic must be permitted.

A directly assigned static public IPv4 is the simplest deployment. For port-preserving 1:1 NAT, set `PUBLIC_IP` to the public address and `LOCAL_IP` to the address actually on the Ubuntu interface. Forward every listed public port/range to the same internal port/range. Both advertised-domain access from the host and TURN-to-Janus media routing must work. Hairpin NAT may be required; correct split DNS can resolve the HTTPS part but is not itself a fix for media reflection. CGNAT without inbound forwarding is not supported.

**A network that permits only outbound TCP 443 is not covered by TURN on 3478/5349.** For that case, deploy TURN/TLS on TCP 443 using a separate public IP or a separate server and adjust Talk's TURN settings. On the present single-IP layout, Nginx owns TCP 443. Merely creating another DNS name does not provide another TCP listener on that IP and port. Do not interpret a successful local check as a guarantee for every corporate firewall.

## Completion and acceptance checks

Initial credentials are never intentionally printed into the deployment log. Read them locally:

```bash
sudo cat /etc/nextcloud-deploy/credentials.txt
sudo nextcloud-occ status
sudo systemctl status nginx php8.3-fpm mariadb redis-server coturn \
    nextcloud-nats nextcloud-janus --no-pager
sudo docker logs --tail 100 nextcloud-talk-hpb
```

Log in at the configured Nextcloud HTTPS address with the generated administrator account and change its initial password. Open Administration settings -> Talk, confirm the high-performance backend status, and inspect the configured TURN servers.

The installer validates service states, Nextcloud HTTPS status, the advertised HPB welcome URL, the public-name WebSocket upgrade, the Janus VideoRoom API, and authenticated TURN Allocate/Refresh operations over UDP, TCP and TLS. It also checks that an unauthenticated TURN allocation is rejected. These checks do **not** transmit browser audio/video and do not prove external reachability of every UDP media port.

Before accepting the installation, create two users and a Talk conversation. Test text chat, two-way audio, two-way video and screen sharing with one device on fixed Internet and one on mobile data. Repeat with a third participant for a group call. Use an isolated Firefox test profile with `media.peerconnection.ice.relay_only=true` to exercise a relay-only path, then revert the setting. Check both transmitted and received media; merely entering a room is not enough. When diagnosing a relay failure, inspect provider firewall/NAT rules and coturn/Janus logs before weakening TLS or firewall security.

SMTP is not configured because no mail-provider credentials were supplied. Configure it separately before relying on invitation emails or email password resets. This installation does not include call recording, SIP/PSTN integration, an Office server or high availability.

## Reruns, failures and maintenance

Rerun the same command after resolving a failure. The installer stores settings in `/etc/nextcloud-deploy/settings.env` and reuses secrets from `/etc/nextcloud-deploy/secrets.env`. For an existing deployment, saved settings take precedence over `--config`; the input file is only consulted for a missing TSIG secret when a first run failed before certificate credentials were written. Edit saved settings deliberately when correcting an incomplete deployment. Host/domain migrations need a separate procedure.

Existing Nextcloud code is not overwritten, administrator passwords are not reset, and application data is not deleted. Repeated Talk configuration avoids endpoint duplicates and repairs changed managed secrets or disabled TLS verification. Managed configuration files are reconciled; custom edits in those files can be overwritten. The first version of an overwritten file is retained under `/etc/nextcloud-deploy/backups/`. This is **not** a full system backup or transactional rollback.

A failing step is reported with its function name and log location:

```bash
sudo tail -n 100 /var/log/nextcloud-deploy.log
sudo journalctl -u coturn -u nextcloud-janus -u nextcloud-nats -n 150 --no-pager
```

The Nextcloud archive is verified against the SHA-256 file fetched over HTTPS from the official release server. The initially selected HPB image ID and repository digest are saved in the state directory; reruns reuse that image instead of silently pulling a different one. These choices improve repeatability, but **do not provide automatic application/container security updates**. OS package installation on a rerun may install newer distribution package versions.

Schedule application and container updates separately, with a backup and a maintenance window. Protect backups of the Nextcloud database, data, application/config directories, deployment state, DNS credentials and certificates, and test restoration. Do not delete `secrets.env` to regenerate passwords for an installed instance.

Certificate renewal is scheduled with `certbot.timer`. Validate renewal after initial deployment:

```bash
sudo certbot renew --dry-run
sudo systemctl list-timers certbot.timer nextcloud-cron.timer --no-pager
```

A deploy hook copies renewed certificate material into `/etc/coturn/certs/` with restrictive permissions, reloads Nginx and restarts coturn. **That coturn restart can interrupt calls currently using the relay**. Monitor certificate expiry and renewal errors; a timer alone does not prove a successful future renewal.

## Test scope for this delivery

See `TEST-REPORT.md`. Ten isolated tests passed: Bash and embedded-language syntax, generated Nginx configuration, Janus libconfig syntax, signaling settings, input validation, atomic/private writes, secret reuse, Talk setup/repeat/repair with mocked OCC, STUN packet/response handling, and Redis/listener checks.

The delivery environment was Debian 13 with Nginx 1.26.3 and PHP 8.4.24, **not** a booted Ubuntu 24.04 host with real DNS credentials and Docker. Package installation, Docker image pull/runtime, real ACME issuance/renewal, native daemon compatibility, full Nextcloud installation, and external browser calls were not executed here. No claim of production acceptance or universal network compatibility is made.

To rerun the isolated tests where their dependencies are installed:

```bash
sudo python3 tests/run-tests.py
```

## Primary references

The architecture and configuration were reviewed against these primary sources on 2026-10-12. Commands and port choices above describe this script, not an upstream turnkey distribution.

- Nextcloud supported platforms: https://docs.nextcloud.com/server/stable/admin_manual/installation/system_requirements.html
- Official Nginx example: https://docs.nextcloud.com/server/stable/admin_manual/installation/nginx.html
- Official release archive: https://download.nextcloud.com/server/releases/
- RFC2136 plugin and restricted BIND policy: https://certbot-dns-rfc2136.readthedocs.io/en/stable/
- Talk OCC commands: https://nextcloud-talk.readthedocs.io/en/stable/occ/
- Talk TURN and network limitations: https://nextcloud-talk.readthedocs.io/en/stable/TURN/
- Talk coturn deployment: https://nextcloud-talk.readthedocs.io/en/stable/coturn/
- Signaling release README: https://github.com/strukturag/nextcloud-spreed-signaling/blob/v2.1.1/README.md
- Signaling configuration: https://github.com/strukturag/nextcloud-spreed-signaling/blob/v2.1.1/server.conf.in
- Release image tag generation: https://github.com/strukturag/nextcloud-spreed-signaling/blob/v2.1.1/.github/workflows/deploydocker.yml
- Janus 1.1.2 configuration: https://github.com/meetecho/janus-gateway/blob/v1.1.2/conf/janus.jcfg.sample.in
