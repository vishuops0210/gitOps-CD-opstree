# Helm Templates to Add

Create these 4 files under `GitOps Repo/helm/templates/`.

---

## 1. `ingress.yaml`

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "microservice.fullname" . }}-ingress
  namespace: {{ .Values.global.namespace | quote }}
  labels:
    {{- include "microservice.labels" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if .Values.ingress.className }}
  ingressClassName: {{ .Values.ingress.className }}
  {{- end }}
  rules:
    {{- range .Values.ingress.hosts }}
    - host: {{ .host | quote }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ .path }}
            pathType: {{ .pathType | default "Prefix" }}
            backend:
              service:
                name: {{ include "microservice.fullname" $ }}-svc
                port:
                  number: {{ (index $.Values.service.specs 0).port }}
          {{- end }}
    {{- end }}
{{- end }}
```

---

## 2. `pdb.yaml`

```yaml
{{- if .Values.pdb.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "microservice.fullname" . }}-pdb
  namespace: {{ .Values.global.namespace | quote }}
  labels:
    {{- include "microservice.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- include "microservice.selectorLabels" . | nindent 6 }}
  minAvailable: {{ .Values.pdb.minAvailable }}
{{- end }}
```

---

## 3. `secret.yaml`

```yaml
{{- if .Values.secret.enabled }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "microservice.fullname" . }}-secret
  namespace: {{ .Values.global.namespace | quote }}
  labels:
    {{- include "microservice.labels" . | nindent 4 }}
type: Opaque
stringData:
  {{- toYaml .Values.secret.data | nindent 2 }}
{{- end }}
```

---

## 4. `networkpolicy.yaml`

```yaml
{{- if .Values.networkPolicy.enabled }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "microservice.fullname" . }}-np
  namespace: {{ .Values.global.namespace | quote }}
  labels:
    {{- include "microservice.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "microservice.selectorLabels" . | nindent 6 }}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
      ports:
        {{- range .Values.service.specs }}
        - protocol: {{ .protocol | default "TCP" }}
          port: {{ .port }}
        {{- end }}
{{- end }}
```

---

## What changed in your app values (36 files updated)

| Old key path | New key path |
|---|---|
| `replicaCount: 1` | `global: { replicaCount: 1 }` |
| `image.repository` | `deployment.image.name` |
| `image.tag` | `deployment.image.tag` |
| `service: { type, port, targetPort }` | `service: { type, specs: [{ name: http, port, targetPort }] }` |
| `resources` | `deployment.resources` |
| `livenessProbe` | `deployment.livenessProbe` |
| `readinessProbe` | `deployment.readinessProbe` |
| `autoscaling` | `hpa` |

Done.
