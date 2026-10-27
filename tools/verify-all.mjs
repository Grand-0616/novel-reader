#!/usr/bin/env node
/**
 * verify-all.mjs
 *
 * 一键跑全部检查。
 *
 * 运行： node tools/verify-all.mjs
 */

import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const suites = [
  ['工程文件路径（pbxproj → 磁盘）', 'verify-pbxproj.mjs'],
  ['结构检查（括号/类型/import）', 'check-syntax.mjs'],
  ['Swift 静态检查', 'lint-swift.mjs'],
  ['核心算法（分章/编码/HTML/EPUB/OPDS）', 'verify-core.mjs'],
  ['分页算法（字符守恒/断点/极端输入）', 'verify-pagination.mjs'],
  ['端到端导入（文件→解析→缓存→读回）', 'verify-e2e.mjs'],
];

let failedSuites = 0;
const results = [];

for (const [name, script] of suites) {
  console.log(`\n\x1b[1m▶ ${name}\x1b[0m`);
  const r = spawnSync(process.execPath, [resolve(__dirname, script)], {
    stdio: 'inherit',
    cwd: resolve(__dirname, '..'),
  });
  const ok = r.status === 0;
  if (!ok) failedSuites++;
  results.push([name, ok]);
}

console.log(`\n${'═'.repeat(56)}`);
for (const [name, ok] of results) {
  console.log(`  ${ok ? '\x1b[32m✓\x1b[0m' : '\x1b[31m✗\x1b[0m'} ${name}`);
}
console.log('═'.repeat(56));

if (failedSuites === 0) {
  console.log('\x1b[32m全部检查通过\x1b[0m');
} else {
  console.log(`\x1b[31m${failedSuites} 组检查未通过\x1b[0m`);
  process.exitCode = 1;
}
