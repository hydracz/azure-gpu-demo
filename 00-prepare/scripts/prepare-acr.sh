#!/usr/bin/env bash

set -euo pipefail

PREPARE_ACR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${PREPARE_ACR_SCRIPT_DIR}/../../common.sh"

ensure_acr_ready() {
	local configured_acr_id="${EXISTING_ACR_ID:-${ACR_ID:-}}"
	local effective_acr_rg="${ACR_RESOURCE_GROUP:-${RESOURCE_GROUP}}"
	local acr_id=""
	local acr_name="${ACR_NAME:-}"
	local acr_login_server=""

	if [[ -n "${configured_acr_id}" ]] && az resource show --ids "${configured_acr_id}" --only-show-errors >/dev/null 2>&1; then
		log "Using existing ACR from ID ${configured_acr_id}"
		acr_id="${configured_acr_id}"
		acr_name="$(az resource show --ids "${acr_id}" --query name -o tsv --only-show-errors)"
		effective_acr_rg="$(az resource show --ids "${acr_id}" --query resourceGroup -o tsv --only-show-errors)"
	elif [[ -n "${configured_acr_id}" ]]; then
		warn "Configured EXISTING_ACR_ID/ACR_ID ${configured_acr_id} was not found; falling back to ACR name settings"
	fi

	if [[ -z "${acr_id}" ]]; then
		require_env LOCATION RESOURCE_GROUP ACR_NAME

		if [[ "$(az group exists --name "${effective_acr_rg}" --only-show-errors)" != "true" ]]; then
			log "Creating resource group ${effective_acr_rg} for ACR"
			az group create \
				--name "${effective_acr_rg}" \
				--location "${LOCATION}" \
				--only-show-errors \
				>/dev/null
		fi

		if az acr show --name "${acr_name}" --resource-group "${effective_acr_rg}" --only-show-errors >/dev/null 2>&1; then
			log "Using existing ACR ${acr_name} in ${effective_acr_rg}"
		else
			log "Creating ACR ${acr_name} in ${effective_acr_rg}"
			az acr create \
				--name "${acr_name}" \
				--resource-group "${effective_acr_rg}" \
				--location "${LOCATION}" \
				--sku Standard \
				--admin-enabled false \
				--only-show-errors \
				>/dev/null
		fi

		acr_id="$(az acr show --name "${acr_name}" --resource-group "${effective_acr_rg}" --query id -o tsv --only-show-errors)"
	fi

	acr_login_server="$(az acr show --name "${acr_name}" --resource-group "${effective_acr_rg}" --query loginServer -o tsv --only-show-errors)"

	export ACR_ID="${acr_id}"
	export EXISTING_ACR_ID="${acr_id}"
	export ACR_NAME="${acr_name}"
	export ACR_RESOURCE_GROUP="${effective_acr_rg}"
	export ACR_LOGIN_SERVER="${acr_login_server}"

	write_generated_env ACR_ID "${acr_id}"
	write_generated_env EXISTING_ACR_ID "${acr_id}"
	write_generated_env ACR_NAME "${acr_name}"
	write_generated_env ACR_RESOURCE_GROUP "${effective_acr_rg}"
	write_generated_env ACR_LOGIN_SERVER "${acr_login_server}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	load_env
	need_cmd az
	require_env AZ_SUBSCRIPTION_ID LOCATION RESOURCE_GROUP
	az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors >/dev/null
	ensure_acr_ready
fi