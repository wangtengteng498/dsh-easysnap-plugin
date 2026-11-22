/**
 * Host half of dsh-easysnap-plugin.
 *
 *   GET /dsh-easysnap-plugin/frame    -> 打开桌面取景框（WinForms 置顶窗口），立即返回
 *   GET /dsh-easysnap-plugin/last     -> 取回最近一次「Snap」拍下的 PNG（没有则 204）
 *
 * 取景框是一个独立的 WinForms 窗口：拖边框移动、拖右下角改变大小，
 * 点 Snap 时把框内屏幕内容实时截下来写到临时文件。
 */
import { spawn } from 'node:child_process';
import { readFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FRAME_SCRIPT = path.join(HERE, 'frame.ps1');
const CAPTURE_SCRIPT = path.join(HERE, 'capture.ps1');

const SHOT = path.join(tmpdir(), 'dsh-easysnap-plugin-frame.png');
const MARK = path.join(tmpdir(), 'dsh-easysnap-plugin-frame.done');

export const inject = ['webServer'];

// 当前取景框子进程（用于 /state 判断窗口是否还开着）
let frameChild = null;

function ps(args, opts = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', ...args], {
      windowsHide: true,
      ...opts,
    });
    let out = '';
    let err = '';
    p.stdout.on('data', (d) => { out += String(d); });
    p.stderr.on('data', (d) => { err += String(d); });
    p.on('error', reject);
    p.on('close', (code) => resolve({ code, out, err }));
  });
}

export function apply(ctx) {
  // 打开取景框（不等待窗口关闭）
  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: '/dsh-easysnap-plugin/frame',
    handler: async (req, res) => {
      try {
        // 先清掉上一张，避免客户端拿到旧图
        await ps(['-Command', 'Remove-Item -LiteralPath "' + SHOT.replace(/"/g, '') + '" -ErrorAction SilentlyContinue'], {});
        // 注意：不要用 detached。在 Electron 里 detached 子进程会被立刻回收，
        // 表现就是“提示已打开但看不到窗口”。保持普通子进程 + unref 即可。
        const child = spawn('powershell.exe', [
          '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
          '-File', FRAME_SCRIPT, '-Out', SHOT, '-DoneMarker', MARK,
        ], { windowsHide: true, stdio: 'ignore' });
        frameChild = child;
        child.on('exit', () => { if (frameChild === child) frameChild = null; });
        child.unref();
        res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
        res.end(String((e && e.message) || e));
      }
    },
  }), 'dsh-easysnap-plugin: open frame');

  // 客户端轮询：取回最近一张
  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: '/dsh-easysnap-plugin/state',
    handler: async (req, res) => {
      const alive = !!(frameChild && frameChild.exitCode === null && !frameChild.killed);
      let hasShot = false;
      try {
        const s = await stat(SHOT);
        const m = await stat(MARK);
        hasShot = !!(s && m && m.mtimeMs >= s.mtimeMs);
      } catch (e) {
        hasShot = false;
      }
      res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
      res.end(JSON.stringify({ alive, hasShot }));
    },
  }), 'dsh-easysnap-plugin: state');

  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: '/dsh-easysnap-plugin/last',
    handler: async (req, res) => {
      try {
        const url = String(req.url || '');
        const q = url.indexOf('?') >= 0 ? url.slice(url.indexOf('?') + 1) : '';
        const since = Number(new URLSearchParams(q).get('since') || '0');
        const s = await stat(SHOT).catch(() => null);
        const m = await stat(MARK).catch(() => null);
        if (!s || !m || m.mtimeMs < s.mtimeMs) { res.writeHead(204); res.end(); return; }
        // mtimeMs 是浮点，必须取整后比较，否则同一条记录会被反复判成"新图"
        const shotTs = Math.floor(m.mtimeMs);
        if (shotTs <= since) { res.writeHead(204); res.end(); return; }
        const buf = await readFile(SHOT);
        res.writeHead(200, {
          'content-type': 'image/png',
          'content-length': buf.length,
          'cache-control': 'no-store',
          'x-shot-ts': String(shotTs),
        });
        res.end(buf);
      } catch (e) {
        res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
        res.end(String((e && e.message) || e));
      }
    },
  }), 'dsh-easysnap-plugin: last shot');

  // 兼容旧路径：窗口列表 / 单窗口或整屏截图
  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: '/dsh-easysnap-plugin/windows',
    handler: async (req, res) => {
      try {
        const r = await ps(['-File', CAPTURE_SCRIPT, '-List']);
        const start = r.out.indexOf('[');
        const end = r.out.lastIndexOf(']');
        res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
        res.end(start >= 0 && end > start ? r.out.slice(start, end + 1) : '[]');
      } catch (e) {
        res.writeHead(500, { 'content-type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ error: String((e && e.message) || e) }));
      }
    },
  }), 'dsh-easysnap-plugin: list windows');

  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: '/dsh-easysnap-plugin/capture',
    handler: async (req, res) => {
      const url = String(req.url || '');
      const q = url.indexOf('?') >= 0 ? url.slice(url.indexOf('?') + 1) : '';
      const hwnd = new URLSearchParams(q).get('hwnd') || '';
      const out = path.join(tmpdir(), `dsh-easysnap-plugin-${Date.now()}.png`);
      try {
        const args = ['-File', CAPTURE_SCRIPT, '-Out', out];
        if (hwnd) args.push('-Hwnd', hwnd);
        const r = await ps(args);
        if (r.code !== 0) throw new Error(r.err || ('exit ' + r.code));
        const buf = await readFile(out);
        res.writeHead(200, { 'content-type': 'image/png', 'content-length': buf.length });
        res.end(buf);
      } catch (e) {
        res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
        res.end(String((e && e.message) || e));
      }
    },
  }), 'dsh-easysnap-plugin: capture');
}
