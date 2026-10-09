const NAME = 'PO0 动态白名单';
const STORE_STATE = 'po0dw_state';
const PLACEHOLDER_HOST = 'fw.example.com';
const RETRY = 3;
const RETRY_DELAY_MS = 1500;
const TIMEOUT_MS = 10000;

const SERVER_ERRORS = {
  unauthorized: 'Token 错误',
  'untrusted peer': 'API 只接受可信反代，检查 trusted_proxy_ip',
  'invalid public IPv4': '服务端没拿到公网 IPv4，请求可能走了代理 / IPv6',
  'INPUT/FORWARD guard not verified': '服务端防火墙规则校验失败',
  'queue / ipset mismatch; manual repair required': '队列与 ipset 不一致，需在服务端 repair',
  'failed to apply whitelist': '服务端写入 ipset 失败',
  'firewall unavailable': '服务端防火墙不可用',
  'not found': '路径不存在，检查 api_host'
};

const ACTIONS = { added: '新增', exists: '已存在', evicted: '新增并淘汰最早 IP' };

function trim(v) {
  return String(v === undefined || v === null ? '' : v).trim();
}

function normalizeBase(value) {
  let v = trim(value);
  if (!v) return '';
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(v)) v = 'https://' + v;
  v = v.replace(/\/+$/, '');
  const m = /^https:\/\/([A-Za-z0-9.-]+)(:\d{1,5})?(\/[^\s?#]*)?$/.exec(v);
  if (!m || m[1].toLowerCase() === PLACEHOLDER_HOST) return '';
  return v;
}

function validToken(value) {
  const v = trim(value);
  return /^[\x21-\x7e]{24,}$/.test(v) ? v : '';
}

function parseJSON(text) {
  try {
    const v = JSON.parse(text);
    return v && typeof v === 'object' ? v : null;
  } catch (e) {
    return null;
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function postOnce(ctx, base, token) {
  try {
    const resp = await ctx.http.post(base + '/add', {
      headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
      body: '',
      timeout: TIMEOUT_MS,
      policy: 'DIRECT'
    });
    let body = '';
    try {
      body = await resp.text();
    } catch (e) {}
    return { status: resp.status, body };
  } catch (e) {
    const msg = trim((e && e.message) || e);
    const m = msg.match(/status:\s*(\d{3})(?:\s*,\s*body:\s*([\s\S]*))?/i);
    if (m) return { status: parseInt(m[1], 10), body: m[2] || '' };
    return { error: msg && msg !== 'null' && msg !== 'undefined' ? msg : '网络请求失败（超时 / TLS 握手失败 / 被拦截）' };
  }
}

async function post(ctx, base, token) {
  let r = null;
  for (let attempt = 1; attempt <= RETRY; attempt++) {
    r = await postOnce(ctx, base, token);
    if (!r.error && r.status && r.status < 500) return r;
    if (attempt < RETRY) await sleep(RETRY_DELAY_MS * attempt);
  }
  if (r.error) r.error += '（已重试 ' + RETRY + ' 次）';
  return r;
}

function statusHint(status, body) {
  if (status === 502 || status === 504) return 'Nginx 连不上内网 API';
  if (status === 404) return '路径不存在，检查 api_host 与 Nginx location';
  if (status === 403) return '被 Nginx 拒绝';
  return String(body || '').replace(/\s+/g, ' ').slice(0, 80) || '无响应体';
}

function interpret(r) {
  if (r.error) return { ok: false, reason: r.error };
  const d = parseJSON(r.body);
  if (!d || r.status < 200 || r.status >= 300) {
    const msg = d && d.error ? SERVER_ERRORS[d.error] || d.error : statusHint(r.status, r.body);
    return { ok: false, reason: 'HTTP ' + r.status + ' ' + msg };
  }
  const list = (Array.isArray(d.whitelist) ? d.whitelist : []).map((e) => (e && typeof e === 'object' ? e.ip : e));
  const listed = !!d.currentIp && list.indexOf(d.currentIp) >= 0;
  const ok = d.enabled === true && listed;
  let reason = '';
  if (!ok) reason = d.enabled !== true ? '服务端规则校验未通过' : '当前 IP 不在白名单';
  return { ok, data: d, list, reason };
}

function onCellular(ctx) {
  try {
    const d = ctx.device || {};
    const onWifi = !!(d.wifi && d.wifi.ssid);
    const hasCell = !!(d.cellular && (d.cellular.carrier || d.cellular.radio));
    return !onWifi && hasCell;
  } catch (e) {
    return false;
  }
}

function mark(v) {
  return v === true ? '✓' : '✗';
}

function render(res, cellular) {
  const lines = [];
  if (!res.ok) lines.push(res.reason);
  if (res.data) {
    const d = res.data;
    if (d.currentIp) lines.push('IP: ' + d.currentIp + (cellular ? ' 📶' : ''));
    lines.push('槽位: ' + res.list.length + '/' + (d.limit === undefined || d.limit === null ? '?' : d.limit));
    if (d.action) lines.push('操作: ' + (ACTIONS[d.action] || d.action));
    if (d.evicted) lines.push('淘汰: ' + d.evicted);
    if (d.firewall) lines.push('防火墙: INPUT ' + mark(d.firewall.input) + ' FORWARD ' + mark(d.firewall.forward));
  }
  return lines.join('\n');
}

export default async function (ctx) {
  const env = ctx.env || {};
  const base = normalizeBase(env.url || env.api_host);
  const token = validToken(env.token);
  let res;
  if (!base || !token) {
    const missing = [];
    if (!base) missing.push('api_host');
    if (!token) missing.push('token');
    res = { ok: false, config: true, reason: '请配置 ' + missing.join(' 和 ') };
  } else {
    res = interpret(await post(ctx, base, token));
  }
  const title = res.ok ? '✅ PO0 加白成功' : res.config ? NAME : '❌ PO0 加白失败';
  const content = render(res, onCellular(ctx));
  const state = res.ok ? 'ok|' + res.data.currentIp : 'fail|' + res.reason;
  let previous = null;
  try {
    previous = ctx.storage.get(STORE_STATE);
  } catch (e) {}
  if (previous !== state) {
    try {
      ctx.storage.set(STORE_STATE, state);
    } catch (e) {}
    ctx.notify({ title: NAME, subtitle: title, body: content });
  }
}
