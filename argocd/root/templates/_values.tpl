{{- /*
Values computed from .Values.site (the inventory, via ansible/lgtm.yml) and settings.yaml, one template per
app (apps.<name>.siteValues). Each returns a YAML map that becomes the Application's helm.valuesObject, on
top of k8s/values/<name>.yaml for upstream charts.
*/ -}}

{{- /* ------------------------------------------------------------------ Argo CD (manages itself) */ -}}
{{- define "lgtm.values.argocd" -}}
{{- $s := .Values.site -}}
{{- $o := $s.oauth | default dict -}}
configs:
  cm:
    url: "https://argocd.{{ $s.domain }}"
    # Without this, Argo CD doesn't assess Applications: the root app wouldn't wait for one wave to be healthy
    resource.customizations.health.argoproj.io_Application: {{ .Files.Get "files/application-health.lua" | toYaml | indent 6 | trim }}
{{- if and $o.enabled $o.argocdClientID }}
    # Login via the IdP with its own OAuth client (not Grafana's). The local "admin" stays as the safety valve.
    # The client secret comes from Secret argocd-oidc (created by lgtm.yml, label part-of: argocd).
    oidc.config: |
      name: {{ $o.name | default "Keycloak" }}
      issuer: {{ $o.issuer }}
      clientID: {{ $o.argocdClientID }}
      clientSecret: $argocd-oidc:client-secret
      requestedScopes: [openid, profile, email]
      enablePKCEAuthentication: true
  rbac:
    # access by the user's roles (claim site.oauth.rolesClaim); everyone else sees nothing
    scopes: "[{{ $o.rolesClaim | default "roles" }}]"
    policy.default: ""
    policy.csv: |
{{- range $o.roles.argocdAdmin | default list }}
      g, {{ . }}, role:admin
{{- end }}
{{- range $o.roles.argocdReadonly | default list }}
      g, {{ . }}, role:readonly
{{- end }}
  # login page: SSO button first, local login de-emphasised (the chart mounts it and sets ui.cssurl)
  styles: {{ .Files.Get "files/login.css" | toYaml | indent 4 | trim }}
{{- if $o.hostIP }}
global:
  hostAliases:      # no DNS for the IdP (lab)
    - { ip: {{ $o.hostIP | quote }}, hostnames: [{{ $o.hostname | quote }}] }
{{- end }}
{{- end }}
{{- end }}

{{- /* ------------------------------------------------------------------ cert-manager */ -}}
{{- define "lgtm.values.cert-manager" -}}
{{- with (.Values.site.tls | default dict).http01CheckNameservers }}
# cert-manager's HTTP-01 self check resolves the hostnames on these DNS servers (cluster DNS can't)
extraArgs: ["--acme-http01-solver-nameservers={{ . }}"]
{{- end }}
{{- end }}

{{- /* ------------------------------------------------------------------ certs/ (trusted CAs) */ -}}
{{- define "lgtm.values.certs" -}}
{{- with .Values.site.trustedCAs }}
siteCAs: {{ . | toYaml | indent 2 | trim }}
{{- end }}
{{- end }}

{{- /* ------------------------------------------------------------------ retention (Loki, Mimir, Tempo, Pyroscope)
       One setting for all four: site.retentionDays (inventory: retention_days). The compactors delete older
       data; a change applies from their next run on (shorter: old data goes, longer: kept from now on). */ -}}
{{- define "lgtm.values.retention" -}}
{{- $days := int (.Values.site.retentionDays | default 183) -}}   {{- /* 6 months if the site sets nothing */ -}}
{{- if eq .app "loki" }}
loki:
  limits_config:
    retention_period: {{ printf "%dd" $days }}
{{- else if eq .app "tempo" }}
tempo:
  retention: {{ printf "%dh" (mul $days 24) }}
{{- else }}
{{ .app }}:
  structuredConfig:
    limits:
      compactor_blocks_retention_period: {{ printf "%dd" $days }}
{{- end }}
{{- end }}

{{- /* ------------------------------------------------------------------ argocd/platform */ -}}
{{- define "lgtm.values.platform" -}}
{{- $s := .Values.site -}}
{{- $tls := $s.tls | default dict -}}
{{- $db := $s.grafanaDB | default dict -}}
domain: {{ $s.domain | quote }}
ingressVIP: {{ $s.ingressVIP | quote }}
hosts: {{ $s.hosts | default list | toJson }}
traefikSelector: {{ .Values.traefik_selector | toJson }}
tls:
  issuer: {{ $tls.issuer | quote }}
  acmeServer: {{ $tls.acmeServer | quote }}
  email: {{ $tls.email | quote }}
  eabKeyID: {{ $tls.eabKeyID | quote }}
  caBundle: {{ $tls.caBundle | default "" | quote }}
grafanaDB:
  image: {{ .Values.grafana_db_image | quote }}
  external: {{ $db.external | default false }}
  backup:
    retention: {{ $db.backupRetention | default "7d" | quote }}
pgbackweb:
  image: {{ .Values.pgbackweb_image | quote }}
s3Endpoint: {{ .Values.s3_endpoint | quote }}
{{- end }}

{{- /* ------------------------------------------------------------------ Grafana */ -}}
{{- define "lgtm.values.grafana" -}}
{{- $s := .Values.site -}}
{{- $o := $s.oauth | default dict -}}
{{- $tenants := $s.tenants | default list -}}
{{- $claim := $o.rolesClaim | default "roles" -}}
{{- $names := list -}}
{{- range $tenants }}{{ $names = append $names .name }}{{ end -}}
image:
  tag: {{ splitList ":" .Values.grafana_image | last | quote }}   # the image built by download.yml
grafana.ini:
  server:
    domain: "grafana.{{ $s.domain }}"
    root_url: "https://grafana.{{ $s.domain }}"   # absolute links; the UI also works on http
{{- with $s.gitSyncHost }}
  # Git Sync (ansible/tasks/grafana-git-sync.yml). Grafana refuses Git servers on private addresses (SSRF
  # protection) unless they are allowed here.
  provisioning:
    allowed_git_urls: {{ . | quote }}
{{- end }}
{{- if $o.enabled }}
  # Login via the IdP; access by the user's roles (claim {{ $claim }}):
  #   {{ $o.roles.grafanaAdmin }} -> Admin in every org + Grafana server admin
  #   {{ $o.roles.tenantPrefix }}<tenant> -> Editor in the org <tenant>
  # auto_assign_org is off, so tenant users don't land in the Main org (which sees all tenants).
  users:
    auto_assign_org: false
  auth.generic_oauth:
    enabled: true
    name: {{ $o.name | default "Keycloak" }}
    # Straight to the IdP instead of Grafana's login form. The form stays as the safety valve for the local
    # admin (IdP down, broken mapping): https://grafana.<domain>/login?disableAutoLogin=true
    auto_login: true
    allow_sign_up: true
    client_id: {{ $o.clientID | quote }}
    scopes: openid email profile
    use_pkce: true
    auth_url: "{{ $o.issuer }}/protocol/openid-connect/auth"
    token_url: "{{ $o.issuer }}/protocol/openid-connect/token"
    api_url: "{{ $o.issuer }}/protocol/openid-connect/userinfo"
    signout_redirect_url: "{{ $o.issuer }}/protocol/openid-connect/logout?client_id={{ $o.clientID }}&post_logout_redirect_uri={{ printf "https://grafana.%s/login" $s.domain | urlquery }}"
    login_attribute_path: preferred_username
    email_attribute_path: email
    name_attribute_path: name
    # not_null(): a user without any role has no claim at all
    role_attribute_path: "contains(not_null({{ $claim }}, `[]`), '{{ $o.roles.grafanaAdmin }}') && 'GrafanaAdmin' || 'Viewer'"
    allow_assign_grafana_admin: true
    org_attribute_path: "not_null({{ $claim }}, `[]`)"
    org_mapping: "{{ $o.roles.grafanaAdmin }}:*:Admin{{ range $tenants }} {{ $o.roles.tenantPrefix }}{{ .name }}:{{ .name }}:Editor{{ end }}"
envValueFrom:
  GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET:
    secretKeyRef: { name: grafana-oauth, key: client-secret }
{{- if $o.hostIP }}
hostAliases:      # no DNS for the IdP (lab)
  - { ip: {{ $o.hostIP | quote }}, hostnames: [{{ $o.hostname | quote }}] }
{{- end }}
{{- end }}
# Datasources, provisioned per org: the Main org (1) sees all tenants (cross-tenant queries), each tenant org only
# its own tenant. A tenant org is included once ansible/lgtm.yml created it and passed its id (site.tenants[].orgId):
# provisioning can't create orgs, and Grafana doesn't start with datasources for an org that doesn't exist.
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      {{- include "lgtm.datasources" (dict "orgId" 1 "tenants" $names) | nindent 6 }}
      {{- range $tenants }}
      {{- if .orgId }}
      {{- include "lgtm.datasources" (dict "orgId" .orgId "tenants" (list .name)) | nindent 6 }}
      {{- end }}
      {{- end }}
{{- end }}
