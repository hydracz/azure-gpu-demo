#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 30-deploy-test-app.sh  —  部署 GPU 探测应用 (Karpenter 管理 GPU 节点)
#
# 核心特点:
#   1. 请求 nvidia.com/gpu 资源
#   2. toleration 匹配 GPU workload taint
#   3. nodeAffinity 选择 GPU 节点 (workload=gpu-test)
#   4. 不使用 KEDA 自动伸缩 (GPU 场景手动控制副本数)
#   5. 不使用 podAntiAffinity (128 核 GPU VM, 一个节点足够)
#   6. 超长 rollout 超时 (GPU VM 启动较慢)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_env
ensure_tooling
require_env \
  AZ_SUBSCRIPTION_ID RESOURCE_GROUP CLUSTER_NAME APP_NAMESPACE APP_NAME TEST_IMAGE_URI \
  APP_MIN_REPLICAS APP_MAX_REPLICAS APP_REQUEST_CPU APP_LIMIT_CPU \
  APP_REQUEST_MEMORY APP_LIMIT_MEMORY APP_REQUEST_GPU GPU_TYPE

az account set --subscription "${AZ_SUBSCRIPTION_ID}" --only-show-errors
az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --overwrite-existing \
  --only-show-errors \
  >/dev/null

log "Deploying namespace ${APP_NAMESPACE} and GPU workload ${APP_NAME}"
log "⚠ GPU VM (128 vCPU) may take 5-15 min to provision. Pod may stay Pending if Spot quota < 128."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${APP_NAMESPACE}
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: ${APP_NAME}-priority
value: 1000
globalDefault: false
description: Priority for GPU probe workload.
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${APP_NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  replicas: ${APP_MIN_REPLICAS}
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      priorityClassName: ${APP_NAME}-priority
      terminationGracePeriodSeconds: 10
      tolerations:
        - key: workload
          operator: Equal
          value: gpu-test
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
                    values: ["gpu-test"]
                  - key: gputype
                    operator: In
                    values: ["${GPU_TYPE}"]
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: karpenter.sh/capacity-type
                    operator: In
                    values: ["spot"]
            - weight: 90
              preference:
                matchExpressions:
                  - key: spot_pool
                    operator: In
                    values: ["yes"]
      containers:
        - name: probe
          image: ${TEST_IMAGE_URI}
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
              name: http
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            requests:
              cpu: ${APP_REQUEST_CPU}
              memory: ${APP_REQUEST_MEMORY}
              nvidia.com/gpu: "${APP_REQUEST_GPU}"
            limits:
              cpu: ${APP_LIMIT_CPU}
              memory: ${APP_LIMIT_MEMORY}
              nvidia.com/gpu: "${APP_REQUEST_GPU}"
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${APP_NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: ${APP_NAME}
  ports:
    - port: 80
      targetPort: http
      protocol: TCP
      name: http
EOF

log "Waiting for rollout (timeout 30m for GPU VM provisioning)"
log "While waiting, check Karpenter status:"
log "  kubectl get nodeclaims"
log "  kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter -f"

if kubectl -n "${APP_NAMESPACE}" rollout status deploy/"${APP_NAME}" --timeout=30m; then
  log "Deployment rolled out successfully"
  kubectl -n "${APP_NAMESPACE}" get pod -o wide
else
  warn "Deployment rollout timed out or failed"
  log "Current pod status:"
  kubectl -n "${APP_NAMESPACE}" get pod -o wide
  log "Current nodeclaims:"
  kubectl get nodeclaims -o wide 2>/dev/null || true
  log "Recent Karpenter logs:"
  kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter --tail=30 2>/dev/null || true
  log ""
  log "Possible causes:"
  log "  1. Spot quota < 128 vCPU → check gpu-spot-pool status"
  log "  2. On-demand quota insufficient → check gpu-ondemand-pool status"
  log "  3. SKU not available in region → check az vm list-skus"
  log "  4. GPU driver plugin not ready → expected when installGPUDrivers=false"
  exit 1
fi
