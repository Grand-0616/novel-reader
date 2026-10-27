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
// Xcode 的对象 ID 是 24 位十六进制。本项目里出现了几种前缀：
//   AA...（手写的工程骨架）、EB/ER/EG（图标资源）。
// 所以这里统一用 [A-Z0-9]{24} 匹配，不限定前缀。
const ID = '([A-Z0-9]{24})';
const groups = new Map();
const groupRe = new RegExp(
  ID + ' /\\* ([^*]+) \\*/ = \\{\\s*isa = PBXGroup;([\\s\\S]*?)\\n\\t\\t\\};', 'g');
let m;
while ((m = groupRe.exec(pbx))) {
  const [, id, name, body] = m;
  const pathM = /path = ([^;]+);/.exec(body);
  const childM = /children = \(([\s\S]*?)\);/.exec(body);
  const children = childM
    ? [...childM[1].matchAll(new RegExp(ID, 'g'))].map((x) => x[1])
    : [];
  groups.set(id, { id, name, path: pathM ? pathM[1] : null, children, body });
}

// ── 2. 建立 parent 关系 ──
const parentOf = new Map();
for (const g of groups.values()) {
  for (const c of g.children) parentOf.set(c, g.id);
}

// ── 3. 解析所有 PBXFileReference ──
// 逐行解析，不依赖缩进层数（不同 Xcode 版本缩进可能不同）
const files = new Map();
for (const line of pbx.split('\n')) {
  if (!line.includes('= {isa = PBXFileReference;')) continue;
  // ID 是行首第一个 24 位十六进制串
  const idM = line.match(/^\s*([A-Z0-9]{24})\b/);
  if (!idM) continue;
  const id = idM[1];
  const nameM = line.match(/\/\* ([^*]+) \*\//);
  const pathM = line.match(/path = ([^;]+);/);
  const name = nameM ? nameM[1].trim() : id;
  files.set(id, { id, name, path: pathM ? pathM[1].trim() : name });
}
console.log(`解析到 ${files.size} 个 PBXFileReference`);

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
