#!/usr/bin/env bash

set -Eeuo pipefail

sa_namespace="${SA_NAMESPACE:-redhat-ods-monitoring}"
sa_name="${SA_NAME:-usage-logs-reader}"
namespace="${NAMESPACE:-ai-grid-policies}"
secret_name="${SECRET_NAME:-usage-logs-hub-read-credential}"
duration="${TOKEN_DURATION:-8760h}"
route_namespace="${ROUTE_NAMESPACE:-redhat-ods-monitoring}"
route_name="${ROUTE_NAME:-usage-logs}"
endpoint_override="${ENDPOINT:-}"
context="${HUB_CONTEXT:-}"

usage() {
  cat <<'EOF'
Mint the hub usage-log reader token, record the query endpoint, and store
both in the Secret the ai-grid-usage-logs spoke Policy ships to every
selected site's read consumer.

The chart cannot create the token: a ServiceAccount token is not a
declarative object. Nor can it render the endpoint: the Route host differs
per fleet and the Argo CD repo-server renders without cluster access. So
this script discovers the Route at runtime and the Policy reads both keys
from the Secret with fromSecret, delivering $ocm_encrypted ciphertext --
neither value ever appears in a managed cluster's manifest.

The identity is read-only -- `get` on the infrastructure tenant, no `create`
-- so a leaked token exposes usage records but cannot corrupt them.

Re-running rotates the token and refreshes the endpoint. The Policy
re-resolves the Secret and each site picks up the new values, so rotation
is the same operation as creation.

Optional environment:
  HUB_CONTEXT     Hub kubeconfig context.
  SA_NAMESPACE    ServiceAccount namespace; defaults to redhat-ods-monitoring,
                  where apps/ai-grid-o11y puts the read identity.
  SA_NAME         ServiceAccount name; defaults to usage-logs-reader.
  NAMESPACE       Secret namespace; defaults to ai-grid-policies, which is
                  spokePolicy.namespace.
  SECRET_NAME     Secret name; defaults to usage-logs-hub-read-credential, which is
                  spokePolicy.readCredential.credentialSecretName.
  TOKEN_DURATION  Token lifetime; defaults to 8760h (one year). The cluster's
                  --service-account-max-token-expiration may cap it; the
                  Verify section of the README prints what was actually issued.
  ROUTE_NAMESPACE Namespace of the store's Route; defaults to
                  redhat-ods-monitoring, where apps/ai-grid-o11y's LokiStack
                  lives.
  ROUTE_NAME      Route name; defaults to usage-logs, which the Loki operator
                  creates from that LokiStack.
  ENDPOINT        Write this query endpoint instead of deriving it from the
                  Route. Must be the tenant root --
                  https://<host>/api/logs/v1/infrastructure, without /otlp --
                  because the consumer appends the Loki API paths itself.
                  Validated like the derived value: the script refuses to write
                  an endpoint that is not https, carries /otlp, or is not the
                  tenant root.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

for required_command in kubectl base64; do
  command -v "$required_command" >/dev/null 2>&1 || die "required command not found: $required_command"
done

kubectl_args=()
if [ -n "$context" ]; then
  kubectl_args+=(--context "$context")
fi

# The ServiceAccount belongs to apps/ai-grid-o11y, which owns the store. A
# token minted before that app has synced would fail with an API error rather
# than a reason, so say which Application has to run first.
kubectl "${kubectl_args[@]}" get serviceaccount "$sa_name" -n "$sa_namespace" >/dev/null 2>&1 ||
  die "serviceaccount $sa_namespace/$sa_name not found: let the ai-grid-o11y Application sync first"

token="$(kubectl "${kubectl_args[@]}" create token "$sa_name" \
  --namespace "$sa_namespace" --duration="$duration")"
# Never write an empty or truncated credential: the Policy would ship it to
# every site and each consumer would fail to authenticate with no clear cause.
[ -n "$token" ] || die "failed to create a token for $sa_namespace/$sa_name"
case "$token" in
  *.*.*) ;;
  *) die "token for $sa_namespace/$sa_name is not a JWT; refusing to write it" ;;
esac

# The query endpoint is the store Route's host plus the tenant root, the same
# derivation the Policy's hub template used when the chart still rendered it.
# The Loki operator creates the Route from apps/ai-grid-o11y's LokiStack, so it
# exists without this app rendering a store -- but not until that app has
# synced and the operator has reconciled, hence the check with a reason.
if [ -n "$endpoint_override" ]; then
  endpoint="$endpoint_override"
else
  route_host="$(kubectl "${kubectl_args[@]}" get route "$route_name" -n "$route_namespace" \
    -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || true)"
  [ -n "$route_host" ] ||
    die "route $route_namespace/$route_name has no ingress host yet: let the ai-grid-o11y Application sync and the Loki operator reconcile first, or set ENDPOINT"
  endpoint="https://${route_host}/api/logs/v1/infrastructure"
fi
case "$endpoint" in
  https://*) ;;
  *) die "endpoint does not start with https://: $endpoint" ;;
esac
# The same mistakes the chart's Helm validation used to catch, moved here because
# this Secret is now the only source of the endpoint: a /otlp suffix is the ingest
# route (every query 404s), and any other path is not the tenant root the consumer
# appends the Loki API paths to.
case "$endpoint" in
  */otlp|*/otlp/*) die "endpoint must not contain /otlp: that is the ingest route, which answers every query with 404. The query endpoint is the tenant root https://<host>/api/logs/v1/infrastructure (got: $endpoint)" ;;
esac
case "$endpoint" in
  https://*/api/logs/v1/infrastructure) ;;
  *) die "endpoint must be the tenant root https://<host>/api/logs/v1/infrastructure, without a query or fragment (got: $endpoint)" ;;
esac

# Declarative, so it cannot collide with Argo CD creating the same namespace
# between a check and a create on a fresh hub.
kubectl "${kubectl_args[@]}" create namespace "$namespace" --dry-run=client -o yaml |
  kubectl "${kubectl_args[@]}" apply -f - -
token_b64="$(printf '%s' "$token" | base64 -w0)"
endpoint_b64="$(printf '%s' "$endpoint" | base64 -w0)"

kubectl "${kubectl_args[@]}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $secret_name
  namespace: $namespace
type: Opaque
data:
  token: $token_b64
  endpoint: $endpoint_b64
EOF

printf 'Created or updated %s/%s from %s/%s.\n' "$namespace" "$secret_name" "$sa_namespace" "$sa_name"
if [ -n "$endpoint_override" ]; then
  printf 'Query endpoint recorded from ENDPOINT.\n'
else
  printf 'Query endpoint recorded from route %s/%s.\n' "$route_namespace" "$route_name"
fi
