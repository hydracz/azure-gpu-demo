#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

need_cmd az
need_cmd kubectl

for required_var in \
  KUBECONFIG_FILE AZURE_SUBSCRIPTION_ID RESOURCE_GROUP LOCATION CLUSTER_NAME \
  MONITOR_WORKSPACE_ID AKS_OIDC_ISSUER KEDA_PROMETHEUS_AUTH_NAME \
  KEDA_PROMETHEUS_IDENTITY_NAME KEDA_PROMETHEUS_OPERATOR_NAMESPACE \
  KEDA_PROMETHEUS_OPERATOR_SERVICE_ACCOUNT_NAME KEDA_PROMETHEUS_OPERATOR_DEPLOYMENT_NAME \
  KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME
do
  [[ -n "${!required_var:-}" ]] || fail "${required_var} is required"
done

refresh_aks_kubeconfig
wait_for_cluster_api
wait_for_deployment "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}" "${KEDA_PROMETHEUS_OPERATOR_DEPLOYMENT_NAME}"
wait_for_crd clustertriggerauthentications.keda.sh

keda_operator_client_id_annotation() {
  kubectl get serviceaccount "${KEDA_PROMETHEUS_OPERATOR_SERVICE_ACCOUNT_NAME}" \
    -n "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}" \
    -o jsonpath="{.metadata.annotations['azure\.workload\.identity/client-id']}" 2>/dev/null || true
}

keda_operator_use_label() {
  kubectl get deployment "${KEDA_PROMETHEUS_OPERATOR_DEPLOYMENT_NAME}" \
    -n "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}" \
    -o jsonpath="{.spec.template.metadata.labels['azure\.workload\.identity/use']}" 2>/dev/null || true
}

keda_operator_has_workload_identity_env() {
  local env_names

  env_names="$(kubectl get pods -n "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}" -l app.kubernetes.io/name=keda-operator -o jsonpath='{.items[0].spec.containers[0].env[*].name}' 2>/dev/null || true)"
  [[ "${env_names}" == *AZURE_FEDERATED_TOKEN_FILE* ]]
}

if ! az identity show --name "${KEDA_PROMETHEUS_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --only-show-errors >/dev/null 2>&1; then
  log "Creating shared KEDA managed identity ${KEDA_PROMETHEUS_IDENTITY_NAME}"
  az identity create \
    --name "${KEDA_PROMETHEUS_IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --only-show-errors \
    >/dev/null
fi

keda_prometheus_client_id="$(az identity show --name "${KEDA_PROMETHEUS_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --query clientId -o tsv --only-show-errors)"
keda_prometheus_principal_id="$(az identity show --name "${KEDA_PROMETHEUS_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --query principalId -o tsv --only-show-errors)"

if [[ -z "$(az role assignment list --assignee-object-id "${keda_prometheus_principal_id}" --scope "${MONITOR_WORKSPACE_ID}" --query "[?roleDefinitionName=='Monitoring Data Reader'].id | [0]" -o tsv --only-show-errors)" ]]; then
  log "Granting Monitoring Data Reader on ${MONITOR_WORKSPACE_ID} to ${KEDA_PROMETHEUS_IDENTITY_NAME}"
  az role assignment create \
    --assignee-object-id "${keda_prometheus_principal_id}" \
    --assignee-principal-type ServicePrincipal \
    --role "Monitoring Data Reader" \
    --scope "${MONITOR_WORKSPACE_ID}" \
    --only-show-errors \
    >/dev/null
fi

if az identity federated-credential show \
  --name "${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}" \
  --identity-name "${KEDA_PROMETHEUS_IDENTITY_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --only-show-errors >/dev/null 2>&1; then
  federated_issuer="$(az identity federated-credential show --name "${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}" --identity-name "${KEDA_PROMETHEUS_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --query issuer -o tsv --only-show-errors)"
  federated_subject="$(az identity federated-credential show --name "${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}" --identity-name "${KEDA_PROMETHEUS_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --query subject -o tsv --only-show-errors)"

  if [[ "${federated_issuer}" != "${AKS_OIDC_ISSUER}" || "${federated_subject}" != "system:serviceaccount:${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}:${KEDA_PROMETHEUS_OPERATOR_SERVICE_ACCOUNT_NAME}" ]]; then
    log "Refreshing federated credential ${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}"
    az identity federated-credential delete \
      --name "${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}" \
      --identity-name "${KEDA_PROMETHEUS_IDENTITY_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --only-show-errors \
      >/dev/null
  fi
fi

restart_required="false"
if ! az identity federated-credential show \
  --name "${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}" \
  --identity-name "${KEDA_PROMETHEUS_IDENTITY_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --only-show-errors >/dev/null 2>&1; then
  log "Creating federated credential ${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}"
  az identity federated-credential create \
    --name "${KEDA_PROMETHEUS_FEDERATED_CREDENTIAL_NAME}" \
    --identity-name "${KEDA_PROMETHEUS_IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --issuer "${AKS_OIDC_ISSUER}" \
    --subject "system:serviceaccount:${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}:${KEDA_PROMETHEUS_OPERATOR_SERVICE_ACCOUNT_NAME}" \
    --audiences api://AzureADTokenExchange \
    --only-show-errors \
    >/dev/null
  restart_required="true"
fi

current_annotation="$(keda_operator_client_id_annotation)"
if [[ "${current_annotation}" != "${keda_prometheus_client_id}" ]]; then
  log "Annotating KEDA operator service account with workload identity client id"
  kubectl annotate serviceaccount "${KEDA_PROMETHEUS_OPERATOR_SERVICE_ACCOUNT_NAME}" \
    -n "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}" \
    azure.workload.identity/client-id="${keda_prometheus_client_id}" \
    --overwrite >/dev/null
  restart_required="true"
fi

current_label="$(keda_operator_use_label)"
if [[ "${current_label}" != "true" ]]; then
  log "Patching KEDA operator deployment for Azure workload identity mutation"
  kubectl patch deployment "${KEDA_PROMETHEUS_OPERATOR_DEPLOYMENT_NAME}" \
    -n "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}" \
    --type merge \
    --patch '{"spec":{"template":{"metadata":{"labels":{"azure.workload.identity/use":"true"}}}}}' >/dev/null
  restart_required="true"
fi

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: keda.sh/v1alpha1
kind: ClusterTriggerAuthentication
metadata:
  name: ${KEDA_PROMETHEUS_AUTH_NAME}
spec:
  podIdentity:
    provider: azure-workload
    identityId: ${keda_prometheus_client_id}
EOF

if ! keda_operator_has_workload_identity_env; then
  restart_required="true"
fi

if [[ "${restart_required}" == "true" ]]; then
  log "Restarting KEDA operator to pick up shared Prometheus workload identity"
  kubectl rollout restart deployment/${KEDA_PROMETHEUS_OPERATOR_DEPLOYMENT_NAME} -n ${KEDA_PROMETHEUS_OPERATOR_NAMESPACE} >/dev/null
fi

wait_for_deployment_rollout "${KEDA_PROMETHEUS_OPERATOR_NAMESPACE}" "${KEDA_PROMETHEUS_OPERATOR_DEPLOYMENT_NAME}" 60 10

log "Shared KEDA Prometheus auth ready: ${KEDA_PROMETHEUS_AUTH_NAME}"