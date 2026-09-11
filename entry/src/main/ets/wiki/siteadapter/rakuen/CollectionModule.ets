import { Logger } from '../../../common/Logger';
import { TemplateContext, TemplateEngine } from '../../template/TemplateEngine';

const TAG = 'CollectionModule';

/**
 * Collection 模块（Module:Collection 的 ArkTS 移植）。
 * - popList：地区采集点一览页（采集点:古拉 / 黄金之国采集点:古拉 等）。
 *   站点实现在 Lua 内执行 mw.smw.ask 后手工拼表格；离线版把等价查询
 *   转交 SmwQueryEngine（惰性登记，渐进渲染），表格由引擎统一渲染。
 * - craftMaterials：制作材料清单（{{craft required item|物品名|数量|…}}）。
 * - setGmkData：站点前端 JS 地图的打点数据登记（mw.smw.subobject），
 *   离线版无前端脚本，仅捕获 CollectionPointId 属性，不产出内容。
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
}
