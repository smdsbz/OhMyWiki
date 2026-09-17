import { Logger } from '../../../common/Logger';
import { TemplateContext, TemplateEngine } from '../../template/TemplateEngine';
import { JsonDataReader } from '../../module/JsonDataReader';

const TAG = 'TboxModule';

/** Gmk/tbox 条目（宝箱放置坐标） */
interface GmkTboxJson {
  Name: string;
  PosX?: number;
  PosZ?: number;
  areas?: string[];
}

/** FSID 条目（场景技能组合） */
interface FsidJson {
  Name?: string;
  FieldSkillID1?: string;
  FieldSkillLevel1?: number;
  FieldSkillID2?: string;
  FieldSkillLevel2?: number;
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
 * Tbox 模块（Module:Tbox 的 ArkTS 移植）。
 * - popTable：宝箱内容表（金币/物品），并捕获 地域/gold/tboxPop 系语义属性——
 *   地区页「宝箱列表」的 [[宝箱:+]][[地域::X]] 查询与 ?Gold/?TboxPopLinkDisplay
 *   打印输出依赖这些属性（对应 mw.smw.set）。
 * - fsInfo：所需场景技能表，捕获 FieldSkill。
 * - appearCondition：出现条件表。
 * - pointMap：xb2map-tbox 交互地图占位 div 的静态打点地图
 *   （宝箱页单点 / 地区页该地图全部宝箱）。
 */
export class TboxModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const f = func.toLowerCase();
    try {
      if (f === 'poptable') {
        return await TboxModule.popTable(args, ctx);
      }
      if (f === 'fsinfo') {
        return await TboxModule.fsInfo(args, ctx);
      }
      if (f === 'appearcondition') {
        return TboxModule.appearCondition(args);
      }
      if (f === 'pointmap') {
        return await TboxModule.pointMap(args, ctx);
      }
      return '';
    } catch (e) {
      Logger.warn(TAG, 'invoke failed: tbox.' + func + ' ' + JSON.stringify(e));
      return '';
    }
  }

  /** 命名实参取值（#invoke 继承的父模板实参形如 "k=v"；空值按 Lua getArgs 语义视为缺省） */
  private static named(args: string[], key: string): string {
    for (const a of args) {
      const eq = a.indexOf('=');
      if (eq > 0 && a.substring(0, eq).trim() === key) {
        return a.substring(eq + 1).trim();
      }
    }
    return '';
  }

  private static capture(ctx: TemplateContext, prop: string, value: string): void {
    if (ctx.capture !== undefined && ctx.capture !== null && value.length > 0) {
      ctx.capture(prop, value);
    }
  }

  /** 物品页标题：优先 物品: 命名空间，其次 黄金之国物品:，缺省回落 物品: */
  private static itemTitle(ctx: TemplateContext, itemName: string): string {
    if (ctx.index !== null) {
      if (ctx.index.pageExists('物品:' + itemName)) {
        return '物品:' + itemName;
      }
      if (ctx.index.pageExists('黄金之国物品:' + itemName)) {
        return '黄金之国物品:' + itemName;
      }
    }
    return '物品:' + itemName;
  }

  /** 宝箱内容表（Module:Tbox.popTable） */
  private static async popTable(args: string[], ctx: TemplateContext): Promise<string> {
    const name = TboxModule.named(args, 'name');
    if (name.length === 0) {
      return '';
    }
    // 地域属性：Gmk/tbox → areas[0]（原站 lowercased）→ Mapinfo.mapName
    const list = await JsonDataReader.read(ctx, 'Gmk/tbox') as GmkTboxJson[] | null;
    if (list !== null) {
      for (const g of list) {
        if (g.Name === name && g.areas !== undefined && g.areas.length > 0) {
          const info = await JsonDataReader.read(ctx, 'Mapinfo/' + g.areas[0].toLowerCase()) as MapinfoJson | null;
          if (info !== null && info.mapName !== undefined) {
            TboxModule.capture(ctx, '地域', info.mapName);
            const mg = info.menuGroup ?? '';
            TboxModule.capture(ctx, 'zoneDisplay', info.mapName +
              (mg.length > 0 ? '・' + mg : ''));
          }
          break;
        }
      }
    }
    // 金币行（goldMin=0 无金币）
    const goldMin = TboxModule.named(args, 'goldMin');
    const goldMax = TboxModule.named(args, 'goldMax');
    let goldRow = '';
    if (goldMin !== '0' && goldMin.length > 0) {
      const gold = goldMin === goldMax ? goldMin : goldMin + ' ~ ' + goldMax;
      goldRow = '\n|-\n!金币\n| ' + gold + ' G';
      TboxModule.capture(ctx, 'gold', gold);
    }
    // 物品行（itm1-6）+ 语义属性
    const itemParts: string[] = [];
    for (let i = 1; i <= 6; i++) {
      const itemName = TboxModule.named(args, 'itm' + i + 'ID');
      if (itemName.length === 0) {
        continue;
      }
      const num = TboxModule.named(args, 'itm' + i + 'Num');
      const title = TboxModule.itemTitle(ctx, itemName);
      const numString = num === '1' ? '' : ' ×' + num;
      itemParts.push('[[' + title + '|' + itemName + ']]' + numString);
      TboxModule.capture(ctx, 'tboxPop', title);
      TboxModule.capture(ctx, 'tboxPopDisplay', itemName + numString);
      TboxModule.capture(ctx, 'tboxPopLinkDisplay', '[[' + title + '|' + itemName + ']]' + numString);
      TboxModule.capture(ctx, title + 'PopNum', num);
    }
    const itemRow = itemParts.length > 0 ? '\n|-\n!物品\n| ' + itemParts.join('<br>') : '';
    return '{| class="wikitable"\n! colspan="2" |宝箱内容' + goldRow + itemRow + '\n|}';
  }

  /** 所需场景技能表（Module:Tbox.fsInfo）；FSID2 行在上 */
  private static async fsInfo(args: string[], ctx: TemplateContext): Promise<string> {
    const map = await JsonDataReader.read(ctx, 'FSID') as Record<string, Object> | null;
    if (map === null) {
      return '';
    }
    let out = TboxModule.fsRow(TboxModule.named(args, 'FSID2'), map, ctx);
    out += TboxModule.fsRow(TboxModule.named(args, 'FSID'), map, ctx);
    if (out.length === 0) {
      return '';
    }
    return '{| class="wikitable"\n! colspan="2" |所需场景技能' + out + '\n|}';
  }

  private static fsRow(fsid: string, map: Record<string, Object>,
    ctx: TemplateContext): string {
    if (fsid.length === 0) {
      return '';
    }
    const raw = map[fsid] !== undefined ? map[fsid] : map[String(parseInt(fsid))];
    if (raw === undefined) {
      return '';
    }
    const fs = raw as FsidJson;
    if (fs.Name === undefined) {
      return '';
    }
    const firstSkill = (fs.FieldSkillID1 ?? '') + 'Lv' + (fs.FieldSkillLevel1 ?? 0);
    const secondSkill = (fs.FieldSkillLevel2 ?? 0) === 0 ?
      '-' : (fs.FieldSkillID2 ?? '') + 'Lv' + (fs.FieldSkillLevel2 ?? 0);
    TboxModule.capture(ctx, 'FieldSkill',
      firstSkill + (secondSkill === '-' ? '' : ' + ' + secondSkill));
    return '\n|-\n| rowspan="2" | ' + fs.Name + '\n| ' + firstSkill +
      '\n|-\n| ' + secondSkill;
  }

  /** 出现条件表（Module:Tbox.appearCondition） */
  private static appearCondition(args: string[]): string {
    const cond = TboxModule.named(args, '出现条件');
    if (cond.length === 0) {
      return '';
    }
    return '{| class="wikitable"\n! 出现条件\n|-\n| ' + cond + '\n|}';
  }

  /** 宝箱定位地图：惰性登记为延迟调用（Reader 阶段 2 建图，不阻塞首帧） */
  private static async pointMap(args: string[], ctx: TemplateContext): Promise<string> {
    const gmkId = args.length > 0 ? args[0].trim() : '';
    const mapName = args.length > 1 ? args[1].trim() : '';
    if (gmkId.length === 0 && mapName.length === 0) {
      return '';
    }
    const mark = TemplateEngine.registerLazyInvoke(ctx, 'tbox', 'pointMap', [gmkId, mapName]);
    if (mark.length > 0) {
      return mark;
    }
    return await TboxModule.buildPointMap(gmkId, mapName, ctx);
  }

  /**
   * 建图：gmkId 非空 → 单个宝箱（底图 = mapName 或 areas[0]，对应宝箱页占位）；
   * 仅 mapName → 该地图全部宝箱（对应地区页「宝箱地图」，等价原站 [[Areas::地图]] 反查）。
   * 换算同 EnemyModule.buildMapSection。
   */
  private static async buildPointMap(gmkId: string, mapName: string,
    ctx: TemplateContext): Promise<string> {
    try {
      const list = await JsonDataReader.read(ctx, 'Gmk/tbox') as GmkTboxJson[] | null;
      if (list === null) {
        return '';
      }
      let area = '';
      let entries: GmkTboxJson[] = [];
      if (gmkId.length > 0) {
        for (const g of list) {
          if (g.Name === gmkId) {
            entries = [g];
            break;
          }
        }
        if (entries.length === 0 || entries[0].areas === undefined || entries[0].areas.length === 0) {
          return '';
        }
        area = mapName.length > 0 ? mapName.toLowerCase() : entries[0].areas[0].toLowerCase();
      } else {
        area = mapName.toLowerCase();
        for (const g of list) {
          if (g.areas !== undefined && g.areas.some((a: string): boolean => a.toLowerCase() === area)) {
            entries.push(g);
          }
        }
      }
      if (entries.length === 0) {
        return '';
      }
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
      const marks: string[] = [];
      for (const g of entries) {
        if (g.PosX === undefined || g.PosZ === undefined) {
          continue;
        }
        const leftPct = ((g.PosX as number) - info.LowerX) / spanX * 100;
        const topPct = ((g.PosZ as number) - info.LowerZ) / spanZ * 100;
        if (leftPct < -5 || leftPct > 105 || topPct < -5 || topPct > 105) {
          continue;
        }
        marks.push(Math.max(0, Math.min(100, leftPct)).toFixed(1) + ',' +
          Math.max(0, Math.min(100, topPct)).toFixed(1));
      }
      if (marks.length === 0) {
        return '';
      }
      const title = (info.mapName ?? '') + (info.menuGroup !== undefined && info.menuGroup.length > 0 &&
        info.menuGroup !== info.mapName ? '・' + info.menuGroup : '');
      return '@@WIKIMAP|' + (area.charAt(0).toUpperCase() + area.substring(1) + '_map_0.png') +
        '|' + title + '|' + info.Width + '|' + info.Height + '|' + marks.join(';') + '@@';
    } catch (e) {
      Logger.warn(TAG, 'buildPointMap error: ' + JSON.stringify(e));
      return '';
    }
  }
}
