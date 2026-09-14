import { SiteAdapter } from '../SiteAdapter';
import { WikiSite } from '../../../model/WikiTypes';

/**
 * monster-hunter-web-data（angrychocobo MHXX 攻略大全静态镜像）站点适配器。
 * 站点为纯静态 HTML，由 scripts/monster-hunter-web-data/crawl.py 预转换成
 * 标准 wikitext 转储（无模板/Lua 模块/SMW），引擎开箱即读：
 * 适配器只声明归属，不提供任何模块能力。
 */
export class MhxxSiteAdapter implements SiteAdapter {
  matches(site: WikiSite): boolean {
    return site.name === 'monster-hunter-web-data';
  }

  createInvokeHandler(): null {
    return null;
  }
}
