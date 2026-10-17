// FakeDsh host: serves the same JSON shape as GET /api/dsh-power/status so the real
// restart engine can probe it unchanged. pid reported = this pid (never in the killed
// targets after a successful restart, which is exactly what Test-InstanceUp checks).
var http = require('http');
var args = process.argv.slice(2);
var i = args.indexOf('--state-port');
var port = parseInt(i >= 0 ? args[i + 1] : '19501', 10);
http.createServer(function (req, res) {
  if (req.url === '/api/dsh-power/status') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, plugin: 'fake-power', pid: process.pid, port: port }));
  } else { res.writeHead(404); res.end(); }
}).listen(port, '127.0.0.1');
