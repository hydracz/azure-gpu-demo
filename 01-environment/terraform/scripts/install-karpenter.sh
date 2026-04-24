#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

required_vars=(
  KUBECONFIG_FILE
  AZURE_SUBSCRIPTION_ID
  RESOURCE_GROUP
  LOCATION
  CLUSTER_NAME
  AKS_ENDPOINT
  SYSTEM_POOL_NAME
  KARPENTER_NAMESPACE
  KARPENTER_SERVICE_ACCOUNT
  KARPENTER_CLIENT_ID
  KARPENTER_PRINCIPAL_ID
  KARPENTER_CHART_DIR
  KARPENTER_CRD_CHART_DIR
  KARPENTER_TARGET_IMAGE_REPOSITORY
  KARPENTER_IMAGE_TAG
  EXISTING_VNET_SUBNET_ID
  AZURE_NODE_RESOURCE_GROUP
  KUBELET_IDENTITY_CLIENT_ID
  NODE_IDENTITIES
  NETWORK_PLUGIN
  NETWORK_PLUGIN_MODE
  NETWORK_POLICY
  SSH_PUBLIC_KEY
  GPU_NODE_IMAGE_FAMILY
  GPU_OS_DISK_SIZE_GB
  INSTALL_GPU_DRIVERS
  GPU_ZONES_CSV
  GPU_SKU_NAME
  SPOT_MAX_PRICE
  CONSOLIDATE_AFTER
  GPU_NODE_CLASS
)

source_shared_env_preserving_current "${SHARED_ENV_FILE:-}" "${required_vars[@]}"

need_cmd helm
need_cmd kubectl
need_cmd python3
need_cmd az

for required_var in "${required_vars[@]}"; do
  [[ -n "${!required_var:-}" ]] || fail "${required_var} is required"
done

ROLE_ASSIGNMENT_MAX_RETRIES="${ROLE_ASSIGNMENT_MAX_RETRIES:-6}"
ROLE_ASSIGNMENT_RETRY_SECONDS="${ROLE_ASSIGNMENT_RETRY_SECONDS:-10}"

[[ -d "${KARPENTER_CHART_DIR}" ]] || fail "Karpenter chart not found: ${KARPENTER_CHART_DIR}"
[[ -d "${KARPENTER_CRD_CHART_DIR}" ]] || fail "Karpenter CRD chart not found: ${KARPENTER_CRD_CHART_DIR}"

refresh_aks_kubeconfig
wait_for_cluster_api
gpu_node_scheduling_key="${GPU_NODE_SCHEDULING_KEY:-scheduling.azure-gpu-demo/dedicated}"

assign_role_if_missing() {
  local role="$1"
  local scope="$2"
  local principal="$3"
  local existing attempt create_output scope_name

  scope_name="$(basename "${scope}")"

  role_assignment_exists() {
    local current_role="$1"
    local current_scope="$2"
    local current_principal="$3"

    az role assignment list \
      --assignee "${current_principal}" \
      --role "${current_role}" \
      --scope "${current_scope}" \
      --query "length(@)" \
      -o tsv \
      --only-show-errors 2>/dev/null
  }

  existing="$(role_assignment_exists "${role}" "${scope}" "${principal}" || echo 0)"

  if [[ "${existing}" != "0" ]]; then
    log "Role '${role}' already assigned on ${scope_name}"
    return 0
  fi

  for attempt in $(seq 1 "${ROLE_ASSIGNMENT_MAX_RETRIES}"); do
    log "Ensuring role '${role}' on ${scope_name} (attempt ${attempt}/${ROLE_ASSIGNMENT_MAX_RETRIES})"

    if create_output="$(az role assignment create \
      --assignee-object-id "${KARPENTER_PRINCIPAL_ID}" \
      --assignee-principal-type ServicePrincipal \
      --role "${role}" \
      --scope "${scope}" \
      --only-show-errors \
      -o none 2>&1)"; then
      log "Assigned role '${role}' on ${scope_name}"
      return 0
    fi

    if [[ "${create_output}" == *"RoleAssignmentExists"* ]]; then
      log "Role '${role}' already assigned on ${scope_name}"
      return 0
    fi

    existing="$(role_assignment_exists "${role}" "${scope}" "${principal}" || echo 0)"
    if [[ "${existing}" != "0" ]]; then
      log "Role '${role}' already assigned on ${scope_name}"
      return 0
    fi

    if [[ "${create_output}" == *"PrincipalNotFound"* || "${create_output}" == *"does not exist in the directory"* || "${create_output}" == *"could not be found"* || "${create_output}" == *"Insufficient privileges to complete the operation"* ]]; then
      if (( attempt < ROLE_ASSIGNMENT_MAX_RETRIES )); then
        warn "Role assignment for '${role}' on ${scope_name} is waiting for directory propagation; retrying in ${ROLE_ASSIGNMENT_RETRY_SECONDS}s"
        sleep "${ROLE_ASSIGNMENT_RETRY_SECONDS}"
        continue
      fi
    fi

    fail "Failed to assign role '${role}' on ${scope_name}: ${create_output}"
  done
}

node_rg_id="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_NODE_RESOURCE_GROUP}"
assign_role_if_missing "Managed Identity Operator" "${node_rg_id}" "${KARPENTER_PRINCIPAL_ID}"

bootstrap_secret_name="$(kubectl get secrets -n kube-system -o go-template='{{range .items}}{{if eq .type "bootstrap.kubernetes.io/token"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | head -n1)"
[[ -n "${bootstrap_secret_name}" ]] || fail "No bootstrap token secret found in kube-system"

bootstrap_token_id="$(kubectl get secret -n kube-system "${bootstrap_secret_name}" -o jsonpath='{.data.token-id}' | base64 -d)"
bootstrap_token_secret="$(kubectl get secret -n kube-system "${bootstrap_secret_name}" -o jsonpath='{.data.token-secret}' | base64 -d)"
[[ -n "${bootstrap_token_id}" && -n "${bootstrap_token_secret}" ]] || fail "Bootstrap token secret ${bootstrap_secret_name} is incomplete"

kubelet_bootstrap_token="${bootstrap_token_id}.${bootstrap_token_secret}"

gpu_zones_yaml="$(python3 - <<'PY' "${GPU_ZONES_CSV}"
import sys

zones = [zone.strip() for zone in sys.argv[1].split(',') if zone.strip()]
if not zones:
    raise SystemExit('GPU_ZONES_CSV must contain at least one zone')

for zone in zones:
    print(f'            - {zone}')
PY
)"

tmp_values_file="$(mktemp)"
cleanup() {
  rm -f "${tmp_values_file}"
}
trap cleanup EXIT

cat >"${tmp_values_file}" <<EOF
serviceAccount:
  name: ${KARPENTER_SERVICE_ACCOUNT}
  annotations:
    azure.workload.identity/client-id: "${KARPENTER_CLIENT_ID}"
podLabels:
  azure.workload.identity/use: "true"
controller:
  env:
    - name: KUBELET_BOOTSTRAP_TOKEN
      value: "${kubelet_bootstrap_token}"
    - name: SSH_PUBLIC_KEY
      value: "${SSH_PUBLIC_KEY}"
    - name: VNET_SUBNET_ID
      value: "${EXISTING_VNET_SUBNET_ID}"
    - name: AZURE_NODE_RESOURCE_GROUP
      value: "${AZURE_NODE_RESOURCE_GROUP}"
    - name: AZURE_SUBSCRIPTION_ID
      value: "${AZURE_SUBSCRIPTION_ID}"
    - name: LOCATION
      value: "${LOCATION}"
    - name: NETWORK_PLUGIN
      value: "${NETWORK_PLUGIN}"
    - name: NETWORK_PLUGIN_MODE
      value: "${NETWORK_PLUGIN_MODE}"
    - name: NETWORK_POLICY
      value: "${NETWORK_POLICY}"
    - name: KUBELET_IDENTITY_CLIENT_ID
      value: "${KUBELET_IDENTITY_CLIENT_ID}"
    - name: NODE_IDENTITIES
      value: "${NODE_IDENTITIES}"
EOF

log "Installing karpenter-crd from ${KARPENTER_CRD_CHART_DIR}"
helm upgrade --install karpenter-crd \
  "${KARPENTER_CRD_CHART_DIR}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --create-namespace

for crd_name in \
  aksnodeclasses.karpenter.azure.com \
  nodeclaims.karpenter.sh \
  nodeoverlays.karpenter.sh \
  nodepools.karpenter.sh
do
  wait_for_crd "${crd_name}" 30
done

log "Installing karpenter from ${KARPENTER_CHART_DIR}"
helm upgrade --install karpenter \
  "${KARPENTER_CHART_DIR}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --reset-values \
  -f "${tmp_values_file}" \
  --set "serviceMonitor.enabled=true" \
  --set "controller.image.repository=${KARPENTER_TARGET_IMAGE_REPOSITORY}" \
  --set "controller.image.tag=${KARPENTER_IMAGE_TAG}" \
  --set "controller.image.digest=" \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${AKS_ENDPOINT}" \
  --set "replicas=1" \
  --timeout 5m

log "Waiting for Karpenter deployment rollout"
wait_for_deployment_rollout "${KARPENTER_NAMESPACE}" karpenter 30 10

log "Applying Azure Monitor ServiceMonitor mirror for Karpenter"
KUBECONFIG_FILE="${KUBECONFIG_FILE}" \
KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE}" \
  bash "${SCRIPT_DIR}/../../scripts/apply-azmonitor-servicemonitors.sh"

log "Applying GPU AKSNodeClass and NodePools"
cat <<EOF | kubectl apply -f -
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: gpu
  annotations:
    kubernetes.io/description: "GPU AKSNodeClass - overlay node subnet, 1TiB ephemeral OS disk, skip GPU driver installation"
spec:
  imageFamily: ${GPU_NODE_IMAGE_FAMILY}
  vnetSubnetID: ${EXISTING_VNET_SUBNET_ID}
  osDiskSizeGB: ${GPU_OS_DISK_SIZE_GB}
  installGPUDrivers: ${INSTALL_GPU_DRIVERS}
EOF

cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-spot-pool
  annotations:
    kubernetes.io/description: "Spot GPU pool - may fail if Spot quota < 128 vCPU"
spec:
  weight: 100
  template:
    metadata:
      labels:
        ${gpu_node_scheduling_key}: ${GPU_NODE_CLASS}
      annotations:
        karpenter.azure.com/spot-max-price: "${SPOT_MAX_PRICE}"
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: topology.kubernetes.io/zone
          operator: In
          values:
${gpu_zones_yaml}
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["${GPU_SKU_NAME}"]
      taints:
        - key: ${gpu_node_scheduling_key}
          value: ${GPU_NODE_CLASS}
          effect: NoSchedule
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: gpu
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: ${CONSOLIDATE_AFTER}
EOF

cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-ondemand-pool
  annotations:
    kubernetes.io/description: "On-demand GPU pool - seed and fallback capacity, scale from zero when idle"
spec:
  weight: 50
  template:
    metadata:
      labels:
        ${gpu_node_scheduling_key}: ${GPU_NODE_CLASS}
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: topology.kubernetes.io/zone
          operator: In
          values:
${gpu_zones_yaml}
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["${GPU_SKU_NAME}"]
      taints:
        - key: ${gpu_node_scheduling_key}
          value: ${GPU_NODE_CLASS}
          effect: NoSchedule
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: gpu
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: ${CONSOLIDATE_AFTER}
EOF

log "Karpenter deployment completed"
log "  Scheduling key : ${gpu_node_scheduling_key}=${GPU_NODE_CLASS}"