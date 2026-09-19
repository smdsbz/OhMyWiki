/**
 * 源数据颜色 → 当前显示模式的适配（引擎通用能力，不含站点知识）。
 * 源站（含 mhxx/rakuen）颜色均按浅色主题设计：浅色单元格底在深色模式下
 * 与浅色文字叠成低对比；深色前景字在深色底上不可读。
 * 换算保留色相（语义色编码可辨）：浅底 → 保色相深底，暗字 → 保色相提亮字；
 * 浅色模式一律原样透传。仅识别 #rgb/#rgba/#rrggbb/#rrggbbaa。
 */
interface Rgb {
  r: number;
  g: number;
  b: number;
}

interface Hsl {
  h: number; // 0..360
  s: number; // 0..1
  l: number; // 0..1
}

interface ParsedColor {
  rgb: Rgb;
  alpha: string; // '' = 不透明，否则两位 hex
}

function parseHex(c: string): ParsedColor | null {
  const m = c.match(/^#([0-9a-fA-F]{3,8})$/);
  if (m === null) {
    return null;
  }
  let h = m[1];
  let alpha = '';
  if (h.length === 3 || h.length === 4) {
    const a = h.length === 4 ? h.charAt(3) + h.charAt(3) : '';
    h = h.charAt(0) + h.charAt(0) + h.charAt(1) + h.charAt(1) + h.charAt(2) + h.charAt(2);
    alpha = a;
  } else if (h.length === 8) {
    alpha = h.substring(6, 8);
    h = h.substring(0, 6);
  } else if (h.length !== 6) {
    return null;
  }
  return {
    rgb: {
      r: parseInt(h.substring(0, 2), 16) / 255,
      g: parseInt(h.substring(2, 4), 16) / 255,
      b: parseInt(h.substring(4, 6), 16) / 255,
    },
    alpha: alpha,
  };
}

function rgbToHsl(c: Rgb): Hsl {
  const max = Math.max(c.r, c.g, c.b);
  const min = Math.min(c.r, c.g, c.b);
  const l = (max + min) / 2;
  let h = 0;
  let s = 0;
  if (max !== min) {
    const d = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    if (max === c.r) {
      h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0);
    } else if (max === c.g) {
      h = (c.b - c.r) / d + 2;
    } else {
      h = (c.r - c.g) / d + 4;
    }
    h *= 60;
  }
  return { h: h, s: s, l: l };
}

function hueToRgb(p: number, q: number, t: number): number {
  let tt = t;
  if (tt < 0) {
    tt += 1;
  }
  if (tt > 1) {
    tt -= 1;
  }
  if (tt < 1 / 6) {
    return p + (q - p) * 6 * tt;
  }
  if (tt < 1 / 2) {
    return q;
  }
  if (tt < 2 / 3) {
    return p + (q - p) * (2 / 3 - tt) * 6;
  }
  return p;
}

function hslToRgb(hsl: Hsl): Rgb {
  if (hsl.s === 0) {
    return { r: hsl.l, g: hsl.l, b: hsl.l };
  }
  const h = hsl.h / 360;
  const q = hsl.l < 0.5 ? hsl.l * (1 + hsl.s) : hsl.l + hsl.s - hsl.l * hsl.s;
  const p = 2 * hsl.l - q;
  return {
    r: hueToRgb(p, q, h + 1 / 3),
    g: hueToRgb(p, q, h),
    b: hueToRgb(p, q, h - 1 / 3),
  };
}

function toHex2(v: number): string {
  const n = Math.max(0, Math.min(255, Math.round(v * 255)));
  const s = n.toString(16);
  return s.length < 2 ? '0' + s : s;
}

function hexOf(rgb: Rgb, alpha: string): string {
  return '#' + toHex2(rgb.r) + toHex2(rgb.g) + toHex2(rgb.b) + alpha;
}

/** 单元格/行内底色：深色模式下浅底（L≥0.5）压到 0.2~0.29 明度、降饱和，保留色相 */
export function adaptSourceBg(c: string, dark: boolean): string {
  const parsed = parseHex(c);
  if (!dark || parsed === null) {
    return c;
  }
  const hsl = rgbToHsl(parsed.rgb);
  if (hsl.l < 0.5) {
    return c;
  }
  return hexOf(hslToRgb({ h: hsl.h, s: hsl.s * 0.55, l: 0.2 + (hsl.l - 0.5) * 0.18 }),
    parsed.alpha);
}

/** 行内前景字色：深色模式下暗字（L<0.5）提到 0.53~0.67 明度、限饱和，保留色相 */
export function adaptSourceFg(c: string, dark: boolean): string {
  const parsed = parseHex(c);
  if (!dark || parsed === null) {
    return c;
  }
  const hsl = rgbToHsl(parsed.rgb);
  if (hsl.l >= 0.5) {
    return c;
  }
  return hexOf(hslToRgb({ h: hsl.h, s: Math.min(hsl.s, 0.8), l: 0.53 + (0.5 - hsl.l) * 0.28 }),
    parsed.alpha);
}
