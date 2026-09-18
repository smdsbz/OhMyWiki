/**
 * 轻量宽容 HTML DOM 层：标签扫描 + 树构建 + 实体解码。
 * 无站点知识、无 IO、不依赖节点模型（DOM→WikiNode 转换在 HtmlParser）。
 * 移植自 scripts/monster-hunter-web-data/crawl.py DomBuilder（服务端渲染、基本良构的页面）。
 */

/** 无结束标签的 void 元素 */
const VOID_TAGS: Set<string> = new Set([
  'img', 'br', 'hr', 'input', 'meta', 'link', 'area', 'base', 'col',
  'embed', 'source', 'track', 'wbr',
]);

/** 隐式闭合：开标签 X 会闭合栈顶的这些未闭合标签（HTML 宽容嵌套规则） */
const IMPLIES_END: Map<string, Set<string>> = new Map<string, Set<string>>([
  ['li', new Set<string>(['li'])],
  ['p', new Set<string>(['p'])],
  ['td', new Set<string>(['td', 'th'])],
  ['th', new Set<string>(['td', 'th'])],
  ['tr', new Set<string>(['tr', 'td', 'th'])],
  ['option', new Set<string>(['option'])],
]);

/** 命名实体表（数字实体 &#N;/&#xH; 单独处理） */
const NAMED_ENTITIES: Record<string, string> = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': '\u00A0',
  'ensp': '\u2002',
  'emsp': '\u2003',
  'copy': '\u00A9',
  'reg': '\u00AE',
  'trade': '\u2122',
  'deg': '\u00B0',
  'plusmn': '\u00B1',
  'times': '\u00D7',
  'divide': '\u00F7',
  'middot': '\u00B7',
  'hellip': '\u2026',
  'mdash': '\u2014',
  'ndash': '\u2013',
  'laquo': '\u00AB',
  'raquo': '\u00BB',
  'larr': '\u2190',
  'rarr': '\u2192',
  'uarr': '\u2191',
  'darr': '\u2193',
  'harr': '\u2194',
};

/** 解码 HTML 实体（命名 + 数字十/十六进制；无分号的宽容跳过） */
export function decodeEntities(s: string): string {
  if (s.indexOf('&') < 0) {
    return s;
  }
  let out = '';
  let i = 0;
  const n = s.length;
  while (i < n) {
    const c = s.charAt(i);
    if (c !== '&') {
      out += c;
      i++;
      continue;
    }
    const semi = s.indexOf(';', i + 1);
    // 分号距 & 超过 10 字符视为普通文本（实体名最长 <10）
    if (semi < 0 || semi - i > 10) {
      out += c;
      i++;
      continue;
    }
    const body = s.substring(i + 1, semi);
    let decoded: string | null = null;
    if (body.length > 1 && body.charAt(0) === '#') {
      const num = body.charAt(1) === 'x' || body.charAt(1) === 'X'
        ? parseInt(body.substring(2), 16)
        : parseInt(body.substring(1), 10);
      if (!isNaN(num) && num > 0 && num < 0x110000) {
        decoded = String.fromCharCode(num);
      }
    } else {
      const named = NAMED_ENTITIES[body];
      if (named !== undefined) {
        decoded = named;
      }
    }
    if (decoded === null) {
      out += c;
      i++;
    } else {
      out += decoded;
      i = semi + 1;
    }
  }
  return out;
}

export class DomNode {
  /** 标签名（小写）；'#text' 表示文本节点 */
  tag: string;
  /** 文本内容（仅 #text 节点有效，已解码实体） */
  text: string;
  attrs: Map<string, string>;
  children: DomNode[];

  constructor(tag: string) {
    this.tag = tag;
    this.text = '';
    this.attrs = new Map<string, string>();
    this.children = [];
  }

  /** class 列表 */
  cls(): string[] {
    const v = this.attrs.get('class');
    if (v === undefined) {
      return [];
    }
    return v.split(/\s+/).filter((c: string) => c.length > 0);
  }

  attr(name: string): string | null {
    const v = this.attrs.get(name);
    return v === undefined ? null : v;
  }

  isText(): boolean {
    return this.tag === '#text';
  }
}

/** 深度优先查找第一个命中的元素 */
export function findFirst(el: DomNode, pred: (el: DomNode) => boolean): DomNode | null {
  if (pred(el)) {
    return el;
  }
  for (const c of el.children) {
    const r = findFirst(c, pred);
    if (r !== null) {
      return r;
    }
  }
  return null;
}

/** 拼接子树全部文本（空白折叠为单空格） */
export function textOf(el: DomNode): string {
  if (el.isText()) {
    return el.text;
  }
  let out = '';
  for (const c of el.children) {
    out += textOf(c);
  }
  return out.replace(/\s+/g, ' ');
}

interface ParsedTag {
  name: string;
  attrs: Map<string, string>;
  selfClosing: boolean;
}

function isWs(c: string): boolean {
  return c === ' ' || c === '\n' || c === '\r' || c === '\t' || c === '\f';
}

function isNameChar(c: string): boolean {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
    || c === '_' || c === '-' || c === ':' || c === '.';
}

export class HtmlDomBuilder {
  private root: DomNode;
  private stack: DomNode[];
  private text: string;

  constructor() {
    this.root = new DomNode('#document');
    this.stack = [this.root];
    this.text = '';
  }

  /** 解析 HTML 文本，返回 #document 根 */
  build(text: string): DomNode {
    this.text = text;
    const n = text.length;
    let i = 0;
    while (i < n) {
      const lt = text.indexOf('<', i);
      if (lt < 0) {
        this.appendText(text.substring(i));
        break;
      }
      if (lt > i) {
        this.appendText(text.substring(i, lt));
      }
      const next = text.charAt(lt + 1);
      if (next === '!') {
        // 注释 <!-- --> 或 <!DOCTYPE ...>
        if (text.startsWith('<!--', lt)) {
          const end = text.indexOf('-->', lt + 4);
          i = end < 0 ? n : end + 3;
        } else {
          const end = text.indexOf('>', lt);
          i = end < 0 ? n : end + 1;
        }
        continue;
      }
      if (next === '/') {
        const gt = text.indexOf('>', lt);
        if (gt < 0) {
          break;
        }
        const name = text.substring(lt + 2, gt).trim().toLowerCase();
        this.handleEndTag(name);
        i = gt + 1;
        continue;
      }
      const gt = this.findTagEnd(lt);
      if (gt < 0) {
        break;
      }
      const parsed = this.parseTag(text.substring(lt + 1, gt));
      if (parsed.name.length > 0) {
        this.handleStartTag(parsed.name, parsed.attrs, parsed.selfClosing);
      }
      i = gt + 1;
    }
    return this.root;
  }

  /** 找标签收尾 '>'（跳过引号内的 '>'） */
  private findTagEnd(from: number): number {
    const n = this.text.length;
    let quote = '';
    for (let i = from + 1; i < n; i++) {
      const c = this.text.charAt(i);
      if (quote.length > 0) {
        if (c === quote) {
          quote = '';
        }
        continue;
      }
      if (c === '"' || c === '\'') {
        quote = c;
        continue;
      }
      if (c === '>') {
        return i;
      }
    }
    return -1;
  }

  /** 解析标签体：name + 属性对（值解码实体） */
  private parseTag(body: string): ParsedTag {
    let selfClosing = false;
    let b = body;
    if (b.endsWith('/')) {
      selfClosing = true;
      b = b.substring(0, b.length - 1);
    }
    const nameMatch = b.match(/^[A-Za-z][\w:-]*/);
    const name = nameMatch !== null ? nameMatch[0].toLowerCase() : '';
    const attrs = new Map<string, string>();
    let i = name.length;
    const n = b.length;
    while (i < n) {
      // 跳过空白
      while (i < n && isWs(b.charAt(i))) {
        i++;
      }
      if (i >= n) {
        break;
      }
      // 属性名
      let j = i;
      while (j < n && !isWs(b.charAt(j)) && b.charAt(j) !== '=') {
        j++;
      }
      const attrName = b.substring(i, j).toLowerCase();
      i = j;
      // 跳过空白
      while (i < n && isWs(b.charAt(i))) {
        i++;
      }
      if (attrName.length === 0 || i >= n || b.charAt(i) !== '=') {
        if (attrName.length > 0) {
          attrs.set(attrName, '');
        }
        continue;
      }
      i++; // 跳过 '='
      while (i < n && isWs(b.charAt(i))) {
        i++;
      }
      if (i >= n) {
        break;
      }
      const q = b.charAt(i);
      let value: string;
      if (q === '"' || q === '\'') {
        const end = b.indexOf(q, i + 1);
        value = end < 0 ? b.substring(i + 1) : b.substring(i + 1, end);
        i = end < 0 ? n : end + 1;
      } else {
        let j2 = i;
        while (j2 < n && !isWs(b.charAt(j2))) {
          j2++;
        }
        value = b.substring(i, j2);
        i = j2;
      }
      if (attrName.length > 0) {
        attrs.set(attrName, decodeEntities(value));
      }
    }
    return { name: name, attrs: attrs, selfClosing: selfClosing };
  }

  private handleStartTag(name: string, attrs: Map<string, string>, selfClosing: boolean): void {
    const closes = IMPLIES_END.get(name);
    if (closes !== undefined) {
      while (this.stack.length > 1 && closes.has(this.stack[this.stack.length - 1].tag)) {
        this.stack.pop();
      }
    }
    const el = new DomNode(name);
    el.attrs = attrs;
    this.stack[this.stack.length - 1].children.push(el);
    if (!VOID_TAGS.has(name) && !selfClosing) {
      this.stack.push(el);
    }
  }

  private handleEndTag(name: string): void {
    if (VOID_TAGS.has(name)) {
      return;
    }
    for (let i = this.stack.length - 1; i > 0; i--) {
      if (this.stack[i].tag === name) {
        this.stack.length = i;
        return;
      }
    }
    // 未匹配的结束标签：忽略
  }

  private appendText(raw: string): void {
    if (raw.length === 0) {
      return;
    }
    const el = new DomNode('#text');
    el.text = decodeEntities(raw);
    this.stack[this.stack.length - 1].children.push(el);
  }
}
