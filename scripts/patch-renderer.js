const fs = require('fs');
const path = require('path');

const targetRoot = process.argv[2];
if (!targetRoot) throw new Error('Usage: node patch-renderer.js <extracted-renderer-asar>');

const legacyMarker = 'leigod-auto-pause:renderer-v1';
const marker = 'leigod-auto-pause:renderer-core-v2';
const assetsRoot = path.join(targetRoot, 'assets');
const candidates = fs.readdirSync(assetsRoot)
  .filter(name => name.endsWith('.js'))
  .map(name => path.join(assetsRoot, name));

let target = null;
let source = null;
for (const file of candidates) {
  const text = fs.readFileSync(file, 'utf8');
  if (text.includes('operation:"exit"') && text.includes('close_tip_type2')) {
    target = file;
    source = text;
    break;
  }
}

if (!target) throw new Error('Unsupported Leigod renderer layout: unified exit asset was not found.');
if (source.includes(marker)) {
  process.stdout.write(JSON.stringify({ changed: false, state: 'already-patched', file: target }));
  process.exit(0);
}

let changed = false;
if (!source.includes(legacyMarker)) {
  const exitIndex = source.indexOf('operation:"exit"');
  const componentStart = Math.max(0, source.lastIndexOf('closeTipModalDialog', exitIndex) - 1000);
  const segment = source.slice(componentStart, exitIndex + 500);
  const storeMatch = segment.match(/([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\(\),[A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*\(\(\)=>\1\.userTimeInfo\)/);
  if (!storeMatch) throw new Error('Unsupported Leigod renderer layout: modal user store was not found.');
  const modalStore = storeMatch[1];

  const handlerPattern = /([A-Za-z_$][\w$]*)=async ([A-Za-z_$][\w$]*)=>\{if\(\2&&([A-Za-z_$][\w$]*)\.type!=="loginout"\)\{/g;
  handlerPattern.lastIndex = componentStart;
  const handlerMatch = handlerPattern.exec(source);
  if (!handlerMatch || handlerMatch.index > exitIndex) {
    throw new Error('Unsupported Leigod renderer layout: type-2 exit function was not found.');
  }
  const argument = handlerMatch[2];
  const props = handlerMatch[3];
  const insertAt = handlerMatch.index + handlerMatch[0].indexOf('{') + 1;
  const hook = `/* ${legacyMarker} */if(${argument}&&${props}.type!=="loginout"&&${modalStore}.isLogin&&${modalStore}.userTimeInfo.timeStatus!=="pause"&&Number(${modalStore}.userTimeInfo.notCanPauseTimeLeft||0)<=0)try{await ${modalStore}.toggleTimeStatus("pause",{scene:"auto_exit"})}catch(__lapError){console.error("leigod-auto-pause failed",__lapError)};`;
  source = source.slice(0, insertAt) + hook + source.slice(insertAt);
  changed = true;
}

const quitMatch = source.match(/([A-Za-z_$][\w$]*)=async\([A-Za-z_$][\w$]*=!0\)=>\{if\(!\1\.__quitting\)try\{\1\.__quitting=!0;const ([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\(\),/);
if (!quitMatch) throw new Error('Unsupported Leigod renderer layout: unified quit function was not found.');
const quitStore = quitMatch[2];
const quitSliceStart = quitMatch.index;
const quitSlice = source.slice(quitSliceStart, quitSliceStart + 2500);
const confirmMatch = /if\([A-Za-z_$][\w$]*\(\),!await [A-Za-z_$][\w$]*\(\)\)return/.exec(quitSlice);
if (!confirmMatch) throw new Error('Unsupported Leigod renderer layout: pause reminder confirmation was not found.');
const coreInsertAt = quitSliceStart + confirmMatch.index + confirmMatch[0].length;
const coreHook = `;/* ${marker} */await ${quitStore}.toggleTimeStatus("pause",{scene:"auto_exit_core"})`;
source = source.slice(0, coreInsertAt) + coreHook + source.slice(coreInsertAt);
changed = true;
fs.writeFileSync(target, source, 'utf8');
process.stdout.write(JSON.stringify({ changed, state: 'patched', file: target, quitStore }));
