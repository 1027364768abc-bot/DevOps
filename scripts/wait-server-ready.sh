#!/usr/bin/env bash
# 等待 Terraform 新创建的 ECS 完全就绪：
#   1. 实例状态变为 Running
#   2. cloud-init 完成，Docker 可正常使用（通过云助手 RunCommand 探测）
# 依赖：aliyun CLI 已配置、jq、环境变量 REGION 与 ECS_INSTANCE_ID。
set -euo pipefail

REGION="${REGION:-cn-hangzhou}"
INSTANCE_ID="${ECS_INSTANCE_ID:-}"

if [ -z "$INSTANCE_ID" ]; then
  echo "ERROR: ECS_INSTANCE_ID is empty" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo apt-get install -y -qq jq
fi

echo "==> waiting for instance ${INSTANCE_ID} to be Running"
STATUS=""
for _ in $(seq 1 60); do
  STATUS="$(
    aliyun ecs DescribeInstances \
      --RegionId "$REGION" \
      --InstanceIds "[\"$INSTANCE_ID\"]" |
      jq -r '.Instances.Instance[0].Status // empty'
  )"
  echo "    instance status: ${STATUS:-unknown}"
  [ "$STATUS" = "Running" ] && break
  sleep 5
done
[ "$STATUS" = "Running" ] || { echo "ERROR: instance did not reach Running in time" >&2; exit 1; }

echo "==> waiting for cloud-init / Docker readiness"
READY_CMD='for i in $(seq 1 120); do docker version >/dev/null 2>&1 && { echo READY; exit 0; }; sleep 5; done; echo NOT_READY; exit 1'
ENCODED="$(printf '%s' "$READY_CMD" | base64 -w 0)"

INVOKE_ID="$(
  aliyun ecs RunCommand \
    --RegionId "$REGION" \
    --InstanceId.1 "$INSTANCE_ID" \
    --Type RunShellScript \
    --CommandContent "$ENCODED" \
    --Timeout 700 \
    --Name wait-docker-ready |
    jq -r '.InvokeId // empty'
)"
[ -n "$INVOKE_ID" ] || { echo "ERROR: failed to invoke readiness command" >&2; exit 1; }

INVOKE_STATUS=""
for _ in $(seq 1 150); do
  INVOKE_STATUS="$(
    aliyun ecs DescribeInvocations \
      --RegionId "$REGION" \
      --InvokeId "$INVOKE_ID" |
      jq -r '.Invocations.Invocation[0].InvocationStatus // empty'
  )"
  echo "    invoke status: ${INVOKE_STATUS:-unknown}"
  case "$INVOKE_STATUS" in
    Success) break ;;
    Failed | PartialFailed) echo "ERROR: readiness command failed" >&2; exit 1 ;;
  esac
  sleep 5
done
[ "$INVOKE_STATUS" = "Success" ] || { echo "ERROR: timeout waiting for Docker" >&2; exit 1; }

EXIT_CODE="$(
  aliyun ecs DescribeInvocationResults \
    --RegionId "$REGION" \
    --InvokeId "$INVOKE_ID" |
    jq -r '.Invocation.InvocationResults.InvocationResult[0].ExitCode // empty'
)"
[ "$EXIT_CODE" = "0" ] || { echo "ERROR: Docker readiness exit code ${EXIT_CODE:-unknown}" >&2; exit 1; }

echo "==> server ${INSTANCE_ID} is ready"
