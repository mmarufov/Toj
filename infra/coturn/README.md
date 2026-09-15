# Toj TURN deployment

Deploy this stack in at least two failure-independent regions. Each node exposes TURN UDP/TCP on
3478, TURN/TLS on 443, UDP relay ports 49152-65535, and Prometheus metrics on a private interface.
Do not place a TCP-only HTTP reverse proxy in front of TURN.

## Required deployment values

- A unique public hostname and public/external address per node.
- A certificate and private key for the TURN hostname.
- A private metrics-listener address; never bind coturn metrics to a public interface.
- The same high-entropy REST-auth secret configured in the Toj call-control service and coturn.
- Provider firewall rules for 3478 UDP/TCP, 443 TCP, and the UDP relay range.
- Provider egress rules that reject loopback, private/VPC, link-local, metadata/control-plane,
  CGNAT, benchmark/test/documentation, ULA, and multicast destinations. Mirror every
  `denied-peer-ip` range from the coturn configuration and add any provider-specific service
  ranges; the in-process deny list is not the only security boundary.
- Static Prometheus gauges `toj_turn_allocation_capacity` and
  `toj_turn_egress_capacity_bytes_per_second`, set to this node's provisioned limits.
- A log sink with a verified retention policy of no more than 24 hours for raw coturn logs. The
  Compose rotation limits disk use but is not a time-based retention guarantee.

Render `turnserver.conf.example` through the deployment secret store. Keep the resulting
`turnserver.conf` and `certs/` local; both paths are gitignored.

The pinned container runs as `nobody:nogroup` (UID/GID 65534). On a dedicated Linux host, make the
rendered config and copied certificate material readable by that GID without making the REST secret
or private key world-readable; for example, use root:65534 ownership, mode `0640` for files, and
mode `0750` for `certs/`. Reapply those permissions after certificate renewal before a rolling
restart. The Compose tmpfs mounts are owned by the same UID/GID so the read-only container can write
only its PID and ephemeral coturn state.

Replace every placeholder in the example. Set `realm` and `server-name` to the node's TURN
hostname, `external-ip` to its public address, `relay-ip` to the address on the host relay
interface, and `prometheus-address` to a private address. For a node behind port-preserving 1:1
NAT, use coturn's `PUBLIC_IP/PRIVATE_IP` form when an explicit mapping is required. Coturn 4.14
already requires TLS 1.2 or newer; never add the `tlsv1` or `tlsv1_1` compatibility switches.
Set `total-quota`, `bps-capacity`, and the two exported capacity gauges from load-tested node
limits; `bps-capacity` and the egress gauge are bytes per second. Video deployments begin with
`max-bps=512000` bytes per second per allocation (about 4.096 Mbps aggregate) while Toj caps a
single outbound camera stream at 1.5 Mbps. Do not copy one node's measured capacity to another
region without an independent load test.

Use an external authenticated TURN allocation probe for health. Container process liveness alone
does not prove that public UDP/TCP/TLS paths or credentials work. Generate a short-lived coturn
REST username and HMAC credential from the shared secret in the probe's secret store; there is no
separate health secret understood by this configuration.

Rotate the REST secret without invalidating live credentials by rolling a configuration containing
both old and new `static-auth-secret` lines through the TURN nodes one at a time, changing
`TOJ_TURN_SHARED_SECRET` in the call-control service to the new value, waiting at least 60 minutes
for old credentials to expire, and then rolling removal of the old line one node at a time. Keep a
healthy node available during every restart and verify allocation health after each step.

## Relay security boundary

Toj uses UDP relay allocations for media only. `no-tcp-relay` disables RFC 6062 TCP relay
endpoints, which prevents a credential holder from turning coturn into a generic TCP proxy. It
does **not** disable TURN clients connecting over TCP on 3478 or TLS on 443; those transports stay
available for restrictive networks and carry the UDP relay allocation.

The `denied-peer-ip` rules reject non-public and special-use peer addresses, including the common
cloud metadata endpoints in link-local, CGNAT, RFC1918, ULA, and Azure's `168.63.129.16` platform
address. Do not create `allowed-peer-ip` overrides into deployment networks. A deny list cannot
predict every provider control-plane range, so enforce the same policy at the host or cloud egress
firewall and add provider-specific ranges there before enabling the node.

Validate the Compose structure and confirm the pinned image supports the required hardening options
before every rollout:

```sh
python3 infra/coturn/validate-peer-policy.py
docker compose config --quiet
docker compose run --rm --no-deps --entrypoint turnserver coturn --help \
  | grep -E -- '--no-tcp-relay|--denied-peer-ip'
```

Start the rendered configuration in a non-production node and require its authenticated allocation
health probe to pass before shifting traffic. Then use short-lived test credentials and
`turnutils_uclient` or an equivalent external probe to
confirm that a public UDP echo peer succeeds while private, link-local metadata, documentation,
benchmark, IPv6 ULA/link-local, and multicast peers receive a forbidden-peer response. Also prove
that allocations work over `turn:host:3478?transport=tcp` and
`turns:host:443?transport=tcp`; `no-tcp-relay` must not remove those client paths.

## Voice release gate

Before advertising `voice_calls_v1`, verify from physical iPhones on independent carriers:

1. Direct ICE and TURN/UDP calls.
2. Complete UDP blocking with TURN/TLS on 443.
3. IPv4, IPv6, and NAT64 where the provider supports them.
4. Failure of either region while a call is active, followed by ICE restart through the survivor.
5. Credentials expire after 60 minutes and renew through a replacement allocation at 45 minutes.
6. Metrics contain aggregate allocation/traffic data only; raw client IP logs expire within 24 hours.
7. Attempts to create permissions for every denied address class fail from outside the deployment,
   and provider flow logs show no route from relay ports to VPC or metadata/control-plane services.

## Video release gate

Before advertising `video_calls_v1`, complete every voice gate above, then prove that a mixed
audio/video load remains below 60% of allocation and egress capacity at the intended rollout
percentage. External allocation probes must continue passing independently over UDP, TCP, and TLS
443 throughout the test. Complete the repository's
[Video Calls v1 release report](../../docs/releases/video-calls-v1.md) before setting video readiness.

The control plane should return both regions in measured-preference order. WebRTC connectivity
checks, not GeoIP alone, select the final route.
