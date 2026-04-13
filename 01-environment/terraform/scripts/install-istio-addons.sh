#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../scripts/image-sync-lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../scripts/kiali-image-sync.sh"

need_cmd az
need_cmd helm
need_cmd kubectl

for required_var in \
  KUBECONFIG_FILE AZURE_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME ACR_NAME \
  ISTIO_INTERNAL_INGRESS_GATEWAY_ENABLED ISTIO_EXTERNAL_INGRESS_GATEWAY_ENABLED \
  ISTIO_INTERNAL_INGRESS_GATEWAY_MIN_REPLICAS ISTIO_INTERNAL_INGRESS_GATEWAY_MAX_REPLICAS \
  ISTIO_EXTERNAL_INGRESS_GATEWAY_MIN_REPLICAS ISTIO_EXTERNAL_INGRESS_GATEWAY_MAX_REPLICAS \
  ISTIO_KIALI_ENABLED ISTIO_KIALI_NAMESPACE ISTIO_KIALI_REPLICAS \
  ISTIO_KIALI_VIEW_ONLY_MODE ISTIO_KIALI_OPERATOR_CHART_VERSION \
  ISTIO_KIALI_PROMETHEUS_RETENTION_PERIOD ISTIO_KIALI_PROMETHEUS_SCRAPE_INTERVAL \
  ISTIO_KIALI_PROXY_SERVICE_NAME ISTIO_KIALI_PROXY_SERVICE_ACCOUNT_NAME MONITOR_WORKSPACE_QUERY_ENDPOINT
do
  [[ -n "${!required_var:-}" ]] || fail "${required_var} is required"
done

refresh_aks_kubeconfig
wait_for_cluster_api

if [[ "${ISTIO_KIALI_ENABLED}" == "true" ]]; then
  sync_kiali_images
fi

validate_replica_pair() {
  local gateway_name="$1"
  local min_replicas="$2"
  local max_replicas="$3"

  [[ "${min_replicas}" =~ ^[0-9]+$ ]] || fail "${gateway_name} min replicas must be an integer"
  [[ "${max_replicas}" =~ ^[0-9]+$ ]] || fail "${gateway_name} max replicas must be an integer"
  (( min_replicas >= 2 )) || fail "${gateway_name} min replicas must be >= 2 for AKS managed Istio"
  (( max_replicas >= min_replicas )) || fail "${gateway_name} max replicas must be >= min replicas"
}

wait_for_hpa_prefix() {
  local prefix="$1"
  local hpa_names=""
  local attempt

  for attempt in $(seq 1 30); do
    hpa_names="$(kubectl get hpa -n aks-istio-ingress -o name 2>/dev/null | grep "${prefix}-" || true)"
    if [[ -n "${hpa_names}" ]]; then
      printf '%s\n' "${hpa_names}"
      return 0
    fi

    warn "Waiting for HPA ${prefix} in aks-istio-ingress (${attempt}/30)"
    sleep 10
  done

  fail "HPA ${prefix} not found in aks-istio-ingress"
}

patch_gateway_hpa() {
  local gateway_type="$1"
  local min_replicas="$2"
  local max_replicas="$3"
  local prefix="aks-istio-ingressgateway-${gateway_type}"
  local hpa_name

  validate_replica_pair "${gateway_type} ingress gateway" "${min_replicas}" "${max_replicas}"

  while IFS= read -r hpa_name; do
    [[ -n "${hpa_name}" ]] || continue
    log "Patching ${hpa_name} with min=${min_replicas}, max=${max_replicas}"
    kubectl patch "${hpa_name}" -n aks-istio-ingress --type merge \
      --patch "{\"spec\":{\"minReplicas\":${min_replicas},\"maxReplicas\":${max_replicas}}}" >/dev/null
  done < <(wait_for_hpa_prefix "${prefix}")
}

ensure_namespace() {
  local namespace="$1"
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

wait_for_deployment() {
  local namespace="$1"
  local name="$2"
  local attempt

  for attempt in $(seq 1 60); do
    if kubectl get deployment "${name}" -n "${namespace}" >/dev/null 2>&1; then
      return 0
    fi

    warn "Waiting for deployment ${name} in ${namespace} (${attempt}/60)"
    sleep 10
  done

  fail "Deployment ${name} was not created in ${namespace}"
}

wait_for_kiali_success() {
  local namespace="$1"
  local attempt
  local successful
  local failure

  for attempt in $(seq 1 60); do
    successful="$(kubectl get kiali kiali -n "${namespace}" -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || true)"
    if [[ "${successful}" == "True" ]]; then
      return 0
    fi

    failure="$(kubectl get kiali kiali -n "${namespace}" -o jsonpath='{.status.conditions[?(@.type=="Failure")].status}' 2>/dev/null || true)"
    if [[ "${failure}" == "True" ]]; then
      kubectl get kiali kiali -n "${namespace}" -o yaml >&2 || true
      fail "Kiali operator reported reconciliation failure"
    fi

    warn "Waiting for Kiali reconciliation in ${namespace} (${attempt}/60)"
    sleep 10
  done

  kubectl get kiali kiali -n "${namespace}" -o yaml >&2 || true
  fail "Timed out waiting for Kiali reconciliation"
}

deploy_azure_monitor_query_proxy() {
  [[ -n "${ISTIO_KIALI_PROXY_CLIENT_ID:-}" ]] || fail "ISTIO_KIALI_PROXY_CLIENT_ID is required when Kiali is enabled"

  ensure_namespace "${ISTIO_KIALI_NAMESPACE}"

  log "Deploying Azure Monitor auth proxy in ${ISTIO_KIALI_NAMESPACE}"
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${ISTIO_KIALI_PROXY_SERVICE_ACCOUNT_NAME}
  namespace: ${ISTIO_KIALI_NAMESPACE}
  annotations:
    azure.workload.identity/client-id: "${ISTIO_KIALI_PROXY_CLIENT_ID}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${ISTIO_KIALI_PROXY_SERVICE_NAME}
  namespace: ${ISTIO_KIALI_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${ISTIO_KIALI_PROXY_SERVICE_NAME}
  template:
    metadata:
      labels:
        app: ${ISTIO_KIALI_PROXY_SERVICE_NAME}
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: ${ISTIO_KIALI_PROXY_SERVICE_ACCOUNT_NAME}
      containers:
        - name: aad-auth-proxy
          image: ${ISTIO_KIALI_PROXY_TARGET_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - name: auth-port
              containerPort: 8082
          env:
            - name: AUDIENCE
              value: https://prometheus.monitor.azure.com/.default
            - name: TARGET_HOST
              value: ${MONITOR_WORKSPACE_QUERY_ENDPOINT}
            - name: LISTENING_PORT
              value: "8082"
          livenessProbe:
            httpGet:
              path: /health
              port: auth-port
            initialDelaySeconds: 5
            timeoutSeconds: 5
          readinessProbe:
            httpGet:
              path: /ready
              port: auth-port
            initialDelaySeconds: 5
            timeoutSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: ${ISTIO_KIALI_PROXY_SERVICE_NAME}
  namespace: ${ISTIO_KIALI_NAMESPACE}
spec:
  selector:
    app: ${ISTIO_KIALI_PROXY_SERVICE_NAME}
  ports:
    - name: http
      port: 80
      targetPort: 8082
EOF

  kubectl rollout status deployment/${ISTIO_KIALI_PROXY_SERVICE_NAME} -n "${ISTIO_KIALI_NAMESPACE}" --timeout=5m
}

install_kiali() {
  local proxy_url="http://${ISTIO_KIALI_PROXY_SERVICE_NAME}.${ISTIO_KIALI_NAMESPACE}.svc.cluster.local"

  ensure_namespace "${ISTIO_KIALI_NAMESPACE}"

  log "Installing Kiali operator into ${ISTIO_KIALI_NAMESPACE}"
  helm repo add kiali https://kiali.org/helm-charts >/dev/null 2>&1 || true
  helm repo update kiali >/dev/null
  helm upgrade --install kiali-operator kiali/kiali-operator \
    --namespace "${ISTIO_KIALI_NAMESPACE}" \
    --create-namespace \
    --version "${ISTIO_KIALI_OPERATOR_CHART_VERSION}" \
    --set "image.repo=${ISTIO_KIALI_OPERATOR_TARGET_IMAGE_REPOSITORY}" \
    --set "image.tag=${ISTIO_KIALI_IMAGE_TAG}" \
    --set allowAdHocKialiImage=true \
    --wait \
    --timeout 10m >/dev/null

  kubectl wait --for=condition=Established crd/kialis.kiali.io --timeout=2m >/dev/null

  log "Applying Kiali custom resource"
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: kiali.io/v1alpha1
kind: Kiali
metadata:
  name: kiali
  namespace: ${ISTIO_KIALI_NAMESPACE}
  annotations:
    ansible.sdk.operatorframework.io/verbosity: "1"
spec:
  auth:
    strategy: anonymous
  deployment:
    namespace: ${ISTIO_KIALI_NAMESPACE}
    cluster_wide_access: true
    image_name: ${ISTIO_KIALI_TARGET_IMAGE_NAME}
    image_version: ${ISTIO_KIALI_IMAGE_TAG}
    service_type: ClusterIP
    replicas: ${ISTIO_KIALI_REPLICAS}
    view_only_mode: ${ISTIO_KIALI_VIEW_ONLY_MODE}
  external_services:
    grafana:
      enabled: false
    prometheus:
      url: "${proxy_url}"
      health_check_url: "${proxy_url}/ready"
      thanos_proxy:
        enabled: true
        retention_period: "${ISTIO_KIALI_PROMETHEUS_RETENTION_PERIOD}"
        scrape_interval: "${ISTIO_KIALI_PROMETHEUS_SCRAPE_INTERVAL}"
  istio_labels:
    ingress_gateway_label: "azureservicemesh/istio.component=ingress-gateway"
  server:
    web_root: "/"
EOF

  wait_for_kiali_success "${ISTIO_KIALI_NAMESPACE}"
  wait_for_deployment "${ISTIO_KIALI_NAMESPACE}" kiali
  kubectl rollout status deployment/kiali -n "${ISTIO_KIALI_NAMESPACE}" --timeout=10m
}

if [[ "${ISTIO_EXTERNAL_INGRESS_GATEWAY_ENABLED}" == "true" ]]; then
  patch_gateway_hpa external "${ISTIO_EXTERNAL_INGRESS_GATEWAY_MIN_REPLICAS}" "${ISTIO_EXTERNAL_INGRESS_GATEWAY_MAX_REPLICAS}"
fi

if [[ "${ISTIO_INTERNAL_INGRESS_GATEWAY_ENABLED}" == "true" ]]; then
  patch_gateway_hpa internal "${ISTIO_INTERNAL_INGRESS_GATEWAY_MIN_REPLICAS}" "${ISTIO_INTERNAL_INGRESS_GATEWAY_MAX_REPLICAS}"
fi

if [[ "${ISTIO_KIALI_ENABLED}" == "true" ]]; then
  deploy_azure_monitor_query_proxy
  install_kiali
fi