#!/usr/bin/env node
/**
 * verify-pagination.mjs
 *
 * 验证分页算法的正确性（不依赖 Core Text）。
 *
 * 把 Paginator.paginate 的控制流原样移植过来，用一个
 * 可控的"排版模拟器"替代 CTFramesetter，验证：
 *   1. 每页从上一页结束处接着排（不重叠、不丢字）
 *   2. 所有页拼起来 = 原文（字符守恒）
 *   3. 不会死循环、不会产生空页
 *   4. 换行断点优化生效且不会把页缩得太短
 *   5. 极端输入（超小容器、超长无标点）不崩
 *
 * 运行： node tools/verify-pagination.mjs
 */

let passed = 0, failed = 0;
const failures = [];

function check(name, fn) {
  try { fn(); passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
  catch (e) { failed++; failures.push([name, e]); console.log(`  \x1b[31m✗\x1b[0m ${name}\n      ${e.message}`); }
}
function assert(c, m) { if (!c) throw new Error(m || 'assert'); }
function assertEq(a, b, m) {
  if (a !== b) throw new Error(`${m || 'not equal'}\n      expected ${JSON.stringify(b)}\n      actual   ${JSON.stringify(a)}`);
}

// ── 模拟 Core Text：每行容纳 charsPerLine 个字符，共 linesPerPage 行 ──
function makeFakeTypesetter(charsPerLine, linesPerPage) {
  return function (text, from) {
    const capacity = charsPerLine * linesPerPage;
    const remaining = text.length - from;
    return Math.min(capacity, remaining);
  };
}

// ── Paginator.paginate 的等价实现 ──
function paginate(text, typeset) {
  const total = text.length;
  if (total === 0) return [{ location: 0, length: 0 }];
  if (!typeset) return [{ location: 0, length: total }];

  const pages = [];
  let location = 0;
  let guardCount = 0;

  while (location < total && guardCount < 20000) {
    guardCount++;
    const visible = typeset(text, location);
    let consumed = visible;
    if (consumed <= 0) consumed = Math.min(1, total - location);

    if (location + consumed < total) {
      consumed = adjustToNaturalBreak(text, location, consumed);
    }
    if (consumed <= 0) consumed = 1;
    consumed = Math.min(consumed, total - location);

    pages.push({ location, length: consumed });
    location += consumed;
  }
  if (pages.length === 0) pages = [{ location: 0, length: total }];
  return pages;
}

function adjustToNaturalBreak(text, start, length) {
  const end = start + length;
  if (end > text.length || length <= 8) return length;
  const searchStart = Math.max(start + 1, end - 120);
  const slice = text.slice(searchStart, end);
  const idx = slice.lastIndexOf('\n');
  if (idx >= 0) {
    const abs = searchStart + idx + 1;
    if (abs > start) return abs - start;
  }
  return length;
}

// ── 测试 ──

function section(t) { console.log(`\n\x1b[1m${t}\x1b[0m`); }

section('1. 字符守恒');
check('无换行文本：所有页拼起来等于原文', () => {
  const text = '字'.repeat(1000);
  const pages = paginate(text, makeFakeTypesetter(20, 10));
  const joined = pages.map((p) => text.slice(p.location, p.location + p.length)).join('');
  assertEq(joined, text, '拼回来的内容与原文不一致');
});
check('有换行文本：字符守恒', () => {
  const text = Array.from({ length: 200 }, (_, i) => `第${i}段的内容，稍微长一点点。`).join('\n');
  const pages = paginate(text, makeFakeTypesetter(24, 12));
  const joined = pages.map((p) => text.slice(p.location, p.location + p.length)).join('');
  assertEq(joined, text);
});
check('中英混排：字符守恒', () => {
  const text = 'The quick brown fox 跳过 lazy dog。'.repeat(100);
  const pages = paginate(text, makeFakeTypesetter(30, 8));
  const joined = pages.map((p) => text.slice(p.location, p.location + p.length)).join('');
  assertEq(joined, text);
});

section('2. 页范围正确性');
check('页范围连续且不重叠', () => {
  const text = '字'.repeat(2000);
  const pages = paginate(text, makeFakeTypesetter(20, 10));
  let expectStart = 0;
  for (const p of pages) {
    assertEq(p.location, expectStart, '页起点与上一页终点不衔接');
    assert(p.length > 0, '出现空页');
    expectStart = p.location + p.length;
  }
  assertEq(expectStart, text.length, '最后一页没有覆盖到结尾');
});
check('没有空页', () => {
  const text = '测试文本。'.repeat(500);
  const pages = paginate(text, makeFakeTypesetter(18, 6));
  assert(pages.every((p) => p.length > 0), '存在 length=0 的页');
});
check('页数与容量估算相符', () => {
  const text = '字'.repeat(1000);
  const pages = paginate(text, makeFakeTypesetter(20, 10)); // 每页 200 字
  assertEq(pages.length, 5, `1000 字 / 200 字每页 应为 5 页，实际 ${pages.length}`);
});

section('3. 换行断点优化');
check('页尾尽量落在换行后', () => {
  // 每行 50 字，每页 5 行 = 250 字容量；每 30 字一个换行
  const lines = [];
  for (let i = 0; i < 100; i++) lines.push('字'.repeat(29) + '\n');
  const text = lines.join('');
  const pages = paginate(text, makeFakeTypesetter(50, 5));
  // 每页应该断在 \n 之后
  for (let i = 0; i < pages.length - 1; i++) {
    const p = pages[i];
    const lastChar = text[p.location + p.length - 1];
    assertEq(lastChar, '\n', `第 ${i + 1} 页没有断在换行处`);
  }
});
check('断点优化不会让页缩得过短', () => {
  // 换行出现在很靠前的位置时，不应回退太多
  const text = '字'.repeat(10) + '\n' + '字'.repeat(5000);
  const pages = paginate(text, makeFakeTypesetter(50, 10)); // 容量 500
  assert(pages[0].length > 400, `第一页只有 ${pages[0].length} 字，回退过多`);
});
check('没有换行时保持原长度', () => {
  const text = '字'.repeat(1000);
  const pages = paginate(text, makeFakeTypesetter(20, 10));
  assertEq(pages[0].length, 200, '无换行时不应调整长度');
});

section('4. 极端输入');
check('空文本返回一页', () => {
  const pages = paginate('', makeFakeTypesetter(20, 10));
  assertEq(pages.length, 1);
  assertEq(pages[0].length, 0);
});
check('单字符文本', () => {
  const pages = paginate('字', makeFakeTypesetter(20, 10));
  assertEq(pages.length, 1);
  assertEq(pages[0].length, 1);
});
check('容器极小（每页 1 字）不死循环', () => {
  const text = '字'.repeat(500);
  const pages = paginate(text, makeFakeTypesetter(1, 1));
  assertEq(pages.length, 500);
  assert(pages.every((p) => p.length === 1));
});
check('排版器返回 0 时强制前进', () => {
  const text = '字'.repeat(50);
  const pages = paginate(text, () => 0);
  assertEq(pages.length, 50, '应每次强制前进 1 个字符');
  const joined = pages.map((p) => text.slice(p.location, p.location + p.length)).join('');
  assertEq(joined, text);
});
check('超长无标点文本不越界', () => {
  const text = 'A'.repeat(100000);
  const pages = paginate(text, makeFakeTypesetter(40, 25));
  const last = pages[pages.length - 1];
  assertEq(last.location + last.length, text.length);
});

section('5. 真实场景模拟');
check('一章 8000 字在 iPhone 上约 20-30 页', () => {
  // iPhone 15: 宽 393pt，左右边距 5.5% → 可用约 350pt；字号 19 → 每行约 18 字
  // 高 852pt，减去安全区与边距约 640pt；行高 19*1.2+8 ≈ 31 → 每页约 20 行
  const charsPerLine = 18;
  const linesPerPage = 20;
  const text = '字'.repeat(8000);
  const pages = paginate(text, makeFakeTypesetter(charsPerLine, linesPerPage));
  const perPage = charsPerLine * linesPerPage; // 360
  assertEq(pages.length, Math.ceil(8000 / perPage));
  assert(pages.length >= 20 && pages.length <= 30,
    `8000 字应在 20-30 页之间，实际 ${pages.length} 页`);
});
check('带段落的中文小说页数合理', () => {
  const paragraphs = [];
  for (let i = 0; i < 100; i++) {
    paragraphs.push('　　' + '他沿着石阶往上走，每走七步就停下来数一次呼吸。'.repeat(2));
  }
  const text = paragraphs.join('\n');
  const pages = paginate(text, makeFakeTypesetter(18, 20));
  assert(pages.length > 10, `页数过少：${pages.length}`);
  const joined = pages.map((p) => text.slice(p.location, p.location + p.length)).join('');
  assertEq(joined, text, '真实场景下字符不守恒');
});

console.log(`\n${'─'.repeat(50)}`);
if (failed === 0) console.log(`\x1b[32m全部通过：${passed} 项\x1b[0m`);
else {
  console.log(`\x1b[31m失败 ${failed} 项\x1b[0m / 通过 ${passed} 项`);
  for (const [n, e] of failures) console.log(`  - ${n}: ${e.message.split('\n')[0]}`);
  process.exitCode = 1;
}
