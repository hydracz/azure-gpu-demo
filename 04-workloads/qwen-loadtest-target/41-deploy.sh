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
need_cmd openssl

require_env \
  AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME MONITOR_WORKSPACE_QUERY_ENDPOINT

if [[ -z "${QWEN_LOADTEST_TARGET_IMAGE_OVERRIDE}" ]]; then
  bash "${SCRIPT_DIR}/40-sync-image.sh"
fi
set -a
# shellcheck disable=SC1090
source "${GENERATED_ENV_FILE}"
set +a
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

[[ -n "${QWEN_LOADTEST_TARGET_IMAGE}" ]] || fail "QWEN_LOADTEST_TARGET_IMAGE is empty. Run 40-sync-image.sh first."
[[ -n "${QWEN_LOADTEST_GPU_TYPE}" ]] || fail "QWEN_LOADTEST_GPU_TYPE or GPU_TYPE is required"

QWEN_LOADTEST_ISTIO_REVISION="$(resolve_istio_revision)"
ensure_namespace_with_revision "${QWEN_LOADTEST_NAMESPACE}" "${QWEN_LOADTEST_ISTIO_REVISION}"
ensure_image_pull_secret
ensure_shared_keda_auth

external_gateway_ip="$(kubectl get service "${QWEN_LOADTEST_GATEWAY_SELECTOR}" -n "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
[[ -n "${external_gateway_ip}" ]] || fail "Unable to resolve external Istio gateway IP from ${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}/${QWEN_LOADTEST_GATEWAY_SELECTOR}"

if [[ -z "${QWEN_LOADTEST_HOST:-}" ]]; then
  QWEN_LOADTEST_HOST="${QWEN_LOADTEST_NAME}.${external_gateway_ip}.sslip.io"
fi

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

tls_tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tls_tmp_dir}"' EXIT

cat >"${tls_tmp_dir}/openssl.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = ${QWEN_LOADTEST_HOST}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${QWEN_LOADTEST_HOST}
EOF

openssl req \
  -x509 \
  -nodes \
  -days 365 \
  -newkey rsa:2048 \
  -keyout "${tls_tmp_dir}/tls.key" \
  -out "${tls_tmp_dir}/tls.crt" \
  -config "${tls_tmp_dir}/openssl.cnf" >/dev/null 2>&1

kubectl -n "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" create secret tls "${QWEN_LOADTEST_TLS_SECRET_NAME}" \
  --cert="${tls_tmp_dir}/tls.crt" \
  --key="${tls_tmp_dir}/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

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
log "  url             : ${QWEN_LOADTEST_URL}"
log "  gateway ip      : ${external_gateway_ip}"
log "  keda query      : ${QWEN_LOADTEST_KEDA_QUERY}"