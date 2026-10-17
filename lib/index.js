/**
 * dsh-power · 宿主半侧 / host half
 *
 * 一个只管电源的插件：重启 / 关闭 DSH。桌面端和 web 端都靠**同一套**实现——
 * 页面上的**一个**电源卡片（浏览器侧挂件：插图的左半 = 关机、右半 = 重启，
 * 点一次只问一句、再点同一半才执行）和模型工具 / 命令走的是同一条链路。
 *
 * 为什么单独成插件：卡片（审批 / 提问 / 完成）那一半已经是 dsh-desk-card 了；
 * 电源这一半当初和它挤在一个文件里，结果是"改卡片顺手动到重启"。
 *
 * 设计要点（每一条都对应一次真实的崩溃）：
 *
 *  1) 重启不是"杀宿主进程再拉一个"。桌面端还有一个 Electron 外壳在监护宿主子进程，
 *     宿主一死外壳就自己把它拉起来。只杀宿主的重启脚本会和外壳抢同一个 web 端口，
 *     抢输的那一方带着 EADDRINUSE 死掉 —— 用户看到的就是"每次重启都崩"。
 *     所以重启脚本杀的是**所有**同名进程（外壳 + 宿主 + 渲染器），一个都不留。
 *
 *  2) 拉起动作必须逃出宿主所在的 Job Object：helper 是被宿主 spawn 的，宿主被强杀时
 *     整个 job 一起关，helper 再启动的任何东西都会被系统杀掉。脚本用
 *     WMI(Win32_Process.Create) → explorer.exe → 计划任务 三级降级来跳出 job。
 *
 *  3) "起来了"的判据是**新实例**真的在应答，不是"有个同名的进程存在"：核心 /health
 *     藏在 web token 后面（未认证 GET 得到 401，健康的实例看起来是死的），所以脚本问的
 *     是插件自己的状态路由，并且要求应答里的 host pid 是杀掉之后才出现的年轻进程——
 *     否则"另一个老实例在同一端口上应答"会被当成重启成功。
 *
 *  4) 注入挂件走 webserver 的**结构化注入表**（webserver/index-inject 事件），
 *     而不是 tapIndex 字符串替换：桌面壳的 index.html 从 dist 静态出，只有前者生效。
 *     而且注入的是一段**内联** script，由页面自己去建 <script src>，因为 script-src 行
 *     一旦加载失败会 reject 掉整个 boot（应用起不来）。
 *
 *  5) 脚本只有一份（scripts/restart-dsh.ps1）。以前有三份实现，它们会各自漂移，
 *     于是每次修完看起来都"没收敛"。
 *
 * @module dsh-power
 */

import { spawn } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const name = 'dsh-power';

/**
 * 声明本插件要用到的服务，cordis 会等它们就绪后再调用 apply。
 * webServer 给路由与注入行，tools / commands 给模型工具与 /power 命令，settings 用来判断界面语言。
 * 不声明的话 apply 可能在这些服务还没挂上时就被调用。
 */
export const inject = ['webServer', 'tools', 'commands', 'settings'];

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = join(HERE, '..', 'scripts', 'restart-dsh.ps1');
const WIDGET_FILE = join(HERE, '..', 'client', 'widget.js');
const WIDGET_URL = '/dsh-power/widget.js';
const LOG = join(tmpdir(), 'dsh-power.log');
const RESTART_LOG = join(tmpdir(), 'dsh-power-restart.log');
const DSH_HOME = process.env.DSH_HOME ?? join(homedir(), '.dsh');
const STATUS_DIR = join(DSH_HOME, 'power-restart');
const STATUS_FILE = join(STATUS_DIR, 'last.json');

function dbg(message) {
  try {
    appendFileSync(LOG, `${new Date().toISOString()} ${message}\n`, 'utf8');
  } catch {
    /* 日志写不进去不影响功能 */
  }
}

// ---------------------------------------------------------------- 配置

function settings(patch) {
  const config = patch ?? {};
  return {
    // 0 = 从 webServer 服务或 --port 参数发现；只有发现失败才需要显式指定。
    port: Number.isFinite(config.port) && config.port > 0 ? config.port : 0,
    // 进程名：脚本用它认出"哪些进程属于 DSH"，再从中只挑**本实例的进程树**
    // （我们的 Electron 外壳 + 其同名后代）来停，不会误杀另开的 DSH 实例。
    processName:
      typeof config.processName === 'string' && config.processName.length > 0
        ? config.processName
        : 'DeepSeek Harness',
    // '' = 用 process.execPath（就是当前这个可执行文件）。
    exePath: typeof config.exePath === 'string' ? config.exePath : '',
    showRestart: config.showRestart !== false,
    showShutdown: config.showShutdown !== false,
    // 两次点击确认（关机 + 重启都吃这个开关）。confirmShutdown 是历史名，仍兼容。
    confirmPower: config.confirmPower !== false && config.confirmShutdown !== false,
    // 待确认窗口的毫秒数（默认 3000）。
    confirmMs: Number.isFinite(config.confirmMs) && config.confirmMs >= 1000 ? config.confirmMs : 3000,
    logToTemp: config.logToTemp !== false,
    // 重启完成后把新窗口顶到最前面（用户靠"看见它弹出来"判断重启好了）。
    // 关掉它 = 传 -NoForeground 给脚本，新实例安静地在后台起来。
    foreground: config.foreground !== false,
  };
}

/** 端口发现：webServer 服务 → argv 的 --port → 0（交给脚本跳过端口检查）。 */
function resolvePort(ctx, configured) {
  if (configured > 0) return configured;
  try {
    const address = ctx?.webServer?.server?.address?.();
    if (address !== null && typeof address === 'object' && Number.isFinite(address.port) && address.port > 0) {
      return address.port;
    }
  } catch {
    /* 拿不到就继续往下试 */
  }
  try {
    const port = ctx?.webServer?.port;
    if (Number.isFinite(port) && port > 0) return port;
  } catch {
    /* ignore */
  }
  try {
    const argv = process.argv;
    for (let index = 0; index < argv.length; index += 1) {
      const token = argv[index];
      if (token === '--port' || token === '-p') {
        const value = Number(argv[index + 1]);
        if (Number.isFinite(value) && value > 0) return value;
      } else if (typeof token === 'string' && token.startsWith('--port=')) {
        const value = Number(token.slice('--port='.length));
        if (Number.isFinite(value) && value > 0) return value;
      }
    }
  } catch {
    /* ignore */
  }
  return 0;
}

// ---------------------------------------------------------------- 电源动作

/**
 * 唯一的电源入口。restart 和 shutdown 都交给同一个脚本：
 * 同一个 mutex、同一套"按 pid 精确停进程"、同一份日志，所以两者不会漂移。
 *
 * `start` 给 helper 一个独立进程组，这样它能活过它所杀掉的那个宿主。
 */
function runPowerScript(action, reason, active, port, extra = {}) {
  const exe = active.exePath.length > 0 ? active.exePath : process.execPath;
  const safeReason = String(reason ?? '').replace(/['"\r\n]/gu, ' ').slice(0, 120);

  if (!existsSync(SCRIPT)) {
    const message = `authoritative script missing: ${SCRIPT}`;
    dbg(`${action}: ${message}`);
    return { ok: false, error: message };
  }

  const args = [
    '/c', 'start', '', '/min',
    'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-WindowStyle', 'Hidden',
    '-File', SCRIPT,
    '-ProcessName', active.processName,
    '-ExePath', exe,
    '-LogPath', RESTART_LOG,
    '-Reason', safeReason,
    '-Port', String(port),
    '-StatusPath', STATUS_FILE,
    // 本实例的宿主 pid：脚本从它爬到本实例的 Electron 外壳，只停这棵同名树。
    // 没有它就退化成"停所有同名进程"（旧行为），多开时会误杀另一个实例。
    '-HostPid', String(process.pid),
  ];
  if (action === 'shutdown') args.push('-ShutdownOnly');
  if (extra.dryRun === true) args.push('-DryRun');
  // 默认让脚本在新实例起来后把它的窗口顶到最前面；foreground=false 时关掉。
  if (active.foreground === false) args.push('-NoForeground');

  try {
    const child = spawn('cmd.exe', args, { stdio: 'ignore', windowsHide: true });
    child.unref();
    dbg(`${action}: script launched (${safeReason}) port=${port} pid=${child.pid ?? '?'} -> ${SCRIPT}`);
    return { ok: true, action, reason: safeReason, port, helperPid: child.pid ?? null, script: SCRIPT };
  } catch (error) {
    const message = error?.stack ?? String(error);
    dbg(`${action} failed: ${message}`);
    return { ok: false, error: message };
  }
}

/** 最近一次电源动作的记录，由脚本写在 <DSH_HOME>/power-restart/last.json。 */
function lastStatus() {
  try {
    if (!existsSync(STATUS_FILE)) return { found: false, path: STATUS_FILE };
    let raw = readFileSync(STATUS_FILE, 'utf8');
    // The helper writes this with PowerShell 5.1 `Set-Content -Encoding UTF8`, which
    // prefixes a BOM - and JSON.parse chokes on it ("Unexpected token '﻿'"). Strip it.
    if (raw.charCodeAt(0) === 0xfeff) raw = raw.slice(1);
    const parsed = JSON.parse(raw);
    return { found: true, path: STATUS_FILE, record: parsed };
  } catch (error) {
    return { found: false, path: STATUS_FILE, error: error?.message ?? String(error) };
  }
}

// ---------------------------------------------------------------- 挂件注入

function widgetSource(active) {
  try {
    let source = readFileSync(WIDGET_FILE, 'utf8');
    // 两个动作的显隐、以及"要不要点两次确认 / 确认窗口多长"交给宿主配置，挂件本身
    // 不需要知道 profile 长什么样。两个动作都关掉时挂件不画卡片（见 widget.js 的 boot()）。
    // __dshPowerConfirmShutdown 保留为 __dshPowerConfirmPower 的别名（旧挂件读它）。
    const boot = `window.__dshPowerShowRestart=${active.showRestart === true};` +
      `window.__dshPowerShowShutdown=${active.showShutdown === true};` +
      `window.__dshPowerConfirmPower=${active.confirmPower === true};` +
      `window.__dshPowerConfirmShutdown=${active.confirmPower === true};` +
      `window.__dshPowerConfirmMs=${active.confirmMs};`;
    return boot + source;
  } catch (error) {
    dbg(`widget read failed: ${error?.message ?? error}`);
    return '/* dsh-power widget missing */';
  }
}

/**
 * 桌面壳的 index.html 从安装包静态 dist 出，只有 webserver/index-inject 的结构化行
 * 能生效；而且必须用**内联 script 行**由页面自己建 <script src>，因为 script-src 行
 * 一旦加载失败会 reject 掉整个 boot（应用起不来）。
 */
function indexInjectText() {
  return (
    '(function(){try{var d=document.body||document.head||document.documentElement;if(!d)return;' +
    `var s=document.createElement("script");s.src="${WIDGET_URL}";s.onerror=function(){};d.appendChild(s)}catch(e){}})()`
  );
}

function registerIndexInjection(root) {
  try {
    root.on('webserver/index-inject', (table) => {
      try {
        if (!Array.isArray(table)) return;
        for (const row of table) {
          if (row?.kind === 'script' && typeof row.text === 'string' && row.text.includes(WIDGET_URL)) return;
          if (row?.kind === 'script-src' && row.src === WIDGET_URL) return;
        }
        table.push({ kind: 'script', placement: 'body', text: indexInjectText() });
        dbg('index injection row registered (desktop shell)');
      } catch (error) {
        dbg(`index injection failed: ${error?.message ?? error}`);
      }
    });
  } catch (error) {
    dbg(`index injection subscribe failed: ${error?.message ?? error}`);
  }
}

// ---------------------------------------------------------------- HTTP

function sendJson(res, status, body) {
  try {
    res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
    res.end(JSON.stringify(body));
  } catch {
    /* 客户端断了也无所谓 */
  }
}

function isLoopback(req) {
  try {
    const host = String(req?.headers?.host ?? '').toLowerCase();
    const hostname = host.replace(/:\d+$/u, '').replace(/^\[|\]$/gu, '');
    return hostname === '127.0.0.1' || hostname === 'localhost' || hostname === '::1';
  } catch {
    return false;
  }
}

/**
 * CSRF 门。isLoopback 只证明"请求是发给本机的"，不证明"请求来自我们的页面"：
 * 浏览器里任何网页都能对 http://127.0.0.1:<port> 发一个"简单请求"（不带自定义头、
 * body 是纯文本），照样送达 —— 那意味着一个广告页就能把你的 DSH 关掉。
 * 解法：要求一个自定义头。跨源带自定义头必然先 preflight，我们不应答 OPTIONS，
 * 预检失败浏览器就拦下真实请求；同源挂件加这一个头是零成本的。
 */
function hasWidgetProof(req) {
  try {
    return String(req?.headers?.['x-dsh-power'] ?? '') === '1';
  } catch {
    return false;
  }
}

function readJsonBody(req) {
  return new Promise((resolve) => {
    let raw = '';
    try {
      req.on('data', (chunk) => {
        raw += chunk;
        if (raw.length > 4096) {
          raw = '';
          req.destroy();
        }
      });
      req.on('end', () => {
        try {
          const parsed = JSON.parse(raw.length > 0 ? raw : '{}');
          resolve(parsed !== null && typeof parsed === 'object' ? parsed : {});
        } catch {
          resolve({});
        }
      });
      req.on('error', () => resolve({}));
    } catch {
      resolve({});
    }
  });
}

function registerRoutes(ctx, active) {
  try {
    // webServer 已在 inject 里声明，apply 运行时它已经就绪，直接注册即可；
    // 用 ctx.effect 把 disposer 挂到插件生命周期上，卸载时路由一起消失。
    // 正确形状（照 asar 里 dsh-client-hmr / dsh-command-* 的官方用法）：
    //   { kind: 'exact', path, handler(req, res) }  —— handler 是 Node 风格。
    // 用 { path, methods: { GET: fn } }（notifier 那层的形状）webServer 不认，
    // 所有请求一律 400，挂件脚本永远加载不到 → 看不到按钮。
    const register = (path, handler) => {
      ctx.effect(() => ctx.webServer.register({ kind: 'exact', path, handler }), `dsh-power route ${path}`);
      dbg(`route registered: ${path}`);
    };

    const action = (path, actionName) =>
      register(path, async (req, res) => {
        if (req.method !== 'POST') {
          res.writeHead(405);
          res.end();
          return;
        }
        if (!isLoopback(req)) {
          sendJson(res, 403, { ok: false, error: 'loopback only' });
          return;
        }
        // CSRF check: 必须带 x-dsh-power=1，否则浏览器会拦（pre-flight）或者我们直接拒。
        if (!hasWidgetProof(req)) {
          sendJson(res, 403, { ok: false, error: 'missing proof header' });
          return;
        }
        const body = await readJsonBody(req);
        if (typeof body.event === 'string') dbg(`client event: ${body.event}`);
        // 页面加载回执只记一行日志：它每次打开页面都会发，绝不能因此动到任何进程。
        if (typeof body.event === 'string' && body.dryRun === true) {
          sendJson(res, 200, { ok: true, dryRun: true, action: actionName });
          return;
        }
        const port = resolvePort(ctx, active.port);
        const dryRun = body.dryRun === true;
        // dryRun 一路传到脚本，而不是在这里就 return。
        // 早期版本在 JS 里直接短路，于是"干跑"从来没走过真正的 spawn 路径 ——
        // 而真正需要干跑验证的恰恰是那条路径（能不能枚举到宿主进程）。
        // 脚本收到 -DryRun 后只枚举、只探测端口与就绪，不停止也不启动任何东西。
        if (dryRun) dbg(`${actionName}: dry-run forwarded to the script (port=${port})`);
        else dbg(`${actionName}: requested from the widget (port=${port})`);
        const result = runPowerScript(
          actionName,
          dryRun ? 'dry run' : 'widget button',
          active,
          port,
          { dryRun },
        );
        sendJson(res, result.ok ? 200 : 500, { ...result, port });
      });

    action('/api/dsh-power/restart', 'restart');
    action('/api/dsh-power/shutdown', 'shutdown');

    register('/api/dsh-power/status', (req, res) => {
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        res.writeHead(405);
        res.end();
        return;
      }
      sendJson(res, 200, {
        ok: true,
        plugin: name,
        pid: process.pid,
        execPath: process.execPath,
        port: resolvePort(ctx, active.port),
        script: SCRIPT,
        scriptPresent: existsSync(SCRIPT),
        last: lastStatus(),
      });
    });

    register(WIDGET_URL, (req, res) => {
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        res.writeHead(405);
        res.end();
        return;
      }
      try {
        const source = widgetSource(active);
        res.writeHead(200, {
          'content-type': 'application/javascript; charset=utf-8',
          'cache-control': 'no-store',
        });
        if (req.method === 'HEAD') res.end();
        else res.end(source);
      } catch (error) {
        dbg(`widget serve failed: ${error?.message ?? error}`);
        res.writeHead(500);
        res.end();
      }
    });

    // web 形态：直接改写宿主送出的 index.html
    try {
      ctx.effect(() =>
        ctx.webServer.tapIndex((html) => {
          if (typeof html !== 'string' || html.includes(WIDGET_URL)) return html;
          const tag = `<script defer src="${WIDGET_URL}"></script>`;
          return html.includes('</body>') ? html.replace('</body>', `${tag}</body>`) : html + tag;
        }),
      );
    } catch (error) {
      dbg(`tapIndex unavailable: ${error?.message ?? error}`);
    }
    dbg('routes registered (/api/dsh-power/*, /dsh-power/widget.js)');
  } catch (error) {
    dbg(`routes failed: ${error?.stack ?? error}`);
  }
}

// ---------------------------------------------------------------- 模型工具 / 命令

function isEnglishLocale(ctx) {
  try {
    const locale = ctx.settings?.get?.('locale');
    return (typeof locale?.preference === 'string' ? locale.preference.toLowerCase() : '').startsWith('en');
  } catch {
    return false;
  }
}

function registerModelTools(ctx, active) {
  const en = isEnglishLocale(ctx);
  const textOutput = (value) => [{ type: 'text', text: JSON.stringify(value, null, 2) }];

  try {
    ctx.tools.register({
      name: 'power_restart',
      description: en
        ? 'Restart the whole DeepSeek Harness app (Electron shell included) so plugin and config changes take effect. Stops only THIS instance\'s process tree (the same-named Electron shell and its children), so other running instances are left alone; waits for the web port to free, relaunches outside the host Job Object, confirms the new instance really answers on the plugin\'s own status route, watches it stay up, and pushes its window to the foreground. Says why when the app does not come back (a live instance holding the single-instance lock, a launch that never started, or a boot that never served). The session connection drops and the page reconnects automatically. Returns the helper pid and the port.'
        : '重启整个 DeepSeek Harness（连同 Electron 外壳），用于让插件与配置改动生效。只停当前实例的进程树（同名的 Electron 外壳及其子进程），不碰其他正在运行的实例；等 web 端口释放后，在宿主 Job Object 之外重新拉起，以插件自己的状态路由确认真实应答，盯住它别中途倒下，再顶到最前面。没起来时会说明具体原因（单实例锁被别的实例占着、拉起根本没发生、起来了却没在服务）。会话连接会短暂中断，页面自动重连。返回 helper pid 与端口。',
      parameters: {
        type: 'object',
        properties: {
          reason: { type: 'string', description: en ? 'Why the restart is happening; written to the log.' : '重启原因，会写进日志。' },
        },
      },
      output: { schema: {}, render: (_args, value) => textOutput(value) },
      async execute(args) {
        const port = resolvePort(ctx, active.port);
        return runPowerScript('restart', args?.reason ?? 'model tool', active, port);
      },
    });
  } catch (error) {
    if (String(error).includes('already registered')) {
      dbg('power_restart already registered by another plugin; skipping our tool');
    } else {
      dbg(`power_restart registration failed: ${error?.stack ?? error}`);
    }
  }

  try {
    ctx.tools.register({
      name: 'power_shutdown',
      description: en
        ? 'Shut DeepSeek Harness down without restarting: stops this instance\'s process tree (the same-named Electron shell included) and does not relaunch anything. Other running instances are left alone. Returns once the helper has been launched; the app then exits.'
        : '关闭 DeepSeek Harness，不重启：停掉当前实例的进程树（含同名的 Electron 外壳），不拉起任何东西，也不影响其他正在运行的实例。返回时 helper 已启动，随后应用退出。',
      parameters: { type: 'object', properties: {} },
      output: { schema: {}, render: (_args, value) => textOutput(value) },
      async execute() {
        const port = resolvePort(ctx, active.port);
        return runPowerScript('shutdown', 'model tool', active, port);
      },
    });
  } catch (error) {
    if (String(error).includes('already registered')) {
      dbg('power_shutdown already registered by another plugin; skipping our tool');
    } else {
      dbg(`power_shutdown registration failed: ${error?.stack ?? error}`);
    }
  }

  try {
    ctx.tools.register({
      name: 'power_status',
      description: en
        ? 'Report how dsh-power is wired up (this process, the resolved port, the restart script path) and the outcome of the most recent restart/shutdown, as written by the helper script. Read-only; never restarts anything.'
        : '报告 dsh-power 的接线情况（当前进程、解析出的端口、重启脚本路径）以及 helper 脚本写下的最近一次重启/关闭结果。只读，不会触发任何动作。',
      parameters: { type: 'object', properties: {} },
      output: { schema: {}, render: (_args, value) => textOutput(value) },
      async execute() {
        return {
          ok: true,
          plugin: name,
          pid: process.pid,
          execPath: process.execPath,
          processName: active.processName,
          port: resolvePort(ctx, active.port),
          script: SCRIPT,
          scriptPresent: existsSync(SCRIPT),
          restartLog: RESTART_LOG,
          log: LOG,
          last: lastStatus(),
        };
      },
    });
  } catch (error) {
    dbg(`power_status registration failed: ${error?.stack ?? error}`);
  }
}

function registerCommands(ctx, active) {
  try {
    ctx.commands.register({
      name: 'power',
      description: isEnglishLocale(ctx)
        ? 'Power actions: /power restart | shutdown | status'
        : '电源操作：/power restart | shutdown | status',
      recordInput: false,
      async handler(invocation) {
        // Commands receive the text typed after the command name as `rawInput`
        // (see dsh-commands: invocation = { commandId, agent, rawInput, attachments, signal }).
        const raw = String(invocation?.rawInput ?? '').trim().toLowerCase();
        const port = resolvePort(ctx, active.port);
        if (raw.startsWith('shutdown') || raw.startsWith('stop') || raw.startsWith('关')) {
          const result = runPowerScript('shutdown', 'command', active, port);
          return { kind: result.ok ? 'success' : 'error', text: JSON.stringify(result, null, 2) };
        }
        if (raw.startsWith('status') || raw.startsWith('状态')) {
          return {
            kind: 'success',
            text: JSON.stringify(
              { ok: true, pid: process.pid, port, script: SCRIPT, last: lastStatus() },
              null,
              2,
            ),
          };
        }
        const result = runPowerScript('restart', 'command', active, port);
        return { kind: result.ok ? 'success' : 'error', text: JSON.stringify(result, null, 2) };
      },
    });
  } catch (error) {
    if (String(error).includes('already registered')) {
      dbg('command "power" already registered by another plugin; skipping ours');
    } else {
      dbg(`command registration failed: ${error?.stack ?? error}`);
    }
  }
}

// ---------------------------------------------------------------- 插件

export function apply(root, config) {
  const active = settings(config);
  try {
    mkdirSync(STATUS_DIR, { recursive: true });
  } catch {
    /* ignore */
  }

  dbg(`apply() started config=${JSON.stringify(config ?? {})} pid=${process.pid} execPath=${process.execPath}`);

  // ① 注入行必须最先注册：桌面壳在启动时一次性收集这张表。
  registerIndexInjection(root);

  // ② 路由 + 挂件
  registerRoutes(root, active);

  // ③ 模型工具与命令
  registerModelTools(root, active);
  registerCommands(root, active);

  // ④ 生命周期：只是把事实记进日志，方便下次出问题时有据可查。
  try {
    root.effect(() => () => {
      dbg('dispose: dsh-power unloading');
    });
  } catch (error) {
    dbg(`dispose hook failed: ${error?.message ?? error}`);
  }
}
