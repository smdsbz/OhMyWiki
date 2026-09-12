import { Logger } from '../../../common/Logger';
import { TemplateContext, TemplateEngine } from '../../template/TemplateEngine';
import { Row, SmwQueryEngine } from '../../smw/SmwQueryEngine';
import { JsonDataReader } from '../../module/JsonDataReader';

const TAG = 'CollectionModule';

/** Gmk/collection 条目（采集点放置坐标） */
interface GmkCollectionJson {
  Name: string;
  PosX?: number;
  PosY?: number;
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
 * Collection 模块（Module:Collection 的 ArkTS 移植）。
 * - popList：地区采集点一览页（采集点:古拉 / 黄金之国采集点:古拉 等）。
 *   站点实现在 Lua 内执行 mw.smw.ask 后手工拼表格；离线版把等价查询
 *   转交 SmwQueryEngine（惰性登记，渐进渲染），表格由引擎统一渲染。
 * - craftMaterials：制作材料清单（{{craft required item|物品名|数量|…}}）。
 * - setGmkData：站点前端 JS 地图的打点数据登记（mw.smw.subobject），
 *   离线版无前端脚本，仅捕获 CollectionPointId 属性，不产出内容。
 * - itemMap：物品页「地图」区块（原站 multi-xb2map-collection 交互地图）——
 *   反查产出该物品的采集点页 → 取各放置点坐标 → 按地区底图发射静态打点地图。
 */
export class CollectionModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const f = func.toLowerCase();
    try {
      if (f === 'poplist') {
        return await CollectionModule.popList(ctx);
      }
      if (f === 'craftmaterials') {
        return CollectionModule.craftMaterials(args, ctx);
      }
      if (f === 'setgmkdata') {
        CollectionModule.captureGmkId(args, ctx);
        return '';
      }
      if (f === 'itemmap') {
        return await CollectionModule.itemMap(args, ctx);
      }
      return '';
    } catch (e) {
      Logger.warn(TAG, 'invoke failed: collection.' + func + ' ' + JSON.stringify(e));
      return '';
    }
  }

  /** 页面标题去命名空间（mw.title.getCurrentTitle().text 等价） */
  private static titleText(ctx: TemplateContext): string {
    const ci = ctx.pageTitle.indexOf(':');
    return ci >= 0 ? ctx.pageTitle.substring(ci + 1) : ctx.pageTitle;
  }

  /**
   * 地区采集点一览：SMW 查询 [[采集点:+]][[地域::地区]]，
   * 列与站点一致：采集点类型 | 数量 | 道具/概率 ×4，按 CollectionTableId 排序。
   * 惰性上下文登记 PendingAsk（Reader 阶段 2 执行回填，长查询带进度条、可取消）；
   * 属性提取等无查询通道的上下文只返回返回链接（同时阻断递归查询）。
   */
  private static async popList(ctx: TemplateContext): Promise<string> {
    const ns = ctx.pageTitle.startsWith('黄金之国') ? '黄金之国采集点' : '采集点';
    const region = CollectionModule.titleText(ctx);
    const qargs: string[] = [
      '[[' + ns + ':+]][[地域::' + region + ']]',
      '?单次采集数量=数量',
      '?采集道具1=道具', '?采集概率1=概率',
      '?采集道具2=道具', '?采集概率2=概率',
      '?采集道具3=道具', '?采集概率3=概率',
      '?采集道具4=道具', '?采集概率4=概率',
      'mainlabel=采集点类型',
      'limit=200',
      'sort=CollectionTableId',
    ];
    const backLink = '<div><small><span style="color:#666"><</span> [[' + ns + ']]</small></div>';
    const mark = TemplateEngine.registerLazyAsk(ctx, qargs, false);
    if (mark.length > 0) {
      Logger.info(TAG, 'popList lazy: ns=' + ns + ' region=' + region);
      return backLink + '\n' + mark;
    }
    if (ctx.askHandler !== undefined && ctx.askHandler !== null) {
      Logger.info(TAG, 'popList direct: ns=' + ns + ' region=' + region);
      const table = await ctx.askHandler.query(qargs, ctx, false);
      return table.length > 0 ? backLink + '\n' + table : backLink;
    }
    return backLink;
  }

  /** 制作材料清单：位置参数「物品名|数量」成对 → [[物品:名|名]] ×数量（黄金之国页用对应命名空间） */
  private static craftMaterials(args: string[], ctx: TemplateContext): string {
    const itemNs = ctx.pageTitle.startsWith('黄金之国') ? '黄金之国物品' : '物品';
    const sb: string[] = [];
    let i = 0;
    while (i + 1 < args.length) {
      const name = args[i].trim();
      const amount = args[i + 1].trim();
      if (name.length > 0 && amount.length > 0) {
        sb.push('<div>[[' + itemNs + ':' + name + '|' + name + ']] ×' + amount + '</div>');
      }
      i += 2;
    }
    return sb.join('\n');
  }

  /** 捕获 CollectionPointId 语义属性（坐标等打点数据离线版暂不使用） */
  private static captureGmkId(args: string[], ctx: TemplateContext): void {
    if (ctx.capture === undefined || ctx.capture === null) {
      return;
    }
    for (const a of args) {
      const eq = a.indexOf('=');
      if (eq > 0) {
        const key = a.substring(0, eq).trim();
        const val = a.substring(eq + 1).trim();
        if (key === 'CollectionPointId' && val.length > 0) {
          ctx.capture(key, val);
          return;
        }
      }
    }
  }

  /**
   * 物品页地图：惰性登记为延迟调用（查询+建图不阻塞首帧），Reader 阶段 2 解析；
   * 属性提取等无查询通道的上下文返回空。
   */
  private static async itemMap(args: string[], ctx: TemplateContext): Promise<string> {
    const item = (args.length > 0 ? args[0] : '').trim();
    if (item.length === 0 || ctx.index === null) {
      return '';
    }
    const mark = TemplateEngine.registerLazyInvoke(ctx, 'collection', 'itemMap', [item]);
    if (mark.length > 0) {
      Logger.info(TAG, 'itemMap lazy: ' + item);
      return mark;
    }
    if (ctx.askHandler === undefined || ctx.askHandler === null) {
      return '';
    }
    return await CollectionModule.buildItemMaps(item, ctx);
  }

  /** 建图：采集物反查采集点页（主线+黄金之国）→ CollectionPointId →
   *  Gmk/collection 坐标按地区分组 → Mapinfo 底图发射 @@WIKIMAP 行 */
  private static async buildItemMaps(item: string, ctx: TemplateContext): Promise<string> {
    try {
      const eng = SmwQueryEngine.get();
      const rows: Row[] = [];
      for (const ns of ['采集点', '黄金之国采集点']) {
        const r = await eng.queryRows([
          '[[' + ns + ':+]][[采集物::' + item + ']]',
          '?CollectionPointId',
          'limit=500',
        ], ctx);
        for (const row of r) {
          rows.push(row);
        }
      }
      if (rows.length === 0) {
        Logger.info(TAG, 'itemMap: no collection pages for ' + item);
        return '';
      }
      const gmkList = await JsonDataReader.read(ctx, 'Gmk/collection') as GmkCollectionJson[] | null;
      if (gmkList === null) {
        return '';
      }
      const byName: Map<string, GmkCollectionJson> = new Map();
      for (const g of gmkList) {
        byName.set(g.Name, g);
      }
      // 地区 → 放置点（世界坐标）
      const byArea: Map<string, GmkCollectionJson[]> = new Map();
      for (const row of rows) {
        const ids = row.props.get('CollectionPointId');
        if (ids === undefined) {
          continue;
        }
        for (const id of ids) {
          const g = byName.get(id.trim());
          if (g === undefined || g.PosX === undefined || g.PosZ === undefined) {
            continue;
          }
          const areas = g.areas ?? [];
          for (const area of areas) {
            // 跳过船版变体：原站按页面级 ?Areas 输出建图，不含 *_shipoff（线上 API 实证），
            // 船版底图与常规版坐标不匹配，误画会打进虚空
            if (area.length === 0 || area.endsWith('_shipoff')) {
              continue;
            }
            const arr = byArea.get(area);
            if (arr === undefined) {
              byArea.set(area, [g]);
            } else {
              arr.push(g);
            }
          }
        }
      }
      const sb: string[] = [];
      for (const area of byArea.keys()) {
        const info = await JsonDataReader.read(ctx, 'Mapinfo/' + area) as MapinfoJson | null;
        if (info === null || info.LowerX === undefined || info.UpperX === undefined ||
          info.LowerZ === undefined || info.UpperZ === undefined ||
          info.Width === undefined || info.Height === undefined || info.Height <= 0) {
          continue;
        }
        const spanX = info.UpperX - info.LowerX;
        const spanZ = info.UpperZ - info.LowerZ;
        if (spanX <= 0 || spanZ <= 0) {
          continue;
        }
        const marks: string[] = [];
        for (const g of byArea.get(area) as GmkCollectionJson[]) {
          // 世界坐标 → 图内百分比（推导见 EnemyModule.buildMapSection：X 向右增、Z 向下增）
          const leftPct = ((g.PosX as number) - info.LowerX) / spanX * 100;
          const topPct = ((g.PosZ as number) - info.LowerZ) / spanZ * 100;
          if (leftPct < -5 || leftPct > 105 || topPct < -5 || topPct > 105) {
            continue;
          }
          marks.push(Math.max(0, Math.min(100, leftPct)).toFixed(1) + ',' +
            Math.max(0, Math.min(100, topPct)).toFixed(1));
        }
        if (marks.length === 0) {
          continue;
        }
        const title = (info.mapName ?? '') + (info.menuGroup !== undefined && info.menuGroup.length > 0 &&
          info.menuGroup !== info.mapName ? '・' + info.menuGroup : '');
        sb.push('@@WIKIMAP|' + (area.charAt(0).toUpperCase() + area.substring(1) + '_map_0.png') +
          '|' + title + '|' + info.Width + '|' + info.Height +
          '|' + marks.join(';') + '@@');
      }
      Logger.info(TAG, 'itemMap built: ' + item + ' -> ' + sb.length + ' maps (' + rows.length + ' pages)');
      return sb.join('\n');
    } catch (e) {
      Logger.warn(TAG, 'buildItemMaps error: ' + JSON.stringify(e));
      return '';
    }
  }
}
