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
Reaper CronJob / ServiceAccount / Role / ConfigMap name (fullname + "-reaper").
*/}}
{{- define "cursor-worker-pool.reaperName" -}}
{{- printf "%s-reaper" (include "cursor-worker-pool.fullname" . | trunc 56 | trimSuffix "-") -}}
{{- end -}}

{{/*
Reaper image: hibernation.reaper.image.repository if set, otherwise the
controller image (which already has kubectl).
*/}}
{{- define "cursor-worker-pool.reaperImage" -}}
{{- if .Values.hibernation.reaper.image.repository -}}
{{- $repository := .Values.hibernation.reaper.image.repository -}}
{{- if .Values.hibernation.reaper.image.digest -}}
{{- printf "%s@%s" $repository .Values.hibernation.reaper.image.digest -}}
{{- else -}}
{{- $tag := required "hibernation.reaper.image.tag is required when hibernation.reaper.image.repository is set" .Values.hibernation.reaper.image.tag | toString -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}
{{- else -}}
{{- include "cursor-worker-pool.controllerImage" . -}}
{{- end -}}
{{- end -}}

{{- define "cursor-worker-pool.reaperPullPolicy" -}}
{{- if .Values.hibernation.reaper.image.pullPolicy -}}
{{- .Values.hibernation.reaper.image.pullPolicy -}}
{{- else -}}
{{- include "cursor-worker-pool.controllerPullPolicy" . -}}
{{- end -}}
{{- end -}}

{{/*
Duration string to whole seconds. Accepts a bare integer (seconds) or
<n>s, <n>m, <n>h, <n>d. Anything else fails the render.
*/}}
{{- define "cursor-worker-pool.durationSeconds" -}}
{{- $s := . | toString -}}
{{- if regexMatch "^[0-9]+$" $s -}}
{{- $s -}}
{{- else if regexMatch "^[0-9]+[smhd]$" $s -}}
{{- $n := regexFind "^[0-9]+" $s | int64 -}}
{{- $u := regexFind "[smhd]$" $s -}}
{{- if eq $u "s" -}}{{ $n }}
{{- else if eq $u "m" -}}{{ mul $n 60 }}
{{- else if eq $u "h" -}}{{ mul $n 3600 }}
{{- else -}}{{ mul $n 86400 }}
{{- end -}}
{{- else -}}
{{- fail (printf "invalid duration %q: use <n>s, <n>m, <n>h or <n>d (for example 72h)" $s) -}}
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
{{- if .Values.hibernation.enabled -}}
{{- if not .Values.controller.enabled -}}
{{- fail "hibernation.enabled requires controller.enabled=true (the spawn hook creates and mounts the workspace PVCs)." -}}
{{- end -}}
{{- if not .Values.workerDir -}}
{{- fail "hibernation.enabled requires workerDir (the workspace PVC is mounted there)." -}}
{{- end -}}
{{- $_ := required "hibernation.size is required" .Values.hibernation.size -}}
{{- if not .Values.hibernation.accessModes -}}
{{- fail "hibernation.accessModes must list at least one access mode." -}}
{{- end -}}
{{- $window := .Values.hibernation.wakeWindowSeconds | int -}}
{{- if or (lt $window 1) (gt $window 3600) -}}
{{- fail "hibernation.wakeWindowSeconds must be 1..3600 (the pool's workerReadyTimeoutSeconds)." -}}
{{- end -}}
{{- if and .Values.hibernation.mountHome (not .Values.hibernation.homeDir) -}}
{{- fail "hibernation.mountHome requires hibernation.homeDir." -}}
{{- end -}}
{{- if and .Values.hibernation.seed.fromPath .Values.hibernation.seed.cloneUrl -}}
{{- fail "set only one of hibernation.seed.fromPath and hibernation.seed.cloneUrl." -}}
{{- end -}}
{{- $_ := include "cursor-worker-pool.durationSeconds" .Values.hibernation.pvcTtl -}}
{{- $_ := include "cursor-worker-pool.durationSeconds" .Values.hibernation.podTtl -}}
{{- if and .Values.hibernation.reaper.enabled (not .Values.hibernation.reaper.schedule) -}}
{{- fail "hibernation.reaper.schedule is required when the reaper is enabled." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Worker CLI arguments shared by the plain and hibernation Pod shapes.
*/}}
{{- define "cursor-worker-pool.workerArgs" -}}
- worker
- --pool
- "${POOL}"
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
{{- end -}}

{{/*
PersistentVolumeClaim kubectl-created by the spawn hook when hibernation is
on. Same ${WORKER_SLUG} / ${WORKER_ID} / ${POOL} tokens as the Pod. The
last-used annotations are stamped by the hook on every spawn and wake; the
reaper reads last-used-epoch.
*/}}
{{- define "cursor-worker-pool.workspacePvc" -}}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: "ws-${WORKER_SLUG}"
  namespace: {{ .Release.Namespace | quote }}
  labels:
    app.kubernetes.io/name: {{ include "cursor-worker-pool.name" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: workspace
    cursor.com/worker-id: "${WORKER_SLUG}"
  annotations:
    cursor.com/worker-id: "${WORKER_ID}"
    cursor.com/pool: "${POOL}"
spec:
  accessModes:
    {{- toYaml .Values.hibernation.accessModes | nindent 4 }}
  {{- with .Values.hibernation.storageClassName }}
  storageClassName: {{ . | quote }}
  {{- end }}
  resources:
    requests:
      storage: {{ .Values.hibernation.size | quote }}
{{- end -}}

{{/*
Pod manifest kubectl-created by the spawn hook. Column-0 YAML. The hook
substitutes exactly three tokens with sed: ${WORKER_SLUG} (DNS-1123 form of
the worker id, used for Kubernetes names and labels), ${WORKER_ID} (the id
the controller claimed, passed to the worker verbatim) and ${POOL}.
generateName gives every episode its own Pod name so a wake never collides
with the previous Succeeded Pod. restartPolicy is Never so an idle-release
exit is terminal.
*/}}
{{- define "cursor-worker-pool.workerPod" -}}
apiVersion: v1
kind: Pod
metadata:
  generateName: "${WORKER_SLUG}-"
  namespace: {{ .Release.Namespace | quote }}
  labels:
    app.kubernetes.io/name: {{ include "cursor-worker-pool.name" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: worker
    cursor.com/worker-id: "${WORKER_SLUG}"
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  annotations:
    cursor.com/worker-id: "${WORKER_ID}"
    cursor.com/pool: "${POOL}"
    {{- with .Values.podAnnotations }}
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
      {{- if .Values.hibernation.enabled }}
      {{- /* The entrypoint seeds an empty workspace volume, then execs the configured command with the worker arguments. */}}
      command:
        - /bin/sh
        - /cursor-hooks/entrypoint.sh
      args:
        {{- toYaml .Values.command | nindent 8 }}
        {{- include "cursor-worker-pool.workerArgs" . | nindent 8 }}
      {{- else }}
      command:
        {{- toYaml .Values.command | nindent 8 }}
      args:
        {{- include "cursor-worker-pool.workerArgs" . | nindent 8 }}
      {{- end }}
      env:
        - name: CURSOR_API_KEY
          valueFrom:
            secretKeyRef:
              name: {{ include "cursor-worker-pool.secretName" . }}
              key: {{ .Values.auth.secretKey | quote }}
        - name: CURSOR_POOL
          value: "${POOL}"
        - name: CURSOR_AGENT_WORKER_ID
          value: "${WORKER_ID}"
        - name: CURSOR_WORKER_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
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
      {{- if or .Values.hibernation.enabled .Values.extraVolumeMounts }}
      volumeMounts:
        {{- if .Values.hibernation.enabled }}
        - name: workspace
          mountPath: {{ .Values.workerDir | quote }}
          subPath: workspace
        {{- if .Values.hibernation.mountHome }}
        - name: workspace
          mountPath: {{ .Values.hibernation.homeDir | quote }}
          subPath: home
        {{- end }}
        - name: cursor-hooks
          mountPath: /cursor-hooks
          readOnly: true
        {{- end }}
        {{- with .Values.extraVolumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- end }}
  {{- if or .Values.hibernation.enabled .Values.extraVolumes }}
  volumes:
    {{- if .Values.hibernation.enabled }}
    - name: workspace
      persistentVolumeClaim:
        claimName: "ws-${WORKER_SLUG}"
    - name: cursor-hooks
      configMap:
        name: {{ include "cursor-worker-pool.spawnConfigMapName" . }}
        defaultMode: 0755
        items:
          - key: entrypoint.sh
            path: entrypoint.sh
    {{- end }}
    {{- with .Values.extraVolumes }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
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
