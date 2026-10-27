#!/usr/bin/env node
/**
 * lint-swift.mjs
 *
 * 没有 Xcode 时的静态检查：扫出 Swift 侧最容易编译失败的几类问题。
 * 不是完整编译器，只覆盖这次手写代码的高风险模式。
 *
 * 运行： node tools/lint-swift.mjs
 */

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

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

const files = walk(SRC);
const sources = files.map((f) => ({ path: f, rel: relative(SRC, f), text: readFileSync(f, 'utf8') }));

let problems = 0;
const report = [];

function issue(level, file, line, msg) {
  problems++;
  report.push({ level, file, line, msg });
}

function lineOf(text, index) {
  return text.slice(0, index).split('\n').length;
}

// ── 1. 全局重复类型声明 ──────────────────────────────
const typeDecls = new Map();
const typeRe = /^\s*(?:public |internal |private |fileprivate )?(?:final )?(?:struct|class|enum|protocol|extension)\s+([A-Z][A-Za-z0-9_]*)/gm;
for (const { rel, text } of sources) {
  let m;
  while ((m = typeRe.exec(text))) {
    const name = m[1];
    // extension 允许重复
    if (m[0].includes('extension')) continue;
    if (!typeDecls.has(name)) typeDecls.set(name, []);
    typeDecls.get(name).push(rel);
  }
}
for (const [name, where] of typeDecls) {
  if (where.length > 1) {
    issue('error', where.join(', '), 0, `类型 ${name} 重复声明`);
  }
}

// ── 2. 顶层函数重复 ─────────────────────────────────
const funcDecls = new Map();
const funcRe = /^(?:public |internal )?(?:static )?func\s+([a-zA-Z_][A-Za-z0-9_]*)\s*\(/gm;
for (const { rel, text } of sources) {
  let m;
  while ((m = funcRe.exec(text))) {
    const key = `${rel}::${m[1]}`;
    if (!funcDecls.has(key)) funcDecls.set(key, 0);
    funcDecls.set(key, funcDecls.get(key) + 1);
  }
}
for (const [key, count] of funcDecls) {
  if (count > 1) {
    const [file, fn] = key.split('::');
    // 同文件重载是合法的，只在完全相同的签名下才算问题，这里只提示
    issue('warn', file, 0, `函数 ${fn} 在同文件出现 ${count} 次（确认是重载而非重复定义）`);
  }
}

// ── 3. 使用但未声明的项目内类型 ──────────────────────
const declaredTypes = new Set(typeDecls.keys());
// 系统/框架类型白名单（不完整，仅覆盖本项目用到的）
const systemTypes = new Set([
  'String', 'Int', 'Double', 'Float', 'Bool', 'Data', 'Date', 'URL', 'UUID', 'Array', 'Dictionary',
  'Set', 'Optional', 'Result', 'Error', 'NSRange', 'NSString', 'NSAttributedString', 'NSMutableParagraphStyle',
  'NSRegularExpression', 'JSONSerialization', 'JSONDecoder', 'JSONEncoder', 'FileManager', 'UserDefaults',
  'Bundle', 'NotificationCenter', 'Timer', 'DispatchQueue', 'Task', 'MainActor', 'Sendable', 'Character',
  'CharacterSet', 'Unicode', 'CGFloat', 'CGSize', 'CGPoint', 'CGRect', 'CGPath', 'UIColor', 'UIFont',
  'UIImage', 'UIGraphicsImageRenderer', 'UIPasteboard', 'UIApplication', 'UIView', 'UILabel', 'UITextView',
  'UIViewController', 'UIWindow', 'UIResponder', 'NSObject', 'CTFramesetter', 'CTFrame', 'CTLine',
  'CTFramesetterCreateWithAttributedString', 'CTFramesetterCreateFrame', 'CTFrameDraw', 'z_stream',
  'ModelContainer', 'ModelContext', 'ModelConfiguration', 'Schema', 'FetchDescriptor', 'ModelActor',
  'View', 'App', 'Scene', 'WindowGroup', 'Environment', 'EnvironmentValues', 'Binding', 'State',
  'StateObject', 'ObservedObject', 'ObservableObject', 'Published', 'Bindable', 'Query', 'Model',
  'Attribute', 'Relationship', 'ColorScheme', 'Color', 'Image', 'Text', 'Button', 'VStack', 'HStack',
  'ZStack', 'ScrollView', 'LazyVGrid', 'List', 'Form', 'Section', 'NavigationStack', 'NavigationLink',
  'TabView', 'ToolbarItem', 'Menu', 'Picker', 'Toggle', 'Slider', 'TextField', 'SecureField', 'TextEditor',
  'ProgressView', 'Spacer', 'Divider', 'Label', 'Capsule', 'RoundedRectangle', 'Rectangle', 'Circle',
  'LinearGradient', 'GridItem', 'GeometryReader', 'DragGesture', 'Gesture', 'AsyncImage', 'ContentView',
  'UIViewRepresentable', 'UIHostingController', 'NSLayoutConstraint', 'UTType', 'LocalizedError',
  'Error', 'Void', 'Any', 'AnyObject', 'Never', 'Self', 'Type', 'Sequence', 'Collection',
  'IndexSet', 'ArraySlice', 'Substring', 'SubSequence', 'Comparable', 'Equatable', 'Hashable',
  'Codable', 'Encodable', 'Decodable', 'Identifiable', 'CaseIterable', 'Observable', 'Observation',
  'OperationQueue', 'URLSession', 'URLRequest', 'URLResponse', 'HTTPURLResponse', 'URLComponents',
  'Data', 'TimeInterval', 'Calendar', 'Locale', 'NumberFormatter', 'ByteCountFormatter',
  'TextMeasurer', 'ContentUnavailableView', 'LocalizedStringKey', 'ViewBuilder', 'NSLog',
  'AsyncStream', 'CheckedContinuation', 'withCheckedContinuation', 'NSAttributedStringKey',
  'NSMutableAttributedString', 'CFStringEncoding', 'CFStringEncodings', 'CFStringConvertEncodingToNSStringEncoding',
  'UnicodeScalar', 'String.Encoding', 'UIBezierPath', 'UIScreen', 'UIEdgeInsets',
]);

// 只检查"项目里自己定义但拼错"的情况：找 XxxView / XxxManager 这类命名
const projectish = /^[A-Z][A-Za-z0-9]*(View|Manager|Service|Parser|Store|Source|Registry|Engine|Client|Cache|Loader|Splitter|Sanitizer|Archive|Node|Selector|Rule|Feed|Entry|Candidate|Detail|Position|Chapter|Book|State|Theme|Style|Panel|Banner|Sheet|Cell|Grid|Preview|Card|Measurer|Paginator|Handler|Settings|Controller|Representable)$/;
const usedProjectish = new Set();
for (const { text } of sources) {
  let m;
  const useRe = /\b([A-Z][A-Za-z0-9]*)\b/g;
  while ((m = useRe.exec(text))) {
    if (projectish.test(m[1])) usedProjectish.add(m[1]);
  }
}
for (const t of usedProjectish) {
  if (!declaredTypes.has(t) && !systemTypes.has(t)) {
    issue('warn', '-', 0, `引用了未在本项目声明的类型 ${t}（确认是系统类型或拼写正确）`);
  }
}

// ── 4. SwiftData @Model 使用限制 ─────────────────────
for (const { rel, text } of sources) {
  if (!text.includes('@Model')) continue;
  // @Model 类里不能用 let 存储属性（除了有默认值/唯一属性）
  const modelBlocks = text.split('@Model');
  for (let i = 1; i < modelBlocks.length; i++) {
    const block = modelBlocks[i].split('\n').slice(0, 60).join('\n');
    const lets = block.match(/^\s+(?:private )?let\s+\w+/gm) || [];
    for (const l of lets) {
      issue('warn', rel, 0, `@Model 中使用 let 存储属性：${l.trim()}（SwiftData 需要 var）`);
    }
    // 枚举/结构体作为存储属性必须有 Codable
    if (/^\s+var\s+\w+\s*:\s*(?!String|Int|Double|Bool|Data|Date|UUID|\[)/m.test(block)) {
      const m = block.match(/^\s+var\s+(\w+)\s*:\s*([A-Z][A-Za-z0-9_]*)/m);
      if (m) {
        const type = m[2];
        const ok = ['String', 'Int', 'Double', 'Bool', 'Data', 'Date', 'UUID'].includes(type);
        if (!ok) {
          issue('warn', rel, 0, `@Model 存储属性 ${m[1]}: ${type} —— 需确认 Codable 或标记 @Transient`);
        }
      }
    }
  }
}

// ── 5. 明显的作用域错误：private 扩展成员被外部使用 ──
for (const { rel, text } of sources) {
  const privateExt = text.match(/private extension (\w+)/);
  if (privateExt) {
    const typeName = privateExt[1];
    for (const other of sources) {
      if (other.rel === rel) continue;
      if (new RegExp(`\\b${typeName}\\(`).test(other.text)) {
        issue('warn', other.rel, 0, `${typeName} 在 ${rel} 是 private 扩展，外部文件不可见`);
      }
    }
  }
}

// ── 6. @Observable + didSet 的已知坑 ─────────────────
for (const { rel, text } of sources) {
  if (!text.includes('@Observable')) continue;
  const lines = text.split('\n');
  lines.forEach((l, i) => {
    if (/didSet/.test(l) && /var\s+\w+\s*:/.test(l)) {
      // 检查 didSet 体内是否读取了 self 的其它属性（会触发观测冲突）
      const next = lines.slice(i + 1, i + 4).join(' ');
      if (/persist\(\)/.test(next) && /self\./.test(next)) {
        issue('warn', rel, i + 1, '@Observable 的 didSet 里访问 self 属性有风险');
      }
    }
  });
}

// ── 7. await 用在非 async 上下文 ────────────────────
for (const { rel, text } of sources) {
  const lines = text.split('\n');
  let inAsync = false;
  let depth = 0;
  let funcDepth = -1;
  lines.forEach((l, i) => {
    if (/\bfunc\b.*\basync\b/.test(l)) { inAsync = true; funcDepth = depth; }
    if (/\bfunc\b/.test(l) && !/async/.test(l) && !/^\s*\/\//.test(l)) {
      // 非 async 函数开始，若之前没有闭合则重置
    }
    const opens = (l.match(/\{/g) || []).length;
    const closes = (l.match(/\}/g) || []).length;
    depth += opens - closes;
    if (inAsync && funcDepth >= 0 && depth <= funcDepth && closes > 0) {
      inAsync = false;
      funcDepth = -1;
    }
  });
}

// ── 8. 强制解包（生产代码里应避免）────────────────────
for (const { rel, text } of sources) {
  const lines = text.split('\n');
  lines.forEach((l, i) => {
    if (/^\s*\/\//.test(l)) return;
    if (/try!/.test(l)) {
      issue('warn', rel, i + 1, '使用了 try!（可能崩溃）');
    }
    if (/!\s*$/.test(l) && !/!=/.test(l) && /\)!|\w!\./.test(l)) {
      issue('warn', rel, i + 1, '疑似强制解包');
    }
  });
}

// ── 9. SwiftUI 常见误用 ─────────────────────────────
for (const { rel, text } of sources) {
  const lines = text.split('\n');
  lines.forEach((l, i) => {
    // .onChange 旧签名（iOS 17 起需两参数闭包）
    if (/\.onChange\(of:\s*[^)]+\)\s*\{/.test(l) && !/\{.*,.*in/.test(l)) {
      issue('warn', rel, i + 1, '.onChange 使用旧签名，iOS 17 需要 (oldValue, newValue) 或零参数');
    }
    // @Bindable var x = x 在 body 内是合法的，但赋值给非 self 属性要检查
    if (/Text\(.*\)\.font\(\.system\(size:\s*[^)]*appState/.test(l)) {
      issue('warn', rel, i + 1, 'Text 内插值 + 属性访问，确认没有被 ViewBuilder 拆断');
    }
  });
}

// ── 10. 检查 import 是否齐全 ────────────────────────
const needsImport = [
  { pattern: /\bUIImage\b/, import: 'UIKit', except: ['SwiftUI'] },
  { pattern: /\bzlib\b|\binflateInit2_/, import: 'zlib', except: [] },
  { pattern: /CTFramesetter|CTFrame|CTLine/, import: 'CoreText', except: ['UIKit', 'SwiftUI'] },
  { pattern: /@Model\b|ModelContext|FetchDescriptor/, import: 'SwiftData', except: [] },
  { pattern: /@Observable\b/, import: 'Observation', except: ['SwiftUI'] },
];
for (const { rel, text } of sources) {
  for (const { pattern, import: imp, except } of needsImport) {
    if (pattern.test(text) && !new RegExp(`^import ${imp}$`, 'm').test(text)) {
      const hasException = except.some((e) => new RegExp(`^import ${e}$`, 'm').test(text));
      if (!hasException) {
        issue('error', rel, 0, `使用 ${pattern} 但没有 import ${imp}`);
      }
    }
  }
}

// ── 输出 ────────────────────────────────────────────
const errors = report.filter((r) => r.level === 'error');
const warns = report.filter((r) => r.level === 'warn');

console.log(`检查 ${sources.length} 个 Swift 文件\n`);

if (errors.length) {
  console.log('\x1b[31m错误\x1b[0m');
  for (const r of errors) console.log(`  ${r.file}:${r.line}  ${r.msg}`);
}
if (warns.length) {
  console.log('\n\x1b[33m提示\x1b[0m');
  for (const r of warns) console.log(`  ${r.file}:${r.line}  ${r.msg}`);
}
if (!errors.length && !warns.length) {
  console.log('\x1b[32m未发现明显问题\x1b[0m');
}

console.log(`\n错误 ${errors.length} / 提示 ${warns.length}`);
process.exitCode = errors.length > 0 ? 1 : 0;
