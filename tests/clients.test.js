const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ROOT = path.join(__dirname, '..');
const RAW_PREFIX = 'https://raw.githubusercontent.com/zcp1997/po0-dynamic-whitelist/main/';
const SHARED = fs.readFileSync(path.join(ROOT, 'clients/scripts/whitelist.js'), 'utf8');
const EGERN = fs
  .readFileSync(path.join(ROOT, 'clients/egern/whitelist.js'), 'utf8')
  .replace('export default async function', 'globalThis.main = async function');
const TOKEN = 'tok_abcdefghijklmnopqrstuvwxyz0123456789';

function body(extra) {
  return JSON.stringify(
    Object.assign(
      {
        enabled: true,
        whitelist: [
          { ip: '198.51.100.1', slot: null },
          { ip: '203.0.113.7', slot: null }
        ],
        limit: 10,
        currentIp: '203.0.113.7',
        action: 'added',
        evicted: null,
        firewall: { input: true, forward: true }
      },
      extra || {}
    )
  );
}

const OK = { status: 200, body: body() };

function runShared(kind, opts) {
  opts = opts || {};
  const responses = (opts.responses || [OK]).slice();
  const next = () => (responses.length > 1 ? responses.shift() : responses[0]);
  const requests = [];
  const notes = [];
  const store = Object.assign({}, opts.store || {});
  return new Promise((resolve, reject) => {
    const ctx = { console };
    ctx.setTimeout = (fn) => setImmediate(fn);
    ctx.$done = (value) => resolve({ value, requests, notes, store });
    if (kind === 'qx') {
      ctx.$task = {
        fetch(req) {
          requests.push(req);
          const r = next();
          return r.error ? Promise.reject({ error: r.error }) : Promise.resolve({ statusCode: r.status, body: r.body });
        }
      };
      ctx.$prefs = {
        valueForKey: (k) => (k in store ? store[k] : null),
        setValueForKey: (v, k) => ((store[k] = v), true)
      };
      ctx.$notify = (...a) => notes.push(a);
      ctx.$environment = opts.environment || {};
    } else {
      const call = (method) => (req, cb) => {
        requests.push(Object.assign({ method }, req));
        const r = next();
        setImmediate(() => (r.error !== undefined ? cb(r.error, null, null) : cb(null, { status: r.status }, r.body)));
      };
      ctx.$httpClient = { post: call('POST'), get: call('GET') };
      ctx.$persistentStore = {
        read: (k) => (k in store ? store[k] : null),
        write: (v, k) => ((store[k] = v), true)
      };
      ctx.$notification = { post: (...a) => notes.push(a) };
      if (kind === 'surge') ctx.$environment = { 'surge-version': '5.12.0', 'surge-build': '3100' };
      if (kind === 'stash') ctx.$environment = { 'stash-version': '2.7.0' };
      if (kind === 'shadowrocket') ctx.$rocket = {};
      if (kind === 'loon') ctx.$loon = 'iPhone15,2 18.0 3.2.0(1000)';
      if (opts.script) ctx.$script = opts.script;
      if (opts.network) ctx.$network = opts.network;
    }
    if ('argument' in opts) ctx.$argument = opts.argument;
    vm.createContext(ctx);
    try {
      vm.runInContext(SHARED, ctx);
    } catch (e) {
      reject(e);
    }
  });
}

const SURGE_ARG = 'token=' + TOKEN + '&url=https://fw.test.example';

test('Surge: 成功加白，请求直连并带 Bearer', async () => {
  const r = await runShared('surge', { argument: SURGE_ARG, network: { v4: { primaryInterface: 'pdp_ip0' } } });
  assert.equal(r.requests.length, 1);
  const req = r.requests[0];
  assert.equal(req.method, 'POST');
  assert.equal(req.url, 'https://fw.test.example/add');
  assert.equal(req.headers.Authorization, 'Bearer ' + TOKEN);
  assert.equal(req.policy, 'DIRECT');
  assert.equal(req.timeout, 10);
  assert.equal(req.insecure, false);
  assert.equal(req.node, undefined);
  assert.equal(r.value.title, '✅ PO0 加白成功');
  assert.match(r.value.content, /IP: 203\.0\.113\.7 📶/);
  assert.match(r.value.content, /槽位: 2\/10/);
  assert.match(r.value.content, /操作: 新增/);
  assert.match(r.value.content, /防火墙: INPUT ✓ FORWARD ✓/);
  assert.equal(r.value.icon, 'checkmark.shield');
  assert.equal(r.notes.length, 1);
  assert.equal(r.store.po0dw_state, 'ok|203.0.113.7');
});

test('Surge: 状态不变不重复通知，面板不通知', async () => {
  const first = await runShared('surge', { argument: SURGE_ARG });
  const again = await runShared('surge', { argument: SURGE_ARG, store: first.store });
  assert.equal(again.notes.length, 0);
  const panel = await runShared('surge', {
    argument: SURGE_ARG,
    script: { type: 'generic' },
    responses: [{ status: 401, body: '{"error": "unauthorized"}' }]
  });
  assert.equal(panel.notes.length, 0);
  assert.equal(panel.store.po0dw_state, 'fail|HTTP 401 Token 错误');
});

test('Surge: 兼容旧版参数里的编码 url', async () => {
  const r = await runShared('surge', { argument: 'token=' + TOKEN + '&url=https%3A%2F%2Ffw.test.example%2F' });
  assert.equal(r.requests[0].url, 'https://fw.test.example/add');
});

test('Loon: 插件对象参数、node 直连、毫秒超时', async () => {
  const r = await runShared('loon', { argument: { api_host: 'fw.test.example', token: TOKEN } });
  const req = r.requests[0];
  assert.equal(req.url, 'https://fw.test.example/add');
  assert.equal(req.node, 'DIRECT');
  assert.equal(req.policy, undefined);
  assert.equal(req.timeout, 10000);
  assert.equal(req.insecure, false);
  assert.equal(r.value.title, '✅ PO0 加白成功');
});

test('Quantumult X: 从 URL # 参数读取配置，direct 策略', async () => {
  const sourcePath = RAW_PREFIX + 'clients/scripts/whitelist.js#api_host=fw.test.example&token=' + TOKEN;
  const r = await runShared('qx', { environment: { sourcePath } });
  const req = r.requests[0];
  assert.equal(req.method, 'POST');
  assert.equal(req.url, 'https://fw.test.example/add');
  assert.equal(req.opts.policy, 'direct');
  assert.equal(req.opts['skip-cert-verify'], false);
  assert.equal(r.value, undefined);
  assert.equal(r.notes.length, 1);
  assert.equal(r.notes[0][1], '✅ PO0 加白成功');
});

test('Quantumult X: 支持 $environment.variables', async () => {
  const r = await runShared('qx', { environment: { variables: { api_host: 'fw.test.example', token: TOKEN } } });
  assert.equal(r.requests[0].url, 'https://fw.test.example/add');
});

test('Stash: 字符串参数，秒级超时，磁贴背景色', async () => {
  const r = await runShared('stash', { argument: 'api_host=fw.test.example&token=' + TOKEN });
  assert.equal(r.requests[0].timeout, 10);
  assert.equal(r.requests[0].policy, 'DIRECT');
  assert.equal(r.value.backgroundColor, '#34C759');
});

test('Shadowrocket: 去掉外层引号后解析参数', async () => {
  const r = await runShared('shadowrocket', { argument: '"api_host=fw.test.example&token=' + TOKEN + '"' });
  assert.equal(r.requests[0].url, 'https://fw.test.example/add');
  assert.equal(r.requests[0].timeout, 10);
});

test('未替换占位符时不发请求并提示配置', async () => {
  const r = await runShared('stash', { argument: 'api_host=fw.example.com&token=REPLACE_WITH_TOKEN' });
  assert.equal(r.requests.length, 0);
  assert.equal(r.value.title, 'PO0 动态白名单');
  assert.equal(r.value.content, '请配置 api_host 和 token');
});

test('拒绝 http:// 地址', async () => {
  const r = await runShared('surge', { argument: 'token=' + TOKEN + '&url=http://fw.test.example' });
  assert.equal(r.requests.length, 0);
  assert.equal(r.value.content, '请配置 api_host');
});

test('持久化存储兜底', async () => {
  const r = await runShared('surge', { store: { po0dw_api_host: 'store.test.example', po0dw_token: TOKEN } });
  assert.equal(r.requests[0].url, 'https://store.test.example/add');
});

test('401 不重试并给出中文原因', async () => {
  const r = await runShared('surge', { argument: SURGE_ARG, responses: [{ status: 401, body: '{"error": "unauthorized"}' }] });
  assert.equal(r.requests.length, 1);
  assert.equal(r.value.title, '❌ PO0 加白失败');
  assert.equal(r.value.content, 'HTTP 401 Token 错误');
});

test('502 重试后成功', async () => {
  const r = await runShared('surge', {
    argument: SURGE_ARG,
    responses: [{ status: 502, body: '<html>502</html>' }, OK]
  });
  assert.equal(r.requests.length, 2);
  assert.equal(r.value.title, '✅ PO0 加白成功');
});

test('网络错误重试 3 次', async () => {
  const r = await runShared('loon', {
    argument: { api_host: 'fw.test.example', token: TOKEN },
    responses: [{ error: null }]
  });
  assert.equal(r.requests.length, 3);
  assert.match(r.value.content, /网络请求失败.*已重试 3 次/);
});

test('enabled=false 判定失败并展示防火墙状态', async () => {
  const r = await runShared('surge', {
    argument: SURGE_ARG,
    responses: [{ status: 200, body: body({ enabled: false, firewall: { input: true, forward: false } }) }]
  });
  assert.equal(r.value.title, '❌ PO0 加白失败');
  assert.match(r.value.content, /服务端规则校验未通过/);
  assert.match(r.value.content, /FORWARD ✗/);
});

test('淘汰信息', async () => {
  const r = await runShared('surge', {
    argument: SURGE_ARG,
    responses: [{ status: 200, body: body({ action: 'evicted', evicted: '192.0.2.9' }) }]
  });
  assert.match(r.value.content, /操作: 新增并淘汰最早 IP/);
  assert.match(r.value.content, /淘汰: 192\.0\.2\.9/);
});

function runEgern(env, responses, storage) {
  const queue = (responses || [OK]).slice();
  const next = () => (queue.length > 1 ? queue.shift() : queue[0]);
  const requests = [];
  const notes = [];
  const kv = Object.assign({}, storage || {});
  const ctx = {
    env,
    device: { wifi: { ssid: null }, cellular: { carrier: 'X', radio: 'NR' } },
    storage: { get: (k) => (k in kv ? kv[k] : null), set: (k, v) => (kv[k] = v) },
    notify: (o) => notes.push(o),
    http: {
      post: async (url, o) => {
        requests.push(Object.assign({ url }, o));
        const r = next();
        if (r.throwMessage) throw new Error(r.throwMessage);
        if (r.status < 200 || r.status >= 300) throw new Error('HTTP error! status: ' + r.status + ', body: ' + r.body);
        return { status: r.status, text: async () => r.body };
      }
    }
  };
  const sandbox = { console, setTimeout: (fn) => setImmediate(fn) };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(EGERN, sandbox);
  return sandbox.main(ctx).then(() => ({ requests, notes, kv }));
}

test('Egern: 成功加白并通知', async () => {
  const r = await runEgern({ api_host: 'fw.test.example', token: TOKEN });
  assert.equal(r.requests.length, 1);
  assert.equal(r.requests[0].url, 'https://fw.test.example/add');
  assert.equal(r.requests[0].policy, 'DIRECT');
  assert.equal(r.requests[0].timeout, 10000);
  assert.equal(r.requests[0].headers.Authorization, 'Bearer ' + TOKEN);
  assert.equal(r.notes.length, 1);
  assert.equal(r.notes[0].subtitle, '✅ PO0 加白成功');
  assert.match(r.notes[0].body, /IP: 203\.0\.113\.7 📶/);
  const again = await runEgern({ api_host: 'fw.test.example', token: TOKEN }, [OK], r.kv);
  assert.equal(again.notes.length, 0);
});

test('Egern: 非 2xx 抛错时解析状态码', async () => {
  const r = await runEgern({ api_host: 'fw.test.example', token: TOKEN }, [{ status: 401, body: '{"error": "unauthorized"}' }]);
  assert.equal(r.requests.length, 1);
  assert.equal(r.notes[0].body, 'HTTP 401 Token 错误');
});

test('Egern: 网络错误重试，未配置不请求', async () => {
  const r = await runEgern({ api_host: 'fw.test.example', token: TOKEN }, [{ throwMessage: 'The request timed out.' }]);
  assert.equal(r.requests.length, 3);
  assert.match(r.notes[0].body, /The request timed out\.（已重试 3 次）/);
  const none = await runEgern({ api_host: 'fw.example.com', token: '' });
  assert.equal(none.requests.length, 0);
  assert.equal(none.notes[0].body, '请配置 api_host 和 token');
});

const MODULES = [
  'clients/surge/whitelist.sgmodule',
  'clients/loon/whitelist.plugin',
  'clients/stash/whitelist.stoverride',
  'clients/quantumultx/whitelist.snippet',
  'clients/shadowrocket/whitelist.srmodule',
  'clients/egern/whitelist.yaml'
];

test('模块引用的仓库文件都存在', () => {
  for (const m of MODULES) {
    const text = fs.readFileSync(path.join(ROOT, m), 'utf8');
    const refs = text.match(new RegExp(RAW_PREFIX.replace(/[.]/g, '\\.') + '[^\\s,"#?]+', 'g')) || [];
    assert.ok(refs.length > 0, m);
    for (const ref of refs) assert.ok(fs.existsSync(path.join(ROOT, ref.slice(RAW_PREFIX.length))), ref);
  }
});

test('需要手改的模块占位符数量与说明一致', () => {
  for (const m of ['clients/stash/whitelist.stoverride', 'clients/quantumultx/whitelist.snippet', 'clients/shadowrocket/whitelist.srmodule']) {
    const text = fs.readFileSync(path.join(ROOT, m), 'utf8');
    const body = text.replace(/^(#!desc=|desc:).*$/gm, '').replace(/^  使用前.*$/gm, '');
    assert.equal((body.match(/fw\.example\.com/g) || []).length, 3, m);
    assert.equal((body.match(/REPLACE_WITH_TOKEN/g) || []).length, 2, m);
  }
});
