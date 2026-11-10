import { TemplateContext } from '../../template/TemplateEngine';
import { SdvArgs, SdvData } from './SdvArgs';

const TAG = 'SdvItemsModule';

/**
 * {{#invoke:Items|renderName/renderDescription/...}}（Template:Name 12381 次 /
 * Template:Description 3256 次的底层）。
 * 数据页：Module:Data/Items_zh_*、Items_en_*、Items_overrides_*（lua_data_to_json 产物）。
 */
export class ItemsModule {
  /** title→renderName 产物缓存（同名探测跨页面重复，LRU 由 Map 容量近似） */
  private static nameCache: Map<string, string> = new Map();

  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const f = func.toLowerCase();
    if (f === 'rendername') {
      return await ItemsModule.renderName(args, ctx);
    }
    if (f === 'renderdescription') {
      return await ItemsModule.renderDescription(args, ctx);
    }
    if (f === 'getchinesename') {
      return await ItemsModule.getChineseName(SdvArgs.pos(args, 0), ctx);
    }
    if (f === 'getenglishname') {
      return await ItemsModule.getEnglishName(SdvArgs.pos(args, 0), ctx);
    }
    if (f === 'getdescription') {
      return await ItemsModule.getDescription(SdvArgs.pos(args, 0), ctx);
    }
    if (f === 'getid') {
      return await ItemsModule.getId(SdvArgs.pos(args, 0), ctx);
    }
    if (f === 'getitemid') {
      const id = await ItemsModule.getId(SdvArgs.pos(args, 0), ctx);
      return id.replace(/\\/g, '<br />');
    }
    if (f === 'getchinesenamebyid' || f === 'getenglishnamebyid') {
      const key = SdvArgs.normalizeKey(SdvArgs.pos(args, 0));
      const m = await SdvData.loadStrMap(ctx, f === 'getchinesenamebyid'
        ? 'Items_zh_id_name' : 'Items_en_id_name');
      return SdvData.getStr(m, key);
    }
    return '';
  }

  static async getEnglishName(name: string, ctx: TemplateContext): Promise<string> {
    const text = SdvArgs.normalizeKey(name);
    if (text.length === 0) {
      return '';
    }
    const zhIdByName = await SdvData.loadStrMap(ctx, 'Items_zh_name_ids');
    const enNameById = await SdvData.loadStrMap(ctx, 'Items_en_ids_name');
    const id = SdvData.getStr(zhIdByName, text);
    return id.length > 0 ? SdvData.getStr(enNameById, id) : '';
  }

  static async getChineseName(name: string, ctx: TemplateContext): Promise<string> {
    const text = SdvArgs.normalizeKey(name);
    if (text.length === 0) {
      return '';
    }
    const ovName = await SdvData.loadStrMap(ctx, 'Items_overrides_name');
    if (SdvData.has(ovName, text)) {
      return SdvData.getStr(ovName, text);
    }
    const enIdByName = await SdvData.loadStrMap(ctx, 'Items_en_name_ids');
    const zhNameById = await SdvData.loadStrMap(ctx, 'Items_zh_ids_name');
    const id = SdvData.getStr(enIdByName, text);
    return id.length > 0 ? SdvData.getStr(zhNameById, id) : '';
  }

  static async getDescription(name: string, ctx: TemplateContext): Promise<string> {
    const text = SdvArgs.normalizeKey(name);
    if (text.length === 0) {
      return '';
    }
    const ovDesc = await SdvData.loadStrMap(ctx, 'Items_overrides_description');
    if (SdvData.has(ovDesc, text)) {
      return SdvData.getStr(ovDesc, text);
    }
    const zhDescByName = await SdvData.loadStrMap(ctx, 'Items_zh_name_desc');
    const hit = SdvData.getStr(zhDescByName, text);
    if (hit.length > 0) {
      return hit;
    }
    const enIdByName = await SdvData.loadStrMap(ctx, 'Items_en_name_ids');
    const zhNameById = await SdvData.loadStrMap(ctx, 'Items_zh_ids_name');
    const id = SdvData.getStr(enIdByName, text);
    if (id.length > 0) {
      const cn = SdvArgs.normalizeKey(SdvData.getStr(zhNameById, id));
      if (cn.length > 0) {
        const viaCn = SdvData.getStr(zhDescByName, cn);
        if (viaCn.length > 0) {
          return viaCn;
        }
      }
    }
    const zhDescById = await SdvData.loadStrMap(ctx, 'Items_zh_id_desc');
    return SdvData.getStr(zhDescById, text);
  }

  static async getId(name: string, ctx: TemplateContext): Promise<string> {
    const text = SdvArgs.normalizeKey(name);
    if (text.length === 0) {
      return '';
    }
    const enIdByName = await SdvData.loadStrMap(ctx, 'Items_en_name_ids');
    const en = SdvData.getStr(enIdByName, text);
    if (en.length > 0) {
      return en;
    }
    const zhIdByName = await SdvData.loadStrMap(ctx, 'Items_zh_name_ids');
    const zh = SdvData.getStr(zhIdByName, text);
    if (zh.length > 0) {
      return zh;
    }
    const ovItems = await SdvData.loadStrMap(ctx, 'Items_overrides_items');
    return SdvData.getStr(ovItems, text);
  }

  /** 物品名带图徽标（Template:Name 核心）：图片探测（中文名→英文名→Blank icon）+链接 */
  static async renderName(args: string[], ctx: TemplateContext): Promise<string> {
    const pos = SdvArgs.positional(args);
    const inputName = pos.length > 0 ? pos[0] : '';
    const description = pos.length > 1 ? pos[1] : '';
    const size = SdvArgs.namedOr(args, 'size', '24');
    const link = SdvArgs.named(args, 'link');
    const alt = SdvArgs.named(args, 'alt');

    const cacheKey = inputName + '\u0001' + description + '\u0001' + size + '\u0001' +
      (link ?? '') + '\u0001' + (alt ?? '');
    const cached = ItemsModule.nameCache.get(cacheKey);
    if (cached !== undefined) {
      return cached;
    }

    let imageName = inputName;
    if (ctx.index !== null && !ctx.index.imageExists(inputName + '.png')) {
      const englishName = await ItemsModule.getEnglishName(inputName, ctx);
      if (englishName.length > 0 && ctx.index.imageExists(englishName + '.png')) {
        imageName = englishName;
      } else {
        imageName = 'Blank icon';
      }
    }

    let linkText: string;
    if (link !== null && link.length > 0) {
      linkText = '[[' + link + ']]';
    } else if (alt !== null && alt.length > 0) {
      linkText = '[[' + alt + ']]';
    } else {
      const chineseName = await ItemsModule.getChineseName(inputName, ctx);
      linkText = '[[' + (chineseName.length > 0 ? chineseName : inputName) + ']]';
    }

    const result = '[[File:' + imageName + '.png|' + size + 'px|link=]] ' + linkText +
      (description.length > 0 ? '（' + description + '）' : '');
    if (ItemsModule.nameCache.size > 4096) {
      ItemsModule.nameCache.clear();
    }
    ItemsModule.nameCache.set(cacheKey, result);
    return result;
  }

  static async renderDescription(args: string[], ctx: TemplateContext): Promise<string> {
    const pos = SdvArgs.positional(args);
    const itemType = pos.length > 0 ? pos[0] : '';
    const itemName = pos.length > 1 ? pos[1] : '';
    const lower = itemType.toLowerCase();
    if (lower === 'recipe' || itemType === '食谱' || itemType === '配方') {
      return '一个用于制作' + itemName + '的配方';
    }
    if (lower === 'blueprint' || itemType === '图纸') {
      return '用于制造' + itemName + '的设计图';
    }
    return await ItemsModule.getDescription(itemType, ctx);
  }
}
