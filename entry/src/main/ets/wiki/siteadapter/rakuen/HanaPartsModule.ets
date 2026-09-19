import { Logger } from '../../../common/Logger';
import { TemplateContext } from '../../template/TemplateEngine';

const TAG = 'HanaPartsModule';

/**
 * 模块:HanaParts 的 ArkTS 移植（原 Lua 见 rakuen-database pages/模块/HanaParts.wiki）。
 * 花的零件类模板（武技卡/技能RAM/必杀技强化RAM/战斗类别CPU/属性核心）的表格片段拼接，
 * 输出被拼回外层 wikitable 语法中（#invoke 父框架实参继承 JS/JK/JD 等命名参数）。
 */
export class HanaPartsModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const f = func.toLowerCase();
    try {
      if (f === 'installabletable') {
        return HanaPartsModule.installableTable(args);
      }
      if (f === 'statrev') {
        return HanaPartsModule.statRev(args);
      }
      if (f === 'changemodel') {
        return HanaPartsModule.changeModel(args);
      }
      if (f === 'manufacture') {
        return HanaPartsModule.manufacture(args, ctx);
      }
      return '';
    } catch (e) {
      Logger.warn(TAG, 'invoke failed: hanaparts.' + func + ' ' + JSON.stringify(e));
      return '';
    }
  }

  /** 命名实参取值（#invoke 继承的父模板实参形如 "k=v"） */
  private static named(args: string[], key: string): string {
    for (const a of args) {
      const eq = a.indexOf('=');
      if (eq > 0 && a.substring(0, eq).trim() === key) {
        return a.substring(eq + 1).trim();
      }
    }
    return '';
  }

  private static mark(v: string): string {
    if (v === 'TRUE') {
      return '✔';
    }
    if (v === 'FALSE') {
      return '✘';
    }
    return '';
  }

  /** 可装备行（花JS/花JK/花JD）：表头片段 + 三格居中值（拼入外层 wikitable） */
  private static installableTable(args: string[]): string {
    const js = HanaPartsModule.mark(HanaPartsModule.named(args, 'JS'));
    const jk = HanaPartsModule.mark(HanaPartsModule.named(args, 'JK'));
    const jd = HanaPartsModule.mark(HanaPartsModule.named(args, 'JD'));
    return '! [[异刃:花JS|JS]] !! [[异刃:花JK|JK]] !! [[异刃:花JD|JD]]\n' +
      '|-\n' +
      '|style="text-align:center;"| ' + js + '\n' +
      '|style="text-align:center;"| ' + jk + '\n' +
      '|style="text-align:center;"| ' + jd + '\n';
  }

  /** 属性修正（取首个非 0 项，如 最大HP修正10%） */
  private static statRev(args: string[]): string {
    const statList: string[] = ['最大HP修正', '力量修正', '以太力修正', '灵巧修正', '敏捷修正', '运气修正'];
    for (const key of statList) {
      const v = HanaPartsModule.named(args, key);
      if (v.length > 0 && v !== '0') {
        return '|colspan="3"| ' + key + v + '%\n';
      }
    }
    return '';
  }

  /** 外观变更行（可选） */
  private static changeModel(args: string[]): string {
    const v = HanaPartsModule.named(args, '外观变更');
    if (v.length === 0) {
      return '';
    }
    return '|-\n' +
      '| [[外观变更道具|角色外观变更]]\n' +
      '|colspan="3"| [[' + v + ']]\n';
  }

  /** 零件制作表（技术书 + 所需以太结晶）；无技术书时不输出（与 Lua 一致） */
  private static manufacture(args: string[], ctx: TemplateContext): string {
    const book = HanaPartsModule.named(args, '技术书');
    if (book.length === 0) {
      return '';
    }
    let title: string;
    if (book === '无') {
      title = '无需技术书';
    } else {
      // mw.title.new(技术书, "物品").fullText：物品命名空间全称
      let target = '物品:' + book;
      if (ctx.index !== null && !ctx.index.pageExists(target)) {
        target = book;
      }
      title = '[[' + target + '|' + book + ']]';
    }
    return '{| class="wikitable"\n' +
      '|-\n' +
      '! 零件制作 !! 以太结晶\n' +
      '|-\n' +
      '| ' + title + ' || ' + HanaPartsModule.named(args, '所需以太结晶') + '\n' +
      '|}';
  }
}
