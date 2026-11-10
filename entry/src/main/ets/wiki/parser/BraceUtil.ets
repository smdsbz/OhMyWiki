/**
 * 括号/标签扫描工具：被模板引擎与 wikitext 解析器共用。
 */

export class BraceUtil {
  /**
   * 找到与 text[openIdx..openIdx+1] == '{{' 匹配的 '}}'。
   * 跳过：{{{...}}} 参数块、[[...]] 链接块、<nowiki>...</nowiki>。
   * @returns '}}' 之后的下标；未找到返回 -1
   */
  static findTemplateClose(text: string, openIdx: number): number {
    // 起始即三花括号（{{{X}}} 参数 / {{{X}} 2 闭形态）：
    //  - 真参数块：整块吞掉（与下方循环内遇嵌套三括号一致）
    //  - 2 闭形态：返回 -1，调用方逐字符降级（首 '{' 字面量 + {{X}} 正常配平），
    //    避免把 {{{X}} 误锚成模板 {{ {!}} }} 导致整块蒸发
    if (text.charCodeAt(openIdx) === 123 && text.charCodeAt(openIdx + 1) === 123 &&
      text.charCodeAt(openIdx + 2) === 123) {
      const tend = BraceUtil.skipTripleBrace(text, openIdx);
      return tend;
    }
    let i = openIdx + 2;
    let depth = 1;
    const n = text.length;
    while (i < n - 1) {
      // 参数块 {{{...}}}
      if (text.charCodeAt(i) === 123 && text.charCodeAt(i + 1) === 123 && text.charCodeAt(i + 2) === 123) {
        const end = BraceUtil.skipTripleBrace(text, i);
        if (end > 0) {
          i = end;
          continue;
        }
        if (end < 0) {
          // 2 闭形态 {{{X}}（MediaWiki 括号栈语义 = '{' + {{X}}）：吃掉首 '{' 字面量，
          // 余下 {{X}} 交给下方普通深度配平——不能作 -1 上抛，否则含此构造的外层调用整体炸掉
          i++;
          continue;
        }
      }
      // 链接块 [[...]]
      if (text.charCodeAt(i) === 91 && text.charCodeAt(i + 1) === 91) {
        const end = BraceUtil.findBracketClose(text, i);
        if (end < 0) {
          return -1;
        }
        i = end;
        continue;
      }
      // <nowiki> / <pre> 块
      if (text.charCodeAt(i) === 60) {
        const lt = text.indexOf('<', i);
        if (lt === i) {
          const tagEnd = BraceUtil.skipXmlBlock(text, i);
          if (tagEnd > i) {
            i = tagEnd;
            continue;
          }
        }
      }
      const c0 = text.charCodeAt(i);
      const c1 = text.charCodeAt(i + 1);
      if (c0 === 123 && c1 === 123) {
        depth++;
        i += 2;
        continue;
      }
      if (c0 === 125 && c1 === 125) {
        depth--;
        i += 2;
        if (depth === 0) {
          return i;
        }
        continue;
      }
      i++;
    }
    return -1;
  }

  /** 跳过 {{{...}}} 参数块（含嵌套），返回其后下标；未找到返回 -1 */
  static skipTripleBrace(text: string, openIdx: number): number {
    let i = openIdx + 3;
    let depth = 1;
    const n = text.length;
    while (i < n - 2) {
      if (text.charCodeAt(i) === 123 && text.charCodeAt(i + 1) === 123 && text.charCodeAt(i + 2) === 123) {
        depth++;
        i += 3;
        continue;
      }
      // 默认值内嵌套的 {{模板}} / [[链接]]：整块跳过，防止其闭合括号被误当参数块的 }}}
      // （如 {{{1|{{FULLPAGENAME}}}}} 曾被截在首个 }}}，残留 }} 使后续配平全盘错位）
      if (text.charCodeAt(i) === 123 && text.charCodeAt(i + 1) === 123) {
        const e = BraceUtil.findTemplateClose(text, i);
        if (e < 0) {
          return -1;
        }
        i = e;
        continue;
      }
      if (text.charCodeAt(i) === 91 && text.charCodeAt(i + 1) === 91) {
        const e = BraceUtil.findBracketClose(text, i);
        if (e < 0) {
          return -1;
        }
        i = e;
        continue;
      }
      // 2 闭形态 {{{X}}：depth 1 时遇到孤立 }}（后一字符非 }）= 块以 {{X}} 收尾、
      // 首个 { 为字面量 —— 返回 -1 让调用方走降级路径（不能吞到远处别的参数的 }}}）
      if (text.charCodeAt(i) === 125 && text.charCodeAt(i + 1) === 125 &&
        text.charCodeAt(i + 2) !== 125 && depth === 1) {
        return -1;
      }
      if (text.charCodeAt(i) === 125 && text.charCodeAt(i + 1) === 125 && text.charCodeAt(i + 2) === 125) {
        depth--;
        i += 3;
        if (depth === 0) {
          return i;
        }
        continue;
      }
      i++;
    }
    return -1;
  }

  /** 找到与 [[ 匹配的 ]]，返回其后下标；未找到返回 -1 */
  static findBracketClose(text: string, openIdx: number): number {
    let i = openIdx + 2;
    let depth = 1;
    const n = text.length;
    while (i < n - 1) {
      if (text.charCodeAt(i) === 91 && text.charCodeAt(i + 1) === 91) {
        depth++;
        i += 2;
        continue;
      }
      if (text.charCodeAt(i) === 93 && text.charCodeAt(i + 1) === 93) {
        depth--;
        i += 2;
        if (depth === 0) {
          return i;
        }
        continue;
      }
      i++;
    }
    return -1;
  }

  /**
   * 跳过 <name ...>...</name> 或自闭合 <name .../>。
   * openIdx 指向 '<'。返回其后下标；不是合法标签返回 openIdx。
   */
  static skipXmlBlock(text: string, openIdx: number): number {
    const n = text.length;
    // 解析标签名
    let j = openIdx + 1;
    while (j < n && (text[j] === ' ' || text[j] === '\t')) {
      j++;
    }
    let nameStart = j;
    while (j < n && !(text[j] === ' ' || text[j] === '\t' || text[j] === '>' || text[j] === '/')) {
      j++;
    }
    if (j === nameStart) {
      return openIdx;
    }
    const name = text.substring(nameStart, j);
    const lower = name.toLowerCase();
    // 仅处理可跳过的块级/保护标签
    if (lower !== 'nowiki' && lower !== 'pre' && lower !== 'gallery' && lower !== 'ref' &&
      lower !== 'syntaxhighlight' && lower !== 'source' && lower !== 'imagemap' &&
      lower !== 'includeonly' && lower !== 'noinclude' && lower !== 'poem') {
      return openIdx;
    }
    // 自闭合
    let k = j;
    while (k < n && text[k] !== '>') {
      k++;
    }
    if (k >= n) {
      return openIdx;
    }
    if (k > j && text[k - 1] === '/') {
      return k + 1;
    }
    // 找闭合标签
    const closeTag = '</' + name + '>';
    const ci = text.toLowerCase().indexOf(closeTag, k);
    if (ci < 0) {
      // 未闭合，跳到标签结束
      return k + 1;
    }
    return ci + closeTag.length;
  }

  /**
   * 按顶层分隔符拆分（分隔符不出现在 {{{ }}}、[[ ]]、{{ }} 内）。
   * @param sep 分隔字符，如 '|'
   */
  static splitTopLevel(text: string, sep: string): string[] {
    const parts: string[] = [];
    let start = 0;
    let i = 0;
    const n = text.length;
    while (i < n) {
      const c = text.charAt(i);
      if (c === '{' && i + 1 < n && text.charAt(i + 1) === '{') {
        const end = BraceUtil.findTemplateClose(text, i);
        if (end < 0) {
          break;
        }
        i = end;
        continue;
      }
      if (c === '[' && i + 1 < n && text.charAt(i + 1) === '[') {
        const end = BraceUtil.findBracketClose(text, i);
        if (end < 0) {
          break;
        }
        i = end;
        continue;
      }
      if (c === '<' && i + 2 < n) {
        const tagEnd = BraceUtil.skipXmlBlock(text, i);
        if (tagEnd > i) {
          i = tagEnd;
          continue;
        }
      }
      if (c === sep) {
        parts.push(text.substring(start, i));
        start = i + 1;
      }
      i++;
    }
    parts.push(text.substring(start));
    return parts;
  }
}
