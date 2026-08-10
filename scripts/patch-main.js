const fs = require('fs');
const path = require('path');

const targetRoot = process.argv[2];
if (!targetRoot) throw new Error('Usage: node patch-main.js <extracted-app-asar>');

const mainPath = path.join(targetRoot, 'dist', 'main', 'main.js');
const source = fs.readFileSync(mainPath, 'utf8');
const marker = 'leigod-auto-pause:shutdown-guard-v3';
const legacyMarker = 'leigod-auto-pause:v1';

if (source.includes(marker)) {
  process.stdout.write(JSON.stringify({ changed: false, state: 'already-patched', mainPath }));
  process.exit(0);
}

const bootstrap = 'require("./main.jsc");';
if (!source.includes(bootstrap)) {
  throw new Error('Unsupported Leigod main.js layout: main.jsc bootstrap was not found.');
}

const nativeShutdownHook = String.raw`
/* leigod-auto-pause:shutdown-native-v2 */
const __lapNativeShutdownMessage = 0x0011; // WM_QUERYENDSESSION
const __lapNativeHookedWindows = new WeakSet();
let __lapNativeShutdownSeen = false;
function __lapAttachNativeShutdownHook(win) {
  if (!win || win.isDestroyed() || __lapNativeHookedWindows.has(win)) return;
  if (typeof win.hookWindowMessage !== "function") {
    __lapLog("auto-shutdown-native unsupported");
    return;
  }
  __lapNativeHookedWindows.add(win);
  win.hookWindowMessage(__lapNativeShutdownMessage, () => {
    if (__lapNativeShutdownSeen) return;
    __lapNativeShutdownSeen = true;
    const reset = setTimeout(() => { __lapNativeShutdownSeen = false; }, 15000);
    if (reset.unref) reset.unref();
    __lapLog("auto-shutdown-native received");
    __lapPause("auto-shutdown-native", win);
  });
}
__lapElectron.app.on("browser-window-created", (_event, win) => {
  __lapAttachNativeShutdownHook(win);
});
__lapElectron.app.whenReady().then(() => {
  __lapElectron.BrowserWindow.getAllWindows().forEach(__lapAttachNativeShutdownHook);
});
`;

const shutdownGuardHook = String.raw`
/* leigod-auto-pause:shutdown-guard-v3 */
const __lapShutdownGuardMessage = 0x8A51;
const __lapGuardHookedWindows = new WeakSet();
function __lapAttachShutdownGuardHook(win) {
  if (!win || win.isDestroyed() || __lapGuardHookedWindows.has(win)) return;
  if (typeof win.hookWindowMessage !== "function") {
    __lapLog("auto-shutdown-guard unsupported");
    return;
  }
  __lapGuardHookedWindows.add(win);
  win.hookWindowMessage(__lapShutdownGuardMessage, () => {
    __lapLog("auto-shutdown-guard received");
    __lapPause("auto-shutdown-guard", win);
  });
}
__lapElectron.app.on("browser-window-created", (_event, win) => {
  __lapAttachShutdownGuardHook(win);
});
__lapElectron.app.whenReady().then(() => {
  __lapElectron.BrowserWindow.getAllWindows().forEach(__lapAttachShutdownGuardHook);
});
`;

const hook = String.raw`
/* leigod-auto-pause:v1 */
const __lapElectron = require("electron");
const __lapFs = require("fs");
const __lapPath = require("path");
let __lapBypassQuit = false;
let __lapPending = null;
const __lapLogPath = __lapPath.join(process.env.LOCALAPPDATA || __dirname, "LeigodAutoPause", "auto-pause.log");
function __lapLog(message) {
  try {
    __lapFs.mkdirSync(__lapPath.dirname(__lapLogPath), { recursive: true });
    __lapFs.appendFileSync(__lapLogPath, new Date().toISOString() + " " + message + "\n");
  } catch (_) {}
}
function __lapRendererScript(reason) {
  return "(async()=>{try{" +
    "const root=document.querySelector('#app');" +
    "const app=root&&root.__vue_app__;" +
    "const provides=app&&app._context&&app._context.provides;" +
    "const values=provides?Reflect.ownKeys(provides).map(k=>provides[k]):[];" +
    "const pinia=values.find(v=>v&&v._s instanceof Map&&v._s.has('user'));" +
    "const user=pinia&&pinia._s.get('user');" +
    "if(!user)return {status:'user-store-not-found'};" +
    "if(!user.isLogin)return {status:'not-logged-in'};" +
    "const info=user.userTimeInfo||{};" +
    "if(info.timeStatus==='pause')return {status:'already-paused'};" +
    "if(Number(info.notCanPauseTimeLeft||0)>0)return {status:'non-pausable-time-active'};" +
    "await user.toggleTimeStatus('pause',{scene:" + JSON.stringify(reason) + "});" +
    "return {status:(user.userTimeInfo||{}).timeStatus||'pause-requested'};" +
    "}catch(error){return {status:'error',error:String(error&&error.stack||error)}}})()";
}
function __lapFindWindow(preferred) {
  if (preferred && !preferred.isDestroyed()) return preferred;
  return __lapElectron.BrowserWindow.getAllWindows().find(win => !win.isDestroyed() && !win.webContents.isDestroyed());
}
function __lapPause(reason, preferred) {
  if (__lapPending) return __lapPending;
  const win = __lapFindWindow(preferred);
  if (!win) {
    __lapLog(reason + " no-window");
    return Promise.resolve({ status: "no-window" });
  }
  const request = win.webContents.executeJavaScript(__lapRendererScript(reason), true);
  const timeout = new Promise(resolve => setTimeout(() => resolve({ status: "timeout" }), 6000));
  __lapPending = Promise.race([request, timeout]).then(result => {
    __lapLog(reason + " " + JSON.stringify(result));
    return result;
  }, error => {
    __lapLog(reason + " execute-error " + String(error));
    return { status: "execute-error" };
  });
  return __lapPending;
}
function __lapFinishQuit(reason, preferred) {
  __lapPause(reason, preferred).finally(() => {
    __lapBypassQuit = true;
    setTimeout(() => __lapElectron.app.quit(), 0);
  });
}
__lapElectron.app.on("before-quit", event => {
  if (__lapBypassQuit) return;
  event.preventDefault();
  __lapFinishQuit("auto-exit");
});
__lapElectron.app.on("browser-window-created", (_event, win) => {
  win.on("query-session-end", event => {
    if (__lapBypassQuit) return;
    event.preventDefault();
    __lapFinishQuit("auto-shutdown", win);
  });
});
` + nativeShutdownHook + shutdownGuardHook;

const addition = source.includes(legacyMarker) ? shutdownGuardHook : hook;
const patched = source.replace(bootstrap, addition + '\n' + bootstrap);
fs.writeFileSync(mainPath, patched, 'utf8');
process.stdout.write(JSON.stringify({ changed: true, state: 'patched', mainPath }));
