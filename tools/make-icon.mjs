import { writeFileSync } from "node:fs";
import { deflateSync } from "node:zlib";

const W = 1024, H = 1024;
const px = Buffer.alloc(W * H * 4);

// 深靛蓝背景 + 米色书页图形
const bg = [0x2e, 0x3a, 0x5c];
const page = [0xf2, 0xec, 0xdd];
const spine = [0xc9, 0xb8, 0x92];

function set(x, y, c) {
  if (x < 0 || y < 0 || x >= W || y >= H) return;
  const i = (y * W + x) * 4;
  px[i] = c[0]; px[i+1] = c[1]; px[i+2] = c[2]; px[i+3] = 255;
}

// 背景
for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) set(x, y, bg);

// 书页矩形（居中）
const bx = 260, by = 220, bw = 504, bh = 584;
for (let y = by; y < by + bh; y++) for (let x = bx; x < bx + bw; x++) set(x, y, page);
// 书脊
for (let y = by; y < by + bh; y++) for (let x = bx; x < bx + 46; x++) set(x, y, spine);
// 文字行
const line = [0x8a, 0x83, 0x72];
for (let row = 0; row < 9; row++) {
  const ly = by + 90 + row * 52;
  const lw = row % 4 === 3 ? 260 : 380;
  for (let y = ly; y < ly + 16; y++)
    for (let x = bx + 90; x < bx + 90 + lw; x++) set(x, y, line);
}

// 写 PNG
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const t = Buffer.from(type, "ascii");
  const body = Buffer.concat([t, data]);
  const crcTable = [];
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crcTable[n] = c >>> 0;
  }
  let crc = 0xffffffff;
  for (const b of body) crc = crcTable[(crc ^ b) & 0xff] ^ (crc >>> 8);
  crc = (crc ^ 0xffffffff) >>> 0;
  const c = Buffer.alloc(4); c.writeUInt32BE(crc);
  return Buffer.concat([len, body, c]);
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4);
ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;

// 每行前置 filter byte 0
const raw = Buffer.alloc(H * (W * 4 + 1));
for (let y = 0; y < H; y++) {
  raw[y * (W * 4 + 1)] = 0;
  px.copy(raw, y * (W * 4 + 1) + 1, y * W * 4, (y + 1) * W * 4);
}

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk("IHDR", ihdr),
  chunk("IDAT", deflateSync(raw, { level: 9 })),
  chunk("IEND", Buffer.alloc(0)),
]);

const out = process.argv[2];
writeFileSync(out, png);
console.log("wrote", out, png.length, "bytes");
