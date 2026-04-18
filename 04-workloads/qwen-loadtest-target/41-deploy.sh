#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QWEN_LOADTEST_TARGET_IMAGE_OVERRIDE="${QWEN_LOADTEST_TARGET_IMAGE:-}"
QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME_OVERRIDE="${QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME:-}"
QWEN_LOADTEST_KEDA_QUERY_OVERRIDE="${QWEN_LOADTEST_KEDA_QUERY:-}"
QWEN_LOADTEST_HOST_OVERRIDE="${QWEN_LOADTEST_HOST:-}"
QWEN_LOADTEST_GATEWAY_SCHEME_OVERRIDE="${QWEN_LOADTEST_GATEWAY_SCHEME:-}"
MONITOR_WORKSPACE_QUERY_ENDPOINT_OVERRIDE="${MONITOR_WORKSPACE_QUERY_ENDPOINT:-}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common.sh"

load_env
if [[ -n "${QWEN_LOADTEST_GATEWAY_SCHEME_OVERRIDE}" ]]; then
  QWEN_LOADTEST_GATEWAY_SCHEME="${QWEN_LOADTEST_GATEWAY_SCHEME_OVERRIDE}"
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
if [[ -n "${MONITOR_WORKSPACE_QUERY_ENDPOINT_OVERRIDE}" ]]; then
  MONITOR_WORKSPACE_QUERY_ENDPOINT="${MONITOR_WORKSPACE_QUERY_ENDPOINT_OVERRIDE}"
fi
if [[ -n "${QWEN_LOADTEST_TARGET_IMAGE_OVERRIDE}" ]]; then
  QWEN_LOADTEST_TARGET_IMAGE="${QWEN_LOADTEST_TARGET_IMAGE_OVERRIDE}"
fi
if [[ -n "${QWEN_LOADTEST_KEDA_QUERY_OVERRIDE}" ]]; then
  QWEN_LOADTEST_KEDA_QUERY="${QWEN_LOADTEST_KEDA_QUERY_OVERRIDE}"
fi
if [[ -n "${QWEN_LOADTEST_HOST_OVERRIDE}" ]]; then
  QWEN_LOADTEST_HOST="${QWEN_LOADTEST_HOST_OVERRIDE}"
fi
ensure_aks_kubeconfig

QWEN_LOADTEST_NAMESPACE="${QWEN_LOADTEST_NAMESPACE:-qwen-loadtest}"
QWEN_LOADTEST_NAME="${QWEN_LOADTEST_NAME:-qwen-loadtest-target}"
QWEN_LOADTEST_SERVICE_NAME="${QWEN_LOADTEST_SERVICE_NAME:-${QWEN_LOADTEST_NAME}}"
QWEN_LOADTEST_GATEWAY_NAME="${QWEN_LOADTEST_GATEWAY_NAME:-qwen-loadtest-internal}"
QWEN_LOADTEST_GATEWAY_CLASS_NAME="${QWEN_LOADTEST_GATEWAY_CLASS_NAME:-istio}"
QWEN_LOADTEST_GATEWAY_INTERNAL_LB="${QWEN_LOADTEST_GATEWAY_INTERNAL_LB:-true}"
QWEN_LOADTEST_GATEWAY_SCHEME="${QWEN_LOADTEST_GATEWAY_SCHEME:-http}"
QWEN_LOADTEST_TLS_ENABLED="${QWEN_LOADTEST_TLS_ENABLED:-false}"
QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE="${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE:-${QWEN_LOADTEST_NAMESPACE}}"
QWEN_LOADTEST_GATEWAY_SELECTOR="${QWEN_LOADTEST_GATEWAY_SELECTOR:-${QWEN_LOADTEST_GATEWAY_NAME}}"
QWEN_LOADTEST_KEDA_AUTH_NAME="${QWEN_LOADTEST_KEDA_AUTH_NAME:-${KEDA_PROMETHEUS_AUTH_NAME:-azure-managed-prometheus}}"
QWEN_LOADTEST_ISTIO_REVISION="${QWEN_LOADTEST_ISTIO_REVISION:-}"
QWEN_LOADTEST_CONTAINER_PORT="${QWEN_LOADTEST_CONTAINER_PORT:-8080}"
QWEN_LOADTEST_SERVICE_PORT="${QWEN_LOADTEST_SERVICE_PORT:-8080}"
QWEN_LOADTEST_SEED_MIN_REPLICAS="${QWEN_LOADTEST_SEED_MIN_REPLICAS:-1}"
QWEN_LOADTEST_SEED_MAX_REPLICAS="${QWEN_LOADTEST_SEED_MAX_REPLICAS:-2}"
QWEN_LOADTEST_ELASTIC_MIN_REPLICAS="${QWEN_LOADTEST_ELASTIC_MIN_REPLICAS:-0}"
QWEN_LOADTEST_ELASTIC_MAX_REPLICAS="${QWEN_LOADTEST_ELASTIC_MAX_REPLICAS:-4}"
QWEN_LOADTEST_POLLING_INTERVAL="${QWEN_LOADTEST_POLLING_INTERVAL:-30}"
QWEN_LOADTEST_COOLDOWN_PERIOD="${QWEN_LOADTEST_COOLDOWN_PERIOD:-600}"
QWEN_LOADTEST_KEDA_QUERY_WINDOW="${QWEN_LOADTEST_KEDA_QUERY_WINDOW:-5m}"
QWEN_LOADTEST_KEDA_THRESHOLD="${QWEN_LOADTEST_KEDA_THRESHOLD:-30}"
QWEN_LOADTEST_KEDA_ACTIVATION_THRESHOLD="${QWEN_LOADTEST_KEDA_ACTIVATION_THRESHOLD:-12}"
QWEN_LOADTEST_ELASTIC_SCALEUP_PODS="${QWEN_LOADTEST_ELASTIC_SCALEUP_PODS:-1}"
QWEN_LOADTEST_ELASTIC_SCALEUP_PERIOD_SECONDS="${QWEN_LOADTEST_ELASTIC_SCALEUP_PERIOD_SECONDS:-60}"
QWEN_LOADTEST_ELASTIC_SCALEDOWN_STABILIZATION_SECONDS="${QWEN_LOADTEST_ELASTIC_SCALEDOWN_STABILIZATION_SECONDS:-600}"
QWEN_LOADTEST_ELASTIC_SCALEDOWN_PERCENT="${QWEN_LOADTEST_ELASTIC_SCALEDOWN_PERCENT:-50}"
QWEN_LOADTEST_ELASTIC_SCALEDOWN_PERIOD_SECONDS="${QWEN_LOADTEST_ELASTIC_SCALEDOWN_PERIOD_SECONDS:-60}"
QWEN_LOADTEST_SEED_SCALEUP_PODS="${QWEN_LOADTEST_SEED_SCALEUP_PODS:-1}"
QWEN_LOADTEST_SEED_SCALEUP_PERIOD_SECONDS="${QWEN_LOADTEST_SEED_SCALEUP_PERIOD_SECONDS:-180}"
QWEN_LOADTEST_SEED_SCALEDOWN_STABILIZATION_SECONDS="${QWEN_LOADTEST_SEED_SCALEDOWN_STABILIZATION_SECONDS:-600}"
QWEN_LOADTEST_SEED_SCALEDOWN_PERCENT="${QWEN_LOADTEST_SEED_SCALEDOWN_PERCENT:-50}"
QWEN_LOADTEST_SEED_SCALEDOWN_PERIOD_SECONDS="${QWEN_LOADTEST_SEED_SCALEDOWN_PERIOD_SECONDS:-120}"
QWEN_LOADTEST_GPU_REQUEST="${QWEN_LOADTEST_GPU_REQUEST:-1}"
QWEN_LOADTEST_CPU_REQUEST="${QWEN_LOADTEST_CPU_REQUEST:-4}"
QWEN_LOADTEST_CPU_LIMIT="${QWEN_LOADTEST_CPU_LIMIT:-8}"
QWEN_LOADTEST_MEMORY_REQUEST="${QWEN_LOADTEST_MEMORY_REQUEST:-24Gi}"
QWEN_LOADTEST_MEMORY_LIMIT="${QWEN_LOADTEST_MEMORY_LIMIT:-32Gi}"
default_gpu_node_class="$(resolve_gpu_node_class)"
default_gpu_node_sku_label_value="$(derive_gpu_node_sku_label_value)"
QWEN_LOADTEST_GPU_NODE_CLASS="${QWEN_LOADTEST_GPU_NODE_CLASS:-${default_gpu_node_class}}"
QWEN_LOADTEST_GPU_NODE_SCHEDULING_KEY="${QWEN_LOADTEST_GPU_NODE_SCHEDULING_KEY:-${GPU_NODE_SCHEDULING_KEY:-scheduling.azure-gpu-demo/dedicated}}"
QWEN_LOADTEST_GPU_NODE_SKU_LABEL_VALUE="${QWEN_LOADTEST_GPU_NODE_SKU_LABEL_VALUE:-${default_gpu_node_sku_label_value}}"
QWEN_LOADTEST_TARGET_IMAGE="${QWEN_LOADTEST_TARGET_IMAGE:-}"
QWEN_LOADTEST_SOURCE_IMAGE="${QWEN_LOADTEST_SOURCE_LOGIN_SERVER}/${QWEN_LOADTEST_SOURCE_IMAGE_REPOSITORY}:${QWEN_LOADTEST_SOURCE_IMAGE_TAG}"
QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME="${QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME_OVERRIDE:-${QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME:-qwen-loadtest-source-regcred}}"
QWEN_LOADTEST_SEED_NAME="${QWEN_LOADTEST_SEED_NAME:-${QWEN_LOADTEST_NAME}-seed}"
QWEN_LOADTEST_ELASTIC_NAME="${QWEN_LOADTEST_ELASTIC_NAME:-${QWEN_LOADTEST_NAME}-elastic}"
QWEN_LOADTEST_SEED_SCALEDOBJECT_NAME="${QWEN_LOADTEST_SEED_SCALEDOBJECT_NAME:-${QWEN_LOADTEST_SEED_NAME}}"
QWEN_LOADTEST_ELASTIC_SCALEDOBJECT_NAME="${QWEN_LOADTEST_ELASTIC_SCALEDOBJECT_NAME:-${QWEN_LOADTEST_ELASTIC_NAME}}"

[[ -n "${QWEN_LOADTEST_GPU_NODE_SKU_LABEL_VALUE}" ]] || fail "Unable to determine karpenter.azure.com/sku-gpu-name label value from GPU_NODE_SKU_LABEL_VALUE or GPU_SKU_NAME"

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

require_integer_range() {
  local name="$1"
  local value="$2"
  local minimum="$3"
  local maximum="$4"

  [[ "${value}" =~ ^[0-9]+$ ]] || fail "${name} must be an integer, got: ${value}"
  (( value >= minimum && value <= maximum )) || fail "${name} must be between ${minimum} and ${maximum}, got: ${value}"
}

wait_for_hpa() {
  local scaledobject_name="$1"
  local attempts="${2:-30}"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl get hpa -n "${QWEN_LOADTEST_NAMESPACE}" | grep -q "${scaledobject_name}"; then
      return 0
    fi

    if [[ "${attempt}" == "${attempts}" ]]; then
      fail "Timed out waiting for KEDA-generated HPA for ${scaledobject_name}"
    fi

    sleep 5
  done
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

wait_for_deployment() {
  local namespace="$1"
  local name="$2"
  local attempts="${3:-60}"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl get deployment "${name}" -n "${namespace}" >/dev/null 2>&1; then
      return 0
    fi

    warn "Waiting for deployment ${namespace}/${name} (${attempt}/${attempts})"
    sleep 10
  done

  fail "Deployment ${namespace}/${name} was not created in time"
}

wait_for_service() {
  local namespace="$1"
  local name="$2"
  local attempts="${3:-60}"
  local attempt

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl get service "${name}" -n "${namespace}" >/dev/null 2>&1; then
      return 0
    fi

    warn "Waiting for service ${namespace}/${name} (${attempt}/${attempts})"
    sleep 10
  done

  fail "Service ${namespace}/${name} was not created in time"
}

wait_for_gateway_programmed() {
  local namespace="$1"
  local name="$2"

  kubectl wait \
    --for=condition=programmed \
    --timeout=20m \
    -n "${namespace}" \
    "gateway.gateway.networking.k8s.io/${name}" >/dev/null
}

apply_gateway() {
  local host="$1"
  local internal_lb_annotation=""

  if [[ "${QWEN_LOADTEST_GATEWAY_INTERNAL_LB}" == "true" ]]; then
    internal_lb_annotation="    service.beta.kubernetes.io/azure-load-balancer-internal: \"true\""
  fi

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${QWEN_LOADTEST_GATEWAY_NAME}
  namespace: ${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}
  annotations:
    gateway.istio.io/name-override: ${QWEN_LOADTEST_GATEWAY_SELECTOR}
${internal_lb_annotation}
  labels:
    istio.io/rev: ${QWEN_LOADTEST_ISTIO_REVISION}
spec:
  gatewayClassName: ${QWEN_LOADTEST_GATEWAY_CLASS_NAME}
  listeners:
    - name: http
      hostname: ${host}
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
EOF
}

resolve_gateway_lb_ip() {
  local address

  address="$(kubectl get gateway "${QWEN_LOADTEST_GATEWAY_NAME}" -n "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  if [[ -z "${address}" ]]; then
    address="$(kubectl get service "${QWEN_LOADTEST_GATEWAY_SELECTOR}" -n "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  fi

  printf '%s\n' "${address}"
}

wait_for_gateway_workload_ready() {
  wait_for_deployment "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" "${QWEN_LOADTEST_GATEWAY_SELECTOR}"
  kubectl rollout status deployment/"${QWEN_LOADTEST_GATEWAY_SELECTOR}" -n "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" --timeout=20m >/dev/null
  wait_for_service "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" "${QWEN_LOADTEST_GATEWAY_SELECTOR}"
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

is_repo_managed_keda_query() {
  local query="$1"

  [[ -z "${query}" ]] && return 0

  if [[ "${query}" == *"envoy_cluster_upstream_rq_"* ]]; then
    return 0
  fi

  if [[ "${query}" == *"istio_requests_total{"* && "${query}" == *"destination_service_name=\"${QWEN_LOADTEST_SERVICE_NAME}\""* ]]; then
    return 0
  fi

  if [[ "${query}" == *"istio_requests_total{"* && "${query}" == *"destination_workload=\"${QWEN_LOADTEST_NAME}\""* ]]; then
    return 0
  fi

  return 1
}

[[ -n "${QWEN_LOADTEST_TARGET_IMAGE}" ]] || fail "QWEN_LOADTEST_TARGET_IMAGE is empty. Run 00-prepare/10-sync-qwen-model.sh first, or export QWEN_LOADTEST_TARGET_IMAGE explicitly."
require_integer_range QWEN_LOADTEST_SEED_MIN_REPLICAS "${QWEN_LOADTEST_SEED_MIN_REPLICAS}" 1 3
require_integer_range QWEN_LOADTEST_SEED_MAX_REPLICAS "${QWEN_LOADTEST_SEED_MAX_REPLICAS}" 1 3
require_integer_range QWEN_LOADTEST_ELASTIC_MIN_REPLICAS "${QWEN_LOADTEST_ELASTIC_MIN_REPLICAS}" 0 7
require_integer_range QWEN_LOADTEST_ELASTIC_MAX_REPLICAS "${QWEN_LOADTEST_ELASTIC_MAX_REPLICAS}" 1 7
(( QWEN_LOADTEST_SEED_MIN_REPLICAS <= QWEN_LOADTEST_SEED_MAX_REPLICAS )) || fail "QWEN_LOADTEST_SEED_MIN_REPLICAS must be <= QWEN_LOADTEST_SEED_MAX_REPLICAS"
(( QWEN_LOADTEST_ELASTIC_MIN_REPLICAS <= QWEN_LOADTEST_ELASTIC_MAX_REPLICAS )) || fail "QWEN_LOADTEST_ELASTIC_MIN_REPLICAS must be <= QWEN_LOADTEST_ELASTIC_MAX_REPLICAS"
(( QWEN_LOADTEST_KEDA_ACTIVATION_THRESHOLD < QWEN_LOADTEST_KEDA_THRESHOLD )) || fail "QWEN_LOADTEST_KEDA_ACTIVATION_THRESHOLD must be lower than QWEN_LOADTEST_KEDA_THRESHOLD"

QWEN_LOADTEST_ISTIO_REVISION="$(resolve_istio_revision)"
ensure_namespace_with_revision "${QWEN_LOADTEST_NAMESPACE}" "${QWEN_LOADTEST_ISTIO_REVISION}"
ensure_image_pull_secret
ensure_shared_keda_auth

if [[ -z "${QWEN_LOADTEST_HOST:-}" || "${QWEN_LOADTEST_HOST}" == "${QWEN_LOADTEST_NAME}."*.sslip.io ]]; then
  QWEN_LOADTEST_HOST="${QWEN_LOADTEST_NAME}.internal"
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
  name: ${QWEN_LOADTEST_SEED_NAME}
  namespace: ${QWEN_LOADTEST_NAMESPACE}
spec:
  progressDeadlineSeconds: 3600
  replicas: ${QWEN_LOADTEST_SEED_MIN_REPLICAS}
  selector:
    matchLabels:
      app: ${QWEN_LOADTEST_NAME}
      component: seed
  template:
    metadata:
      labels:
        app: ${QWEN_LOADTEST_NAME}
        component: seed
    spec:
${image_pull_secrets_yaml}
      terminationGracePeriodSeconds: 30
      tolerations:
        - key: ${QWEN_LOADTEST_GPU_NODE_SCHEDULING_KEY}
          operator: Equal
          value: ${QWEN_LOADTEST_GPU_NODE_CLASS}
          effect: NoSchedule
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: ${QWEN_LOADTEST_GPU_NODE_SCHEDULING_KEY}
                    operator: In
                    values: ["${QWEN_LOADTEST_GPU_NODE_CLASS}"]
                  - key: karpenter.azure.com/sku-gpu-name
                    operator: In
                    values: ["${QWEN_LOADTEST_GPU_NODE_SKU_LABEL_VALUE}"]
                  - key: karpenter.sh/capacity-type
                    operator: In
                    values: ["on-demand"]
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values: ["${QWEN_LOADTEST_NAME}"]
                  - key: component
                    operator: In
                    values: ["seed"]
              topologyKey: kubernetes.io/hostname
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
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${QWEN_LOADTEST_ELASTIC_NAME}
  namespace: ${QWEN_LOADTEST_NAMESPACE}
spec:
  progressDeadlineSeconds: 3600
  replicas: ${QWEN_LOADTEST_ELASTIC_MIN_REPLICAS}
  selector:
    matchLabels:
      app: ${QWEN_LOADTEST_NAME}
      component: elastic
  template:
    metadata:
      labels:
        app: ${QWEN_LOADTEST_NAME}
        component: elastic
    spec:
${image_pull_secrets_yaml}
      terminationGracePeriodSeconds: 30
      tolerations:
        - key: ${QWEN_LOADTEST_GPU_NODE_SCHEDULING_KEY}
          operator: Equal
          value: ${QWEN_LOADTEST_GPU_NODE_CLASS}
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
                  - key: ${QWEN_LOADTEST_GPU_NODE_SCHEDULING_KEY}
                    operator: In
                    values: ["${QWEN_LOADTEST_GPU_NODE_CLASS}"]
                  - key: karpenter.azure.com/sku-gpu-name
                    operator: In
                    values: ["${QWEN_LOADTEST_GPU_NODE_SKU_LABEL_VALUE}"]
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: ${QWEN_LOADTEST_GPU_NODE_SCHEDULING_KEY}
                    operator: In
                    values: ["${QWEN_LOADTEST_GPU_NODE_CLASS}"]
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

kubectl delete deployment "${QWEN_LOADTEST_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete scaledobject.keda.sh "${QWEN_LOADTEST_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true

kubectl delete gateway.networking.istio.io "${QWEN_LOADTEST_GATEWAY_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete virtualservice.networking.istio.io "${QWEN_LOADTEST_NAME}" -n "${QWEN_LOADTEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true

apply_gateway "${QWEN_LOADTEST_HOST}"
wait_for_gateway_programmed "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}" "${QWEN_LOADTEST_GATEWAY_NAME}"
wait_for_gateway_workload_ready

gateway_lb_ip="$(resolve_gateway_lb_ip)"
[[ -n "${gateway_lb_ip}" ]] || fail "Unable to resolve Gateway API load balancer IP from ${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}/${QWEN_LOADTEST_GATEWAY_NAME}"

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${QWEN_LOADTEST_NAME}
  namespace: ${QWEN_LOADTEST_NAMESPACE}
spec:
  parentRefs:
    - name: ${QWEN_LOADTEST_GATEWAY_NAME}
      sectionName: http
  hostnames:
    - ${QWEN_LOADTEST_HOST}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: ${QWEN_LOADTEST_SERVICE_NAME}
          port: ${QWEN_LOADTEST_SERVICE_PORT}
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

QWEN_LOADTEST_URL="${QWEN_LOADTEST_GATEWAY_SCHEME}://${QWEN_LOADTEST_HOST}"
default_qwen_keda_query="sum(increase(istio_requests_total{reporter=\"destination\",source_workload=\"${QWEN_LOADTEST_GATEWAY_SELECTOR}\",destination_service_name=\"${QWEN_LOADTEST_SERVICE_NAME}\",response_code!~\"5..\"}[${QWEN_LOADTEST_KEDA_QUERY_WINDOW}])) or vector(0)"

if is_repo_managed_keda_query "${QWEN_LOADTEST_KEDA_QUERY_OVERRIDE:-${QWEN_LOADTEST_KEDA_QUERY:-}}"; then
  QWEN_LOADTEST_KEDA_QUERY="${default_qwen_keda_query}"
fi

QWEN_LOADTEST_SEED_QUERY_OFFSET="${QWEN_LOADTEST_SEED_QUERY_OFFSET:-$(( QWEN_LOADTEST_KEDA_THRESHOLD * QWEN_LOADTEST_ELASTIC_MAX_REPLICAS ))}"
QWEN_LOADTEST_ELASTIC_KEDA_QUERY="${QWEN_LOADTEST_ELASTIC_KEDA_QUERY:-${QWEN_LOADTEST_KEDA_QUERY}}"
QWEN_LOADTEST_SEED_KEDA_QUERY="${QWEN_LOADTEST_SEED_KEDA_QUERY:-clamp_min((${QWEN_LOADTEST_KEDA_QUERY}) - ${QWEN_LOADTEST_SEED_QUERY_OFFSET}, 0) or vector(0)}"

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: ${QWEN_LOADTEST_ELASTIC_SCALEDOBJECT_NAME}
  namespace: ${QWEN_LOADTEST_NAMESPACE}
spec:
  scaleTargetRef:
    name: ${QWEN_LOADTEST_ELASTIC_NAME}
  minReplicaCount: ${QWEN_LOADTEST_ELASTIC_MIN_REPLICAS}
  maxReplicaCount: ${QWEN_LOADTEST_ELASTIC_MAX_REPLICAS}
  pollingInterval: ${QWEN_LOADTEST_POLLING_INTERVAL}
  cooldownPeriod: ${QWEN_LOADTEST_COOLDOWN_PERIOD}
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 0
          policies:
            - type: Pods
              value: ${QWEN_LOADTEST_ELASTIC_SCALEUP_PODS}
              periodSeconds: ${QWEN_LOADTEST_ELASTIC_SCALEUP_PERIOD_SECONDS}
        scaleDown:
          stabilizationWindowSeconds: ${QWEN_LOADTEST_ELASTIC_SCALEDOWN_STABILIZATION_SECONDS}
          policies:
            - type: Percent
              value: ${QWEN_LOADTEST_ELASTIC_SCALEDOWN_PERCENT}
              periodSeconds: ${QWEN_LOADTEST_ELASTIC_SCALEDOWN_PERIOD_SECONDS}
  triggers:
    - type: prometheus
      metricType: AverageValue
      authenticationRef:
        name: ${QWEN_LOADTEST_KEDA_AUTH_NAME}
        kind: ClusterTriggerAuthentication
      metadata:
        serverAddress: ${MONITOR_WORKSPACE_QUERY_ENDPOINT}
        query: >-
          ${QWEN_LOADTEST_ELASTIC_KEDA_QUERY}
        threshold: "${QWEN_LOADTEST_KEDA_THRESHOLD}"
        activationThreshold: "${QWEN_LOADTEST_KEDA_ACTIVATION_THRESHOLD}"
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: ${QWEN_LOADTEST_SEED_SCALEDOBJECT_NAME}
  namespace: ${QWEN_LOADTEST_NAMESPACE}
spec:
  scaleTargetRef:
    name: ${QWEN_LOADTEST_SEED_NAME}
  minReplicaCount: ${QWEN_LOADTEST_SEED_MIN_REPLICAS}
  maxReplicaCount: ${QWEN_LOADTEST_SEED_MAX_REPLICAS}
  pollingInterval: ${QWEN_LOADTEST_POLLING_INTERVAL}
  cooldownPeriod: ${QWEN_LOADTEST_COOLDOWN_PERIOD}
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 0
          policies:
            - type: Pods
              value: ${QWEN_LOADTEST_SEED_SCALEUP_PODS}
              periodSeconds: ${QWEN_LOADTEST_SEED_SCALEUP_PERIOD_SECONDS}
        scaleDown:
          stabilizationWindowSeconds: ${QWEN_LOADTEST_SEED_SCALEDOWN_STABILIZATION_SECONDS}
          policies:
            - type: Percent
              value: ${QWEN_LOADTEST_SEED_SCALEDOWN_PERCENT}
              periodSeconds: ${QWEN_LOADTEST_SEED_SCALEDOWN_PERIOD_SECONDS}
  triggers:
    - type: prometheus
      metricType: AverageValue
      authenticationRef:
        name: ${QWEN_LOADTEST_KEDA_AUTH_NAME}
        kind: ClusterTriggerAuthentication
      metadata:
        serverAddress: ${MONITOR_WORKSPACE_QUERY_ENDPOINT}
        query: >-
          ${QWEN_LOADTEST_SEED_KEDA_QUERY}
        threshold: "${QWEN_LOADTEST_KEDA_THRESHOLD}"
        activationThreshold: "${QWEN_LOADTEST_KEDA_ACTIVATION_THRESHOLD}"
EOF

kubectl rollout status deployment/${QWEN_LOADTEST_SEED_NAME} -n "${QWEN_LOADTEST_NAMESPACE}" --timeout=30m >/dev/null

if (( QWEN_LOADTEST_ELASTIC_MIN_REPLICAS > 0 )); then
  kubectl rollout status deployment/${QWEN_LOADTEST_ELASTIC_NAME} -n "${QWEN_LOADTEST_NAMESPACE}" --timeout=30m >/dev/null
fi

wait_for_hpa "${QWEN_LOADTEST_ELASTIC_SCALEDOBJECT_NAME}"
wait_for_hpa "${QWEN_LOADTEST_SEED_SCALEDOBJECT_NAME}"

write_generated_env QWEN_LOADTEST_NAMESPACE "${QWEN_LOADTEST_NAMESPACE}"
write_generated_env QWEN_LOADTEST_NAME "${QWEN_LOADTEST_NAME}"
write_generated_env QWEN_LOADTEST_SERVICE_NAME "${QWEN_LOADTEST_SERVICE_NAME}"
write_generated_env QWEN_LOADTEST_SEED_NAME "${QWEN_LOADTEST_SEED_NAME}"
write_generated_env QWEN_LOADTEST_ELASTIC_NAME "${QWEN_LOADTEST_ELASTIC_NAME}"
write_generated_env QWEN_LOADTEST_SEED_SCALEDOBJECT_NAME "${QWEN_LOADTEST_SEED_SCALEDOBJECT_NAME}"
write_generated_env QWEN_LOADTEST_ELASTIC_SCALEDOBJECT_NAME "${QWEN_LOADTEST_ELASTIC_SCALEDOBJECT_NAME}"
write_generated_env QWEN_LOADTEST_SEED_MIN_REPLICAS "${QWEN_LOADTEST_SEED_MIN_REPLICAS}"
write_generated_env QWEN_LOADTEST_SEED_MAX_REPLICAS "${QWEN_LOADTEST_SEED_MAX_REPLICAS}"
write_generated_env QWEN_LOADTEST_ELASTIC_MIN_REPLICAS "${QWEN_LOADTEST_ELASTIC_MIN_REPLICAS}"
write_generated_env QWEN_LOADTEST_ELASTIC_MAX_REPLICAS "${QWEN_LOADTEST_ELASTIC_MAX_REPLICAS}"
write_generated_env QWEN_LOADTEST_HOST "${QWEN_LOADTEST_HOST}"
write_generated_env QWEN_LOADTEST_URL "${QWEN_LOADTEST_URL}"
write_generated_env QWEN_LOADTEST_GATEWAY_IP "${gateway_lb_ip}"
write_generated_env QWEN_LOADTEST_GATEWAY_SCHEME "${QWEN_LOADTEST_GATEWAY_SCHEME}"
write_generated_env QWEN_LOADTEST_GATEWAY_INTERNAL_LB "${QWEN_LOADTEST_GATEWAY_INTERNAL_LB}"
write_generated_env QWEN_LOADTEST_TLS_ENABLED "${QWEN_LOADTEST_TLS_ENABLED}"
write_generated_env QWEN_LOADTEST_TEST_MODE "${QWEN_LOADTEST_TEST_MODE}"
write_generated_env QWEN_LOADTEST_TEST_PATH "${QWEN_LOADTEST_TEST_PATH}"
write_generated_env QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY "${QWEN_LOADTEST_TEST_VIA_CLUSTER_GATEWAY}"
write_generated_env QWEN_LOADTEST_GATEWAY_SELECTOR "${QWEN_LOADTEST_GATEWAY_SELECTOR}"
write_generated_env QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE "${QWEN_LOADTEST_GATEWAY_WORKLOAD_NAMESPACE}"
write_generated_env QWEN_LOADTEST_KEDA_AUTH_NAME "${QWEN_LOADTEST_KEDA_AUTH_NAME}"
write_generated_env MONITOR_WORKSPACE_QUERY_ENDPOINT "${MONITOR_WORKSPACE_QUERY_ENDPOINT}"
write_generated_env QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME "${QWEN_LOADTEST_IMAGE_PULL_SECRET_NAME}"
write_generated_env QWEN_LOADTEST_ISTIO_REVISION "${QWEN_LOADTEST_ISTIO_REVISION}"
write_generated_env QWEN_LOADTEST_KEDA_QUERY "${QWEN_LOADTEST_KEDA_QUERY}"
write_generated_env QWEN_LOADTEST_ELASTIC_KEDA_QUERY "${QWEN_LOADTEST_ELASTIC_KEDA_QUERY}"
write_generated_env QWEN_LOADTEST_SEED_QUERY_OFFSET "${QWEN_LOADTEST_SEED_QUERY_OFFSET}"
write_generated_env QWEN_LOADTEST_SEED_KEDA_QUERY "${QWEN_LOADTEST_SEED_KEDA_QUERY}"

log "Deployment completed"
log "  namespace       : ${QWEN_LOADTEST_NAMESPACE}"
log "  target image    : ${QWEN_LOADTEST_TARGET_IMAGE}"
log "  seed deploy     : ${QWEN_LOADTEST_SEED_NAME} (${QWEN_LOADTEST_SEED_MIN_REPLICAS}-${QWEN_LOADTEST_SEED_MAX_REPLICAS}, require on-demand)"
log "  elastic deploy  : ${QWEN_LOADTEST_ELASTIC_NAME} (${QWEN_LOADTEST_ELASTIC_MIN_REPLICAS}-${QWEN_LOADTEST_ELASTIC_MAX_REPLICAS}, prefer spot, fallback on-demand)"
log "  gpu selector    : ${QWEN_LOADTEST_GPU_NODE_SCHEDULING_KEY}=${QWEN_LOADTEST_GPU_NODE_CLASS}"
log "  gpu sku label   : karpenter.azure.com/sku-gpu-name=${QWEN_LOADTEST_GPU_NODE_SKU_LABEL_VALUE}"
log "  istio revision  : ${QWEN_LOADTEST_ISTIO_REVISION}"
log "  gateway service : ${QWEN_LOADTEST_GATEWAY_SELECTOR}"
log "  url             : ${QWEN_LOADTEST_URL}"
log "  gateway ip      : ${gateway_lb_ip}"
log "  base query      : ${QWEN_LOADTEST_KEDA_QUERY}"
log "  elastic query   : ${QWEN_LOADTEST_ELASTIC_KEDA_QUERY}"
log "  seed offset     : ${QWEN_LOADTEST_SEED_QUERY_OFFSET}"
log "  seed query      : ${QWEN_LOADTEST_SEED_KEDA_QUERY}"