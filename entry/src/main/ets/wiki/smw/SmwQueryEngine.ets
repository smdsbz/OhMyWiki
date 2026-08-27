import { Logger } from '../../common/Logger';
import { WikiIndex } from '../../data/WikiIndex';
import { BraceUtil } from '../parser/BraceUtil';
import { TemplateContext, TemplateEngine, AskHandler } from '../template/TemplateEngine';
import { EnemyModule } from '../module/EnemyModule';

const TAG = 'SmwQueryEngine';

/** 属性过滤条件 */
interface PropFilter {
  prop: string;
  value: string;
}

/** 展示属性 */
interface DisplayProp {
  prop: string;
  label: string;
}

/** 解析后的 #ask 查询 */
interface AskQuery {
  /** 命名空间前缀过滤（如 '任务:'），null 表示不限 */
  nsPrefix: string | null;
  /** 属性过滤（AND） */
  propFilters: PropFilter[];
  /** 展示属性（?属性=标签） */
  displayProps: DisplayProp[];
  /** 排序属性 */
  sortProps: string[];
  /** 行数上限（0 = 不限） */
  limit: number;
  /** 首列（页面名）表头 */
  mainLabel: string;
  /** headers=plain：不输出表头行 */
  headersPlain: boolean;
  /** 输出格式（table/list） */
  format: string;
}

interface Row {
  title: string;
  props: Map<string, string[]>;
}
/**
 * SMW 语义查询引擎：解析 {{#ask:...}}，对页面做属性过滤/排序/渲染。
 * 属性来源：页面 wikitext 中的 [[属性::值]] 与 {{#set:属性=值}}（含模板展开后）。
 * 单例 + 属性缓存，站点切换时 clear()。
 */
export class SmwQueryEngine implements AskHandler {
  private static instance: SmwQueryEngine | null = null;

  /** 页面标题 → 属性表（懒构建 + 缓存） */
  private propCache: Map<string, Map<string, string[]>> = new Map();

  static get(): SmwQueryEngine {
    if (SmwQueryEngine.instance === null) {
      SmwQueryEngine.instance = new SmwQueryEngine();
    }
    return SmwQueryEngine.instance;
  }

  /** 站点切换时清空缓存 */
  clear(): void {
    this.propCache.clear();
  }

  async query(args: string[], ctx: TemplateContext, isShow: boolean = false): Promise<string> {
    try {
      // 展开查询文本中的模板（如 [[地区::{{SUBPAGENAME}}]]），保留 [[...]] 结构
      const expandedArgs: string[] = [];
      for (const a of args) {
        expandedArgs.push(await this.expandQueryText(a, ctx));
      }
      if (isShow) {
        return await this.queryShow(expandedArgs, ctx);
      }
      const q = this.parseQuery(expandedArgs);
      const titles = this.collectTitles(q, ctx);
      const rows: Row[] = [];
      const reportProgress = ctx.onProgress !== undefined && ctx.onProgress !== null;
      // 敌人命名空间快速路径：过滤/展示/排序属性全部可由游戏 JSON 直取时，
      // 跳过逐页完整模板展开（每敌人 1 次 IO），无法解析的页面回退完整路径
      const useEnemyFast = q.nsPrefix === '敌人:' && this.enemyFastCoverable(q);
      for (let ti = 0; ti < titles.length; ti++) {
        const props = await this.extractPropsSmart(titles[ti], ctx, useEnemyFast);
        if (this.matches(q, props)) {
          rows.push({ title: titles[ti], props: props });
        }
        // 进度回报：每 20 页或最后一页（Reader 侧 total≥30 才展示进度条）
        if (reportProgress && ((ti + 1) % 20 === 0 || ti === titles.length - 1)) {
          ctx.onProgress!(ti + 1, titles.length);
        }
      }
      Logger.info(TAG, 'query: titles=' + titles.length + ' matched=' + rows.length +
        ' ns=' + q.nsPrefix + ' fast=' + useEnemyFast + ' filters=' + JSON.stringify(q.propFilters));
      this.sortRows(rows, q);
      if (q.limit > 0 && rows.length > q.limit) {
        rows.length = q.limit;
      }
      return this.render(rows, q, ctx.index);
    } catch (e) {
      Logger.warn(TAG, 'query error: ' + JSON.stringify(e));
      return '';
    }
  }

  /**
   * {{#show:页面名|?属性}}：取单个页面的属性值，内联输出（非表格）。
   * 属性名尾部 '#'（如 ?出售价格#）表示取原始值，忽略单位。
   */
  private async queryShow(args: string[], ctx: TemplateContext): Promise<string> {
    if (args.length === 0 || ctx.index === null) {
      return '';
    }
    const title = args[0].trim();
    if (title.length === 0) {
      return '';
    }
    // 解析展示属性（?属性 / ?属性# / ?属性=标签 —— #show 只用属性名）
    const props: string[] = [];
    for (let k = 1; k < args.length; k++) {
      const seg = args[k].trim();
      if (seg.startsWith('?')) {
        const body = seg.substring(1);
        const eq = this.topLevelIndexOf(body, '=');
        const name = (eq > 0 ? body.substring(0, eq) : body).trim();
        // 去掉尾部 #（SMW 原始值标记）
        props.push(name.endsWith('#') ? name.substring(0, name.length - 1) : name);
      }
    }
    const pageProps = await this.extractProps(title, ctx);
    const parts: string[] = [];
    for (const p of props) {
      const values = pageProps.get(p);
      if (values === undefined) {
        continue;
      }
      for (const v of values) {
        if (v.length > 0) {
          parts.push(v);
        }
      }
    }
    Logger.info(TAG, 'show: ' + title + ' props=' + JSON.stringify(props) + ' -> ' + parts.length + ' values');
    return parts.join('、');
  }

  /** 展开查询文本中的模板（如 {{SUBPAGENAME}}），保留 [[...]] 结构 */
  private async expandQueryText(text: string, ctx: TemplateContext): Promise<string> {
    const engine = new TemplateEngine({
      pageTitle: ctx.pageTitle,
      index: ctx.index,
      invokeHandler: ctx.invokeHandler,
      askHandler: null,
    });
    const sb: string[] = [];
    let i = 0;
    const n = text.length;
    while (i < n) {
      const c = text.charAt(i);
      if (c === '[' && i + 1 < n && text.charAt(i + 1) === '[') {
        const end = BraceUtil.findBracketClose(text, i);
        if (end < 0) {
          sb.push(c);
          i++;
          continue;
        }
        const inner = text.substring(i + 2, end - 2);
        const expandedInner = await this.expandQueryText(inner, ctx);
        sb.push('[[' + expandedInner + ']]');
        i = end;
        continue;
      }
      if (c === '{' && i + 1 < n && text.charAt(i + 1) === '{') {
        const end = BraceUtil.findTemplateClose(text, i);
        if (end < 0) {
          sb.push(c);
          i++;
          continue;
        }
        const inner = text.substring(i + 2, end - 2);
        const expanded = await engine.expand('{{' + inner + '}}');
        sb.push(expanded);
        i = end;
        continue;
      }
      sb.push(c);
      i++;
    }
    return sb.join('');
  }

  private parseQuery(args: string[]): AskQuery {
    const q: AskQuery = {
      nsPrefix: null,
      propFilters: [],
      displayProps: [],
      sortProps: [],
      limit: 0,
      mainLabel: '',
      headersPlain: false,
      format: 'table',
    };
    // 条件（第一个参数）：[[ns:+]] / [[属性::值]]
    if (args.length > 0) {
      const cond = args[0];
      let i = 0;
      const n = cond.length;
      while (i < n) {
        if (cond.startsWith('[[', i)) {
          const end = BraceUtil.findBracketClose(cond, i);
          if (end < 0) {
            break;
          }
          const inner = cond.substring(i + 2, end - 2).trim();
          this.parseCondition(inner, q);
          i = end;
          continue;
        }
        i++;
      }
    }
    // 选项（其余参数）
    for (let k = 1; k < args.length; k++) {
      const seg = args[k].trim();
      if (seg.length === 0) {
        continue;
      }
      if (seg.startsWith('?')) {
        const body = seg.substring(1);
        const eq = this.topLevelIndexOf(body, '=');
        if (eq > 0) {
          q.displayProps.push({ prop: body.substring(0, eq).trim(), label: body.substring(eq + 1).trim() });
        } else {
          q.displayProps.push({ prop: body.trim(), label: '' });
        }
      } else {
        const eq = this.topLevelIndexOf(seg, '=');
        if (eq > 0) {
          const key = seg.substring(0, eq).trim().toLowerCase();
          const val = seg.substring(eq + 1).trim();
          if (key === 'sort') {
            q.sortProps = val.split(',').map((s) => s.trim()).filter((s) => s.length > 0);
          } else if (key === 'limit') {
            const num = parseInt(val);
            q.limit = isNaN(num) ? 0 : num;
          } else if (key === 'mainlabel') {
            q.mainLabel = val;
          } else if (key === 'headers') {
            q.headersPlain = val.toLowerCase() === 'plain';
          } else if (key === 'format') {
            q.format = val.toLowerCase();
          }
        }
      }
    }
    return q;
  }

  private parseCondition(inner: string, q: AskQuery): void {
    // 属性过滤 [[属性::值]]
    const dc = this.findTopLevelDoubleColon(inner);
    if (dc >= 0) {
      const prop = inner.substring(0, dc).trim();
      const value = inner.substring(dc + 2).trim();
      if (prop.length > 0) {
        q.propFilters.push({ prop: prop, value: value });
      }
      return;
    }
    // 命名空间前缀 [[ns:+]]
    if (inner.endsWith(':+')) {
      const ns = inner.substring(0, inner.length - 2).trim();
      if (ns.length > 0) {
        q.nsPrefix = ns + ':';
      }
      return;
    }
    // 其他条件（分类等）暂不支持，忽略
  }

  private collectTitles(q: AskQuery, ctx: TemplateContext): string[] {
    if (ctx.index === null) {
      return [];
    }
    if (q.nsPrefix !== null) {
      return ctx.index.titlesByPrefix(q.nsPrefix);
    }
    return ctx.index.titlesByPrefix('');
  }

  /** 敌人快速路径可覆盖的属性集（与 EnemyModule.propsFast 保持一致） */
  private static readonly ENEMY_FAST_PROPS: string[] =
    ['ZoneID', '敌人分类', '地域', '等级', '等级浮动', '无视等级差补正'];

  /** 查询的过滤/展示/排序属性是否全部在敌人快速路径覆盖范围内 */
  private enemyFastCoverable(q: AskQuery): boolean {
    const fast = SmwQueryEngine.ENEMY_FAST_PROPS;
    for (const f of q.propFilters) {
      if (fast.indexOf(f.prop) < 0) {
        return false;
      }
    }
    for (const p of q.displayProps) {
      if (fast.indexOf(p.prop) < 0) {
        return false;
      }
    }
    for (const s of q.sortProps) {
      if (fast.indexOf(s) < 0) {
        return false;
      }
    }
    return true;
  }

  /** 属性提取：优先敌人快速路径（JSON 直取），null 时回退完整展开；结果统一入 propCache */
  private async extractPropsSmart(title: string, ctx: TemplateContext,
    useEnemyFast: boolean): Promise<Map<string, string[]>> {
    if (!useEnemyFast) {
      return await this.extractProps(title, ctx);
    }
    const cached = this.propCache.get(title);
    if (cached !== undefined) {
      return cached;
    }
    const fast = await EnemyModule.propsFast(ctx, title);
    if (fast !== null) {
      this.propCache.set(title, fast);
      return fast;
    }
    return await this.extractProps(title, ctx);
  }

  /** 提取页面语义属性（模板展开 + 捕获 [[属性::值]] / {{#set:...}}），带缓存 */
  private async extractProps(title: string, ctx: TemplateContext): Promise<Map<string, string[]>> {
    const cached = this.propCache.get(title);
    if (cached !== undefined) {
      return cached;
    }
    const props = new Map<string, string[]>();
    if (ctx.index !== null) {
      const raw = await ctx.index.readPage(title);
      if (raw !== null) {
        const engine = new TemplateEngine({
          pageTitle: title,
          index: ctx.index,
          invokeHandler: ctx.invokeHandler,
          askHandler: null,
          capture: (prop: string, value: string): void => {
            const p = prop.trim();
            if (p.length === 0) {
              return;
            }
            const v = value.trim();
            const arr = props.get(p);
            if (arr === undefined) {
              props.set(p, [v]);
            } else {
              arr.push(v);
            }
          },
        });
        await engine.expand(raw);
      }
    }
    this.propCache.set(title, props);
    return props;
  }

  private matches(q: AskQuery, props: Map<string, string[]>): boolean {
    for (const f of q.propFilters) {
      const values = props.get(f.prop);
      if (values === undefined) {
        return false;
      }
      let found = false;
      for (const v of values) {
        if (v === f.value) {
          found = true;
          break;
        }
      }
      if (!found) {
        return false;
      }
    }
    return true;
  }

  private sortRows(rows: Row[], q: AskQuery): void {
    if (q.sortProps.length === 0) {
      return;
    }
    rows.sort((a: Row, b: Row) => {
      for (const sp of q.sortProps) {
        const av = this.firstValue(a.props, sp);
        const bv = this.firstValue(b.props, sp);
        const cmp = this.naturalCompare(av, bv);
        if (cmp !== 0) {
          return cmp;
        }
      }
      return 0;
    });
  }

  private firstValue(props: Map<string, string[]>, prop: string): string {
    const arr = props.get(prop);
    if (arr === undefined || arr.length === 0) {
      return '';
    }
    return arr[0];
  }

  /** 数字感知字符串比较（'b-24' vs 'b-3' → 24 > 3） */
  private naturalCompare(a: string, b: string): number {
    const pa = a.match(/(\d+|\D+)/g) ?? [];
    const pb = b.match(/(\d+|\D+)/g) ?? [];
    const n = Math.max(pa.length, pb.length);
    for (let i = 0; i < n; i++) {
      const x = pa[i] ?? '';
      const y = pb[i] ?? '';
      if (x === y) {
        continue;
      }
      const xn = parseInt(x);
      const yn = parseInt(y);
      if (!isNaN(xn) && !isNaN(yn)) {
        return xn - yn;
      }
      return x < y ? -1 : 1;
    }
    return 0;
  }

  private render(rows: Row[], q: AskQuery, index: WikiIndex | null): string {
    if (q.format === 'list' || q.format === 'ul') {
      const sb: string[] = [];
      for (const r of rows) {
        sb.push('* [[' + r.title + '|' + this.displayTitle(r.title) + ']]');
      }
      return sb.join('\n');
    }
    // 默认表格
    const sb: string[] = [];
    sb.push('{| class="wikitable"');
    if (!q.headersPlain) {
      sb.push('|-');
      sb.push('! ' + (q.mainLabel.length > 0 ? q.mainLabel : '页面'));
      for (const dp of q.displayProps) {
        sb.push('! ' + (dp.label.length > 0 ? dp.label : dp.prop));
      }
    }
    for (const r of rows) {
      sb.push('|-');
      sb.push('| [[' + r.title + '|' + this.displayTitle(r.title) + ']]');
      for (const dp of q.displayProps) {
        const values = r.props.get(dp.prop);
        const parts: string[] = [];
        if (values !== undefined) {
          for (const v of values) {
            parts.push(this.linkifyValue(v, index));
          }
        }
        sb.push('| ' + parts.join('<br>'));
      }
    }
    sb.push('|}');
    return sb.join('\n');
  }

  /** 把纯页面引用值转为链接（如 '异刃:伊吹' → [[异刃:伊吹|伊吹]]） */
  private linkifyValue(v: string, index: WikiIndex | null): string {
    if (v.length === 0 || v.indexOf('[') >= 0 || index === null) {
      return v;
    }
    if (index.pageExists(v)) {
      const ci = v.indexOf(':');
      const display = ci >= 0 ? v.substring(ci + 1) : v;
      return '[[' + v + '|' + display + ']]';
    }
    return v;
  }

  private displayTitle(title: string): string {
    const ci = title.indexOf(':');
    return ci >= 0 ? title.substring(ci + 1) : title;
  }

  /** 顶层 '::' 下标（不在 [[ ]] 或 {{ }} 内） */
  private findTopLevelDoubleColon(text: string): number {
    let i = 0;
    const n = text.length;
    while (i < n - 1) {
      const c = text.charAt(i);
      if (c === '[' && text.charAt(i + 1) === '[') {
        const end = BraceUtil.findBracketClose(text, i);
        if (end < 0) {
          return -1;
        }
        i = end;
        continue;
      }
      if (c === '{' && text.charAt(i + 1) === '{') {
        const end = BraceUtil.findTemplateClose(text, i);
        if (end < 0) {
          return -1;
        }
        i = end;
        continue;
      }
      if (c === ':' && text.charAt(i + 1) === ':') {
        return i;
      }
      i++;
    }
    return -1;
  }

  /** 顶层分隔符下标 */
  private topLevelIndexOf(text: string, sep: string): number {
    let i = 0;
    const n = text.length;
    while (i < n) {
      const c = text.charAt(i);
      if (c === '{' && i + 1 < n && text.charAt(i + 1) === '{') {
        const e = BraceUtil.findTemplateClose(text, i);
        if (e < 0) {
          return -1;
        }
        i = e;
        continue;
      }
      if (c === '[' && i + 1 < n && text.charAt(i + 1) === '[') {
        const e = BraceUtil.findBracketClose(text, i);
        if (e < 0) {
          return -1;
        }
        i = e;
        continue;
      }
      if (c === sep) {
        return i;
      }
      i++;
    }
    return -1;
  }
}