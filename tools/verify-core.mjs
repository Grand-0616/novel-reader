#!/usr/bin/env node
/**
 * verify-core.mjs
 *
 * 在没有 Xcode 的环境下验证项目核心算法逻辑。
 * 把 Swift 侧的纯算法（章节切分、编码探测、HTML→文本、
 * OPDS 条目解析、规则抽取）按相同规则移植成 JS，
 * 并用 fixture 数据跑通全链路，确保上机前逻辑是对的。
 *
 * 运行： node tools/verify-core.mjs
 */

import { readFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

let passed = 0;
let failed = 0;
const failures = [];

function check(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  \x1b[32m✓\x1b[0m ${name}`);
  } catch (err) {
    failed++;
    failures.push({ name, err });
    console.log(`  \x1b[31m✗\x1b[0m ${name}\n      ${err.message}`);
  }
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg || 'assertion failed');
}

function assertEq(actual, expected, msg) {
  if (actual !== expected) {
    throw new Error(`${msg || 'not equal'}\n      expected: ${JSON.stringify(expected)}\n      actual:   ${JSON.stringify(actual)}`);
  }
}

function section(title) {
  console.log(`\n\x1b[1m${title}\x1b[0m`);
}

// ────────────────────────────────────────────────────────────
// 1. TextSanitizer 移植
// ────────────────────────────────────────────────────────────

const CHAPTER_PATTERNS = [
  // 括号包住章节号：【第7章】归墟 / （第7章）
  /^\s{0,4}[【（(]\s*第\s*[0-9０-９零一二三四五六七八九十百千万两]{1,12}\s*[章节回卷]\s*[】）)][^。！？；]{0,40}$/,
  // 第N章 / 第N回 / 第N节
  /^\s{0,8}第\s*[0-9０-９零一二三四五六七八九十百千万两]{1,12}\s*[章节回卷折幕话篇](?:\s|：|:|[^。！？；\n]{0,60})$/,
  // 正文 第N章
  /^\s{0,8}正文\s*第\s*[0-9零一二三四五六七八九十百千万两]{1,12}\s*[章节回][^。！？；]{0,60}$/,
  // 卷X 第Y章
  /^\s{0,8}[卷部]\s*[0-9零一二三四五六七八九十百千万两]{1,6}\s*第\s*[0-9零一二三四五六七八九十百千万两]{1,12}\s*[章节回][^。！？；]{0,60}$/,
  // Chapter 12
  /^\s{0,8}chapter\s*[0-9ivxlcdm]{1,8}\b.{0,80}$/i,
  // 序章 / 楔子 / 尾声 / 番外
  /^\s{0,8}(?:序章|序言|序|楔子|引子|前言|尾声|后记|终章|大结局|番外[一二三四五六七八九十0-9]*)\s*.{0,40}$/,
];

function isChapterTitle(line) {
  const trimmed = line.trim();
  if (!trimmed) return false;
  if ([...trimmed].length > 60) return false;
  if (trimmed.includes('。') && [...trimmed].length > 24) return false;
  return CHAPTER_PATTERNS.some((re) => re.test(trimmed));
}

const JUNK_MARKERS = [
  '本章未完', '请收藏本站', '请记住本书', '首发地址', '最新章节请',
  '手机阅读', '手机用户请', '百度搜索', '笔趣阁', 'www.', 'http://', 'https://',
  '天才一秒记住', '更新最快', '无弹窗', '广告', '加入书签', '投推荐票',
  '一秒记住本站', '章节错误', '举报后维护', '内容严重缺失', '请勿开启浏览器阅读模式',
  '红色字体', '推荐一个app', '你可以用', '本站域名', '顶点小说', '书趣阁',
];

function isJunkLine(line) {
  const t = line.trim();
  if (t.length <= 2) return false;
  if ([...t].every((c) => '-=_*~·—─═　 '.includes(c))) return true;
  const lower = t.toLowerCase();
  return JUNK_MARKERS.some((m) => lower.includes(m.toLowerCase()));
}

function normalizeBody(raw) {
  let s = raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\u00a0/g, ' ')
    .replace(/\u3000/g, '  ').replace(/\ufeff/g, '');
  const lines = [];
  let blankRun = 0;
  for (const rawLine of s.split('\n')) {
    const line = rawLine.replace(/[ \t]{2,}/g, '  ');
    const trimmed = line.trim();
    if (!trimmed) {
      blankRun++;
      if (blankRun > 1) continue;
      lines.push('');
    } else {
      blankRun = 0;
      lines.push(isJunkLine(trimmed) ? '' : line);
    }
  }
  while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
  while (lines.length && !lines[0].trim()) lines.shift();
  return lines.join('\n');
}

function applyIndent(body) {
  const lines = body.split('\n');
  let indented = 0, total = 0;
  for (const l of lines) {
    if (!l.trim()) continue;
    total++;
    if (l.startsWith('  ') || l.startsWith('\t')) indented++;
  }
  if (total === 0 || indented / total >= 0.6) return body;
  return lines.map((l) => {
    const t = l.trim();
    return t ? '  ' + t : '';
  }).join('\n');
}

// ────────────────────────────────────────────────────────────
// 2. ChapterSplitter 移植
// ────────────────────────────────────────────────────────────

const MAX_CHAPTER_CHARS = 30000;
const MIN_CHAPTER_CHARS = 40;

function paragraphSplit(ch) {
  const paragraphs = ch.content.split('\n');
  const targetChunks = Math.max(2, Math.ceil([...ch.content].length / MAX_CHAPTER_CHARS));
  const chunks = [];
  let current = [];
  let currentLen = 0;
  const targetLen = [...ch.content].length / targetChunks;
  for (const p of paragraphs) {
    current.push(p);
    currentLen += [...p].length + 1;
    if (currentLen >= targetLen && chunks.length < targetChunks - 1) {
      chunks.push(current);
      current = [];
      currentLen = 0;
    }
  }
  if (current.length) chunks.push(current);
  const total = chunks.length;
  return chunks.map((lines, idx) => ({
    title: total > 1 ? `${ch.title} (${idx + 1}/${total})` : ch.title,
    content: normalizeBody(lines.join('\n')),
  }));
}

function hardSplit(body, bookTitle) {
  let paragraphs = body.split('\n').map((p) => p.trim()).filter(Boolean);
  if (paragraphs.length <= 1) {
    const pieces = [];
    let current = '';
    for (const ch of body) {
      current += ch;
      if ('。！？…\n'.includes(ch)) {
        const t = current.trim();
        if (t) pieces.push(t);
        current = '';
      }
    }
    const t = current.trim();
    if (t) pieces.push(t);
    paragraphs = pieces;
  }
  const result = [];
  let buf = [], bufLen = 0, part = 1;
  const TARGET = 6000;
  const flush = () => {
    if (!buf.length) return;
    result.push({ title: `${bookTitle} - 第${part}节`, content: normalizeBody(buf.join('\n')) });
    buf = []; bufLen = 0; part++;
  };
  for (const p of paragraphs) {
    buf.push(p);
    bufLen += [...p].length + 1;
    if (bufLen >= TARGET) flush();
  }
  flush();
  return result;
}

function isRealPreamble(text) {
  const trimmed = text.trim();
  if ([...trimmed].length < 200) return false;
  const lines = trimmed.split('\n').map((l) => l.trim()).filter(Boolean);
  const metaPrefixes = ['书名', '作者', '简介', '内容简介', '分类', '状态', '字数',
    '更新时间', '最新章节', '来源', '网址', '声明', '版权'];
  let metaLines = 0, proseLines = 0;
  for (const l of lines) {
    if (metaPrefixes.some((p) => l.startsWith(p)) && [...l].length <= 40) metaLines++;
    else if (l.includes('http') || l.includes('www.')) metaLines++;
    else if ([...l].length > 12) proseLines++;
  }
  return proseLines >= 3 && proseLines > metaLines * 2;
}

function looksLikeProse(text) {
  const t = text.trim();
  if (!t) return false;
  if (/[。！？…；”』」!?;]/.test(t)) return true;
  const lines = t.split('\n').filter((l) => l.trim());
  if (lines.length >= 2) return true;
  return [...t].length >= 20;
}

function splitChapters(raw, bookTitle = '正文') {
  const normalized = raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const lines = normalized.split('\n');
  const chapters = [];
  let currentTitle = bookTitle;
  let buffer = [];
  let hasTitle = false;

  const flush = () => {
    const body = normalizeBody(buffer.join('\n'));
    buffer = [];
    if (!body) return;
    if (chapters.length > 0 && [...body].length < MIN_CHAPTER_CHARS && !looksLikeProse(body)) {
      const last = chapters.pop();
      chapters.push({ title: last.title, content: last.content + '\n\n' + body });
      return;
    }
    chapters.push({ title: currentTitle, content: body });
  };

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (line && [...line].length <= 60 && isChapterTitle(line)) {
      if (!hasTitle) {
        const preamble = normalizeBody(buffer.join('\n'));
        buffer = [];
        if (isRealPreamble(preamble)) chapters.push({ title: '前言', content: preamble });
        currentTitle = line;
        hasTitle = true;
        continue;
      }
      flush();
      currentTitle = line;
      buffer = [];
    } else {
      buffer.push(rawLine);
    }
  }
  flush();

  if (!hasTitle) {
    const body = normalizeBody(normalized);
    if (!body) return [];
    return hardSplit(body, bookTitle);
  }
  if (!chapters.length) {
    const body = normalizeBody(normalized);
    if (!body) return [];
    return hardSplit(body, bookTitle);
  }

  const out = [];
  for (const ch of chapters) {
    if ([...ch.content].length > MAX_CHAPTER_CHARS) out.push(...paragraphSplit(ch));
    else out.push(ch);
  }
  return out;
}

function parseFileNameTitle(fileName) {
  let name = fileName.replace(/\.[^.]+$/, '').trim();
  let m = name.match(/^《(.+?)》\s*(.*)$/);
  if (m) return { title: m[1], author: (m[2] || '').trim() };
  m = name.match(/^[[【](.+?)[\]】]\s*(.+)$/);
  if (m) return { title: m[2].trim(), author: m[1] };
  for (const sep of [' - ', ' – ', '—', '_', '（', '(']) {
    const idx = name.lastIndexOf(sep);
    if (idx > 0) {
      let title = name.slice(0, idx).trim();
      let author = name.slice(idx + sep.length).trim();
      if (sep === '（' || sep === '(') {
        author = author.replace(/[）)]/g, '');
        if ([...author].length > 12) continue;
      }
      title = title.replace(/[[\]]/g, '');
      if (title) return { title, author };
    }
  }
  const ai = name.indexOf('作者');
  if (ai > 0) {
    const title = name.slice(0, ai).trim();
    const author = name.slice(ai + 2).replace(/[：:]/g, '').trim();
    if (title) return { title, author };
  }
  return { title: name, author: '' };
}

// ────────────────────────────────────────────────────────────
// 3. 编码探测移植
// ────────────────────────────────────────────────────────────

function isValidUTF8(buf) {
  let i = 0;
  while (i < buf.length) {
    const b = buf[i];
    if (b < 0x80) { i++; continue; }
    let need = 0;
    if ((b & 0xe0) === 0xc0) need = 1;
    else if ((b & 0xf0) === 0xe0) need = 2;
    else if ((b & 0xf8) === 0xf0) need = 3;
    else return false;
    if (i + need >= buf.length) return false;
    for (let k = 1; k <= need; k++) if ((buf[i + k] & 0xc0) !== 0x80) return false;
    i += need + 1;
  }
  return true;
}

function decodeAuto(buf) {
  if (buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) {
    return { text: new TextDecoder('utf-8').decode(buf.subarray(3)), encoding: 'utf-8-bom' };
  }
  if (isValidUTF8(buf)) return { text: new TextDecoder('utf-8').decode(buf), encoding: 'utf-8' };
  try {
    return { text: new TextDecoder('gb18030').decode(buf), encoding: 'gb18030' };
  } catch {
    return { text: new TextDecoder('utf-8', { fatal: false }).decode(buf), encoding: 'gb18030(fallback)' };
  }
}

// ────────────────────────────────────────────────────────────
// 4. HTML → 纯文本 & 规则抽取移植
// ────────────────────────────────────────────────────────────

const ENTITIES = {
  nbsp: ' ', amp: '&', lt: '<', gt: '>', quot: '"', apos: "'",
  hellip: '…', mdash: '—', ndash: '–', ldquo: '“', rdquo: '”',
  lsquo: '‘', rsquo: '’', middot: '·', times: '×', copy: '©',
};

function decodeEntities(s) {
  return s
    .replace(/&([a-zA-Z]{2,10});/g, (m, name) => ENTITIES[name.toLowerCase()] ?? m)
    .replace(/&#(x?)([0-9a-fA-F]{1,6});/g, (m, hex, num) => {
      const code = parseInt(num, hex ? 16 : 10);
      try { return String.fromCodePoint(code); } catch { return m; }
    });
}

const BLOCK_TAGS = ['p', 'div', 'br', 'li', 'tr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'section', 'article', 'blockquote', 'dd', 'dt', 'table', 'ul', 'ol', 'hr'];

function htmlToPlainText(html) {
  let s = html;
  for (const tag of ['script', 'style', 'noscript', 'svg']) {
    s = s.replace(new RegExp(`<${tag}[^>]*>[\\s\\S]*?</${tag}>`, 'gi'), '');
  }
  s = s.replace(/<!--[\s\S]*?-->/g, '');
  for (const tag of BLOCK_TAGS) {
    s = s.replace(new RegExp(`</?${tag}[^>]*>`, 'gi'), '\n');
  }
  s = s.replace(/<[^>]+>/g, '');
  s = decodeEntities(s);
  s = s.replace(/\r\n/g, '\n').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n');
  const out = [];
  for (const raw of s.split('\n')) {
    const l = raw.trim();
    if (!l) {
      if (out[out.length - 1] === '') continue;
      out.push('');
    } else out.push(l);
  }
  return out.join('\n').trim();
}

function parseCSS(rule) {
  const tokens = rule.replace(/>/g, ' ').trim().split(/\s+/).filter(Boolean);
  return tokens.map((token) => {
    const sel = { tag: null, id: null, classes: [], attrs: [] };
    const parts = token.match(/(^[a-zA-Z0-9*]+)|(#[\w-]+)|(\.[\w-]+)|(\[[^\]]+\])/g) || [];
    for (const p of parts) {
      if (p.startsWith('#')) sel.id = p.slice(1);
      else if (p.startsWith('.')) sel.classes.push(p.slice(1));
      else if (p.startsWith('[')) {
        const m = p.match(/^\[([\w-]+)=["']?([^"'\]]+)["']?\]$/);
        if (m) sel.attrs.push([m[1], m[2]]);
      } else if (p !== '*') sel.tag = p.toLowerCase();
    }
    return sel;
  });
}

/** 取一个容器的完整 HTML（按标签配对） */
function sliceBalanced(html, openMatch) {
  const tag = (openMatch[0].match(/^<([a-zA-Z0-9]+)/) || [, 'div'])[1];
  const start = openMatch.index;
  const re = new RegExp(`<(/?)${tag}(?:\\s[^>]*)?>`, 'gi');
  re.lastIndex = start;
  let depth = 0, end = html.length, mm;
  while ((mm = re.exec(html))) {
    if (mm[1] === '/') {
      depth--;
      if (depth === 0) { end = mm.index + mm[0].length; break; }
    } else if (!mm[0].endsWith('/>')) {
      depth++;
    }
  }
  return html.slice(start, end);
}

function extractByCSS(html, rule) {
  const chain = parseCSS(rule);
  const last = chain[chain.length - 1];
  const tagName = last.tag || 'div';
  const openRe = new RegExp(`<${tagName}\\b([^>]*)>`, 'gi');
  let m;
  while ((m = openRe.exec(html))) {
    const attrs = m[1] ?? '';
    if (last.id && !new RegExp(`id\\s*=\\s*["']?${last.id}["']?`).test(attrs)) continue;
    if (last.classes.length) {
      const cls = ((attrs.match(/class\s*=\s*["']([^"']*)["']/) || [, ''])[1]).split(/\s+/);
      if (!last.classes.every((c) => cls.includes(c))) continue;
    }
    return sliceBalanced(html, m);
  }
  return null;
}

function extractContent(html, selector, removeSelectors = []) {
  let target = html;
  if (selector && selector !== 'body') {
    const byRule = extractByCSS(html, selector);
    if (byRule) target = byRule;
  }
  for (const rm of removeSelectors) {
    const chain = parseCSS(rm);
    const last = chain[chain.length - 1];
    const tagName = last.tag || 'div';
    const cls = last.classes[0];
    const re = cls
      ? new RegExp(`<${tagName}\\b[^>]*class\\s*=\\s*["'][^"']*\\b${cls}\\b[^"']*["'][^>]*>[\\s\\S]*?</${tagName}>`, 'gi')
      : new RegExp(`<${tagName}\\b[^>]*>[\\s\\S]*?</${tagName}>`, 'gi');
    target = target.replace(re, '');
  }
  return normalizeBody(htmlToPlainText(target));
}

// ────────────────────────────────────────────────────────────
// 5. OPDS 条目解析移植
// ────────────────────────────────────────────────────────────

function parseOPDSEntries(xml) {
  const entries = [];
  const re = /<entry\b[\s\S]*?<\/entry>/gi;
  let m;
  while ((m = re.exec(xml))) {
    const block = m[0];
    const title = (block.match(/<title[^>]*>([\s\S]*?)<\/title>/i) || [, ''])[1].trim();
    if (!title) continue;
    const author = (block.match(/<author[^>]*>[\s\S]*?<name[^>]*>([\s\S]*?)<\/name>/i) || [, null])[1];
    const links = [];
    const linkRe = /<link\b[^>]*>/gi;
    let lm;
    while ((lm = linkRe.exec(block))) {
      const tag = lm[0];
      const href = (tag.match(/href\s*=\s*["']([^"']+)["']/i) || [, ''])[1];
      const type = ((tag.match(/type\s*=\s*["']([^"']+)["']/i) || [, ''])[1]).toLowerCase();
      const rel = ((tag.match(/rel\s*=\s*["']([^"']+)["']/i) || [, ''])[1]).toLowerCase();
      if (href) links.push({ href, type, rel });
    }
    const cover = links.find((l) => l.rel.includes('image') || l.rel.includes('thumbnail'));
    let best = null, bestPrio = -1;
    for (const l of links) {
      if (l.rel.includes('image') || l.type.startsWith('image/')) continue;
      let prio = 0;
      if (l.type.includes('epub') || /\.epub$/i.test(l.href)) prio = 100;
      else if (l.type.includes('text/plain') || /\.txt$/i.test(l.href)) prio = 90;
      else if (l.type.includes('html') || /\.html?$/i.test(l.href)) prio = 80;
      else if (l.type.includes('atom+xml') || l.rel === 'subsection') prio = 70;
      else prio = 10;
      if (prio > bestPrio) { bestPrio = prio; best = l; }
    }
    if (!best) continue;
    const kind = best.type.includes('atom+xml') || best.rel === 'subsection' ? 'directory'
      : best.type.includes('html') ? 'chapter'
      : 'book';
    entries.push({ title, author, href: best.href, kind, cover: cover?.href ?? null });
  }
  return entries;
}

// ────────────────────────────────────────────────────────────
// 6. 测试数据
// ────────────────────────────────────────────────────────────

function makeFixtureTxt() {
  const ch1 = [
    '　　夜色沉下来的时候，山谷里起了雾。',
    '　　他沿着石阶往上走，每走七步就停下来数一次呼吸。',
    '',
    '本章未完，请收藏本站，首发地址 www.example.com',
    '',
    '　　第一百级的台阶上落着一片枯叶。',
  ].join('\n');

  const ch2 = [
    '　　“你来了。”老人的声音从廊下传来。',
    '　　他没有回头，只是把手上那盏灯往旁边挪了半寸。',
    '',
    '　　灯芯哔剥响了一声。',
  ].join('\n');

  const ch3 = [
    '　　下山的路比上山短，他想。',
    '　　可这一次，他没有数台阶。',
    '　　雾散了，山谷里露出一片青灰色的屋脊。',
    '　　远处有人在喊他的名字，声音被风削得很薄。',
  ].join('\n');

  return [
    '书名：雾隐山',
    '作者：林晚',
    '简介：一个关于登山者的故事。',
    '',
    '第一章 上山',
    ch1,
    '',
    '第二章 灯',
    ch2,
    '',
    '第三章 归途',
    ch3,
  ].join('\n');
}

function crc32(buf) {
  let table = crc32.table;
  if (!table) {
    table = crc32.table = new Uint32Array(256);
    for (let i = 0; i < 256; i++) {
      let c = i;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      table[i] = c >>> 0;
    }
  }
  let crc = 0xffffffff;
  for (const b of buf) crc = table[(crc ^ b) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function makeEPUB() {
  const files = {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml':
      '<?xml version="1.0"?><container version="1.0"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
    'OEBPS/content.opf':
      '<?xml version="1.0"?><package><metadata><dc:title>雪线之上</dc:title><dc:creator>沈舟</dc:creator><dc:description>高原救援队的故事。</dc:description></metadata><manifest>' +
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml"/>' +
      '<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>' +
      '<item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>' +
      '</manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>',
    'OEBPS/nav.xhtml':
      '<html><body><nav><ol><li><a href="ch1.xhtml">第一章 暴风雪</a></li><li><a href="ch2.xhtml">第二章 撤离</a></li></ol></nav></body></html>',
    'OEBPS/ch1.xhtml':
      '<html><body><h2>第一章</h2><p>风从垭口灌下来，帐篷的支架发出断裂前的呻吟。</p><p>他按下对讲机的按钮，只听到电流声。</p></body></html>',
    'OEBPS/ch2.xhtml':
      '<html><body><h2>第二章</h2><p>直升机的旋翼在雪面上投下一圈黑影。</p><p>“先送伤员。”他说。</p></body></html>',
  };
  const encoder = new TextEncoder();
  const chunks = [];
  const central = [];
  let offset = 0;

  for (const [name, content] of Object.entries(files)) {
    const data = encoder.encode(content);
    const nameBytes = encoder.encode(name);
    const crc = crc32(data);

    const local = Buffer.alloc(30 + nameBytes.length);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0, 6);
    local.writeUInt16LE(0, 8);      // stored
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBytes.length, 26);
    local.writeUInt16LE(0, 28);
    Buffer.from(nameBytes).copy(local, 30);

    const cd = Buffer.alloc(46 + nameBytes.length);
    cd.writeUInt32LE(0x02014b50, 0);
    cd.writeUInt16LE(20, 4);
    cd.writeUInt16LE(20, 6);
    cd.writeUInt16LE(0, 8);
    cd.writeUInt16LE(0, 10);        // stored
    cd.writeUInt32LE(crc, 16);
    cd.writeUInt32LE(data.length, 20);
    cd.writeUInt32LE(data.length, 24);
    cd.writeUInt16LE(nameBytes.length, 28);
    cd.writeUInt32LE(offset, 42);
    Buffer.from(nameBytes).copy(cd, 46);

    chunks.push(local, Buffer.from(data));
    central.push(cd);
    offset += local.length + data.length;
  }

  const cdBuf = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(central.length, 8);
  eocd.writeUInt16LE(central.length, 10);
  eocd.writeUInt32LE(cdBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);

  return Buffer.concat([...chunks, cdBuf, eocd]);
}

function readZipStored(buf) {
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 65557); i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('EOCD not found');
  const total = buf.readUInt16LE(eocd + 10);
  const cdOffset = buf.readUInt32LE(eocd + 16);
  const entries = {};
  let p = cdOffset;
  for (let i = 0; i < total; i++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) break;
    const method = buf.readUInt16LE(p + 10);
    const compSize = buf.readUInt32LE(p + 20);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    const localOff = buf.readUInt32LE(p + 42);
    const name = buf.subarray(p + 46, p + 46 + nameLen).toString('utf8');
    const lNameLen = buf.readUInt16LE(localOff + 26);
    const lExtraLen = buf.readUInt16LE(localOff + 28);
    const start = localOff + 30 + lNameLen + lExtraLen;
    const raw = buf.subarray(start, start + compSize);
    if (method === 0) entries[name] = raw.toString('utf8');
    p += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

function epubParse(buf, fallbackTitle = 'unnamed') {
  const files = readZipStored(buf);
  const container = files['META-INF/container.xml'] || '';
  const opfPath = (container.match(/full-path\s*=\s*"([^"]+)"/) || [, null])[1];
  assert(opfPath, 'container.xml 里应能找到 rootfile');
  const opf = files[opfPath];
  assert(opf, 'OPF 文件应存在');

  const title = (opf.match(/<dc:title[^>]*>(.*?)<\/dc:title>/) || [, fallbackTitle])[1];
  const author = (opf.match(/<dc:creator[^>]*>(.*?)<\/dc:creator>/) || [, ''])[1];
  const summary = (opf.match(/<dc:description[^>]*>(.*?)<\/dc:description>/) || [, ''])[1];

  const manifest = {};
  for (const m of opf.matchAll(/<item\b[^>]*>/gi)) {
    const tag = m[0];
    const id = (tag.match(/id\s*=\s*"([^"]+)"/) || [, null])[1];
    const href = (tag.match(/href\s*=\s*"([^"]+)"/) || [, null])[1];
    if (id && href) manifest[id] = href;
  }
  const spine = [...opf.matchAll(/<itemref\b[^>]*>/gi)]
    .map((m) => (m[0].match(/idref\s*=\s*"([^"]+)"/) || [, null])[1])
    .filter(Boolean);

  const opfDir = opfPath.includes('/') ? opfPath.slice(0, opfPath.lastIndexOf('/')) : '';
  const navTitles = {};
  const nav = files[`${opfDir}/nav.xhtml`] || '';
  for (const m of nav.matchAll(/<a\b[^>]*href\s*=\s*"([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi)) {
    navTitles[m[1]] = htmlToPlainText(m[2]);
  }

  const chapters = [];
  for (const idref of spine) {
    const href = manifest[idref];
    if (!href) continue;
    const full = opfDir ? `${opfDir}/${href}` : href;
    const html = files[full] ?? files[href];
    if (!html) continue;
    const text = htmlToPlainText(html);
    if (!text) continue;
    const heading = (html.match(/<h[1-3][^>]*>([\s\S]*?)<\/h[1-3]>/i) || [, ''])[1];
    chapters.push({
      title: navTitles[href] || htmlToPlainText(heading) || `第${chapters.length + 1}节`,
      content: normalizeBody(text),
    });
  }
  return { title: htmlToPlainText(title), author: htmlToPlainText(author), summary, chapters };
}

// ────────────────────────────────────────────────────────────
// 7. 执行验证
// ────────────────────────────────────────────────────────────

section('1. 章节标题识别');
check('识别"第一章 上山"', () => assert(isChapterTitle('第一章 上山')));
check('识别"第一百二十三章"', () => assert(isChapterTitle('第一百二十三章')));
check('识别"正文 第12章 试探"', () => assert(isChapterTitle('正文 第12章 试探')));
check('识别"Chapter 3 - The Road"', () => assert(isChapterTitle('Chapter 3 - The Road')));
check('识别"楔子"', () => assert(isChapterTitle('楔子')));
check('识别"【第7章】归墟"', () => assert(isChapterTitle('【第7章】归墟')));
check('识别"（第7章）"', () => assert(isChapterTitle('（第7章）')));
check('识别"卷三 第12章 归途"', () => assert(isChapterTitle('卷三 第12章 归途')));
check('不把普通句子当章节', () => assert(!isChapterTitle('他走了很久，还是没有看到人。')));
check('不把长段落当章节', () => assert(!isChapterTitle('第一章里他做了很多事情'.repeat(6))));
check('不把"第一次见面"当章节', () => assert(!isChapterTitle('第一次见面的时候他就这样')));

section('2. 广告行清洗');
check('识别"本章未完，请收藏本站"', () => assert(isJunkLine('本章未完，请收藏本站，首发地址 www.example.com')));
check('识别纯网址行', () => assert(isJunkLine('https://example.com/book/123')));
check('识别分隔符行', () => assert(isJunkLine('────────────')));
check('正常正文不误删', () => assert(!isJunkLine('他把灯往旁边挪了半寸。')));
check('短句"走了。"不误删', () => assert(!isJunkLine('走了。')));

section('3. 正文归一与缩进');
check('压缩连续空行', () => assertEq(normalizeBody('甲\n\n\n\n乙'), '甲\n\n乙'));
check('全角空格转半角缩进', () => assertEq(normalizeBody('　　第一段'), '  第一段'));
check('自动补缩进', () => assertEq(applyIndent('第一段\n第二段\n第三段'), '  第一段\n  第二段\n  第三段'));
check('已有缩进不重复添加', () => {
  const src = '  甲\n  乙\n  丙';
  assertEq(applyIndent(src), src);
});

section('4. TXT 分章全链路');
const fixtureTxt = makeFixtureTxt();
const chapters = splitChapters(fixtureTxt, '雾隐山');
check('切出 3 章', () => assertEq(chapters.length, 3, `实际 ${chapters.length} 章: ${chapters.map((c) => c.title).join(' | ')}`));
check('第一章标题正确', () => assertEq(chapters[0].title, '第一章 上山'));
check('第二章标题正确', () => assertEq(chapters[1].title, '第二章 灯'));
check('第三章标题正确', () => assertEq(chapters[2].title, '第三章 归途'));
check('第一章正文不含广告行', () => {
  assert(!chapters[0].content.includes('本章未完'), '广告行没被清掉');
  assert(!chapters[0].content.includes('www.example.com'), '网址没被清掉');
});
check('第一章正文内容完整', () => {
  assert(chapters[0].content.includes('夜色沉下来的时候'), '丢了开头');
  assert(chapters[0].content.includes('第一百级的台阶上落着一片枯叶'), '丢了结尾');
});
check('第二章正文正确', () => assert(chapters[1].content.includes('灯芯哔剥响了一声')));
check('文件头元信息不生成"前言"章节', () => {
  assert(!chapters.some((c) => c.title === '前言'), `不应有前言：${chapters.map((c) => c.title).join(' | ')}`);
});
check('文件名解析：书名 - 作者', () => {
  const r = parseFileNameTitle('雾隐山 - 林晚.txt');
  assertEq(r.title, '雾隐山'); assertEq(r.author, '林晚');
});
check('文件名解析：《书名》作者', () => {
  const r = parseFileNameTitle('《雪线之上》沈舟.txt');
  assertEq(r.title, '雪线之上'); assertEq(r.author, '沈舟');
});
check('文件名解析：[作者]书名', () => {
  const r = parseFileNameTitle('[刘慈欣]三体.epub');
  assertEq(r.title, '三体'); assertEq(r.author, '刘慈欣');
});
check('无章节标记时按字数硬切', () => {
  const body = '这是一段没有章节标记的长文本，用来测试硬切逻辑是否生效。'.repeat(400);
  const total = [...body].length;                 // 11200
  const res = splitChapters(body, '无名');
  assert(res.length >= 2, `11200 字按 6000 一段应至少切 2 段，实际 ${res.length}`);
  const sum = res.reduce((acc, c) => acc + [...c.content].length, 0);
  // 允许因空行/标点处理产生的少量差异
  assert(Math.abs(sum - total) < total * 0.1, `字数丢失过多：原文 ${total}，切后 ${sum}`);
  assert(res.every((c) => c.content.length > 0), '存在空章节');
});
check('硬切后的分段长度不超过上限', () => {
  const body = '这是一段没有章节标记的长文本，用来测试硬切逻辑是否生效。'.repeat(2000); // 56000 字
  const res = splitChapters(body, '超长');
  assert(res.length >= 9, `56000 字应切成 9 段以上，实际 ${res.length}`);
  for (const c of res) {
    const n = [...c.content].length;
    // 单段可能因一句超长而略超上限，放宽到 1.3 倍
    assert(n <= 30000 * 1.3, `分段过长：${n} 字`);
  }
});
check('无换行文本按句号硬切', () => {
  const body = '第一句话说完了。第二句话也说完了！第三句话呢？'.repeat(300);
  const res = splitChapters(body, '无名2');
  assert(res.length >= 2, `应至少切 2 段，实际 ${res.length}`);
});

section('5. 编码探测');
check('UTF-8 正确识别', () => {
  const r = decodeAuto(Buffer.from('中文内容测试', 'utf8'));
  assertEq(r.encoding, 'utf-8');
  assertEq(r.text, '中文内容测试');
});
check('UTF-8 BOM 剥离', () => {
  const r = decodeAuto(Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from('带BOM', 'utf8')]));
  assertEq(r.encoding, 'utf-8-bom');
  assertEq(r.text, '带BOM');
});
check('GBK 字节不被误判为 UTF-8', () => {
  const gbk = Buffer.from([0xd6, 0xd0, 0xce, 0xc4]); // "中文" 的 GBK
  assert(!isValidUTF8(gbk), 'GBK 字节被误判为合法 UTF-8');
  assertEq(decodeAuto(gbk).encoding, 'gb18030');
});
check('非法 UTF-8 序列被拒绝', () => {
  assert(!isValidUTF8(Buffer.from([0xe4, 0xb8, 0x41])));
  assert(!isValidUTF8(Buffer.from([0xff, 0xfe, 0x00])));
});

section('6. HTML → 纯文本');
const sampleHTML = `<!DOCTYPE html><html><head><title>测试页</title>
<style>body{color:red}</style></head><body>
<div id="content">
  <p>第一段：风从垭口灌下来。</p>
  <p>第二段&nbsp;含&nbsp;实体&amp;符号。</p>
  <div class="ads"><a href="http://ad.example.com">这是广告</a></div>
  <p>第三段：他按下对讲机。</p>
</div>
<script>console.log('脚本不该出现')</script>
</body></html>`;
check('段落正确分行', () => {
  const text = htmlToPlainText(sampleHTML);
  assert(text.includes('第一段'), '缺第一段');
  assert(text.includes('第三段'), '缺第三段');
  assert(text.indexOf('第一段') < text.indexOf('第三段'), '顺序错误');
});
check('script/style 被移除', () => {
  const text = htmlToPlainText(sampleHTML);
  assert(!text.includes('脚本不该出现'), 'script 内容泄漏');
  assert(!text.includes('color:red'), 'style 内容泄漏');
});
check('HTML 实体解码', () => assertEq(htmlToPlainText('<p>A&nbsp;B&amp;C&mdash;D&#26085;</p>'), 'A B&C—D日'));
check('CSS 规则抽取正文容器', () => {
  const text = extractContent(sampleHTML, '#content', ['.ads']);
  assert(text.includes('第一段'), '缺第一段');
  assert(!text.includes('这是广告'), '广告块没被移除');
});
check('CSS 规则抽取 class 容器', () => {
  const html = '<div class="chapter-c"><p>正文一</p><p>正文二</p></div><div class="other">其他</div>';
  const text = extractContent(html, 'div.chapter-c');
  assert(text.includes('正文一'), '缺正文一');
  assert(!text.includes('其他'), '抓到了错误的容器');
});

section('7. EPUB 解析链路（自建 stored zip）');
const epub = epubParse(makeEPUB(), 'unnamed');
check('读到 dc:title', () => assertEq(epub.title, '雪线之上'));
check('读到 dc:creator', () => assertEq(epub.author, '沈舟'));
check('读到 dc:description', () => assert(epub.summary.includes('高原救援队')));
check('spine 解析出 2 章', () => assertEq(epub.chapters.length, 2, `实际 ${epub.chapters.length}`));
check('章节标题取自 nav.xhtml', () => {
  assertEq(epub.chapters[0].title, '第一章 暴风雪');
  assertEq(epub.chapters[1].title, '第二章 撤离');
});
check('章节正文正确', () => {
  assert(epub.chapters[0].content.includes('帐篷的支架'), '第一章正文错误');
  assert(epub.chapters[1].content.includes('先送伤员'), '第二章正文错误');
});

section('8. OPDS 条目解析');
const opdsFeed = `<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>我的 NAS 书库</title>
  <entry>
    <title>雾隐山</title>
    <author><name>林晚</name></author>
    <content type="text">一个关于登山者的故事。</content>
    <link rel="http://opds-spec.org/image" href="/covers/1.jpg" type="image/jpeg"/>
    <link rel="http://opds-spec.org/acquisition" href="/books/1.epub" type="application/epub+zip"/>
    <link rel="http://opds-spec.org/acquisition" href="/books/1.txt" type="text/plain"/>
  </entry>
  <entry>
    <title>雪线之上</title>
    <author><name>沈舟</name></author>
    <link rel="http://opds-spec.org/acquisition" href="/books/2.txt" type="text/plain"/>
  </entry>
  <entry>
    <title>分类：武侠</title>
    <link rel="subsection" href="/opds/wuxia" type="application/atom+xml;profile=opds-catalog"/>
  </entry>
</feed>`;
const opdsEntries = parseOPDSEntries(opdsFeed);
check('解析出 3 个条目', () => assertEq(opdsEntries.length, 3));
check('优先选择 epub 作为下载链接', () => {
  assertEq(opdsEntries[0].href, '/books/1.epub');
  assertEq(opdsEntries[0].kind, 'book');
});
check('封面地址正确', () => assertEq(opdsEntries[0].cover, '/covers/1.jpg'));
check('作者解析正确', () => assertEq(opdsEntries[0].author, '林晚'));
check('导航条目识别为目录', () => {
  assertEq(opdsEntries[2].kind, 'directory');
  assertEq(opdsEntries[2].href, '/opds/wuxia');
});

section('9. 规则书源：搜索结果解析');
const searchHTML = `
<ul class="result-list">
  <li><div class="result-item"><h3><a href="/book/101">雾隐山</a></h3><span class="author">林晚</span></div></li>
  <li><div class="result-item"><h3><a href="/book/102">雪线之上</a></h3><span class="author">沈舟</span></div></li>
</ul>`;
check('提取 2 条搜索结果的标题与链接', () => {
  const items = searchHTML.match(/<div class="result-item">[\s\S]*?<\/h3>[\s\S]*?<\/div>/g) || [];
  assert(items.length >= 2, `应找到 2 条，实际 ${items.length}`);
  const titles = items.map((i) => htmlToPlainText((i.match(/<a[^>]*>([\s\S]*?)<\/a>/) || [, ''])[1]));
  assertEq(titles.join(','), '雾隐山,雪线之上');
  const hrefs = items.map((i) => (i.match(/href="([^"]+)"/) || [, ''])[1]);
  assertEq(hrefs.join(','), '/book/101,/book/102');
});

section('10. 相对地址解析');
check('相对路径拼接', () => {
  assertEq(new URL('/books/1.epub', 'http://192.168.1.10:8083/opds').href,
    'http://192.168.1.10:8083/books/1.epub');
});
check('协议相对地址', () => {
  assertEq(new URL('//cdn.example.com/a.jpg', 'https://example.com/x').href,
    'https://cdn.example.com/a.jpg');
});
check('baseURL 规范化去尾斜杠', () => {
  let s = 'http://192.168.1.10:8083/opds/';
  if (s.endsWith('/')) s = s.slice(0, -1);
  assertEq(s, 'http://192.168.1.10:8083/opds');
});

// ────────────────────────────────────────────────────────────
// 8. 写出 fixture
// ────────────────────────────────────────────────────────────

section('11. 生成测试文件');
const fixtureDir = resolve(__dirname, 'fixtures');
if (!existsSync(fixtureDir)) mkdirSync(fixtureDir, { recursive: true });

check('写出 雾隐山 - 林晚.txt', () => {
  writeFileSync(resolve(fixtureDir, '雾隐山 - 林晚.txt'), makeFixtureTxt(), 'utf8');
});
check('写出 雪线之上.epub', () => {
  writeFileSync(resolve(fixtureDir, '雪线之上.epub'), makeEPUB());
});
check('写出 广告干扰测试.txt', () => {
  const junk = [
    '第一章 试读',
    '　　正文第一段。',
    '笔趣阁 www.example-site.com 最新章节请访问本站',
    '　　正文第二段，需要足够长以免被当成空章合并掉。',
    '一秒记住本站：m.example-site.com',
    '　　正文第三段，继续填充内容让这一章超过四十个字符。',
    '第二章 继续',
    '　　正文第四段。',
    '手机用户请浏览 m.example-site.com 阅读更优质的章节',
    '　　正文第五段，同样需要足够的长度来保证章节不被合并。',
  ].join('\n');
  writeFileSync(resolve(fixtureDir, '广告干扰测试.txt'), junk, 'utf8');
});
check('写出 GBK编码样本.txt', () => {
  // "第一章" + 换行，GBK 编码
  const gbkMap = { '第': [0xb5, 0xda], '一': [0xd2, 0xbb], '章': [0xd5, 0xc2] };
  const bytes = [];
  for (const ch of '第一章') bytes.push(...gbkMap[ch]);
  writeFileSync(resolve(fixtureDir, 'GBK编码样本.txt'), Buffer.from(bytes));
});
check('写出 fixtures/README.txt', () => {
  writeFileSync(resolve(fixtureDir, 'README.txt'), [
    '把这些文件拖进「文件」App → 我的 iPhone → 书虫 → Inbox，',
    '或直接从「书架 → + → 从文件导入」选择，用来验证解析链路。',
    '',
    '雾隐山 - 林晚.txt     : 标准中文小说，含元信息头和广告行',
    '雪线之上.epub        : 最小可解析 EPUB（2 章）',
    '广告干扰测试.txt      : 含盗版站广告行，验证清洗',
    'GBK编码样本.txt      : GBK 字节，验证编码探测',
  ].join('\n'), 'utf8');
});

// ────────────────────────────────────────────────────────────
// 汇总
// ────────────────────────────────────────────────────────────

console.log(`\n${'─'.repeat(52)}`);
if (failed === 0) {
  console.log(`\x1b[32m全部通过：${passed} 项\x1b[0m`);
} else {
  console.log(`\x1b[31m失败 ${failed} 项\x1b[0m / 通过 ${passed} 项`);
  for (const f of failures) console.log(`  - ${f.name}: ${f.err.message.split('\n')[0]}`);
  process.exitCode = 1;
}
