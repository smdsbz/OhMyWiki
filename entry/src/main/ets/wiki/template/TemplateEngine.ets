import { Logger } from '../../common/Logger';
import { WikiIndex } from '../../data/WikiIndex';
import { BraceUtil } from '../parser/BraceUtil';

const TAG = 'TemplateEngine';

/** #invoke 分发接口（由站点适配器提供实现） */
export interface InvokeHandler {
  invoke(module: string, func: string, args: string[], ctx: TemplateContext): Promise<string>;
}

/** #ask/#show 语义查询分发接口（由 SmwQueryEngine 实现） */
export interface AskHandler {
  query(args: string[], ctx: TemplateContext, isShow: boolean): Promise<string>;
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
}

const MAX_DEPTH = 10;
/** 占位标记：\u0000OMPH:reason\u0000 */
export const PLACEHOLDER_MARK = '\u0000OMPH:';

/**
 * 模板展开引擎：把 wikitext 中的 {{...}}（模板、解析函数、魔术字、
 * SMW 语义标注）展开为普通文本，供解析器继续处理。
 */
export class TemplateEngine {
  private ctx: TemplateContext;

  constructor(ctx: TemplateContext) {
    this.ctx = ctx;
  }

  async expand(text: string): Promise<string> {
    return await this.expandInner(text, 0, []);
  }

  private async expandInner(text: string, depth: number, stack: string[]): Promise<string> {
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
        // 保护块（nowiki/pre 等）原样保留
        const tagEnd = BraceUtil.skipXmlBlock(text, i);
        if (tagEnd > i) {
          sb.push(text.substring(i, tagEnd));
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
        sb.push(await this.expandOne(inner, depth, stack));
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
        // 展开链接内的模板（如 [[{{FULLPAGENAME}}/子页|显示]]）
        const expandedInner = await this.expandInner(inner, depth + 1, stack);
        const dc = this.findTopLevelDoubleColon(expandedInner);
        if (dc >= 0) {
          // SMW [[属性::目标|标签]]：属性存储目标，显示用标签（无标签则显示目标）
          const prop = expandedInner.substring(0, dc).trim();
          const value = expandedInner.substring(dc + 2).trim();
          if (this.ctx.capture !== undefined && this.ctx.capture !== null) {
            const pipe = value.indexOf('|');
            this.ctx.capture(prop, pipe >= 0 ? value.substring(0, pipe).trim() : value);
          }
          const pipe2 = value.indexOf('|');
          sb.push(pipe2 >= 0 ? value.substring(pipe2 + 1).trim() : value);
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

  private async expandOne(inner: string, depth: number, stack: string[]): Promise<string> {
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
        name = (await this.expandInner(name, depth + 1, stack)).trim();
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
    // 展开名称中的嵌套模板（如 {{Special:PrefixIndex/{{FULLPAGENAME}}/ ...}}）
    if (name.indexOf('{{') >= 0) {
      name = (await this.expandInner(name, depth + 1, stack)).trim();
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
      return await this.parserFunction(name, rest, depth, stack);
    }
    // 主命名空间转页 {{:Page}}
    if (name.startsWith(':')) {
      return '';
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
    return await this.expandTemplate(name, rest, depth, stack);
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

  private async parserFunction(name: string, rest: string, depth: number, stack: string[]): Promise<string> {
    const args = BraceUtil.splitTopLevel(rest, '|');
    const fname = name.toLowerCase();
    if (fname === '#if') {
      const test = this.get(args, 0);
      return await this.expandInner(test.trim().length > 0 ? this.get(args, 1) : this.get(args, 2), depth + 1, stack);
    }
    if (fname === '#ifeq') {
      const a = this.get(args, 0).trim();
      const b = this.get(args, 1).trim();
      return await this.expandInner(a === b ? this.get(args, 2) : this.get(args, 3), depth + 1, stack);
    }
    if (fname === '#ifexist') {
      // 标题参数先展开嵌套魔术字/模板（如 {{#ifexist:文件:{{NAMESPACE}}-{{PAGENAME}}.jpg|...}}）
      const title = (await this.expandInner(this.get(args, 0), depth + 1, stack)).trim();
      const exists = this.ctx.index !== null && this.ctx.index.pageExists(title);
      return await this.expandInner(exists ? this.get(args, 1) : this.get(args, 2), depth + 1, stack);
    }
    if (fname === '#iferror') {
      return await this.expandInner(this.get(args, 2), depth + 1, stack);
    }
    if (fname === '#switch') {
      const value = this.get(args, 0).trim();
      let def = '';
      for (let i = 1; i < args.length; i++) {
        const seg = args[i];
        const eq = this.topLevelIndexOf(seg, '=');
        if (eq < 0) {
          continue;
        }
        const key = seg.substring(0, eq).trim();
        const val = seg.substring(eq + 1);
        if (key === '#default') {
          def = val;
        } else if (key === value) {
          return await this.expandInner(val, depth + 1, stack);
        }
      }
      return await this.expandInner(def, depth + 1, stack);
    }
    if (fname === '#expr') {
      // 先展开参数中的嵌套调用（如 {{#expr:{{#show:...}}*2}}），再求值
      const expr = await this.expandInner(this.get(args, 0), depth + 1, stack);
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
    if (fname === '#invoke') {
      const module = this.get(args, 0).trim();
      const func = this.get(args, 1).trim();
      const callArgs: string[] = [];
      for (let i = 2; i < args.length; i++) {
        callArgs.push(args[i]);
      }
      if (this.ctx.invokeHandler !== null) {
        return await this.ctx.invokeHandler.invoke(module, func, callArgs, this.ctx);
      }
      return this.placeholder('Lua 模块 ' + module + ' 未实现');
    }
    if (fname === '#ask' || fname === '#show') {
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
            const value = a.substring(eq + 1).trim();
            if (prop.length > 0) {
              this.ctx.capture(prop, value);
            }
          }
        }
      }
      return '';
    }
    if (fname === '#related' || fname === '#categorytree' || fname === '#dpl' || fname === '#language') {
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
      case 'NS': {
        const idx = parseInt(this.get(rest.split('|'), 0));
        if (!isNaN(idx) && idx === 0) {
          return '';
        }
        return '';
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

  private async expandTemplate(name: string, rest: string, depth: number, stack: string[]): Promise<string> {
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
        named.set(a.substring(0, eq).trim(), a.substring(eq + 1));
      } else {
        positional.push(a);
      }
    }
    const substituted = this.substituteParams(cleaned, named, positional);
    const newStack = stack.concat([name]);
    return await this.expandInner(substituted, depth + 1, newStack);
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

  /** 极简算术表达式求值（+ - * / % 与括号、一元负号） */
  private evalExpr(expr: string): string {
    const s = expr.replace(/\s/g, '');
    if (s.length === 0) {
      return '';
    }
    const pos: number[] = [0];
    const result = this.parseExprAdd(s, pos);
    if (pos[0] < s.length || isNaN(result)) {
      return '';
    }
    const rounded = Math.round(result * 1e9) / 1e9;
    if (Number.isInteger(rounded)) {
      return String(rounded);
    }
    return String(rounded);
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
    if (pos[0] < s.length && s.charAt(pos[0]) === '(') {
      pos[0]++;
      const v = this.parseExprAdd(s, pos);
      if (pos[0] < s.length && s.charAt(pos[0]) === ')') {
        pos[0]++;
      }
      return v;
    }
    // 数字
    let j = pos[0];
    while (j < s.length && (s.charAt(j) >= '0' && s.charAt(j) <= '9' || s.charAt(j) === '.')) {
      j++;
    }
    if (j === pos[0]) {
      pos[0] = s.length;
      return 0;
    }
    const num = parseFloat(s.substring(pos[0], j));
    pos[0] = j;
    return num;
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
