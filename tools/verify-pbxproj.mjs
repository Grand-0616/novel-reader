#!/usr/bin/env node
/**
 * verify-pbxproj.mjs
 *
 * 校验 Xcode 工程文件里的每个源文件路径能否在磁盘上找到。
 *
 * 这类错误在本地用 Xcode 打开时会自动修正，所以很难发现；
 * 但命令行构建（CI）会直接报 "Build input files cannot be found"。
 *
 * 运行： node tools/verify-pbxproj.mjs
 */

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const PBX = join(ROOT, 'NovelReader.xcodeproj', 'project.pbxproj');

const pbx = readFileSync(PBX, 'utf8');

// ── 1. 解析所有 PBXGroup，建立 id -> {path, parent} ──
const groups = new Map();
const groupRe = /([A-F0-9]{24}) \/\* ([^*]+) \*\/ = \{\s*isa = PBXGroup;([\s\S]*?)\n\t\t\};/g;
let m;
while ((m = groupRe.exec(pbx))) {
  const [, id, name, body] = m;
  const pathM = /path = ([^;]+);/.exec(body);
  const childM = /children = \(([\s\S]*?)\);/.exec(body);
  const children = childM
    ? [...childM[1].matchAll(/([A-F0-9]{24})/g)].map((x) => x[1])
    : [];
  groups.set(id, { id, name, path: pathM ? pathM[1] : null, children, body });
}

// ── 2. 建立 parent 关系 ──
const parentOf = new Map();
for (const g of groups.values()) {
  for (const c of g.children) parentOf.set(c, g.id);
}

// ── 3. 解析所有 PBXFileReference ──
const files = new Map();
const fileRe = /([A-F0-9]{24}) \/\* ([^*]+) \*\/ = \{isa = PBXFileReference;([^}]*)\}/g;
while ((m = fileRe.exec(pbx))) {
  const [, id, name, body] = m;
  const pathM = /path = ([^;]+);/.exec(body);
  files.set(id, { id, name, path: pathM ? pathM[1] : name });
}

// ── 4. 递归计算完整路径 ──
function fullPath(id) {
  const parts = [];
  let cur = id;
  const seen = new Set();
  while (cur) {
    if (seen.has(cur)) return { error: '循环引用' };
    seen.add(cur);
    const node = groups.get(cur) || files.get(cur);
    if (!node) return { error: `找不到节点 ${cur}` };
    if (node.path) parts.unshift(node.path);
    cur = parentOf.get(cur);
  }
  return { path: parts.join('/') };
}

// ── 5. 校验 ──
let errors = 0;
let checked = 0;
const report = [];

for (const [id, f] of files) {
  if (!/\.(swift|plist|xcassets|json|png|epub)$/i.test(f.path)) continue;
  const r = fullPath(id);
  if (r.error) {
    report.push({ level: 'error', name: f.name, msg: r.error });
    errors++;
    continue;
  }
  checked++;
  const abs = join(ROOT, r.path);
  if (!existsSync(abs)) {
    report.push({ level: 'error', name: f.name, resolved: r.path, msg: '磁盘上不存在' });
    errors++;
  }
}

// ── 6. 检查编译阶段引用的文件是否都在 files 里 ──
const srcPhase = pbx.match(/\/\* Begin PBXSourcesBuildPhase section \*\/([\s\S]*?)\/\* End PBXSourcesBuildPhase/);
const buildFileRefs = new Map();
const bfRe = /([A-F0-9]{24}) \/\* ([^*]+) in Sources \*\/ = \{isa = PBXBuildFile; fileRef = ([A-F0-9]{24})/g;
while ((m = bfRe.exec(pbx))) {
  buildFileRefs.set(m[1], { name: m[2], fileRef: m[3] });
}
const phaseEntries = srcPhase
  ? [...srcPhase[1].matchAll(/([A-F0-9]{24}) \/\* ([^*]+) in Sources \*\//g)].map((x) => ({
      id: x[1], name: x[2],
    }))
  : [];

for (const e of phaseEntries) {
  const bf = buildFileRefs.get(e.id);
  if (!bf) {
    report.push({ level: 'error', name: e.name, msg: '编译阶段条目找不到 PBXBuildFile' });
    errors++;
    continue;
  }
  if (!files.has(bf.fileRef)) {
    report.push({ level: 'error', name: e.name, msg: 'fileRef 指向不存在的 PBXFileReference' });
    errors++;
  }
}

// ── 输出 ──
console.log(`解析 ${groups.size} 个 group，${files.size} 个文件引用`);
console.log(`校验 ${checked} 个文件路径，${phaseEntries.length} 个编译条目\n`);

if (errors) {
  console.log('\x1b[31m错误\x1b[0m');
  for (const r of report) {
    const where = r.resolved ? `  (解析为 ${r.resolved})` : '';
    console.log(`  ${r.name}: ${r.msg}${where}`);
  }
  console.log(`\n\x1b[31m${errors} 处问题\x1b[0m`);
  process.exitCode = 1;
} else {
  console.log('\x1b[32m工程路径全部正确\x1b[0m');
}
