#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QWEN_LOADTEST_TARGET_IMAGE_OVERRIDE="${QWEN_LOADTEST_TARGET_IMAGE:-}"
QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME_OVERRIDE="${QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME:-}"
QWEN_LOADTEST_KEDA_QUERY_OVERRIDE="${QWEN_LOADTEST_KEDA_QUERY:-}"
QWEN_LOADTEST_TEST_MODE_OVERRIDE="${QWEN_LOADTEST_TEST_MODE:-}"
QWEN_LOADTEST_TEST_PATH_OVERRIDE="${QWEN_LOADTEST_TEST_PATH:-}"
QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY_OVERRIDE="${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY:-}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
if [[ -n "${QWEN_LOADTEST_TEST_MODE_OVERRIDE}" ]]; then
  QWEN_LOADTEST_TEST_MODE="${QWEN_LOADTEST_TEST_MODE_OVERRIDE}"
fi
if [[ -n "${QWEN_LOADTEST_TEST_PATH_OVERRIDE}" ]]; then
  QWEN_LOADTEST_TEST_PATH="${QWEN_LOADTEST_TEST_PATH_OVERRIDE}"
fi
if [[ -n "${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY_OVERRIDE}" ]]; then
  QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY="${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY_OVERRIDE}"
fi
need_cmd kubectl
need_cmd python3

require_env \
  AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME MONITOR_WORKSPACE_QUERY_ENDPOINT

if [[ -f "${GENERATED_ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${GENERATED_ENV_FILE}"
  set +a
fi
if [[ -n "${QWEN_LOADTEST_TARGET_IMAGE_OVERRIDE}" ]]; then
  QWEN_LOADTEST_TARGET_IMAGE="${QWEN_LOADTEST_TARGET_IMAGE_OVERRIDE}"
fi
if [[ -n "${QWEN_LOADTEST_KEDA_QUERY_OVERRIDE}" ]]; then
  QWEN_LOADTEST_KEDA_QUERY="${QWEN_LOADTEST_KEDA_QUERY_OVERRIDE}"
fi
if [[ -n "${QWEN_LOADTEST_TEST_MODE_OVERRIDE}" ]]; then
  QWEN_LOADTEST_TEST_MODE="${QWEN_LOADTEST_TEST_MODE_OVERRIDE}"
fi
if [[ -n "${QWEN_LOADTEST_TEST_PATH_OVERRIDE}" ]]; then
  QWEN_LOADTEST_TEST_PATH="${QWEN_LOADTEST_TEST_PATH_OVERRIDE}"
fi
if [[ -n "${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY_OVERRIDE}" ]]; then
  QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY="${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY_OVERRIDE}"
fi
ensure_aks_kubeconfig

QWEN_LOADTEST_NAMESPACE="${QWEN_LOADTEST_NAMESPACE:-qwen-loadtest}"
QWEN_LOADTEST_NAME="${QWEN_LOADTEST_NAME:-qwen-loadtest-target}"
QWEN_LOADTEST_SERVICE_NAME="${QWEN_LOADTEST_SERVICE_NAME:-${QWEN_LOADTEST_NAME}}"
QWEN_LOADTEST_GATEWAY_NAME="${QWEN_LOADTEST_GATEWAY_NAME:-qwen-loadtest-external}"
QWEN_LOADTEST_TLS_SECRET_NAME="${QWEN_LOADTEST_TLS_SECRET_NAME:-qwen-loadtest-target-tls}"
QWEN_LOADTEST_CERTIFICATE_NAME="${QWEN_LOADTEST_CERTIFICATE_NAME:-${QWEN_LOADTEST_NAME}}"
QWEN_LOADTEST_CERT_ISSUER_NAME="${QWEN_LOADTEST_CERT_ISSUER_NAME:-${CERT_MANAGER_PROD_ISSUER_NAME:-letsencrypt-prod}}"
QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE="${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE:-aks-istio-ingress}"
QWEN_LOADTEST_GATEWAY_SELECTOR="${QWEN_LOADTEST_GATEWAY_SELECTOR:-aks-istio-ingressgateway-external}"
QWEN_LOADTEST_KEDA_AUTH_NAME="${QWEN_LOADTEST_KEDA_AUTH_NAME:-${KEDA_PROMETHEUS_AUTH_NAME:-azure-managed-prometheus}}"
QWEN_LOADTEST_ISTIO_REVISION="${QWEN_LOADTEST_ISTIO_REVISION:-}"
QWEN_LOADTEST_CONTAINER_PORT="${QWEN_LOADTEST_CONTAINER_PORT:-8080}"
QWEN_LOADTEST_SERVICE_PORT="${QWEN_LOADTEST_SERVICE_PORT:-8080}"
QWEN_LOADTEST_MIN_REPLICAS="${QWEN_LOADTEST_MIN_REPLICAS:-1}"
QWEN_LOADTEST_MAX_REPLICAS="${QWEN_LOADTEST_MAX_REPLICAS:-8}"
QWEN_LOADTEST_POLLING_INTERVAL="${QWEN_LOADTEST_POLLING_INTERVAL:-5}"
QWEN_LOADTEST_COOLDOWN_PERIOD="${QWEN_LOADTEST_COOLDOWN_PERIOD:-60}"
QWEN_LOADTEST_KEDA_THRESHOLD="${QWEN_LOADTEST_KEDA_THRESHOLD:-1}"
QWEN_LOADTEST_KEDA_ACTIVATION_THRESHOLD="${QWEN_LOADTEST_KEDA_ACTIVATION_THRESHOLD:-1}"
QWEN_LOADTEST_GPU_REQUEST="${QWEN_LOADTEST_GPU_REQUEST:-1}"
QWEN_LOADTEST_CPU_REQUEST="${QWEN_LOADTEST_CPU_REQUEST:-4}"
QWEN_LOADTEST_CPU_LIMIT="${QWEN_LOADTEST_CPU_LIMIT:-8}"
QWEN_LOADTEST_MEMORY_REQUEST="${QWEN_LOADTEST_MEMORY_REQUEST:-24Gi}"
QWEN_LOADTEST_MEMORY_LIMIT="${QWEN_LOADTEST_MEMORY_LIMIT:-32Gi}"
QWEN_LOADTEST_GPU_TYPE="${QWEN_LOADTEST_GPU_TYPE:-${GPU_TYPE:-}}"
QWEN_LOADTEST_NODE_WORKLOAD_LABEL="${QWEN_LOADTEST_NODE_WORKLOAD_LABEL:-gpu-test}"
QWEN_LOADTEST_TARGET_IMAGE="${QWEN_LOADTEST_TARGET_IMAGE:-}"
QWEN_LOADTEST_SOURCE_IMAGE="${QWEN_LOADTEST_SOURCE_LOGIN_SERVER}/${QWEN_LOADTEST_SOURCE_IMAGE_REPOSITORY}:${QWEN_LOADTEST_SOURCE_IMAGE_TAG}"
QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME="${QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME_OVERRIDE:-${QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME:-qwen-loadtest-source-regcred}}"

resolve_istio_revision() {
  local revision="${QWEN_LOADTEST_ISTIO_REVISION:-}"

  if [[ -z "${revision}" && -n "${ISTIO_REVISIONS_CSV:-}" ]]; then
    IFS=',' read -r revision _ <<<"${ISTIO_REVISIONS_CSV}"
  fi

  if [[ -z "${revision}" && -n "${SERVICE_MESH_REVISIONS_CSV:-}" ]]; then
    IFS=',' read -r revision _ <<<"${SERVICE_MESH_REVISIONS_CSV}"
  fi

  if [[ -z "${revision}" ]]; then
    revision="$(kubectl get mutatingwebhookconfigurations -o name 2>/dev/null | grep -o 'asm-[0-9-]\+' | head -n 1 || true)"
  fi

  [[ -n "${revision}" ]] || fail "Unable to determine AKS managed Istio revision. Set QWEN_LOADTEST_ISTIO_REVISION or ensure ISTIO_REVISIONS_CSV is exported."
  printf '%s\n' "${revision}"
}

ensure_namespace_with_revision() {
  local namespace="$1"
  local revision="$2"

  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "${namespace}" istio.io/rev="${revision}" --overwrite >/dev/null
}

ensure_shared_keda_auth() {
  if ! kubectl get clustertriggerauthentication.keda.sh "${QWEN_LOADTEST_KEDA_AUTH_NAME}" >/dev/null 2>&1; then
    fail "Shared KEDA ClusterTriggerAuthentication ${QWEN_LOADTEST_KEDA_AUTH_NAME} not found. Run the environment bootstrap first so KEDA can query Azure Managed Prometheus."
  fi
}

ensure_cert_manager_ready() {
  local ingress_class_name="${CERT_MANAGER_INGRESS_CLASS_NAME:-istio}"
  local issuer_ready

  kubectl get ingressclass "${ingress_class_name}" >/dev/null 2>&1 || fail "IngressClass ${ingress_class_name} not found. Run the environment bootstrap first."
  kubectl get clusterissuer "${QWEN_LOADTEST_CERT_ISSUER_NAME}" >/dev/null 2>&1 || fail "ClusterIssuer ${QWEN_LOADTEST_CERT_ISSUER_NAME} not found. Run the environment bootstrap first."

  issuer_ready="$(kubectl get clusterissuer "${QWEN_LOADTEST_CERT_ISSUER_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [[ "${issuer_ready}" == "True" ]] || fail "ClusterIssuer ${QWEN_LOADTEST_CERT_ISSUER_NAME} is not Ready. Check cert-manager installation first."
}

ensure_host_resolves_to_gateway_ip() {
  local host="$1"
  local expected_ip="$2"
  local attempts="${3:-18}"
  local attempt
  local resolved

  for attempt in $(seq 1 "${attempts}"); do
    resolved="$(python3 - "${host}" <<'PY'
import socket
import sys

host = sys.argv[1]
ips = sorted({item[4][0] for item in socket.getaddrinfo(host, None, family=socket.AF_INET)})
print(",".join(ips))
PY
 2>/dev/null || true)"

    if [[ ",${resolved}," == *",${expected_ip},"* ]]; then
      return 0
    fi

    warn "Waiting for ${host} to resolve to ${expected_ip} (${attempt}/${attempts}); current A records: ${resolved:-none}"
    sleep 10
  done

  fail "Host ${host} does not resolve to external gateway IP ${expected_ip}. Update DNS first or leave QWEN_LOADTEST_HOST empty to use sslip.io."
}

ensure_image_pull_secret() {
  if [[ "${QWEN_LOADTEST_TARGET_IMAGE}" != "${QWEN_LOADTEST_SOURCE_LOGIN_SERVER}/"* ]]; then
    return 0
  fi

  [[ -n "${QWEN_LOADTEST_SOURCE_PASSWORD:-}" ]] || fail "QWEN_LOADTEST_SOURCE_PASSWORD is required when deploying directly from ${QWEN_LOADTEST_SOURCE_LOGIN_SERVER}"

  kubectl -n "${QWEN_LOADTEST_NAMESPACE}" create secret docker-registry "${QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME}" \
    --docker-server="${QWEN_LOADTEST_SOURCE_LOGIN_SERVER}" \
    --docker-username="${QWEN_LOADTEST_SOURCE_USERNAME}" \
    --docker-password="${QWEN_LOADTEST_SOURCE_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

wait_for_certificate_ready() {
  local namespace="$1"
  local name="$2"
  local attempts="${3:-90}"
  local attempt
  local ready
  local secret_pem

  for attempt in $(seq 1 "${attempts}"); do
    ready="$(kubectl get certificate "${name}" -n "${namespace}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    secret_pem="$(kubectl get secret "${QWEN_LOADTEST_TLS_SECRET_NAME}" -n "${namespace}" -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)"
    if [[ "${ready}" == "True" && -n "${secret_pem}" ]]; then
      return 0
    fi

    warn "Waiting for Certificate ${namespace}/${name} to become Ready (${attempt}/${attempts})"
    sleep 10
  done

  kubectl get certificate,certificaterequest,order,challenge,ingress -n "${namespace}" 2>/dev/null || true
  kubectl describe certificate "${name}" -n "${namespace}" 2>/dev/null || true
  fail "Certificate ${namespace}/${name} was not issued in time"
}

[[ -n "${QWEN_LOADTEST_TARGET_IMAGE}" ]] || fail "QWEN_LOADTEST_TARGET_IMAGE is empty. Run 00-prepare/10-sync-qwen-model.sh first, or export QWEN_LOADTEST_TARGET_IMAGE explicitly."
[[ -n "${QWEN_LOADTEST_GPU_TYPE}" ]] || fail "QWEN_LOADTEST_GPU_TYPE or GPU_TYPE is required"

QWEN_LOADTEST_ISTIO_REVISION="$(resolve_istio_revision)"
ensure_namespace_with_revision "${QWEN_LOADTEST_NAMESPACE}" "${QWEN_LOADTEST_ISTIO_REVISION}"
ensure_image_pull_secret
ensure_shared_keda_auth
ensure_cert_manager_ready

external_gateway_ip="$(kubectl get service "${QWEN_LOADTEST_GATEWAY_SELECTOR}" -n "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
[[ -n "${external_gateway_ip}" ]] || fail "Unable to resolve external Istio gateway IP from ${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}/${QWEN_LOADTEST_GATEWAY_SELECTOR}"

if [[ -z "${QWEN_LOADTEST_HOST:-}" ]]; then
  QWEN_LOADTEST_HOST="${QWEN_LOADTEST_NAME}.${external_gateway_ip}.sslip.io"
fi

ensure_host_resolves_to_gateway_ip "${QWEN_LOADTEST_HOST}" "${external_gateway_ip}"

QWEN_LOADTEST_URL="https://${QWEN_LOADTEST_HOST}"
QWEN_LOADTEST_UPSTREAM_CLUSTER="outbound|${QWEN_LOADTEST_SERVICE_PORT}||${QWEN_LOADTEST_SERVICE_NAME}.${QWEN_LOADTEST_NAMESPACE}.svc.cluster.local"
default_qwen_keda_query="sum(envoy_cluster_upstream_rq_active{app=\"${QWEN_LOADTEST_GATEWAY_SELECTOR}\",cluster_name=\"${QWEN_LOADTEST_UPSTREAM_CLUSTER}\"}) or vector(0)"

if [[ -z "${QWEN_LOADTEST_KEDA_QUERY:-}" ]] || printf '%s\n' "${QWEN_LOADTEST_KEDA_QUERY}" | grep -Eq 'cluster_name="[^"]+"\) or vector\(0\)\}$'; then
  QWEN_LOADTEST_KEDA_QUERY="${default_qwen_keda_query}"
fi

image_pull_secrets_yaml=""
if [[ "${QWEN_LOADTEST_TARGET_IMAGE}" == "${QWEN_LOADTEST_SOURCE_LOGIN_SERVER}/"* ]]; then
  image_pull_secrets_yaml="$(cat <<EOF
      imagePullSecrets:
        - name: ${QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME}
EOF
)"
fi

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${QWEN_LOADTEST_NAME}
  namespace: ${QWEN_LOADTEST_NAMESPACE}
spec:
  progressDeadlineSeconds: 3600
  replicas: ${QWEN_LOADTEST_MIN_REPLICAS}
  selector:
    matchLabels:
      app: ${QWEN_LOADTEST_NAME}
  template:
    metadata:
      labels:
        app: ${QWEN_LOADTEST_NAME}
    spec:
${image_pull_secrets_yaml}
      terminationGracePeriodSeconds: 30
      tolerations:
        - key: workload
          operator: Equal
          value: ${QWEN_LOADTEST_NODE_WORKLOAD_LABEL}
          effect: NoSchedule
        - key: kubernetes.azure.com/scalesetpriority
          operator: Equal
          value: spot
          effect: NoSchedule
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: workload
                    operator: In
                    values: ["${QWEN_LOADTEST_NODE_WORKLOAD_LABEL}"]
                  - key: gputype
                    operator: In
                    values: ["${QWEN_LOADTEST_GPU_TYPE}"]
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: karpenter.sh/capacity-type
                    operator: In
                    values: ["spot"]
      containers:
        - name: ${QWEN_LOADTEST_NAME}
          image: ${QWEN_LOADTEST_TARGET_IMAGE}
          imagePullPolicy: Always
          ports:
            - name: http
              containerPort: ${QWEN_LOADTEST_CONTAINER_PORT}
          startupProbe:
            tcpSocket:
              port: http
            failureThreshold: 120
            periodSeconds: 5
          readinessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 20
            periodSeconds: 10
          resources:
            requests:
              cpu: ${QWEN_LOADTEST_CPU_REQUEST}
              memory: ${QWEN_LOADTEST_MEMORY_REQUEST}
              nvidia.com/gpu: "${QWEN_LOADTEST_GPU_REQUEST}"
            limits:
              cpu: ${QWEN_LOADTEST_CPU_LIMIT}
              memory: ${QWEN_LOADTEST_MEMORY_LIMIT}
              nvidia.com/gpu: "${QWEN_LOADTEST_GPU_REQUEST}"
---
apiVersion: v1
kind: Service
metadata:
  name: ${QWEN_LOADTEST_SERVICE_NAME}
  namespace: ${QWEN_LOADTEST_NAMESPACE}
spec:
  selector:
    app: ${QWEN_LOADTEST_NAME}
  ports:
    - name: http
      port: ${QWEN_LOADTEST_SERVICE_PORT}
      targetPort: http
EOF

kubectl delete gateway.networking.istio.io "${QWEN_LOADTEST_GATEWAY_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete virtualservice.networking.istio.io "${QWEN_LOADTEST_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${QWEN_LOADTEST_CERTIFICATE_NAME}
  namespace: ${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}
spec:
  secretName: ${QWEN_LOADTEST_TLS_SECRET_NAME}
  issuerRef:
    kind: ClusterIssuer
    name: ${QWEN_LOADTEST_CERT_ISSUER_NAME}
  dnsNames:
    - ${QWEN_LOADTEST_HOST}
EOF

wait_for_certificate_ready "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" "${QWEN_LOADTEST_CERTIFICATE_NAME}"

cat <<EOF | kubectl apply -f - >/dev/null
---
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: ${QWEN_LOADTEST_GATEWAY_NAME}
  namespace: ${QWEN_LOADTEST_NAMESPACE}
spec:
  selector:
    istio: ${QWEN_LOADTEST_GATEWAY_SELECTOR}
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - ${QWEN_LOADTEST_HOST}
      tls:
        httpsRedirect: true
    - port:
        number: 443
        name: https
        protocol: HTTPS
      hosts:
        - ${QWEN_LOADTEST_HOST}
      tls:
        mode: SIMPLE
        credentialName: ${QWEN_LOADTEST_TLS_SECRET_NAME}
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ${QWEN_LOADTEST_NAME}
  namespace: ${QWEN_LOADTEST_NAMESPACE}
spec:
  hosts:
    - ${QWEN_LOADTEST_HOST}
  gateways:
    - ${QWEN_LOADTEST_GATEWAY_NAME}
  http:
    - route:
        - destination:
            host: ${QWEN_LOADTEST_SERVICE_NAME}.${QWEN_LOADTEST_NAMESPACE}.svc.cluster.local
            port:
              number: ${QWEN_LOADTEST_SERVICE_PORT}
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: ${QWEN_LOADTEST_NAME}
  namespace: ${QWEN_LOADTEST_NAMESPACE}
spec:
  host: ${QWEN_LOADTEST_SERVICE_NAME}.${QWEN_LOADTEST_NAMESPACE}.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      simple: LEAST_REQUEST
    connectionPool:
      http:
        http1MaxPendingRequests: 1
        maxRequestsPerConnection: 1
EOF

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: ${QWEN_LOADTEST_NAME}
  namespace: ${QWEN_LOADTEST_NAMESPACE}
spec:
  scaleTargetRef:
    name: ${QWEN_LOADTEST_NAME}
  minReplicaCount: ${QWEN_LOADTEST_MIN_REPLICAS}
  maxReplicaCount: ${QWEN_LOADTEST_MAX_REPLICAS}
  pollingInterval: ${QWEN_LOADTEST_POLLING_INTERVAL}
  cooldownPeriod: ${QWEN_LOADTEST_COOLDOWN_PERIOD}
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 0
          policies:
            - type: Pods
              value: 4
              periodSeconds: 15
        scaleDown:
          stabilizationWindowSeconds: 60
          policies:
            - type: Percent
              value: 100
              periodSeconds: 15
  triggers:
    - type: prometheus
      metricType: AverageValue
      authenticationRef:
        name: ${QWEN_LOADTEST_KEDA_AUTH_NAME}
        kind: ClusterTriggerAuthentication
      metadata:
        serverAddress: ${MONITOR_WORKSPACE_QUERY_ENDPOINT}
        query: >-
          ${QWEN_LOADTEST_KEDA_QUERY}
        threshold: "${QWEN_LOADTEST_KEDA_THRESHOLD}"
        activationThreshold: "${QWEN_LOADTEST_KEDA_ACTIVATION_THRESHOLD}"
EOF

kubectl rollout status deployment/${QWEN_LOADTEST_NAME} -n "${QWEN_LOADTEST_NAMESPACE}" --timeout=30m >/dev/null

for attempt in $(seq 1 30); do
  if kubectl get hpa -n "${QWEN_LOADTEST_NAMESPACE}" | grep -q "${QWEN_LOADTEST_NAME}"; then
    break
  fi

  if [[ "${attempt}" == "30" ]]; then
    fail "Timed out waiting for KEDA-generated HPA for ${QWEN_LOADTEST_NAME}"
  fi

  sleep 5
done

write_generated_env QWEN_LOADTEST_NAMESPACE "${QWEN_LOADTEST_NAMESPACE}"
write_generated_env QWEN_LOADTEST_NAME "${QWEN_LOADTEST_NAME}"
write_generated_env QWEN_LOADTEST_SERVICE_NAME "${QWEN_LOADTEST_SERVICE_NAME}"
write_generated_env QWEN_LOADTEST_HOST "${QWEN_LOADTEST_HOST}"
write_generated_env QWEN_LOADTEST_URL "${QWEN_LOADTEST_URL}"
write_generated_env QWEN_LOADTEST_GATEWAY_IP "${external_gateway_ip}"
write_generated_env QWEN_LOADTEST_TEST_MODE "${QWEN_LOADTEST_TEST_MODE}"
write_generated_env QWEN_LOADTEST_TEST_PATH "${QWEN_LOADTEST_TEST_PATH}"
write_generated_env QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY "${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY}"
write_generated_env QWEN_LOADTEST_CERTIFICATE_NAME "${QWEN_LOADTEST_CERTIFICATE_NAME}"
write_generated_env QWEN_LOADTEST_CERT_ISSUER_NAME "${QWEN_LOADTEST_CERT_ISSUER_NAME}"
write_generated_env QWEN_LOADTEST_TLS_SECRET_NAME "${QWEN_LOADTEST_TLS_SECRET_NAME}"
write_generated_env QWEN_LOADTEST_GATEWAY_SELECTOR "${QWEN_LOADTEST_GATEWAY_SELECTOR}"
write_generated_env QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}"
write_generated_env QWEN_LOADTEST_KEDA_AUTH_NAME "${QWEN_LOADTEST_KEDA_AUTH_NAME}"
write_generated_env QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME "${QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME}"
write_generated_env QWEN_LOADTEST_ISTIO_REVISION "${QWEN_LOADTEST_ISTIO_REVISION}"
write_generated_env QWEN_LOADTEST_KEDA_QUERY "${QWEN_LOADTEST_KEDA_QUERY}"

log "Deployment completed"
log "  namespace       : ${QWEN_LOADTEST_NAMESPACE}"
log "  target image    : ${QWEN_LOADTEST_TARGET_IMAGE}"
log "  istio revision  : ${QWEN_LOADTEST_ISTIO_REVISION}"
log "  gateway selector: ${QWEN_LOADTEST_GATEWAY_SELECTOR}"
log "  tls issuer      : ${QWEN_LOADTEST_CERT_ISSUER_NAME}"
log "  url             : ${QWEN_LOADTEST_URL}"
log "  gateway ip      : ${external_gateway_ip}"
log "  keda query      : ${QWEN_LOADTEST_KEDA_QUERY}"