// coFamio iOS app-icon generator — pure Node, no deps.
// Draws the brand mark (white family house on an indigo gradient with a warm
// amber heart — family / co-parenting motif) as RGBA pixels and writes every
// AppIcon.appiconset size (iPhone/iPad/Marketing PNGs) plus the Contents.json.
// Run:  bun ios/scripts/gen-icons.mjs   (from the site root)
// Full-bleed square art; iOS applies the rounded-rect mask automatically.
// Note: this file intentionally draws full-bleed art (no rounded corner inset)
// because App Store / iOS mask the icon; do not bake in corners for the
// marketing (1024) slot either — Apple applies a per-device mask on top.
import { deflateSync } from "node:zlib";
import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT = join(fileURLToPath(new URL(".", import.meta.url)), "..", "App", "App", "Assets.xcassets", "AppIcon.appiconset");
mkdirSync(OUT, { recursive: true });

// ---- CRC32 (PNG chunks need it; zlib doesn't expose it) -------------------
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type, "ascii"), data])), 0);
  return Buffer.concat([len, Buffer.from(type, "ascii"), data, crcBuf]);
}
function writePNG(size, rgba) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;
  ihdr[9] = 6; // RGBA
  const raw = Buffer.alloc(size * (size * 4 + 1));
  for (let y = 0; y < size; y++) {
    raw[y * (size * 4 + 1)] = 0;
    raw.set(rgba.subarray(y * size * 4, (y + 1) * size * 4), y * (size * 4 + 1) + 1);
  }
  const idat = deflateSync(raw, { level: 9 });
  return Buffer.concat([sig, chunk("IHDR", ihdr), chunk("IDAT", idat), chunk("IEND", Buffer.alloc(0))]);
}

// ---- Drawing --------------------------------------------------------------
const INDIGO_TOP = [67, 56, 202];  // #4338ca (indigo-700) — top of bg gradient
const INDIGO_BOT = [99, 102, 241]; // #6366f1 (indigo-500) — bottom of bg gradient
const WHITE = [255, 255, 255];
const AMBER = [245, 158, 11];      // #f59e0b warm accent (family heart)
const LIGHT = [165, 180, 252];     // indigo-300 roof highlight

// Point-in-triangle (roof): apex (0.5,0.21), base corners (0.17,0.55),(0.83,0.55)
function inTriangle(px, py, ax, ay, bx, by, cx, cy) {
  const s = (ax, ay, bx, by, px, py) => (bx - ax) * (py - ay) - (by - ay) * (px - ax);
  const d1 = s(ax, ay, bx, by, px, py);
  const d2 = s(bx, by, cx, cy, px, py);
  const d3 = s(cx, cy, ax, ay, px, py);
  const hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
  const hasPos = d1 > 0 || d2 > 0 || d3 > 0;
  return !(hasNeg && hasPos);
}

// Heart (lobes at top, point-down) sitting in the house body = family/co-parent warmth.
function inHeart(u, v) {
  const cx = 0.5, cy = 0.678, r = 0.072;
  const lx = cx - 0.058, ly = cy - 0.046;           // left lobe center
  const rx = cx + 0.058, ry = cy - 0.046;           // right lobe center
  const inL = (u - lx) * (u - lx) + (v - ly) * (v - ly) <= r * r;
  const inR = (u - rx) * (u - rx) + (v - ry) * (v - ry) <= r * r;
  const inTri = inTriangle(u, v, cx - 0.088, cy - 0.028, cx + 0.088, cy - 0.028, cx, cy + 0.11);
  return inL || inR || inTri;
}

function drawIcon(size) {
  const rgba = new Uint8Array(size * size * 4);
  const px = (u) => Math.round(u * size);
  // body rect (white house)
  const bodyX0 = px(0.235), bodyX1 = px(0.765), bodyY0 = px(0.53), bodyY1 = px(0.8);
  // roof highlight band (bottom edge of the roof)
  const hlY0 = px(0.5), hlY1 = px(0.56);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const u = (x + 0.5) / size;
      const v = (y + 0.5) / size;
      // subtle vertical gradient background (indigo-700 → indigo-500)
      const bg = [
        Math.round(INDIGO_TOP[0] + (INDIGO_BOT[0] - INDIGO_TOP[0]) * v),
        Math.round(INDIGO_TOP[1] + (INDIGO_BOT[1] - INDIGO_TOP[1]) * v),
        Math.round(INDIGO_TOP[2] + (INDIGO_BOT[2] - INDIGO_TOP[2]) * v),
      ];
      let c = bg;
      const inBody = x >= bodyX0 && x <= bodyX1 && y >= bodyY0 && y <= bodyY1;
      const inRoof = inTriangle(u, v, 0.5, 0.21, 0.17, 0.55, 0.83, 0.55);
      if (inRoof) {
        c = WHITE;
        if (y >= hlY0 && y <= hlY1) c = LIGHT;
      } else if (inBody) {
        c = inHeart(u, v) ? AMBER : WHITE;
      }
      const i = (y * size + x) * 4;
      rgba[i] = c[0]; rgba[i + 1] = c[1]; rgba[i + 2] = c[2]; rgba[i + 3] = 255;
    }
  }
  return rgba;
}

// ---- Slots: (filename, idiom, size, scale, pixel size) ---------------------
const slots = [
  ["icon-20@1x.png", "ipad", "20x20", "1x", 20],
  ["icon-20@2x.png", "iphone", "20x20", "2x", 40],
  ["icon-20@2x.png", "ipad", "20x20", "2x", 40],
  ["icon-20@3x.png", "iphone", "20x20", "3x", 60],
  ["icon-29@1x.png", "ipad", "29x29", "1x", 29],
  ["icon-29@2x.png", "iphone", "29x29", "2x", 58],
  ["icon-29@2x.png", "ipad", "29x29", "2x", 58],
  ["icon-29@3x.png", "iphone", "29x29", "3x", 87],
  ["icon-40@1x.png", "ipad", "40x40", "1x", 40],
  ["icon-40@2x.png", "iphone", "40x40", "2x", 80],
  ["icon-40@2x.png", "ipad", "40x40", "2x", 80],
  ["icon-40@3x.png", "iphone", "40x40", "3x", 120],
  ["icon-60@2x.png", "iphone", "60x60", "2x", 120],
  ["icon-60@3x.png", "iphone", "60x60", "3x", 180],
  ["icon-76@1x.png", "ipad", "76x76", "1x", 76],
  ["icon-76@2x.png", "ipad", "76x76", "2x", 152],
  ["icon-83.5@2x.png", "ipad", "83.5x83.5", "2x", 167],
  ["icon-1024.png", "ios-marketing", "1024x1024", "1x", 1024],
];

const images = [];
const written = new Set();
for (const [file, idiom, size, scale, pixels] of slots) {
  if (!written.has(file)) {
    writeFileSync(join(OUT, file), writePNG(pixels, drawIcon(pixels)));
    written.add(file);
  }
  images.push({ filename: file, idiom, size, scale });
}
const contents = {
  images,
  info: { author: "xcode", version: 1 },
};
writeFileSync(join(OUT, "Contents.json"), JSON.stringify(contents, null, 2));
console.log("Wrote", written.size, "icon PNGs + Contents.json to", OUT);