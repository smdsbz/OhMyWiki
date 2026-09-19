import { Logger } from '../../common/Logger';
import { WikiIndex } from '../../data/WikiIndex';
import { NodeType, WikiNode, MapMarker } from '../../model/WikiTypes';
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
  /** 与 node 同级的后续块（如闭合标签之后同一行的余量解析结果） */
  siblings?: WikiNode[];
}

/** 混合文本切分出的顶层块级 HTML 片段 */
interface HtmlChunk {
  /** 'div' | 'ol' | 'ul' | 'text' */
  kind: string;
  text?: string;
  /** 块级片段的完整开标签原文（div 用，提取 class/id） */
  openTag?: string;
  /** 块级片段的内部内容 */
  inner?: string;
}

/** splitTopBlocks 结果：前导文本（进 li inline）+ 交替片段序列 */
interface TopSplit {
  lead: string;
  pieces: HtmlChunk[];
}

/** lineCloseLi 结果：外层 li 在行内的闭合位置与闭合后余量 */
interface LiScan {
  closeIdx: number;
  rest: string;
}

/**
 * wikitext → 节点树解析器。
 * 输入应为「模板已展开」的文本（含 [[链接]]、[[文件:…]]、表格、列表等）。
 */
export class WikitextParser {
  private index: WikiIndex | null;
  private currentTitle: string;
  /** 无 id 的 mw-collapsible 容器自动编号 */
  private collapsibleSeq: number = 0;

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

  /** 检查文本是否有未闭合的 [[ 或 {{（跨行链接/模板） */
  private hasUnclosedBrackets(text: string): boolean {
    let i = 0;
    const n = text.length;
    while (i < n - 1) {
      if (text.charAt(i) === '[' && text.charAt(i + 1) === '[') {
        const end = BraceUtil.findBracketClose(text, i);
        if (end < 0) {
          return true;
        }
        i = end;
        continue;
      }
      if (text.charAt(i) === '{' && text.charAt(i + 1) === '{') {
        const end = BraceUtil.findTemplateClose(text, i);
        if (end < 0) {
          return true;
        }
        i = end;
        continue;
      }
      i++;
    }
    return false;
  }

  private isListLine(line: string): boolean {
    const t = line.replace(/^\s*/, '');
    return t.length > 0 && (t.charAt(0) === '*' || t.charAt(0) === '#' || t.charAt(0) === ';' || t.charAt(0) === ':');
  }

  /** 解析地图行：@@WIKIMAP|底图文件名|标题|宽|高|left,top;left,top...@@ */
  private parseMapLine(line: string): WikiNode | null {
    try {
      const body = line.substring('@@WIKIMAP|'.length, line.length - 2);
      const parts = body.split('|');
      if (parts.length < 5) {
        return null;
      }
      const image = parts[0].trim();
      const title = parts[1].trim();
      const w = parseFloat(parts[2]);
      const h = parseFloat(parts[3]);
      const markers: MapMarker[] = [];
      if (parts[4].length > 0) {
        for (const seg of parts[4].split(';')) {
          const xy = seg.split(',');
          if (xy.length === 2) {
            markers.push({ left: parseFloat(xy[0]), top: parseFloat(xy[1]) });
          }
        }
      }
      if (image.length === 0 || isNaN(w) || isNaN(h) || h <= 0 || markers.length === 0) {
        return null;
      }
      const node: WikiNode = {
        type: NodeType.Map,
        mapImage: image,
        mapTitle: title,
        mapRatio: w / h,
        mapMarkers: markers,
      };
      return node;
    } catch (e) {
      return null;
    }
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
      // 地图：@@WIKIMAP|底图文件名|标题|宽|高|left,top;left,top...@@（模块输出的通用协议）
      if (trimmed.startsWith('@@WIKIMAP|') && trimmed.endsWith('@@')) {
        flush();
        const node = this.parseMapLine(trimmed);
        if (node !== null) {
          out.push(node);
        }
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
        if (htmlBlock.siblings !== undefined) {
          for (const s of htmlBlock.siblings) {
            out.push(s);
          }
        }
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
      // 合并未闭合的 [[ / {{ 到后续行（如 [[NPC:米米\n|米米\n]]），直到括号闭合
      let mergedContent = content;
      while (this.hasUnclosedBrackets(mergedContent) && i + 1 < end) {
        const nextLine = lines[i + 1];
        const nt = nextLine.replace(/^\s+/, '');
        // 不合并以列表标记开头的行（那是新的列表项）
        if (nt.length > 0 && (nt.charAt(0) === '*' || nt.charAt(0) === '#' ||
          nt.charAt(0) === ';' || nt.charAt(0) === ':')) {
          break;
        }
        i++;
        mergedContent += '\n' + nextLine;
      }
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
      let inlineText = mergedContent;
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
    } else if (lower.startsWith('<ol') || lower.startsWith('<ul')) {
      return this.parseHtmlList(lines, start, end);
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

    // 同行开闭形态（<div ...>内容</div> 单行）：取标签间内容解析，
    //  闭合位置按嵌套深度配平（内层 div 的 </div> 不提前闭合外层）；
    //  闭合标签后的行尾余量解析为兄弟块（不属于容器内容）。
    //  注意在去缩进后的 t/lower 上取下标，保证二者对齐
    const openEnd = t.indexOf('>');
    const closeIdx = openEnd >= 0 ? this.findBalancedClose(lower, openEnd + 1, openTag, closeTag) : -1;
    if (closeIdx >= 0) {
      const innerLines: string[] = [];
      const content = t.substring(openEnd + 1, closeIdx);
      if (content.trim().length > 0) {
        innerLines.push(content);
      }
      const node = this.buildHtmlContainer(t, align, innerLines);
      const siblings: WikiNode[] = [];
      const remainder = t.substring(this.endOfCloseTag(t, closeIdx, closeTag));
      if (remainder.trim().length > 0) {
        const rem = this.parseBlocks([remainder], 0, 1);
        for (const s of rem) {
          siblings.push(s);
        }
      }
      return { node: node, nextIndex: start + 1, siblings: siblings.length > 0 ? siblings : undefined };
    }

    // 收集直到闭合标签（深度感知：嵌套同名标签不提前闭合）
    const inner: string[] = [];
    let i = start + 1;
    let closed = false;
    let depth = 1;
    let afterLines: string[] = [];
    while (i < end) {
      const line = lines[i];
      const lowerLine = line.toLowerCase();
      let pos = 0;
      let closedAt = -1;
      while (pos < lowerLine.length) {
        const o = lowerLine.indexOf(openTag, pos);
        const c = lowerLine.indexOf(closeTag, pos);
        if (c < 0) {
          if (o >= 0) {
            depth++;
            pos = o + openTag.length;
            continue;
          }
          break;
        }
        if (o >= 0 && o < c) {
          depth++;
          pos = o + openTag.length;
        } else {
          depth--;
          if (depth === 0) {
            closedAt = c;
            break;
          }
          pos = c + closeTag.length;
        }
      }
      if (closedAt >= 0) {
        const before = line.substring(0, closedAt);
        if (before.trim().length > 0) {
          inner.push(before);
        }
        const rest = line.substring(this.endOfCloseTag(line, closedAt, closeTag));
        if (rest.trim().length > 0) {
          afterLines = [rest];
        }
        closed = true;
        i++;
        break;
      }
      inner.push(line);
      i++;
    }
    const node = this.buildHtmlContainer(t, align, inner);
    if (!closed) {
      // 未闭合：尽力渲染已收集内容
      return { node: node, nextIndex: i };
    }
    const siblings: WikiNode[] = [];
    if (afterLines.length > 0) {
      const rem = this.parseBlocks(afterLines, 0, afterLines.length);
      for (const s of rem) {
        siblings.push(s);
      }
    }
    return { node: node, nextIndex: i, siblings: siblings.length > 0 ? siblings : undefined };
  }

  /** 闭合标签的结束下标（closeTag 形如 '</div'，需再吞掉 '>' 及可能的空白） */
  private endOfCloseTag(text: string, closeIdx: number, closeTag: string): number {
    const gt = text.indexOf('>', closeIdx + closeTag.length);
    return gt >= 0 ? gt + 1 : closeIdx + closeTag.length;
  }

  /** 从 from 起找配平的外层闭合标签下标（openTag 出现一次深度+1，closeTag 一次-1，归 0 处闭合） */
  private findBalancedClose(lower: string, from: number, openTag: string, closeTag: string): number {
    let depth = 1;
    let i = from;
    while (i < lower.length) {
      const o = lower.indexOf(openTag, i);
      const c = lower.indexOf(closeTag, i);
      if (c < 0) {
        return -1;
      }
      if (o >= 0 && o < c) {
        depth++;
        i = o + openTag.length;
      } else {
        depth--;
        if (depth === 0) {
          return c;
        }
        i = c + closeTag.length;
      }
    }
    return -1;
  }

  /** 组装 HTML 块容器节点：解析 class/id（mw-collapsible 折叠标记）并挂接子块 */
  private buildHtmlContainer(openTagRaw: string, align: string, innerLines: string[]): WikiNode {
    const node: WikiNode = {
      type: NodeType.Container,
      align: align.length > 0 ? align : undefined,
      children: this.parseBlocks(innerLines, 0, innerLines.length),
    };
    if (/^<div\b/i.test(openTagRaw)) {
      const cm = openTagRaw.match(/class\s*=\s*"([^"]*)"/i);
      if (cm !== null && cm[1].length > 0) {
        node.htmlClass = cm[1];
      }
      this.applyCollapsibleAttrs(openTagRaw, node);
    }
    return node;
  }

  /** 开标签属性中的 MediaWiki 折叠标记：class 含 mw-customtoggle-X → toggleFor；
   *  class 含 mw-collapsible（id=mw-customcollapsible-X）→ collapsibleId/collapsed。
   *  容器与表格行（|- class=…）共用 */
  private applyCollapsibleAttrs(attrText: string, node: WikiNode): void {
    const cm = attrText.match(/class\s*=\s*"([^"]*)"/i);
    if (cm === null) {
      return;
    }
    const cls = cm[1];
    const tm = cls.match(/\bmw-customtoggle-([^\s"]+)/);
    if (tm !== null) {
      node.toggleFor = tm[1];
    }
    if (/\bmw-collapsible\b/.test(cls)) {
      const im = attrText.match(/id\s*=\s*"mw-customcollapsible-([^"\s]+)"/i);
      node.collapsibleId = im !== null ? im[1] : 'auto' + (++this.collapsibleSeq);
      node.collapsed = /\bmw-collapsed\b/.test(cls);
    }
  }

  /** 解析 HTML 列表 <ol>/<ul>：每个 <li>…</li> 一个列表项（支持跨行 li、嵌套列表、内嵌 div） */
  private parseHtmlList(lines: string[], start: number, end: number): ParsedBlock {
    const first = lines[start].replace(/^\s+/, '');
    const lowerFirst = first.toLowerCase();
    const ordered = lowerFirst.startsWith('<ol');
    // 同行完整形式（模板展开产物常见）：<ol><li>…</li><li>…</li></ol>
    const openTag = ordered ? '<ol' : '<ul';
    const closeTag = ordered ? '</ol' : '</ul';
    if (lowerFirst.indexOf(closeTag) >= 0) {
      const openEnd = first.indexOf('>');
      const closeIdx = openEnd >= 0 ? this.findBalancedClose(lowerFirst, openEnd + 1, openTag, closeTag) : -1;
      if (closeIdx >= 0) {
        const inner = first.substring(openEnd + 1, closeIdx);
        const node = this.buildHtmlList(ordered, inner);
        const siblings: WikiNode[] = [];
        const rest = first.substring(this.endOfCloseTag(first, closeIdx, closeTag));
        if (rest.trim().length > 0) {
          const rem = this.parseBlocks([rest], 0, 1);
          for (const s of rem) {
            siblings.push(s);
          }
        }
        return { node: node, nextIndex: start + 1, siblings: siblings.length > 0 ? siblings : undefined };
      }
    }
    const items: WikiNode[] = [];
    let i = start + 1;
    let current: string[] = [];
    let inItem = false;
    let closed = false;
    const flushItem = (): void => {
      if (current.length > 0) {
        items.push(this.makeHtmlListItem(current.join('\n').trim()));
        current = [];
      }
    };
    while (i < end) {
      const line = lines[i];
      const trimmed = line.trim();
      const lower = trimmed.toLowerCase();
      if (lower.startsWith('</ol') || lower.startsWith('</ul')) {
        if (inItem) {
          flushItem();
          inItem = false;
        }
        i++;
        closed = true;
        break;
      }
      if (lower.startsWith('<li')) {
        if (inItem) {
          flushItem();
        }
        inItem = true;
        const gt = lower.indexOf('>');
        if (gt >= 0) {
          const body = trimmed.substring(gt + 1);
          // 同行闭合的 <li>xxx</li>：内嵌 </li> 不提前闭合——按 li 嵌套深度配平
          const scan = this.lineCloseLi(body, 1);
          if (scan.closeIdx >= 0) {
            const piece = body.substring(0, scan.closeIdx);
            if (piece.trim().length > 0) {
              current.push(piece);
            }
            flushItem();
            inItem = false;
          } else if (body.trim().length > 0) {
            current.push(body);
          }
        }
        i++;
        continue;
      }
      if (lower.startsWith('</li')) {
        flushItem();
        inItem = false;
        i++;
        continue;
      }
      if (inItem) {
        // li 续行：内嵌嵌套列表的 </li> 不算外层闭合，深度配平归零才是本项结束
        const scan = this.lineCloseLi(trimmed, 1);
        if (scan.closeIdx >= 0) {
          const before = trimmed.substring(0, scan.closeIdx);
          if (before.trim().length > 0) {
            current.push(before);
          }
          flushItem();
          inItem = false;
        } else {
          current.push(trimmed);
        }
      }
      i++;
    }
    if (inItem) {
      flushItem();
    }
    if (!closed && items.length === 0) {
      return { node: null, nextIndex: start };
    }
    const node: WikiNode = {
      type: ordered ? NodeType.OrderedList : NodeType.UnorderedList,
      children: items,
    };
    return { node: node, nextIndex: i };
  }

  /** 单行文本内找 li 深度归零位置（depthIn 为进入本行前的深度） */
  private lineCloseLi(text: string, depthIn: number): LiScan {
    const re = /<(\/?)li\b[^>]*>/gi;
    let depth = depthIn;
    let m: RegExpExecArray | null;
    while ((m = re.exec(text)) !== null) {
      depth += m[1] === '/' ? -1 : 1;
      if (depth === 0) {
        const res: LiScan = { closeIdx: m.index, rest: text.substring(m.index + m[0].length) };
        return res;
      }
    }
    const none: LiScan = { closeIdx: -1, rest: '' };
    return none;
  }

  /** 从列表 inner 文本切出各 li 项（嵌套列表归属其外层项）并建列表节点 */
  private buildHtmlList(ordered: boolean, inner: string): WikiNode {
    const items: WikiNode[] = [];
    const re = /<(\/?)li\b[^>]*>/gi;
    let depth = 0;
    let itemStart = -1;
    let m: RegExpExecArray | null;
    while ((m = re.exec(inner)) !== null) {
      if (m[1] === '/') {
        depth--;
        if (depth === 0) {
          const raw = inner.substring(itemStart, m.index);
          if (raw.trim().length > 0) {
            items.push(this.makeHtmlListItem(raw));
          }
          itemStart = -1;
        }
      } else {
        depth++;
        if (depth === 1) {
          itemStart = m.index + m[0].length;
        }
      }
    }
    if (depth >= 1 && itemStart >= 0) {
      // 未闭合的尾项：尽力收
      const raw = inner.substring(itemStart);
      if (raw.trim().length > 0) {
        items.push(this.makeHtmlListItem(raw));
      }
    }
    return { type: ordered ? NodeType.OrderedList : NodeType.UnorderedList, children: items };
  }

  /** li 原文 → ListItem：前导行内文本进 inline（列表标号随行），
   *  其后的顶层块级 HTML（div/ol/ul，如折叠内容、嵌套列表）进 children，
   *  块间的尾随文本也按顺序包成 Paragraph 进 children（保持视觉顺序） */
  private makeHtmlListItem(text: string): WikiNode {
    const parts = this.splitTopBlocks(text);
    const inline = parts.lead.trim().length > 0 ? this.parseInline(parts.lead) : [];
    const node: WikiNode = { type: NodeType.ListItem, inline: inline };
    if (parts.pieces.length > 0) {
      node.children = [];
      for (const p of parts.pieces) {
        if (p.kind === 'text') {
          const txt = (p.text ?? '').replace(/^(\s*<br\s*\/?>)+/i, '');
          if (txt.trim().length > 0) {
            (node.children as WikiNode[]).push({ type: NodeType.Paragraph, inline: this.parseInline(txt) });
          }
        } else {
          const parsed = this.parseBlockChunk(p);
          if (parsed !== null) {
            (node.children as WikiNode[]).push(parsed);
          }
        }
      }
      if ((node.children as WikiNode[]).length === 0) {
        node.children = undefined;
      }
    }
    return node;
  }

  /** 把混合文本切为前导文本与顶层块级 HTML 片段（div/ol/ul 深度感知配平） */
  private splitTopBlocks(text: string): TopSplit {
    const out: TopSplit = { lead: '', pieces: [] };
    const lower = text.toLowerCase();
    const re = /<(div|ol|ul)\b[^>]*>/gi;
    let cursor = 0;
    let m: RegExpExecArray | null;
    while ((m = re.exec(text)) !== null) {
      if (m.index < cursor) {
        continue; // 已被前一块吞掉的嵌套标签
      }
      const kind = m[1].toLowerCase();
      const openTag = '<' + kind;
      const closeTag = '</' + kind;
      const closeIdx = this.findBalancedClose(lower, m.index + m[0].length, openTag, closeTag);
      if (closeIdx < 0) {
        continue; // 未配平：当普通文本（行内解析会丢弃裸标签）
      }
      const chunkEnd = this.endOfCloseTag(text, closeIdx, closeTag);
      const between = text.substring(cursor, m.index);
      if (out.lead.length === 0 && out.pieces.length === 0) {
        out.lead = between;
      } else if (between.trim().length > 0) {
        out.pieces.push({ kind: 'text', text: between });
      }
      out.pieces.push({ kind: kind, openTag: text.substring(m.index, m.index + m[0].length),
        inner: text.substring(m.index + m[0].length, closeIdx) });
      cursor = chunkEnd;
    }
    const tail = text.substring(cursor);
    if (out.lead.length === 0 && out.pieces.length === 0) {
      out.lead = tail;
    } else if (tail.trim().length > 0) {
      out.pieces.push({ kind: 'text', text: tail });
    }
    return out;
  }

  /** 单个顶层块级 HTML 片段 → 节点 */
  private parseBlockChunk(p: HtmlChunk): WikiNode | null {
    if (p.kind === 'div') {
      const innerLines = (p.inner ?? '').split('\n');
      return this.buildHtmlContainer(p.openTag ?? '', '', innerLines);
    }
    if (p.kind === 'ol' || p.kind === 'ul') {
      return this.buildHtmlList(p.kind === 'ol', p.inner ?? '');
    }
    return null;
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
    let rowAttrs = '';
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
        // 行属性（|- class="mw-customtoggle-X" / |- class="mw-collapsible mw-collapsed" id=…）：
        //  行级折叠标记，待该行首个单元格建行时套用
        rowAttrs = t.substring(2);
        i++;
        continue;
      }
      if (t.startsWith('|') || t.startsWith('!')) {
        if (currentRow === null) {
          currentRow = { type: NodeType.TableRow, children: [] };
          if (rowAttrs.length > 0) {
            this.applyCollapsibleAttrs(rowAttrs, currentRow);
            rowAttrs = '';
          }
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
      // 其他行：若是单元格内容的延续（以 '|' 或 '!' 开头之外），追加到最后一个单元格。
      //  延续内容按行内语法解析——可能含链接等结构，不能当纯文本拼接（否则 [[..]] 原文泄漏）
      if (currentRow !== null && (currentRow.children as WikiNode[]).length > 0) {
        const cells = currentRow.children as WikiNode[];
        const lastCell = cells[cells.length - 1];
        const lastInline = lastCell.inline as WikiNode[];
        const contText = raw.trim();
        if (contText.length > 0) {
          const parsed = this.parseInline(contText);
          // MediaWiki 语义：单元格内跨行内容以空格连接
          const first = parsed.length > 0 ? parsed[0] : null;
          if (first !== null && first.type === NodeType.Text) {
            first.text = ' ' + (first.text ?? '');
            for (const p of parsed) {
              lastInline.push(p);
            }
          } else if (first !== null) {
            lastInline.push({ type: NodeType.Text, text: ' ' });
            for (const p of parsed) {
              lastInline.push(p);
            }
          } else {
            lastInline.push({ type: NodeType.Text, text: ' ' });
          }
        }
      }
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
    let widthPct = 0;
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
        const wm = attrs.match(/width\s*=\s*["']?(\d+(?:\.\d+)?)%?/i);
        if (wm === null) {
          const ws = attrs.match(/width\s*:\s*(\d+(?:\.\d+)?)%/i);
          if (ws !== null) {
            widthPct = parseFloat(ws[1]);
          }
        } else if (wm[0].indexOf('%') >= 0) {
          widthPct = parseFloat(wm[1]);
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
    if (widthPct > 0) {
      node.widthPct = widthPct;
    }
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
      // HTML 标签：先 flush 前置文本再入 handler——handler 直接 push 节点，
      //  后 flush 会把换行/样式节点排到前文之前（A<br>B 曾渲染为 ⏎AB）
      if (c === '<') {
        flushPlain();
        const handled = this.handleInlineTag(text, i, out, flushPlain);
        if (handled !== null) {
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
    let height: number | undefined;
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
        // x400px：高度限定（MediaWiki 语法）
        const wh = opt.match(/^x(\d+)px$/);
        if (wh !== null) {
          height = parseInt(wh[1]);
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
      fileHeight: height,
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
    // Web 嵌入（bilibili iframe 等）：无法离线呈现，显式占位而非静默丢弃
    if (lower.startsWith('<iframe', i) || lower.startsWith('<video', i) ||
      lower.startsWith('<embed', i) || lower.startsWith('<audio', i)) {
      const selfClose = lower.indexOf('>', i);
      if (selfClose >= 0) {
        out.push({ type: NodeType.Placeholder, reason: '嵌入视频/外部内容（离线版暂不支持）' });
        return selfClose + 1;
      }
      const closeGuess = lower.indexOf('</' + (lower.startsWith('<iframe', i) ? 'iframe' : 'video'), i);
      return closeGuess >= 0 ? closeGuess : i;
    }
    // <gallery> 等块级残留 → 忽略（ol/ul/li 由 parseHtmlList 块级处理，此处为行内兜底）
    if (lower.startsWith('<gallery', i) || lower.startsWith('<imagemap', i) ||
      lower.startsWith('<templatestyles', i) || lower.startsWith('<references', i) ||
      lower.startsWith('<noinclude', i) || lower.startsWith('<includeonly', i) ||
      lower.startsWith('<onlyinclude', i) || lower.startsWith('<ol', i) ||
      lower.startsWith('<ul', i) || lower.startsWith('<li', i) ||
      lower.startsWith('</ol', i) || lower.startsWith('</ul', i) || lower.startsWith('</li', i)) {
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
        // 折叠开关（MediaWiki mw-customtoggle-X）：包成带 toggleFor 的样式节点，渲染期接点击
        if (!isClose) {
          const tm = full.match(/class\s*=\s*"[^"]*\bmw-customtoggle-([^\s"]+)/i);
          if (tm !== null) {
            const toggleCloseTag = '</' + tagName + '>';
            const tclose = lower.indexOf(toggleCloseTag, i + full.length);
            if (tclose >= 0) {
              const node: WikiNode = {
                type: NodeType.Color,
                inline: this.parseInline(text.substring(i + full.length, tclose)),
                toggleFor: tm[1],
              };
              const tcolor = this.tagColor(full);
              if (tcolor !== null) {
                node.color = tcolor;
              }
              out.push(node);
              return tclose + toggleCloseTag.length;
            }
          }
        }
        // 带样式语义的容器（<font color> / style color / <small><big> 字号）：包成样式节点
        if (!isClose) {
          const color = this.tagColor(full);
          const fontSize = tagName === 'small' ? 10 : (tagName === 'big' ? 18 : 0);
          if (color !== null || fontSize > 0) {
            const closeTag = '</' + tagName + '>';
            const close = lower.indexOf(closeTag, i);
            if (close >= 0) {
              const node: WikiNode = {
                type: NodeType.Color,
                inline: this.parseInline(text.substring(i + full.length, close)),
              };
              if (color !== null) {
                node.color = color;
              }
              if (fontSize > 0) {
                node.fontSize = fontSize;
              }
              out.push(node);
              return close + closeTag.length;
            }
          }
        }
        return i + full.length;
      }
      // 其他标签原样输出文本
      return i + full.length;
    }
    return null;
  }

  /** 从标签原文提取颜色：color 属性或 style 内 color: 声明（仅接受 #rrgg[bbl] 形式） */
  private tagColor(tag: string): string | null {
    const cm = tag.match(/color\s*=\s*"(#[0-9a-fA-F]{3,8})"/i);
    if (cm !== null) {
      return cm[1];
    }
    const sm = tag.match(/color\s*:\s*(#[0-9a-fA-F]{3,8})/i);
    if (sm !== null) {
      return sm[1];
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
