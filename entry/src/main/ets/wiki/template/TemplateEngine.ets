import { Logger } from '../../common/Logger';
import { WikiIndex } from '../../data/WikiIndex';
import { BraceUtil } from '../parser/BraceUtil';

const TAG = 'TemplateEngine';

/** #invoke 分发接口（由站点适配器提供实现） */
export interface InvokeHandler {
  invoke(module: string, func: string, args: string[], ctx: TemplateContext): Promise<string>;
}

/** #ask/#show 语义查询分发接口（由 SmwQueryEngine 实现） */
/** 结构化查询结果行（AskHandler.queryRows 用；SmwQueryEngine.Row 结构兼容） */
export interface AskRow {
  title: string;
}

export interface AskHandler {
  query(args: string[], ctx: TemplateContext, isShow: boolean): Promise<string>;
  /** 结构化查询（可选，SmwQueryEngine 提供）：返回结果行（页面+属性），供站点模块内部消费 */
  queryRows?(args: string[], ctx: TemplateContext): Promise<Array<AskRow>>;
}

/** 惰性登记的 #ask/#show（渐进渲染：Reader 后台执行后回填占位标记） */
export interface PendingAsk {
  id: number;
  args: string[];
  isShow: boolean;
}

/** 惰性登记的 #invoke 延迟调用（渐进渲染：模块产出的重计算——如建图查询——
 *  由 Reader 阶段 2 重新调用模块执行后回填占位标记） */
export interface PendingInvoke {
  id: number;
  module: string;
  func: string;
  args: string[];
}

/** 模板展开上下文 */
export interface TemplateContext {
  pageTitle: string;
  index: WikiIndex | null;
  invokeHandler: InvokeHandler | null;
  /** SMW 语义查询处理器（可选，缺省时 #ask 显示占位） */
  askHandler?: AskHandler | null;
  /** 语义属性捕获回调（可选，用于构建属性索引） */
  capture?: (prop: string, value: string) => void;
  /** 长查询进度回调（可选）：done 已处理页数 / total 候选页数 */
  onProgress?: (done: number, total: number) => void;
  /** 惰性 #ask/#show（渐进渲染）：不立即执行，登记到 pendingAsks 并返回占位标记 */
  lazyAsk?: boolean;
  /** 惰性模式下的查询登记表（由页面持有，阶段 2 逐条执行） */
  pendingAsks?: PendingAsk[];
  /** 惰性模式下的模块延迟调用登记表（由页面持有，阶段 2 逐条执行） */
  pendingInvokes?: PendingInvoke[];
  /** 取消信号（可选，返回 true 时长查询应尽快中止）：页面销毁后终止后台扫描 */
  cancelled?: () => boolean;
}

const MAX_DEPTH = 10;
/** 占位标记：\u0000OMPH:reason\u0000 */
export const PLACEHOLDER_MARK = '\u0000OMPH:';

/** 展开中的模板实参帧（#invoke 父框架实参继承用） */
interface TemplateFrame {
  positional: string[];
  named: string[];
}

/**
 * 模板展开引擎：把 wikitext 中的 {{...}}（模板、解析函数、魔术字、
 * SMW 语义标注）展开为普通文本，供解析器继续处理。
 */
export class TemplateEngine {
  private ctx: TemplateContext;
  /** 惰性 #ask/#show 全局自增 id */
  private static askSeq = 0;
  /** 当前展开中的模板实参帧栈（单层即可：#invoke 只回溯最近一层模板实参） */
  private frame: TemplateFrame | null = null;
  /** #arraydefine 定义的数组（Arrays 扩展子集；单页展开生命周期） */
  private ctxArrays: Map<string, string[]> = new Map();

  constructor(ctx: TemplateContext) {
    this.ctx = ctx;
  }

  /** 登记惰性 #ask/#show 查询并返回占位标记（渐进渲染）；
   *  非惰性上下文返回空串，调用方应回退为立即执行。
   *  供 #ask 解析函数与站点模块（#invoke 内部产生 SMW 查询）共用 */
  static registerLazyAsk(ctx: TemplateContext, args: string[], isShow: boolean): string {
    if (ctx.lazyAsk === true && ctx.pendingAsks !== undefined && ctx.pendingAsks !== null) {
      TemplateEngine.askSeq++;
      const pa: PendingAsk = { id: TemplateEngine.askSeq, args: args, isShow: isShow };
      ctx.pendingAsks.push(pa);
      return PLACEHOLDER_MARK + 'ASK:' + pa.id + '\u0000';
    }
    return '';
  }

  /** 登记惰性 #invoke 延迟调用并返回占位标记；非惰性上下文返回空串（调用方立即执行）。
   *  供站点模块把自身重计算（查询+建图等）推迟到 Reader 阶段 2，不阻塞首帧 */
  static registerLazyInvoke(ctx: TemplateContext, module: string, func: string, args: string[]): string {
    if (ctx.lazyAsk === true && ctx.pendingInvokes !== undefined && ctx.pendingInvokes !== null) {
      TemplateEngine.askSeq++;
      const pi: PendingInvoke = { id: TemplateEngine.askSeq, module: module, func: func, args: args };
      ctx.pendingInvokes.push(pi);
      return PLACEHOLDER_MARK + 'INV:' + pi.id + '\u0000';
    }
    return '';
  }

  async expand(text: string): Promise<string> {
    return await this.expandInner(text, 0, [], false);
  }

  /** inFnArg：当前文本是否位于解析函数实参内（如 {{#expr:{{#show:…}}*2}}）。
   *  实参内的 #ask/#show 结果会被同步消费（求值/比较），必须立即执行；
 *  其余位置（页面顶层、模板体）可惰性登记，占位结果在解析前回填 */
  private async expandInner(text: string, depth: number, stack: string[], inFnArg: boolean): Promise<string> {
    if (depth > MAX_DEPTH) {
      return '';
    }
    const sb: string[] = [];
    let i = 0;
    const n = text.length;
    while (i < n) {
      const c = text.charAt(i);
      if (c === '<') {
        // HTML 注释
        if (text.startsWith('<!--', i)) {
          const end = text.indexOf('-->', i + 4);
          if (end >= 0) {
            i = end + 3;
            continue;
          }
        }
        // 保护块（nowiki/pre 等）原样保留；<ref> 例外——脚注体内的
        // {{模板}}/[[链接]] 必须展开（Cite 语义），标签本体重组保留
        const tagEnd = BraceUtil.skipXmlBlock(text, i);
        if (tagEnd > i) {
          const block = text.substring(i, tagEnd);
          const refOpen = block.match(/^<ref\b[^>]*>/i);
          if (refOpen !== null) {
            const refClose = block.toLowerCase().lastIndexOf('</ref>');
            const refInner = refClose >= 0
              ? block.substring(refOpen[0].length, refClose) : block.substring(refOpen[0].length);
            const expanded = await this.expandInner(refInner, depth, stack, inFnArg);
            sb.push(refOpen[0] + expanded + (refClose >= 0 ? '</ref>' : ''));
          } else {
            sb.push(block);
          }
          i = tagEnd;
          continue;
        }
      }
      if (c === '{' && i + 1 < n && text.charAt(i + 1) === '{') {
        const end = BraceUtil.findTemplateClose(text, i);
        if (end < 0) {
          sb.push(c);
          i++;
          continue;
        }
        const inner = text.substring(i + 2, end - 2);
        sb.push(await this.expandOne(inner, depth, stack, inFnArg));
        i = end;
        continue;
      }
      if (c === '[' && i + 1 < n && text.charAt(i + 1) === '[') {
        const end = BraceUtil.findBracketClose(text, i);
        if (end < 0) {
          sb.push(c);
          i++;
          continue;
        }
        const inner = text.substring(i + 2, end - 2);
        // 展开链接内的模板（如 [[{{FULLPAGENAME}}/子页|显示]]）。
        //  链接目标/标签被同步用于构成链接本身，按实参上下文处理（同步）
        const expandedInner = await this.expandInner(inner, depth + 1, stack, true);
        const dc = this.findTopLevelDoubleColon(expandedInner);
        if (dc >= 0) {
          // SMW [[属性::目标|标签]]：语义标注之外仍是普通内部链接，输出 [[目标|标签]]
          //  交解析器渲染——目标页存在则可点击跳转，不存在则退化为纯文本（与 MediaWiki
          //  对 wikipage 型/值型属性的渲染一致）；属性存储仍取目标
          const prop = expandedInner.substring(0, dc).trim();
          const value = expandedInner.substring(dc + 2).trim();
          const pipe = value.indexOf('|');
          const target = pipe >= 0 ? value.substring(0, pipe).trim() : value;
          if (this.ctx.capture !== undefined && this.ctx.capture !== null) {
            this.ctx.capture(prop, target);
          }
          const label = pipe >= 0 ? value.substring(pipe + 1).trim() : '';
          if (target.length === 0) {
            sb.push(label);
          } else {
            sb.push(label.length > 0 ? '[[' + target + '|' + label + ']]' : '[[' + target + ']]');
          }
          i = end;
          continue;
        }
        sb.push('[[' + expandedInner + ']]');
        i = end;
        continue;
      }
      sb.push(c);
      i++;
    }
    return sb.join('');
  }

  private async expandOne(inner: string, depth: number, stack: string[], inFnArg: boolean): Promise<string> {
    // Special 页面（名称含 ':'，需特殊处理分隔符）
    const trimmed = inner.trim();
    if (trimmed.startsWith('Special:PrefixIndex/')) {
      let sep = -1;
      let i = 0;
      const tn = trimmed.length;
      while (i < tn) {
        const c = trimmed.charAt(i);
        if (c === '{' && i + 1 < tn && trimmed.charAt(i + 1) === '{') {
          const e = BraceUtil.findTemplateClose(trimmed, i);
          if (e < 0) {
            break;
          }
          i = e;
          continue;
        }
        if (c === '[' && i + 1 < tn && trimmed.charAt(i + 1) === '[') {
          const e = BraceUtil.findBracketClose(trimmed, i);
          if (e < 0) {
            break;
          }
          i = e;
          continue;
        }
        if (c === '|') {
          sep = i;
          break;
        }
        i++;
      }
      let name = sep >= 0 ? trimmed.substring(0, sep) : trimmed;
      const rest = sep >= 0 ? trimmed.substring(sep + 1) : '';
      if (name.indexOf('{{') >= 0) {
        name = (await this.expandInner(name, depth + 1, stack, true)).trim();
      }
      return await this.specialPrefixIndex(name, rest);
    }
    // 找名称结束位置（顶层 ':' 或 '|'，跳过嵌套 {{ }} / [[ ]]）
    let nameEnd = -1;
    let i = 0;
    const n = inner.length;
    while (i < n) {
      const c = inner.charAt(i);
      if (c === '{' && i + 1 < n && inner.charAt(i + 1) === '{') {
        const e = BraceUtil.findTemplateClose(inner, i);
        if (e < 0) {
          break;
        }
        i = e;
        continue;
      }
      if (c === '[' && i + 1 < n && inner.charAt(i + 1) === '[') {
        const e = BraceUtil.findBracketClose(inner, i);
        if (e < 0) {
          break;
        }
        i = e;
        continue;
      }
      if (c === ':' || c === '|') {
        nameEnd = i;
        break;
      }
      i++;
    }
    let name = (nameEnd >= 0 ? inner.substring(0, nameEnd) : inner).trim();
    const rest = nameEnd >= 0 ? inner.substring(nameEnd + 1) : '';
    // 展开名称中的嵌套模板（如 {{Special:PrefixIndex/{{FULLPAGENAME}}/ ...}}）。
    //  名称被同步用于查找模板/函数，按实参上下文处理（同步）
    if (name.indexOf('{{') >= 0) {
      name = (await this.expandInner(name, depth + 1, stack, true)).trim();
    }
    if (name.length === 0) {
      return '';
    }
    // 魔术管道符
    if (name === '!') {
      return '|';
    }
    if (name === '=') {
      return '=';
    }
    if (name === '-') {
      return '';
    }
    // 行为开关 / 控制
    if (name === 'DEFAULTSORT' || name === 'DISPLAYTITLE' || name === 'DEFAULTSORTKEY') {
      return '';
    }
    // 解析函数
    if (name.startsWith('#')) {
      return await this.parserFunction(name, rest, depth, stack, inFnArg);
    }
    // 主命名空间转页 {{:Page}}（全页转录）
    if (name.startsWith(':')) {
      return await this.transcludePage(name.substring(1), depth, stack, undefined, false);
    }
    // 魔术字
    const magic = this.magicWord(name, rest);
    if (magic !== null) {
      return magic;
    }
    // Special 页面
    if (name.startsWith('Special:PrefixIndex/')) {
      return await this.specialPrefixIndex(name, rest);
    }
    // 普通模板
    return await this.expandTemplate(name, rest, depth, stack, inFnArg);
  }

  /** {{Special:PrefixIndex/<前缀>|...}}：列出指定前缀的子页面 */
  private async specialPrefixIndex(name: string, rest: string): Promise<string> {
    const prefix = name.substring('Special:PrefixIndex/'.length);
    const args = BraceUtil.splitTopLevel(rest, '|');
    let stripPrefix = false;
    for (const a of args) {
      const eq = this.topLevelIndexOf(a, '=');
      if (eq > 0) {
        const key = a.substring(0, eq).trim().toLowerCase();
        const val = a.substring(eq + 1).trim();
        if (key === 'stripprefix' && val === '1') {
          stripPrefix = true;
        }
      }
    }
    if (this.ctx.index === null) {
      return '';
    }
    const titles = this.ctx.index.titlesByPrefix(prefix);
    const sb: string[] = [];
    for (const t of titles) {
      const display = stripPrefix && t.length > prefix.length ? t.substring(prefix.length) : t;
      sb.push('* [[' + t + '|' + display + ']]');
    }
    return sb.join('\n');
  }

  /** 解析函数。实参的展开结果会被同步消费（求值/比较/选择分支），
   *  故实参内一律以同步上下文展开（inFnArg=true） */
  private async parserFunction(name: string, rest: string, depth: number, stack: string[],
    inFnArg: boolean): Promise<string> {
    const args = BraceUtil.splitTopLevel(rest, '|');
    const fname = name.toLowerCase();
    if (fname === '#if') {
      // MediaWiki 语义：实参先展开再判真值（{{#if:{{lc:…}}}} 展开为空 → else 分支）
      const test = await this.expandInner(this.get(args, 0), depth + 1, stack, true);
      return await this.expandInner(test.trim().length > 0 ? this.get(args, 1) : this.get(args, 2), depth + 1, stack, true);
    }
    if (fname === '#ifeq') {
      const a = (await this.expandInner(this.get(args, 0), depth + 1, stack, true)).trim();
      const b = (await this.expandInner(this.get(args, 1), depth + 1, stack, true)).trim();
      return await this.expandInner(a === b ? this.get(args, 2) : this.get(args, 3), depth + 1, stack, true);
    }
    if (fname === '#ifexist') {
      // 标题参数先展开嵌套魔术字/模板（如 {{#ifexist:文件:{{NAMESPACE}}-{{PAGENAME}}.jpg|...}}）
      const title = (await this.expandInner(this.get(args, 0), depth + 1, stack, true)).trim();
      const exists = this.ctx.index !== null && this.ctx.index.pageExists(title);
      return await this.expandInner(exists ? this.get(args, 1) : this.get(args, 2), depth + 1, stack, true);
    }
    if (fname === '#iferror') {
      // 展开 test 后按 MediaWiki 语义检测错误标记；本引擎求值失败产出空串而非 error class，
      //  空串按「非错误」走 else 分支（与多数调用点「兜底默认值」用法一致）
      const test = await this.expandInner(this.get(args, 0), depth + 1, stack, true);
      const hasErr = test.includes('class="error"') || test.includes('{{#');
      return await this.expandInner(hasErr ? this.get(args, 1) : this.get(args, 2), depth + 1, stack, true);
    }
    if (fname === '#ifexpr') {
      const expr = await this.expandInner(this.get(args, 0), depth + 1, stack, true);
      const s = expr.replace(/\s+/g, '');
      const v = s.length > 0 ? this.evalExprValue(s) : NaN;
      const truthy = !isNaN(v) && v !== 0;
      return await this.expandInner(truthy ? this.get(args, 1) : this.get(args, 2), depth + 1, stack, true);
    }
    if (fname === '#switch') {
      // 值与键都先展开再比较（MediaWiki 语义；{{#switch:{{lc:Fall}}|fall=秋季}} 此前不展开永不命中）
      const value = (await this.expandInner(this.get(args, 0), depth + 1, stack, true)).trim();
      let def = '';
      let matched = false;
      for (let i = 1; i < args.length; i++) {
        const seg = args[i];
        const eq = this.topLevelIndexOf(seg, '=');
        if (eq < 0) {
          // 尾段裸值 = 默认结果；中间裸值 = fall-through 候选（命中后取下一个带 = 段）
          if (i === args.length - 1) {
            def = seg;
          } else if ((await this.expandInner(seg, depth + 1, stack, true)).trim() === value) {
            matched = true;
          }
          continue;
        }
        const key = (await this.expandInner(seg.substring(0, eq), depth + 1, stack, true)).trim();
        const val = seg.substring(eq + 1);
        if (key === '#default') {
          def = val;
        } else if (key === value || matched) {
          // MediaWiki 语义：switch 分支结果去首尾空白——多行 case 源码的分支值带
          //  尾随换行，不 trim 会把 {|-开表行 / !-表头行从属性中间劈成两行（属性泄漏）
          return (await this.expandInner(val, depth + 1, stack, true)).trim();
        }
      }
      const defOut = (await this.expandInner(def, depth + 1, stack, true)).trim();
      return defOut;
    }
    if (fname === '#expr') {
      // 先展开参数中的嵌套调用（如 {{#expr:{{#show:...}}*2}}），再求值
      const expr = await this.expandInner(this.get(args, 0), depth + 1, stack, true);
      return this.evalExpr(expr);
    }
    if (fname === '#titleparts') {
      const title = this.get(args, 0);
      const parts = title.split('/');
      const count = parseInt(this.get(args, 1));
      const from = parseInt(this.get(args, 2));
      let out = parts;
      if (!isNaN(count) && count >= 0) {
        out = parts.slice(0, count);
      }
      if (!isNaN(from) && from >= 1 && from <= out.length) {
        out = out.slice(from - 1);
      }
      return out.join('/');
    }
    if (fname === '#pos' || fname === '#sub' || fname === '#replace' ||
      fname === '#explode' || fname === '#len') {
      // StringFunctions（同步展开实参）
      const a0 = await this.expandInner(this.get(args, 0), depth + 1, stack, true);
      const a1 = await this.expandInner(this.get(args, 1), depth + 1, stack, true);
      const a2 = await this.expandInner(this.get(args, 2), depth + 1, stack, true);
      if (fname === '#pos') {
        const off = a2.length > 0 ? parseInt(a2) : 0;
        const at = a0.indexOf(a1, isNaN(off) || off < 0 ? 0 : off);
        return at >= 0 ? String(at) : '';
      }
      if (fname === '#sub') {
        let start = parseInt(a1);
        let len = a2.length > 0 ? parseInt(a2) : NaN;
        if (isNaN(start)) {
          return a0;
        }
        if (start < 0) {
          start = Math.max(0, a0.length + start);
        }
        if (isNaN(len)) {
          return a0.substring(start);
        }
        if (len < 0) {
          len = a0.length + len - start;
        }
        return a0.substring(start, start + len);
      }
      if (fname === '#replace') {
        return a1.length > 0 ? a0.split(a1).join(a2) : a0;
      }
      if (fname === '#explode') {
        if (a1.length === 0) {
          return a0;
        }
        const parts = a0.split(a1);
        let n = parseInt(a2.length > 0 ? a2 : '0');
        if (isNaN(n)) {
          n = 0;
        }
        if (n < 0) {
          n = parts.length + n;
        }
        return n >= 0 && n < parts.length ? parts[n] : '';
      }
      return String(a0.length); // #len
    }
    if (fname === '#arraydefine' || fname === '#arrayindex') {
      // Arrays 扩展子集（仅 dump 实际用到的两个函数）
      const key = this.get(args, 0).trim();
      if (fname === '#arraydefine') {
        const vals = await this.expandInner(this.get(args, 1), depth + 1, stack, true);
        const delim = args.length > 2 && this.get(args, 2).trim().length > 0
          ? this.get(args, 2).trim() : ',';
        const list = vals.length === 0 ? [] : vals.split(delim);
        this.ctxArrays.set(key, list);
        return '';
      }
      const arr = this.ctxArrays.get(key);
      if (arr === undefined) {
        return await this.expandInner(this.get(args, 2), depth + 1, stack, true);
      }
      let idx = parseInt((await this.expandInner(this.get(args, 1), depth + 1, stack, true)).trim());
      if (isNaN(idx)) {
        idx = 1;
      }
      // Lua 1-based / PHP Arrays 扩展 1-based 索引，支持负数倒数
      const i = idx < 0 ? arr.length + idx + 1 : idx;
      return i >= 1 && i <= arr.length ? arr[i - 1] : '';
    }
    if (fname === '#tag') {
      // {{#tag:tagname|content|attrs...}}：按标签类型分派
      const tag = this.get(args, 0).trim().toLowerCase();
      const content = await this.expandInner(this.get(args, 1), depth + 1, stack, true);
      if (tag === 'templatestyles' || tag === 'seo' || tag === 'syntaxhighlight' ||
        tag === 'source' || tag === 'pre') {
        return '';
      }
      if (tag === 'nowiki') {
        return content;
      }
      // ref/references/gallery 等交回解析层（原样重建标签让 Parser 机制处理）
      return '<' + tag + '>' + content + '</' + tag + '>';
    }
    if (fname === '#lst' || fname === '#lsth') {
      // LabeledSectionTransclusion：#lst:页|标签（<section begin=end>）、#lsth:页|标题（按章节标题）
      const title = (await this.expandInner(this.get(args, 0), depth + 1, stack, true)).trim();
      const second = (await this.expandInner(this.get(args, 1), depth + 1, stack, true)).trim();
      const mode: 'label' | 'heading' = fname === '#lst' ? 'label' : 'heading';
      return await this.transcludePage(title, depth, stack, second.length > 0 ? second : undefined, mode === 'heading');
    }
    if (fname === '#invoke') {
      const module = this.get(args, 0).trim();
      const func = this.get(args, 1).trim();
      const callArgs: string[] = [];
      for (let i = 2; i < args.length; i++) {
        callArgs.push(args[i]);
      }
      // 父框架实参继承（模拟 Lua Module:Arguments.getArgs 的父参数回溯）：
      //  {{craft required item|物品名|数量}} 的模板体是 {{#invoke:collection|craftMaterials}}，
      //  #invoke 自身无直接实参，取所在模板的实参
      if (callArgs.length === 0 && this.frame !== null) {
        for (const p of this.frame.positional) {
          callArgs.push(p);
        }
        for (const nv of this.frame.named) {
          callArgs.push(nv);
        }
      }
      if (this.ctx.invokeHandler !== null) {
        return await this.ctx.invokeHandler.invoke(module, func, callArgs, this.ctx);
      }
      return this.placeholder('Lua 模块 ' + module + ' 未实现');
    }
    if (fname === '#ask' || fname === '#show') {
      // 渐进渲染：惰性模式登记不执行，返回占位标记（Reader 阶段 2 执行后回填）。
      //  条件是「不在解析函数实参内」——实参内的结果会被同步消费（如 {{#expr:{{#show:…}}*2}}
      //  商店价格），必须立即执行，否则占位文本被当数值解析（价格变 0）；
      //  其余位置（页面顶层、模板体内）登记后回填即可，模板嵌套的深查询不再阻塞首帧
      if (!inFnArg) {
        const mark = TemplateEngine.registerLazyAsk(this.ctx, args, fname === '#show');
        if (mark.length > 0) {
          return mark;
        }
      }
      if (this.ctx.askHandler !== undefined && this.ctx.askHandler !== null) {
        return await this.ctx.askHandler.query(args, this.ctx, fname === '#show');
      }
      return this.placeholder('SMW 语义查询离线版暂不支持');
    }
    if (fname === '#set' || fname === '#subobject' || fname === '#set_internal' || fname === '#declare') {
      if (fname === '#set' && this.ctx.capture !== undefined && this.ctx.capture !== null) {
        for (const a of args) {
          const eq = this.topLevelIndexOf(a, '=');
          if (eq > 0) {
            const prop = a.substring(0, eq).trim();
            if (prop.length > 0) {
              // 值先展开再捕获：模板参数代入后会残留 {{#ifeq:}}/{{#if:}} 等未求值
              //  解析函数（如 采集道具2={{#if:X|物品:X}}），直接存原始串会把
              //  wikitext 源码当属性值；空值跳过（SMW 空赋值不存储）
              const value = (await this.expandInner(a.substring(eq + 1), depth + 1, stack, true)).trim();
              if (value.length > 0) {
                this.ctx.capture(prop, value);
              }
            }
          }
        }
      }
      return '';
    }
    if (fname === '#related' || fname === '#categorytree' || fname === '#dpl' ||
      fname === '#language' || fname === '#seo' || fname === '#widget' ||
      fname === '#tag:templatestyles' || fname === '#time') {
      // 站点 SEO 元数据 / Widget 标记：离线渲染无意义，吞掉（未知函数会保留原文泄漏花括号）
      return '';
    }
    // 未知解析函数：保留原文
    return '{{' + name + ':' + rest + '}}';
  }

  private magicWord(name: string, rest: string): string | null {
    const upper = name.toUpperCase();
    const title = this.ctx.pageTitle;
    const ci = title.indexOf(':');
    const ns = ci >= 0 ? title.substring(0, ci) : '';
    const page = ci >= 0 ? title.substring(ci + 1) : title;
    const segs = page.split('/');
    const pagename = segs[segs.length - 1];
    const base = segs.length > 1 ? segs.slice(0, segs.length - 1).join('/') : pagename;
    const root = segs[0];
    const subpage = segs.length > 1 ? segs.slice(1).join('/') : '';

    switch (upper) {
      case 'PAGENAME': return pagename;
      case 'FULLPAGENAME': return title;
      case 'PAGENAMEE': return this.urlEncode(pagename);
      case 'FULLPAGENAMEE': return this.urlEncode(title);
      case 'NAMESPACE': return ns;
      case 'NAMESPACEE': return this.urlEncode(ns);
      case 'BASEPAGENAME': return base;
      case 'ROOTPAGENAME': return root;
      case 'SUBPAGENAME': return subpage;
      case 'SITENAME': return 'OhMyWiki';
      case 'LC': return this.get(rest.split('|'), 0).toLowerCase();
      case 'UC': return this.get(rest.split('|'), 0).toUpperCase();
      case 'LCFIRST': {
        const s = this.get(rest.split('|'), 0);
        return s.length > 0 ? s.charAt(0).toLowerCase() + s.substring(1) : s;
      }
      case 'UCFIRST': {
        const s = this.get(rest.split('|'), 0);
        return s.length > 0 ? s.charAt(0).toUpperCase() + s.substring(1) : s;
      }
      case 'URLENCODE': return this.urlEncode(this.get(rest.split('|'), 0));
      // URL 构造类（离线无站点基址）：'#' 保持 [{{fullurl:…}} label] 外链形态可渲染、点击无操作
      case 'FULLURL': case 'FULLURLE': case 'LOCALURL': case 'LOCALURLE': case 'URL':
        return '#';
      case 'NS': {
        // {{ns:<id 或名>}} → 命名空间规范名（{{ns:User}}→'User'）；主 ns 返回 ''。
        //  未知名原样返回（不返回空——否则 #switch 键展开后与主ns空 NAMESPACE 相等，
        //  会错命中空分支使整个 #default 内容塌缩，如 Infobox villager 的 ns:User talk）
        const arg = this.get(rest.split('|'), 0).trim();
        const byId: Record<string, string> = {
          '0': '', '-2': 'Media', '-1': 'Special', '2': 'User', '3': 'User talk',
          '4': 'Project', '6': 'File', '8': 'MediaWiki', '10': 'Template',
          '12': 'Help', '14': 'Category', '828': 'Module'
        };
        const byName: Record<string, string> = {
          'user': 'User', '用户': 'User', 'user talk': 'User talk', '用户讨论': 'User talk',
          'file': 'File', '文件': 'File', 'file talk': 'File talk',
          'image': 'File', 'template': 'Template', '模板': 'Template',
          'template talk': 'Template talk', 'help': 'Help', '帮助': 'Help',
          'category': 'Category', '分类': 'Category', 'module': 'Module', '模块': 'Module',
          'project': 'Project', 'media': 'Media', 'special': 'Special'
        };
        if (byId[arg] !== undefined) {
          return byId[arg];
        }
        const canon = byName[arg.toLowerCase()];
        return canon !== undefined ? canon : arg;
      }
      default:
        // CURRENT*/LOCAL* 等时间相关 → 空
        if (upper.startsWith('CURRENT') || upper.startsWith('LOCAL') || upper === 'SERVER' ||
          upper === 'REVISION' || upper === 'NUMBEROF' || upper === 'PAGESIN') {
          return '';
        }
        return null;
    }
  }

  private async expandTemplate(name: string, rest: string, depth: number, stack: string[],
    inFnArg: boolean): Promise<string> {
    if (stack.indexOf(name) >= 0) {
      // 循环引用保护
      return '';
    }
    if (this.ctx.index === null) {
      return '';
    }
    let source: string | null = null;
    try {
      source = await this.ctx.index.readTemplate(name);
    } catch (e) {
      Logger.warn(TAG, 'read template failed: ' + name + ' ' + JSON.stringify(e));
    }
    if (source === null) {
      return '';
    }
    const cleaned = this.cleanSource(source);
    const args = BraceUtil.splitTopLevel(rest, '|');
    const named: Map<string, string> = new Map();
    const positional: string[] = [];
    for (const a of args) {
      const eq = this.topLevelIndexOf(a, '=');
      if (eq > 0) {
        // MediaWiki 语义：参数值去除首尾空白（含换行）——
        //  `|概率1=35\n` 的尾随换行若保留，代入 [[..::35\n%]] 会产生跨行断链
        named.set(a.substring(0, eq).trim(), a.substring(eq + 1).trim());
      } else {
        positional.push(a.trim());
      }
    }
    const substituted = this.substituteParams(cleaned, named, positional);
    const newStack = stack.concat([name]);
    // 模板体展开期间登记实参帧，供体内 #invoke 无直接实参时回溯（getArgs 语义）
    const namedList: string[] = [];
    named.forEach((v: string, k: string): void => {
      namedList.push(k + '=' + v);
    });
    const prevFrame = this.frame;
    this.frame = { positional: positional, named: namedList };
    try {
      return await this.expandInner(substituted, depth + 1, newStack, inFnArg);
    } finally {
      this.frame = prevFrame;
    }
  }

  /** 参数替换：{{{key}}} / {{{key|default}}} / {{{1}}}；默认值支持嵌套 {{{...}}}（递归替换） */
  private substituteParams(source: string, named: Map<string, string>, positional: string[], depth: number = 0): string {
    if (depth > 8) {
      return '';
    }
    const sb: string[] = [];
    let i = 0;
    const n = source.length;
    while (i < n) {
      if (i + 2 < n && source.charCodeAt(i) === 123 && source.charCodeAt(i + 1) === 123 && source.charCodeAt(i + 2) === 123) {
        const end = BraceUtil.skipTripleBrace(source, i);
        if (end < 0) {
          sb.push(source.charAt(i));
          i++;
          continue;
        }
        const inner = source.substring(i + 3, end - 3);
        let key = inner;
        let def: string | null = null;
        const pipe = this.topLevelIndexOf(inner, '|');
        if (pipe >= 0) {
          key = inner.substring(0, pipe);
          def = inner.substring(pipe + 1);
        }
        const k = key.trim();
        let val: string | null = null;
        if (named.has(k)) {
          val = named.get(k) as string;
        } else {
          const num = parseInt(k);
          if (!isNaN(num) && num >= 1 && num <= positional.length) {
            val = positional[num - 1];
          }
        }
        if (val === null) {
          val = def !== null ? this.substituteParams(def, named, positional, depth + 1) : '';
        }
        sb.push(val);
        i = end;
        continue;
      }
      sb.push(source.charAt(i));
      i++;
    }
    return sb.join('');
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

  private get(arr: string[], idx: number): string {
    return idx < arr.length ? arr[idx] : '';
  }

  private placeholder(reason: string): string {
    return PLACEHOLDER_MARK + reason + '\u0000';
  }

  private urlEncode(s: string): string {
    let out = '';
    for (let i = 0; i < s.length; i++) {
      const ch = s.charAt(i);
      const code = s.charCodeAt(i);
      if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
        ch === '-' || ch === '_' || ch === '.' || ch === '~') {
        out += ch;
      } else {
        let hex = code.toString(16);
        if (hex.length < 2) {
          hex = '0' + hex;
        }
        out += '%' + hex.toUpperCase();
      }
    }
    return out;
  }

  /** 算术表达式求值（MediaWiki #expr 子集：比较/加减乘除 mod div/round/floor/ceil/trunc/abs、
   *  括号、一元正负、科学计数法）。优先级：比较 < round < 加减 < 乘除 < 一元 < 函数/数字 */
  private evalExpr(expr: string): string {
    const v = this.evalExprValue(expr.replace(/\s+/g, ''));
    if (isNaN(v)) {
      return '';
    }
    const rounded = Math.round(v * 1e9) / 1e9;
    return String(rounded);
  }

  /** 数值形态求值（失败返回 NaN，供 #ifexpr 真值判断） */
  private evalExprValue(s: string): number {
    if (s.length === 0) {
      return NaN;
    }
    const pos: number[] = [0];
    const result = this.parseExprCompare(s, pos);
    if (pos[0] < s.length || isNaN(result)) {
      return NaN;
    }
    return result;
  }

  /** PHP round 语义（.5 远离零），n 可为负 */
  private phpRound(v: number, n: number): number {
    const m = Math.pow(10, n);
    const scaled = Math.abs(v) * m;
    const r = Math.round(scaled);
    return (v < 0 ? -r : r) / m;
  }

  private parseExprCompare(s: string, pos: number[]): number {
    let v = this.parseExprRound(s, pos);
    while (pos[0] < s.length) {
      let op = '';
      const two = s.substring(pos[0], pos[0] + 2);
      if (two === '<=' || two === '>=' || two === '==' || two === '<>' || two === '!=') {
        op = two;
        pos[0] += 2;
      } else {
        const one = s.charAt(pos[0]);
        if (one === '<' || one === '>' || one === '=') {
          op = one;
          pos[0] += 1;
        } else {
          break;
        }
      }
      const rhs = this.parseExprRound(s, pos);
      switch (op) {
        case '<': v = v < rhs ? 1 : 0; break;
        case '>': v = v > rhs ? 1 : 0; break;
        case '<=': v = v <= rhs ? 1 : 0; break;
        case '>=': v = v >= rhs ? 1 : 0; break;
        default: v = v === rhs ? 1 : 0; break; // = == <> !=
      }
    }
    return v;
  }

  /** round 层：加法结果 <round n>（n 为要保留的小数位数，可为负） */
  private parseExprRound(s: string, pos: number[]): number {
    let v = this.parseExprAdd(s, pos);
    while (s.startsWith('round', pos[0])) {
      pos[0] += 5;
      const n = this.parseExprAdd(s, pos);
      v = this.phpRound(v, n);
    }
    return v;
  }

  private parseExprAdd(s: string, pos: number[]): number {
    let v = this.parseExprMul(s, pos);
    while (pos[0] < s.length) {
      const c = s.charAt(pos[0]);
      if (c === '+') {
        pos[0]++;
        v += this.parseExprMul(s, pos);
      } else if (c === '-') {
        pos[0]++;
        v -= this.parseExprMul(s, pos);
      } else {
        break;
      }
    }
    return v;
  }

  private parseExprMul(s: string, pos: number[]): number {
    let v = this.parseExprUnary(s, pos);
    while (pos[0] < s.length) {
      const c = s.charAt(pos[0]);
      if (c === '*') {
        pos[0]++;
        v *= this.parseExprUnary(s, pos);
      } else if (c === '/') {
        pos[0]++;
        const d = this.parseExprUnary(s, pos);
        v = d === 0 ? 0 : v / d;
      } else if (c === '%') {
        pos[0]++;
        const d = this.parseExprUnary(s, pos);
        v = d === 0 ? 0 : v % d;
      } else if (s.startsWith('mod', pos[0])) {
        pos[0] += 3;
        const d = this.parseExprUnary(s, pos);
        v = d === 0 ? 0 : v % d;
      } else if (s.startsWith('div', pos[0])) {
        pos[0] += 3;
        const d = this.parseExprUnary(s, pos);
        v = d === 0 ? 0 : Math.trunc(v / d);
      } else {
        break;
      }
    }
    return v;
  }

  private parseExprUnary(s: string, pos: number[]): number {
    if (pos[0] < s.length && s.charAt(pos[0]) === '-') {
      pos[0]++;
      return -this.parseExprUnary(s, pos);
    }
    if (pos[0] < s.length && s.charAt(pos[0]) === '+') {
      pos[0]++;
      return this.parseExprUnary(s, pos);
    }
    // 函数前缀：floor( ceil( trunc( abs( round(
    const fn = s.substring(pos[0], pos[0] + 6).match(/^(floor|ceil|trunc|abs|round)\(/);
    if (fn !== null) {
      const name = fn[1];
      pos[0] += name.length + 1;
      const v = this.parseExprCompare(s, pos);
      if (pos[0] < s.length && s.charAt(pos[0]) === ')') {
        pos[0]++;
      }
      switch (name) {
        case 'floor': return Math.floor(v);
        case 'ceil': return Math.ceil(v);
        case 'trunc': return Math.trunc(v);
        case 'abs': return Math.abs(v);
        default: return this.phpRound(v, 0); // round(x) 等价 round(x, 0)
      }
    }
    if (pos[0] < s.length && s.charAt(pos[0]) === '(') {
      pos[0]++;
      const v = this.parseExprCompare(s, pos);
      if (pos[0] < s.length && s.charAt(pos[0]) === ')') {
        pos[0]++;
      }
      return v;
    }
    // 数字（含科学计数法）
    let j = pos[0];
    while (j < s.length && (s.charAt(j) >= '0' && s.charAt(j) <= '9' || s.charAt(j) === '.')) {
      j++;
    }
    if (j > pos[0] && j < s.length && (s.charAt(j) === 'e' || s.charAt(j) === 'E')) {
      let k = j + 1;
      if (k < s.length && (s.charAt(k) === '+' || s.charAt(k) === '-')) {
        k++;
      }
      const d0 = k;
      while (k < s.length && s.charAt(k) >= '0' && s.charAt(k) <= '9') {
        k++;
      }
      if (k > d0) {
        j = k;
      }
    }
    if (j === pos[0]) {
      pos[0] = s.length;
      return 0;
    }
    const num = parseFloat(s.substring(pos[0], j));
    pos[0] = j;
    return num;
  }

  /** 页面转录（{{:Page}} 全页 / {{#lst:页|标签}} / {{#lsth:页|标题}}）：
   *  - 循环防护：stack key 统一为 ':'+规范标题（不带标签后缀，防 #lst/#lsth 互引绕过）
   *  - 深度：转录本身不耗 depth（留给段内模板嵌套，防 页→模板→#lst→段内模板 提前触顶）
   *  - 热门被转录页走 WikiIndex pageCache */
  private async transcludePage(rawTitle: string, depth: number, stack: string[],
    label: string | undefined, byHeading: boolean): Promise<string> {
    if (this.ctx.index === null || rawTitle.length === 0) {
      return '';
    }
    const title = this.ctx.index.resolveLink(rawTitle, this.ctx.pageTitle);
    if (title === null) {
      return '';
    }
    const key = ':' + title;
    if (stack.indexOf(key) >= 0) {
      return '';
    }
    const source = await this.ctx.index.readPageCached(title);
    if (source === null) {
      return '';
    }
    let cleaned = this.cleanSource(source);
    let seg = cleaned;
    if (byHeading) {
      // #lsth:页|标题 —— 从匹配标题行到下一个同级/更高级标题前（不含标题行）
      const escaped = label !== undefined ? label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') : '';
      if (escaped.length === 0) {
        return '';
      }
      const hm = cleaned.match(new RegExp('^([={2,6})\\s*' + escaped + '\\s*\\1\\s*$', 'm'));
      if (hm === null || hm.index === undefined) {
        return '';
      }
      const level = hm[1].length;
      const bodyStart = hm.index + hm[0].length;
      const nextM = cleaned.substring(bodyStart)
        .match(new RegExp('^([={2,' + level + '})[^=]', 'm'));
      const bodyEnd = nextM !== null && nextM.index !== undefined
        ? bodyStart + nextM.index : cleaned.length;
      seg = cleaned.substring(bodyStart, bodyEnd);
    } else if (label !== undefined) {
      // #lst:页|标签 —— <section begin="标签"/> 到对应 end 标记；同名多段全部拼接
      const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const beginRe = new RegExp('<section\\s+begin\\s*=\\s*(?:"' + escaped + '"|\'' + escaped +
        '\'|' + escaped + ')\\s*/\\s*>', 'gi');
      const endRe = new RegExp('<section\\s+end\\s*=\\s*(?:"' + escaped + '"|\'' + escaped +
        '\'|' + escaped + ')\\s*/\\s*>', 'gi');
      const parts: string[] = [];
      let bm: RegExpExecArray | null;
      while ((bm = beginRe.exec(cleaned)) !== null) {
        endRe.lastIndex = bm.index + bm[0].length;
        const em = endRe.exec(cleaned);
        const segEnd = em !== null ? em.index : cleaned.length;
        parts.push(cleaned.substring(bm.index + bm[0].length, segEnd));
        if (em === null) {
          break;
        }
      }
      seg = parts.join('\n');
    }
    // 残留 section 标记剥离（转录内容不应泄漏标记）
    seg = seg.replace(/<section\s+(?:begin|end)\s*=[^>]*\/?>/gi, '');
    return await this.expandInner(seg, depth, stack.concat(key), false);
  }

  /** 模板源码清理：注释、noinclude 移除、includeonly 标签剥离（内容保留）。
   * 容错：转储中可能存在未闭合的 <includeonly> 标签，
   * MediaWiki 对未闭合标签按“延伸到文末”处理，等价于直接剥标签保内容。 */
  private cleanSource(src: string): string {
    let s = src.replace(/<!--[\s\S]*?-->/g, '');
    // onlyinclude：仅保留其中内容
    const only = s.match(/<onlyinclude>[\s\S]*?<\/onlyinclude>/g);
    if (only !== null && only.length > 0) {
      return only.map((seg: string) => seg.replace(/<\/?onlyinclude>/g, '')).join('');
    }
    // noinclude 移除（含未闭合：从标签到文末）
    s = s.replace(/<noinclude>[\s\S]*?<\/noinclude>/g, '');
    s = s.replace(/<noinclude>[\s\S]*$/g, '');
    s = s.replace(/<noinclude\s*\/>/g, '');
    // includeonly：剥标签保内容（配对与未闭合均处理）
    s = s.replace(/<includeonly\s*\/>/g, '');
    s = s.replace(/<\/?includeonly>/g, '');
    return s;
  }
}
