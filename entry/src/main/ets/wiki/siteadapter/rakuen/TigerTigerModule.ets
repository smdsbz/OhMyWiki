import { Logger } from '../../../common/Logger';
import { TemplateContext } from '../../template/TemplateEngine';

const TAG = 'TigerTigerModule';

interface TTDrop {
  name: string;
  rate: string;
}

/**
 * 模块:TigerTiger 的 ArkTS 移植（原 Lua 见 rakuen-database pages/模块/TigerTiger.wiki）。
 * TIGER! TIGER! 各 STAGE 页宝箱掉落表：按概率降序，零件优先链 花的零件: → 物品:；
 * 捕获 TT宝箱（物品/零件页获得方式的 [[~TIGER! TIGER!/*]] 查询依赖）与逐宝箱出率属性。
 */
export class TigerTigerModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const f = func.toLowerCase();
    try {
      if (f === 'tboxdrop') {
        return TigerTigerModule.tboxDrop(args, ctx);
      }
      return '';
    } catch (e) {
      Logger.warn(TAG, 'invoke failed: tigertiger.' + func + ' ' + JSON.stringify(e));
      return '';
    }
  }

  private static tboxDrop(args: string[], ctx: TemplateContext): string {
    const box = TigerTigerModule.named(args, '宝箱');
    const drops: TTDrop[] = [];
    for (const a of args) {
      const eq = a.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const k = a.substring(0, eq).trim();
      if (k === '宝箱') {
        continue;
      }
      drops.push({ name: k, rate: a.substring(eq + 1).trim() });
    }
    drops.sort((x: TTDrop, y: TTDrop): number => parseFloat(y.rate) - parseFloat(x.rate));

    let out = '{| class="wikitable sortable" style="width: 95%"\n|-\n! 零件名称 !! 概率\n';
    for (const d of drops) {
      let title = d.name;
      let fullText = '';
      if (ctx.index !== null && ctx.index.pageExists('花的零件:' + d.name)) {
        fullText = '花的零件:' + d.name;
        title = '[[' + fullText + '|' + d.name + ']]';
      } else if (ctx.index !== null && ctx.index.pageExists('物品:' + d.name)) {
        fullText = '物品:' + d.name;
        title = '[[' + fullText + '|' + d.name + ']]';
      }
      if (fullText.length > 0 && ctx.capture !== undefined && ctx.capture !== null) {
        ctx.capture('TT宝箱', fullText);
        ctx.capture(d.name + box + '宝箱出率', d.rate + '%');
      }
      out += '|-\n| ' + title + ' || ' + d.rate + '%\n';
    }
    out += '|}';
    return out;
  }

  private static named(args: string[], key: string): string {
    for (const a of args) {
      const eq = a.indexOf('=');
      if (eq > 0 && a.substring(0, eq).trim() === key) {
        return a.substring(eq + 1).trim();
      }
    }
    return '';
  }
}
