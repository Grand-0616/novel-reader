#!/usr/bin/env node
/**
 * verify-e2e.mjs
 *
 * 端到端模拟：把 ImportService + Store 的落库流程用 Node 复刻，
 * 用真实 fixture 走一遍"文件 → 解析 → 章节切分 → 写缓存 → 读回"，
 * 验证最终用户拿到的东西是对的。
 *
 * 运行： node tools/verify-e2e.mjs
 */

import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { inflateRawSync } from 'node:zlib';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURES = resolve(__dirname, 'fixtures');
const SANDBOX = resolve(__dirname, '.e2e-sandbox');

let passed = 0, failed = 0;
const failures = [];
function check(name, fn) {
  try { fn(); passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
  catch (e) { failed++; failures.push([name, e]); console.log(`  \x1b[31m✗\x1b[0m ${name}\n      ${e.message}`); }
}
function assert(c, m) { if (!c) throw new Error(m || 'assert'); }
function assertEq(a, b, m) { if (a !== b) throw new Error(`${m||'not equal'}: expected ${JSON.stringify(b)}, actual ${JSON.stringify(a)}`); }
function section(t) { console.log(`\n\x1b[1m${t}\x1b[0m`); }

// ═══════════════════════════════════════════════════
// 从 verify-core.mjs 复用的核心算法（保持同步）
// ═══════════════════════════════════════════════════

const CHAPTER_PATTERNS = [
  /^\s{0,4}[【（(]\s*第\s*[0-9０-９零一二三四五六七八九十百千万两]{1,12}\s*[章节回卷]\s*[】）)][^。！？；]{0,40}$/,
  /^\s{0,8}第\s*[0-9０-９零一二三四五六七八九十百千万两]{1,12}\s*[章节回卷折幕话篇](?:\s|：|:|[^。！？；\n]{0,60})$/,
  /^\s{0,8}正文\s*第\s*[0-9零一二三四五六七八九十百千万两]{1,12}\s*[章节回](?:\s|：|:|\s*[\S]){0,80}$/,
  /^\s{0,8}[卷部]\s*[0-9零一二三四五六七八九十百千万两]{1,6}\s*第\s*[0-9零一二三四五六七八九十百千万两]{1,12}\s*[章节回][^。！？；]{0,60}$/,
  /^\s{0,8}chapter\s*[0-9ivxlcdm]{1,8}\b.{0,80}$/i,
  /^\s{0,8}(?:序章|序言|序|楔子|引子|前言|尾声|后记|终章|大结局|番外[一二三四五六七八九十0-9]*)\s*.{0,40}$/,
];
function isChapterTitle(line) {
  const t = line.trim();
  if (!t || [...t].length > 60) return false;
  if (t.includes('。') && [...t].length > 24) return false;
  return CHAPTER_PATTERNS.some((r) => r.test(t));
}

const JUNK = ['本章未完','请收藏本站','请记住本书','首发地址','最新章节请','手机阅读','手机用户请',
  '百度搜索','笔趣阁','www.','http://','https://','天才一秒记住','更新最快','无弹窗','广告',
  '加入书签','投推荐票','一秒记住本站','章节错误','举报后维护','内容严重缺失','红色字体',
  '推荐一个app','你可以用','本站域名','顶点小说','书趣阁'];
function isJunkLine(line) {
  const t = line.trim();
  if (t.length <= 2) return false;
  if ([...t].every((c) => '-=_*~·—─═　 '.includes(c))) return true;
  const lower = t.toLowerCase();
  return JUNK.some((m) => lower.includes(m.toLowerCase()));
}

function normalizeBody(raw) {
  let s = raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\u00a0/g, ' ')
    .replace(/\u3000/g, '  ').replace(/\ufeff/g, '');
  const lines = []; let blankRun = 0;
  for (const rawLine of s.split('\n')) {
    const line = rawLine.replace(/[ \t]{2,}/g, '  ');
    const t = line.trim();
    if (!t) { blankRun++; if (blankRun > 1) continue; lines.push(''); }
    else { blankRun = 0; lines.push(isJunkLine(t) ? '' : line); }
  }
  while (lines.length && !lines[lines.length-1].trim()) lines.pop();
  while (lines.length && !lines[0].trim()) lines.shift();
  return lines.join('\n');
}

function applyIndent(body) {
  const lines = body.split('\n');
  let ind = 0, tot = 0;
  for (const l of lines) { if (!l.trim()) continue; tot++; if (l.startsWith('  ') || l.startsWith('\t')) ind++; }
  if (tot === 0 || ind / tot >= 0.6) return body;
  return lines.map((l) => { const t = l.trim(); return t ? '  ' + t : ''; }).join('\n');
}

const MIN_CHAPTER = 40, MAX_CHAPTER = 30000;

function isRealPreamble(text) {
  const t = text.trim();
  if ([...t].length < 200) return false;
  const lines = t.split('\n').map((l) => l.trim()).filter(Boolean);
  const meta = ['书名','作者','简介','内容简介','分类','状态','字数','更新时间','最新章节','来源','网址','声明','版权'];
  let m = 0, p = 0;
  for (const l of lines) {
    if (meta.some((x) => l.startsWith(x)) && [...l].length <= 40) m++;
    else if (l.includes('http') || l.includes('www.')) m++;
    else if ([...l].length > 12) p++;
  }
  return p >= 3 && p > m * 2;
}

function hardSplit(body, bookTitle) {
  let paras = body.split('\n').map((p) => p.trim()).filter(Boolean);
  if (paras.length <= 1) {
    const pieces = []; let cur = '';
    for (const ch of body) {
      cur += ch;
      if ('。！？…\n'.includes(ch)) { const t = cur.trim(); if (t) pieces.push(t); cur = ''; }
    }
    const t = cur.trim(); if (t) pieces.push(t);
    paras = pieces;
  }
  const out = []; let buf = [], len = 0, part = 1;
  const flush = () => {
    if (!buf.length) return;
    out.push({ title: `${bookTitle} - 第${part}节`, content: normalizeBody(buf.join('\n')) });
    buf = []; len = 0; part++;
  };
  for (const p of paras) { buf.push(p); len += [...p].length + 1; if (len >= 6000) flush(); }
  flush();
  return out;
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
  const norm = raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const chapters = [];
  let title = bookTitle, buffer = [], hasTitle = false;
  const flush = () => {
    const body = normalizeBody(buffer.join('\n'));
    buffer = [];
    if (!body) return;
    if (chapters.length && [...body].length < MIN_CHAPTER && !looksLikeProse(body)) {
      const last = chapters.pop();
      chapters.push({ title: last.title, content: last.content + '\n\n' + body });
      return;
    }
    chapters.push({ title, content: body });
  };
  for (const rawLine of norm.split('\n')) {
    const line = rawLine.trim();
    if (line && [...line].length <= 60 && isChapterTitle(line)) {
      if (!hasTitle) {
        const pre = normalizeBody(buffer.join('\n'));
        buffer = [];
        if (isRealPreamble(pre)) chapters.push({ title: '前言', content: pre });
        title = line; hasTitle = true; continue;
      }
      flush(); title = line; buffer = [];
    } else buffer.push(rawLine);
  }
  flush();
  if (!hasTitle) { const b = normalizeBody(norm); return b ? hardSplit(b, bookTitle) : []; }
  if (!chapters.length) { const b = normalizeBody(norm); return b ? hardSplit(b, bookTitle) : []; }
  return chapters;
}

function decodeAuto(buf) {
  if (buf.length >= 3 && buf[0]===0xef && buf[1]===0xbb && buf[2]===0xbf)
    return { text: new TextDecoder('utf-8').decode(buf.subarray(3)), encoding: 'utf-8-bom' };
  // 严格 UTF-8 校验
  let i = 0, ok = true;
  while (i < buf.length) {
    const b = buf[i];
    if (b < 0x80) { i++; continue; }
    let need = 0;
    if ((b & 0xe0) === 0xc0) need = 1;
    else if ((b & 0xf0) === 0xe0) need = 2;
    else if ((b & 0xf8) === 0xf0) need = 3;
    else { ok = false; break; }
    if (i + need >= buf.length) { ok = false; break; }
    for (let k = 1; k <= need; k++) if ((buf[i+k] & 0xc0) !== 0x80) { ok = false; break; }
    if (!ok) break;
    i += need + 1;
  }
  if (ok) return { text: new TextDecoder('utf-8').decode(buf), encoding: 'utf-8' };
  try { return { text: new TextDecoder('gb18030').decode(buf), encoding: 'gb18030' }; }
  catch { return { text: new TextDecoder('utf-8', {fatal:false}).decode(buf), encoding: 'gb18030-fallback' }; }
}

// ═══════════════════════════════════════════════════
// ZIP + EPUB
// ═══════════════════════════════════════════════════

function unzip(buf) {
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 65557); i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('不是有效的 ZIP');
  const total = buf.readUInt16LE(eocd + 10);
  const cdOff = buf.readUInt32LE(eocd + 16);
  const files = {};
  let p = cdOff;
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
    files[name] = method === 0 ? raw.toString('utf8') : inflateRawSync(raw).toString('utf8');
    p += 46 + nameLen + extraLen + commentLen;
  }
  return files;
}

function parseEPUB(buf) {
  const files = unzip(buf);
  const container = files['META-INF/container.xml'] || '';
  const opfPath = (container.match(/full-path\s*=\s*"([^"]+)"/) || [, null])[1];
  assert(opfPath, '找不到 OPF');
  const opf = files[opfPath];
  const title = (opf.match(/<dc:title[^>]*>(.*?)<\/dc:title>/) || [, '未命名'])[1];
  const author = (opf.match(/<dc:creator[^>]*>(.*?)<\/dc:creator>/) || [, ''])[1];
  const summary = (opf.match(/<dc:description[^>]*>(.*?)<\/dc:description>/) || [, ''])[1];

  const manifest = {};
  for (const m of opf.matchAll(/<item\b[^>]*>/gi)) {
    const id = (m[0].match(/id\s*=\s*"([^"]+)"/) || [, null])[1];
    const href = (m[0].match(/href\s*=\s*"([^"]+)"/) || [, null])[1];
    if (id && href) manifest[id] = href;
  }
  const spine = [...opf.matchAll(/<itemref\b[^>]*>/gi)]
    .map((m) => (m[0].match(/idref\s*=\s*"([^"]+)"/) || [, null])[1]).filter(Boolean);

  const dir = opfPath.includes('/') ? opfPath.slice(0, opfPath.lastIndexOf('/')) : '';
  const navTitles = {};
  const nav = files[`${dir}/nav.xhtml`] || '';
  for (const m of nav.matchAll(/<a\b[^>]*href\s*=\s*"([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi)) {
    navTitles[m[1]] = htmlToText(m[2]);
  }

  const chapters = [];
  for (const idref of spine) {
    const href = manifest[idref];
    if (!href) continue;
    const full = dir ? `${dir}/${href}` : href;
    const html = files[full] ?? files[href];
    if (!html) continue;
    const text = htmlToText(html);
    if (!text || text.length < 30) continue;
    const h = (html.match(/<h[1-3][^>]*>([\s\S]*?)<\/h[1-3]>/i) || [, ''])[1];
    chapters.push({
      title: navTitles[href] || htmlToText(h) || `第${chapters.length + 1}节`,
      content: applyIndent(normalizeBody(text)),
    });
  }
  return { title: htmlToText(title), author: htmlToText(author), summary, chapters };
}

const ENT = { nbsp:' ',amp:'&',lt:'<',gt:'>',quot:'"',apos:"'",hellip:'…',mdash:'—',ndash:'–',ldquo:'“',rdquo:'”' };
function decodeEnt(s) {
  return s.replace(/&([a-zA-Z]{2,10});/g, (m, n) => ENT[n.toLowerCase()] ?? m)
          .replace(/&#(x?)([0-9a-fA-F]{1,6});/g, (m, h, d) => {
            try { return String.fromCodePoint(parseInt(d, h ? 16 : 10)); } catch { return m; }
          });
}
function htmlToText(html) {
  let s = html;
  for (const t of ['script','style','noscript','svg'])
    s = s.replace(new RegExp(`<${t}[^>]*>[\\s\\S]*?</${t}>`, 'gi'), '');
  s = s.replace(/<!--[\s\S]*?-->/g, '');
  for (const t of ['p','div','br','li','tr','h1','h2','h3','h4','h5','h6','section','article','blockquote','dd','dt','table','ul','ol','hr'])
    s = s.replace(new RegExp(`</?${t}[^>]*>`, 'gi'), '\n');
  s = s.replace(/<[^>]+>/g, '');
  s = decodeEnt(s);
  s = s.replace(/\r\n/g, '\n').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n');
  const out = [];
  for (const raw of s.split('\n')) {
    const l = raw.trim();
    if (!l) { if (out[out.length-1] === '') continue; out.push(''); }
    else out.push(l);
  }
  return out.join('\n').trim();
}

// ═══════════════════════════════════════════════════
// 模拟 Store.insertBook
// ═══════════════════════════════════════════════════

function insertBook(parsed, bookId) {
  const cacheDir = join(SANDBOX, 'ChapterCache', bookId);
  mkdirSync(cacheDir, { recursive: true });

  const book = {
    id: bookId,
    title: parsed.title || '未命名',
    author: parsed.author,
    summary: parsed.summary,
    format: parsed.format,
    chapterCount: 0,
    totalCharacters: 0,
    cachedChapterCount: 0,
    chapters: [],
  };

  parsed.chapters.forEach((ch, idx) => {
    const file = join(cacheDir, String(idx).padStart(5, '0') + '.txt');
    writeFileSync(file, ch.content, 'utf8');
    book.chapters.push({
      index: idx,
      title: ch.title,
      characterCount: [...ch.content].length,
      cachePath: file,
      isCached: true,
    });
    book.cachedChapterCount++;
    book.totalCharacters += [...ch.content].length;
  });

  book.chapterCount = parsed.chapters.length;
  return book;
}

function readChapter(book, index) {
  const ch = book.chapters[index];
  if (!ch) return null;
  return readFileSync(ch.cachePath, 'utf8');
}

// ═══════════════════════════════════════════════════
// 执行
// ═══════════════════════════════════════════════════

if (existsSync(SANDBOX)) rmSync(SANDBOX, { recursive: true });
mkdirSync(SANDBOX, { recursive: true });

section('1. TXT 端到端：雾隐山 - 林晚.txt');
{
  const file = resolve(FIXTURES, '雾隐山 - 林晚.txt');
  const raw = readFileSync(file);
  const decoded = decodeAuto(raw);
  check('编码识别为 UTF-8', () => assertEq(decoded.encoding, 'utf-8'));
  check('书名/作者从文件头解析', () => {
    // 模拟 TXTParser 的元信息抽取
    let author = '', title = '雾隐山';
    for (const line of decoded.text.split('\n').slice(0, 60)) {
      const t = line.trim();
      if (!author && /^作者[：:]/.test(t)) author = t.replace(/^作者[：:]\s*/, '').trim();
      if (/^书名[：:]/.test(t)) title = t.replace(/^书名[：:]\s*/, '').trim();
    }
    assertEq(title, '雾隐山');
    assertEq(author, '林晚');
  });

  const chapters = splitChapters(decoded.text, '雾隐山');
  check('切出 3 章', () => assertEq(chapters.length, 3, `实际 ${chapters.length}: ${chapters.map(c=>c.title).join('|')}`));

  const book = insertBook({ ...decoded, title: '雾隐山', author: '林晚', summary: '', format: 'txt', chapters }, 'book-txt-1');
  check('落库后章节数正确', () => assertEq(book.chapterCount, 3));
  check('总字数 > 0', () => assert(book.totalCharacters > 50, `总字数 ${book.totalCharacters}`));
  check('所有章节已缓存', () => assertEq(book.cachedChapterCount, 3));

  check('读回第一章内容正确', () => {
    const text = readChapter(book, 0);
    assert(text.includes('夜色沉下来的时候'), '缺开头');
    assert(text.includes('枯叶'), '缺结尾');
    assert(!text.includes('本章未完'), '广告未清除');
  });
  check('读回第二章内容正确', () => {
    assert(readChapter(book, 1).includes('灯芯哔剥响了一声'));
  });
  check('章节文件按序号命名', () => {
    assert(book.chapters[0].cachePath.endsWith('00000.txt'));
    assert(book.chapters[2].cachePath.endsWith('00002.txt'));
  });
}

section('2. EPUB 端到端：雪线之上.epub');
{
  const raw = readFileSync(resolve(FIXTURES, '雪线之上.epub'));
  check('ZIP 魔数正确', () => assertEq(raw.subarray(0,2).toString('ascii'), 'PK'));
  const parsed = parseEPUB(raw);
  check('书名解析', () => assertEq(parsed.title, '雪线之上'));
  check('作者解析', () => assertEq(parsed.author, '沈舟'));
  check('简介解析', () => assert(parsed.summary.includes('高原救援队')));
  check('解析出 2 章', () => assertEq(parsed.chapters.length, 2, `实际 ${parsed.chapters.length}`));
  check('章节标题来自 nav', () => {
    assertEq(parsed.chapters[0].title, '第一章 暴风雪');
    assertEq(parsed.chapters[1].title, '第二章 撤离');
  });

  const book = insertBook({ ...parsed, format: 'epub' }, 'book-epub-1');
  check('落库成功', () => assertEq(book.chapterCount, 2));
  check('读回正文正确', () => {
    const t = readChapter(book, 0);
    assert(t.includes('帐篷的支架'), '缺第一章内容');
    assert(!t.includes('<p>'), 'HTML 标签未清除');
  });
}

section('3. GBK 编码端到端');
{
  const raw = readFileSync(resolve(FIXTURES, 'GBK编码样本.txt'));
  check('识别为 GB18030', () => {
    const d = decodeAuto(raw);
    assertEq(d.encoding, 'gb18030');
  });
  check('解码出正确中文', () => {
    const d = decodeAuto(raw);
    assertEq(d.text.trim(), '第一章');
  });
}

section('4. 广告干扰清洗端到端');
{
  const raw = readFileSync(resolve(FIXTURES, '广告干扰测试.txt'));
  const d = decodeAuto(raw);
  const chapters = splitChapters(d.text, '广告测试');
  check('切出 2 章', () => assertEq(chapters.length, 2, `实际 ${chapters.length}: ${chapters.map(c=>c.title).join('|')}`));
  check('正文中不含广告关键词', () => {
    const all = chapters.map((c) => c.content).join('\n');
    for (const junk of ['笔趣阁', '一秒记住本站', '手机用户请浏览', 'example-site.com']) {
      assert(!all.includes(junk), `仍含广告：${junk}`);
    }
  });
  check('正文内容保留', () => {
    const all = chapters.map((c) => c.content).join('\n');
    assert(all.includes('正文第一段'), '正文丢失');
    assert(all.includes('正文第五段'), '正文丢失');
  });

  const book = insertBook({ title: '广告测试', author: '', summary: '', format: 'txt', chapters }, 'book-junk-1');
  check('落库后读回无广告', () => {
    const t = readChapter(book, 0);
    assert(!t.includes('笔趣阁'), '缓存文件里还有广告');
  });
}

section('5. 缓存目录结构');
{
  const { readdirSync } = await import('node:fs');
  const cacheRoot = join(SANDBOX, 'ChapterCache');
  const books = readdirSync(cacheRoot);
  check('每本书一个目录', () => assertEq(books.length, 3, `实际 ${books.length} 个: ${books.join(',')}`));
  check('目录内文件数正确', () => {
    assertEq(readdirSync(join(cacheRoot, 'book-txt-1')).length, 3);
    assertEq(readdirSync(join(cacheRoot, 'book-epub-1')).length, 2);
    assertEq(readdirSync(join(cacheRoot, 'book-junk-1')).length, 2);
  });
  check('文件名为 5 位补零', () => {
    const files = readdirSync(join(cacheRoot, 'book-txt-1')).sort();
    assertEq(files.join(','), '00000.txt,00001.txt,00002.txt');
  });
}

section('6. 进度位置映射');
{
  // 模拟 ReadingPosition：charOffset 必须能映射回正确的页
  const text = '字'.repeat(1000);
  const charsPerLine = 20, linesPerPage = 10, perPage = 200;
  const pages = [];
  for (let loc = 0; loc < text.length; loc += perPage) {
    pages.push({ location: loc, length: Math.min(perPage, text.length - loc) });
  }

  const findPage = (offset) =>
    pages.findIndex((p) => offset >= p.location && offset < p.location + p.length);

  check('偏移 0 在第 0 页', () => assertEq(findPage(0), 0));
  check('偏移 199 仍在第 0 页', () => assertEq(findPage(199), 0));
  check('偏移 200 在第 1 页', () => assertEq(findPage(200), 1));
  check('偏移 999 在最后一页', () => assertEq(findPage(999), 4));
  check('超出范围的偏移返回 -1（调用方需兜底到第 0 页）', () => {
    assertEq(findPage(1000), -1);
  });
}

// ═══════════════════════════════════════════════════
console.log(`\n${'─'.repeat(52)}`);
if (failed === 0) console.log(`\x1b[32m全部通过：${passed} 项\x1b[0m`);
else {
  console.log(`\x1b[31m失败 ${failed} 项\x1b[0m / 通过 ${passed} 项`);
  for (const [n, e] of failures) console.log(`  - ${n}: ${e.message.split('\n')[0]}`);
  process.exitCode = 1;
}
