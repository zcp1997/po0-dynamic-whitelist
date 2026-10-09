#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
SET=po0_dynamic_whitelist
REGION=po0_region_whitelist
CHAIN=PO0_REGION_WHITELIST
FWD=PO0_DYNAMIC_FWD
TAG=po0-dynamic-v02
CFG=/etc/po0-dynamic-whitelist/config.json
DATA=/var/lib/po0-dynamic-whitelist
BK=/var/backups/po0-dynamic-whitelist
ROOT=/opt/po0-dynamic-whitelist
SERVICE=po0-dynamic-whitelist.service
fail(){ echo "ERROR: $*" >&2; exit 1; }
need(){ for x in ipset iptables-nft iptables-nft-save ip6tables-nft-save nft python3; do command -v "$x" >/dev/null || fail "Missing $x"; done; }
read_cfg(){
  read -r PEER HOST PORT IFACES < <(python3 - "$CFG" <<'PY'
import sys,json,ipaddress
c=json.load(open(sys.argv[1]));
for k in ('listen_host','trusted_proxy_ip'):
 a=ipaddress.ip_address(c[k]); assert a.version==4 and not a.is_unspecified
assert isinstance(c['listen_port'],int) and 1<=c['listen_port']<=65535
assert isinstance(c['max_slots'],int) and not isinstance(c['max_slots'],bool) and 1<=c['max_slots']<=100
assert isinstance(c['api_token'],str) and len(c['api_token'])>=24 and 'REPLACE' not in c['api_token']
interfaces=c.get('ingress_interfaces')
assert isinstance(interfaces,list) and interfaces and len(interfaces)<=16
assert all(isinstance(i,str) and i and len(i)<=15 and i.replace('_','').replace('-','').replace('.','').isalnum() for i in interfaces)
assert len(set(interfaces))==len(interfaces)
print(c['trusted_proxy_ip'],c['listen_host'],c['listen_port'],','.join(interfaces))
PY
)
}
# Strictly parse -S rules; avoid fuzzy deletion and edit only owned resources.
rule_index(){ local ch=$1 literal=$2; iptables-nft -S "$ch" | grep '^-A ' | awk -v s="$literal" 'index($0,s){print NR}'; }
rule_count(){ local ch=$1 literal=$2; iptables-nft -S "$ch" | grep -Fc -- "$literal" || true; }
owner_rule(){ local ch=$1 token=$2; iptables-nft -S "$ch" | grep -F -- '--comment '"$token" || true; }
assert_original(){
  ipset list "$REGION" >/dev/null || fail 'Original region ipset missing'
  iptables-nft -S "$CHAIN" >/dev/null || fail 'Original region chain missing'
  local rules
  rules=$(iptables-nft -S "$CHAIN")
  [[ $(grep -c -- '--match-set po0_region_whitelist src' <<<"$rules") == 1 ]] || fail 'Region accept rule ambiguous'
  [[ $(grep -c -- '-j REJECT' <<<"$rules") == 1 ]] || fail 'Region reject rule ambiguous'
  iptables-nft -S INPUT | grep -Fq -- "-j $CHAIN" || fail 'Region chain not attached to INPUT'
}
backup(){
  local dir="$BK/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  install -d -m 700 "$dir"
  iptables-nft-save >"$dir/iptables-nft.before"
  ip6tables-nft-save >"$dir/ip6tables-nft.before"
  ipset save >"$dir/ipset.before"
  nft -a list ruleset >"$dir/nft.before" 
  [[ -f "$CFG" ]] && cp "$CFG" "$dir/config.before.json"
  chmod 600 "$dir"/*
  echo "$dir"
}
ensure_set(){
  if ! ipset list "$SET" >/dev/null 2>&1; then ipset create "$SET" hash:ip family inet maxelem 1024; fi
  ipset list "$SET" | grep -q 'Type: hash:ip' || fail 'Unexpected dynamic set type'
}
ensure_input(){
  local rules idx
  rules=$(iptables-nft -S "$CHAIN")
  [[ $(grep -c -- "--comment ${TAG}-allow" <<<"$rules" || true) -le 1 ]] || fail 'Duplicate INPUT dynamic rules'
  [[ $(grep -c -- "--comment ${TAG}-api" <<<"$rules" || true) -le 1 ]] || fail 'Duplicate INPUT API rules'
  if ! grep -Fq -- "--comment ${TAG}-allow" <<<"$rules"; then
    idx=$(awk '/--match-set po0_region_whitelist src/{print NR-1;exit}' <<<"$rules")
    [[ "$idx" =~ ^[0-9]+$ ]] || fail 'Cannot find original region rule position'
    iptables-nft -I "$CHAIN" "$idx" -m set --match-set "$SET" src -m comment --comment "${TAG}-allow" -j ACCEPT
  fi
  rules=$(iptables-nft -S "$CHAIN")
  if ! grep -Fq -- "--comment ${TAG}-api" <<<"$rules"; then
    idx=$(awk '/--match-set po0_region_whitelist src/{print NR-1;exit}' <<<"$rules")
    iptables-nft -I "$CHAIN" "$idx" -s "$PEER/32" -d "$HOST/32" -p tcp --dport "$PORT" -m comment --comment "${TAG}-api" -j ACCEPT
  fi
}
verify_forward_chain(){
  local rules
  rules=$(iptables-nft -S "$FWD") || return 1
  python3 - "$SET" "$REGION" "$FWD" <<'PYVERIFY'
import subprocess,sys,shlex
_,dyn,reg,chain=sys.argv
rows=[shlex.split(x) for x in subprocess.check_output(['iptables-nft','-S',chain],text=True).splitlines() if x.startswith('-A ')]
if len(rows)!=3:sys.exit(1)
if not (rows[0][-2:]==['-j','RETURN'] and rows[0][rows[0].index('--match-set')+1:rows[0].index('--match-set')+3]==[dyn,'src']):sys.exit(1)
if not (rows[1][-2:]==['-j','RETURN'] and rows[1][rows[1].index('--match-set')+1:rows[1].index('--match-set')+3]==[reg,'src']):sys.exit(1)
if '-j' not in rows[2]:sys.exit(1)
if rows[2][rows[2].index('-j')+1]!='REJECT':sys.exit(1)
PYVERIFY
}
ensure_forward(){
  if ! iptables-nft -S "$FWD" >/dev/null 2>&1; then iptables-nft -N "$FWD"; fi
  local r; r=$(iptables-nft -S "$FWD")
  # Never alter a pre-existing chain with this name unless its complete content is ours.
  if grep -q '^-A ' <<<"$r"; then
    verify_forward_chain || fail 'Unknown forward chain contents; refusing to modify'
  else
    iptables-nft -A "$FWD" -m set --match-set "$SET" src -j RETURN
    iptables-nft -A "$FWD" -m set --match-set "$REGION" src -j RETURN
    iptables-nft -A "$FWD" -j REJECT --reject-with icmp-port-unreachable
  fi
  local iface line tag
  IFS=',' read -ra interfaces <<<"$IFACES"
  for iface in "${interfaces[@]}"; do
    tag="${TAG}-fwd-${iface}"
    line=$(owner_rule FORWARD "$tag")
    if [[ -z "$line" ]]; then
      iptables-nft -I FORWARD 1 -i "$iface" -m conntrack --ctstate NEW -m conntrack --ctstate DNAT -m comment --comment "$tag" -j "$FWD"
    fi
  done
}
verify(){
  assert_original
  local s region reject dyn api
  s=$(iptables-nft -S "$CHAIN")
  # Position check uses only unambiguous comment and canonical set references.
  python3 -c '
import subprocess,sys
r=subprocess.check_output(["iptables-nft","-S","PO0_REGION_WHITELIST"],text=True).splitlines()
f=lambda s:[i for i,x in enumerate(r) if s in x]
a=f("--comment po0-dynamic-v02-allow"); b=f("--comment po0-dynamic-v02-api")
c=f("--match-set po0_region_whitelist src");d=f("-j REJECT")
assert all(len(x)==1 for x in (a,b,c,d)) and a[0]<c[0]<d[0] and b[0]<c[0],"INPUT order invalid"
' || fail 'INPUT guard ordering invalid'
  local f rules iface
  rules=$(iptables-nft -S "$FWD")
  [[ $(grep -c '^-A ' <<<"$rules") == 3 ]] || fail 'FORWARD guard has unexpected rules'
  grep -Fq -- "--match-set $SET src -j RETURN" <<<"$rules" || fail 'Forward dynamic bypass missing'
  grep -Fq -- "--match-set $REGION src -j RETURN" <<<"$rules" || fail 'Forward region bypass missing'
  grep -Fq -- '-j REJECT' <<<"$rules" || fail 'Forward reject missing'
  verify_forward_chain || fail 'FORWARD chain contents mismatch'
  IFS=',' read -ra interfaces <<<"$IFACES"
  for iface in "${interfaces[@]}"; do
    [[ $(owner_rule FORWARD "${TAG}-fwd-${iface}" | wc -l) == 1 ]] || fail "Forward hook missing $iface"
  done
  # Docker may prepend rules to FORWARD. Every hook must precede any non-project rule.
  python3 - "$TAG" "$IFACES" <<'PY'
import subprocess,sys
lines=[x for x in subprocess.check_output(['iptables-nft','-S','FORWARD'],text=True).splitlines() if x.startswith('-A ')]
interfaces=sys.argv[2].split(','); tags=[f'--comment {sys.argv[1]}-fwd-{x}' for x in interfaces]
assert all(any(t in row for row in lines) for t in tags)
first_other=next((i for i,line in enumerate(lines) if not any(t in line for t in tags)),len(lines))
assert all(next(i for i,line in enumerate(lines) if t in line)<first_other for t in tags), 'Docker/another rule precedes guard'
PY
  echo 'INPUT/FORWARD guards verified; DNAT scope only.'
}
remove_owned(){
  python3 - "$TAG" "$CHAIN" <<'PYDELETE'
import subprocess,sys,shlex
prefix,inp=sys.argv[1:]
allowed={prefix+'-allow',prefix+'-api'}
chains=(inp,'FORWARD')
for chain in chains:
 p=subprocess.run(['iptables-nft','-S',chain],capture_output=True,text=True)
 if p.returncode: continue
 found=[]
 for row in p.stdout.splitlines():
  if not row.startswith('-A '):continue
  tokens=shlex.split(row)
  if '--comment' not in tokens:continue
  tag=tokens[tokens.index('--comment')+1]
  if chain=='FORWARD' and tag.startswith(prefix+'-fwd-'):
   allowed_tag=True
  else:allowed_tag=(chain==inp and tag in allowed)
  if allowed_tag:found.append(tokens)
 # A duplicate signature or foreign application with our tag is ambiguous.
 seen=[r[r.index('--comment')+1] for r in found]
 if len(seen)!=len(set(seen)):raise SystemExit('Duplicate project tag; refusing cleanup')
 for tokens in found:
  subprocess.run(['iptables-nft','-D',chain]+tokens[2:],check=True)
PYDELETE
  if iptables-nft -S "$FWD" >/dev/null 2>&1; then
    verify_forward_chain || fail "FORWARD chain has foreign or changed rules; refusing deletion"
    local refs
    refs=$(iptables-nft -S | grep -F -- "-j $FWD" || true)
    [[ -z "$refs" ]] || fail 'Foreign references to project FORWARD chain; refusing deletion'
    iptables-nft -F "$FWD"
    iptables-nft -X "$FWD"
  fi
  if ipset list "$SET" >/dev/null 2>&1; then ipset destroy "$SET" || fail 'Dynamic set has foreign references'; fi
}

case "${1:-}" in
  backup) need; backup;;
  install)
    need; assert_original
    [[ $EUID -eq 0 ]] || fail 'root required'
    [[ -f "$CFG" ]] || fail "Create $CFG based on config.json first"
    read_cfg
    [[ ! -e /etc/systemd/system/$SERVICE ]] || fail 'Already installed; use verify'
    # Preflight: never take ownership of a chain created by another application.
    if iptables-nft -S "$FWD" >/dev/null 2>&1; then
      verify_forward_chain || fail 'Reserved FORWARD chain name is already owned by another application'
    fi
    # Ensure configured ingress interfaces exist before writing any rule.
    IFS=',' read -ra pre_interfaces <<<"$IFACES"
    for pre_iface in "${pre_interfaces[@]}"; do
      [[ -e "/sys/class/net/$pre_iface" ]] || fail "Configured ingress interface missing: $pre_iface"
    done
    snapshot=$(backup); echo "Pre-install backup: $snapshot"
    trap 'echo "Install failed: attempting selective rollback" >&2; systemctl disable --now "$SERVICE" 2>/dev/null || true; rm -f "/etc/systemd/system/$SERVICE"; systemctl daemon-reload || true; remove_owned || true' ERR
    install -d -m 755 "$ROOT"; install -d -m 700 "$DATA"
    cp "$(dirname "$0")/whitelist_api.py" "$ROOT/whitelist_api.py"
    cp "$(dirname "$0")/firewall.sh" "$ROOT/firewall.sh"
    chmod 755 "$ROOT/firewall.sh"
    [[ -f "$DATA/whitelist.json" ]] || printf '[]\n' >"$DATA/whitelist.json"
    ensure_set; ensure_input; ensure_forward; verify
    cat >/etc/systemd/system/$SERVICE <<EOF_SERVICE
[Unit]
Description=PO0 Dynamic Whitelist v0.2
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStartPre=$ROOT/firewall.sh repair
ExecStart=/usr/bin/python3 $ROOT/whitelist_api.py
Restart=on-failure
RestartSec=3
User=root
UMask=0077
NoNewPrivileges=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=$DATA
PrivateTmp=yes
[Install]
WantedBy=multi-user.target
EOF_SERVICE
    systemctl daemon-reload; systemctl enable --now "$SERVICE"
    trap - ERR
    echo "$snapshot" >"$ROOT/backup-location"
    echo "Installed. Snapshot: $snapshot"
    ;;
  repair)
    need; read_cfg; assert_original; ensure_set; ensure_input; ensure_forward; verify
    ;;
  verify)
    need; read_cfg; verify; ipset list "$SET" | head -9
    ;;
  uninstall)
    need; [[ $EUID -eq 0 ]] || fail 'root required'
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    remove_owned
    rm -f "/etc/systemd/system/$SERVICE"; systemctl daemon-reload
    echo 'Only project-owned INPUT/FORWARD hooks, chain and dynamic set removed; original PO0 preserved.'
    ;;
  *) echo "Usage: $0 {backup|install|repair|verify|uninstall}"; exit 2;;
esac
