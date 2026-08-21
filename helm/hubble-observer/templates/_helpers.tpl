{{/*
Expand the name of the chart.
*/}}
{{- define "hubble-observer.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "hubble-observer.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "hubble-observer.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "hubble-observer.labels" -}}
helm.sh/chart: {{ include "hubble-observer.chart" . }}
{{ include "hubble-observer.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "hubble-observer.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hubble-observer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Port of the Hubble Relay service.
Cilium switches the relay service port to 443 once TLS is enabled on the relay
server, so an unset hubbleRelay.port follows that behaviour.
*/}}
{{- define "hubble-observer.relayPort" -}}
{{- $tls := .Values.hubbleRelay.tls | default dict -}}
{{- if .Values.hubbleRelay.port -}}
{{- .Values.hubbleRelay.port -}}
{{- else if $tls.enabled -}}
443
{{- else -}}
80
{{- end -}}
{{- end }}

{{/*
Fully qualified address of the Hubble Relay service.
*/}}
{{- define "hubble-observer.relayAddress" -}}
{{- printf "%s.%s.svc.%s:%s" .Values.hubbleRelay.serviceName .Values.hubbleRelay.namespace .Values.hubbleRelay.clusterDomain (include "hubble-observer.relayPort" .) -}}
{{- end }}

{{/*
Directory the Hubble Relay certificates are mounted to.
*/}}
{{- define "hubble-observer.relayTlsMountPath" -}}
{{- $tls := .Values.hubbleRelay.tls | default dict -}}
{{- $tls.mountPath | default "/var/lib/hubble-observer/tls" -}}
{{- end }}

{{/*
Whether certificates have to be mounted into the container.
*/}}
{{- define "hubble-observer.relayTlsMounted" -}}
{{- $tls := .Values.hubbleRelay.tls | default dict -}}
{{- $ca := $tls.ca | default dict -}}
{{- $client := $tls.client | default dict -}}
{{- if and $tls.enabled (or $ca.secretName $ca.configMapName $client.enabled) -}}
true
{{- end -}}
{{- end }}

{{/*
TLS configuration for the hubble CLI. The CLI reads all server options from
HUBBLE_ prefixed environment variables, which makes the observe command and the
probes share the same configuration.
*/}}
{{- define "hubble-observer.relayTlsEnv" -}}
{{- $tls := .Values.hubbleRelay.tls | default dict -}}
{{- if $tls.enabled -}}
{{- $ca := $tls.ca | default dict -}}
{{- $client := $tls.client | default dict -}}
{{- $mountPath := include "hubble-observer.relayTlsMountPath" . -}}
- name: HUBBLE_TLS
  value: "true"
{{- with $tls.serverName }}
- name: HUBBLE_TLS_SERVER_NAME
  value: {{ . | quote }}
{{- end }}
{{- if or $ca.secretName $ca.configMapName }}
- name: HUBBLE_TLS_CA_CERT_FILES
  value: {{ printf "%s/ca.crt" $mountPath | quote }}
{{- end }}
{{- if $client.enabled }}
- name: HUBBLE_TLS_CLIENT_CERT_FILE
  value: {{ printf "%s/client.crt" $mountPath | quote }}
- name: HUBBLE_TLS_CLIENT_KEY_FILE
  value: {{ printf "%s/client.key" $mountPath | quote }}
{{- end }}
{{- if $tls.insecureSkipVerify }}
- name: HUBBLE_TLS_ALLOW_INSECURE
  value: "true"
{{- end }}
{{- end -}}
{{- end }}

{{/*
Reject incomplete TLS configurations instead of rendering a deployment that
cannot connect to Hubble Relay.
*/}}
{{- define "hubble-observer.validateTls" -}}
{{- $tls := .Values.hubbleRelay.tls | default dict -}}
{{- if $tls.enabled -}}
{{- $ca := $tls.ca | default dict -}}
{{- $client := $tls.client | default dict -}}
{{- if and $ca.secretName $ca.configMapName -}}
{{- fail "hubbleRelay.tls.ca.secretName and hubbleRelay.tls.ca.configMapName are mutually exclusive, set only one of them" -}}
{{- end -}}
{{- if and (not $ca.secretName) (not $ca.configMapName) (not $tls.insecureSkipVerify) -}}
{{- fail "hubbleRelay.tls.enabled requires the CA that signed the Hubble Relay server certificate: set hubbleRelay.tls.ca.secretName or hubbleRelay.tls.ca.configMapName (or hubbleRelay.tls.insecureSkipVerify=true to skip verification)" -}}
{{- end -}}
{{- if and $client.enabled (not $client.secretName) -}}
{{- fail "hubbleRelay.tls.client.enabled requires hubbleRelay.tls.client.secretName, the secret holding the client certificate and key" -}}
{{- end -}}
{{- end -}}
{{- end }}
