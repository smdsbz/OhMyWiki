import { TemplateContext } from '../../template/TemplateEngine';
import { SdvArgs } from './SdvArgs';

/** {{#invoke:Map|main|...}}：静态位置地图（谷/岛底图 + 像素标记点）。
 *  输出 @@WIKIMAP 协议行（WikitextParser.parseMapLine 消费，标记为百分比坐标） */
export class MapModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    if (func.toLowerCase() !== 'main') {
      return '';
    }
    const island = SdvArgs.namedOr(args, 'island', '');
    const main = SdvArgs.namedOr(args, 'main', 'true');
    const pos = SdvArgs.positional(args);
    const width = (pos.length > 2 && parseFloat(pos[2]) > 0) ? parseFloat(pos[2]) : 400;
    const height = Math.floor(width / 400 * 244 + 0.5);

    let bgImage = '';
    let prefix = 'loc';
    if (island === 'true') {
      bgImage = 'Ginger Island Map.png';
      prefix = 'islandloc';
    } else if (island === 'small') {
      bgImage = 'Map with Island.png';
    } else if (main !== 'false') {
      bgImage = 'Map.png';
    } else {
      return '';
    }

    const pts: string[] = [];
    const addPoint = (xStr: string | null, yStr: string | null): void => {
      if (xStr === null || yStr === null) {
        return;
      }
      const x = parseFloat(xStr);
      const y = parseFloat(yStr);
      if (isNaN(x) || isNaN(y)) {
        return;
      }
      // px → 底图百分比（坐标按 400px 宽度设计）
      const leftPct = Math.round(x / width * 10000) / 100;
      const topPct = Math.round(y / height * 10000) / 100;
      pts.push(leftPct.toFixed(2) + ',' + topPct.toFixed(2));
    };
    if (island === 'true') {
      addPoint(SdvArgs.named(args, prefix + '1x'), SdvArgs.named(args, prefix + '1y'));
    } else {
      addPoint(pos.length > 0 ? pos[0] : null, pos.length > 1 ? pos[1] : null);
    }
    for (let i = 2; i <= 4; i++) {
      addPoint(SdvArgs.named(args, prefix + i + 'x'), SdvArgs.named(args, prefix + i + 'y'));
    }
    if (pts.length === 0) {
      return '';
    }
    return '@@WIKIMAP|' + bgImage + '|位置|' + width + '|' + height + '|' + pts.join(';') + '@@';
  }
}

/** Tabs 标签页对（标题+内容） */
interface TabPair {
  title: string;
  content: string;
}

/** {{#invoke:Tabs|tabs/tabs2}}：交互标签页降级为顺序面板（{{#Widget:}} 已被引擎吞掉） */
export class TabsModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const f = func.toLowerCase();
    if (f !== 'tabs' && f !== 'tabs2') {
      return '';
    }
    const tabs: TabPair[] = [];
    if (f === 'tabs2') {
      const pos = SdvArgs.positional(args);
      for (let i = 0; i + 1 < pos.length; i += 2) {
        if (pos[i].trim().length === 0) {
          break;
        }
        tabs.push({ title: pos[i].trim(), content: (pos[i + 1] ?? '').trim() });
      }
    } else {
      for (let i = 1; i < 50; i++) {
        const t = SdvArgs.named(args, 'title' + i);
        if (t === null || t.trim().length === 0) {
          break;
        }
        const c = SdvArgs.named(args, 'content' + i);
        tabs.push({ title: t.trim(), content: c !== null ? c.trim() : '' });
      }
    }
    if (tabs.length === 0) {
      return '<div>错误：未提供任何有效的标签页数据。</div>';
    }
    const parts: string[] = [];
    for (const t of tabs) {
      parts.push('\'\'\'' + t.title + '\'\'\'');
      if (t.content.length > 0) {
        parts.push(t.content);
      }
    }
    return parts.join('\n\n');
  }
}
