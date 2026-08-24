import { Logger } from '../../common/Logger';
import { WikiIndex } from '../../data/WikiIndex';
import { NodeType, WikiNode } from '../../model/WikiTypes';
import { BraceUtil } from './BraceUtil';
import { PLACEHOLDER_MARK } from '../template/TemplateEngine';

const TAG = 'WikitextParser';

interface ListFrame {
  type: NodeType;
  children: WikiNode[];
}

interface ParsedTable {
  node: WikiNode;
  nextIndex: number;
}

interface ParsedBlock {
  node: WikiNode | null;
  nextIndex: number;
}

/**
 * wikitext → 节点树解析器。
 * 输入应为「模板已展开」的文本（含 [[链接]]、[[文件:…]]、表格、列表等）。
 */
export class WikitextParser {
  private index: WikiIndex | null;
  private currentTitle: string;

  constructor(index: WikiIndex | null, currentTitle: string) {
    this.index = index;
    this.currentTitle = currentTitle;
  }

  parse(text: string): WikiNode[] {
    // 去掉行为开关
    const cleaned = text.replace(/__[A-Z_]+__/g, '');
    const lines = cleaned.split('\n');
    return this.parseBlocks(lines, 0, lines.length);
  }

  private isBlank(line: string): boolean {
    return line.trim().length === 0;
  }

  private isListLine(line: string): boolean {
    const t = line.replace(/^\s*/, '');
    return t.length > 0 && (t.charAt(0) === '*' || t.charAt(0) === '#' || t.charAt(0) === ';' || t.charAt(0) === ':');
  }

  /** 解析块级结构 */
  private parseBlocks(lines: string[], start: number, end: number): WikiNode[] {
    const out: WikiNode[] = [];
    let pending: string[] = [];
    let i = start;

    const flush = (): void => {
      if (pending.length > 0) {
        const para: WikiNode = {
          type: NodeType.Paragraph,
          inline: this.parseInline(pending.join(' ')),
        };
        out.push(para);
        pending = [];
      }
    };

    while (i < end) {
      const raw = lines[i];
      if (this.isBlank(raw)) {
        flush();
        i++;
        continue;
      }
      const trimmed = raw.replace(/^\s+/, '');
      // 表格
      if (trimmed.startsWith('{|')) {
        flush();
        const tbl = this.parseTable(lines, i);
        if (tbl.node !== null) {
          out.push(tbl.node);
        }
        i = tbl.nextIndex;
        continue;
      }
      // 标题
      const h = this.matchHeading(raw);
      if (h !== null) {
        flush();
        out.push(h.node as WikiNode);
        i++;
        continue;
      }
      // 分隔线
      if (this.isHr(raw)) {
        flush();
        const hr: WikiNode = { type: NodeType.Hr };
        out.push(hr);
        i++;
        continue;
      }
      // 列表
      if (this.isListLine(raw)) {
        flush();
        const li = this.parseList(lines, i, end);
        if (li.node !== null) {
          out.push(li.node);
        }
        i = li.nextIndex;
        continue;
      }
      // 预格式化
      if (raw.startsWith(' ')) {
        flush();
        const pre = this.parsePre(lines, i, end);
        if (pre.node !== null) {
          out.push(pre.node);
        }
        i = pre.nextIndex;
        continue;
      }
      // 块级 HTML 容器
      const htmlBlock = this.parseHtmlBlock(lines, i, end);
      if (htmlBlock.node !== null) {
        flush();
        out.push(htmlBlock.node as WikiNode);
        i = htmlBlock.nextIndex;
        continue;
      }
      // 普通段落行
      pending.push(raw);
      i++;
    }
    flush();
    return out;
  }

  private matchHeading(line: string): ParsedBlock | null {
    const m = line.match(/^(={1,6})\s*(.*?)\s*\1\s*$/);
    if (m === null) {
      return null;
    }
    const level = m[1].length;
    const content = m[2];
    const node: WikiNode = {
      type: NodeType.Heading,
      level: level,
      inline: this.parseInline(content),
    };
    return { node: node, nextIndex: 0 };
  }

  private isHr(line: string): boolean {
    const t = line.trim();
    if (t.length < 4) {
      return false;
    }
    for (let i = 0; i < t.length; i++) {
      if (t.charAt(i) !== '-') {
        return false;
      }
    }
    return true;
  }

  private parsePre(lines: string[], start: number, end: number): ParsedBlock {
    const buf: string[] = [];
    let i = start;
    while (i < end && lines[i].startsWith(' ')) {
      buf.push(lines[i].substring(1));
      i++;
    }
    const node: WikiNode = { type: NodeType.Pre, text: buf.join('\n') };
    return { node: node, nextIndex: i };
  }

  private parseList(lines: string[], start: number, end: number): ParsedBlock {
    const stack: ListFrame[] = [];
    const roots: WikiNode[] = [];
    let i = start;

    const closeTo = (depth: number): void => {
      while (stack.length > depth) {
        const f = stack.pop() as ListFrame;
        if (stack.length === 0) {
          roots.push({ type: f.type, children: f.children });
        } else {
          const parent = stack[stack.length - 1];
          const last = parent.children[parent.children.length - 1];
          if (last !== undefined && last.type === NodeType.ListItem) {
            if (last.children === undefined) {
              last.children = [];
            }
            (last.children as WikiNode[]).push({ type: f.type, children: f.children });
          } else {
            parent.children.push({ type: f.type, children: f.children });
          }
        }
      }
    };

    while (i < end) {
      const raw = lines[i];
      const t = raw.replace(/^\s+/, '');
      if (t.length === 0) {
        // 空行：结束列表
        closeTo(0);
        i++;
        break;
      }
      const c0 = t.charAt(0);
      if (c0 !== '*' && c0 !== '#' && c0 !== ';' && c0 !== ':') {
        break;
      }
      // 解析标记序列
      const types: NodeType[] = [];
      let pos = 0;
      let sawNonMarker = false;
      while (pos < t.length) {
        const ch = t.charAt(pos);
        if (ch === '*') {
          types.push(NodeType.UnorderedList);
          pos++;
        } else if (ch === '#') {
          types.push(NodeType.OrderedList);
          pos++;
        } else if (ch === ';') {
          types.push(NodeType.UnorderedList);
          pos++;
        } else if (ch === ':') {
          types.push(NodeType.UnorderedList);
          pos++;
        } else {
          sawNonMarker = true;
          break;
        }
      }
      const content = sawNonMarker ? t.substring(pos) : '';
      // 将 ';term:def' / ':x' 转为带缩进的条目
      const isTerm = t.charAt(0) === ';';
      const isIndent = t.charAt(0) === ':';

      // 对齐列表栈：仅创建并压栈，挂接统一由 closeTo 完成（避免同一帧被重复挂接）
      while (stack.length < types.length) {
        const f: ListFrame = { type: types[stack.length], children: [] };
        stack.push(f);
      }
      closeTo(types.length);

      const listFrame = stack[stack.length - 1];
      let inlineText = content;
      let boldTerm: WikiNode[] | null = null;
      if (isTerm) {
        const colonIdx = this.topLevelIndexOf(content, ':');
        if (colonIdx >= 0) {
          const term = content.substring(0, colonIdx).trim();
          const def = content.substring(colonIdx + 1);
          boldTerm = [{ type: NodeType.Bold, inline: this.parseInline(term) }];
          inlineText = def;
        } else {
          boldTerm = [{ type: NodeType.Bold, inline: this.parseInline(content.trim()) }];
          inlineText = '';
        }
      }
      const item: WikiNode = {
        type: NodeType.ListItem,
        inline: this.parseInline(inlineText),
      };
      if (boldTerm !== null) {
        const merged: WikiNode[] = boldTerm;
        if (inlineText.trim().length > 0) {
          merged.push({ type: NodeType.Text, text: '：' });
          merged.push(...(item.inline as WikiNode[]));
        }
        item.inline = merged;
      }
      if (isIndent) {
        item.type = NodeType.Indent;
      }
      listFrame.children.push(item);
      i++;
    }
    closeTo(0);
    // roots 已经包含各级列表；若只有一个根列表则直接返回
    const merged: WikiNode[] = [];
    for (const r of roots) {
      merged.push(r);
    }
    const node: WikiNode = merged.length === 1 ? merged[0] : { type: NodeType.Paragraph, children: merged };
    return { node: node, nextIndex: i };
  }

  private parseHtmlBlock(lines: string[], start: number, end: number): ParsedBlock {
    const raw = lines[start];
    const t = raw.replace(/^\s+/, '');
    const lower = t.toLowerCase();
    // <center> / <blockquote> / <div ...> 跨行容器
    let openTag = '';
    let closeTag = '';
    let align = '';
    if (lower.startsWith('<center')) {
      openTag = '<center';
      closeTag = '</center>';
    } else if (lower.startsWith('<blockquote')) {
      openTag = '<blockquote';
      closeTag = '</blockquote>';
    } else if (lower.startsWith('<div')) {
      openTag = '<div';
      closeTag = '</div>';
      const am = raw.match(/text-align\s*:\s*(center|left|right)/i);
      if (am !== null) {
        align = am[1];
      }
    } else if (lower.startsWith('<gallery')) {
      return this.parseGallery(lines, start, end);
    } else if (lower.startsWith('<imagemap')) {
      // 查找 </imagemap>
      let i = start;
      while (i < end && lines[i].toLowerCase().indexOf('</imagemap') < 0) {
        i++;
      }
      const node: WikiNode = { type: NodeType.Placeholder, reason: 'Imagemap 离线版暂不支持' };
      return { node: node, nextIndex: i + 1 < end ? i + 1 : i };
    } else {
      return { node: null, nextIndex: start };
    }

    // 收集直到闭合标签
    const inner: string[] = [];
    let i = start + 1;
    let closed = false;
    while (i < end) {
      if (lines[i].toLowerCase().indexOf(closeTag) >= 0) {
        const cidx = lines[i].toLowerCase().indexOf(closeTag);
        const before = lines[i].substring(0, cidx);
        if (before.trim().length > 0) {
          inner.push(before);
        }
        closed = true;
        i++;
        break;
      }
      inner.push(lines[i]);
      i++;
    }
    const childLines = inner;
    const node: WikiNode = {
      type: NodeType.Container,
      align: align.length > 0 ? align : undefined,
      children: this.parseBlocks(childLines, 0, childLines.length),
    };
    return { node: node, nextIndex: i };
  }

  private parseGallery(lines: string[], start: number, end: number): ParsedBlock {
    const files: WikiNode[] = [];
    let i = start + 1;
    while (i < end) {
      const l = lines[i].trim();
      if (l.startsWith('</gallery') || l.startsWith('</gallery>')) {
        i++;
        break;
      }
      if (l.length > 0) {
        const m = l.match(/\[\[(.*?)\]\]/);
        if (m !== null) {
          const inner = m[1];
          const fileNode = this.makeFileNode(inner);
          if (fileNode !== null) {
            files.push(fileNode);
          }
        }
      }
      i++;
    }
    const node: WikiNode = { type: NodeType.Container, children: files };
    return { node: node, nextIndex: i };
  }

  /** 解析表格 */
  private parseTable(lines: string[], start: number): ParsedTable {
    const rows: WikiNode[] = [];
    let caption: WikiNode[] | null = null;
    let currentRow: WikiNode | null = null;
    let i = start + 1;
    // rowspan 占位跟踪：行号 -> 该行被上方 rowspan 占用的列集合
    const rowspanOcc: Map<number, Set<number>> = new Map();
    let rowIndex = 0;
    let usedCols: Set<number> = new Set();

    // 计算单元格列位置（跳过被 rowspan 占用的列），并登记后续行的占位
    const placeCell = (cell: WikiNode): void => {
      const occ = rowspanOcc.get(rowIndex);
      let col = 0;
      while (usedCols.has(col) || (occ !== undefined && occ.has(col))) {
        col++;
      }
      cell.colIndex = col;
      usedCols.add(col);
      const rs = cell.rowSpan !== undefined ? cell.rowSpan : 1;
      if (rs > 1) {
        for (let r = rowIndex + 1; r < rowIndex + rs; r++) {
          const cur = rowspanOcc.get(r);
          if (cur === undefined) {
            const ns = new Set<number>();
            ns.add(col);
            rowspanOcc.set(r, ns);
          } else {
            cur.add(col);
          }
        }
      }
    };

    const pushRow = (): void => {
      if (currentRow !== null) {
        rows.push(currentRow);
        currentRow = null;
      }
      rowIndex++;
      usedCols = new Set();
    };

    while (i < lines.length) {
      const raw = lines[i];
      const t = raw.trim();
      if (t.startsWith('|}')) {
        pushRow();
        i++;
        break;
      }
      if (t.startsWith('|+')) {
        pushRow();
        const cap = t.substring(2);
        caption = this.parseInline(cap);
        i++;
        continue;
      }
      if (t.startsWith('|-')) {
        pushRow();
        i++;
        continue;
      }
      if (t.startsWith('|') || t.startsWith('!')) {
        if (currentRow === null) {
          currentRow = { type: NodeType.TableRow, children: [] };
        }
        const isHeader = t.charAt(0) === '!';
        let seg = t.substring(1);
        if (isHeader) {
          // 头部单元格按 '!!' 拆分
          const parts = this.splitDouble(seg, '!');
          for (const p of parts) {
            const cell = this.makeCell(p, true);
            placeCell(cell);
            (currentRow.children as WikiNode[]).push(cell);
          }
        } else {
          const parts = this.splitDouble(seg, '|');
          for (const p of parts) {
            const cell = this.makeCell(p, false);
            placeCell(cell);
            (currentRow.children as WikiNode[]).push(cell);
          }
        }
        i++;
        continue;
      }
      // 其他行：若是单元格内容的延续（以 '|' 或 '!' 开头之外），忽略
      i++;
    }

    const node: WikiNode = { type: NodeType.Table, children: rows };
    if (caption !== null) {
      node.caption = caption;
    }
    return { node: node, nextIndex: i };
  }

  /** 按 '||' / '!!' 拆分（顶层，忽略嵌套结构） */
  private splitDouble(text: string, ch: string): string[] {
    const parts: string[] = [];
    let i = 0;
    const n = text.length;
    let cur = '';
    while (i < n) {
      if (text.charAt(i) === ch && i + 1 < n && text.charAt(i + 1) === ch) {
        parts.push(cur);
        cur = '';
        i += 2;
        continue;
      }
      if (text.charAt(i) === '{' && i + 1 < n && text.charAt(i + 1) === '{') {
        const e = BraceUtil.findTemplateClose(text, i);
        if (e < 0) {
          break;
        }
        cur += text.substring(i, e);
        i = e;
        continue;
      }
      if (text.charAt(i) === '[' && i + 1 < n && text.charAt(i + 1) === '[') {
        const e = BraceUtil.findBracketClose(text, i);
        if (e < 0) {
          break;
        }
        cur += text.substring(i, e);
        i = e;
        continue;
      }
      cur += text.charAt(i);
      i++;
    }
    parts.push(cur);
    return parts;
  }

  private makeCell(seg: string, header: boolean): WikiNode {
    let content = seg.trim();
    let colSpan = 1;
    let rowSpan = 1;
    let align = '';
    // 属性部分：| attrs | content
    const pi = this.topLevelIndexOf(content, '|');
    if (pi >= 0) {
      const attrs = content.substring(0, pi).trim();
      if (attrs.length > 0 && attrs.indexOf('=') >= 0) {
        content = content.substring(pi + 1).trim();
        const cs = attrs.match(/colspan\s*=\s*["']?(\d+)/i);
        if (cs !== null) {
          colSpan = parseInt(cs[1]);
        }
        const rs = attrs.match(/rowspan\s*=\s*["']?(\d+)/i);
        if (rs !== null) {
          rowSpan = parseInt(rs[1]);
        }
        const am = attrs.match(/text-align\s*:\s*(center|left|right)/i);
        if (am !== null) {
          align = am[1];
        }
        const am2 = attrs.match(/align\s*=\s*["']?(center|left|right)/i);
        if (am2 !== null) {
          align = am2[1];
        }
      }
    }
    const node: WikiNode = {
      type: header ? NodeType.TableHeaderCell : NodeType.TableCell,
      inline: this.parseInline(content),
      colSpan: colSpan > 1 ? colSpan : undefined,
      rowSpan: rowSpan > 1 ? rowSpan : undefined,
      align: align.length > 0 ? align : undefined,
    };
    return node;
  }

  /** 行内解析 */
  parseInline(text: string): WikiNode[] {
    const out: WikiNode[] = [];
    let i = 0;
    const n = text.length;
    let plain = '';

    const flushPlain = (): void => {
      if (plain.length > 0) {
        out.push({ type: NodeType.Text, text: plain });
        plain = '';
      }
    };

    while (i < n) {
      const c = text.charAt(i);
      // 占位标记
      if (c === '\u0000' && text.startsWith(PLACEHOLDER_MARK, i)) {
        const end = text.indexOf('\u0000', i + PLACEHOLDER_MARK.length);
        if (end >= 0) {
          flushPlain();
          const reason = text.substring(i + PLACEHOLDER_MARK.length, end);
          out.push({ type: NodeType.Placeholder, reason: reason });
          i = end + 1;
          continue;
        }
      }
      // 内部链接 / 文件
      if (c === '[' && i + 1 < n && text.charAt(i + 1) === '[') {
        const end = BraceUtil.findBracketClose(text, i);
        if (end < 0) {
          plain += c;
          i++;
          continue;
        }
        const inner = text.substring(i + 2, end - 2);
        flushPlain();
        const handled = this.handleLinkInner(inner, out);
        if (handled) {
          i = end;
          continue;
        }
        plain += text.substring(i, end);
        i = end;
        continue;
      }
      // 外部链接 [http://... label]
      if (c === '[' && i + 2 < n && (text.startsWith('[http', i) || text.startsWith('[https', i) || text.startsWith('[ftp', i))) {
        const end = text.indexOf(']', i);
        if (end >= 0) {
          flushPlain();
          const inner = text.substring(i + 1, end);
          const sp = inner.indexOf(' ');
          if (sp > 0) {
            const url = inner.substring(0, sp);
            const label = inner.substring(sp + 1);
            out.push({ type: NodeType.ExternalLink, href: url, text: label });
          } else {
            out.push({ type: NodeType.ExternalLink, href: inner, text: inner });
          }
          i = end + 1;
          continue;
        }
      }
      // 加粗斜体
      if (text.startsWith("'''''", i)) {
        const end = text.indexOf("'''''", i + 5);
        if (end >= 0) {
          flushPlain();
          out.push({ type: NodeType.BoldItalic, inline: this.parseInline(text.substring(i + 5, end)) });
          i = end + 5;
          continue;
        }
      }
      if (text.startsWith("'''", i)) {
        const end = text.indexOf("'''", i + 3);
        if (end >= 0) {
          flushPlain();
          out.push({ type: NodeType.Bold, inline: this.parseInline(text.substring(i + 3, end)) });
          i = end + 3;
          continue;
        }
      }
      if (text.startsWith("''", i)) {
        const end = text.indexOf("''", i + 2);
        if (end >= 0) {
          flushPlain();
          out.push({ type: NodeType.Italic, inline: this.parseInline(text.substring(i + 2, end)) });
          i = end + 2;
          continue;
        }
      }
      // HTML 标签
      if (c === '<') {
        const handled = this.handleInlineTag(text, i, out, flushPlain);
        if (handled !== null) {
          flushPlain();
          i = handled;
          continue;
        }
      }
      // 实体
      if (c === '&') {
        const semi = text.indexOf(';', i);
        if (semi >= 0 && semi - i <= 10) {
          const ent = text.substring(i, semi + 1);
          const dec = this.decodeEntity(ent);
          if (dec !== null) {
            plain += dec;
            i = semi + 1;
            continue;
          }
        }
      }
      if (c === '\n') {
        plain += ' ';
        i++;
        continue;
      }
      plain += c;
      i++;
    }
    flushPlain();
    return out;
  }

  /** 处理 [[...]] 内部内容，返回是否已处理 */
  private handleLinkInner(inner: string, out: WikiNode[]): boolean {
    // 链接目标与显示
    let target = inner;
    let display: string | null = null;
    const pipe = this.topLevelIndexOf(inner, '|');
    if (pipe >= 0) {
      target = inner.substring(0, pipe);
      display = inner.substring(pipe + 1);
    }
    const t = target.trim();
    // 文件
    if (t.startsWith('文件:') || t.startsWith('File:')) {
      const fileNode = this.makeFileNode(inner);
      if (fileNode !== null) {
        out.push(fileNode);
      }
      return true;
    }
    // 分类
    if (t.startsWith('分类:') || t.startsWith('Category:') || t.startsWith('CATEGORY:')) {
      return true;
    }
    // SMW 属性标注（模板展开后应已处理，这里兜底）
    const dc = this.findDoubleColon(t);
    if (dc >= 0) {
      const val = t.substring(dc + 2);
      out.push(...this.parseInline(display !== null ? display : val));
      return true;
    }
    // 内部链接
    const resolved = this.index !== null ? this.index.resolveLink(t, this.currentTitle) : null;
    const show = display !== null ? display : t;
    if (resolved !== null) {
      out.push({ type: NodeType.Link, target: resolved, inline: this.parseInline(show) });
      return true;
    }
    // 解析失败：普通文本
    out.push(...this.parseInline(show));
    return true;
  }

  private findDoubleColon(text: string): number {
    const idx = text.indexOf('::');
    return idx;
  }

  /** 生成图片节点 */
  private makeFileNode(inner: string): WikiNode | null {
    const pipe = this.topLevelIndexOf(inner, '|');
    const first = (pipe >= 0 ? inner.substring(0, pipe) : inner).trim();
    let fileName = first;
    const colon = first.indexOf(':');
    if (colon >= 0) {
      fileName = first.substring(colon + 1);
    }
    fileName = fileName.trim();
    if (fileName.length === 0) {
      return null;
    }
    let width: number | undefined;
    let align: string | undefined;
    let link: string | undefined;
    let caption: string | null = null;
    if (pipe >= 0) {
      const opts = BraceUtil.splitTopLevel(inner.substring(pipe + 1), '|');
      for (const o of opts) {
        const opt = o.trim();
        if (opt.length === 0) {
          continue;
        }
        const w = opt.match(/^(\d+)px$/);
        if (w !== null) {
          width = parseInt(w[1]);
          continue;
        }
        // x400px：高度限定（MediaWiki 语法），按宽度近似处理
        const wh = opt.match(/^x(\d+)px$/);
        if (wh !== null) {
          width = parseInt(wh[1]);
          continue;
        }
        if (opt === 'center' || opt === '居中') {
          align = 'center';
          continue;
        }
        if (opt === 'left') {
          align = 'left';
          continue;
        }
        if (opt === 'right') {
          align = 'right';
          continue;
        }
        if (opt === 'thumb' || opt === 'thumbnail' || opt === '无框' || opt === 'frame' ||
          opt === 'frameless' || opt === 'border' || opt === 'none') {
          continue;
        }
        if (opt.startsWith('link=')) {
          link = opt.substring(5);
          continue;
        }
        if (opt.startsWith('alt=') || opt.startsWith('title=')) {
          continue;
        }
        // 说明文字
        caption = opt;
      }
    }
    const node: WikiNode = {
      type: NodeType.FileImage,
      fileName: fileName,
      fileWidth: width,
      fileAlign: align,
      fileLink: link,
    };
    if (caption !== null) {
      node.caption = this.parseInline(caption);
    }
    return node;
  }

  /** 处理行内 HTML 标签，返回跳转下标或 null */
  private handleInlineTag(text: string, i: number, out: WikiNode[], flush: () => void): number | null {
    const lower = text.toLowerCase();
    // <br>
    if (lower.startsWith('<br', i)) {
      let j = i + 3;
      while (j < text.length && text.charAt(j) !== '>') {
        j++;
      }
      out.push({ type: NodeType.LineBreak });
      if (j < text.length) {
        return j + 1;
      }
      return i + 4;
    }
    // <nowiki> 原样
    if (lower.startsWith('<nowiki>', i)) {
      const close = lower.indexOf('</nowiki>', i);
      if (close >= 0) {
        const raw = text.substring(i + 8, close);
        out.push({ type: NodeType.Text, text: raw });
        return close + 9;
      }
      return i + 8;
    }
    // <ref>…</ref> 丢弃
    if (lower.startsWith('<ref', i)) {
      const close = lower.indexOf('</ref>', i);
      if (close >= 0) {
        return close + 6;
      }
      return i;
    }
    // <gallery> 等块级残留 → 忽略
    if (lower.startsWith('<gallery', i) || lower.startsWith('<imagemap', i) ||
      lower.startsWith('<templatestyles', i) || lower.startsWith('<references', i) ||
      lower.startsWith('<noinclude', i) || lower.startsWith('<includeonly', i) ||
      lower.startsWith('<onlyinclude', i)) {
      // 找到 '>' 或对应闭合
      const gt = text.indexOf('>', i);
      if (gt < 0) {
        return i + 1;
      }
      return gt + 1;
    }
    // 格式标签：<b> <i> <u> <s> <span> <div> <small> <big> <sup> <sub> <font> <center>
    const tagMatch = text.substring(i).match(/^<\/?([a-zA-Z0-9]+)\b[^>]*>/);
    if (tagMatch !== null) {
      const tagName = tagMatch[1].toLowerCase();
      const full = tagMatch[0];
      const isClose = full.charAt(1) === '/';
      if (tagName === 'b') {
        if (!isClose) {
          const close = lower.indexOf('</b>', i);
          if (close >= 0) {
            out.push({ type: NodeType.Bold, inline: this.parseInline(text.substring(i + full.length, close)) });
            return close + 4;
          }
        }
        return i + full.length;
      }
      if (tagName === 'i') {
        if (!isClose) {
          const close = lower.indexOf('</i>', i);
          if (close >= 0) {
            out.push({ type: NodeType.Italic, inline: this.parseInline(text.substring(i + full.length, close)) });
            return close + 4;
          }
        }
        return i + full.length;
      }
      if (tagName === 'span' || tagName === 'div' || tagName === 'font' || tagName === 'small' ||
        tagName === 'big' || tagName === 'sup' || tagName === 'sub' || tagName === 'u' ||
        tagName === 's' || tagName === 'center' || tagName === 'abbr') {
        return i + full.length;
      }
      // 其他标签原样输出文本
      return i + full.length;
    }
    return null;
  }

  private decodeEntity(ent: string): string | null {
    switch (ent) {
      case '&amp;': return '&';
      case '&lt;': return '<';
      case '&gt;': return '>';
      case '&quot;': return '"';
      case '&nbsp;': return ' ';
      case '&apos;': return "'";
      case '&#39;': return "'";
      case '&#039;': return "'";
      case '&middot;': return '·';
      case '&bull;': return '•';
      case '&minus;': return '−';
      case '&times;': return '×';
      case '&ndash;': return '–';
      case '&mdash;': return '—';
      case '&hellip;': return '…';
      case '&copy;': return '©';
      case '&reg;': return '®';
      case '&trade;': return '™';
      default: {
        const m = ent.match(/^&#(\d+);$/);
        if (m !== null) {
          return String.fromCharCode(parseInt(m[1]));
        }
        return null;
      }
    }
  }

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
