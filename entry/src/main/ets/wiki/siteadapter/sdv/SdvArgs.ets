import { TemplateContext } from '../../template/TemplateEngine';

/** SDV 模块通用取参/工具（对应 Lua Module:Arguments/Utils 的子集） */
export class SdvArgs {
  /** 命名实参（引擎把 named 以 'k=v' 原文混入 args）；未找到返回 null */
  static named(args: string[], key: string): string | null {
    const lower = key.toLowerCase();
    for (const a of args) {
      const eq = a.indexOf('=');
      if (eq > 0 && a.substring(0, eq).trim().toLowerCase() === lower) {
        return a.substring(eq + 1);
      }
    }
    return null;
  }

  static namedOr(args: string[], key: string, def: string): string {
    const v = SdvArgs.named(args, key);
    return v !== null ? v : def;
  }

  /** 位置实参（剔除 'k=v' 形态的命名实参） */
  static positional(args: string[]): string[] {
    return args.filter((a: string): boolean => !/^[A-Za-z][A-Za-z0-9 _-]*=/.test(a));
  }

  static pos(args: string[], idx: number): string {
    const p = SdvArgs.positional(args);
    return idx < p.length ? p[idx] : '';
  }

  /** Lua utils.normalizeKey：小写 + 下划线→空格 */
  static normalizeKey(t: string): string {
    return t.toLowerCase().replace(/_/g, ' ');
  }

  /** mw.language formatNum（zh：千分位逗号） */
  static formatNum(n: number): string {
    const neg = n < 0;
    const s = Math.abs(Math.trunc(n)).toString();
    const grouped = s.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    return (neg ? '-' : '') + grouped;
  }

  static ctxPageName(ctx: TemplateContext): string {
    const t = ctx.pageTitle;
    const ci = t.indexOf(':');
    const page = ci >= 0 ? t.substring(ci + 1) : t;
    return page;
  }
}

/** SDV 数据页（Module:Data/<name>，JSON 体）读取；静态缓存 */
export class SdvData {
  private static cache: Map<string, Record<string, string> | null> = new Map();

  /** 值全为字符串的数据页（Items/ID 系） */
  static async loadStrMap(ctx: TemplateContext, name: string): Promise<Record<string, string> | null> {
    if (SdvData.cache.has(name)) {
      return SdvData.cache.get(name) ?? null;
    }
    let m: Record<string, string> | null = null;
    if (ctx.index !== null) {
      const text = await ctx.index.readPage('Module:Data/' + name);
      if (text !== null && text.length > 0) {
        try {
          m = JSON.parse(text) as Record<string, string>;
        } catch (e) {
          m = null;
        }
      }
    }
    SdvData.cache.set(name, m);
    return m;
  }

  /** 取字符串值；缺省 '' */
  static getStr(m: Record<string, string> | null, key: string): string {
    if (m === null) {
      return '';
    }
    const v = m[key];
    return v !== undefined && v !== null ? v : '';
  }

  static has(m: Record<string, string> | null, key: string): boolean {
    return m !== null && m[key] !== undefined && m[key] !== null;
  }
}
