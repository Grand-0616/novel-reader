#!/usr/bin/env node
/**
 * make-icons.mjs
 *
 * 生成 iOS 需要的各尺寸 AppIcon PNG（无第三方依赖）。
 *
 * 为什么需要这个：
 *   GitHub Actions 的 macos runner 上，Xcode 16.2+ 的 actool 编译
 *   asset catalog 时会去找 iOS 模拟器运行时来渲染图标，找不到就报
 *   "No simulator runtime version ... available to use with iphonesimulator SDK"。
 *   而下载模拟器运行时有好几 GB，太慢。
 *
 *   解法：把图标做成独立的 PNG 文件，用 Info.plist 的 CFBundleIconFiles
 *   直接引用，完全不经过 actool。
 *
 * 运行： node tools/make-icons.mjs
 */

import { writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateSync } from 'node:zlib';

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT = resolve(__dirname, '..', 'NovelReader', 'Resources', 'Icons');

// iOS 需要的图标尺寸（point × scale = 像素）
const SIZES = [
  // iPhone
  { name: 'AppIcon-20@2x', px: 40 },
  { name: 'AppIcon-20@3x', px: 60 },
  { name: 'AppIcon-29@2x', px: 58 },
  { name: 'AppIcon-29@3x', px: 87 },
  { name: 'AppIcon-40@2x', px: 80 },
  { name: 'AppIcon-40@3x', px: 120 },
  { name: 'AppIcon-60@2x', px: 120 },
  { name: 'AppIcon-60@3x', px: 180 },
  // iPad
  { name: 'AppIcon-20@1x~ipad', px: 20 },
  { name: 'AppIcon-29@1x~ipad', px: 29 },
  { name: 'AppIcon-40@1x~ipad', px: 40 },
  { name: 'AppIcon-76@1x~ipad', px: 76 },
  { name: 'AppIcon-76@2x~ipad', px: 152 },
  { name: 'AppIcon-83.5@2x~ipad', px: 167 },
  // App Store
  { name: 'AppIcon-1024', px: 1024 },
];

// ── PNG 编码 ──
function crc32(buf) {
  let table = crc32.t;
  if (!table) {
    table = crc32.t = new Uint32Array(256);
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

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const c = Buffer.alloc(4);
  c.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, c]);
}

/** 画一个 size×size 的图标：深靛蓝底 + 米色书页 + 书脊 + 文字行 */
function makeIcon(size) {
  const px = Buffer.alloc(size * size * 4);

  const bg = [0x2e, 0x3a, 0x5c];
  const page = [0xf2, 0xec, 0xdd];
  const spine = [0xc9, 0xb8, 0x92];
  const line = [0x8a, 0x83, 0x72];

  const set = (x, y, c) => {
    if (x < 0 || y < 0 || x >= size || y >= size) return;
    const i = (y * size + x) * 4;
    px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255;
  };

  // 背景
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) set(x, y, bg);

  // 按 1024 基准等比缩放
  const s = size / 1024;
  const rect = (x0, y0, w, h, c) => {
    const X0 = Math.round(x0 * s), Y0 = Math.round(y0 * s);
    const X1 = Math.round((x0 + w) * s), Y1 = Math.round((y0 + h) * s);
    for (let y = Y0; y < Y1; y++) for (let x = X0; x < X1; x++) set(x, y, c);
  };

  // 书页
  rect(260, 220, 504, 584, page);
  // 书脊
  rect(260, 220, 46, 584, spine);
  // 文字行
  for (let row = 0; row < 9; row++) {
    const ly = 220 + 90 + row * 52;
    const lw = row % 4 === 3 ? 260 : 380;
    rect(260 + 90, ly, lw, 16, line);
  }

  // 行数据（每行前置 filter byte 0）
  const raw = Buffer.alloc(size * (size * 4 + 1));
  for (let y = 0; y < size; y++) {
    raw[y * (size * 4 + 1)] = 0;
    px.copy(raw, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4);
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;   // bit depth
  ihdr[9] = 6;   // RGBA
  ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// ── 生成 ──
if (!existsSync(OUT)) mkdirSync(OUT, { recursive: true });

let total = 0;
for (const { name, px } of SIZES) {
  const png = makeIcon(px);
  writeFileSync(join(OUT, `${name}.png`), png);
  total += png.length;
  console.log(`  ${name}.png  ${px}x${px}  ${png.length} bytes`);
}

console.log(`\n生成 ${SIZES.length} 个图标，共 ${(total / 1024).toFixed(1)} KB`);
console.log(`输出目录：${OUT}`);
