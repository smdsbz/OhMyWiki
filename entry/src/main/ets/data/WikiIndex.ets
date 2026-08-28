import { Logger } from '../common/Logger';
import { DataSource, PathUtil } from './DataSource';
import { WikiSite } from '../model/WikiTypes';

const TAG = 'WikiIndex';

/** manifest.json 条目 */
interface ManifestEntry {
  title: string;
  ns: number;
  pageid: number;
  path: string;
  bytes: number;
}

/** summary.json 条目 */
interface SummaryEntry {
  site?: string;
  total_pages?: number;
}

/**
 * 单个站点的索引：title → pages/ 下相对路径；图片文件名集合。
 */
export class WikiIndex {
  readonly source: DataSource;
  readonly rootRel: string;

  private titleToPath: Map<string, string> = new Map();
  private templateCache: Map<string, string | null> = new Map();
  private loaded: boolean = false;

  constructor(source: DataSource, rootRel: string) {
    this.source = source;
    this.rootRel = rootRel;
  }

  private rel(rel: string): string {
    return PathUtil.join(this.rootRel, rel);
  }

  isLoaded(): boolean {
    return this.loaded;
  }

  /** 加载索引（manifest.json 优先，缺失则遍历 pages/）。
   *  图片不做全量清单：按需试探读取（readImageBinary），站点打开零图片成本 */
  async load(): Promise<void> {
    this.titleToPath.clear();
    const manifestOk = await this.loadManifest();
    if (!manifestOk) {
      await this.walkPages();
    }
    this.loaded = true;
    Logger.info(TAG, 'index loaded: ' + this.titleToPath.size + ' pages');
  }

  private async loadManifest(): Promise<boolean> {
    try {
      const relPath = this.rel('manifest.json');
      const text = await this.source.readText(relPath);
      const arr = JSON.parse(text) as ManifestEntry[];
      for (const e of arr) {
        if (e.path && e.title) {
          this.titleToPath.set(this.normalizeTitle(e.title), 'pages/' + e.path);
        }
      }
      return true;
    } catch (e) {
      Logger.warn(TAG, 'no manifest.json, fallback to walk: ' + JSON.stringify(e));
      return false;
    }
  }

  private async walkPages(): Promise<void> {
    const pagesRel = this.rel('pages');
    Logger.info(TAG, 'walkPages: listing ' + pagesRel);
    const files = await this.source.listAllFiles(pagesRel);
    Logger.info(TAG, 'walkPages: found ' + files.length + ' files');
    // 调试：尝试直接读一个已知页面
    try {
      const testPage = await this.source.readText(this.rel('pages/Main/首页.wiki'));
      Logger.info(TAG, 'walkPages: test read pages/Main/首页.wiki -> ' + testPage.length + ' chars');
    } catch (e) {
      Logger.warn(TAG, 'walkPages: test read failed: ' + JSON.stringify(e));
    }
    for (const f of files) {
      if (!f.endsWith('.wiki')) {
        continue;
      }
      const noExt = f.substring(0, f.length - 5);
      const idx = noExt.lastIndexOf('/');
      const dir = idx >= 0 ? noExt.substring(0, idx) : '';
      const base = idx >= 0 ? noExt.substring(idx + 1) : noExt;
      const title = dir.length > 0 && dir !== 'Main' ? dir + ':' + base : base;
      this.titleToPath.set(this.normalizeTitle(title), 'pages/' + f);
    }
  }

  /** 图片试探结果缓存：引用名 → 实际命中文件名（null = 确认缺失）。
   *  候选覆盖旧规范化表全部命中形态：原名 / 冒号空格斜杠→下划线（任务图 94 张此形态）/ 首字母互换 */
  private imageResolveCache: Map<string, string | null> = new Map();

  /** 懒加载读取图片字节：按需试探 images/ 下候选名，全失败返回 null（占位）。结果缓存不重试 */
  async readImageBinary(fileName: string): Promise<Uint8Array | null> {
    const base = fileName.split('/').pop() ?? fileName;
    if (base.length === 0) {
      return null;
    }
    const cached = this.imageResolveCache.get(base);
    if (cached === null) {
      return null;
    }
    const candidates: string[] = [];
    if (cached !== undefined) {
      candidates.push(cached);
    } else {
      // 候选：① 原名 ② 冒号/空格/斜杠→下划线（MediaWiki 存储形态）③①② 的首字母大小写互换
      const under = base.replace(/[:\s/]+/g, '_');
      const first = under.charAt(0);
      const swapped = first >= 'a' && first <= 'z'
        ? first.toUpperCase() + under.substring(1)
        : (first >= 'A' && first <= 'Z' ? first.toLowerCase() + under.substring(1) : '');
      candidates.push(base);
      if (under !== base) {
        candidates.push(under);
      }
      if (swapped.length > 0 && swapped !== base && swapped !== under) {
        candidates.push(swapped);
      }
    }
    for (const cand of candidates) {
      try {
        const rel = PathUtil.join(PathUtil.join(this.rootRel, 'images'), cand);
        const bytes = await this.source.readBinary(rel);
        this.imageResolveCache.set(base, cand);
        return bytes;
      } catch (e) {
        // 试下一个候选
      }
    }
    this.imageResolveCache.set(base, null);
    return null;
  }

  /** 标题规范化（下划线→空格、首字母大小写兼容） */
  private normalizeTitle(t: string): string {
    return t.replace(/_/g, ' ').trim();
  }

  pageCount(): number {
    return this.titleToPath.size;
  }

  /** 根据规范标题找页面相对路径（相对站点根） */
  findPath(title: string): string | null {
    const t = this.normalizeTitle(title);
    if (this.titleToPath.has(t)) {
      return this.titleToPath.get(t) as string;
    }
    // 兼容 MediaWiki 首字母大小写（整串 + 冒号后页面名）
    const variants = this.caseVariants(t);
    for (const v of variants) {
      if (this.titleToPath.has(v)) {
        return this.titleToPath.get(v) as string;
      }
    }
    return null;
  }

  /** MediaWiki 标题大小写变体：整串首字母 + 冒号后页面名首字母（大写/小写） */
  private caseVariants(title: string): string[] {
    const out: string[] = [];
    const add = (s: string): void => {
      if (s.length > 0 && s !== title && out.indexOf(s) < 0) {
        out.push(s);
      }
    };
    if (title.length > 0) {
      add(title.charAt(0).toLowerCase() + title.substring(1));
      add(title.charAt(0).toUpperCase() + title.substring(1));
    }
    const ci = title.indexOf(':');
    if (ci >= 0 && ci < title.length - 1) {
      const ns = title.substring(0, ci + 1);
      const name = title.substring(ci + 1);
      add(ns + name.charAt(0).toLowerCase() + name.substring(1));
      add(ns + name.charAt(0).toUpperCase() + name.substring(1));
    }
    return out;
  }

  pageExists(title: string): boolean {
    return this.findPath(title) !== null;
  }

  /** 列出以指定前缀开头的页面标题（如 'Category:'、'Help:'） */
  titlesByPrefix(prefix: string): string[] {
    const out: string[] = [];
    for (const t of this.titleToPath.keys()) {
      if (t.startsWith(prefix)) {
        out.push(t);
      }
    }
    return out;
  }

  imageExists(fileName: string): boolean {
    // 懒加载改造后不再维护全量清单；仅同步判定缓存已知结果，未知返回 true（由 readImageBinary 实际探测）
    return this.imageResolveCache.get(fileName.split('/').pop() ?? fileName) !== null;
  }

  /** 读取页面原始 wikitext */
  async readPage(title: string): Promise<string | null> {
    const p = this.findPath(title);
    if (!p) {
      return null;
    }
    try {
      return await this.source.readText(this.rel(p));
    } catch (e) {
      Logger.warn(TAG, 'readPage failed: ' + title + ' ' + JSON.stringify(e));
      return null;
    }
  }

  /** 读取模板页源码（模板命名空间，带缓存） */
  async readTemplate(name: string): Promise<string | null> {
    const cached = this.templateCache.get(name);
    if (cached !== undefined) {
      return cached;
    }
    const text = await this.readPage('模板:' + name);
    this.templateCache.set(name, text);
    return text;
  }

  /** 读取 JSON 命名空间数据页 */
  async readJsonData(sub: string): Promise<string | null> {
    return this.readPage('JSON:' + sub);
  }

  /**
   * 解析链接目标 → 规范标题。
   * 处理：/子页、../父页、:强制主命名空间、带命名空间前缀、同命名空间相对。
   * 返回 null 表示页面不存在。
   */
  resolveLink(raw: string, currentTitle: string): string | null {
    let target = this.normalizeTitle(raw);
    if (target.length === 0) {
      return null;
    }
    // 去除尾部斜杠（如 [[/第一章/]] 的尾 '/'），避免子页面标题带上斜杠导致查找失败
    while (target.length > 1 && target.endsWith('/')) {
      target = target.substring(0, target.length - 1);
    }
    // 外部链接（由解析器处理，这里不处理）
    if (target.indexOf('://') >= 0) {
      return null;
    }
    // 强制主命名空间 / 文件等显示语法
    if (target.startsWith(':')) {
      target = target.substring(1);
      return this.pageExists(target) ? target : null;
    }
    // 子页面
    if (target.startsWith('/')) {
      const full = currentTitle + target;
      return this.pageExists(full) ? full : null;
    }
    if (target.startsWith('../')) {
      const rest = target.substring(3);
      const ci = currentTitle.lastIndexOf('/');
      const parent = ci >= 0 ? currentTitle.substring(0, ci) : currentTitle;
      const full = parent.length > 0 ? parent + '/' + rest : rest;
      return this.pageExists(full) ? full : null;
    }
    // 带命名空间前缀
    if (target.indexOf(':') >= 0) {
      return this.pageExists(target) ? target : null;
    }
    // 同命名空间相对
    const ci = currentTitle.indexOf(':');
    if (ci >= 0) {
      const ns = currentTitle.substring(0, ci);
      const cand = ns + ':' + target;
      if (this.pageExists(cand)) {
        return cand;
      }
    }
    return this.pageExists(target) ? target : null;
  }

  /** 读取站点概要信息（summary.json） */
  async readSummary(): Promise<SummaryEntry | null> {
    try {
      const text = await this.source.readText(this.rel('summary.json'));
      return JSON.parse(text) as SummaryEntry;
    } catch (e) {
      return null;
    }
  }

  /** 探测一个候选站点文件夹，返回站点信息或 null */
  static async probeSite(source: DataSource, dirName: string): Promise<WikiSite | null> {
    const rootRel = dirName;
    try {
      const pagesIsDir = await source.isDir(PathUtil.join(rootRel, 'pages'));
      if (!pagesIsDir) {
        return null;
      }
      const idx = new WikiIndex(source, rootRel);
      const summary = await idx.readSummary();
      let displayName = dirName;
      let totalPages = 0;
      if (summary !== null) {
        if (summary.site !== undefined && summary.site.length > 0) {
          displayName = summary.site;
        }
        if (summary.total_pages !== undefined) {
          totalPages = summary.total_pages;
        }
      }
      const site: WikiSite = {
        name: dirName,
        displayName: displayName,
        sourceKey: source.key,
        rootRel: rootRel,
        totalPages: totalPages,
        homeTitle: '首页',
      };
      return site;
    } catch (e) {
      Logger.warn(TAG, 'probeSite failed: ' + dirName + ' ' + JSON.stringify(e));
      return null;
    }
  }
}
