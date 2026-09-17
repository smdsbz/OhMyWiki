import { Logger } from '../../../common/Logger';
import { TemplateContext, TemplateEngine } from '../../template/TemplateEngine';
import { JsonDataReader } from '../../module/JsonDataReader';

const TAG = 'SalvageModule';

/** Gmk/salvage 条目（打捞点放置坐标） */
interface GmkSalvageJson {
  Name: string;
  PosX?: number;
  PosZ?: number;
  areas?: string[];
}

/** Mapinfo 条目（底图世界坐标范围） */
interface MapinfoJson {
  Name: string;
  mapName?: string;
  menuGroup?: string;
  Width?: number;
  Height?: number;
  LowerX?: number;
  LowerZ?: number;
  UpperX?: number;
  UpperZ?: number;
}

/**
 * Salvage 模块（Module:Salvage 的 ArkTS 移植）。
 * - popTable：打捞点页的气瓶概率表（{{salvagePop|gmkId}}），并捕获
 *   地域/SalvagePop/SalvageEnemyPop 语义属性（对应 mw.smw.set）——
 *   物品页「获得方式」的 [[打捞点:+]][[SalvagePop::物品:x]] 反查依赖这些属性，
 *   属性提取（SmwQueryEngine.extractProps）会带着 capture 上下文重入本模块。
 * - pointMap：打捞点页顶部 xb2map-salvage 交互地图占位 div 的静态打点地图。
 */
export class SalvageModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const f = func.toLowerCase();
    try {
      if (f === 'poptable') {
        return await SalvageModule.popTable(args.length > 0 ? args[0].trim() : '', ctx);
      }
      if (f === 'pointmap') {
        return await SalvageModule.pointMap(args.length > 0 ? args[0].trim() : '', ctx);
      }
      return '';
    } catch (e) {
      Logger.warn(TAG, 'invoke failed: salvage.' + func + ' ' + JSON.stringify(e));
      return '';
    }
  }

  private static str(v: Object | undefined): string {
    return v === undefined || v === null ? '' : String(v);
  }

  private static num(v: Object | undefined): number {
    const n = parseFloat(SalvageModule.str(v));
    return isNaN(n) ? 0 : n;
  }

  private static capture(ctx: TemplateContext, prop: string, value: string): void {
    if (ctx.capture !== undefined && ctx.capture !== null && value.length > 0) {
      ctx.capture(prop, value);
    }
  }

  /** Gmk/salvage 里查打捞点条目 */
  private static async findGmk(ctx: TemplateContext, gmkId: string): Promise<GmkSalvageJson | null> {
    const list = await JsonDataReader.read(ctx, 'Gmk/salvage') as GmkSalvageJson[] | null;
    if (list === null) {
      return null;
    }
    for (const g of list) {
      if (g.Name === gmkId) {
        return g;
      }
    }
    return null;
  }

  /**
   * 打捞点概率表（Module:Salvage.popTable）。
   * 表格输出与站点 Lua 逐行对齐（含「收藏道具表仅在有宝藏表时输出」等原版怪癖）。
   */
  private static async popTable(gmkId: string, ctx: TemplateContext): Promise<string> {
    if (gmkId.length === 0) {
      return '';
    }
    // 地域属性：getMapinfo —— Gmk/salvage → areas[0] → Mapinfo.mapName
    const gmk = await SalvageModule.findGmk(ctx, gmkId);
    const area = gmk !== null && gmk.areas !== undefined && gmk.areas.length > 0 ? gmk.areas[0] : '';
    if (area.length > 0) {
      const info = await JsonDataReader.read(ctx, 'Mapinfo/' + area) as MapinfoJson | null;
      if (info !== null && info.mapName !== undefined) {
        SalvageModule.capture(ctx, '地域', info.mapName);
      }
    }
    const data = await JsonDataReader.read(ctx, 'SalvagePoint/' + gmkId) as Record<string, Object> | null;
    if (data === null) {
      return '';
    }
    const btn = (i: number): string => {
      const b = data['BtnChallenge' + i];
      return b === undefined ? '' : SalvageModule.str((b as Record<string, Object>)['BtnType1']);
    };
    const b1 = btn(0);
    let out = '按键：' + (b1 === 'Random' ? '随机' : b1 + btn(1) + btn(2));
    const sections: string[][] = [
      ['普通气瓶', 'SalvageTable1'], ['白银气瓶', 'SalvageTable2'],
      ['黄金气瓶', 'SalvageTable3'], ['极品气瓶', 'SalvageTable4'], ['增幅气瓶', 'SalvageTable5'],
    ];
    for (const sec of sections) {
      const st = data[sec[1]];
      // SalvageTable5 在无增幅气瓶的数据里是空字符串 ""（原版 data["SalvageTable5"] ~= ""）
      if (st === undefined || st === null || typeof st === 'string') {
        continue;
      }
      out += '\n\n=== ' + sec[0] + ' ===\n\n' + SalvageModule.displayTable(st as Record<string, Object>, ctx);
    }
    return out;
  }

  /** 单个气瓶概率表（Module:Salvage 的 parseSalvageTable + DisplayTable 合并） */
  private static displayTable(st: Record<string, Object>, ctx: TemplateContext): string {
    // 收藏道具（ColleTable1-3）
    const colleRows: string[][] = [];
    for (let i = 1; i <= 3; i++) {
      const raw = st['ColleTable' + i];
      const pct = SalvageModule.num(st['ColleTablePercent' + i]) / 100;
      if (raw === undefined || pct <= 0) {
        continue;
      }
      const c = raw as Record<string, Object>;
      const rows = SalvageModule.itemRows(c, ctx, 'SalvagePop');
      if (rows.staticPop.length === 0 && rows.randomPop.length === 0) {
        continue;
      }
      colleRows.push([String(pct), rows.staticPop.join('<br>'), rows.randNum, rows.randomPop.join('<br>')]);
    }
    // 宝藏（TresureTable1-3；行有无道具都输出）
    const treasureRows: string[][] = [];
    for (let i = 1; i <= 3; i++) {
      const raw = st['TresureTable' + i];
      const pct = SalvageModule.num(st['TresureTablePercent' + i]) / 100;
      if (raw === undefined || pct <= 0) {
        continue;
      }
      const t = raw as Record<string, Object>;
      const rows = SalvageModule.itemRows(t, ctx, 'SalvagePop');
      let gold = '0';
      if (SalvageModule.num(t['goldPopMin']) > 0 && SalvageModule.num(t['goldMax']) > 0) {
        gold = SalvageModule.num(t['goldMin']) + ' ~ ' + SalvageModule.num(t['goldMax']);
      }
      const rsc = SalvageModule.str(t['RSC_ID']);
      const img = rsc === '4' ? '[[文件:Mnu064 image 1.png|136px]]' :
        rsc === '5' ? '[[文件:Mnu064 image 2.png|136px]]' :
          rsc === '6' ? '[[文件:Mnu064 image 4.png|136px]]' : '';
      treasureRows.push([String(pct), img, gold, rows.staticPop.join('<br>'), rows.randNum,
        rows.randomPop.join('<br>')]);
    }
    // 敌人（EnemyPopTable1-3）
    const enemyRows: string[][] = [];
    for (let i = 1; i <= 3; i++) {
      const raw = st['EnemyPopTable' + i];
      const pct = SalvageModule.num(st['EnemyPopTablePercent' + i]) / 100;
      if (raw === undefined || pct <= 0) {
        continue;
      }
      const e = raw as Record<string, Object>;
      const pop: string[] = [];
      for (let k = 1; k <= 4; k++) {
        const name = SalvageModule.str(e['ene' + k + 'ID']);
        if (name.length === 0) {
          continue;
        }
        const per = SalvageModule.num(e['ene' + k + 'Per']);
        if (per > 0) {
          pop.push('[[敌人:' + name + '|' + name + ']] ' + per + '%');
          SalvageModule.capture(ctx, 'SalvageEnemyPop', '敌人:' + name);
        }
      }
      if (pop.length > 0) {
        enemyRows.push([String(pct), pop.join('<br>')]);
      }
    }
    const hit = SalvageModule.num(st['TresureBoxHit']) / 100;
    const enemyHit = SalvageModule.num(st['EnemyPopHit']) / 100;
    // 拼表顺序与原站一致：收藏 → 敌人 → 宝藏；收藏表仅在宝藏表非空时输出
    let collectionTable = '';
    if (treasureRows.length > 0 && colleRows.length > 0) {
      const sb: string[] = ['{| class="wikitable"', '|+', '! colspan="4" |收藏道具', '|+',
        '!概率', '!必出道具', '! colspan="2" |额外道具'];
      for (const r of colleRows) {
        sb.push('|-\n|' + r[0] + '%\n|' + r[1] + '\n|' + r[2] + '\n|' + r[3]);
      }
      sb.push('|}');
      collectionTable = sb.join('\n') + '\n';
    }
    let enemyTable = '';
    if (enemyRows.length > 0 && enemyHit > 0) {
      const sb: string[] = ['{| class="wikitable"', '|+', '! colspan="2" |敌人 基础出现率：' + enemyHit + '%',
        '|+', '!概率', '!名称'];
      for (const r of enemyRows) {
        sb.push('|-\n|' + r[0] + '%\n|' + r[1]);
      }
      sb.push('|}');
      enemyTable = sb.join('\n') + '\n';
    }
    let treasureTable = '';
    if (treasureRows.length > 0) {
      const sb: string[] = ['{| class="wikitable"', '|+', '! colspan="6" |宝藏 基础出现率：' + hit + '%',
        '|+', '!概率', '!宝箱类型', '!金币', '!必出道具', '! colspan="2" |额外道具'];
      for (const r of treasureRows) {
        sb.push('|-\n|' + r[0] + '%\n|' + r[1] + '\n|' + r[2] + '\n|' + r[3] + '\n|' + r[4] + '\n|' + r[5]);
      }
      sb.push('|}');
      treasureTable = sb.join('\n') + '\n';
    }
    return '<div style="display:flex;flex-wrap:wrap;">\n' + collectionTable + enemyTable + treasureTable + '</div>\n';
  }

  /** itm1-8 行：必出道具（Num>0）/ 额外道具（Per>0），并按 prop 写入 SalvagePop 类属性 */
  private static itemRows(t: Record<string, Object>, ctx: TemplateContext, prop: string): ItemRows {
    const staticPop: string[] = [];
    const randomPop: string[] = [];
    for (let k = 1; k <= 8; k++) {
      const name = SalvageModule.str(t['itm' + k + 'ID']);
      if (name.length === 0) {
        continue;
      }
      const link = '[[物品:' + name + '|' + name + ']]';
      if (SalvageModule.num(t['itm' + k + 'Num']) > 0) {
        staticPop.push(link);
        SalvageModule.capture(ctx, prop, '物品:' + name);
      }
      const per = SalvageModule.num(t['itm' + k + 'Per']);
      if (per > 0) {
        randomPop.push(link + ' ' + per + '%');
        SalvageModule.capture(ctx, prop, '物品:' + name);
      }
    }
    const min = SalvageModule.num(t['randitmPopMin']);
    const max = SalvageModule.num(t['randitmPopMax']);
    return {
      staticPop: staticPop,
      randomPop: randomPop,
      randNum: min === max ? String(min) : min + ' ~ ' + max,
    };
  }

  /** 打捞点定位地图：惰性登记为延迟调用（Reader 阶段 2 建图，不阻塞首帧） */
  private static async pointMap(gmkId: string, ctx: TemplateContext): Promise<string> {
    if (gmkId.length === 0) {
      return '';
    }
    const mark = TemplateEngine.registerLazyInvoke(ctx, 'salvage', 'pointMap', [gmkId]);
    if (mark.length > 0) {
      return mark;
    }
    return await SalvageModule.buildPointMap(gmkId, ctx);
  }

  /** 建图：放置坐标 → Mapinfo 世界范围 → 百分比标记（换算同 EnemyModule.buildMapSection） */
  private static async buildPointMap(gmkId: string, ctx: TemplateContext): Promise<string> {
    try {
      const gmk = await SalvageModule.findGmk(ctx, gmkId);
      if (gmk === null || gmk.PosX === undefined || gmk.PosZ === undefined ||
        gmk.areas === undefined || gmk.areas.length === 0) {
        return '';
      }
      const area = gmk.areas[0];
      const info = await JsonDataReader.read(ctx, 'Mapinfo/' + area) as MapinfoJson | null;
      if (info === null || info.LowerX === undefined || info.UpperX === undefined ||
        info.LowerZ === undefined || info.UpperZ === undefined ||
        info.Width === undefined || info.Height === undefined || info.Height <= 0) {
        return '';
      }
      const spanX = info.UpperX - info.LowerX;
      const spanZ = info.UpperZ - info.LowerZ;
      if (spanX <= 0 || spanZ <= 0) {
        return '';
      }
      const leftPct = ((gmk.PosX as number) - info.LowerX) / spanX * 100;
      const topPct = ((gmk.PosZ as number) - info.LowerZ) / spanZ * 100;
      if (leftPct < -5 || leftPct > 105 || topPct < -5 || topPct > 105) {
        return '';
      }
      const mark = Math.max(0, Math.min(100, leftPct)).toFixed(1) + ',' +
        Math.max(0, Math.min(100, topPct)).toFixed(1);
      const title = (info.mapName ?? '') + (info.menuGroup !== undefined && info.menuGroup.length > 0 &&
        info.menuGroup !== info.mapName ? '・' + info.menuGroup : '');
      return '@@WIKIMAP|' + (area.charAt(0).toUpperCase() + area.substring(1) + '_map_0.png') +
        '|' + title + '|' + info.Width + '|' + info.Height + '|' + mark + '@@';
    } catch (e) {
      Logger.warn(TAG, 'buildPointMap error: ' + JSON.stringify(e));
      return '';
    }
  }
}

interface ItemRows {
  staticPop: string[];
  randomPop: string[];
  randNum: string;
}
