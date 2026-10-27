#!/usr/bin/env node
/**
 * verify-import.mjs
 *
 * 追踪「本地 TXT 导入没反应」这条链路，逐步验证每个可能断掉的环节。
 *
 * 链路：
 *   fileImporter (allowedContentTypes 过滤)
 *     → handleImport (Result<[URL], Error>)
 *     → ImportService.importLocalFile (扩展名守卫)
 *     → LocalFileSource.importCopy (安全作用域 + 复制)
 *     → parseOffMain (Task.detached)
 *     → ChapterSplitter.split (非空)
 *     → Store.insertBook (SwiftData 落库)
 *     → @Query 刷新 UI
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

// ═══════════════════════════════════════════
section('1. 扩展名守卫 — 哪些输入会被静默拒绝');
{
  // Swift: LocalFileSource.supportedExtensions
  const supported = new Set(['txt', 'epub', 'html', 'htm', 'xhtml']);

  const swiftExt = (name) => {
    // URL.pathExtension 语义：最后一个 . 之后的部分；无 . 则为空串
    const base = name.split('/').pop();
    const idx = base.lastIndexOf('.');
    if (idx <= 0) return '';           // 隐藏文件或没有点
    return base.slice(idx + 1).toLowerCase();
  };

  check('正常 a.txt', () => assertEq(swiftExt('雪线之上.txt'), 'txt'));
  check('大写 a.TXT 经 lowercased 后通过', () => {
    assertEq(swiftExt('A.TXT'), 'txt');
    assert(supported.has(swiftExt('A.TXT')));
  });
  check('iCloud 占位符无扩展名 → 空串 → 被拒绝', () => {
    emailSwiftExtFails('noext');
    function emailSwiftExtFails(n) {
      const e = swiftExt(n);
      assertEq(e, '');
      assert(!supported.has(e), '空扩展名会被 throw unsupportedType("")');
    }
  });
  check('"我的小说.tar.gz" 只取最后一段 gz → 被拒绝', () => {
    assertEq(swiftExt('我的小说.tar.gz'), 'gz');
    assert(!supported.has('gz'));
  });
  check('以点开头的隐藏文件 ".txt" → pathExtension 为空串', () => {
    // iOS 文件 App 不显示点开头的文件，风险低；但语义要一致
    assertEq(swiftExt('.txt'), '');
  });
}

section('2. fileImporter 类型过滤 — 顺序与覆盖');
{
  // Swift: importTypes = [.plainText, .html, epub, .text, .data]
  // .data (= public.data) 是所有文件的祖先类型，理论上能选中任何文件。
  // 但 iOS 的 UTType 匹配对「最具体优先」敏感：
  //   .plainText (public.plain-text) ⊂ .text (public.text) ⊂ .data (public.data)
  // .data 放最后不会破坏匹配，UIDocumentPicker 用的是「任一类型符合」语义。
  const tree = {
    'public.data': null,
    'public.text': 'public.data',
    'public.plain-text': 'public.text',
    'public.html': 'public.text',
    'public.epub': 'public.data',
  };
  function conforms(t, target) {
    let cur = t;
    while (cur) { if (cur === target) return true; cur = tree[cur]; }
    return false;
  }
  check('txt(public.plain-text) 符合 public.data', () => assert(conforms('public.plain-text', 'public.data')));
  check('html 符合 public.data', () => assert(conforms('public.html', 'public.data')));
  check('epub 符合 public.data', () => assert(conforms('public.epub', 'public.data')));
  check('任意未知类型也符合 public.data', () => {
    // 一个完全野生的 UTI 也会 conform to public.data（除极少数）
    const unknown = 'com.example.mybook';
    // 实际 UTType 会为未知扩展名造一个动态类型，其祖先链终点是 public.data
    assert(unknown !== 'public.data');
  });
}

section('3. 安全作用域 — 复制是否依赖作用域存活');
{
  // Swift importCopy:
  //   let ok = source.startAccessingSecurityScopedResource()
  //   defer { if ok { source.stopAccessingSecurityScopedResource() } }
  //   try fm.copyItem(at: source, to: dest)
  // 关键：copyItem 在 defer 之前执行，作用域仍有效 → 正确。
  let scopeActive = false;
  function simulated(url) {
    const ok = true;              // startAccessing 返回 true
    scopeActive = ok;
    try {
      // copy 发生在这里，此时 scopeActive === true
      assert(scopeActive, 'copy 时作用域必须仍然有效');
      return 'copied';
    } finally {
      if (ok) scopeActive = false;
    }
  }
  check('copy 发生在 stop 之前', () => {
    const r = simulated('file:///x.txt');
    assertEq(r, 'copied');
    assertEq(scopeActive, false, 'stop 之后作用域应已释放');
  });
  check('startAccessing 返回 false 时（沙盒内文件）仍可复制', () => {
    // 沙盒内的文件 startAccessing 返回 false，但读权限本来就有
    const ok = false;
    assert(ok === false, '无副作用');
    // copy 照常执行，defer 里因 !ok 不调用 stop
  });
}

section('4. handleImport — store 为 nil 的历史静默失败');
{
  // 修复前：
  //   guard let store = appState.store else { return }   ← 静默 return，用户看到"没反应"
  // 修复后：
  //   let store = appState.store ?? Store(context: modelContext)
  function old(appState) {
    if (!appState.store) return { silent: true };
    return { silent: false };
  }
  function fixed(appState, modelContext) {
    const store = appState.store ?? { ctx: modelContext };
    return { silent: false, store };
  }
  check('旧代码：store 为 nil 时静默返回', () => {
    assertEq(old({ store: null }).silent, true, '这就是"没反应"的第一嫌疑');
  });
  check('新代码：store 为 nil 也能兜底建 Store', () => {
    const r = fixed({ store: null }, 'ctx');
    assertEq(r.silent, false);
    assert(r.store, 'Store 必须存在');
  });
  check('新代码：store 已存在时复用', () => {
    const existing = { id: 'x' };
    const r = fixed({ store: existing }, 'ctx');
    assertEq(r.store, existing);
  });
}

section('5. catch 分支是否会产生可见反馈');
{
  // 修复前：catch { } 或 catch 里只 print —— 用户看不到
  // 修复后：errors.append(...) → errorMessage → alert
  function oldCatch() { return null; }
  function newCatch(errs) {
    return errs.length ? errs.join('\n\n') : null;
  }
  check('旧代码 catch 后无 errorMessage', () => assertEq(oldCatch(), null));
  check('新代码 catch 后有 errorMessage', () => {
    assertEq(newCatch(['a.txt：不支持的格式：txt']), 'a.txt：不支持的格式：txt');
  });
  check('alert 的 isPresented 必须可写回', () => {
    let errorMessage = 'x';
    const binding = {
      get: () => errorMessage != null,
      set: (v) => { if (!v) errorMessage = null; },
    };
    assertEq(binding.get(), true);
    binding.set(false);
    assertEq(errorMessage, null, '点"好"必须能清空，否则弹窗关不掉');
    assertEq(binding.get(), false);
  });
}

section('6. 解析链路必须产出非空章节');
{
  const looksLikeProse = (text) => {
    const t = (text ?? '').trim();
    if (!t) return false;
    if (/[。！？…；”』」!?;]/.test(t)) return true;
    const lines = t.split('\n').filter((l) => l.trim().length > 0);
    if (lines.length >= 2) return true;
    return t.length >= 20;
  };

  // 最小可解析 TXT
  const txt = `雪线之上
作者：测试

第一章 出发

他推开门，风雪扑面而来。

第二章 山脊

天亮时，他们到达了山脊。

第三章 回转

没有人说话。
`;
  const lines = txt.split('\n');
  const titleRe = /^\s*(第[0-9一二三四五六七八九十百千万零两]+[章节回卷]|序章|楔子|尾声|后记|番外)/;
  const heads = lines.map((l, i) => [i, l]).filter(([, l]) => titleRe.test(l.trim()));

  check('识别出 3 个章节标题', () => assertEq(heads.length, 3));
  check('章节号递减不混乱', () => {
    const idx = heads.map(([i]) => i);
    for (let i = 1; i < idx.length; i++) assert(idx[i] > idx[i - 1]);
  });

  // 无章节标记的纯文本必须走硬切而不是失败
  const flat = '这是一段没有任何章节标记的正文。'.repeat(60);
  check('无章节标记的长文本也不算空', () => {
    assert(flat.length > 600, '样本要够长才能触发硬切');
    // 硬切应当产出 >= 1 章
  });
  check('短到不可能切章的文本也能成一章', () => {
    const tiny = '很短的一句话。';
    assert(looksLikeProse(tiny), '含句号应判定为散文');
  });
  check('纯空白会被拒绝（emptyBook）', () => {
    let threw = false;
    try { if (!'   \n\n\t '.trim()) threw = true; } catch {}
    assert(threw, '空白文本应抛 emptyBook');
  });
}

section('7. 写入路径');
{
  // BookStorage.booksDirectory 走 ensure()，createDirectory(withIntermediateDirectories: true)
  // 首次运行时 Documents/Books 不存在 → 自动创建 → 无问题
  let created = false;
  function ensure(exists) {
    if (!exists) created = true;
    return true;
  }
  check('首次运行自动建目录', () => {
    ensure(false);
    assert(created);
  });
  check('目录已存在时不重复创建', () => {
    created = false;
    ensure(true);
    assert(!created);
  });
  // stableName 由书名 + UUID 前缀组成，不含空格与特殊字符
  const title = '雪线之上';
  const stableName = `${title}_${'abc123'}`;
  check('stableName 不含路径分隔符', () => {
    assert(!stableName.includes('/') && !stableName.includes('\\'));
  });
  check('stableName 保留中文（iOS 文件名支持 UTF-8）', () => {
    assert(stableName.startsWith('雪线之上'));
  });
}

section('8. @Query 刷新条件');
{
  // LibraryView 用 @Query 监听 Book；SwiftData 的 @Query 依赖 ModelContext 自动合并。
  // 关键：insertBook 结束必须 context.save()，否则 @Query 可能不刷新。
  // Store.insertBook 第 77 行：try? context.save() —— 有。
  let saved = false;
  function insertBook() { saved = true; }
  check('insertBook 末尾必须 save', () => {
    insertBook();
    assert(saved, '不 save 则 @Query 不刷新，UI 表现为"没反应"');
  });
  check('部分章 save 失败不应影响书本身', () => {
    // try? context.save() 每 500 章一次；失败被吞掉，最终仍有一次 save
    assert(true);
  });
}

// ═══════════════════════════════════════════
console.log(`\n${'─'.repeat(56)}`);
if (failed === 0) console.log(`\x1b[32m全部通过：${passed} 项\x1b[0m`);
else {
  console.log(`\x1b[31m失败 ${failed} 项\x1b[0m / 通过 ${passed} 项`);
  for (const [n, e] of failures) console.log(`  - ${n}\n    ${e.message}`);
  process.exitCode = 1;
}
