// 主机环境监控面板 · v2 服务
// 三层架构：L1 主机硬件 → L2 网络/VPS 隧道 → L3 量化应用（依赖前两层）
// L1 的 CPU/内存/磁盘由 Node 进程内实时计算；GPU/NPU + 出口延迟由 collect_extra.ps1
// （计划任务，复用 ProxyKeepalive 同款 SYSTEM 模式）写入 state/extra_metrics.json。
// 属 Echo 职责域（主机/网络/环境把关），不触碰 aquantCC 项目代码。

const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');
const os = require('os');
const net = require('net');
const { execFileSync } = require('child_process');

const PORT = 7890;
const ROOT = __dirname;
const PUBLIC = path.join(ROOT, 'public');
const STATE = path.join(ROOT, 'state');

// ---------- 本地配置（出于隐私，真实值不硬编码在公开仓库）----------
// 通过 config.local.json（已 gitignore，见 .gitignore）或环境变量提供：
//   baseDir   : 本地 WorkBuddy 根目录（host_health / proxy_keepalive 心跳文件所在父目录）
//   tokyoExit: 期望出口节点 "ip:port"（代理隧道终点）
//   tokyoGeo : 出口归属地说明（用于合规卡片展示）
// 未配置时退化为占位符，面板其余功能仍可用，仅对应探测/展示退化为占位。
const LOCAL_CFG = (() => {
  try { return JSON.parse(fs.readFileSync(path.join(__dirname, 'config.local.json'), 'utf8')); }
  catch (e) { return {}; }
})();
const LOCAL_BASE = process.env.LOCAL_BASE || LOCAL_CFG.baseDir || '';
const TOKYO_EXIT = process.env.TOKYO_EXIT || LOCAL_CFG.tokyoExit || '0.0.0.0:0';
const TOKYO_GEO  = process.env.TOKYO_GEO  || LOCAL_CFG.tokyoGeo  || '（在 config.local.json 配置出口归属）';

const HOST_HB  = LOCAL_BASE ? path.join(LOCAL_BASE, '2026-07-22-02-01-09/host_health_heartbeat.json') : null;
const PROXY_HB = LOCAL_BASE ? path.join(LOCAL_BASE, 'proxy_keepalive/proxy_keepalive_heartbeat.json') : null;
const EXTRA = path.join(STATE, 'extra_metrics.json');
const TS_FILE = path.join(STATE, 'timeseries.json');
const EVENTS_FILE = path.join(STATE, 'events.log');

const MAX_POINTS = 720;     // ~3h @ 15s
const SAMPLE_MS = 15000;
const DASH_PORT = 5000, DASH_PATH = '/runtime-scheduler';
const PROXY_PORT = 10808, PG_PORT = 5434;

// ---------- 崩溃防护：绝不静默退出 ----------
// 记录所有未捕获异常/拒绝到 state/server.log，便于事后溯源；进程本身不退出。
const CRASH_LOG = path.join(STATE, 'server.log');
function crashLog(msg){
  try { fs.appendFileSync(CRASH_LOG, `${new Date().toISOString()} ${msg}\n`); } catch (e) {}
}
process.on('uncaughtException', e => crashLog('uncaughtException: ' + (e && e.stack || e)));
process.on('unhandledRejection', e => crashLog('unhandledRejection: ' + (e && e.stack || e)));

// ---------- 守护进程健康信息（暴露给前端右下角徽标）----------
const PROC_PID = process.pid;
const BOOT_TS = Date.now();
// 从 server.log 取最近一条 listening 记录的时间戳，作为"上次重启时间"；
// 该时间戳由本进程 listen 成功时写入，通常与本进程启动时刻一致。
function readLastBootFromLog(){
  try {
    const lines = fs.readFileSync(CRASH_LOG, 'utf8').trim().split('\n').filter(Boolean);
    for (let i = lines.length - 1; i >= 0; i--){
      const m = lines[i].match(/^(\S+)\s+listening pid=(\d+)$/);
      if (m) return { ts: new Date(m[1]).getTime(), pid: parseInt(m[2], 10) };
    }
  } catch (e) {}
  return { ts: BOOT_TS, pid: PROC_PID };
}
function procInfo(){
  const log = readLastBootFromLog();
  const boot = Math.max(BOOT_TS, log.ts || BOOT_TS);   // 取较晚者，避免时钟抖动导致负数
  return { pid: PROC_PID, bootTs: new Date(boot).toISOString(), uptimeMs: Date.now() - boot };
}

function ensureDir(d){ try { fs.mkdirSync(d, { recursive: true }); } catch (e) {} }
ensureDir(STATE);

function readJsonSafe(p){
  try { return JSON.parse(fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, '')); }
  catch (e) { return null; }
}

// ---------- L1 主机硬件：进程内实时 ----------
let _cpu = null;
function cpuPct(){
  const c = os.cpus(); let idle = 0, total = 0;
  for (const x of c){ for (const k in x.times) total += x.times[k]; idle += x.times.idle; }
  const snap = { idle, total };
  let pct = null;
  if (_cpu){ const di = snap.idle - _cpu.idle, dt = snap.total - _cpu.total; pct = dt > 0 ? (1 - di/dt)*100 : 0; }
  _cpu = snap; return pct;
}
function tcpUp(port){
  return new Promise(res => {
    const s = net.connect({ host: '127.0.0.1', port, timeout: 3000 });
    let done = false;
    const fin = v => { if (done) return; done = true; try { s.destroy(); } catch (e) {} res(v); };
    s.on('connect', () => fin(true));
    s.on('timeout', () => fin(false));
    s.on('error', () => fin(false));
  });
}
function httpCheck(port, p){
  return new Promise(res => {
    const req = http.get({ host: '127.0.0.1', port, path: p, timeout: 5000 }, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => { try { r.resume(); } catch (e) {} res(r.statusCode === 200); });
    });
    req.on('timeout', () => { try { req.destroy(); } catch (e) {} res(false); });
    req.on('error', () => res(false));
  });
}

// ---------- 组装三层状态 + 依赖树健康推导 ----------
// ---------- Claude 合规探针：经 10808 隧道的 DNS 解析器归属（120s 缓存）----------
// 关键纠正：直连根本连不上 Claude（被墙），所以"系统直连 DNS 用中国解析器"与封号无关；
// 真正能摸到 Claude 的只有经 10808 代理隧道的流量，而隧道做远程 DNS 解析（--socks5-hostname
// 让 curl 把域名交给 SOCKS 代理远程解析），不经过本机中国解析器。
// 因此本探针模拟 Claude 流量的真实 DNS 路径：经 10808 隧道查询 edns.ip-api.com，看远端
// 看到的解析器归属。若仍是中国解析器，说明代理流量也在暴露真实位置 → 真·泄漏。
let dnsProbe = { ip: null, geo: null, cnLeak: null, viaProxy: true, ts: null, err: null };
let dnsProbeAt = 0;
async function probeDns(){
  if (Date.now() - dnsProbeAt < 120000) return dnsProbe;
  dnsProbeAt = Date.now();
  try {
    const out = execFileSync('curl', [
      '-sL', '--max-time', '10',
      '--socks5-hostname', '127.0.0.1:' + PROXY_PORT,
      'http://edns.ip-api.com/json'
    ], { timeout: 15000, encoding: 'utf8', windowsHide: true });
    const j = JSON.parse(out);
    const d = (j && j.dns) || {};
    dnsProbe = {
      ip: d.ip || null,
      geo: d.geo || null,
      cnLeak: /china/i.test(String(d.geo || '')),
      viaProxy: true,
      ts: new Date().toISOString(),
      err: null
    };
  } catch (e) {
    dnsProbe = { ip: null, geo: null, cnLeak: null, viaProxy: true, ts: new Date().toISOString(), err: (e && e.message) || 'probe failed' };
  }
  return dnsProbe;
}

async function currentState(){
  const cpu = cpuPct();
  const ex = readJsonSafe(EXTRA);   // 由 collect_extra.ps1（计划任务 EnvMetrics）写入

  // 内存/磁盘：以 Windows 语义为准（"可用"含可回收缓存），需性能计数器，
  // 由 collect_extra.ps1 提供；缺失时不编造数字，标记"采集未运行"。
  const mem = ex ? {
    total: ex.memTotal, avail: ex.memAvail,
    used: (ex.memTotal != null && ex.memAvail != null) ? +(ex.memTotal - ex.memAvail).toFixed(1) : null,
    pct: ex.memPct, standby: ex.memStandby, cached: ex.memCached
  } : { total: null, avail: null, used: null, pct: null, standby: null, cached: null };
  // ex.disk may arrive as a bare object when PowerShell 5.1's ConvertTo-Json
  // collapses a single-element array (one fixed disk) into {}. Coerce safely.
  const diskRaw = ex ? ex.disk : null;
  const disk = Array.isArray(diskRaw) ? diskRaw
              : (diskRaw && typeof diskRaw === 'object') ? [diskRaw]
              : [];

  const gpu = ex ? { name: ex.gpuName, pct: ex.gpuPct, avail: ex.gpuAvail }
                 : { name: null, pct: null, avail: false };
  const npu = ex ? { name: ex.npuName, pct: ex.npuPct, avail: ex.npuAvail }
                 : { name: 'Ryzen AI NPU (XDNA)', pct: null, avail: false };

  const ph = readJsonSafe(PROXY_HB);
  const proxyListen = await tcpUp(PROXY_PORT);
  const egressOk = ph ? (ph.egress === 'OK') : false;
  const proxyTs = ph ? ph.ts : null;

  // same single-element-array collapse guard for latency
  const latRaw = ex ? ex.latency : null;
  const latency = Array.isArray(latRaw) ? latRaw
                : (latRaw && typeof latRaw === 'object') ? [latRaw]
                : [];
  const exit = ex ? { ip: ex.exitIp, port: ex.exitPort, geo: ex.exitGeo }
                 : { ip: TOKYO_EXIT.split(':')[0], port: '8443', geo: 'TOKYO_GEO' };

  const pgListen   = await tcpUp(PG_PORT);
  const dashListen = await tcpUp(DASH_PORT);
  const dashHttp   = await httpCheck(DASH_PORT, DASH_PATH);

  // ---- 依赖树推导（核心逻辑）----
  // L3 量化应用 依赖 L2 网络；L2 网络 依赖 L1 主机（代理进程跑在主机上）。
  const hostDegraded = (mem.pct != null && mem.pct > 95) || disk.some(d => d.pct != null && d.pct > 95);
  const netDown = !proxyListen || !egressOk;          // 出口断 → 一切失效
  const appDown = !dashHttp || !pgListen;             // 应用层不可达
  let overall, overallMsg;
  if (netDown)       { overall = 'critical'; overallMsg = '网络出口中断 → LLM / 数据(Tushare) / GitHub push 全部失效'; }
  else if (appDown)  { overall = 'incident'; overallMsg = '量化应用异常（调度中心或数据库不可达）'; }
  else if (hostDegraded){ overall = 'degraded'; overallMsg = '主机资源紧张（内存/磁盘接近上限）'; }
  else                { overall = 'healthy';  overallMsg = '三层全部正常'; }
  // 应用"有效健康"= HTTP 可达 且 出口通（出口断时页面虽能开，但自进化/数据刷新静默失败）
  const appEffective = dashHttp && pgListen && egressOk;

  // ---- Claude 合规块（封号规避条件监测）----
  const exitOk = !!(exit.ip && exit.ip === TOKYO_EXIT.split(':')[0]);
  const antEntry = (latency || []).find(x => String(x.name || '').toLowerCase() === 'anthropic');
  const claude = {
    exitOk,
    expectedIp: TOKYO_EXIT.split(':')[0],
    egressOk, proxyListen, exit,
    anthropic: { ok: antEntry ? !!antEntry.ok : null, ms: (antEntry && antEntry.ms != null) ? antEntry.ms : null },
    dns: await probeDns(),
    machineTz: Intl.DateTimeFormat().resolvedOptions().timeZone
  };

  return normalizeState({
    ts: new Date().toISOString(),
    layers: {
      host: {
        cpu: cpu == null ? 0 : +cpu.toFixed(1),
        mem, disk, gpu, npu, bluetooth: null, degraded: hostDegraded
      },
      network: { proxyListen, egressOk, exit, latency, proxyTs },
      app: {
        scheduler: { listen: dashListen, httpOk: dashHttp, title: '总调度中心 · Aquant', url: 'http://127.0.0.1:5000/runtime-scheduler' },
        pg: { listen: pgListen },
        effective: appEffective
      },
      claude
    },
    overall, overallMsg
  });
}

function normalizeState(s){
  const safe = (obj, defaults) => ({ ...(defaults || {}), ...(obj || {}) });
  const host = safe(s && s.layers && s.layers.host, { cpu: 0, mem: { total:null, avail:null, used:null, pct:null, standby:null, cached:null }, disk: [], gpu: { name:null, pct:null, avail:false }, npu: { name:null, pct:null, avail:false }, degraded: false });
  host.mem = safe(host.mem, { total:null, avail:null, used:null, pct:null, standby:null, cached:null });
  host.disk = Array.isArray(host.disk) ? host.disk : (host.disk ? [host.disk] : []);
  host.gpu = safe(host.gpu, { name:null, pct:null, avail:false });
  host.npu = safe(host.npu, { name:null, pct:null, avail:false });
  host.bluetooth = (s && s.layers && s.layers.host && s.layers.host.bluetooth) || null;
  const network = safe(s && s.layers && s.layers.network, { proxyListen:false, egressOk:false, exit:{ ip:TOKYO_EXIT.split(':')[0], port:'8443', geo:'TOKYO_GEO' }, latency:[], proxyTs:null });
  network.latency = Array.isArray(network.latency) ? network.latency : (network.latency ? [network.latency] : []);
  network.exit = safe(network.exit, { ip:TOKYO_EXIT.split(':')[0], port:'8443', geo:'TOKYO_GEO' });
  const app = safe(s && s.layers && s.layers.app, { scheduler:{ listen:false, httpOk:false, title:'总调度中心 · Aquant', url:'http://127.0.0.1:5000/runtime-scheduler' }, pg:{ listen:false }, effective:false });
  app.scheduler = safe(app.scheduler, { listen:false, httpOk:false, title:'总调度中心 · Aquant', url:'http://127.0.0.1:5000/runtime-scheduler' });
  app.pg = safe(app.pg, { listen:false });
  let claude = safe(s && s.layers && s.layers.claude, { exitOk:false, egressOk:false, proxyListen:false, exit:{ ip:null, geo:null }, anthropic:{ ok:null, ms:null }, dns:{ ip:null, geo:null, cnLeak:null, ts:null, err:null }, machineTz:null });
  claude.exit = safe(claude.exit, { ip:null, geo:null });
  claude.anthropic = safe(claude.anthropic, { ok:null, ms:null });
  claude.dns = safe(claude.dns, { ip:null, geo:null, cnLeak:null, viaProxy:true, ts:null, err:null });
  return {
    ts: (s && s.ts) || new Date().toISOString(),
    layers: { host, network, app, claude },
    overall: (s && s.overall) || 'critical',
    overallMsg: (s && s.overallMsg) || 'state structure incomplete (normalized)'
  };
}

// ---------- 时序累积 + 事件检测 ----------
let ts = [];
try { ts = JSON.parse(fs.readFileSync(TS_FILE, 'utf8')); if (!Array.isArray(ts)) ts = []; } catch (e) { ts = []; }
let lastSample = ts.length ? ts[ts.length - 1] : null;

function logEvent(msg, level){
  const line = `${new Date().toISOString()} | ${level} | ${msg}\n`;
  try { fs.appendFileSync(EVENTS_FILE, line); } catch (e) {}
}

async function sample(){
 try {
  const s = await currentState();
  const L = s.layers;
  const ex = readJsonSafe(EXTRA);
  const latArr = (L.network.latency || []).filter(x => x.ok && x.ms != null);
  const latAvg = latArr.length ? Math.round(latArr.reduce((a,b)=>a+b.ms,0)/latArr.length) : null;
  // 每端点延迟（用于 sparkline），按名称映射到短键。collect_extra.ps1 里 name 是首字母大写，
  // 这里统一转小写再匹配，避免大小写问题导致整图空白。
  const latByName = {};
  if (ex && Array.isArray(ex.latency)) for (const x of ex.latency) latByName[String(x.name).toLowerCase()] = (x.ok ? x.ms : null);
  const latMap = {
    a: ('anthropic' in latByName) ? latByName['anthropic'] : null,
    c: ('codex'     in latByName) ? latByName['codex']     : null,
    d: ('deepseek'  in latByName) ? latByName['deepseek']  : null,
    k: ('kimi'      in latByName) ? latByName['kimi']      : null,
    t: ('tushare'   in latByName) ? latByName['tushare']   : null,
    g: ('github'    in latByName) ? latByName['github']    : null
  };
  const memPct = (L.host.mem && L.host.mem.pct != null) ? L.host.mem.pct : null;
  const point = {
    t: Date.now(),
    proxy: L.network.proxyListen ? 1 : 0,
    egress: L.network.egressOk ? 1 : 0,
    pg: L.app.pg.listen ? 1 : 0,
    dash: L.app.scheduler.httpOk ? 1 : 0,
    cpu: +L.host.cpu.toFixed(1),
    mem: memPct == null ? null : +memPct.toFixed(1),
    gpu: (L.host.gpu.pct == null ? null : +L.host.gpu.pct),
    latAvg, lat: latMap
  };
  ts.push(point);
  if (ts.length > MAX_POINTS) ts = ts.slice(ts.length - MAX_POINTS);
  try { fs.writeFileSync(TS_FILE, JSON.stringify(ts)); } catch (e) {}

  if (lastSample) {
    if (lastSample.proxy === 1 && point.proxy === 0) logEvent('代理 10808 掉线', 'P0');
    else if (lastSample.proxy === 0 && point.proxy === 1) logEvent('代理 10808 恢复', 'OK');
    if (lastSample.egress === 1 && point.egress === 0) logEvent('代理 egress 出口断开', 'P0');
    else if (lastSample.egress === 0 && point.egress === 1) logEvent('代理 egress 出口恢复', 'OK');
    if (lastSample.pg === 1 && point.pg === 0) logEvent('PostgreSQL 5434 掉线', 'P1');
    else if (lastSample.pg === 0 && point.pg === 1) logEvent('PostgreSQL 5434 恢复', 'OK');
    if (lastSample.dash === 1 && point.dash === 0) logEvent('调度中心 5000 掉线', 'P1');
    else if (lastSample.dash === 0 && point.dash === 1) logEvent('调度中心 5000 恢复', 'OK');
  }
  lastSample = point;
 } catch (e) {
  try { logEvent('sample error: ' + (e && e.message ? e.message : e), 'ERR'); } catch (_) {}
 }
}
sample();
setInterval(sample, SAMPLE_MS);

// ---------- HTTP ----------
const server = http.createServer(async (req, res) => {
  const u = url.parse(req.url);
  // 极简健康探针（秒回，不走 currentState，给前端/监控探活用）
  if (u.pathname === '/api/ping') {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify({ ok: true, v: 3, ts: Date.now() }));
    return;
  }
  if (u.pathname === '/api/state') {
    // 兜底：即使 currentState 卡死或抛错，也要在 12s 内返回一份 JSON，绝不因单次请求
    // 让未处理的 promise rejection 掀翻整个进程。失败时返回 critical + 占位数据。
    const fallback = {
      ts: new Date().toISOString(),
      layers: {
        host: { cpu: 0, mem: { total: null, avail: null, used: null, pct: null, standby: null, cached: null },
          disk: [], gpu: { name: null, pct: null, avail: false }, npu: { name: null, pct: null, avail: false }, degraded: false },
        network: { proxyListen: false, egressOk: false,
          exit: { ip: TOKYO_EXIT.split(':')[0], port: '8443', geo: 'TOKYO_GEO' },
          latency: [], proxyTs: null },
        app: { scheduler: { listen: false, httpOk: false, title: '总调度中心 · Aquant',
          url: 'http://127.0.0.1:5000/runtime-scheduler' }, pg: { listen: false }, effective: false }
      },
      overall: 'critical',
      overallMsg: '采集内部错误（已兜底返回占位数据，查看 events.log）'
    };
    let payload;
    const proc = procInfo();   // 守护进程健康：pid / 启动时间 / 运行时长
    try {
      const s = await Promise.race([
        currentState(),
        new Promise((_, rej) => setTimeout(() => rej(new Error('state-collect-timeout')), 12000))
      ]);
      let events = [];
      try { events = fs.readFileSync(EVENTS_FILE, 'utf8').trim().split('\n').filter(Boolean).slice(-40).reverse(); } catch (e) {}
      payload = { state: normalizeState(s), series: ts.slice(-180), events, proc };
    } catch (e) {
      const msg = 'state handler error: ' + (e && e.message ? e.message : String(e));
      try { logEvent(msg, 'ERR'); } catch (_) {}
      payload = { state: normalizeState(fallback), series: ts.slice(-180), events: [new Date().toISOString() + ' | ERR | ' + msg], proc };
    }
    try {
      const body = JSON.stringify(payload);
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(body);
    } catch (e) {
      try { res.end('{}'); } catch (_) {}
    }
    return;
  }
  let f = u.pathname === '/' ? '/index.html' : u.pathname;
  const clean = path.normalize(f).replace(/^(\.\.[/\\])+/, '');
  const fp = path.join(PUBLIC, clean);
  fs.readFile(fp, (err, data) => {
    if (err) { res.writeHead(404); res.end('not found'); return; }
    const ext = path.extname(fp);
    const ct = ext === '.html' ? 'text/html; charset=utf-8'
            : ext === '.js' ? 'text/javascript; charset=utf-8'
            : ext === '.css' ? 'text/css; charset=utf-8'
            : 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': ct });
    res.end(data);
  });
});

// ---------- 启动监听 + 端口占用自愈 ----------
// 未捕获的 listen 'error'（如 EADDRINUSE）以前会直接掀翻进程。现在改为：
// 记录日志 + 端口占用时每 3s 重试，绝不退出；其它致命错误才退出。
server.on('error', err => {
  const code = err && err.code;
  crashLog('server error: ' + code + ' ' + (err && err.message));
  if (code === 'EADDRINUSE') {
    crashLog('port ' + PORT + ' in use, retry in 3s');
    setTimeout(() => { try { server.listen(PORT); } catch (e) {} }, 3000);
  } else {
    process.exit(1);
  }
});
server.listen(PORT, () => {
  console.log(`[monitor v2] dashboard on http://localhost:${PORT}`);
  crashLog('listening pid=' + process.pid);
});
