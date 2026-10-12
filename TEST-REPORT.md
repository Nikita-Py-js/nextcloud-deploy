# Verification report

Date: 2026-10-12

## Result

10 isolated tests passed. These are static, configuration-rendering and mocked unit tests, not an Ubuntu installation or a real call test.

Installer SHA-256: `e0e53534c9b38be7d815d1947b185cec75980bfd66be6824ea2ce69feb6d8d59`

## Environment

Debian 13 container; Bash; Python 3.13; PHP 8.4.24 CLI; Nginx 1.26.3; OpenSSL; jq; libconfig.so.11. The target distribution is Ubuntu 24.04 with PHP 8.3 and its distribution packages.

Generated Nginx configuration passed nginx -t with an isolated self-signed test certificate. Nginx 1.26 reports a deprecation warning for `listen ... http2`; this syntax is retained for Ubuntu 24.04's Nginx 1.24 compatibility. No Nginx process was started.

Janus configuration passed libconfig syntax parsing; the actual Janus executable was not run. The PHP stdin bridge passed syntax validation with PHP 8.4; it was not booted against an installed Nextcloud instance.

Mocked OCC tests exercised an empty signaling configuration, first-run setup, a second run without duplicate endpoints, and repair of a duplicate/insecure signaling endpoint and a changed TURN secret. They do not substitute for testing the actual installed Talk release.

The secret-file tests verified reuse and restricted permissions using temporary files only. STUN tests checked packet lengths, padding, HMAC construction and response parsing; no real TURN daemon was available in this environment.

## Not executed

- Ubuntu 24.04 package installation and systemd service startup.
- Docker registry pull, image architecture resolution and container execution.
- Actual Nextcloud installation and Talk activation.
- RFC2136 updates against a user DNS zone.
- Let's Encrypt certificate issuance, renewal or the live renewal hook.
- Native coturn, NATS and Janus integration.
- External firewall/NAT reachability and real two-party/group browser calls.

The installer includes on-host checks for these services and local TURN allocations, but browser/media acceptance must still be performed on the deployed server.

## Test output

```text
test_atomic_write_and_private_directory (__main__.DeploymentTests.test_atomic_write_and_private_directory) ... ok
test_bash_and_embedded_syntax (__main__.DeploymentTests.test_bash_and_embedded_syntax) ... ok
test_janus_libconfig_syntax (__main__.DeploymentTests.test_janus_libconfig_syntax) ... ok
test_nginx_config (__main__.DeploymentTests.test_nginx_config) ... ok
test_redis_order_and_private_listeners (__main__.DeploymentTests.test_redis_order_and_private_listeners) ... ok
test_secrets_are_reused (__main__.DeploymentTests.test_secrets_are_reused) ... ok
test_signaling_config (__main__.DeploymentTests.test_signaling_config) ... ok
test_stun_packet_and_response_parser (__main__.DeploymentTests.test_stun_packet_and_response_parser) ... ok
test_talk_initialization_repeat_and_repair (__main__.DeploymentTests.test_talk_initialization_repeat_and_repair) ... ok
test_validation (__main__.DeploymentTests.test_validation) ... ok

----------------------------------------------------------------------
Ran 10 tests in 4.252s

OK
```
