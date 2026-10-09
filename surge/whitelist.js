/* PO0 dynamic whitelist; Surge script, parameter: token=<TOKEN>&url=https%3A%2F%2Ffw.example.com */
(function () {
  var opts = {};
  String(typeof $argument === 'string' ? $argument : '').split('&').forEach(function (p) {
    var i = p.indexOf('='); if (i > -1) opts[p.slice(0, i)] = decodeURIComponent(p.slice(i + 1));
  });
  var base = (opts.url || 'https://fw.example.com').replace(/\/$/, '');
  var token = opts.token || '';
  if (!token) return $done({title:'PO0 动态白名单',content:'请配置 token',icon:'xmark.shield'});
  $httpClient.post({url:base+'/add',headers:{'Authorization':'Bearer '+token,'Content-Type':'application/json'},body:'',timeout:15},function(err,resp,body){
    if (err) return $done({title:'PO0 动态白名单',content:'请求失败：'+String(err),icon:'xmark.shield'});
    try {
      var d=JSON.parse(body);
      var applied=d.enabled===true && (d.whitelist||[]).some(function(e){return (typeof e==='string'?e:e.ip)===d.currentIp;});
      var txt='IP: '+(d.currentIp||'?')+'\n槽位: '+(d.whitelist||[]).length+'/'+d.limit+'\n操作: '+(d.action||'-')+(d.evicted?'\n淘汰: '+d.evicted:'');
      $done({title:applied?'✅ PO0 加白成功':'❌ PO0 加白失败',content:applied?txt:((d.error||'未生效')+'\n'+txt),icon:applied?'checkmark.shield':'xmark.shield'});
    } catch(e) { $done({title:'PO0 动态白名单',content:'无效响应 '+String(resp&&resp.status||'')+' '+String(body).slice(0,150),icon:'xmark.shield'}); }
  });
})();
