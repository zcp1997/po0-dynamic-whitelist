#!/bin/sh
set -eu

RAW=${PO0DW_RAW:-https://raw.githubusercontent.com/zcp1997/po0-dynamic-whitelist/main}
LABEL=com.github.zcp1997.po0dw
HOTPLUG=/etc/hotplug.d/iface/99-po0dw
NM_HOOK=/etc/NetworkManager/dispatcher.d/90-po0dw
NETWORKD_HOOK=/etc/networkd-dispatcher/routable.d/90-po0dw
UNIT_DIR=/etc/systemd/system

say() { printf '[po0dw-install] %s\n' "$*"; }
fail() { printf '[po0dw-install] 错误: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法:
  PO0DW_URL=fw.example.com PO0DW_TOKEN=xxx sh install.sh          安装或升级
  sh install.sh uninstall                                          卸载

支持: Linux (systemd / cron) · macOS (launchd) · Android Termux · OpenWrt / Kwrt
未提供 PO0DW_URL / PO0DW_TOKEN 时，会沿用已有配置或在终端交互输入。
可选: PO0DW_RAW 指定脚本下载源（镜像），PO0DW_PLATFORM 强制平台
EOF
}

is_termux_prefix() {
  case "$1" in
    */com.termux/*) return 0 ;;
  esac
  return 1
}

detect_platform() {
  if [ -f /etc/openwrt_release ]; then
    echo openwrt
  elif [ -n "${TERMUX_VERSION:-}" ] || is_termux_prefix "${PREFIX:-}"; then
    echo termux
  elif [ "$(uname -s)" = Darwin ]; then
    echo macos
  elif [ "$(id -u)" = 0 ] && command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    echo systemd
  else
    echo cron
  fi
}

set_paths() {
  PLIST=
  DOMAIN=
  case "$PLATFORM" in
    openwrt)
      BIN=/usr/bin/po0dw
      CONF=/etc/po0dw.conf
      LOG=/tmp/po0dw.log
      ;;
    termux)
      BIN=$PREFIX/bin/po0dw
      CONF=$PREFIX/etc/po0dw.conf
      LOG=$PREFIX/var/log/po0dw.log
      ;;
    macos)
      if [ "$(id -u)" = 0 ]; then
        BIN=/usr/local/bin/po0dw
        CONF=/etc/po0dw.conf
        LOG=/var/log/po0dw.log
        PLIST=/Library/LaunchDaemons/$LABEL.plist
        DOMAIN=system
      else
        BIN=$HOME/.local/bin/po0dw
        CONF=$HOME/.config/po0dw.conf
        LOG=$HOME/Library/Logs/po0dw.log
        PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
        DOMAIN=gui/$(id -u)
      fi
      ;;
    systemd)
      BIN=/usr/local/bin/po0dw
      CONF=/etc/po0dw.conf
      LOG=
      ;;
    cron)
      if [ "$(id -u)" = 0 ]; then
        BIN=/usr/local/bin/po0dw
        CONF=/etc/po0dw.conf
        LOG=/var/log/po0dw.log
      else
        BIN=$HOME/.local/bin/po0dw
        CONF=$HOME/.config/po0dw.conf
        LOG=$HOME/.cache/po0dw.log
      fi
      ;;
    *) fail "未知平台: $PLATFORM" ;;
  esac
}

conf_value() {
  [ -r "$CONF" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | tail -n 1 | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

prompt() {
  (: </dev/tty) 2>/dev/null || return 1
  printf '%s' "$1" >/dev/tty
  REPLY=
  if [ "${2:-}" = secret ] && command -v stty >/dev/null 2>&1; then
    stty -echo </dev/tty 2>/dev/null || true
    IFS= read -r REPLY </dev/tty || REPLY=
    stty echo </dev/tty 2>/dev/null || true
    printf '\n' >/dev/tty
  else
    IFS= read -r REPLY </dev/tty || REPLY=
  fi
}

collect() {
  URL=${PO0DW_URL:-$(conf_value PO0DW_URL)}
  TOKEN=${PO0DW_TOKEN:-$(conf_value PO0DW_TOKEN)}
  if [ -z "$URL" ] && prompt 'API 域名（如 fw.example.com）: '; then URL=$REPLY; fi
  if [ -z "$TOKEN" ] && prompt 'API Token（输入不回显）: ' secret; then TOKEN=$REPLY; fi
  [ -n "$URL" ] || fail '缺少 PO0DW_URL'
  [ -n "$TOKEN" ] || fail '缺少 PO0DW_TOKEN'
  case "$URL$TOKEN" in
    *\"*|*\\*) fail 'PO0DW_URL / PO0DW_TOKEN 不能包含双引号或反斜杠' ;;
  esac
}

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 -m 60 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  elif command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -q -O "$2" "$1"
  else
    fail '需要 curl 或 wget 下载脚本'
  fi
}

pkg_install() {
  if command -v apk >/dev/null 2>&1; then
    apk add "$1" >/dev/null
  elif command -v opkg >/dev/null 2>&1; then
    opkg install "$1" >/dev/null
  else
    fail "请手动安装 $1"
  fi
}

openwrt_deps() {
  need=
  command -v curl >/dev/null 2>&1 || need=curl
  [ -s /etc/ssl/certs/ca-certificates.crt ] || need="$need ca-bundle"
  [ -n "$need" ] || return 0
  say "安装依赖:$need"
  if command -v apk >/dev/null 2>&1; then apk update >/dev/null; else opkg update >/dev/null; fi
  for p in $need; do pkg_install "$p"; done
}

termux_deps() {
  command -v curl >/dev/null 2>&1 || pkg install -y curl
  command -v crontab >/dev/null 2>&1 || pkg install -y cronie
  command -v sv-enable >/dev/null 2>&1 || pkg install -y termux-services
}

install_bin() {
  mkdir -p "$(dirname "$BIN")"
  tmp=$BIN.tmp.$$
  src=
  case "$0" in
    *install.sh) src=$(dirname "$0")/po0dw.sh ;;
  esac
  if [ -n "$src" ] && [ -f "$src" ]; then
    cp "$src" "$tmp"
  else
    fetch "$RAW/clients/shell/po0dw.sh" "$tmp" || { rm -f "$tmp"; fail "下载失败: $RAW/clients/shell/po0dw.sh"; }
  fi
  if ! head -n 1 "$tmp" | grep -q '^#!/bin/sh'; then
    rm -f "$tmp"
    fail '下载的 po0dw.sh 内容异常'
  fi
  if [ "$PLATFORM" = termux ]; then
    sed -i "1s|^#!/bin/sh|#!$PREFIX/bin/sh|" "$tmp"
  fi
  chmod 755 "$tmp"
  mv -f "$tmp" "$BIN"
}

write_conf() {
  mkdir -p "$(dirname "$CONF")"
  old_umask=$(umask)
  umask 077
  printf 'PO0DW_URL="%s"\nPO0DW_TOKEN="%s"\n' "$URL" "$TOKEN" >"$CONF"
  umask "$old_umask"
  chmod 600 "$CONF"
}

write_exec() {
  cat >"$1"
  chmod 755 "$1"
}

cron_set() {
  current=$(crontab -l 2>/dev/null || true)
  kept=$(printf '%s\n' "$current" | grep -v -F "$BIN" || true)
  if [ -n "$1" ] && [ -n "$kept" ]; then
    printf '%s\n%s\n' "$kept" "$1" | crontab -
  elif [ -n "$1" ]; then
    printf '%s\n' "$1" | crontab -
  elif [ -n "$kept" ]; then
    printf '%s\n' "$kept" | crontab -
  else
    crontab -r 2>/dev/null || true
  fi
}

install_cron() {
  mkdir -p "$(dirname "$LOG")"
  cron_set "*/10 * * * * PO0DW_CONF='$CONF' '$BIN' >'$LOG' 2>&1"
  if [ "$PLATFORM" = termux ]; then
    sv-enable crond >/dev/null 2>&1 || say '提示: crond 未启动，请重开 Termux 后执行 sv-enable crond'
  else
    say '提示: 请确认 cron 服务已运行（如 systemctl enable --now cron / rc-service crond start）'
  fi
}

install_systemd() {
  cat >"$UNIT_DIR/po0dw.service" <<EOF
[Unit]
Description=PO0 Dynamic Whitelist client
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=PO0DW_CONF=$CONF
ExecStart=$BIN
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
EOF
  cat >"$UNIT_DIR/po0dw.timer" <<'EOF'
[Unit]
Description=Run po0dw every 10 minutes

[Timer]
OnBootSec=1min
OnCalendar=*:0/10

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now po0dw.timer >/dev/null 2>&1
  if [ -d "$(dirname "$NM_HOOK")" ]; then
    write_exec "$NM_HOOK" <<'EOF'
#!/bin/sh
case "$2" in
  up|dhcp4-change|connectivity-change) systemctl start --no-block po0dw.service ;;
esac
EOF
    say "已添加 NetworkManager 网络切换钩子: $NM_HOOK"
  fi
  if [ -d "$(dirname "$NETWORKD_HOOK")" ]; then
    write_exec "$NETWORKD_HOOK" <<'EOF'
#!/bin/sh
systemctl start --no-block po0dw.service
EOF
    say "已添加 networkd-dispatcher 网络切换钩子: $NETWORKD_HOOK"
  fi
}

install_launchd() {
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>exec "\$0" &gt;"\$1" 2&gt;&amp;1</string>
    <string>$BIN</string>
    <string>$LOG</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PO0DW_CONF</key>
    <string>$CONF</string>
  </dict>
  <key>StartInterval</key>
  <integer>600</integer>
  <key>WatchPaths</key>
  <array>
    <string>/Library/Preferences/SystemConfiguration</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
}

sysupgrade_keep() {
  touch /etc/sysupgrade.conf
  for f in "$BIN" "$CONF" "$HOTPLUG"; do
    grep -qxF "$f" /etc/sysupgrade.conf || printf '%s\n' "$f" >>/etc/sysupgrade.conf
  done
}

sysupgrade_forget() {
  [ -f /etc/sysupgrade.conf ] || return 0
  grep -vxF -e "$BIN" -e "$CONF" -e "$HOTPLUG" /etc/sysupgrade.conf >/etc/sysupgrade.conf.po0dw || true
  cat /etc/sysupgrade.conf.po0dw >/etc/sysupgrade.conf
  rm -f /etc/sysupgrade.conf.po0dw
}

install_openwrt() {
  touch /etc/crontabs/root
  sed -i "\\#$BIN#d" /etc/crontabs/root
  printf '*/10 * * * * %s >%s 2>&1\n' "$BIN" "$LOG" >>/etc/crontabs/root
  /etc/init.d/cron enable >/dev/null 2>&1 || true
  /etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/cron start >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$HOTPLUG")"
  write_exec "$HOTPLUG" <<EOF
#!/bin/sh
[ "\$ACTION" = ifup ] || [ "\$ACTION" = ifupdate ] || exit 0
wan_if=
if [ -f /lib/functions/network.sh ]; then
  . /lib/functions/network.sh
  network_find_wan wan_if
fi
case "\$INTERFACE" in
  wan|wan_*|wwan*|pppoe*|modem*|lte*|4g*|5g*) ;;
  *) [ -n "\$wan_if" ] && [ "\$INTERFACE" = "\$wan_if" ] || exit 0 ;;
esac
( sleep 5; $BIN >$LOG 2>&1 ) &
EOF
  sysupgrade_keep
}

do_uninstall() {
  case "$PLATFORM" in
    systemd)
      systemctl disable --now po0dw.timer >/dev/null 2>&1 || true
      rm -f "$UNIT_DIR/po0dw.service" "$UNIT_DIR/po0dw.timer" "$NM_HOOK" "$NETWORKD_HOOK"
      systemctl daemon-reload
      ;;
    macos)
      launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || launchctl unload "$PLIST" >/dev/null 2>&1 || true
      rm -f "$PLIST"
      ;;
    openwrt)
      if [ -f /etc/crontabs/root ]; then
        sed -i "\\#$BIN#d" /etc/crontabs/root
        /etc/init.d/cron restart >/dev/null 2>&1 || true
      fi
      rm -f "$HOTPLUG"
      sysupgrade_forget
      ;;
    termux|cron)
      if command -v crontab >/dev/null 2>&1; then cron_set ''; fi
      ;;
  esac
  rm -f "$BIN" "$CONF"
  say "已卸载（平台: $PLATFORM）"
}

ACTION=${1:-install}
case "$ACTION" in
  install|uninstall) ;;
  help|-h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

PLATFORM=${PO0DW_PLATFORM:-$(detect_platform)}
set_paths

if [ "$ACTION" = uninstall ]; then
  do_uninstall
  exit 0
fi

case "$PLATFORM" in
  openwrt)
    [ "$(id -u)" = 0 ] || fail 'OpenWrt / Kwrt 需要 root'
    openwrt_deps
    ;;
  termux) termux_deps ;;
esac
command -v curl >/dev/null 2>&1 || fail '缺少 curl，请先安装'

collect
say "平台: $PLATFORM"
install_bin
write_conf
case "$PLATFORM" in
  openwrt) install_openwrt ;;
  systemd) install_systemd ;;
  macos) install_launchd ;;
  termux|cron) install_cron ;;
esac
say "脚本: $BIN"
say "配置: $CONF"
[ -z "$LOG" ] || say "日志: $LOG"
say '立即执行一次:'
if PO0DW_CONF="$CONF" "$BIN"; then
  say '安装完成'
else
  rc=$?
  if [ "$rc" = 2 ]; then
    fail "配置无效，请修改 $CONF 后重新运行 po0dw"
  fi
  say '已安装，但本次加白失败，请按上面的提示排查后执行 po0dw 重试'
  exit 1
fi
