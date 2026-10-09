#!/bin/sh
set -u

VERSION=0.3.0
RETRY=${PO0DW_RETRY:-3}
TIMEOUT=${PO0DW_TIMEOUT:-15}
PLACEHOLDER_HOST=fw.example.com

log() { printf '[po0dw] %s\n' "$*"; }
die() { printf '[po0dw] %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<EOF
po0dw $VERSION - PO0 Dynamic Whitelist 客户端

用法:
  po0dw            把当前公网 IPv4 加入白名单（默认）
  po0dw status     只查询白名单，不加白
  po0dw version    显示版本

配置（优先级从高到低）:
  环境变量 PO0DW_URL / PO0DW_TOKEN
  配置文件 \$PO0DW_CONF，默认依次查找 /etc/po0dw.conf、\$PREFIX/etc/po0dw.conf、~/.config/po0dw.conf
    PO0DW_URL="fw.example.com"
    PO0DW_TOKEN="你的 api_token"
EOF
}

find_conf() {
  if [ -n "${PO0DW_CONF:-}" ]; then
    printf '%s\n' "$PO0DW_CONF"
    return
  fi
  for f in /etc/po0dw.conf "${PREFIX:-/nonexistent}/etc/po0dw.conf" "${HOME:-/nonexistent}/.config/po0dw.conf"; do
    if [ -f "$f" ]; then
      printf '%s\n' "$f"
      return
    fi
  done
}

conf_get() {
  [ -n "$2" ] && [ -r "$2" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$2" | tail -n 1 | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

normalize_base() {
  v=$(printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$v" ] || return 1
  case "$v" in
    https://*) ;;
    *://*) return 1 ;;
    *) v="https://$v" ;;
  esac
  v=$(printf '%s' "$v" | sed 's#/*$##')
  host=$(printf '%s' "$v" | sed -n 's|^https://\([A-Za-z0-9.-][A-Za-z0-9.-]*\)\(:[0-9][0-9]*\)\{0,1\}\(/[^?# ]*\)\{0,1\}$|\1|p')
  [ -n "$host" ] || return 1
  [ "$(printf '%s' "$host" | tr ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz)" != "$PLACEHOLDER_HOST" ] || return 1
  printf '%s\n' "$v"
}

valid_token() {
  [ "${#1}" -ge 24 ] || return 1
  case "$1" in
    *[!!-~]*) return 1 ;;
  esac
  return 0
}

json_str() {
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

json_raw() {
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}[:space:]]*\).*/\1/p" | head -n 1
}

json_ips() {
  printf '%s' "$1" | grep -o '"ip"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/'
}

mark() {
  if [ "$1" = true ]; then printf '✓'; else printf '✗'; fi
}

server_hint() {
  case "$1" in
    unauthorized) printf 'Token 错误' ;;
    'untrusted peer') printf 'API 只接受可信反代，检查 trusted_proxy_ip' ;;
    'invalid public IPv4') printf '服务端没拿到公网 IPv4，请求可能走了代理 / IPv6' ;;
    'INPUT/FORWARD guard not verified') printf '服务端防火墙规则校验失败' ;;
    'queue / ipset mismatch; manual repair required') printf '队列与 ipset 不一致，需在服务端 repair' ;;
    'failed to apply whitelist') printf '服务端写入 ipset 失败' ;;
    'firewall unavailable') printf '服务端防火墙不可用' ;;
    'not found') printf '路径不存在，检查 PO0DW_URL' ;;
    *) printf '%s' "$1" ;;
  esac
}

status_hint() {
  case "$1" in
    502|504) printf 'Nginx 连不上内网 API' ;;
    404) printf '路径不存在，检查 PO0DW_URL 与 Nginx location' ;;
    403) printf '被 Nginx 拒绝' ;;
    *) printf '%s' "$2" | tr '\r\n\t' '   ' | cut -c1-80 ;;
  esac
}

request_once() {
  esc=$(printf '%s' "$TOKEN" | sed 's/[\\"]/\\&/g')
  if [ "$1" = POST ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$esc" | curl -K - -4 -sS --noproxy '*' --connect-timeout 8 -m "$TIMEOUT" \
      -H 'Content-Type: application/json' -X POST --data '' -w '\n%{http_code}' "$BASE$2" 2>&1
  else
    printf 'header = "Authorization: Bearer %s"\n' "$esc" | curl -K - -4 -sS --noproxy '*' --connect-timeout 8 -m "$TIMEOUT" \
      -w '\n%{http_code}' "$BASE$2" 2>&1
  fi
}

request() {
  attempt=1
  while :; do
    out=$(request_once "$1" "$2")
    rc=$?
    CODE=$(printf '%s\n' "$out" | tail -n 1)
    BODY=$(printf '%s\n' "$out" | sed '$d')
    case "$CODE" in
      [0-9][0-9][0-9]) ;;
      *) CODE=000 ;;
    esac
    if [ "$rc" -eq 0 ] && [ "$CODE" -ge 100 ] && [ "$CODE" -lt 500 ]; then
      return 0
    fi
    if [ "$attempt" -ge "$RETRY" ]; then
      [ "$rc" -eq 0 ] || ERR=$(printf '%s' "$BODY" | tr '\r\n' '  ' | cut -c1-160)
      return 1
    fi
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

fail_reason() {
  if [ -n "${ERR:-}" ]; then
    printf '网络请求失败（已重试 %s 次）：%s' "$RETRY" "$ERR"
    return
  fi
  err=$(json_str "$BODY" error)
  if [ -n "$err" ]; then
    printf 'HTTP %s %s' "$CODE" "$(server_hint "$err")"
  else
    printf 'HTTP %s %s' "$CODE" "$(status_hint "$CODE" "$BODY")"
  fi
}

is_json() {
  case "$1" in
    '{'*) return 0 ;;
  esac
  return 1
}

summarize() {
  CUR=$(json_str "$BODY" currentIp)
  LIMIT=$(json_raw "$BODY" limit)
  ENABLED=$(json_raw "$BODY" enabled)
  IPS=$(json_ips "$BODY")
  COUNT=0
  LISTED=0
  for ip in $IPS; do
    COUNT=$((COUNT + 1))
    [ "$ip" = "$CUR" ] && LISTED=1
  done
  FW="防火墙 INPUT $(mark "$(json_raw "$BODY" input)") FORWARD $(mark "$(json_raw "$BODY" forward)")"
}

cmd_add() {
  if ! request POST /add || [ "$CODE" -lt 200 ] || [ "$CODE" -ge 300 ] || ! is_json "$BODY"; then
    log "❌ $(fail_reason)"
    return 1
  fi
  summarize
  action=$(json_str "$BODY" action)
  evicted=$(json_str "$BODY" evicted)
  case "$action" in
    added) what=新增 ;;
    exists) what=已存在 ;;
    evicted) what="新增，淘汰 $evicted" ;;
    *) what=${action:-未知} ;;
  esac
  if [ "$ENABLED" = true ] && [ "$LISTED" = 1 ]; then
    log "✅ $CUR 已在白名单（$what，槽位 $COUNT/${LIMIT:-?}，$FW）"
    return 0
  fi
  if [ "$ENABLED" != true ]; then
    log "❌ 服务端规则校验未通过（IP ${CUR:-?}，$FW）"
  else
    log "❌ 当前 IP ${CUR:-?} 不在白名单（槽位 $COUNT/${LIMIT:-?}）"
  fi
  return 1
}

cmd_status() {
  if ! request GET /status || [ "$CODE" -lt 200 ] || [ "$CODE" -ge 300 ] || ! is_json "$BODY"; then
    log "❌ $(fail_reason)"
    return 1
  fi
  summarize
  log "当前出口 ${CUR:-未知}"
  n=0
  for ip in $IPS; do
    n=$((n + 1))
    if [ "$ip" = "$CUR" ]; then log "  → $n. $ip"; else log "    $n. $ip"; fi
  done
  [ "$n" -gt 0 ] || log "    （白名单为空）"
  log "槽位 $COUNT/${LIMIT:-?} · $FW · 规则$( [ "$ENABLED" = true ] && printf '生效' || printf '未生效')"
  if [ "$LISTED" = 1 ] && [ "$ENABLED" = true ]; then
    log "✅ 当前出口已在白名单"
    return 0
  fi
  log "⚠️  当前出口不在白名单（status 只查询不加白，需要时运行 po0dw）"
  return 1
}

MODE=add
case "${1:-}" in
  ''|add) ;;
  status) MODE=status ;;
  version|-v|--version) printf 'po0dw %s\n' "$VERSION"; exit 0 ;;
  help|-h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v curl >/dev/null 2>&1 || die '缺少 curl，请先安装'

CONF=$(find_conf)
RAW_URL=${PO0DW_URL:-$(conf_get PO0DW_URL "$CONF")}
TOKEN=${PO0DW_TOKEN:-$(conf_get PO0DW_TOKEN "$CONF")}
BASE=$(normalize_base "$RAW_URL") || die "PO0DW_URL 无效或未配置（需 https 域名，当前: ${RAW_URL:-空}）"
valid_token "$TOKEN" || die 'PO0DW_TOKEN 无效或未配置（至少 24 位可见 ASCII 字符）'
ERR=

if [ "$MODE" = status ]; then
  cmd_status
else
  cmd_add
fi
