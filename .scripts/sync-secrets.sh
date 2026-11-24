#!/usr/bin/env bash
#
# 同步 .scripts/gh-secrets.json 到 GitHub Repository Secrets，
# 可选触发并等待 GitHub Actions 部署。
#
# 所有交互（是否部署）都在任务开始前一次性完成，执行期间不会再询问。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_FILE="$SCRIPT_DIR/gh-secrets.json"
WORKFLOW_FILE="deploy-cloudflare.yml"

ACTION_MODE=""          # sync | deploy | deploy_nowait（空 = 开跑前询问）
DRY_RUN=0
PRUNE=0
FORCE=0
WATCH_TIMEOUT="${WATCH_TIMEOUT:-900}"

TMP_FILES=""
cleanup() {
  if [ -n "$TMP_FILES" ]; then
    # shellcheck disable=SC2086
    rm -f $TMP_FILES 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() {
  echo "❌ $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法: ./.scripts/sync-secrets.sh [选项]

不带选项时，脚本会先展示配置摘要，再让你选择本次操作（选完后全程无交互）。

选项:
  --no-deploy        只同步 Secrets，不触发部署
  --deploy           同步 → 触发部署 → 等待完成并校验
  --deploy-nowait    同步 → 触发部署 → 不等待，只输出链接
  --dry-run          只显示将要同步的内容，不做任何修改
  --prune            删除 GitHub 上存在、但本地 JSON 已删除的 Secret
  --force            已有部署在运行时仍然触发
  -h, --help         显示本帮助

环境变量:
  WATCH_TIMEOUT      等待部署完成的上限秒数，默认 900

示例:
  ./.scripts/sync-secrets.sh
  ./.scripts/sync-secrets.sh --deploy
  ./.scripts/sync-secrets.sh --no-deploy
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-deploy)      ACTION_MODE="sync"; shift ;;
    --deploy)         ACTION_MODE="deploy"; shift ;;
    --deploy-nowait)  ACTION_MODE="deploy_nowait"; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --prune)          PRUNE=1; shift ;;
    --force)          FORCE=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------- 预检
command -v gh   >/dev/null 2>&1 || fail "未找到 gh CLI，请先安装并登录"
command -v jq   >/dev/null 2>&1 || fail "未找到 jq，请先安装"
command -v curl >/dev/null 2>&1 || fail "未找到 curl"

[ -f "$SECRETS_FILE" ] || fail "找不到 $SECRETS_FILE"

if ! gh auth status >/dev/null 2>&1; then
  fail "gh 未登录，请先执行: gh auth login"
fi

REPO="$(cd "$ROOT_DIR" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
  || fail "无法识别 GitHub 仓库（请在仓库目录内运行）"

PERM="$(gh repo view "$REPO" --json viewerPermission -q .viewerPermission 2>/dev/null || echo '')"
[ "$PERM" = "ADMIN" ] || fail "需要仓库 ADMIN 权限才能写入 Secrets，当前: ${PERM:-未知}"

jq empty "$SECRETS_FILE" >/dev/null 2>&1 || fail "$SECRETS_FILE 不是合法 JSON"

echo "📄 读取并校验 $SECRETS_FILE"

# ---------------------------------------------------------------- 校验
for k in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID CUSTOM_DOMAIN DOMAIN ADMIN JWT_SECRET NAME; do
  [ "$(jq --arg k "$k" 'has($k)' "$SECRETS_FILE")" = "true" ] || fail "缺少字段: $k"
done

jq -e '.DOMAIN | type == "array" and length > 0' "$SECRETS_FILE" >/dev/null \
  || fail "DOMAIN 必须是非空数组，例如 [\"example.com\"]"

jq -e '.DOMAIN | all(.[]; type == "string" and test("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$"))' "$SECRETS_FILE" >/dev/null \
  || fail "DOMAIN 中存在非法域名（必须小写，不带 @、协议、路径）"

NAME="$(jq -r '.NAME' "$SECRETS_FILE")"
printf '%s' "$NAME" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' \
  || fail "NAME 非法：只允许小写字母、数字和连字符，且不能以连字符开头/结尾（当前: $NAME）"

JWT_SECRET="$(jq -r '.JWT_SECRET' "$SECRETS_FILE")"
[ -n "$JWT_SECRET" ] || fail "JWT_SECRET 不能为空"
if printf '%s' "$JWT_SECRET" | grep -q '[?%#/\\]'; then
  fail "JWT_SECRET 不能包含 ? % # / \\"
fi

ADMIN="$(jq -r '.ADMIN' "$SECRETS_FILE")"
printf '%s' "$ADMIN" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' \
  || fail "ADMIN 不是合法邮箱地址（当前: $ADMIN）"

CUSTOM_DOMAIN="$(jq -r '.CUSTOM_DOMAIN // ""' "$SECRETS_FILE")"
if [ -n "$CUSTOM_DOMAIN" ]; then
  printf '%s' "$CUSTOM_DOMAIN" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' \
    || fail "CUSTOM_DOMAIN 必须是纯主机名（不带 https://、不带路径）"
fi

[ -n "$(jq -r '.CLOUDFLARE_ACCOUNT_ID' "$SECRETS_FILE")" ] || fail "CLOUDFLARE_ACCOUNT_ID 不能为空"
[ -n "$(jq -r '.CLOUDFLARE_API_TOKEN'  "$SECRETS_FILE")" ] || fail "CLOUDFLARE_API_TOKEN 不能为空"

echo "✅ 校验通过"
echo

# ---------------------------------------------------------------- 摘要
KEYS="$(jq -r 'keys_unsorted[]' "$SECRETS_FILE")"

for k in $KEYS; do
  case "$k" in
    DOMAIN|NAME|CUSTOM_DOMAIN|ADMIN|AI_MODEL|ANALYSIS_CACHE|EMAIL|R2_BUCKET_NAME|PROJECT_LINK)
      v="$(jq -c --arg k "$k" '.[$k]' "$SECRETS_FILE")"
      printf '   %-24s %s\n' "$k" "$v"
      ;;
    *)
      v="$(jq -r --arg k "$k" '.[$k] | tostring' "$SECRETS_FILE")"
      if [ -n "$v" ]; then
        printf '   %-24s ******** (%s 字符)\n' "$k" "${#v}"
      else
        printf '   %-24s (空)\n' "$k"
      fi
      ;;
  esac
done

# ---------------------------------------------------------------- 选择
if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "🧪 dry-run：以下内容不会真正执行"
  echo "   仓库: $REPO"
  echo "   将同步: $(echo "$KEYS" | tr '\n' ' ')"
  if [ "$PRUNE" -eq 1 ]; then
    echo "   将清理: 远端存在但本地 JSON 没有的 Secret"
  fi
  case "$ACTION_MODE" in
    deploy)        echo "   部署动作: 触发并等待完成 + 校验" ;;
    deploy_nowait) echo "   部署动作: 触发但不等待" ;;
    sync|"")       echo "   部署动作: 未选择（只同步）" ;;
  esac
  exit 0
fi

if [ -z "$ACTION_MODE" ]; then
  if [ ! -t 0 ]; then
    fail "非交互环境，请显式指定 --no-deploy / --deploy / --deploy-nowait"
  fi
  echo
  echo "请选择本次操作（选完后不再询问）："
  echo "  1) 只同步 Secrets（默认）"
  echo "  2) 同步 → 触发部署 → 等待完成并校验"
  echo "  3) 同步 → 触发部署 → 不等待，只输出链接"
  while true; do
    printf '输入 1/2/3 [1]: '
    read -r choice || choice=""
    case "${choice:-1}" in
      1) ACTION_MODE="sync"; break ;;
      2) ACTION_MODE="deploy"; break ;;
      3) ACTION_MODE="deploy_nowait"; break ;;
      *) echo "请输入 1、2 或 3" ;;
    esac
  done
fi

case "$ACTION_MODE" in
  sync)          echo; echo "▶ 开始执行：只同步 Secrets" ;;
  deploy)        echo; echo "▶ 开始执行：同步 → 部署 → 等待 → 校验" ;;
  deploy_nowait) echo; echo "▶ 开始执行：同步 → 部署（不等待）" ;;
esac

# ---------------------------------------------------------------- 检查进行中的部署
if [ "$ACTION_MODE" != "sync" ]; then
  ACTIVE_ID="$(gh run list -R "$REPO" -w "$WORKFLOW_FILE" -L 10 \
    --json databaseId,status \
    --jq '[.[] | select(.status == "in_progress" or .status == "queued") | .databaseId][0] // empty')"
  if [ -n "$ACTIVE_ID" ] && [ "$FORCE" -ne 1 ]; then
    fail "当前有部署正在运行（run #$ACTIVE_ID，https://github.com/$REPO/actions/runs/$ACTIVE_ID）。
   为避免并发修改 Worker 已中止。等待完成后重试，或加 --force。"
  fi
fi

# ---------------------------------------------------------------- 同步
SECRET_COUNT="$(echo "$KEYS" | wc -l | tr -d ' ')"
echo
echo "🔐 正在同步 $SECRET_COUNT 个 Secret 到 $REPO ..."

for k in $KEYS; do
  if [ "$k" = "DOMAIN" ]; then
    value="$(jq -c '.DOMAIN' "$SECRETS_FILE")"
  else
    value="$(jq -r --arg k "$k" '.[$k] | tostring' "$SECRETS_FILE")"
  fi
  gh secret set "$k" -R "$REPO" --body "$value" >/dev/null
  printf '   ✓ %s\n' "$k"
done

if [ "$PRUNE" -eq 1 ]; then
  REMOTE_KEYS="$(gh secret list -R "$REPO" --json name --jq '.[].name')"
  for name in $REMOTE_KEYS; do
    if ! printf '%s\n' "$KEYS" | grep -qxF "$name"; then
      gh secret delete "$name" -R "$REPO" >/dev/null
      printf '   🗑  已删除远端多余 Secret: %s\n' "$name"
    fi
  done
fi

echo "✅ Secret 同步完成"

if [ "$ACTION_MODE" = "sync" ]; then
  echo
  echo "稍后触发部署："
  echo "  gh workflow run $WORKFLOW_FILE -R $REPO"
  exit 0
fi

# ---------------------------------------------------------------- 触发部署
PREV_ID="$(gh run list -R "$REPO" -w "$WORKFLOW_FILE" -e workflow_dispatch -L 1 \
  --json databaseId --jq '.[0].databaseId // empty')"

echo
echo "🚀 触发 GitHub Actions 部署 ..."
gh workflow run "$WORKFLOW_FILE" -R "$REPO" >/dev/null

NEW_ID=""
i=0
while [ "$i" -lt 20 ]; do
  sleep 3
  CANDIDATE="$(gh run list -R "$REPO" -w "$WORKFLOW_FILE" -e workflow_dispatch -L 1 \
    --json databaseId --jq '.[0].databaseId // empty')"
  if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "$PREV_ID" ]; then
    NEW_ID="$CANDIDATE"
    break
  fi
  i=$((i + 1))
done

[ -n "$NEW_ID" ] || fail "60 秒内未找到新触发的 run，请到 https://github.com/$REPO/actions 查看"

RUN_URL="https://github.com/$REPO/actions/runs/$NEW_ID"
echo "   $RUN_URL"

if [ "$ACTION_MODE" = "deploy_nowait" ]; then
  echo "✅ 已触发（未等待结果）"
  exit 0
fi

# ---------------------------------------------------------------- 等待完成
run_with_timeout() {
  local seconds="$1"
  shift
  "$@" &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$seconds" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 5
    waited=$((waited + 5))
  done
  local status=0
  wait "$pid" || status=$?
  return "$status"
}

echo
echo "⏳ 等待部署完成（上限 ${WATCH_TIMEOUT}s）..."
WATCH_STATUS=0
run_with_timeout "$WATCH_TIMEOUT" gh run watch "$NEW_ID" -R "$REPO" --exit-status --compact --interval 10 \
  || WATCH_STATUS=$?

if [ "$WATCH_STATUS" -eq 124 ]; then
  echo "⚠️  等待超时，任务可能仍在运行：$RUN_URL"
  exit 1
fi

if [ "$WATCH_STATUS" -ne 0 ]; then
  echo
  echo "❌ 部署失败，以下是失败步骤日志："
  gh run view "$NEW_ID" -R "$REPO" --log-failed || true
  echo "   详情: $RUN_URL"
  exit 1
fi

echo "✅ 部署成功"

# ---------------------------------------------------------------- 部署后校验
echo
echo "🔍 校验部署结果 ..."
FAILED=0

if [ -n "$CUSTOM_DOMAIN" ]; then
  CODE=""
  for _ in 1 2 3; do
    CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$CUSTOM_DOMAIN/" || true)"
    [ "$CODE" = "200" ] && break
    sleep 5
  done
  if [ "$CODE" = "200" ]; then
    echo "   ✓ https://$CUSTOM_DOMAIN 返回 200"
  else
    echo "   ✗ https://$CUSTOM_DOMAIN 返回 ${CODE:-无响应}"
    FAILED=1
  fi
fi

TOKEN="$(jq -r '.CLOUDFLARE_API_TOKEN' "$SECRETS_FILE")"
ACCOUNT="$(jq -r '.CLOUDFLARE_ACCOUNT_ID' "$SECRETS_FILE")"
SETTINGS_TMP="$(mktemp "${TMPDIR:-/tmp}/sync-secrets.XXXXXX")"
TMP_FILES="$TMP_FILES $SETTINGS_TMP"

if curl -s --max-time 20 \
  -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/scripts/$NAME/settings" \
  -o "$SETTINGS_TMP" && jq -e '.success == true' "$SETTINGS_TMP" >/dev/null 2>&1; then

  DEPLOYED_DOMAINS="$(jq -c '[.result.bindings[] | select(.name == "domain") | .json][0] // empty' "$SETTINGS_TMP")"
  EXPECTED_DOMAINS="$(jq -c '.DOMAIN' "$SECRETS_FILE")"

  if [ -n "$DEPLOYED_DOMAINS" ] && \
     [ "$(jq -n --argjson a "$DEPLOYED_DOMAINS" --argjson b "$EXPECTED_DOMAINS" '($a | sort) == ($b | sort)')" = "true" ]; then
    echo "   ✓ Worker domain 绑定 = $DEPLOYED_DOMAINS"
  else
    echo "   ✗ Worker domain 绑定不匹配（线上: ${DEPLOYED_DOMAINS:-空}）"
    FAILED=1
  fi

  DEPLOYED_ADMIN="$(jq -r '[.result.bindings[] | select(.name == "admin") | .text][0] // empty' "$SETTINGS_TMP")"
  if [ "$DEPLOYED_ADMIN" = "$ADMIN" ]; then
    echo "   ✓ admin = $ADMIN"
  else
    echo "   ✗ admin 不匹配（线上: ${DEPLOYED_ADMIN:-空}，本地: $ADMIN）"
    FAILED=1
  fi
else
  echo "   ⚠️  无法读取 Worker settings（token 权限或网络问题），跳过绑定校验"
fi

if [ -n "$CUSTOM_DOMAIN" ]; then
  DOMAINS_TMP="$(mktemp "${TMPDIR:-/tmp}/sync-secrets.XXXXXX")"
  TMP_FILES="$TMP_FILES $DOMAINS_TMP"
  if curl -s --max-time 20 \
    -H "Authorization: Bearer $TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/domains" \
    -o "$DOMAINS_TMP" && jq -e '.success == true' "$DOMAINS_TMP" >/dev/null 2>&1; then
    if [ "$(jq -r --arg h "$CUSTOM_DOMAIN" --arg s "$NAME" \
      '[.result[] | select(.hostname == $h and .service == $s and .enabled == true)] | length' "$DOMAINS_TMP")" -gt 0 ]; then
      echo "   ✓ 自定义域 $CUSTOM_DOMAIN → $NAME 已启用"
    else
      echo "   ✗ 自定义域 $CUSTOM_DOMAIN 未绑定到 $NAME"
      FAILED=1
    fi
  fi
fi

echo
if [ "$FAILED" -ne 0 ]; then
  echo "⚠️  部署成功，但校验发现问题"
  echo "   $RUN_URL"
  exit 1
fi

echo "✅ 全部完成"
echo "   $RUN_URL"
