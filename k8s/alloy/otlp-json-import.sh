#!/bin/sh
# Sidecar of the Alloy pod: imports OTLP/JSON files from /otel-import/<tenant>/ (hostPath /var/lib/otel-import)
# into Alloy's "import" receiver (127.0.0.1:4320) with X-Scope-OrgID = <tenant>. Accepts one OTLP export request
# per file or JSON Lines (one request per line, as written by the OTel Collector's file exporter). A file is
# picked up once it hasn't changed for a minute (scp finished) and renamed to *.imported or *.failed; the
# otel-import-cleanup timer on the node deletes those later. (Alloy has no OTLP-file receiver.)
first_line_is_object() {
  head -c 1 "$1" | grep -q '{' && [ "$(head -n 1 "$1" | tail -c 2)" = "}" ]
}
post() {  # $1 file with one OTLP/JSON request, $2 tenant
  if grep -q '"resourceSpans"' "$1"; then p=v1/traces
  elif grep -q '"resourceMetrics"' "$1"; then p=v1/metrics
  elif grep -q '"resourceLogs"' "$1"; then p=v1/logs
  else echo "not OTLP/JSON: $1"; return 1; fi
  wget -q -O /dev/null --header "Content-Type: application/json" --header "X-Scope-OrgID: $2" \
    --post-file "$1" "http://127.0.0.1:4320/$p"
}
while true; do
  find /otel-import -mindepth 2 -maxdepth 2 -type f -name '*.json' -mmin +0 | while read -r f; do
    tenant=$(basename "$(dirname "$f")"); ok=1
    # JSON Lines = several lines and the first line is a complete object "{...}"
    if [ "$(grep -c . "$f")" -gt 1 ] && first_line_is_object "$f"; then
      # JSON Lines: one request per line
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf '%s' "$line" > /tmp/request.json
        post /tmp/request.json "$tenant" || ok=0
      done < "$f"
    else
      post "$f" "$tenant" || ok=0
    fi
    if [ $ok = 1 ]; then mv "$f" "$f.imported"; echo "imported $f (tenant $tenant)"
    else mv "$f" "$f.failed"; echo "FAILED $f (tenant $tenant)"; fi
  done
  sleep 15
done
