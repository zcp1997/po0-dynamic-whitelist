var NAME = 'PO0 动态白名单';
var INLINE_API_HOST = '';
var INLINE_TOKEN = '';
var STORE_API_HOST = 'po0dw_api_host';
var STORE_TOKEN = 'po0dw_token';
var STORE_STATE = 'po0dw_state';
var PLACEHOLDER_HOST = 'fw.example.com';
var RETRY = 3;
var RETRY_DELAY_MS = 1500;

var isQX = typeof $task !== 'undefined';
var isLoon = typeof $loon !== 'undefined';
var hasHttpClient = typeof $httpClient !== 'undefined';
var envText = '';
try {
  if (typeof $environment !== 'undefined' && $environment) envText = JSON.stringify($environment).toLowerCase();
} catch (e) {}
var isRocket = !isQX && !isLoon && (typeof $rocket !== 'undefined' || envText.indexOf('shadowrocket') >= 0);
var isStash = !isQX && !isLoon && !isRocket && envText.indexOf('stash') >= 0;
var isSurge = !isQX && !isLoon && !isRocket && !isStash && envText.indexOf('surge') >= 0;
var TIMEOUT = isLoon ? 10000 : isSurge || isStash || isRocket ? 10 : null;

function trim(v) {
  return String(v === undefined || v === null ? '' : v).replace(/^\s+|\s+$/g, '');
}

function decode(v) {
  try {
    return decodeURIComponent(v);
  } catch (e) {
    return v;
  }
}

function parseQuery(text, out) {
  String(text).split('&').forEach(function (part) {
    var i = part.indexOf('=');
    if (i > 0) out[trim(part.slice(0, i))] = trim(decode(part.slice(i + 1)));
  });
  return out;
}

function parseArgument(raw) {
  var out = {};
  if (raw === undefined || raw === null) return out;
  if (Array.isArray(raw)) {
    if (raw.length > 0) out.api_host = trim(raw[0]);
    if (raw.length > 1) out.token = trim(raw[1]);
    return out;
  }
  if (typeof raw === 'object') {
    Object.keys(raw).forEach(function (k) {
      out[k] = trim(raw[k]);
    });
    return out;
  }
  var text = trim(raw);
  if (/^(["']).*\1$/.test(text)) text = text.slice(1, -1);
  if (text.charAt(0) === '{' || text.charAt(0) === '[') {
    try {
      return parseArgument(JSON.parse(text));
    } catch (e) {}
  }
  return parseQuery(text, out);
}

function qxArguments() {
  if (!isQX || typeof $environment === 'undefined' || !$environment) return {};
  if ($environment.variables && typeof $environment.variables === 'object') return parseArgument($environment.variables);
  var path = String($environment.sourcePath || '');
  var i = path.indexOf('#');
  return i >= 0 ? parseQuery(path.slice(i + 1), {}) : {};
}

function storeRead(key) {
  try {
    if (isQX) return $prefs.valueForKey(key);
    if (typeof $persistentStore !== 'undefined') return $persistentStore.read(key);
  } catch (e) {}
  return null;
}

function storeWrite(value, key) {
  try {
    if (isQX) return $prefs.setValueForKey(value, key);
    if (typeof $persistentStore !== 'undefined') return $persistentStore.write(value, key);
  } catch (e) {}
  return false;
}

function notify(title, subtitle, body) {
  try {
    if (isQX) $notify(title, subtitle, body);
    else if (typeof $notification !== 'undefined') $notification.post(title, subtitle, body);
  } catch (e) {}
}

function normalizeBase(value) {
  var v = trim(value);
  if (!v) return '';
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(v)) v = 'https://' + v;
  v = v.replace(/\/+$/, '');
  var m = /^https:\/\/([A-Za-z0-9.-]+)(:\d{1,5})?(\/[^\s?#]*)?$/.exec(v);
  if (!m || m[1].toLowerCase() === PLACEHOLDER_HOST) return '';
  return v;
}

function validToken(value) {
  var v = trim(value);
  return /^[\x21-\x7e]{24,}$/.test(v) ? v : '';
}

function firstValid(list, check) {
  for (var i = 0; i < list.length; i++) {
    var v = check(list[i]);
    if (v) return v;
  }
  return '';
}

function parseJSON(text) {
  try {
    var v = JSON.parse(text);
    return v && typeof v === 'object' ? v : null;
  } catch (e) {
    return null;
  }
}

function describeError(err) {
  var text = '';
  if (err !== undefined && err !== null) {
    text = typeof err === 'object' ? String(err.error || err.message || err.description || '') : String(err);
  }
  text = trim(text);
  if (!text || text === 'null' || text === 'undefined' || text === '{}') return '网络请求失败（超时 / TLS 握手失败 / 被拦截）';
  return text;
}

function delay(ms) {
  return new Promise(function (resolve) {
    if (typeof setTimeout === 'function') setTimeout(resolve, ms);
    else resolve();
  });
}

function sendOnce(base, token, method, path) {
  var opts = {
    url: base + path,
    headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' }
  };
  if (method === 'POST') opts.body = '';
  return new Promise(function (resolve) {
    if (isQX) {
      opts.method = method;
      opts.opts = { policy: 'direct', 'skip-cert-verify': false };
      $task.fetch(opts).then(
        function (resp) {
          if (resp && resp.statusCode) resolve({ status: resp.statusCode, body: resp.body });
          else resolve({ error: describeError(null) });
        },
        function (err) {
          resolve({ error: describeError(err && err.error !== undefined ? err.error : err) });
        }
      );
      return;
    }
    if (!hasHttpClient) {
      resolve({ error: '当前客户端不支持 $httpClient' });
      return;
    }
    opts.insecure = false;
    if (TIMEOUT !== null) opts.timeout = TIMEOUT;
    if (isLoon) opts.node = 'DIRECT';
    else opts.policy = 'DIRECT';
    var callback = function (err, resp, body) {
      var status = resp && (resp.status || resp.statusCode);
      if (err || !status) resolve({ error: describeError(err) });
      else resolve({ status: status, body: body });
    };
    if (method === 'POST') $httpClient.post(opts, callback);
    else $httpClient.get(opts, callback);
  });
}

function retryable(r) {
  return !!r.error || !r.status || r.status >= 500;
}

function send(base, token, method, path, attempt) {
  attempt = attempt || 1;
  return sendOnce(base, token, method, path).then(function (r) {
    if (!retryable(r)) return r;
    if (attempt >= RETRY) {
      if (r.error) r.error += '（已重试 ' + RETRY + ' 次）';
      return r;
    }
    return delay(RETRY_DELAY_MS * attempt).then(function () {
      return send(base, token, method, path, attempt + 1);
    });
  });
}

var SERVER_ERRORS = {
  unauthorized: 'Token 错误',
  'untrusted peer': 'API 只接受可信反代，检查 trusted_proxy_ip',
  'invalid public IPv4': '服务端没拿到公网 IPv4，请求可能走了代理 / IPv6',
  'INPUT/FORWARD guard not verified': '服务端防火墙规则校验失败',
  'queue / ipset mismatch; manual repair required': '队列与 ipset 不一致，需在服务端 repair',
  'failed to apply whitelist': '服务端写入 ipset 失败',
  'firewall unavailable': '服务端防火墙不可用',
  'not found': '路径不存在，检查 api_host'
};

function statusHint(status, body) {
  if (status === 502 || status === 504) return 'Nginx 连不上内网 API';
  if (status === 404) return '路径不存在，检查 api_host 与 Nginx location';
  if (status === 403) return '被 Nginx 拒绝';
  return String(body || '').replace(/\s+/g, ' ').slice(0, 80) || '无响应体';
}

function interpret(r) {
  if (r.error) return { ok: false, reason: r.error };
  var d = parseJSON(r.body);
  if (!d || r.status < 200 || r.status >= 300) {
    var msg = d && d.error ? SERVER_ERRORS[d.error] || d.error : statusHint(r.status, r.body);
    return { ok: false, reason: 'HTTP ' + r.status + ' ' + msg };
  }
  var list = (Array.isArray(d.whitelist) ? d.whitelist : []).map(function (e) {
    return e && typeof e === 'object' ? e.ip : e;
  });
  var listed = !!d.currentIp && list.indexOf(d.currentIp) >= 0;
  var ok = d.enabled === true && listed;
  var reason = '';
  if (!ok) reason = d.enabled !== true ? '服务端规则校验未通过' : '当前 IP 不在白名单';
  return { ok: ok, data: d, list: list, reason: reason };
}

function onCellular() {
  try {
    var iface = ($network.v4 && $network.v4.primaryInterface) || ($network.v6 && $network.v6.primaryInterface) || '';
    return iface.indexOf('pdp_ip') === 0;
  } catch (e) {
    return false;
  }
}

function isPanel() {
  try {
    return typeof $script !== 'undefined' && !!$script && $script.type === 'generic';
  } catch (e) {
    return false;
  }
}

function mark(v) {
  return v === true ? '✓' : '✗';
}

var ACTIONS = { added: '新增', exists: '已存在', evicted: '新增并淘汰最早 IP' };

function render(res) {
  var lines = [];
  if (!res.ok) lines.push(res.reason);
  if (res.data) {
    var d = res.data;
    if (d.currentIp) lines.push('IP: ' + d.currentIp + (onCellular() ? ' 📶' : ''));
    lines.push('槽位: ' + res.list.length + '/' + (d.limit === undefined || d.limit === null ? '?' : d.limit));
    if (d.action) lines.push('操作: ' + (ACTIONS[d.action] || d.action));
    if (d.evicted) lines.push('淘汰: ' + d.evicted);
    if (d.firewall) lines.push('防火墙: INPUT ' + mark(d.firewall.input) + ' FORWARD ' + mark(d.firewall.forward));
  }
  return lines.join('\n');
}

var finished = false;

function finish(title, content, ok) {
  if (finished) return;
  finished = true;
  if (isQX) {
    $done();
    return;
  }
  var color = ok ? '#34C759' : '#FF3B30';
  $done({
    title: title,
    content: content,
    icon: ok ? 'checkmark.shield' : 'xmark.shield',
    'icon-color': color,
    backgroundColor: color
  });
}

function report(res) {
  var title = res.ok ? '✅ PO0 加白成功' : res.config ? NAME : '❌ PO0 加白失败';
  var content = render(res);
  var state = res.ok ? 'ok|' + res.data.currentIp : 'fail|' + res.reason;
  if (storeRead(STORE_STATE) !== state) {
    storeWrite(state, STORE_STATE);
    if (!isPanel()) notify(NAME, title, content);
  }
  finish(title, content, res.ok);
}

function run() {
  var args = parseArgument(typeof $argument !== 'undefined' ? $argument : null);
  var qx = qxArguments();
  var base = firstValid([args.url, args.api_host, qx.url, qx.api_host, storeRead(STORE_API_HOST), INLINE_API_HOST], normalizeBase);
  var token = firstValid([args.token, qx.token, storeRead(STORE_TOKEN), INLINE_TOKEN], validToken);
  if (!base || !token) {
    var missing = [];
    if (!base) missing.push('api_host');
    if (!token) missing.push('token');
    return Promise.resolve({ ok: false, config: true, reason: '请配置 ' + missing.join(' 和 ') });
  }
  return send(base, token, 'POST', '/add').then(interpret);
}

try {
  run().then(report, function (e) {
    report({ ok: false, reason: '脚本异常: ' + describeError(e) });
  });
} catch (e) {
  report({ ok: false, reason: '脚本异常: ' + describeError(e) });
}
