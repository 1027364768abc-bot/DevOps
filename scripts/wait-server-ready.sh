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
READY_CMD='for i in $(seq 1 180); do [ -f /opt/cloud-init-done ] && docker version >/dev/null 2>&1 && { echo READY; exit 0; }; sleep 5; done; echo NOT_READY; exit 1'
ENCODED="$(printf '%s' "$READY_CMD" | base64 -w 0)"

INVOKE_ID="$(
  aliyun ecs RunCommand \
    --RegionId "$REGION" \
    --InstanceId.1 "$INSTANCE_ID" \
    --Type RunShellScript \
    --CommandContent "$ENCODED" \
    --ContentEncoding Base64 \
    --Timeout 1000 \
    --Name wait-docker-ready |
    jq -r '.InvokeId // empty'
)"
[ -n "$INVOKE_ID" ] || { echo "ERROR: failed to invoke readiness command" >&2; exit 1; }

# 就绪失败时收集 ECS 上的诊断信息（cloud-init 状态、Docker、初始化日志）
dump_diagnostics() {
  echo "==> collecting diagnostics from instance ${INSTANCE_ID}"
  DUMP_CMD='echo "--- cloud-init status ---"; cloud-init status --long 2>&1; echo; echo "--- marker ---"; ls -l /opt/cloud-init-done 2>&1; echo; echo "--- docker ---"; docker --version 2>&1; systemctl is-active docker 2>&1; echo; echo "--- devops-init.log ---"; tail -n 120 /var/log/devops-init.log 2>&1; echo; echo "--- cloud-init-output.log ---"; tail -n 120 /var/log/cloud-init-output.log 2>&1'
  ENCODED_DUMP="$(printf '%s' "$DUMP_CMD" | base64 -w 0)"
  DUMP_INVOKE_ID="$(
    aliyun ecs RunCommand \
      --RegionId "$REGION" \
      --InstanceId.1 "$INSTANCE_ID" \
      --Type RunShellScript \
      --CommandContent "$ENCODED_DUMP" \
      --ContentEncoding Base64 \
      --Timeout 60 2>/dev/null |
      jq -r '.InvokeId // empty'
  )"
  [ -n "$DUMP_INVOKE_ID" ] || { echo "WARN: failed to invoke diagnostics" >&2; return; }
  for _ in $(seq 1 20); do
    DUMP_STATUS="$(
      aliyun ecs DescribeInvocations \
        --RegionId "$REGION" \
        --InvokeId "$DUMP_INVOKE_ID" 2>/dev/null |
        jq -r '.Invocations.Invocation[0].InvocationStatus // empty'
    )"
    case "$DUMP_STATUS" in
      Success | Failed | PartialFailed) break ;;
    esac
    sleep 3
  done
  OUT="$(
    aliyun ecs DescribeInvocationResults \
      --RegionId "$REGION" \
      --InvokeId "$DUMP_INVOKE_ID" 2>/dev/null |
      jq -r '.Invocation.InvocationResults.InvocationResult[0].Output // empty'
  )"
  if [ -n "$OUT" ]; then
    printf '%s' "$OUT" | base64 -d 2>/dev/null || echo "WARN: cannot decode diagnostics output" >&2
    echo
  else
    echo "WARN: no diagnostics output returned" >&2
  fi
}

INVOKE_STATUS=""
START_TS="$(date +%s)"
for _ in $(seq 1 200); do
  INVOKE_STATUS="$(
    aliyun ecs DescribeInvocations \
      --RegionId "$REGION" \
      --InvokeId "$INVOKE_ID" |
      jq -r '.Invocations.Invocation[0].InvocationStatus // empty'
  )"
  ELAPSED_MIN="$(( ($(date +%s) - START_TS) / 60 ))"
  echo "    invoke status: ${INVOKE_STATUS:-unknown} (已等待 ${ELAPSED_MIN} 分钟)"
  case "$INVOKE_STATUS" in
    Success) break ;;
    Failed | PartialFailed) echo "ERROR: readiness command failed" >&2; dump_diagnostics; exit 1 ;;
  esac
  sleep 5
done
[ "$INVOKE_STATUS" = "Success" ] || { echo "ERROR: timeout waiting for Docker" >&2; dump_diagnostics; exit 1; }

EXIT_CODE="$(
  aliyun ecs DescribeInvocationResults \
    --RegionId "$REGION" \
    --InvokeId "$INVOKE_ID" |
    jq -r '.Invocation.InvocationResults.InvocationResult[0].ExitCode // empty'
)"
[ "$EXIT_CODE" = "0" ] || { echo "ERROR: Docker readiness exit code ${EXIT_CODE:-unknown}" >&2; dump_diagnostics; exit 1; }

echo "==> server ${INSTANCE_ID} is ready"
