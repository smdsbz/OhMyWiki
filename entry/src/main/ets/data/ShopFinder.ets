import { Logger } from '../common/Logger';
import { WikiIndex } from './WikiIndex';

const TAG = 'ShopFinder';

/** 某商店的基本信息 */
export interface ShopInfo {
  /** 商店页标题，如 '商店:汉努恩鱼店' */
  title: string;
  /** 地区，如 '斯佩比亚' */
  region: string;
  /** 具体位置，如 '斯佩比亚帝国・帝都阿尔巴马格・爱比尔商业区' */
  location: string;
}

/**
 * 商店索引：收纳包道具名 → 出售它的商店列表（含地区/位置）。
 * 数据来源为「商店」命名空间页面（{{商店}} 头部 + {{ShopGoodsPouchItemRow}} 行）。
 * 懒构建 + 缓存：首次查询或 warm() 时扫描全部商店页。
 */
export class ShopFinder {
  private index: WikiIndex;
  private map: Map<string, ShopInfo[]> | null = null;
  private loadPromise: Promise<void> | null = null;

  constructor(index: WikiIndex) {
    this.index = index;
  }

  /** 后台预构建（不等待） */
  warm(): void {
    if (this.loadPromise === null) {
      this.loadPromise = this.build();
    }
  }

  /** 查询某收纳包道具的出售商店（首次调用会触发扫描并缓存） */
  async find(itemName: string): Promise<ShopInfo[]> {
    if (this.map === null) {
      if (this.loadPromise === null) {
        this.loadPromise = this.build();
      }
      await this.loadPromise;
    }
    const arr = this.map?.get(itemName);
    return arr !== undefined ? arr : [];
  }

  private async build(): Promise<void> {
    const map = new Map<string, ShopInfo[]>();
    try {
      const titles = this.index.titlesByPrefix('商店:');
      for (const t of titles) {
        try {
          const raw = await this.index.readPage(t);
          if (raw === null) {
            continue;
          }
          const items = this.extractPouchItems(raw);
          if (items.length === 0) {
            continue;
          }
          const info: ShopInfo = {
            title: t,
            region: this.extractField(raw, '地区'),
            location: this.extractField(raw, '位置'),
          };
          for (const it of items) {
            let arr = map.get(it);
            if (arr === undefined) {
              arr = [];
              map.set(it, arr);
            }
            arr.push(info);
          }
        } catch (e) {
          Logger.warn(TAG, 'scan shop failed: ' + t + ' ' + JSON.stringify(e));
        }
      }
      this.map = map;
      Logger.info(TAG, 'shop map built: ' + map.size + ' items from ' + titles.length + ' shops');
    } catch (e) {
      Logger.warn(TAG, 'build shop map failed: ' + JSON.stringify(e));
      this.map = map;
    }
  }

  /** 从 {{商店 ...}} 头部提取字段 */
  private extractField(raw: string, key: string): string {
    const re = new RegExp('\\|\\s*' + key + '\\s*=\\s*([^\\n|]+)');
    const m = raw.match(re);
    if (m !== null) {
      return m[1].trim();
    }
    return '';
  }

  /** 提取所有 {{ShopGoodsPouchItemRow|物品名|...}} 的物品名 */
  private extractPouchItems(raw: string): string[] {
    const out: string[] = [];
    const re = /\{\{\s*ShopGoodsPouchItemRow\s*\|([^|}]+)/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(raw)) !== null) {
      const name = m[1].trim();
      if (name.length > 0 && out.indexOf(name) < 0) {
        out.push(name);
      }
    }
    return out;
  }
}
