import { Logger } from '../../../common/Logger';
import { InvokeHandler, TemplateContext, PLACEHOLDER_MARK } from '../../template/TemplateEngine';
import { HtmlBoxStyle, SiteAdapter } from '../SiteAdapter';
import { WikiSite } from '../../../model/WikiTypes';
import { EnemyModule } from './EnemyModule';
import { CollectionModule } from './CollectionModule';
import { SalvageModule } from './SalvageModule';
import { TboxModule } from './TboxModule';
import { QuestModule } from './QuestModule';
import { HanaPartsModule } from './HanaPartsModule';
import { TigerTigerModule } from './TigerTigerModule';

const TAG = 'RakuenSiteAdapter';

/** 前端交互地图占位 div（multi-xb2map-collection）匹配：高亮物品名捕获组 */
const ITEM_MAP_DIV_RE = /<div[^>]*class="[^"]*xb2map-collection[^"]*"[^>]*data-highlight-collection-item="([^"]*)"[^>]*><\/div>/g;
/** 前端交互地图占位 div（xb2map-salvage）匹配：打捞点 gmkId 捕获组 */
const SALVAGE_MAP_DIV_RE = /<div[^>]*class="[^"]*xb2map-salvage[^"]*"[^>]*data-gmk-id="([^"]*)"[^>]*><\/div>/g;
/** 前端交互地图占位 div（xb2map-tbox）匹配：gmkId（宝箱页单点，可空）与 mapName（地区页全图）捕获组 */
const TBOX_MAP_DIV_RE = /<div[^>]*class="[^"]*xb2map-tbox[^"]*"[^>]*data-gmk-id="([^"]*)"[^>]*data-map-name="([^"]*)"[^>]*><\/div>/g;

/** 搜索直达排除的命名空间前缀：MediaWiki/SMW 标准设施（本地化名）+
 *  扩展命名空间（Gadget/JSON）+ 本站 Project 元页（免责声明/捐助等）。
 *  内容页（主命名空间与游戏数据命名空间）不受影响 */
const SEARCH_EXCLUDED_NS: string[] = [
  '文件:', '模板:', '模块:', '分类:', '属性:', 'MediaWiki:',
  '用户:', '用户讨论:', 'smw/schema:', 'Gadget:', 'Gadget definition:',
  'JSON:', '帮助:', '项目:', '乐园数据管理室:',
];

/** 站点皮肤（load.php modules=skins.timeless.xbxb.v6，2026-09-19 取证）：
 *  .card{background:rgba(37,37,37,.5);border:1px solid #3e3e3e;padding:1em;margin:.5em}
 *  .card .title{border-bottom:solid 2px #cccccc}
 *  .quest-collapse{margin:.4em;padding:1em;background:rgba(42,136,116,.4);border-radius:.6em}
 *  站点只有深色皮肤，浅色侧按系统成对灰阶取值（#2C2C2E↔#E5E5EA 一族） */
const RAKUEN_BOX_STYLES: Map<string, HtmlBoxStyle> = new Map<string, HtmlBoxStyle>([
  ['card', {
    bgDark: 'rgba(37,37,37,0.5)', bgLight: 'rgba(229,229,234,0.6)',
    borderDark: '#3e3e3e', borderLight: '#d1d1d6',
    radiusVp: 8, padVp: 12,
  }],
  ['title', {
    borderDark: '#cccccc', borderLight: '#3a3a3c', underline: true,
  }],
  ['quest-collapse', {
    bgDark: 'rgba(42,136,116,0.4)', bgLight: 'rgba(42,136,116,0.15)',
    radiusVp: 10, padVp: 12,
  }],
]);

/**
 * rakuen-database（xenoblade2.cn 转储）站点适配器。
 * 该站点的 {{#invoke}} 模块以 ArkTS 移植实现注册于此；
 * 后续通用 Lua 虚拟机落地后，可替换为数据驱动实现而不动引擎。
 */
export class RakuenSiteAdapter implements SiteAdapter {
  readonly searchExcludedNs: string[] = SEARCH_EXCLUDED_NS;
  readonly htmlBoxStyles: Map<string, HtmlBoxStyle> = RAKUEN_BOX_STYLES;

  matches(site: WikiSite): boolean {
    return site.name === 'rakuen-database';
  }

  createInvokeHandler(): InvokeHandler | null {
    return new RakuenModuleHost();
  }

  /** 站点前端 JS 交互地图的占位 div → 离线版静态地图模块调用
   *  （div 在模板体内，一阶段展开后 {{FULLPAGENAME}} 已求值，此处改写后再展开一次） */
  rewriteWikitext(text: string): string {
    return text.replace(ITEM_MAP_DIV_RE, '{{#invoke:collection|itemMap|$1}}')
      .replace(SALVAGE_MAP_DIV_RE, '{{#invoke:salvage|pointMap|$1}}')
      .replace(TBOX_MAP_DIV_RE, '{{#invoke:tbox|pointMap|$1|$2}}');
  }
}

/** 该站点的 #invoke 分发宿主：模块名 → ArkTS 实现；未实现返回占位 */
class RakuenModuleHost implements InvokeHandler {
  async invoke(module: string, func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const lower = module.toLowerCase();
    try {
      switch (lower) {
        case 'enemy':
          return await EnemyModule.invoke(func, args, ctx);
        case 'collection':
          return await CollectionModule.invoke(func, args, ctx);
        case 'salvage':
          return await SalvageModule.invoke(func, args, ctx);
        case 'tbox':
          return await TboxModule.invoke(func, args, ctx);
        case 'quest':
          return await QuestModule.invoke(func, args, ctx);
        case 'hanaparts':
          return await HanaPartsModule.invoke(func, args, ctx);
        case 'tigertiger':
          return await TigerTigerModule.invoke(func, args, ctx);
        default:
          return PLACEHOLDER_MARK + 'Lua 模块 ' + module + ' 未实现（离线版暂不支持）' + '\u0000';
      }
    } catch (e) {
      Logger.warn(TAG, 'invoke failed: ' + module + '.' + func + ' ' + JSON.stringify(e));
      return PLACEHOLDER_MARK + '模块 ' + module + ' 执行出错' + '\u0000';
    }
  }
}
