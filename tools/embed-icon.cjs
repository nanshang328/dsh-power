// Inline client/niang-sleep.webp into client/widget.js as a data URI.
//
//   python tools/build-icon.py      -> client/niang-sleep.png (source of truth)
//                                      client/niang-sleep.webp (512px, 40KB base64)
//   node   tools/embed-icon.cjs     -> rewrites the ICON_DATA_URI line in widget.js
//
// Why a build step at all: widget.js is served by the plugin's own route and is
// re-read from disk on every page load, so inlining the picture means the button
// face changes without restarting DSH. The placeholder is a token that this
// script replaces; if it is ever left unreplaced the widget treats it as
// "no picture" and falls back to the inline SVG power glyph.
const fs = require('fs');
const path = require('path');

const PLUGIN = path.dirname(__dirname);
const IMAGE = path.join(PLUGIN, 'client', 'niang-sleep.webp');
const WIDGET = path.join(PLUGIN, 'client', 'widget.js');
const TOKEN = '__DSH_POWER_ICON_DATA_URI__';

if (!fs.existsSync(IMAGE)) {
  console.error('missing ' + IMAGE + ' -- run: python tools/build-icon.py');
  process.exit(1);
}

const base64 = fs.readFileSync(IMAGE).toString('base64');
const dataUri = 'data:image/webp;base64,' + base64;

const source = fs.readFileSync(WIDGET, 'utf8');
const line = "var ICON_DATA_URI = '" + TOKEN + "';";

// Replace the token wherever it sits inside that declaration -- the file on disk
// may already hold a previous data URI, which is exactly the normal re-run case.
const pattern = /var ICON_DATA_URI = '[^']*';/;
if (!pattern.test(source) && source.indexOf(TOKEN) === -1) {
  console.error('widget.js has no ICON_DATA_URI line; refusing to guess');
  process.exit(1);
}

const next = source.replace(pattern, "var ICON_DATA_URI = '" + dataUri + "';");
fs.writeFileSync(WIDGET, next, 'utf8');

const check = fs.readFileSync(WIDGET, 'utf8');
console.log('image        : ' + IMAGE + ' (' + fs.statSync(IMAGE).size + ' bytes)');
console.log('data uri     : ' + dataUri.length + ' chars');
console.log('widget.js    : ' + source.length + ' -> ' + check.length + ' chars');
console.log('placeholder  : ' + (check.indexOf(TOKEN) === -1 ? 'gone (good)' : 'STILL PRESENT'));
console.log('declaration  : ' + (check.match(pattern) || ['?'])[0].slice(0, 60) + '...');