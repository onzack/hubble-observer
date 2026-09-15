<div align="center">
<img src="assets/hubble-observer_background.png" alt="Hubble Observer Logo" width="500">
</div>

# Hubble Observer

The Hubble Observer is a small observability component that monitors network flows within Cilium.
> **Note:** You can enable the **CF2CNP** feature in the Helm chart (`cf2cnp.enabled=true`) to automatically generate CiliumNetworkPolicies based on observed network flows. **These policies are not applied automatically; you need to download them and apply them yourself.** See the `values.yaml` file for additional `cf2cnp` configuration options.

The Hubble Observer also includes a Grafana dashboard for visualizing Cilium network flows. Here's a preview of the dashboard:

[![Grafana Dashboard Preview](assets/grafanadashboard.png)](https://grafana.com/grafana/dashboards/23862)

## Prerequisites

Before installing the Hubble Observer, ensure you have the following components installed in your Kubernetes cluster:

1. **Hubble Relay**
   - Required to connect to all Cilium pods and export the flows.

1. **Grafana Operator**
   - Required for deploying the Grafana dashboard. (you can disable this: `grafanaDashboard.enabled=false`)
   - Installation instructions: [Grafana Operator Documentation](https://github.com/grafana/grafana-operator)

1. **Loki**
   - Required for log aggregation and querying
   - The Grafana dashboard uses LogQL queries
   - Installation instructions: [Loki Documentation](https://grafana.com/docs/loki/latest/setup/install/)

> The way it works is very straightforward: it uses the hubble container image which connects to the hubble relay and sends all flows to the stdout. Thats why you need a log collector which ships the logs to Loki.

## Installation

```bash
helm upgrade --install hubble-observer oci://ghcr.io/onzack/helm-charts/hubble-observer --version <VERSION>
```

## How the image and its flags work

[`docs/HUBBLE-CLI-IMAGE.md`](docs/HUBBLE-CLI-IMAGE.md) — what `quay.io/cilium/hubble` contains, the five CLI capabilities the observer relies on, why the shell is load-bearing, and the measured comparison of the 1.16.4 CLI with the 1.20.1 one (same JSON, same 49 fields).

## Configuration

See `values.yaml` for configuration options.

`fieldMask` keeps only the listed flow fields (`hubble observe --field-mask`): Hubble Relay strips the rest before sending, so the stream, the pod log and Loki all shrink — `values.yaml` carries the smallest mask that still feeds every dashboard panel (~35% fewer bytes per flow, measured), plus `is_reply`, which no panel reads but a policy generator does: cf2cnp refuses a reply flow by that field ("this is a reply packet - you need to allow the original request"), and the same flow with the field masked away generated `Allow ingress to shop/frontend … from shop/backend on TCP/54468` — a rule for the reply's direction on an ephemeral port (measured with cf2cnp 0.7.0 on a recorded HTTP response flow). Keep `is_reply` in any mask whose flows feed a generator. `extraArgs` appends further `hubble observe` flags verbatim.
`ciliumNetworkPolicy.enabled=true` renders a policy that allows the observer egress to Hubble Relay on the relay pod's listen port (`ciliumNetworkPolicy.relayPort`, default `4245` — Cilium enforces egress policy on the backend pod's port, not the Service port) and, by default, to the cluster DNS (`ciliumNetworkPolicy.dns`, needed because the relay is reached by name); point `dns.namespace` / `dns.matchLabels` at your DNS pods if they are not `kube-system` / `k8s-app=kube-dns`.

CF2CNP can be exposed via `cf2cnp.ingress` or, with the Gateway API, via `cf2cnp.httpRoute`. The URL the Grafana dashboard uses is taken from the first ingress host or httpRoute hostname.

## TLS and mTLS to Hubble Relay

If TLS is enabled on the Hubble Relay server (`hubble.relay.tls.server.enabled=true` in Cilium Helm chart), the Hubble Observer has to connect over TLS as well. When the relay additionally enforces mutual TLS (`hubble.relay.tls.server.mtls=true`), a client certificate signed by the Cilium CA is required.

Cilium creates its Hubble certificates in the namespace it is installed into (usually `kube-system`). Helm can only mount secrets from the namespace of the release, so the certificates have to be available in the namespace the Hubble Observer is installed into.

### Configure the chart

TLS only (relay verifies nothing, the observer verifies the relay):

```yaml
hubbleRelay:
  tls:
    enabled: true
    ca:
      secretName: hubble-observer-relay-certs
```

mTLS, with the CA and the client key pair in the same secret:

```yaml
hubbleRelay:
  tls:
    enabled: true
    ca:
      secretName: hubble-observer-relay-certs
    client:
      enabled: true
      secretName: hubble-observer-relay-certs
```

The CA can also come from a ConfigMap, for example a cluster wide CA bundle, via `hubbleRelay.tls.ca.configMapName`. The key names inside the secret or ConfigMap are configurable through `hubbleRelay.tls.ca.key`, `hubbleRelay.tls.client.certKey` and `hubbleRelay.tls.client.keyKey`.

### Notes

- `hubbleRelay.port` is empty by default and resolves to `443` when `hubbleRelay.tls.enabled=true` and to `80` otherwise, matching Cilium's relay service. Set it explicitly if you changed `hubble.relay.servicePort`.
- `hubbleRelay.tls.serverName` defaults to `hubble.hubble-relay.cilium.io`, which matches the `*.hubble-relay.cilium.io` certificate Cilium issues for the relay. Adjust it if your relay certificate uses a different name, for example when `hubble.relay.tls.server.extraDnsNames` is set.
- The hubble CLI does not reload certificates while running, so the pod has to be restarted after certificate rotation.
- The certificates are mounted with mode `0400`. When running the container as a non-root user, set `podSecurityContext.fsGroup` so the files stay readable.
- `hubbleRelay.tls.insecureSkipVerify=true` disables verification of the relay certificate. It is only meant for debugging.

## Optional: the Policy Verdicts dashboard

cf2cnp turns flows into CiliumNetworkPolicies; the [hubble-policy-verdicts](https://github.com/ephico2real2/hubble-policy-verdicts)
dashboard shows what those policies then do — audited (policy evaluated, not enforced), forwarded (an allow rule
matched), dropped (enforced) — per namespace and per source → destination, from Hubble's `policy` metric. It is a
dependency of this chart, off by default:

```yaml
policyVerdictsDashboard:
  enabled: true
  dashboard: {folder: Cilium}
```

The panels need the `policy` metric enabled on the agents with source/destination contexts (see that chart's README).
## A second observer for policy-verdict events

The default observer streams DROPPED flows. Hubble also emits a **policy-verdict** event for every verdict a
policy decides — allowed and denied — carrying the policy's name and kind (`ingress_allowed_by`,
`egress_allowed_by`, `ingress_denied_by`, `egress_denied_by`). They are a small share of all events (measured
on Cilium 1.20.1: 5.6 %), so a second release of this chart with `--type policy-verdict` is a cheap way to
answer "which policy allowed this?" in Loki:

```bash
helm install hubble-observer-verdicts oci://ghcr.io/onzack/helm-charts/hubble-observer -n hubble-observer \
  -f examples/values-policy-verdicts.yaml
```

Then, in Grafana on the Loki datasource:

```logql
sum by (allowed_by) (count_over_time({container="hubble-observer-verdicts"} | json allowed_by="flow.ingress_allowed_by[0].name" | allowed_by != "" [$__range]))
```

Point your collector at the new pod's log the same way it tails the first (`examples/` and the walkthrough in
https://github.com/ephico2real2/cilium-implementation-poc/tree/main/demos/25-hubble-observer-loki).
