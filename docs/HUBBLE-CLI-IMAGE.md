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

## Versions: 1.16.4 CLI, 1.20.1 relay — and why the image is not bumped

- `quay.io/cilium/hubble` has **no release tag after `v1.16.4`** (checked `v1.17.0` … `v1.20.1`: absent;
  `latest` is a stale `v0.9.0-dev` build from 2021 — never use it). The Hubble CLI project publishes
  tarballs only since then. The chart's default is the newest published CLI image.
- The CLI works against a 1.20.1 relay because the Observer API is stable; it prints one version
  warning at connect time. **Measured: the JSON is identical.** The same DROPPED flows serialized by
  the 1.16.4 CLI (via the relay) and by the 1.20.1 CLI (the one inside the Cilium agent image) carry
  the **same 49 fields** — including `egress_denied_by` with the policy name, revision and kind.
  Nothing is lost with 1.16.4.
- The only newer CLI ships **inside the Cilium agent image** (`quay.io/cilium/cilium:v1.20.1`:
  `hubble v1.20.1`, `/bin/sh → /usr/bin/dash`, all 14 flags the chart uses present). It can be set as
  `image.repository`/`image.tag`, at the cost of a several-hundred-MB image for a one-binary job.
- What the 1.20.1 CLI adds for `observe`, and what it would mean here:

  | flag (1.20.1 only) | value for the observer |
  |---|---|
  | `--from-cluster` / `--to-cluster` | server-side cluster filters — a per-cluster observer in a mesh without a mesh-wide relay |
  | `--field-mask`, `--use-default-field-masks` | ask the relay for fewer fields per flow — smaller lines, less Loki volume |
  | `--print-policy-names` | compact output only; the JSON already carries `*_denied_by` |
  | `--encrypted` / `--unencrypted`, `--reply` / `--not-reply`, `--ip-trace-id` | more server-side filters |
  | `--kube-context`, `--port-forward-port` | CLI-side port-forwarding — not for a pod |

## What the dashboard does not yet show, though the data is there

Two fields present in every dropped flow's JSON are not on the shipped dashboard: `drop_reason_desc`
(`POLICY_DENIED`, `POLICY_DENY`, …) and `egress_denied_by[].name` / `ingress_denied_by[].name` (which
policy dropped it — filled when Cilium's `hubble-network-policy-correlation-enabled` is on, the default
since 1.16). Both are one `sum by (…) (count_over_time(… | json …))` away; see the panels added in the
`cilium-kind-poc` demo 25 for a working example.
