import { TemplateContext } from '../../template/TemplateEngine';
import { SdvArgs } from './SdvArgs';

/** {{#invoke:Array|main}}（{{#invoke: Array |}} 带空格也要命中）：
 *  仅移植 dump 实际用到的 delimiter/finaldelimiter/pretty/newline/list 分支 */
export class ArrayModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const f = func.trim().toLowerCase();
    if (f !== 'main' && f !== 'array') {
      return '';
    }
    const delimiter = SdvArgs.named(args, 'delimiter') ?? SdvArgs.named(args, 'd') ?? '';
    const finalDelimiter = SdvArgs.named(args, 'finaldelimiter') ?? SdvArgs.named(args, 'fd') ?? '';
    const sep = SdvArgs.namedOr(args, 'sep', ',');
    const mode = SdvArgs.namedOr(args, 'mode', '');

    let arr: string[];
    if (mode === 'single') {
      const src = SdvArgs.pos(args, 0);
      arr = src.length > 0 ? src.split(sep).map((v: string): string => v.trim()) : [];
    } else {
      arr = SdvArgs.positional(args).filter((v: string): boolean => v.trim().length > 0);
    }
    if (arr.length === 0) {
      return '';
    }
    if (delimiter === 'pretty') {
      // mw.text.listToText：A、B 和 C（中文用顿号+和）
      if (arr.length === 1) {
        return arr[0];
      }
      const last = arr[arr.length - 1];
      const head = arr.slice(0, -1);
      const fd = finalDelimiter.length > 0 ? finalDelimiter : '和';
      return head.join('、') + fd + last;
    }
    if (finalDelimiter.length > 0) {
      const d = delimiter.length > 0 ? delimiter : ',';
      if (arr.length === 1) {
        return arr[0];
      }
      const last = arr[arr.length - 1];
      return arr.slice(0, -1).join(d) + finalDelimiter + last;
    }
    if (delimiter === 'newline' || delimiter === 'br') {
      return arr.join('<br>');
    }
    if (delimiter === 'list' || delimiter === 'list-newline' || delimiter === 'bullet' ||
      delimiter === '*') {
      const level = SdvArgs.namedOr(args, 'list-level', '**');
      return arr.join('\n' + level);
    }
    return arr.join(delimiter);
  }
}

/** {{#invoke:Hatnote|about/for}}：页顶消歧义提示（expandTemplate hatnote → 斜体盒 wikitext 直出） */
export class HatnoteModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const f = func.toLowerCase();
    if (f !== 'about' && f !== 'for' && f !== 'for2') {
      return '';
    }
    const pos = SdvArgs.positional(args).map((v: string): string => v.trim());
    const pageName = SdvArgs.ctxPageName(ctx);
    const parts: string[] = [];

    if (f === 'about') {
      if (pos.length > 0 && pos[0].length > 0) {
        parts.push('本条目介绍的是' + pos[0]);
      }
      HatnoteModule.pushDescriptionLinks(parts, pos, 1, pageName);
      if (pos.length < 2 && pos.length > 0) {
        parts.push('关于其他用法，请见“\'\'\'' + pageName + '（消歧义）\'\'\'”');
      }
      let out = parts.length > 0 ? parts[0] : '';
      const rest = parts.slice(1);
      if (rest.length > 0) {
        out += (pos.length > 0 && pos[0].length > 0 ? '。 ' : '') + rest.join(' ') + '。';
      } else if (pos.length > 0 && pos[0].length > 0) {
        out += '。';
      }
      return HatnoteModule.hatnoteBox(out);
    }

    // for / for2
    const r = SdvArgs.named(args, 'R');
    if (r !== null && r.length > 0) {
      parts.push(r);
    }
    HatnoteModule.pushDescriptionLinks(parts, pos, 0, pageName);
    if (pos.length === 0) {
      parts.push('关于其他用法，请见');
      parts.push(HatnoteModule.formatLink(pageName + '（消歧义）'));
    }
    let out = parts.length > 0 ? parts[0] : '';
    const rest = parts.slice(1);
    if (rest.length > 0) {
      out += ((r !== null && r.length > 0) ? ' ' : '') + rest.join(' ') + '。';
    }
    return HatnoteModule.hatnoteBox(out);
  }

  private static pushDescriptionLinks(parts: string[], pos: string[], startIndex: number,
    pageName: string): void {
    let state = '';
    for (let i = startIndex; i < pos.length; i++) {
      const v = pos[i];
      if (v.length === 0) {
        continue;
      }
      if (state === 'link') {
        parts.push(HatnoteModule.formatLink(v));
        state = 'end';
      } else if (v === '和' || v === '或' || v === '、') {
        parts.push(v);
      } else {
        if (state === 'end') {
          parts.push('；');
        }
        parts.push('关于' + v + '，请见');
        state = 'link';
      }
    }
    if (state === 'link') {
      parts.push(HatnoteModule.formatLink(pageName + '（消歧义）'));
    }
  }

  private static formatLink(text: string): string {
    if (text.indexOf('[[') >= 0 && text.indexOf(']]') >= 0) {
      return '“\'\'\'' + text + '\'\'\'”';
    }
    return '“\'\'\'[[' + text + ']]\'\'\'”';
  }

  /** Template:Hatnote 的近似：斜体提示行（原站为页顶灰底斜体盒） */
  private static hatnoteBox(content: string): string {
    return '<div style="font-style:italic;">' + content + '</div>';
  }
}

const QUALITY_MAP: Record<string, string> = {
  '4': 'Iridium Quality Icon.png',
  'iridium': 'Iridium Quality Icon.png',
  '2': 'Gold Quality Icon.png',
  'gold': 'Gold Quality Icon.png',
  '1': 'Silver Quality Icon.png',
  'silver': 'Silver Quality Icon.png',
};

/** {{#invoke:Overlayimg|main}}：底图+品质星角标叠加。
 *  离线近似：品质星以小尺寸内联在底图后（原站为右下角绝对定位叠加） */
export class OverlayimgModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const f = func.toLowerCase();
    if (f !== 'main') {
      return '';
    }
    const pos = SdvArgs.positional(args);
    let imgName = (pos.length > 0 && pos[0].length > 0 ? pos[0] : 'Blank icon').replace(/\.png$/i, '');
    const width = parseFloat(SdvArgs.namedOr(args, 'width', '24')) || 24;
    const type = SdvArgs.namedOr(args, 'type', '').toLowerCase();
    const quality = SdvArgs.namedOr(args, 'quality', '0').toLowerCase();

    let out = '[[File:' + imgName + '.png|' + width + 'px|link=]]';
    const star = QUALITY_MAP[quality];
    if (star !== undefined) {
      out += '[[File:' + star + '|' + Math.max(10, Math.round(width / 2)) + 'px|link=]]';
    } else if (type.length > 0 && !ctx.pageTitle.startsWith('Template:')) {
      out += '[[File:' + SdvArgs.namedOr(args, 'type', '') + ' Overlay.png|' +
        Math.max(10, Math.round(width / 2)) + 'px|link=]]';
    }
    return out;
  }
}
