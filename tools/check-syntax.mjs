#!/usr/bin/env node
/**
 * check-syntax.mjs
 *
 * 没有 Swift 编译器时的结构性检查：
 *  - 括号 / 花括号 / 方括号配对（跳过字符串、注释、插值）
 *  - 每个 Swift 文件必须能被"块"正确闭合
 *  - 检查常见的手滑：多余的 `}`、未闭合的 `{`
 *
 * 运行： node tools/check-syntax.mjs
 */

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC = resolve(__dirname, '..', 'NovelReader');

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) walk(p, out);
    else if (name.endsWith('.swift')) out.push(p);
  }
  return out;
}

/**
 * 去掉注释和字符串内容，只留结构字符。
 * 需要正确处理 Swift 的字符串插值 \( ... )，因为里面可能有引号。
 */
function stripNoise(src) {
  let out = '';
  let i = 0;
  const n = src.length;
  const stack = []; // 记录插值嵌套深度

  while (i < n) {
    const c = src[i];
    const next = src[i + 1];

    // 行注释
    if (c === '/' && next === '/') {
      while (i < n && src[i] !== '\n') i++;
      continue;
    }
    // 块注释（Swift 支持嵌套）
    if (c === '/' && next === '*') {
      let depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (src[i] === '/' && src[i + 1] === '*') { depth++; i += 2; continue; }
        if (src[i] === '*' && src[i + 1] === '/') { depth--; i += 2; continue; }
        i++;
      }
      continue;
    }
    // 原始字符串 #"..."# / ##"..."## （正则字面量常用，里面的括号不是代码）
    if (c === '#') {
      let hashes = 0;
      while (src[i + hashes] === '#') hashes++;
      if (src[i + hashes] === '"') {
        const open = '#'.repeat(hashes) + '"';
        const close = '"' + '#'.repeat(hashes);
        // 多行原始字符串
        const triple = '#'.repeat(hashes) + '"""';
        if (src.startsWith(triple, i)) {
          const closeTriple = '"""' + '#'.repeat(hashes);
          i += triple.length;
          while (i < n && !src.startsWith(closeTriple, i)) i++;
          i += closeTriple.length;
          out += '""';
          continue;
        }
        i += open.length;
        while (i < n && !src.startsWith(close, i)) i++;
        i += close.length;
        out += '""';
        continue;
      }
    }
    // 多行字符串 """
    if (c === '"' && src.startsWith('"""', i)) {
      i += 3;
      while (i < n && !src.startsWith('"""', i)) i++;
      i += 3;
      out += '""';
      continue;
    }
    // 普通字符串
    if (c === '"') {
      i++;
      while (i < n) {
        if (src[i] === '\\') { i += 2; continue; }
        if (src[i] === '"') { i++; break; }
        if (src[i] === '\n') break; // 未闭合的字符串，交给外层报错
        i++;
      }
      out += '""';
      continue;
    }
    // 字符
    if (c === "'") {
      i++;
      while (i < n && src[i] !== "'") {
        if (src[i] === '\\') i++;
        i++;
      }
      i++;
      out += "''";
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

let problems = 0;

for (const file of walk(SRC)) {
  const rel = relative(SRC, file);
  const raw = readFileSync(file, 'utf8');
  const clean = stripNoise(raw);

  const pairs = { '{': '}', '(': ')', '[': ']' };
  const closers = { '}': '{', ')': '(', ']': '[' };
  const stack = [];
  const lines = clean.split('\n');

  for (let li = 0; li < lines.length; li++) {
    const line = lines[li];
    for (const ch of line) {
      if (pairs[ch]) {
        stack.push({ ch, line: li + 1 });
      } else if (closers[ch]) {
        if (!stack.length) {
          console.log(`\x1b[31m✗\x1b[0m ${rel}:${li + 1}  多余的 '${ch}'`);
          problems++;
        } else {
          const top = stack.pop();
          if (top.ch !== closers[ch]) {
            console.log(`\x1b[31m✗\x1b[0m ${rel}:${li + 1}  '${ch}' 与第 ${top.line} 行的 '${top.ch}' 不匹配`);
            problems++;
          }
        }
      }
    }
  }
  if (stack.length) {
    for (const s of stack.slice(0, 5)) {
      console.log(`\x1b[31m✗\x1b[0m ${rel}:${s.line}  '${s.ch}' 未闭合`);
      problems++;
    }
  }
}

// ── 检查 SwiftData @Model 的合规性 ──────────────────
const modelFiles = walk(SRC).filter((f) => readFileSync(f, 'utf8').includes('@Model'));
for (const file of modelFiles) {
  const rel = relative(SRC, file);
  const text = readFileSync(file, 'utf8');
  // @Model 类必须有 init
  const classBlocks = text.split(/@Model\s*\n?\s*(?:final\s+)?class\s+/).slice(1);
  for (const block of classBlocks) {
    const name = block.slice(0, block.indexOf('{') > 0 ? block.indexOf('{') : 40).trim();
    if (!/\binit\s*\(/.test(block)) {
      console.log(`\x1b[33m!\x1b[0m ${rel}  @Model 类 ${name.split(/\s/)[0]} 没有显式 init（SwiftData 需要）`);
      problems++;
    }
  }
}

// ── 检查 import 顺序与必需性 ────────────────────────
for (const file of walk(SRC)) {
  const rel = relative(SRC, file);
  const text = readFileSync(file, 'utf8');
  if (/@Model\b/.test(text) && !/^import SwiftData$/m.test(text)) {
    console.log(`\x1b[31m✗\x1b[0m ${rel}  使用 @Model 但缺少 import SwiftData`);
    problems++;
  }
  if (/@Observable\b/.test(text) && !/^import Observation$/m.test(text) && !/^import SwiftUI$/m.test(text)) {
    console.log(`\x1b[31m✗\x1b[0m ${rel}  使用 @Observable 但缺少 import Observation`);
    problems++;
  }
}

console.log(problems === 0
  ? `\x1b[32m结构检查通过：${walk(SRC).length} 个文件\x1b[0m`
  : `\x1b[31m发现 ${problems} 处结构问题\x1b[0m`);
process.exitCode = problems > 0 ? 1 : 0;
