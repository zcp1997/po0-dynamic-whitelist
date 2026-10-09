#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
PO0DW=$ROOT/clients/shell/po0dw.sh
INSTALL=$ROOT/clients/shell/install.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/po0dw-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

TOKEN=tok_abcdefghijklmnopqrstuvwxyz0123456789
PASS=0
FAIL=0

mkdir -p "$TMP/bin" "$TMP/mock"
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
d=$MOCK_DIR
n=$(($(cat "$d/count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$d/count"
cat >"$d/config"
for a in "$@"; do printf '%s\n' "$a"; done >"$d/args"
f=$d/resp.$n
[ -f "$f" ] || f=$d/resp
rc=$(sed -n 1p "$f")
code=$(sed -n 2p "$f")
sed '1,2d' "$f"
printf '\n%s' "$code"
exit "$rc"
EOF
cat >"$TMP/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/sleep"

OK_ADDED='{"enabled": true, "whitelist": [{"ip": "198.51.100.1", "slot": null}, {"ip": "203.0.113.7", "slot": null}], "limit": 10, "currentIp": "203.0.113.7", "action": "added", "evicted": null, "firewall": {"input": true, "forward": true}}'
OK_EXISTS=$(printf '%s' "$OK_ADDED" | sed 's/"added"/"exists"/')
OK_EVICTED=$(printf '%s' "$OK_ADDED" | sed -e 's/"added"/"evicted"/' -e 's/"evicted": null/"evicted": "192.0.2.9"/')
NOT_ENABLED=$(printf '%s' "$OK_ADDED" | sed -e 's/"enabled": true/"enabled": false/' -e 's/"forward": true/"forward": false/')
NOT_LISTED='{"enabled": true, "whitelist": [{"ip": "198.51.100.1", "slot": null}], "limit": 10, "currentIp": "203.0.113.7", "action": null, "evicted": null, "firewall": {"input": true, "forward": true}}'

reset() {
  rm -f "$TMP"/mock/*
}

respond() {
  f=$TMP/mock/resp${3:+.$3}
  printf '%s\n%s\n%s' "${4:-0}" "$1" "$2" >"$f"
}

run() {
  set +e
  OUT=$(env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" MOCK_DIR="$TMP/mock" PO0DW_CONF="${CONF_FILE:-$TMP/none.conf}" \
    ${PO0DW_URL+PO0DW_URL="$PO0DW_URL"} ${PO0DW_TOKEN+PO0DW_TOKEN="$PO0DW_TOKEN"} \
    $SHELL_UNDER_TEST "$PO0DW" "$@" 2>&1)
  RC=$?
  set -e
}

check() {
  if eval "$2"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL [%s] %s\n  rc=%s\n  out=%s\n' "$SHELL_UNDER_TEST" "$1" "${RC:-}" "${OUT:-}"
  fi
}

has() { printf '%s' "$OUT" | grep -F -- "$1" >/dev/null; }
arg() { grep -x -F -- "$1" "$TMP/mock/args" >/dev/null; }
calls() { cat "$TMP/mock/count" 2>/dev/null || echo 0; }

suite() {
  export PO0DW_URL=fw.test.example PO0DW_TOKEN=$TOKEN

  reset; respond 200 "$OK_ADDED"; run
  check 'add success' '[ "$RC" = 0 ] && has "✅ 203.0.113.7 已在白名单（新增，槽位 2/10，防火墙 INPUT ✓ FORWARD ✓）"'
  check 'add uses POST /add with noproxy and ipv4' 'arg https://fw.test.example/add && arg POST && arg --noproxy && arg -4'
  check 'token only via curl config' '! grep -F "$TOKEN" "$TMP/mock/args" >/dev/null && grep -x -F "header = \"Authorization: Bearer $TOKEN\"" "$TMP/mock/config" >/dev/null'

  reset; respond 200 "$OK_EXISTS"; run add
  check 'exists' '[ "$RC" = 0 ] && has "（已存在，槽位 2/10"'

  reset; respond 200 "$OK_EVICTED"; run
  check 'evicted' '[ "$RC" = 0 ] && has "新增，淘汰 192.0.2.9"'

  reset; respond 401 '{"error": "unauthorized"}'; run
  check '401 no retry' '[ "$RC" = 1 ] && has "❌ HTTP 401 Token 错误" && [ "$(calls)" = 1 ]'

  reset; respond 400 '{"error": "invalid public IPv4"}'; run
  check '400 hint' '[ "$RC" = 1 ] && has "服务端没拿到公网 IPv4"'

  reset; respond 502 '<html>bad gateway</html>' 1; respond 200 "$OK_EXISTS" 2; run
  check '502 retried then ok' '[ "$RC" = 0 ] && [ "$(calls)" = 2 ] && has "✅"'

  reset; respond 503 '{"error": "INPUT/FORWARD guard not verified"}'; run
  check '503 after retries' '[ "$RC" = 1 ] && [ "$(calls)" = 3 ] && has "HTTP 503 服务端防火墙规则校验失败"'

  reset; respond 000 'curl: (6) Could not resolve host: fw.test.example' '' 6; run
  check 'network failure' '[ "$RC" = 1 ] && [ "$(calls)" = 3 ] && has "网络请求失败（已重试 3 次）：curl: (6) Could not resolve host"'

  reset; respond 404 '<html>404</html>'; run
  check 'nginx 404' '[ "$RC" = 1 ] && has "HTTP 404 路径不存在"'

  reset; respond 200 "$NOT_ENABLED"; run
  check 'enabled false' '[ "$RC" = 1 ] && has "服务端规则校验未通过" && has "FORWARD ✗"'

  reset; respond 200 "$OK_ADDED"; run status
  check 'status listed' '[ "$RC" = 0 ] && has "当前出口 203.0.113.7" && has "  → 2. 203.0.113.7" && has "    1. 198.51.100.1" && has "✅ 当前出口已在白名单"'
  check 'status uses GET /status' 'arg https://fw.test.example/status && ! arg POST'

  reset; respond 200 "$NOT_LISTED"; run status
  check 'status not listed' '[ "$RC" = 1 ] && has "⚠️  当前出口不在白名单"'

  reset; PO0DW_URL=https://fw.test.example///; run; PO0DW_URL=fw.test.example
  check 'trailing slash normalized' 'arg https://fw.test.example/add'

  reset; PO0DW_URL=http://fw.test.example; run; PO0DW_URL=fw.test.example
  check 'http rejected' '[ "$RC" = 2 ] && has "PO0DW_URL 无效" && [ "$(calls)" = 0 ]'

  reset; PO0DW_URL=fw.example.com; run; PO0DW_URL=fw.test.example
  check 'placeholder rejected' '[ "$RC" = 2 ] && [ "$(calls)" = 0 ]'

  reset; PO0DW_URL=https://FW.Example.COM/; run; PO0DW_URL=fw.test.example
  check 'placeholder rejected case-insensitively' '[ "$RC" = 2 ] && [ "$(calls)" = 0 ]'

  reset; PO0DW_TOKEN=short; run; PO0DW_TOKEN=$TOKEN
  check 'short token rejected' '[ "$RC" = 2 ] && has "PO0DW_TOKEN 无效"'

  unset PO0DW_URL PO0DW_TOKEN
  reset; run
  check 'missing config' '[ "$RC" = 2 ]'

  CONF_FILE=$TMP/client.conf
  printf '%s\n' '  PO0DW_URL = "https://conf.test.example"' "PO0DW_TOKEN='$TOKEN'" >"$CONF_FILE"
  reset; respond 200 "$OK_EXISTS"; run
  check 'config file parsed' '[ "$RC" = 0 ] && arg https://conf.test.example/add'

  reset; respond 200 "$OK_EXISTS"; PO0DW_URL=env.test.example; run; unset PO0DW_URL
  check 'env overrides config' 'arg https://env.test.example/add'

  printf '%s\n' 'PO0DW_URL="conf.test.example"' 'PO0DW_TOKEN="abc\"def\\ghijklmnopqrstuvwxyz0123"' >"$CONF_FILE"
  reset; respond 200 "$OK_EXISTS"; run
  check 'token escaped in curl config' 'grep -x -F "header = \"Authorization: Bearer abc\\\\\\\"def\\\\\\\\ghijklmnopqrstuvwxyz0123\"" "$TMP/mock/config" >/dev/null'
  unset CONF_FILE

  run version
  check 'version' '[ "$RC" = 0 ] && has "po0dw "'
}

install_suite() {
  [ "$(id -u)" != 0 ] || { echo "skip install test as root"; return 0; }
  home=$TMP/ihome
  mkdir -p "$home"
  cat >"$TMP/bin/crontab" <<EOF
#!/bin/sh
if [ "\${1:-}" = -l ]; then cat "$TMP/crontab" 2>/dev/null || exit 1
elif [ "\${1:-}" = -r ]; then rm -f "$TMP/crontab"
else cat >"$TMP/crontab"; fi
EOF
  chmod +x "$TMP/bin/crontab"
  resolved=$(env PATH="$TMP/bin:$PATH" $SHELL_UNDER_TEST -c 'command -v crontab' 2>/dev/null || true)
  if [ "$resolved" != "$TMP/bin/crontab" ]; then
    echo "skip install test: $SHELL_UNDER_TEST 使用内置 crontab"
    return 0
  fi
  printf '%s\n' '0 3 * * * /usr/bin/true' >"$TMP/crontab"
  reset; respond 200 "$OK_EXISTS"
  set +e
  OUT=$(env -i PATH="$TMP/bin:$PATH" HOME="$home" MOCK_DIR="$TMP/mock" PO0DW_PLATFORM=cron \
    PO0DW_URL=fw.test.example PO0DW_TOKEN="$TOKEN" $SHELL_UNDER_TEST "$INSTALL" </dev/null 2>&1)
  RC=$?
  set -e
  check 'install cron' '[ "$RC" = 0 ] && [ -x "$home/.local/bin/po0dw" ] && has "安装完成"'
  check 'install keeps crontab' 'grep -F "/usr/bin/true" "$TMP/crontab" >/dev/null && grep -F "*/10 * * * * PO0DW_CONF=" "$TMP/crontab" >/dev/null'
  check 'install conf mode 600' '[ "$(ls -l "$home/.config/po0dw.conf" | cut -c1-10)" = "-rw-------" ] && grep -F "PO0DW_URL=\"fw.test.example\"" "$home/.config/po0dw.conf" >/dev/null'
  set +e
  OUT=$(env -i PATH="$TMP/bin:$PATH" HOME="$home" MOCK_DIR="$TMP/mock" PO0DW_PLATFORM=cron $SHELL_UNDER_TEST "$INSTALL" </dev/null 2>&1)
  RC=$?
  set -e
  check 'reinstall reuses config' '[ "$RC" = 0 ] && [ "$(grep -c po0dw "$TMP/crontab")" = 1 ]'
  set +e
  OUT=$(env -i PATH="$TMP/bin:$PATH" HOME="$home" PO0DW_PLATFORM=cron $SHELL_UNDER_TEST "$INSTALL" uninstall 2>&1)
  RC=$?
  set -e
  check 'uninstall' '[ "$RC" = 0 ] && [ ! -e "$home/.local/bin/po0dw" ] && [ ! -e "$home/.config/po0dw.conf" ] && ! grep -F po0dw "$TMP/crontab" >/dev/null && grep -F "/usr/bin/true" "$TMP/crontab" >/dev/null'
}

SHELLS=${TEST_SHELLS:-}
if [ -z "$SHELLS" ]; then
  SHELLS=/bin/sh
  command -v dash >/dev/null 2>&1 && SHELLS="$SHELLS dash"
  command -v busybox >/dev/null 2>&1 && SHELLS="$SHELLS busybox_sh"
  command -v bash >/dev/null 2>&1 && SHELLS="$SHELLS bash_posix"
fi

for s in $SHELLS; do
  case "$s" in
    busybox_sh) SHELL_UNDER_TEST="busybox sh" ;;
    bash_posix) SHELL_UNDER_TEST="bash --posix" ;;
    *) SHELL_UNDER_TEST=$s ;;
  esac
  suite
  install_suite
done

printf 'shell tests: %s passed, %s failed (%s)\n' "$PASS" "$FAIL" "$SHELLS"
[ "$FAIL" = 0 ]
