import { TemplateContext } from '../../template/TemplateEngine';
import { SdvArgs } from './SdvArgs';

/** {{#invoke:Calcsellprice|csp|im=|bp=|q=|pm=|fm=}}：物品售价（zh：千分位+金） */
export class CalcsellpriceModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    if (func.toLowerCase() !== 'csp') {
      return '';
    }
    const item = SdvArgs.namedOr(args, 'im', '').toLowerCase();
    const bp = parseFloat(SdvArgs.namedOr(args, 'bp', '0'));
    const q = parseFloat(SdvArgs.namedOr(args, 'q', '0'));
    let pm = parseFloat(SdvArgs.namedOr(args, 'pm', '1'));
    const fm = SdvArgs.namedOr(args, 'fm', '').toLowerCase();
    if (isNaN(bp) || bp === 0) {
      return '0';
    }
    if (isNaN(pm) || item === 'coffee' || item === 'oil') {
      pm = 1;
    }
    let qm = 1;
    if (q === 1) {
      qm = 1.25;
    } else if (q === 2) {
      qm = 1.5;
    } else if (q === 4) {
      qm = 2;
    }
    let ap = bp;
    if (item.includes('wine')) {
      ap = bp * 3;
    } else if (item.includes('juice')) {
      ap = Math.floor(bp * 2.25);
    } else if (item.includes('jelly') || item.includes('pickles')) {
      ap = 50 + bp * 2;
    } else if (item.includes('dried')) {
      ap = Math.floor(bp * 7.5 + 25);
    } else if (item === 'honey') {
      ap = bp !== 100 ? 100 + bp * 2 : 100;
    } else if (item.includes('aged roe')) {
      ap = 2 * (30 + Math.floor(bp / 2));
    } else if (item.includes('roe')) {
      ap = 30 + Math.floor(bp / 2);
    }
    const sum = Math.floor(Math.floor(pm * 10 * Math.floor(qm * ap)) / 10);
    if (fm === 'false') {
      return String(sum);
    }
    return SdvArgs.formatNum(sum) + '金';
  }
}

/** {{#invoke:Calcgrangepoints|cgp|p=|q=}}：展览会评分 */
export class CalcgrangepointsModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    if (func.toLowerCase() !== 'cgp') {
      return '';
    }
    const price = parseFloat(SdvArgs.namedOr(args, 'p', '0'));
    const q = parseFloat(SdvArgs.namedOr(args, 'q', '0'));
    let total = q + 1;
    if (price >= 20) {
      total += 1;
    }
    if (price >= 90) {
      total += 1;
    }
    if (price >= 200) {
      total += 1;
    }
    if (price >= 300 && q < 2) {
      total += 1;
    }
    if (price >= 400 && q < 1) {
      total += 1;
    }
    return String(total);
  }
}

/** {{#invoke:Calcedibility|ce|im=|ed=|q=|ll=}}：能量/生命恢复量 */
export class CalcedibilityModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    if (func.toLowerCase() !== 'ce') {
      return '';
    }
    const item = SdvArgs.namedOr(args, 'im', '').toLowerCase();
    const ed = parseFloat(SdvArgs.namedOr(args, 'ed', '0'));
    const q = parseFloat(SdvArgs.namedOr(args, 'q', '0'));
    if (isNaN(ed) || ed === 0) {
      return '0';
    }
    let result: number;
    if (item === 'energy') {
      result = Math.floor(Math.ceil(ed * 2.5) + ed * q);
    } else {
      result = Math.floor(Math.floor(Math.ceil(ed * 2.5) + ed * q) * 0.45);
    }
    return SdvArgs.formatNum(result);
  }
}

/** {{#invoke:Tcartprice|tprice|price=|separator=|gold=|spacearoundseparator=}}：旅行货车价格区间 */
export class TcartpriceModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    if (func.toLowerCase() !== 'tprice') {
      return '';
    }
    const price = SdvArgs.namedOr(args, 'price', '');
    const separator = SdvArgs.namedOr(args, 'separator', '');
    const gold = SdvArgs.namedOr(args, 'gold', '');
    const space = SdvArgs.namedOr(args, 'spacearoundseparator', 'false').toLowerCase() === 'true';
    const sep = space ? ' ' + separator + ' ' : separator;
    let out = '[[File:Gold.png|18px|link=]]';
    if (price.toLowerCase() === 'furniture') {
      out += '250' + sep + SdvArgs.formatNum(2500);
    } else {
      const p = parseFloat(price);
      const low = p * 3;
      const high = p * 5;
      out += low <= 100 ? '100' : SdvArgs.formatNum(low);
      out += sep;
      out += high <= 1000 ? SdvArgs.formatNum(1000) : SdvArgs.formatNum(high);
    }
    return out + gold;
  }
}

/** {{#invoke:Banner|left/right}}：按季节返回主图横幅文件名（now+8h） */
export class BannerModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const f = func.toLowerCase();
    if (f !== 'left' && f !== 'right') {
      return '';
    }
    const d = new Date(Date.now() + 8 * 3600 * 1000);
    const md = (d.getMonth() + 1) * 100 + d.getDate();
    let suffix = '';
    if (md >= 321 && md < 923) {
      suffix = '';
    } else if (md >= 923 && md < 1221) {
      suffix = ' Fall';
    } else {
      suffix = ' Winter';
    }
    return 'Banner ' + (f === 'left' ? 'Left' : 'Right') + suffix;
  }
}
