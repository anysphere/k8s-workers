{{/*
Chart name, truncated to 63 chars.
*/}}
{{- define "cursor-worker-pool.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name, truncated to 63 chars.
*/}}
{{- define "cursor-worker-pool.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "cursor-worker-pool.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Common labels applied to all resources.
*/}}
{{- define "cursor-worker-pool.labels" -}}
app.kubernetes.io/name: {{ include "cursor-worker-pool.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
Selector labels for the in-cluster controller Deployment. Includes
component=controller so spawned worker Pods (component=worker) are never
adopted by this replica set.
*/}}
{{- define "cursor-worker-pool.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cursor-worker-pool.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: controller
{{- end -}}

{{/*
ServiceAccount name (controller).
*/}}
{{- define "cursor-worker-pool.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- .Values.serviceAccount.name | default (include "cursor-worker-pool.fullname" .) -}}
{{- else -}}
{{- required "serviceAccount.name must be set when serviceAccount.create is false" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Secret that holds CURSOR_API_KEY. Suffix is reserved so the name stays
within the DNS-1123 63-character limit even when fullname is already 63.
*/}}
{{- define "cursor-worker-pool.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- printf "%s-api-key" (include "cursor-worker-pool.fullname" . | trunc 55 | trimSuffix "-") -}}
{{- end -}}
{{- end -}}

{{/*
Spawn-hook ConfigMap name (fullname + "-spawn"), truncated to 63 chars.
*/}}
{{- define "cursor-worker-pool.spawnConfigMapName" -}}
{{- printf "%s-spawn" (include "cursor-worker-pool.fullname" . | trunc 57 | trimSuffix "-") -}}
{{- end -}}

{{/*
Worker image reference (spawned Pods).
*/}}
{{- define "cursor-worker-pool.image" -}}
{{- $repository := required "image.repository is required (worker image with the agent CLI, git, and a cloned repo)" .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repository .Values.image.digest -}}
{{- else -}}
{{- $tag := required "image.tag is required" .Values.image.tag | toString -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
Controller image: controller.image.repository if set, otherwise the worker image.
The controller container must also have kubectl on PATH.
*/}}
{{- define "cursor-worker-pool.controllerImage" -}}
{{- if .Values.controller.image.repository -}}
{{- $repository := .Values.controller.image.repository -}}
{{- if .Values.controller.image.digest -}}
{{- printf "%s@%s" $repository .Values.controller.image.digest -}}
{{- else -}}
{{- $tag := required "controller.image.tag is required when controller.image.repository is set" .Values.controller.image.tag | toString -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}
{{- else -}}
{{- include "cursor-worker-pool.image" . -}}
{{- end -}}
{{- end -}}

{{/*
Pull policy for the controller container.
*/}}
{{- define "cursor-worker-pool.controllerPullPolicy" -}}
{{- if .Values.controller.image.pullPolicy -}}
{{- .Values.controller.image.pullPolicy -}}
{{- else -}}
{{- .Values.image.pullPolicy -}}
{{- end -}}
{{- end -}}

{{/*
Port parsed from managementAddr (host:port or :port or port).
*/}}
{{- define "cursor-worker-pool.managementPort" -}}
{{- $addr := required "managementAddr is required" .Values.managementAddr | toString -}}
{{- if contains ":" $addr -}}
{{- splitList ":" $addr | last -}}
{{- else -}}
{{- $addr -}}
{{- end -}}
{{- end -}}

{{/*
Fail closed on auth, pool, and controller/token invariants.
Required calls are assigned so this helper emits no YAML.
*/}}
{{- define "cursor-worker-pool.validate" -}}
{{- if not .Values.auth.existingSecret -}}
{{- $_ := required "Set auth.existingSecret or auth.apiKey (a team service account API key)." .Values.auth.apiKey -}}
{{- end -}}
{{- $_ := required "pool is required" .Values.pool -}}
{{- $warmIdle := .Values.controller.warmIdle | int -}}
{{- if lt $warmIdle 0 -}}
{{- fail "controller.warmIdle must be >= 0 (0 omits --warm-idle; a positive integer is passed through to agent worker controller)." -}}
{{- end -}}
{{- if and (gt $warmIdle 0) (not .Values.controller.enabled) -}}
{{- fail "controller.warmIdle > 0 requires controller.enabled=true (the in-cluster controller passes --warm-idle; this chart does not patch Deployments or HPA)." -}}
{{- end -}}
{{- if and .Values.controller.enabled (not .Values.serviceAccount.automount) -}}
{{- fail "controller.enabled requires serviceAccount.automount=true so kubectl in the spawn hook can create Pods." -}}
{{- end -}}
{{- end -}}

{{/*
Pod manifest kubectl-created by the spawn hook. Column-0 YAML; runtime
shell variables are ${POD_NAME} and ${POOL}. restartPolicy is Never so an
idle-release exit is terminal.
*/}}
{{- define "cursor-worker-pool.workerPod" -}}
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: {{ .Release.Namespace | quote }}
  labels:
    app.kubernetes.io/name: {{ include "cursor-worker-pool.name" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: worker
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with .Values.podAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
  {{- with .Values.priorityClassName }}
  priorityClassName: {{ . | quote }}
  {{- end }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.podSecurityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: worker
      image: {{ include "cursor-worker-pool.image" . | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      command:
        {{- toYaml .Values.command | nindent 8 }}
      args:
        - worker
        - --pool
        - ${POOL}
        - --idle-release-timeout
        - {{ .Values.idleReleaseTimeout | int | quote }}
        {{- if .Values.workerDir }}
        - --worker-dir
        - {{ .Values.workerDir | quote }}
        {{- end }}
        - --management-addr
        - {{ .Values.managementAddr | quote }}
        {{- range .Values.labels }}
        - --label
        - {{ . | quote }}
        {{- end }}
        {{- range .Values.extraArgs }}
        - {{ . | quote }}
        {{- end }}
        - start
      env:
        - name: CURSOR_API_KEY
          valueFrom:
            secretKeyRef:
              name: {{ include "cursor-worker-pool.secretName" . }}
              key: {{ .Values.auth.secretKey | quote }}
        - name: CURSOR_POOL
          value: ${POOL}
        - name: CURSOR_AGENT_WORKER_ID
          value: ${POD_NAME}
        - name: CURSOR_WORKER_NAME
          value: ${POD_NAME}
        - name: CURSOR_API_ENDPOINT
          value: "${API_ENDPOINT}"
        - name: CURSOR_API_URL
          value: "${API_URL}"
        {{- with .Values.extraEnv }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      ports:
        - name: management
          containerPort: {{ include "cursor-worker-pool.managementPort" . | int }}
          protocol: TCP
      readinessProbe:
        httpGet:
          path: {{ .Values.probes.readiness.path | quote }}
          port: management
        initialDelaySeconds: {{ .Values.probes.readiness.initialDelaySeconds }}
        periodSeconds: {{ .Values.probes.readiness.periodSeconds }}
      livenessProbe:
        httpGet:
          path: {{ .Values.probes.liveness.path | quote }}
          port: management
        initialDelaySeconds: {{ .Values.probes.liveness.initialDelaySeconds }}
        periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      {{- with .Values.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.extraVolumeMounts }}
      volumeMounts:
        {{- toYaml . | nindent 8 }}
      {{- end }}
  {{- with .Values.extraVolumes }}
  volumes:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.topologySpreadConstraints }}
  topologySpreadConstraints:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
