# The image behind Hubble Observer: `quay.io/cilium/hubble`, and how its flags carry the design

Measured on 2026-09-12 against Cilium 1.20.1 (Hubble Relay on mTLS, ClusterMesh of two clusters).

That image is nothing more than the Hubble CLI, `hubble v1.16.4`, in a 36 MB busybox base
(`cmd=[/usr/bin/hubble]`, `/bin/sh → /bin/busybox`). Everything the observer does is one CLI invocation:

```
hubble observe flows --verdict DROPPED --not --drop-reason-desc 'UNSUPPORTED_L3_PROTOCOL' \
  --follow --ip-translation --server hubble-relay.<ns>.svc.<clusterDomain>:<port> -o json > /proc/1/fd/1
```

and five capabilities of that binary carry the whole design.

## The five capabilities

1. **`observe` is a client of the relay's Observer gRPC API.** The CLI captures nothing itself. It asks
   Hubble Relay, and the relay aggregates every node's Hubble server — in a ClusterMesh with a shared
   CA, every node of every cluster (measured: `Connected Nodes: 7/7` from one relay). One observer pod
   therefore sees flows from all meshed clusters, each flow stamped with `source.cluster_name` and
   `destination.cluster_name`.
2. **`--follow` turns a query into a stream.** Without it `observe` prints the ring buffers and exits;
   with it the CLI holds the gRPC stream open and prints each flow as it happens. It also acts as the
   liveness signal: if the stream dies, the process exits and the kubelet restarts the container.
3. **`--verdict` and `--not --drop-reason-desc` are server-side filters.** The CLI sends them to the
   relay as whitelist/blacklist filters (`--not`: "Reverses the next filter to be blacklist"), so only
   the flows that match cross the wire — tens of lines per minute for DROPPED, versus thousands for
   `verdictFilter: none`.
4. **`-o json` with `--ip-translation` (default on) produces the record the dashboard depends on.**
   One JSON object per line — `{"flow": {...}, "node_name": ..., "time": ...}` — with `verdict`,
   `drop_reason_desc`, `traffic_direction`, `egress_denied_by` / `ingress_denied_by` (policy names),
   and `source`/`destination` carrying `namespace`, `pod_name`, `labels`, `identity`, `cluster_name`.
   Loki's `| json` flattens these into `flow_verdict`, `flow_source_cluster_name`, … — the labels every
   panel of the dashboard filters on.
5. **TLS from environment variables.** The CLI reads `HUBBLE_TLS`, `HUBBLE_TLS_SERVER_NAME`,
   `HUBBLE_TLS_CA_CERT_FILES`, `HUBBLE_TLS_CLIENT_CERT_FILE`, `HUBBLE_TLS_CLIENT_KEY_FILE` — the chart
   sets them when `hubbleRelay.tls.enabled=true`, so the command is unchanged and the exec probes
   (plain `hubble status`) inherit the same settings. Precedence: flag > environment > config file.

## The shell is load-bearing

The chart's `args` is `sh -c "hubble observe … > /proc/1/fd/1"`: the shell redirects the CLI's stdout
to the container's PID 1 stdout, which the kubelet writes to `/var/log/pods/<ns>_<pod>_<uid>/hubble-observer/*.log`
— the file a log shipper tails into Loki. A distroless CLI image would need the command changed, not
only the tag.

## Versions: the default image is unmaintained — run the CLI from the Cilium agent image instead

The facts about `quay.io/cilium/hubble` (checked 2026-09-12):

- **No release tag after `v1.16.4`**, pushed 2024-11-21 (`v1.17.0` … `v1.20.1`: absent; `latest` is a
  stale `v0.9.0-dev` build from 2021 — never use it). The Hubble CLI project publishes tarballs only
  since; there is no newer image to move to in that registry.
- Built with **Go 1.23.3** (end of life) on **alpine 3.20.3**. `trivy image --severity CRITICAL,HIGH`:
  **5 CRITICAL + 51 HIGH** (OS layer 2/19, the `hubble` binary 3/32). Unmaintained means those numbers
  only grow.
- The CLI works against a 1.20.1 relay because the Observer API is stable (7/7 nodes, one version
  warning at connect time), and the JSON it prints is identical to the newer CLI's — the same 49
  fields on the same flows, `egress_denied_by` included. Nothing is lost *today*; nothing is fixed *ever*.

The Hubble CLI that **is** maintained ships inside the Cilium agent image, on the same release train as
the relay it talks to. Measured on `quay.io/cilium/cilium:v1.20.1`: `hubble v1.20.1` (Go 1.26.5),
`/bin/sh → /usr/bin/dash` (the `> /proc/1/fd/1` redirect still works), all 14 flags the chart uses
present, trivy **0 CRITICAL** (128 HIGH across its 14 Go binaries; the `hubble` binary itself 0/11).
It is already on every node — it *is* the agent's image — so pinning the observer to the agents'
digest costs no pull:

```yaml
image:
  repository: quay.io/cilium/cilium
  tag: "v1.20.1@sha256:<the digest your cilium DaemonSet runs>"
```

Live with that (Hubble Observer on Cilium 1.20.1, relay on mTLS): pod Ready, `Connected Nodes: 7/7`,
no version warning, 68 of 68 DROPPED flows on stdout and in Loki. The trade: a ~600 MB image for a
one-binary job (already present), and the observer's version now moves with the cluster's Cilium —
which is the point: one release train, one security process, one digest to review.

What the 1.20.1 CLI adds for `observe`, and what it would mean here:

| flag (1.20.1 only) | value for the observer |
|---|---|
| `--from-cluster` / `--to-cluster` | server-side cluster filters — a per-cluster observer in a mesh without a mesh-wide relay |
| `--field-mask`, `--use-default-field-masks` | ask the relay for fewer fields per flow — smaller lines, less Loki volume |
| `--print-policy-names` | compact output only; the JSON already carries `*_denied_by` |
| `--encrypted` / `--unencrypted`, `--reply` / `--not-reply`, `--ip-trace-id` | more server-side filters |
| `--kube-context`, `--port-forward-port` | CLI-side port-forwarding — not for a pod |

## Two fields the dashboard now shows — and the two empty cases

`drop_reason_desc` (`POLICY_DENIED`, `POLICY_DENY`, …) and `egress_denied_by[].name` /
`ingress_denied_by[].name` (which policy dropped it — filled when Cilium's
`hubble-network-policy-correlation-enabled` is on, the default since 1.16) are on the dashboard as two pie
panels under Statistics, *Flows per Drop Reason* and *Flows per Denying Policy* — one
`sum by (…) (count_over_time(… | $logparser …))` each, on the same variables as the other panels. The policy
name is read by JSON path (`flow.egress_denied_by[0].name`, `flow.ingress_denied_by[0].name`) because Loki's
`json` parser flattens nested objects and skips arrays.

They are not on every dropped line, and the panels say so instead of hiding it. Both count only flows whose
verdict is `DROPPED` (the stream carries every verdict when `verdictFilter` is `none`). A flow the L7 proxy
denies is `verdict: DROPPED` with `drop_reason_desc` omitted — Hubble's L7 parser writes the enum's zero value
(`DROP_REASON_UNKNOWN`, `pkg/hubble/parser/seven/parser.go`) and `protojson` leaves a zero enum out — so the
drop-reason panel names it from the L7 record (`L7 denied by the proxy (REQUEST)`). The policy panel counts only
`POLICY_DENIED` and `POLICY_DENY` drops: a name when correlation supplied one; `explicit deny (policy name
unavailable)` for a `POLICY_DENY` without one; `default deny (no matching allow)` for a `POLICY_DENIED` without one
— on a default-deny namespace that last bucket is most drops, and hiding it would make the pie disagree with the
totals above it.

Measured on Cilium 1.20.1: `POLICY_DENIED 274 / POLICY_DENY 40`, and `bank-cell-baseline 20` as a named denying
policy; the queries were also run through Loki 3.7.7's own engine on synthetic flows of each kind (the test lives
beside the reference lab's demo 25). A capture of both panels with data is in the reference lab's CI captures
(`grafana-hubble-observer-flows.png`), one run's evidence at a time.
