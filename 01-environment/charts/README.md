# Charts

This directory contains the Helm charts required by the deployment scripts.

You need to place the following charts here before running the scripts:

## Required Charts

### 1. Karpenter CRD

```bash
# Copy from your karpenter-provider-azure build output, or:
cp -r /path/to/karpenter-provider-azure/charts/karpenter-crd charts/
```

### 2. Karpenter

```bash
cp -r /path/to/karpenter-provider-azure/charts/karpenter charts/
```

### 3. GPU Operator

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm pull nvidia/gpu-operator --version v25.3.4 --untar -d charts/
```

### 4. ServiceMonitor / PodMonitor CRDs (optional)

Place `crd-servicemonitors.yaml` and `crd-podmonitors.yaml` in this directory for Prometheus Operator `ServiceMonitor` / `PodMonitor` compatibility.

```bash
kubectl get crd servicemonitors.monitoring.coreos.com -o yaml > charts/crd-servicemonitors.yaml
kubectl get crd podmonitors.monitoring.coreos.com -o yaml > charts/crd-podmonitors.yaml
```

### 5. cert-manager manifests

This repo vendors the cert-manager installation manifest and the small platform templates needed by the shell and Terraform flows:

- `cert-manager.yaml`
- `letencrypt-signer.yaml`

## Expected Structure

```text
charts/
├── cert-manager.yaml
├── crd-podmonitors.yaml
├── crd-servicemonitors.yaml
├── gpu-operator/
├── karpenter/
├── karpenter-crd/
└── letencrypt-signer.yaml
```
