{{- define "conexao-service.name" -}}
{{- default .Chart.Name .Values.nameOverride -}}
{{- end -}}

{{- define "conexao-service.labels" -}}
app.kubernetes.io/name: {{ include "conexao-service.name" . }}
app.kubernetes.io/part-of: conexao-solidaria
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
