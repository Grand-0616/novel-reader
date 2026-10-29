#!/usr/bin/env node
/**
 * sync-pbxproj.mjs
 *
 * 把 NovelReader/ 目录下新增的源文件自动登记进 project.pbxproj。
 *
 * 为什么需要它：本工程用的是传统 pbxproj（objectVersion 56），
 * 新增 .swift 文件必须同时出现在四处，否则命令行构建直接报
 * "Build input files cannot be found"：
 *   1. PBXFileReference   —— 文件引用
 *   2. PBXBuildFile       —— 编译条目
 *   3. PBXGroup.children  —— 目录树归属
 *   4. PBXSourcesBuildPhase.files —— 真正参与编译
 *
 * 脚本是幂等的：已登记的文件不会重复添加。
 *
 * 运行： node tools/sync-pbxproj.mjs [--dry]
 */

import { readFileSync, writeFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, dirname, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const PBX = join(ROOT, 'NovelReader.xcodeproj', 'project.pbxproj');
const SRC_ROOT = join(ROOT, 'NovelReader');
const DRY = process.argv.includes('--dry');

const ID = '([A-Z0-9]{24})';
const HEX = '0123456789ABCDEF';

// ── 分配新 ID ──────────────────────────────────────────────
// 工程里已有的前缀：buildFile 01xx、fileRef 02xx、group 05xx。
// 新条目从 03xx / 04xx / 06xx 起，避开现有编号。
const seq = { build: 0x301, file: 0x401, group: 0x601 };
const used = new Set();

function alloc(kind) {
  for (;;) {
    const n = seq[kind]++;
    const id = 'AA' + '0'.repeat(18) + n.toString(16).toUpperCase().padStart(4, '0');
    if (!used.has(id)) {
      used.add(id);
      return id;
    }
  }
}

// ── 读工程 ────────────────────────────────────────────────
let pbx = readFileSync(PBX, 'utf8');

for (const m of pbx.matchAll(new RegExp(ID, 'g'))) used.add(m[1]);

// ── 解析 group 树 ─────────────────────────────────────────
const groups = new Map(); // id -> {id, name, path, children}
for (const m of pbx.matchAll(
  new RegExp(ID + ' /\\* ([^*]+) \\*/ = \\{\\s*isa = PBXGroup;([\\s\\S]*?)\\n\\t\\t\\};', 'g'),
)) {
  const [, id, name, body] = m;
  const pathM = /path = ([^;]+);/.exec(body);
  const childM = /children = \(([\s\S]*?)\);/.exec(body);
  groups.set(id, {
    id,
    name,
    path: pathM ? pathM[1] : null,
    children: childM ? [...childM[1].matchAll(new RegExp(ID, 'g'))].map((x) => x[1]) : [],
  });
}

const parentOf = new Map();
for (const g of groups.values()) for (const c of g.children) parentOf.set(c, g.id);

/** group 的磁盘完整路径（相对工程根），无 path 的根 group 返回空串 */
function groupFullPath(id) {
  const parts = [];
  let cur = id;
  const seen = new Set();
  while (cur) {
    if (seen.has(cur)) return null;
    seen.add(cur);
    const g = groups.get(cur);
    if (!g) return null;
    if (g.path) parts.unshift(g.path);
    cur = parentOf.get(cur);
  }
  return parts.join('/');
}

// ── 已登记文件 ────────────────────────────────────────────
const fileRefs = new Map(); // id -> {id, name, path}
for (const line of pbx.split('\n')) {
  if (!line.includes('= {isa = PBXFileReference;')) continue;
  const idM = line.match(/^\s*([A-Z0-9]{24})\b/);
  if (!idM) continue;
  const nameM = line.match(/\/\* ([^*]+) \*\//);
  const pathM = line.match(/path = ([^;]+);/);
  fileRefs.set(idM[1], {
    id: idM[1],
    name: nameM ? nameM[1].trim() : idM[1],
    path: pathM ? pathM[1].trim().replace(/^"|"$/g, '') : '',
  });
}

function fileFullPath(id) {
  const f = fileRefs.get(id);
  if (!f) return null;
  const parent = parentOf.get(id);
  const base = parent ? groupFullPath(parent) : '';
  if (base === null) return null;
  return base ? `${base}/${f.path}` : f.path;
}

const registered = new Set();
for (const id of fileRefs.keys()) {
  const p = fileFullPath(id);
  if (p) registered.add(p.split('/').join(sep));
}

// ── 扫描磁盘 ──────────────────────────────────────────────
/** 需要参与编译/打包的扩展名 */
const WANTED = /\.(swift|plist|json|png|epub|otf|ttf)$/i;

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (name.startsWith('.')) continue;
    const full = join(dir, name);
    const st = statSync(full);
    if (st.isDirectory()) {
      // .xcassets 由 Xcode 的 asset catalog 编译阶段单独处理，
      // 本工程历史上就没登记它（图标走 Resources/Icons 的 png），
      // 这里保持原状，避免改动既有构建行为。
      if (name.endsWith('.xcassets')) continue;
      walk(full, out);
    } else if (WANTED.test(name)) {
      out.push(full);
    }
  }
  return out;
}

const onDisk = walk(SRC_ROOT);
const missing = [];
for (const abs of onDisk) {
  const rel = relative(ROOT, abs).split(sep).join('/');
  if (!registered.has(rel.split('/').join(sep))) missing.push({ abs, rel });
}

if (missing.length === 0) {
  console.log('工程已是最新，无需改动。');
  process.exit(0);
}

console.log(`发现 ${missing.length} 个未登记文件：`);
for (const f of missing) console.log('  + ' + f.rel);

if (DRY) {
  console.log('\n--dry 模式，未写入。');
  process.exit(0);
}

// ── 确保目录对应的 group 存在 ─────────────────────────────
const newGroups = []; // {id, name, path, parentID}

function ensureGroup(dirRel) {
  // dirRel 形如 "NovelReader/Sources/Legado"
  if (!dirRel) return null;

  // 已存在则直接返回
  for (const g of groups.values()) {
    if (groupFullPath(g.id) === dirRel) return g.id;
  }

  const parentRel = dirRel.split('/').slice(0, -1).join('/');
  const name = dirRel.split('/').pop();
  const parentID = parentRel ? ensureGroup(parentRel) : null;

  const id = alloc('group');
  const g = { id, name, path: name, children: [] };
  groups.set(id, g);
  if (parentID) {
    parentOf.set(id, parentID);
    groups.get(parentID).children.push(id);
  }
  newGroups.push({ id, name, path: name, parentID });
  console.log(`  新建 group: ${dirRel} (${id})`);
  return id;
}

// ── 生成插入内容 ──────────────────────────────────────────
const newFileLines = [];   // PBXFileReference
const newBuildLines = [];  // PBXBuildFile
const newPhaseEntries = []; // Sources 阶段
const groupAdds = new Map(); // groupID -> [childID]

for (const { abs, rel } of missing) {
  const dirRel = rel.split('/').slice(0, -1).join('/');
  const fileName = rel.split('/').pop();
  const gid = ensureGroup(dirRel);

  const fileID = alloc('file');
  const ext = fileName.split('.').pop().toLowerCase();
  const fileType = {
    swift: 'sourcecode.swift',
    plist: 'text.plist.xml',
    json: 'text.json',
    png: 'image.png',
    epub: 'file',
    otf: 'file',
    ttf: 'file',
  }[ext] || 'file';

  fileRefs.set(fileID, { id: fileID, name: fileName, path: fileName });
  parentOf.set(fileID, gid);

  newFileLines.push(
    `\t\t${fileID} /* ${fileName} */ = {isa = PBXFileReference; lastKnownFileType = ${fileType}; path = ${fileName}; sourceTree = "<group>"; };`,
  );

  if (gid) {
    if (!groupAdds.has(gid)) groupAdds.set(gid, []);
    groupAdds.get(gid).push(fileID);
  }

  // .swift 才进编译阶段
  if (ext === 'swift') {
    const bfID = alloc('build');
    newBuildLines.push(
      `\t\t${bfID} /* ${fileName} in Sources */ = {isa = PBXBuildFile; fileRef = ${fileID} /* ${fileName} */; };`,
    );
    newPhaseEntries.push(`\t\t\t\t${bfID} /* ${fileName} in Sources */,`);
  } else if (ext === 'png' || ext === 'xcassets' || ext === 'epub' || ext === 'otf' || ext === 'ttf') {
    const bfID = alloc('build');
    newBuildLines.push(
      `\t\t${bfID} /* ${fileName} in Resources */ = {isa = PBXBuildFile; fileRef = ${fileID} /* ${fileName} */; };`,
    );
  }
}

// ── 写入 pbxproj ──────────────────────────────────────────

// 1) PBXBuildFile 段尾插入
{
  const marker = '/* End PBXBuildFile section */';
  const at = pbx.indexOf(marker);
  if (at < 0) throw new Error('找不到 PBXBuildFile section 结束标记');
  pbx = pbx.slice(0, at) + newBuildLines.join('\n') + '\n' + pbx.slice(at);
}

// 2) PBXFileReference 段尾插入
{
  const marker = '/* End PBXFileReference section */';
  const at = pbx.indexOf(marker);
  if (at < 0) throw new Error('找不到 PBXFileReference section 结束标记');
  pbx = pbx.slice(0, at) + newFileLines.join('\n') + '\n' + pbx.slice(at);
}

// 2.5) 新建 group 定义（必须写在 children 追加之前，否则后面正则找不到它）
if (newGroups.length) {
  const marker = '/* End PBXGroup section */';
  const at = pbx.indexOf(marker);
  if (at < 0) throw new Error('找不到 PBXGroup section 结束标记');

  const lines = newGroups
    .map((g) => {
      const kids = groupAdds.get(g.id) ?? [];
      const childLines = kids
        .map((cid) => {
          const f = fileRefs.get(cid);
          const label = f ? f.name : groups.get(cid)?.name ?? cid;
          return `\t\t\t\t${cid} /* ${label} */,`;
        })
        .join('\n');
      return [
        `\t\t${g.id} /* ${g.name} */ = {`,
        '\t\t\tisa = PBXGroup;',
        '\t\t\tchildren = (',
        childLines,
        '\t\t\t);',
        `\t\t\tpath = ${g.name};`,
        '\t\t\tsourceTree = "<group>";',
        '\t\t};',
      ]
        .filter((line) => line !== '')
        .join('\n');
    })
    .join('\n');

  pbx = pbx.slice(0, at) + lines + '\n' + pbx.slice(at);

  // 这些 group 下的文件已写进定义，别在第 3 步重复追加
  for (const g of newGroups) groupAdds.delete(g.id);

  // 把新 group 挂到各自的父 group 上
  for (const g of newGroups) {
    if (!g.parentID) continue;
    if (!groupAdds.has(g.parentID)) groupAdds.set(g.parentID, []);
    groupAdds.get(g.parentID).push(g.id);
  }
}

// 3) group children 追加
for (const [gid, children] of groupAdds) {
  const g = groups.get(gid);
  if (!g) continue;
  const re = new RegExp(
    `(${gid} /\\* [^*]+ \\*/ = \\{\\s*isa = PBXGroup;[\\s\\S]*?children = \\()([\\s\\S]*?)(\\);\\s*path = )`,
  );
  const m = re.exec(pbx);
  if (!m) {
    console.warn(`  ⚠️ 未能定位 group ${gid} 的 children，跳过`);
    continue;
  }
  const existing = m[2];
  const addition = children
    .map((cid) => {
      const f = fileRefs.get(cid);
      const label = f ? f.name : groups.get(cid)?.name ?? cid;
      return `\t\t\t\t${cid} /* ${label} */,\n`;
    })
    .join('');
  const needIndent = existing.endsWith('\n') ? '' : '\n';
  pbx = pbx.replace(re, `$1${existing}${needIndent}${addition}$3`);
}

// 4) Sources 阶段追加
if (newPhaseEntries.length) {
  const re = /(\/\* Begin PBXSourcesBuildPhase section \*\/[\s\S]*?files = \()([\s\S]*?)(\);\s*runOnlyForDeploymentPostprocessing = 0;)/;
  const m = re.exec(pbx);
  if (!m) throw new Error('找不到 PBXSourcesBuildPhase 的 files 列表');
  const needIndent = m[2].endsWith('\n') ? '' : '\n';
  pbx = pbx.replace(re, `$1${m[2]}${needIndent}${newPhaseEntries.join('\n')}\n$3`);
}

writeFileSync(PBX, pbx, 'utf8');
console.log(`\n已登记 ${missing.length} 个文件、${newGroups.length} 个 group。`);
console.log('下一步： node tools/verify-pbxproj.mjs 校验');
