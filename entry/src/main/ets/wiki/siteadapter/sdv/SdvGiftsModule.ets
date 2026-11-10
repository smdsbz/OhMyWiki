import { TemplateContext } from '../../template/TemplateEngine';
import { SdvArgs, SdvData } from './SdvArgs';

/** 村民预定义顺序（Module:GiftsByItem.predefinedOrder） */
const PREDEFINED_ORDER: string[] = [
  '哈维', '山姆', '谢恩', '亚历克斯', '艾利欧特', '塞巴斯蒂安', '海莉', '莉亚', '玛鲁',
  '潘妮', '艾米丽', '阿比盖尔', '皮埃尔', '卡洛琳', '刘易斯', '玛妮', '罗宾',
  '德米特里厄斯', '艾芙琳', '乔治', '贾斯', '文森特', '乔迪', '肯特', '威利', '格斯',
  '潘姆', '莱纳斯', '克林特', '法师', '矮人', '科罗布斯', '桑迪', '雷欧',
];

const TRANSLATION: Record<string, string> = {
  'Alex': '亚历克斯', 'Elliott': '艾利欧特', 'Harvey': '哈维', 'Sam': '山姆',
  'Sebastian': '塞巴斯蒂安', 'Shane': '谢恩', 'Abigail': '阿比盖尔', 'Emily': '艾米丽',
  'Haley': '海莉', 'Leah': '莉亚', 'Maru': '玛鲁', 'Penny': '潘妮',
  'Caroline': '卡洛琳', 'Clint': '克林特', 'Demetrius': '德米特里厄斯', 'Dwarf': '矮人',
  'Evelyn': '艾芙琳', 'George': '乔治', 'Gus': '格斯', 'Jas': '贾斯', 'Jodi': '乔迪',
  'Kent': '肯特', 'Krobus': '科罗布斯', 'Leo': '雷欧', 'Lewis': '刘易斯',
  'Linus': '莱纳斯', 'Marnie': '玛妮', 'Pam': '潘姆', 'Pierre': '皮埃尔',
  'Robin': '罗宾', 'Sandy': '桑迪', 'Vincent': '文森特', 'Willy': '威利',
  'Wizard': '法师',
};

function reverseTranslation(): Record<string, string> {
  const out: Record<string, string> = {};
  for (const k of Object.keys(TRANSLATION)) {
    out[TRANSLATION[k]] = k;
  }
  return out;
}

const ORIGINAL: Record<string, string> = reverseTranslation();

/** GiftsByItem/data 条目（五档村民列表，键 "1","2",...） */
interface GiftItemEntry {
  Love?: Record<string, string>;
  Like?: Record<string, string>;
  Neutral?: Record<string, string>;
  Dislike?: Record<string, string>;
  Hate?: Record<string, string>;
}

/** 档位静态配置：字段名 / 标签 / 好感度 */
interface GiftCat {
  key: string;
  label: string;
  points: string;
}

const CATEGORIES: GiftCat[] = [
  { key: 'Love', label: '最爱', points: '+80' },
  { key: 'Like', label: '喜欢', points: '+45' },
  { key: 'Neutral', label: '普通', points: '+20' },
  { key: 'Dislike', label: '不喜欢', points: '-20' },
  { key: 'Hate', label: '讨厌', points: '-40' },
];

/** {{#invoke:GiftsByItem|generateGiftTable}}：物品送礼偏好表（数据页 GiftsByItem_data） */
export class GiftsByItemModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const f = func.toLowerCase();
    if (f === 'ts') {
      return GiftsByItemModule.ts(SdvArgs.pos(args, 0));
    }
    if (f === 'generategifttable') {
      return await GiftsByItemModule.generateGiftTable(args, ctx);
    }
    return '';
  }

  /** 村民列表 → 去重/字典序/预定义序 → 图标+链接串 */
  private static ts(villagerlist: string): string {
    if (villagerlist.length === 0) {
      return '';
    }
    let names: string[] = [];
    for (const seg of villagerlist.split(',')) {
      const v = seg.trim();
      if (v.length > 0) {
        names.push(v);
      }
    }
    names = Array.from(new Set(names));
    names.sort();
    const orderIdx = (n: string): number => PREDEFINED_ORDER.indexOf(n);
    names.sort((a: string, b: string): number => {
      const ia = orderIdx(a);
      const ib = orderIdx(b);
      const va = ia < 0 ? Number.MAX_SAFE_INTEGER : ia;
      const vb = ib < 0 ? Number.MAX_SAFE_INTEGER : ib;
      return va - vb;
    });
    const parts: string[] = [];
    for (const n of names) {
      const icon = ORIGINAL[n] ?? n;
      parts.push('<span class="no-wrap">[[File:' + icon + ' Icon.png|24px|link=' + n +
        ']]&nbsp;[[' + n + '|' + n + ']]</span>');
    }
    return parts.join(' • ');
  }

  /** GiftsByItem_data 一次性解析缓存（323KB JSON，逐页重解析不可承受） */
  private static dataCache: Record<string, GiftItemEntry> | null | undefined = undefined;

  private static async loadItem(itemName: string, ctx: TemplateContext):
    Promise<GiftItemEntry | null> {
    if (GiftsByItemModule.dataCache === undefined) {
      const text = ctx.index !== null
        ? await ctx.index.readPage('Module:Data/GiftsByItem_data') : null;
      let data: Record<string, GiftItemEntry> | null = null;
      if (text !== null && text.length > 0) {
        try {
          data = JSON.parse(text) as Record<string, GiftItemEntry>;
        } catch (e) {
          data = null;
        }
      }
      GiftsByItemModule.dataCache = data;
    }
    const data = GiftsByItemModule.dataCache;
    if (data === null || data === undefined) {
      return null;
    }
    const itemID = await GiftsByItemModule.getItemId(itemName, ctx);
    if (data[itemID] !== undefined) {
      return data[itemID];
    }
    if (data[itemName] !== undefined) {
      return data[itemName];
    }
    return null;
  }

  /** Module:ID.id：物品名→ID（zh/en 数据页，剥 (O)/(TR) 前缀） */
  private static async itemIdOf(name: string, ctx: TemplateContext): Promise<string> {
    const zh = await SdvData.loadStrMap(ctx, 'ID_data_zh');
    const hit = SdvData.getStr(zh, name);
    if (hit.length > 0) {
      return hit.replace('(O)', '').replace('(TR)', '');
    }
    const en = await SdvData.loadStrMap(ctx, 'ID_data_en');
    return SdvData.getStr(en, name).replace('(O)', '').replace('(TR)', '');
  }

  private static async getItemId(itemName: string, ctx: TemplateContext): Promise<string> {
    const special: Record<string, string> = {
      '诡异玩偶（绿）': '126', '诡异玩偶（黄）': '127', 'Joja可乐': '167',
      '垃圾（物品）': '168', '破损的CD': '171', '鱼饵（物品）': '685',
      '针对性鱼饵': 'SpecificBait', '熏鱼': 'Smoked', '果干': 'DriedFruit',
      '蘑菇干': 'DriedMushrooms', '青蛙蛋': 'FrogEgg',
    };
    if (special[itemName] !== undefined) {
      return special[itemName];
    }
    return await GiftsByItemModule.itemIdOf(itemName, ctx);
  }

  private static catListOf(item: GiftItemEntry, key: string): Record<string, string> | null {
    if (key === 'Love') {
      return item.Love ?? null;
    }
    if (key === 'Like') {
      return item.Like ?? null;
    }
    if (key === 'Neutral') {
      return item.Neutral ?? null;
    }
    if (key === 'Dislike') {
      return item.Dislike ?? null;
    }
    if (key === 'Hate') {
      return item.Hate ?? null;
    }
    return null;
  }

  private static namesOf(list: Record<string, string>): string[] {
    const npcs: string[] = [];
    for (let i = 1; i < 100; i++) {
      const v = list[String(i)];
      if (v === undefined) {
        break;
      }
      npcs.push(v);
    }
    return npcs;
  }

  private static rowHtml(label: string, points: string, npcHtml: string): string {
    return '<tr><th><span class="no-wrap">' + label + '</span><br>' +
      '<span style="font-size:smaller;">' + points + '</span></th><td>' + npcHtml + '</td></tr>';
  }

  private static async autoTable(itemName: string, displayName: string,
    ctx: TemplateContext): Promise<string> {
    const item = await GiftsByItemModule.loadItem(itemName, ctx);
    if (item === null) {
      return '';
    }
    const rows: string[] = ['<table class="wikitable roundedborder">',
      '<tr><th colspan="2">收到' + displayName + '后</th></tr>'];
    let any = false;
    const stardrop = itemName === '星之果茶' || itemName === 'StardropTea';
    for (const cat of CATEGORIES) {
      const list = GiftsByItemModule.catListOf(item, cat.key);
      if (list === null) {
        continue;
      }
      const npcs = GiftsByItemModule.namesOf(list);
      if (npcs.length === 0) {
        continue;
      }
      any = true;
      const points = cat.key === 'Love' && stardrop ? '+250' : cat.points;
      rows.push(GiftsByItemModule.rowHtml(cat.label, points,
        GiftsByItemModule.ts(npcs.join(','))));
    }
    rows.push('</table>');
    if (!any) {
      return '';
    }
    return rows.join('\n');
  }

  private static manualRow(category: string, npcList: string | null,
    itemName: string): string {
    if (npcList === null || npcList.trim().length === 0) {
      return '';
    }
    const cfg: Record<string, string[]> = {
      'love': ['最爱', itemName === '星之果茶' ? '+250' : '+80'],
      'like': ['喜欢', '+45'],
      'neutral': ['普通', '+20'],
      'dislike': ['不喜欢', '-20'],
      'hate': ['讨厌', '-40'],
    };
    const c = cfg[category];
    if (c === undefined) {
      return '';
    }
    return GiftsByItemModule.rowHtml(c[0], c[1], GiftsByItemModule.ts(npcList));
  }

  private static manualTable(itemName: string, displayName: string, args: string[]): string {
    const rows: string[] = ['<table class="wikitable roundedborder">',
      '<tr><th colspan="2">收到' + displayName + '后</th></tr>'];
    rows.push(GiftsByItemModule.manualRow('love', SdvArgs.named(args, 'love'), itemName));
    rows.push(GiftsByItemModule.manualRow('like', SdvArgs.named(args, 'like'), itemName));
    rows.push(GiftsByItemModule.manualRow('neutral', SdvArgs.named(args, 'neutral'), itemName));
    rows.push(GiftsByItemModule.manualRow('dislike', SdvArgs.named(args, 'dislike'), itemName));
    rows.push(GiftsByItemModule.manualRow('hate', SdvArgs.named(args, 'hate'), itemName));
    rows.push('</table>');
    return rows.filter((r: string): boolean => r.length > 0).join('\n');
  }

  private static hasManual(args: string[]): boolean {
    for (const k of ['love', 'like', 'neutral', 'dislike', 'hate']) {
      const v = SdvArgs.named(args, k);
      if (v !== null && v.length > 0) {
        return true;
      }
    }
    return false;
  }

  private static async generateGiftTable(args: string[], ctx: TemplateContext): Promise<string> {
    let itemName = SdvArgs.namedOr(args, 'item', '');
    if (itemName.length === 0) {
      const pos = SdvArgs.positional(args);
      itemName = pos.length > 0 ? pos[0] : SdvArgs.ctxPageName(ctx);
    }
    const displayName = SdvArgs.namedOr(args, 'alt', itemName);
    if (itemName.length === 0) {
      return '';
    }
    const item = await GiftsByItemModule.loadItem(itemName, ctx);
    if (item !== null) {
      const auto = await GiftsByItemModule.autoTable(itemName, displayName, ctx);
      if (auto.length > 0) {
        return auto;
      }
    }
    if (GiftsByItemModule.hasManual(args)) {
      return GiftsByItemModule.manualTable(itemName, displayName, args);
    }
    return '';
  }
}
