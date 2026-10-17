// FakeDsh shell: claims a lock port (Electron requestSingleInstanceLock analogue), spawns
// a host child, respawns the host when it dies (Electron auto-restart analogue).
// A second shell that cannot take the lock quits after ~90ms = STUB, exactly like the real app.
var net = require('net');
var spawn = require('child_process').spawn;
var path = require('path');
var args = process.argv.slice(2);
function flag(name, dflt) {
  var i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
}
var lockPort = parseInt(flag('--lock-port', '19502'), 10);
var statePort = flag('--state-port', '19501');
var respawnMs = parseInt(flag('--respawn-ms', '0'), 10);
var hostScript = path.join(__dirname, 'fake-host.cjs');

function startHost() {
  var child = spawn(process.execPath, [hostScript, '--state-port', statePort], { stdio: 'ignore', windowsHide: true });
  child.on('exit', function () {
    if (respawnMs >= 0) { setTimeout(startHost, respawnMs); }   // shell keeps the host alive, like Electron
  });
}
var probe = net.createServer();
probe.once('error', function () {
  // lock taken by another instance: become the stub the real app becomes
  setTimeout(function () { process.exit(0); }, 90);
});
probe.listen(lockPort, '127.0.0.1', function () {
  startHost();
  setInterval(function () {}, 60000);   // shell idles forever, watching its child
});

