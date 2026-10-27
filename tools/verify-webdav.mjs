#!/usr/bin/env node
/**
 * verify-webdav.mjs
 *
 * 验证 WebDAV 浏览与下载的 URL 拼接链路。
 *
 * 背景：用户报告「WebDAV 能列出书目，但下载报 404」。
 * 列表用 PROPFIND，下载走 fetchData → HTTPClient.resolve。
 * 两条路径如果对 href 的处理不一致，就会出现列表正常、下载 404。
 *
 * 运行： node tools/verify-webdav.mjs
 */

let passed = 0, failed = 0;
const failures = [];
function check(name, fn) {
  try { fn(); passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
  catch (e) { failed++; failures.push([name, e]); console.log(`  \x1b[31m✗\x1b[0m ${name}\n      ${e.message}`); }
}
function assert(c, m) { if (!c) throw new Error(m || 'assert'); }
function assertEq(a, b, m) { if (a !== b) throw new Error(`${m || 'not equal'}:\n        expected ${JSON.stringify(b)}\n        actual   ${JSON.stringify(a)}`); }
function section(t) { console.log(`\n\x1b[1m${t}\x1b[0m`); }

// ═══════════════════════════════════════════════
// 复刻 Swift 的 HTTPClient.resolve 语义（修正后版本）
// ═══════════════════════════════════════════════
function swiftResolve(href, base) {
  const trimmed = (href ?? '').trim();
  if (!trimmed) return null;
  const lower = trimmed.toLowerCase();

  // 1. 完整 URL：原样返回，不重新编码
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    try { return new URL(trimmed).href; } catch { return null; }
  }
  // 2. 协议相对
  if (lower.startsWith('//')) {
    const scheme = base && base.toLowerCase().startsWith('https') ? 'https:' : 'http:';
    return scheme + trimmed;
  }
  if (!base) return null;
  const baseURL = new URL(base);

  // 3. 绝对路径：只借用 origin
  if (trimmed.startsWith('/')) {
    const origin = new URL(baseURL.origin);
    return new URL(trimmed, origin).href;
  }
  // 4. 相对路径：给 base 补尾斜杠
  let baseString = base;
  if (!baseString.endsWith('/')) baseString += '/';
  try { return new URL(trimmed, baseString).href; } catch { return null; }
}

// ═══════════════════════════════════════════════
// 复刻 fetchWebDAV 的 href → itemURL 三分支
// ═══════════════════════════════════════════════
function webdavItemURL(decodedHref, targetHref) {
  const target = new URL(targetHref);
  if (decodedHref.toLowerCase().startsWith('http')) {
    return decodedHref;
  }
  if (decodedHref.startsWith('/')) {
    const u = new URL(target.origin);
    u.pathname = decodedHref;
    u.search = '';
    return u.href;
  }
  return new URL(decodedHref, target).href;
}

// ═══════════════════════════════════════════════
section('1. baseURL 无尾斜杠时的相对解析（经典 404 来源）');
{
  // 用户在「新增书源」里填的 baseURL 通常是 http://nas:5005/webdav
  const base = 'http://nas:5005/webdav';
  check('相对路径 a.txt 自动补尾斜杠，不会丢段', () => {
    const r = swiftResolve('a.txt', base);
    assertEq(r, 'http://nas:5005/webdav/a.txt',
      '修正前会得到 http://nas:5005/a.txt —— 这就是 404 的根因');
  });
  check('base 已带尾斜杠时行为一致', () => {
    const r = swiftResolve('a.txt', base + '/');
    assertEq(r, 'http://nas:5005/webdav/a.txt');
  });
  check('绝对路径只借用 origin', () => {
    const r = swiftResolve('/webdav/a.txt', base);
    assertEq(r, 'http://nas:5005/webdav/a.txt');
  });
  check('绝对路径不会与 base path 重复拼接', () => {
    const r = swiftResolve('/webdav/books/a.txt', 'http://nas:5005/webdav/books');
    assertEq(r, 'http://nas:5005/webdav/books/a.txt');
    assert(!r.includes('/webdav/books/webdav'), `出现重复段: ${r}`);
  });
}

section('1b. 完整 URL 不做二次编码（另一类 404）');
{
  check('%2F 不会被二次编码成 %252F', () => {
    const u = 'http://nas:5005/dav/a%2Fb.txt';
    const r = swiftResolve(u, 'http://nas:5005/dav');
    assert(!r.includes('%252F'), `被二次编码: ${r}`);
  });
  check('已编码的中文路径保持原样', () => {
    const u = 'http://nas:5005/dav/%E9%9B%AA%E7%BA%BF.txt';
    const r = swiftResolve(u, 'http://nas:5005/dav');
    assertEq(r, u);
  });
  check('带签名查询参数不被改动', () => {
    const u = 'http://nas:5005/dav/a.txt?X-Sig=abc%2Bdef%3D';
    const r = swiftResolve(u, 'http://nas:5005/dav');
    assert(r.includes('X-Sig=abc%2Bdef%3D'), `签名被改: ${r}`);
  });
}

section('2. href 形态覆盖（Nextcloud / 群晖 / 通用 WebDAV）');
{
  const target = 'http://nas:5005/webdav/books/';
  const cases = [
    ['Nextcloud 绝对路径', '/remote.php/dav/files/user/books/a.txt', 'http://nas:5005/remote.php/dav/files/user/books/a.txt'],
    ['群晖绝对路径',       '/webdav/books/a.txt',                     'http://nas:5005/webdav/books/a.txt'],
    ['完整 URL',           'http://nas:5005/webdav/books/a.txt',      'http://nas:5005/webdav/books/a.txt'],
    ['相对路径',           'a.txt',                                    'http://nas:5005/webdav/books/a.txt'],
    ['相对子目录',         'sub/b.txt',                                'http://nas:5005/webdav/books/sub/b.txt'],
  ];
  for (const [label, href, expect] of cases) {
    check(label, () => assertEq(webdavItemURL(href, target), expect));
  }
}

section('3. 中文与空格文件名');
{
  const target = 'http://nas:5005/webdav/books/';
  check('百分号编码的 href 解码后能还原', () => {
    const raw = '/webdav/books/%E9%9B%AA%E7%BA%BF%E4%B9%8B%E4%B8%8A.txt';
    const decoded = decodeURIComponent(raw);
    assertEq(decoded, '/webdav/books/雪线之上.txt');
    const url = webdavItemURL(decoded, target);
    // 生成 URL 时应重新编码
    assert(url.includes('%E9%9B%AA'), `未重新编码: ${url}`);
  });
  check('含空格的文件名', () => {
    const url = webdavItemURL('/webdav/books/a b.txt', target);
    assert(url.includes('a%20b.txt') || url.includes('a b.txt'), `异常: ${url}`);
  });
}

section('4. WebDAV XML 解析');
{
  const xml = `<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/webdav/books/</D:href>
    <D:propstat><D:prop>
      <D:displayname>books</D:displayname>
      <D:resourcetype><D:collection/></D:resourcetype>
    </D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/webdav/books/%E9%9B%AA%E7%BA%BF%E4%B9%8B%E4%B8%8A.txt</D:href>
    <D:propstat><D:prop>
      <D:displayname>雪线之上.txt</D:displayname>
      <D:getcontentlength>1773</D:getcontentlength>
      <D:resourcetype/>
    </D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/webdav/books/sub/</D:href>
    <D:propstat><D:prop>
      <D:displayname>sub</D:displayname>
      <D:resourcetype><D:collection/></D:resourcetype>
    </D:prop></D:propstat>
  </D:response>
</D:multistatus>`;

  const blocks = [...xml.matchAll(/<[dD]:response\b[\s\S]*?<\/[dD]:response>/g)].map((m) => m[0]);
  check('解析出 3 个 response', () => assertEq(blocks.length, 3));

  const parsed = blocks.map((b) => {
    const href = (/<[dD]:href[^>]*>([\s\S]*?)<\/[dD]:href>/.exec(b) || [, ''])[1].trim();
    const name = (/<[dD]:displayname[^>]*>([\s\S]*?)<\/[dD]:displayname>/.exec(b) || [, ''])[1].trim();
    const isCollection = /collection/i.test(b);
    return { href, name, isCollection };
  });

  check('自身目录被识别为 collection', () => assert(parsed[0].isCollection));
  check('文件名显示名正确', () => assertEq(parsed[1].name, '雪线之上.txt'));
  check('文件不是 collection', () => assert(!parsed[1].isCollection));
  check('子目录被识别', () => assert(parsed[2].isCollection && parsed[2].name === 'sub'));

  // 自跳过逻辑：trim 后比较
  const selfPath = '/webdav/books/'.replace(/^\/+|\/+$/g, '');
  check('自身路径 trim 后比较能跳过', () => {
    const itemPath = parsed[0].href.replace(/^\/+|\/+$/g, '');
    assertEq(itemPath, selfPath);
  });
}

section('5. 下载链路：列表 href 必须能直接喂给 fetchData');
{
  const base = 'http://nas:5005/webdav';
  const target = base + '/';
  const listHref = webdavItemURL('/webdav/books/a.txt', target);

  check('列表产出的是完整 URL', () => {
    assert(listHref.startsWith('http://'), `不是完整 URL: ${listHref}`);
  });
  check('完整 URL 再过一次 resolve 不会变形', () => {
    const again = swiftResolve(listHref, base);
    assertEq(again, listHref, '如果这里变形，下载就会 404');
  });
  check('文件扩展名可识别', () => {
    const ext = listHref.split('.').pop().toLowerCase();
    assert(['txt', 'epub', 'html', 'htm'].includes(ext), `扩展名异常: ${ext}`);
  });
}

section('6. baseURL 规范化');
{
  // normalizeBase 应该补 scheme、去尾斜杠
  function normalizeBase(raw) {
    let s = (raw ?? '').trim();
    if (!s) return null;
    if (!/^https?/i.test(s)) s = 'http://' + s;
    try {
      const u = new URL(s);
      let str = u.href;
      if (str.endsWith('/')) str = str.slice(0, -1);
      return str;
    } catch { return null; }
  }
  check('补 http://', () => assertEq(normalizeBase('nas:5005/webdav'), 'http://nas:5005/webdav'));
  check('去尾斜杠', () => assertEq(normalizeBase('http://nas:5005/webdav/'), 'http://nas:5005/webdav'));
  check('保留 https', () => assertEq(normalizeBase('https://nas:5006/dav'), 'https://nas:5006/dav'));
  check('空输入返回 null', () => assertEq(normalizeBase(''), null));
}

// ═══════════════════════════════════════════════
console.log(`\n${'─'.repeat(56)}`);
if (failed === 0) console.log(`\x1b[32m全部通过：${passed} 项\x1b[0m`);
else {
  console.log(`\x1b[31m失败 ${failed} 项\x1b[0m / 通过 ${passed} 项`);
  for (const [n, e] of failures) console.log(`  - ${n}\n    ${e.message}`);
  process.exitCode = 1;
}
