import importlib.util, json, tempfile, pathlib, unittest
from unittest.mock import patch

P=pathlib.Path(__file__).resolve().parents[1]/'server'/'whitelist_api.py'
spec=importlib.util.spec_from_file_location('whitelist_api',P)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class QueueTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
  m.DATA=pathlib.Path(self.temp.name)/'queue.json'
  self.live=set()
  def command(*args):
   if args[:2]==('ipset','list'):
    return 'Name: po0_dynamic_whitelist\nMembers:\n'+'\n'.join(sorted(self.live))+'\n'
   if args[:2]==('ipset','add'):
    self.live.add(args[3]);return ''
   if args[:2]==('ipset','del'):
    self.live.remove(args[3]);return ''
   raise RuntimeError(str(args))
  self.patch=patch.object(m,'command',command);self.patch.start();self.addCleanup(self.patch.stop)
 def apply(self,ip,cap):
  old=m.read_queue();new=list(old)
  if ip in old:return 'exists',None
  new.append(ip); evicted=new.pop(0) if len(new)>cap else None
  try:m.reconcile(new);m.save_queue(new)
  except Exception:m.reconcile(old);raise
  return 'evicted' if evicted else 'added',evicted
 def test_fifo_ten_and_duplicates(self):
  for i in range(1,11):self.apply('8.8.8.'+str(i),10)
  self.assertEqual(len(m.read_queue()),10)
  self.assertEqual(self.apply('8.8.8.2',10),('exists',None))
  self.assertEqual(m.read_queue()[0],'8.8.8.1')
  self.assertEqual(self.apply('9.9.9.9',10),('evicted','8.8.8.1'))
  self.assertEqual(m.read_queue()[-1],'9.9.9.9')
  self.assertEqual(set(m.read_queue()),self.live)
 def test_failed_save_rolls_back_set(self):
  for i in range(1,4):self.apply('8.8.8.'+str(i),3)
  original=m.read_queue()
  with patch.object(m,'save_queue',side_effect=OSError('no disk')):
   with self.assertRaises(OSError):self.apply('9.9.9.9',3)
  self.assertEqual(m.read_queue(),original)
  self.assertEqual(self.live,set(original))
 def test_corrupt_or_duplicate_queue_rejected(self):
  m.DATA.write_text('["1.1.1.1","1.1.1.1"]')
  with self.assertRaises(ValueError):m.read_queue()
 def test_ipv4_validation(self):
  for ip in ['127.0.0.1','10.0.0.1','::1','2001:db8::1','bad']:
   with self.assertRaises(ValueError):m.ipv4(ip,public=True)
  self.assertEqual(m.ipv4('8.8.8.8',public=True),'8.8.8.8')

if __name__=='__main__':unittest.main()

class HttpTests(unittest.TestCase):
 def setUp(self):
  import threading,http.server
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
  m.DATA=pathlib.Path(self.temp.name)/'queue.json';m.DATA.write_text('[]')
  self.live=set()
  def command(*args):
   if args[:2]==('ipset','list'):return 'Members:\n'+'\n'.join(self.live)
   if args[:2]==('ipset','add'):self.live.add(args[3]);return ''
   if args[:2]==('ipset','del'):self.live.remove(args[3]);return ''
   raise RuntimeError(args)
  self.patches=[patch.object(m,'command',command),patch.object(m,'verify_rules',return_value=True),patch.object(m,'forward_ready',return_value=True)]
  for p in self.patches:p.start();self.addCleanup(p.stop)
  self.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),m.Handler)
  self.server.cfg={'trusted_proxy_ip':'127.0.0.1','api_token':'A'*40,'max_slots':2}
  self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
  self.addCleanup(self.server.server_close);self.addCleanup(self.server.shutdown)
 def request(self,method,path,token='A'*40,ip='8.8.8.8'):
  import urllib.request,urllib.error
  headers={'Authorization':'Bearer '+token,'X-Real-IP':ip}
  r=urllib.request.Request('http://127.0.0.1:%s%s'%(self.server.server_port,path),headers=headers,method=method)
  try:
   with urllib.request.urlopen(r,timeout=2) as f:return f.status,json.loads(f.read())
  except urllib.error.HTTPError as e:return e.code,json.loads(e.read())
 def test_http_authorization_and_ipv4(self):
  self.assertEqual(self.request('POST','/add',token='wrong')[0],401)
  self.assertEqual(self.request('POST','/add',ip='::1')[0],400)
  self.assertEqual(self.request('POST','/add',ip='192.168.0.1')[0],400)
  self.assertEqual(self.request('GET','/nothing')[0],404)
  self.assertEqual(self.request('DELETE','/add')[0],405)
 def test_http_fifo_and_status(self):
  self.assertEqual(self.request('POST','/add',ip='8.8.8.8')[1]['action'],'added')
  self.assertEqual(self.request('POST','/add',ip='8.8.4.4')[1]['action'],'added')
  self.assertEqual(self.request('POST','/add',ip='8.8.8.8')[1]['action'],'exists')
  resp=self.request('POST','/add',ip='9.9.9.9')[1]
  self.assertEqual(resp['action'],'evicted')
  self.assertEqual(resp['evicted'],'8.8.8.8')
  self.assertTrue(resp['enabled'])
  self.assertTrue(resp['firewall']['forward'])
  self.assertEqual([x['ip'] for x in self.request('GET','/status')[1]['whitelist']],['8.8.4.4','9.9.9.9'])
