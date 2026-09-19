import { Logger } from '../../../common/Logger';
import { TemplateContext } from '../../template/TemplateEngine';

const TAG = 'BdatEnums';

/**
 * 模块:BdatEnums 的运行时解析（原站 Lua 查表数据，转储 pages/模块/BdatEnums.wiki）。
 * 文件为纯数据：`p.表名 = {` 块内每行 `"名称",`（Lua 1-based 顺序键）或 `[n] = "名称"`。
 * 站方改表后随转储更新自动生效，应用侧无需改码。
 */
export class BdatEnums {
  private static tables: Map<string, Map<number, string>> | null = null;
  private static loading: Promise<boolean> | null = null;

  /** 确认已加载（页面渲染入口调用一次；失败仅记日志，查询返回空串降级） */
  static async ensure(ctx: TemplateContext): Promise<boolean> {
    if (BdatEnums.tables !== null) {
      return true;
    }
    if (BdatEnums.loading !== null) {
      return BdatEnums.loading;
    }
    BdatEnums.loading = BdatEnums.load(ctx);
    return BdatEnums.loading;
  }

  private static async load(ctx: TemplateContext): Promise<boolean> {
    if (ctx.index === null) {
      return false;
    }
    try {
      const text = await ctx.index.readPage('模块:BdatEnums');
      if (text === null) {
        Logger.warn(TAG, '模块:BdatEnums 不在转储中');
        return false;
      }
      const tables = new Map<string, Map<number, string>>();
      const blockRe = /p\.(\w+)\s*=\s*\{([\s\S]*?)\n\}/g;
      let bm: RegExpExecArray | null;
      while ((bm = blockRe.exec(text)) !== null) {
        const map = new Map<number, string>();
        let auto = 1;
        const itemRe = /(?:\[(\d+)\]\s*=\s*)?"([^"]*)"/g;
        let im: RegExpExecArray | null;
        while ((im = itemRe.exec(bm[2])) !== null) {
          if (im[1] !== undefined && im[1] !== null) {
            map.set(parseInt(im[1], 10), im[2]);
          } else {
            // 裸字符串项：Lua 数组部分按 1-based 顺序递增（与显式键相互独立）
            map.set(auto, im[2]);
            auto++;
          }
        }
        tables.set(bm[1], map);
      }
      BdatEnums.tables = tables;
      Logger.info(TAG, 'BdatEnums loaded: ' + tables.size + ' tables');
      return true;
    } catch (e) {
      Logger.warn(TAG, 'BdatEnums parse error: ' + JSON.stringify(e));
      return false;
    }
  }

  /** 查表（表或键不存在返回空串） */
  static get(table: string, key: number): string {
    if (BdatEnums.tables === null) {
      return '';
    }
    const t = BdatEnums.tables.get(table);
    if (t === undefined) {
      return '';
    }
    const v = t.get(key);
    return v !== undefined ? v : '';
  }
}
