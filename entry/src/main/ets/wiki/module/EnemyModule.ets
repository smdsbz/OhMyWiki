import { Logger } from '../../common/Logger';
import { TemplateContext, PLACEHOLDER_MARK } from '../template/TemplateEngine';
import { JsonDataReader } from './JsonDataReader';

const TAG = 'EnemyModule';

/** CHR_EnArrange 结构 */
interface EnArrangeJson {
  id: number;
  ParamID: number;
  Name: string;
  Lv: number;
  LvRand: number;
  ExpRev: number;
  GoldRev: number;
  WPRev: number;
  SPRev: number;
  Scale: number;
  EnhanceID1: number;
  EnhanceID2: number;
  EnhanceID3: number;
  ParamRev: number;
  ZoneID: number;
  IgnoreLevPow: boolean;
}

/** CHR_EnParam 结构 */
interface EnParamJson {
  id: number;
  ResourceID: number;
  HpMaxRev: number;
  StrengthRev: number;
  PowEtherRev: number;
  DexRev: number;
  AgilityRev: number;
  LuckRev: number;
  RstPower: number;
  RstEther: number;
  Atr: string;
  CriticalRate: number;
  GuardRate: number;
  IvdFiCombo: number;
  RstFiCombo: number;
}

/** CHR_EnParamTable 结构 */
interface EnParamTableJson {
  id: number;
  HpMaxBase: number;
  StrengthBase: number;
  PowEtherBase: number;
  DexBase: number;
  AgilityBase: number;
  LuckBase: number;
}

/** RSC_En 结构 */
interface RscEnJson {
  id: number;
  TypeFamily: string;
}

/** BTL_Grow 结构 */
interface GrowJson {
  id: number;
  EnemyExp: number;
  EnemyGold: number;
  EnemyWP: number;
  EnemySP: number;
}

/** BTL_Enhance 结构 */
interface EnhanceJson {
  id: number;
  CaptionText: string;
}

/** EnemyIdMap 值元素 */
interface EnemyIdEntry {
  id: number;
  title?: string;
}

/**
 * Enemy 模块（Module:Enemy 的 ArkTS 移植 · 基础统计部分）。
 * 渲染敌人页的核心数据表（基本信息/六维/抗性/反应抗性/被动能力/击杀奖励）。
 * 武技/异刃必杀/掉落明细等依赖更多 JSON + SMW 的部分暂以占位提示。
 */
export class EnemyModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const f = func.toLowerCase();
    if (f === 'main') {
      return await EnemyModule.renderMain(ctx);
    }
    return '';
  }

  private static async renderMain(ctx: TemplateContext): Promise<string> {
    let name = ctx.pageTitle;
    const ci = name.indexOf(':');
    if (ci >= 0) {
      name = name.substring(ci + 1);
    }
    name = name.trim();
    if (name.length === 0) {
      return '';
    }
    const id = await EnemyModule.lookupId(ctx, name);
    if (id <= 0) {
      return '{{#omw-note:未找到该敌人的数据}}';
    }
    try {
      const arrange = await JsonDataReader.read(ctx, 'CHR_EnArrange/' + id) as EnArrangeJson | null;
      if (arrange === null) {
        return '';
      }
      const categoryMap = await JsonDataReader.read(ctx, 'EnemyCategory') as Record<string, string>;
      const category = categoryMap !== null && categoryMap[String(id)] !== undefined ? categoryMap[String(id)] : '普通敌人';

      const param = await JsonDataReader.read(ctx, 'CHR_EnParam/' + arrange.ParamID) as EnParamJson | null;
      const paramBase = await JsonDataReader.read(ctx, 'CHR_EnParamTable/' + arrange.Lv) as EnParamTableJson | null;
      const rsc = param !== null ? await JsonDataReader.read(ctx, 'RSC_En/' + param.ResourceID) as RscEnJson | null : null;
      const grow = await JsonDataReader.read(ctx, 'BTL_Grow/' + arrange.Lv) as GrowJson | null;

      const enh1 = await EnemyModule.loadEnhance(ctx, arrange.EnhanceID1);
      const enh2 = await EnemyModule.loadEnhance(ctx, arrange.EnhanceID2);
      const enh3 = await EnemyModule.loadEnhance(ctx, arrange.EnhanceID3);

      const hp = Math.floor(((paramBase?.HpMaxBase ?? 0) * (param?.HpMaxRev ?? 0)) / 1000);
      const str = Math.floor(((paramBase?.StrengthBase ?? 0) * (param?.StrengthRev ?? 0)) / 1000);
      const ether = Math.floor(((paramBase?.PowEtherBase ?? 0) * (param?.PowEtherRev ?? 0)) / 1000);
      const dex = Math.floor(((paramBase?.DexBase ?? 0) * (param?.DexRev ?? 0)) / 1000);
      const agi = Math.floor(((paramBase?.AgilityBase ?? 0) * (param?.AgilityRev ?? 0)) / 1000);
      const luck = Math.floor(((paramBase?.LuckBase ?? 0) * (param?.LuckRev ?? 0)) / 1000);

      const exp = Math.floor((grow?.EnemyExp ?? 0) * (arrange.ExpRev ?? 100) / 100);
      const gold = Math.floor((grow?.EnemyGold ?? 0) * (arrange.GoldRev ?? 100) / 100);
      const wp = Math.floor((grow?.EnemyWP ?? 0) * (arrange.WPRev ?? 100) / 100);
      const sp = Math.floor((grow?.EnemySP ?? 0) * (arrange.SPRev ?? 100) / 100);

      const reactions = EnemyModule.calcReactions(param !== null ? param.IvdFiCombo : 0, param !== null ? param.RstFiCombo : 0);

      // 捕获 SMW 语义属性（对应 Module:Enemy 的 mw.smw.set），供 #ask 查询过滤/排序
      await EnemyModule.captureSmw(ctx, arrange, category, param, rsc, hp, str, ether, dex, agi, luck,
        exp, gold, wp, sp, reactions);

      const sb: string[] = [];
      // 基本信息（转置）
      const lvFloat = (arrange.LvRand ?? 0) > 0 ? ' (' + arrange.LvRand + ')' : '';
      sb.push(EnemyModule.transpose([
        ['等级', String(arrange.Lv) + lvFloat],
        ['属性', param?.Atr ?? ''],
        ['分类', category],
        ['种族', rsc?.TypeFamily ?? ''],
        ['体型', String(arrange.Scale) + '%'],
      ]));
      // 六维
      sb.push(EnemyModule.rowTable(['HP', '力量', '以太力', '敏捷', '灵巧', '运气'],
        [String(hp), String(str), String(ether), String(agi), String(dex), String(luck)]));
      // 抗性
      sb.push(EnemyModule.rowTable(['物理抗性', '以太抗性', '暴击率', '格挡率'],
        [String(param?.RstPower ?? 0) + '%', String(param?.RstEther ?? 0) + '%',
          String(param?.CriticalRate ?? 0) + '%', String(param?.GuardRate ?? 0) + '%']));
      // 反应动作抗性
      sb.push(EnemyModule.rowTable(['吹飞', '击退', '破防', '倒地', '浮空', '猛击'],
        [reactions[0], reactions[1], reactions[2], reactions[3], reactions[4], reactions[5]]));
      // 被动能力
      const enhList: string[] = [];
      if (enh1.length > 0) {
        enhList.push(enh1);
      }
      if (enh2.length > 0) {
        enhList.push(enh2);
      }
      if (enh3.length > 0) {
        enhList.push(enh3);
      }
      if (enhList.length > 0) {
        sb.push(EnemyModule.singleCellTable('被动能力', enhList.join('<br>')));
      }
      // 击杀奖励
      if (exp > 0 || gold > 0 || wp > 0 || sp > 0) {
        sb.push(EnemyModule.rowTable(['EXP', 'Gold', 'WP', 'SP'],
          [String(exp), String(gold), String(wp), String(sp)]));
      }
      sb.push(PLACEHOLDER_MARK + '武技/掉落明细由 Lua+SMW 生成，离线版暂不渲染' + '\u0000');
      return sb.join('\n');
    } catch (e) {
      Logger.warn(TAG, 'renderMain error: ' + JSON.stringify(e));
      return '';
    }
  }

  /**
   * 捕获 SMW 语义属性（对应 Module:Enemy 的 mw.smw.set），供 #ask 查询过滤/排序。
   * 仅在 ctx.capture 存在时生效（SmwQueryEngine 提取属性时传入）。
   */
  private static async captureSmw(ctx: TemplateContext, arrange: EnArrangeJson, category: string,
    param: EnParamJson | null, rsc: RscEnJson | null, hp: number, str: number, ether: number,
    dex: number, agi: number, luck: number, exp: number, gold: number, wp: number, sp: number,
    reactions: string[]): Promise<void> {
    const capt = ctx.capture;
    if (capt === undefined || capt === null) {
      return;
    }
    const set = (prop: string, value: string): void => {
      if (value.length > 0) {
        capt(prop, value);
      }
    };
    set('ZoneID', String(arrange.ZoneID));
    set('敌人分类', category);
    if (arrange.ZoneID > 0) {
      const fl = await JsonDataReader.read(ctx, 'FLD_maplist/' + arrange.ZoneID) as Record<string, Object> | null;
      if (fl !== null && fl.nameID !== undefined) {
        set('地域', String(fl.nameID));
      }
    }
    set('等级', String(arrange.Lv));
    set('等级浮动', String(arrange.LvRand ?? 0));
    set('无视等级差补正', arrange.IgnoreLevPow ? '✔' : '✘');
    set('种族', rsc?.TypeFamily ?? '');
    set('EXP', String(exp));
    set('Gold', String(gold));
    set('WP', String(wp));
    set('SP', String(sp));
    set('HP', String(hp));
    set('力量', String(str));
    set('以太力', String(ether));
    set('灵巧', String(dex));
    set('敏捷', String(agi));
    set('运气', String(luck));
    set('物理抗性', String(param?.RstPower ?? 0) + '%');
    set('以太抗性', String(param?.RstEther ?? 0) + '%');
    set('暴击率', String(param?.CriticalRate ?? 0) + '%');
    set('格挡率', String(param?.GuardRate ?? 0) + '%');
    set('击退', reactions[0]);
    set('吹飞', reactions[1]);
    set('破防', reactions[2]);
    set('倒地', reactions[3]);
    set('浮空', reactions[4]);
    set('猛击', reactions[5]);
  }

  private static async lookupId(ctx: TemplateContext, name: string): Promise<number> {
    const map = await JsonDataReader.read(ctx, 'EnemyIdMap') as Record<string, Object> | null;
    if (map === null) {
      return 0;
    }
    const raw = map[name];
    if (raw === undefined) {
      return 0;
    }
    const arr = raw as Array<Object>;
    if (arr.length === 0) {
      return 0;
    }
    const first = arr[0];
    if (typeof first === 'number') {
      return first as number;
    }
    const entry = first as EnemyIdEntry;
    return entry.id;
  }

  private static async loadEnhance(ctx: TemplateContext, id: number): Promise<string> {
    if (id <= 0) {
      return '';
    }
    const data = await JsonDataReader.read(ctx, 'BTL_Enhance/' + id) as EnhanceJson | null;
    if (data === null) {
      return '';
    }
    return data.CaptionText ?? '';
  }

  private static bitExtract(n: number, field: number): number {
    return (n >> field) & 1;
  }

  private static calcReactions(ivd: number, rst: number): string[] {
    const names = ['击退', '吹飞', '破防', '倒地', '浮空', '猛击'];
    const out: string[] = [];
    for (let i = 0; i < names.length; i++) {
      const I = EnemyModule.bitExtract(ivd, i);
      const R = EnemyModule.bitExtract(rst, i);
      if (I === 1) {
        out.push('无效');
      } else if (R === 1) {
        out.push('40%');
      } else {
        out.push('100%');
      }
    }
    return out;
  }

  /** 生成转置表格（每行：! 标签 | 值） */
  private static transpose(rows: Array<Array<string>>): string {
    const sb: string[] = ['{| class="wikitable"'];
    for (const r of rows) {
      sb.push('|-');
      sb.push('! ' + r[0]);
      sb.push('| ' + r[1]);
    }
    sb.push('|}');
    return sb.join('\n');
  }

  /** 生成单行表格（表头 + 一行数据） */
  private static rowTable(headers: string[], values: string[]): string {
    const sb: string[] = ['{| class="wikitable"', '|-'];
    sb.push('! ' + headers.join(' !! '));
    sb.push('|-');
    sb.push('| ' + values.join(' || '));
    sb.push('|}');
    return sb.join('\n');
  }

  /** 单列表格 */
  private static singleCellTable(label: string, value: string): string {
    const sb: string[] = ['{| class="wikitable"', '|-', '! ' + label, '|-' ];
    // 单元格内容可能含 <br>，保持原样
    sb.push('| ' + value);
    sb.push('|}');
    return sb.join('\n');
  }
}
