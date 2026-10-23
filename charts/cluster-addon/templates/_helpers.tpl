{{- define "cluster-addon.name" -}}
{{- default .Release.Name .Values.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cluster-addon.selectorLabels" -}}
app.kubernetes.io/name: cluster-addon
app.kubernetes.io/instance: {{ include "cluster-addon.name" . }}
{{- end -}}

{{- define "cluster-addon.labels" -}}
{{ include "cluster-addon.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- with .Values.labels }}
{{ toYaml . }}
{{- end }}
{{- end -}}
