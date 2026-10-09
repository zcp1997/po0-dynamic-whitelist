const STORE_STATE = 'po0dw_state';
const PLACEHOLDER_HOST = 'fw.example.com';
const RETRY = 3;
const RETRY_DELAY_MS = 1500;
const TIMEOUT_MS = 10000;

const SERVER_ERRORS = {
  unauthorized: 'Token 不正确，请核对 token 配置',
  'untrusted peer': '服务端只接受可信反代，请检查 trusted_proxy_ip',
  'invalid public IPv4': '服务端没拿到公网 IPv4，请求可能走了代理或 IPv6',
  'INPUT/FORWARD guard not verified': '服务端防火墙规则校验未通过',
  'queue / ipset mismatch; manual repair required': '服务端队列与 ipset 不一致，需要手动 repair',
  'failed to apply whitelist': '服务端写入 ipset 失败',
  'firewall unavailable': '服务端防火墙暂时不可用',
  'not found': '接口地址不对，请检查 api_host'
};

const TITLES = {
  added: '✅ PO0 已加入白名单',
  evicted: '✅ PO0 已加入白名单',
  exists: '✅ PO0 已在白名单',
  ineffective: '⚠️ PO0 加白未生效',
  fail: '❌ PO0 加白失败',
  config: '⚙️ PO0 待配置'
};

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
    return { error: true, detail: msg && msg !== 'null' && msg !== 'undefined' ? msg : '' };
  }
}

async function post(ctx, base, token) {
  let r = null;
  for (let attempt = 1; attempt <= RETRY; attempt++) {
    r = await postOnce(ctx, base, token);
    if (!r.error && r.status && r.status < 500) return r;
    if (attempt < RETRY) await sleep(RETRY_DELAY_MS * attempt);
  }
  return r;
}

function statusHint(status, body) {
  if (status === 502 || status === 504) return 'Nginx 连不上内网 API';
  if (status === 404) return '接口地址不对，请检查 api_host 和 Nginx 配置';
  if (status === 403) return '请求被 Nginx 拒绝';
  const text = String(body || '').replace(/\s+/g, ' ').slice(0, 60);
  return text ? '服务器返回了意外内容：' + text : '服务器没有返回内容';
}

function firewallProblem(d) {
  const fw = d.firewall || {};
  const bad = [];
  if (fw.input !== true) bad.push('INPUT');
  if (fw.forward !== true) bad.push('FORWARD');
  return bad.length ? '服务端 ' + bad.join(' / ') + ' 规则校验未通过' : '服务端队列与 ipset 不一致';
}

function interpret(r) {
  if (r.error) {
    return { kind: 'fail', reason: '连不上服务器，已重试 ' + RETRY + ' 次', detail: r.detail || '可能是超时、TLS 握手失败或被拦截' };
  }
  const d = parseJSON(r.body);
  if (!d || r.status < 200 || r.status >= 300) {
    const msg = d && d.error ? SERVER_ERRORS[d.error] || d.error : statusHint(r.status, r.body);
    return { kind: 'fail', reason: msg + '（HTTP ' + r.status + '）' };
  }
  const list = (Array.isArray(d.whitelist) ? d.whitelist : []).map((e) => (e && typeof e === 'object' ? e.ip : e));
  const res = { data: d, list };
  if (d.enabled !== true) {
    res.kind = 'ineffective';
    res.reason = firewallProblem(d);
  } else if (!d.currentIp || list.indexOf(d.currentIp) < 0) {
    res.kind = 'ineffective';
    res.reason = '本机 IP 不在白名单中';
  } else {
    res.kind = d.action === 'added' || d.action === 'evicted' ? d.action : 'exists';
  }
  return res;
}

function isOk(res) {
  return res.kind === 'added' || res.kind === 'exists' || res.kind === 'evicted';
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

function slots(res) {
  const limit = res.data.limit === undefined || res.data.limit === null ? '?' : res.data.limit;
  return res.list.length + '/' + limit;
}

function render(res, cellular) {
  const lines = [];
  const d = res.data;
  if (d && d.currentIp) lines.push(d.currentIp + (cellular ? '（蜂窝网络）' : ''));
  if (res.kind === 'added') {
    lines.push('刚刚加入，已用 ' + slots(res) + ' 个槽位');
  } else if (res.kind === 'exists') {
    lines.push('无需重复添加，已用 ' + slots(res) + ' 个槽位');
  } else if (res.kind === 'evicted') {
    lines.push('刚刚加入，槽位已满 ' + slots(res));
    lines.push('最早的 ' + (d.evicted || 'IP') + ' 已被移出');
  } else {
    lines.push(res.reason);
    if (res.detail) lines.push(res.detail);
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
    res = { kind: 'config', reason: '请先填写 ' + missing.join(' 和 ') };
  } else {
    res = interpret(await post(ctx, base, token));
  }
  const title = TITLES[res.kind] || TITLES.fail;
  const content = render(res, onCellular(ctx));
  const state = isOk(res) ? 'ok|' + res.data.currentIp : res.kind + '|' + res.reason;
  let previous = null;
  try {
    previous = ctx.storage.get(STORE_STATE);
  } catch (e) {}
  if (previous !== state) {
    try {
      ctx.storage.set(STORE_STATE, state);
    } catch (e) {}
    ctx.notify({ title, body: content });
  }
}
