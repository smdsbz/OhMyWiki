import { Logger } from '../../common/Logger';
import { WikiIndex } from '../../data/WikiIndex';
import { NodeType, WikiNode, GaugeSeg } from '../../model/WikiTypes';
import { HtmlPageConfig, HtmlInlineStyle } from '../siteadapter/HtmlPageConfig';
import { DomNode, HtmlDomBuilder, findFirst, textOf } from './htmldom/HtmlDom';

const TAG = 'HtmlParser';

interface InlineStyle {
  color: string | null;
  bgColor: string | null;
  bold: boolean;
  fontSize: number | null;
}

const BLOCK_CHILD_TAGS: Set<string> = new Set<string>([
  'table', 'ul', 'ol', 'h2', 'h3', 'h4', 'h5', 'h6', 'div', 'p', 'hr',
  'blockquote', 'section', 'article', 'center', 'pre',
]);

const COLOR_RE = /(background-)?color:\s*(#[0-9a-fA-F]{3,8})/;

/**
 * HTML → WikiNode 节点树解析器（HTML 直渲染路径）。
 * 页面为站点原始 HTML（pack.py 清洗打包），本类只认 HtmlPageConfig 声明的
 * 站点规则（类名/颜色/跳过/白名单），不内置任何站点知识；
 * 产出的节点树交给通用 WikiContentView 渲染。
 */
export class HtmlParser {
  private index: WikiIndex | null;
  private currentTitle: string;
  private config: HtmlPageConfig;
  /** 本页站内路径（如 data/1829.html），相对链接解析的 base */
  private basePath: string;

  private skipTagSet: Set<string>;
  private skipIdSet: Set<string>;
  private skipClassSet: Set<string>;
  private hiddenClassSet: Set<string>;
  private skipHeadingTagSet: Set<string>;
  private headingLevelByTag: Map<string, number>;
  private headingLevelByClass: Map<string, number>;
  private inlineStyleByClass: Map<string, HtmlInlineStyle>;
  private gaugeBarColorByClass: Map<string, string>;

  constructor(index: WikiIndex | null, currentTitle: string, config: HtmlPageConfig) {
    this.index = index;
    this.currentTitle = currentTitle;
    this.config = config;
    const p = index !== null ? index.findPath(currentTitle) : null;
    this.basePath = p !== null ? p.replace(/^pages\//, '') : 'index.html';

    this.skipTagSet = new Set<string>(config.skipTags);
    this.skipIdSet = new Set<string>(config.skipIds);
    this.skipClassSet = new Set<string>(config.skipClasses);
    this.hiddenClassSet = new Set<string>(config.hiddenClasses);
    this.skipHeadingTagSet = new Set<string>(config.skipHeadingTags);
    this.headingLevelByTag = new Map<string, number>();
    const levels = config.headingTagLevels;
    for (const k of Object.keys(levels)) {
      this.headingLevelByTag.set(k, levels[k]);
    }
    this.headingLevelByClass = new Map<string, number>();
    for (const r of config.headingClassRules) {
      this.headingLevelByClass.set(r.cls, r.level);
    }
    this.inlineStyleByClass = new Map<string, HtmlInlineStyle>();
    for (const s of config.inlineClassStyles) {
      this.inlineStyleByClass.set(s.cls, s);
    }
    this.gaugeBarColorByClass = new Map<string, string>();
    const bars = config.gaugeBarColors;
    for (const k of Object.keys(bars)) {
      this.gaugeBarColorByClass.set(k, bars[k]);
    }
  }

  parse(html: string): WikiNode[] {
    const t0 = Date.now();
    const root = new HtmlDomBuilder().build(html);
    const main = findFirst(root, (el: DomNode) => !el.isText() && el.attr('id') === this.config.rootId);
    const body = main !== null
      ? main
      : findFirst(root, (el: DomNode) => el.tag === 'body');
    const start = body !== null ? body : root;
    const nodes = this.convertBlocks(start.children);
    Logger.info(TAG, 'HTML parsed [' + this.currentTitle + '] blocks=' + nodes.length
      + ' in ' + (Date.now() - t0) + 'ms');
    return nodes;
  }

  // ---------------------------------------------------------- 元素过滤 --

  private skipped(el: DomNode): boolean {
    if (el.isText()) {
      return false;
    }
    if (this.skipTagSet.has(el.tag)) {
      return true;
    }
    const id = el.attr('id');
    if (id !== null && this.skipIdSet.has(id)) {
      return true;
    }
    for (const c of el.cls()) {
      if (this.skipClassSet.has(c) || this.hiddenClassSet.has(c)) {
        return true;
      }
    }
    return false;
  }

  /** >0 = 标题级别；0 = 非标题；-1 = 跳过（页面级重复标题） */
  private headingLevelOf(el: DomNode): number {
    if (this.skipHeadingTagSet.has(el.tag)) {
      return -1;
    }
    const byTag = this.headingLevelByTag.get(el.tag);
    if (byTag !== undefined) {
      return byTag;
    }
    for (const c of el.cls()) {
      const byCls = this.headingLevelByClass.get(c);
      if (byCls !== undefined) {
        return byCls;
      }
    }
    return 0;
  }

  // ---------------------------------------------------------- 块级转换 --

  private convertBlocks(nodes: DomNode[]): WikiNode[] {
    const out: WikiNode[] = [];
    for (const n of nodes) {
      if (n.isText()) {
        const t = n.text.replace(/\s+/g, ' ').trim();
        if (t.length > 0) {
          out.push(this.mkParagraph([this.mkText(t)]));
        }
        continue;
      }
      if (this.skipped(n)) {
        continue;
      }
      out.push(...this.convertBlockEl(n));
    }
    return out;
  }

  private convertBlockEl(el: DomNode): WikiNode[] {
    const hl = this.headingLevelOf(el);
    if (hl < 0) {
      return [];
    }
    if (hl > 0) {
      const inline = this.trimEdges(this.convertInline(el.children));
      return inline.length > 0 ? [{ type: NodeType.Heading, level: hl, inline: inline }] : [];
    }
    const tag = el.tag;
    if (tag === 'br') {
      return [];
    }
    if (tag === 'hr') {
      return [{ type: NodeType.Hr }];
    }
    if (tag === 'img') {
      const img = this.mkImage(el);
      return img !== null ? [this.mkParagraph([img])] : [];
    }
    if (tag === 'table') {
      const t = this.parseTable(el);
      return t !== null ? [t] : [];
    }
    if (tag === 'ul' || tag === 'ol') {
      const list = this.parseList(el, tag === 'ol');
      return list !== null ? [list] : [];
    }
    if (tag === 'a') {
      const inline = this.mkLinkInline(el);
      return inline.length > 0 ? [this.mkParagraph(this.trimEdges(inline))] : [];
    }
    // 量表容器（強さ progress / 斩位 kireage）
    const gauges = this.mkGauges(el);
    if (gauges !== null) {
      return gauges.map((g: WikiNode): WikiNode => this.mkParagraph([g]));
    }
    if (tag === 'pre') {
      const text = this.inlineText(el.children);
      return text.length > 0 ? [{ type: NodeType.Pre, text: text }] : [];
    }
    // 透明容器（div/p/center/span 出现在块位置等）
    const centered = this.isCentered(el);
    if (this.hasBlockChild(el)) {
      const blocks = this.convertBlocks(el.children);
      if (centered) {
        return blocks.length > 0 ? [{ type: NodeType.Container, align: 'center', children: blocks }] : [];
      }
      return blocks;
    }
    const inline = this.trimEdges(this.convertInline(el.children));
    if (inline.length === 0) {
      return [];
    }
    if (centered) {
      return [{ type: NodeType.Container, align: 'center', children: [this.mkParagraph(inline)] }];
    }
    return [this.mkParagraph(inline)];
  }

  private hasBlockChild(el: DomNode): boolean {
    for (const c of el.children) {
      if (!c.isText() && BLOCK_CHILD_TAGS.has(c.tag)) {
        return true;
      }
    }
    return false;
  }

  private isCentered(el: DomNode): boolean {
    if (el.tag === 'center') {
      return true;
    }
    const style = el.attr('style') ?? '';
    return /text-align:\s*center/.test(style) || /align:\s*center/.test(style);
  }

  private mkParagraph(inline: WikiNode[]): WikiNode {
    return { type: NodeType.Paragraph, inline: inline };
  }

  private mkText(t: string): WikiNode {
    return { type: NodeType.Text, text: t };
  }

  // ---------------------------------------------------------- 列表 --

  private parseList(el: DomNode, ordered: boolean): WikiNode | null {
    const items: WikiNode[] = [];
    for (const li of el.children) {
      if (li.isText() || this.skipped(li)) {
        continue;
      }
      if (li.tag !== 'li') {
        // 非 li 直接子元素（罕见）：按块展开并归入上一项
        if (items.length > 0) {
          const last = items[items.length - 1];
          const blocks = this.convertBlockEl(li);
          if (blocks.length > 0) {
            (last.children ??= []).push(...blocks);
          }
        }
        continue;
      }
      const inline: WikiNode[] = [];
      const nested: WikiNode[] = [];
      for (const c of li.children) {
        if (c.isText()) {
          const t = c.text.replace(/\s+/g, ' ');
          if (t.trim().length > 0) {
            inline.push(this.mkText(t));
          }
          continue;
        }
        if (c.tag === 'ul' || c.tag === 'ol') {
          const sub = this.parseList(c, c.tag === 'ol');
          if (sub !== null) {
            nested.push(sub);
          }
          continue;
        }
        inline.push(...this.convertInlineEl(c));
      }
      const trimmed = this.trimEdges(inline);
      if (trimmed.length > 0 || nested.length > 0) {
        const item: WikiNode = { type: NodeType.ListItem, inline: trimmed };
        if (nested.length > 0) {
          item.children = nested;
        }
        items.push(item);
      }
    }
    if (items.length === 0) {
      return null;
    }
    return { type: ordered ? NodeType.OrderedList : NodeType.UnorderedList, children: items };
  }

  // ---------------------------------------------------------- 表格 --

  private collectRows(el: DomNode, out: DomNode[]): void {
    for (const c of el.children) {
      if (c.isText() || this.skipped(c)) {
        continue;
      }
      if (c.tag === 'tr') {
        out.push(c);
      } else if (c.tag === 'thead' || c.tag === 'tbody' || c.tag === 'tfoot') {
        this.collectRows(c, out);
      }
    }
  }

  private parseTable(el: DomNode): WikiNode | null {
    const domRows: DomNode[] = [];
    this.collectRows(el, domRows);
    const rows: WikiNode[] = [];
    let caption: WikiNode[] | null = null;
    for (const c of el.children) {
      if (!c.isText() && c.tag === 'caption') {
        caption = this.trimEdges(this.convertInline(c.children));
      }
    }
    // rowspan 占位跟踪：行号 -> 被占列集合（复刻 WikitextParser.placeCell；colspan 占满跨度）
    const rowspanOcc: Map<number, Set<number>> = new Map();
    let rowIndex = 0;
    let usedCols: Set<number> = new Set();
    const placeCell = (cell: WikiNode): void => {
      const occ = rowspanOcc.get(rowIndex);
      let col = 0;
      while (usedCols.has(col) || (occ !== undefined && occ.has(col))) {
        col++;
      }
      cell.colIndex = col;
      const cs = cell.colSpan !== undefined ? cell.colSpan : 1;
      const rs = cell.rowSpan !== undefined ? cell.rowSpan : 1;
      for (let k = 0; k < cs; k++) {
        usedCols.add(col + k);
      }
      if (rs > 1) {
        for (let r = rowIndex + 1; r < rowIndex + rs; r++) {
          for (let k = 0; k < cs; k++) {
            const cur = rowspanOcc.get(r);
            if (cur === undefined) {
              const ns = new Set<number>();
              ns.add(col + k);
              rowspanOcc.set(r, ns);
            } else {
              cur.add(col + k);
            }
          }
        }
      }
    };
    for (const dr of domRows) {
      const cells: WikiNode[] = [];
      for (const c of dr.children) {
        if (c.isText() || this.skipped(c)) {
          continue;
        }
        if (c.tag !== 'td' && c.tag !== 'th') {
          continue;
        }
        const cell = this.mkCell(c);
        placeCell(cell);
        cells.push(cell);
      }
      if (cells.length > 0) {
        rows.push({ type: NodeType.TableRow, children: cells });
      }
      rowIndex++;
      usedCols = new Set();
    }
    if (rows.length === 0) {
      return null;
    }
    const node: WikiNode = { type: NodeType.Table, children: rows };
    if (caption !== null && caption.length > 0) {
      node.caption = caption;
    }
    return node;
  }

  private mkCell(el: DomNode): WikiNode {
    const isHead = el.tag === 'th';
    const cell: WikiNode = {
      type: isHead ? NodeType.TableHeaderCell : NodeType.TableCell,
      inline: [],
    };
    const colspan = this.intAttr(el, 'colspan');
    if (colspan !== null && colspan > 1) {
      cell.colSpan = colspan;
    }
    const rowspan = this.intAttr(el, 'rowspan');
    if (rowspan !== null && rowspan > 1) {
      cell.rowSpan = rowspan;
    }
    const style = el.attr('style') ?? '';
    const widthAttr = el.attr('width') ?? '';
    let pct = this.pctOf(widthAttr);
    if (pct === null) {
      const m = style.match(/width:\s*([\d.]+)%/);
      if (m !== null) {
        pct = parseFloat(m[1]);
      }
    }
    if (pct !== null && pct > 0) {
      cell.widthPct = pct;
    }
    const bg = el.attr('bgcolor');
    if (bg !== null && /^#[0-9a-fA-F]{3,8}$/.test(bg)) {
      cell.bgColor = bg;
    } else {
      const m = style.match(/background-color:\s*(#[0-9a-fA-F]{3,8})/);
      if (m !== null) {
        cell.bgColor = m[1];
      }
    }
    let align = el.attr('align');
    if (align === null) {
      const m = style.match(/text-align:\s*(center|left|right)/);
      align = m !== null ? m[1] : null;
    }
    if (align === 'center' || align === 'left' || align === 'right') {
      cell.align = align;
    }
    (cell.inline as WikiNode[]) = this.trimEdges(this.convertInline(el.children));
    return cell;
  }

  private intAttr(el: DomNode, name: string): number | null {
    const v = el.attr(name);
    if (v === null) {
      return null;
    }
    const n = parseInt(v, 10);
    return isNaN(n) ? null : n;
  }

  private pctOf(v: string): number | null {
    const m = v.trim().match(/^([\d.]+)%$/);
    return m !== null ? parseFloat(m[1]) : null;
  }

  // ---------------------------------------------------------- 行内转换 --

  private convertInline(nodes: DomNode[]): WikiNode[] {
    const out: WikiNode[] = [];
    for (const n of nodes) {
      if (n.isText()) {
        const t = n.text.replace(/\s+/g, ' ');
        if (t.length > 0) {
          out.push(this.mkText(t));
        }
        continue;
      }
      out.push(...this.convertInlineEl(n));
    }
    return out;
  }

  private convertInlineEl(el: DomNode): WikiNode[] {
    if (this.skipped(el)) {
      return [];
    }
    const tag = el.tag;
    if (tag === 'br') {
      return [{ type: NodeType.LineBreak }];
    }
    if (tag === 'img') {
      const img = this.mkImage(el);
      return img !== null ? [img] : [];
    }
    if (tag === 'a') {
      return this.mkLinkInline(el);
    }
    if (tag === 'b' || tag === 'strong') {
      const inner = this.convertInline(el.children);
      return inner.length > 0 ? [{ type: NodeType.Bold, inline: inner }] : [];
    }
    if (tag === 'i' || tag === 'em') {
      const inner = this.convertInline(el.children);
      return inner.length > 0 ? [{ type: NodeType.Italic, inline: inner }] : [];
    }
    if (tag === 'table' || tag === 'ul' || tag === 'ol') {
      // 行内上下文中的嵌套块：压平为文本（行 join <br>，格 join ' / '）
      return this.flattenBlockish(el);
    }
    if (tag === 'h2' || tag === 'h3' || tag === 'h4' || tag === 'h5' || tag === 'h6') {
      const t = textOf(el).trim();
      return t.length > 0 ? [{ type: NodeType.Bold, inline: [this.mkText(t)] }] : [];
    }
    // 量表（強さ progress 条 / 斩位 kireage 多色段）
    const gauges = this.mkGauges(el);
    if (gauges !== null) {
      return gauges;
    }
    // 透明行内元素（span/font/small/big/sup/sub/u/s/div…）：叠加样式后下钻
    const style = this.styleOf(el);
    let inner = this.convertInline(el.children);
    if (inner.length === 0) {
      return [];
    }
    if (style.bold) {
      inner = [{ type: NodeType.Bold, inline: inner }];
    }
    if (style.color !== null || style.fontSize !== null || style.bgColor !== null) {
      const colorNode: WikiNode = { type: NodeType.Color, inline: inner };
      if (style.color !== null) {
        colorNode.color = style.color;
      }
      if (style.fontSize !== null) {
        colorNode.fontSize = style.fontSize;
      }
      if (style.bgColor !== null) {
        colorNode.bgColor = style.bgColor;
      }
      inner = [colorNode];
    }
    return inner;
  }

  /** class 命中 + style 属性 → 行内样式叠加 */
  private styleOf(el: DomNode): InlineStyle {
    const style: InlineStyle = { color: null, bgColor: null, bold: false, fontSize: null };
    for (const c of el.cls()) {
      const s = this.inlineStyleByClass.get(c);
      if (s !== undefined) {
        if (s.color !== undefined && style.color === null) {
          style.color = s.color;
        }
        if (s.bold === true) {
          style.bold = true;
        }
        if (s.fontSize !== undefined && style.fontSize === null) {
          style.fontSize = s.fontSize;
        }
      }
    }
    const styleAttr = el.attr('style') ?? '';
    const m = styleAttr.match(COLOR_RE);
    if (m !== null) {
      if (m[1] !== undefined) {
        style.bgColor = m[2];
      } else {
        style.color = m[2];
      }
    }
    if (el.tag === 'small' && style.fontSize === null) {
      style.fontSize = 12;
    }
    if (el.tag === 'big' && style.fontSize === null) {
      style.fontSize = 17;
    }
    return style;
  }

  /** 去掉行内序列首尾的纯空白文本 */
  private trimEdges(nodes: WikiNode[]): WikiNode[] {
    let start = 0;
    let end = nodes.length;
    while (start < end) {
      const n = nodes[start];
      if (n.type === NodeType.Text && (n.text ?? '').trim().length === 0) {
        start++;
      } else {
        break;
      }
    }
    while (end > start) {
      const n = nodes[end - 1];
      if (n.type === NodeType.Text && (n.text ?? '').trim().length === 0) {
        end--;
      } else {
        break;
      }
    }
    return nodes.slice(start, end);
  }

  private inlineText(nodes: DomNode[]): string {
    const wrapper = new DomNode('div');
    wrapper.children = nodes;
    return textOf(wrapper);
  }

  private flattenBlockish(el: DomNode): WikiNode[] {
    const out: WikiNode[] = [];
    const rows: string[] = [];
    if (el.tag === 'table') {
      const trs: DomNode[] = [];
      this.collectRows(el, trs);
      for (const tr of trs) {
        const cells: string[] = [];
        for (const c of tr.children) {
          if (!c.isText() && (c.tag === 'td' || c.tag === 'th')) {
            const t = textOf(c).trim();
            if (t.length > 0) {
              cells.push(t);
            }
          }
        }
        if (cells.length > 0) {
          rows.push(cells.join(' / '));
        }
      }
    } else {
      for (const c of el.children) {
        if (!c.isText() && c.tag === 'li') {
          const t = textOf(c).trim();
          if (t.length > 0) {
            rows.push(t);
          }
        }
      }
    }
    for (let i = 0; i < rows.length; i++) {
      if (i > 0) {
        out.push({ type: NodeType.LineBreak });
      }
      out.push(this.mkText(rows[i]));
    }
    return out;
  }

  // ---------------------------------------------------------- 链接与图片 --

  /** href 相对 base 解析为站内路径；外链/锚点/非法返回 null（fragment 存于 out[1]） */
  private resolveRelative(href: string): [string, string] | null {
    let h = href;
    let anchor = '';
    const hash = h.indexOf('#');
    if (hash >= 0) {
      anchor = h.substring(hash + 1);
      h = h.substring(0, hash);
    }
    if (h.length === 0) {
      return null;
    }
    if (/^(https?:|mailto:|data:|javascript:)/i.test(h)) {
      return null;
    }
    const stack = this.basePath.split('/');
    stack.pop();
    for (const part of h.split('/')) {
      if (part === '.' || part.length === 0) {
        continue;
      }
      if (part === '..') {
        if (stack.length > 0) {
          stack.pop();
        }
        continue;
      }
      stack.push(part);
    }
    return [stack.join('/'), anchor];
  }

  private mkLinkInline(el: DomNode): WikiNode[] {
    const href = el.attr('href') ?? '';
    if (href.length === 0 || href === '#' || href.toLowerCase().startsWith('javascript:')) {
      // 死链/JS 控件：保留文字不保留链接
      return this.convertInline(el.children);
    }
    const resolved = this.resolveRelative(href);
    if (resolved === null) {
      // 外链：渲染为文字（引擎 ExternalLink 尚无跳转能力）
      const t = textOf(el).trim();
      return t.length > 0 ? [this.mkText(t)] : [];
    }
    const path = resolved[0];
    if (!this.config.internalPathPattern.test(path)) {
      return this.convertInline(el.children);
    }
    const target = this.index !== null ? this.index.resolvePathLink(path) : null;
    if (target === null) {
      return this.convertInline(el.children);
    }
    const link: WikiNode = {
      type: NodeType.Link,
      target: target,
      inline: this.convertInline(el.children),
    };
    return [link];
  }

  private mkImage(el: DomNode): WikiNode | null {
    const src = el.attr('src') ?? '';
    const resolved = this.resolveRelative(src);
    if (resolved === null) {
      const alt = el.attr('alt') ?? '';
      return alt.length > 0 ? this.mkText(alt) : null;
    }
    const path = resolved[0];
    const prefix = this.config.assetPrefix;
    if (!path.startsWith(prefix)) {
      return null;
    }
    const img: WikiNode = { type: NodeType.FileImage, fileName: path.substring(prefix.length) };
    const w = this.intAttr(el, 'width');
    if (w !== null && w > 0 && w <= 2000) {
      img.fileWidth = w;
    }
    return img;
  }

  // ---------------------------------------------------------- 量表 --

  /** div.progress（強さ双色条）与 kireage（斩位多色段）；非量表容器返回 null */
  private mkGauges(el: DomNode): WikiNode[] | null {
    const cls = el.cls();
    for (const c of cls) {
      if (c === this.config.gaugeContainerClass) {
        return this.mkProgressGauge(el);
      }
      if (c === this.config.sharpnessClass) {
        return this.mkSharpnessGauges(el);
      }
    }
    return null;
  }

  private mkProgressGauge(el: DomNode): WikiNode[] {
    const bar = findFirst(el, (c: DomNode): boolean => {
      if (c.isText()) {
        return false;
      }
      for (const k of c.cls()) {
        if (k === this.config.gaugeBarClass) {
          return true;
        }
      }
      return false;
    });
    if (bar === null) {
      return [];
    }
    let color = this.config.gaugeDefaultColor;
    for (const k of bar.cls()) {
      const hit = this.gaugeBarColorByClass.get(k);
      if (hit !== undefined) {
        color = hit;
        break;
      }
    }
    const m = (bar.attr('style') ?? '').match(/width:\s*([\d.]+)%/);
    const pct = m !== null ? parseFloat(m[1]) : 0;
    const out: WikiNode[] = [{
      type: NodeType.Gauge,
      gaugeSegs: [{ pct: pct, color: color } as GaugeSeg],
      gaugeHeight: 4,
    }];
    const barText = textOf(bar).trim();
    if (barText.length > 0) {
      out.push(this.mkText(' ' + barText));
    }
    return out;
  }

  private mkSharpnessGauges(el: DomNode): WikiNode[] {
    // 行分组：span(krN) 为色段（文本点数=长度），含 \n 的文本节点分行（与旧转换器一致）
    const rows: GaugeSeg[][] = [[]];
    for (const c of el.children) {
      if (c.isText()) {
        if (c.text.indexOf('\n') >= 0 && rows[rows.length - 1].length > 0) {
          rows.push([]);
        }
        continue;
      }
      let color: string | null = null;
      for (const k of c.cls()) {
        const s = this.inlineStyleByClass.get(k);
        if (s !== undefined && s.color !== undefined) {
          color = s.color;
          break;
        }
      }
      if (color === null) {
        continue;
      }
      const count = textOf(c).length;
      if (count > 0) {
        rows[rows.length - 1].push({ pct: count, color: color } as GaugeSeg);
      }
    }
    let maxTotal = 0;
    for (const r of rows) {
      let total = 0;
      for (const s of r) {
        total += s.pct;
      }
      if (total > maxTotal) {
        maxTotal = total;
      }
    }
    if (maxTotal === 0) {
      return [];
    }
    const out: WikiNode[] = [];
    for (const r of rows) {
      if (r.length === 0) {
        continue;
      }
      if (out.length > 0) {
        out.push({ type: NodeType.LineBreak });
      }
      const segs: GaugeSeg[] = [];
      for (const s of r) {
        segs.push({ pct: Math.round(s.pct / maxTotal * 100), color: s.color } as GaugeSeg);
      }
      out.push({ type: NodeType.Gauge, gaugeSegs: segs, gaugeHeight: 8 });
    }
    return out;
  }
}
