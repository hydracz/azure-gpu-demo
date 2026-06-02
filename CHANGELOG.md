# Changelog

## 2026-06-02 - AKS GPU/Karpenter redeploy and scale-out validation

### Code changes

- Hardened Karpenter bootstrap token handling in both Terraform and shell install paths.
  - Replaced the previous behavior of selecting the first `kube-system` bootstrap token with a dedicated `bootstrap-token-karp00` token.
  - Added token validation, optional TTL support via `KARPENTER_BOOTSTRAP_TOKEN_TTL_HOURS`, and a minimum remaining lifetime check via `KARPENTER_BOOTSTRAP_TOKEN_MIN_VALID_SECONDS`.
  - Preserved existing bootstrap groups when possible and labeled the managed token with `azure-gpu-demo/karpenter-bootstrap-token=true` for easier auditing.
- Updated AKS managed Istio defaults from `asm-1-27` to `asm-1-29` across Terraform, shell, samples, documentation, and production manifests.
  - `asm-1-27` was no longer accepted in the `southeastasia` redeploy test.
  - The Terraform default can still be set to an empty list if AKS should choose the supported revision automatically.
- Improved Qwen workload deployment resilience.
  - `41-deploy.sh` now verifies that the configured managed Istio revision exists in the cluster before labeling the namespace.
  - If `.generated.env` or inherited environment variables contain a stale revision, the script warns and falls back to the current cluster revision discovered from Istio webhook/deployment resources.
  - The resolved revision is persisted back to `.generated.env` as `QWEN_LOADTEST_ISTIO_REVISION`.

### Test results

- Re-deployed the full environment for `STACK_ID=karpgpu-004498` in subscription `d48da42e-7f16-44c8-89f7-4a7b478bd50a`.
  - AKS cluster: `aks-karpgpu-004498`
  - Resource group: `rg-aks-karpgpu-004498`
  - Node resource group: `MC_rg-aks-karpgpu-004498_aks-karpgpu-004498_southeastasia`
- Terraform deployment completed successfully after switching the managed Istio revision to `asm-1-29`.
- Karpenter, GPU Operator, Dragonfly, Gateway/KEDA, and the Qwen workload were deployed successfully.
- `04-workloads/qwen-loadtest-target/41-deploy.sh` was rerun idempotently and completed successfully.
  - Resolved Istio revision: `asm-1-29`
  - Internal Gateway IP: `10.240.0.9`
  - Qwen elastic deployment: min/max restored to `0/4` after validation
- Qwen smoke test succeeded through the internal Gateway.
  - HTTP status: `200`
  - Response status: `success`
  - GPU execution time: about `10.05s`
- Elastic scale-out was validated by temporarily setting the elastic `ScaledObject` minimum replica count to `2`.
  - Karpenter created spot GPU `NodeClaim` resources.
  - The corresponding Azure VMs moved to running state.
  - Nodes registered with AKS and reached `Ready=True`.
  - GPU Operator then registered `nvidia.com/gpu=1` on the GPU nodes.
  - The scale-out test did not reproduce the customer-reported failure where the VM was running but no node joined the AKS cluster.
- After the test, the elastic `ScaledObject` was restored to `minReplicaCount=0` and the temporary elastic pods were deleted.
- Shell syntax validation passed for the changed deployment scripts:
  - `01-environment/terraform/scripts/install-karpenter.sh`
  - `01-environment/shell/15-deploy-karpenter.sh`
  - `01-environment/terraform/scripts/render-tfvars-from-env.sh`
  - `01-environment/shell/10-create-aks.sh`
  - `04-workloads/qwen-loadtest-target/41-deploy.sh`

### Customer failure analysis

- The most likely root cause of the previous customer-environment failure was unsafe Karpenter bootstrap token selection.
  - The old scripts reused the first bootstrap token found in `kube-system`.
  - In a long-lived or previously modified customer cluster, that token could be expired, close to expiry, or otherwise unsuitable for Karpenter-managed kubelet bootstrap.
  - In that failure mode, Karpenter can still create the Azure VM, so the VM appears as `Running`, but the kubelet cannot complete bootstrap authentication and does not register a Kubernetes node in AKS. The `NodeClaim` therefore never reaches the fully ready state.
- A separate transient state was observed during this validation and should not be confused with the customer failure.
  - Some `NodeClaim` resources temporarily showed `Ready=Unknown` after the VM had already registered as an AKS node.
  - The message was `Resource "nvidia.com/gpu" was requested but not registered`.
  - This was caused by GPU Operator/device-plugin startup latency. Once the toolkit and device plugin daemonsets rolled out, `nvidia.com/gpu` appeared and the `NodeClaim` became `Ready=True`.
- Large image pull time is also expected for this workload.
  - The Qwen image is about `53.5GB`.
  - The first pull took about `7m37s`, during which the workload stayed in `Pulling` or `PodInitializing`.
  - This delay is a workload warm-up behavior and is different from a Karpenter node registration failure.

### Operational notes

- During elastic scale-out, Karpenter temporarily over-provisioned additional spot GPU nodes while GPU resources were not yet registered by the device plugin.
- The GPU NodePools are configured with `consolidationPolicy: WhenEmpty` and `consolidateAfter: 10m`, so empty spot nodes are expected to be reclaimed by Karpenter after the idle window.
- Keep `asm-1-29` as the default managed Istio revision for the current `southeastasia` deployment path unless Azure publishes a newer required revision or the environment is configured to let AKS select the revision automatically.