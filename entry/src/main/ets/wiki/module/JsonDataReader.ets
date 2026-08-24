import { Logger } from '../../common/Logger';
import { TemplateContext } from '../template/TemplateEngine';

const TAG = 'JsonDataReader';

/**
 * JSON 命名空间数据读取器（带缓存）。
 * 数据页：JSON:CHR_EnArrange/179 等，内容为纯 JSON。
 */
export class JsonDataReader {
  private static cache: Map<string, Object> = new Map();

  static async read(ctx: TemplateContext, sub: string): Promise<Object | null> {
    const cached = JsonDataReader.cache.get(sub);
    if (cached !== undefined) {
      return cached;
    }
    if (ctx.index === null) {
      return null;
    }
    try {
      const text = await ctx.index.readJsonData(sub);
      if (text === null) {
        return null;
      }
      const obj = JSON.parse(text) as Object;
      JsonDataReader.cache.set(sub, obj);
      return obj;
    } catch (e) {
      Logger.warn(TAG, 'read json failed: ' + sub + ' ' + JSON.stringify(e));
      return null;
    }
  }

  static clear(): void {
    JsonDataReader.cache.clear();
  }
}
