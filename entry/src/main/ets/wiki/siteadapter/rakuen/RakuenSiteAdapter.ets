import { Logger } from '../../../common/Logger';
import { InvokeHandler, TemplateContext, PLACEHOLDER_MARK } from '../../template/TemplateEngine';
import { SiteAdapter } from '../SiteAdapter';
import { WikiSite } from '../../../model/WikiTypes';
import { EnemyModule } from './EnemyModule';
import { CollectionModule } from './CollectionModule';

const TAG = 'RakuenSiteAdapter';

/** 前端交互地图占位 div（multi-xb2map-collection）匹配：高亮物品名捕获组 */
const ITEM_MAP_DIV_RE = /<div[^>]*class="[^"]*xb2map-collection[^"]*"[^>]*data-highlight-collection-item="([^"]*)"[^>]*><\/div>/g;

/** 搜索直达排除的命名空间前缀：MediaWiki/SMW 标准设施（本地化名）+
 *  扩展命名空间（Gadget/JSON）+ 本站 Project 元页（免责声明/捐助等）。
 *  内容页（主命名空间与游戏数据命名空间）不受影响 */
const SEARCH_EXCLUDED_NS: string[] = [
  '文件:', '模板:', '模块:', '分类:', '属性:', 'MediaWiki:',
  '用户:', '用户讨论:', 'smw/schema:', 'Gadget:', 'Gadget definition:',
  'JSON:', '帮助:', '项目:', '乐园数据管理室:',
];

/**
 * rakuen-database（xenoblade2.cn 转储）站点适配器。
 * 该站点的 {{#invoke}} 模块以 ArkTS 移植实现注册于此；
 * 后续通用 Lua 虚拟机落地后，可替换为数据驱动实现而不动引擎。
 */
export class RakuenSiteAdapter implements SiteAdapter {
  readonly searchExcludedNs: string[] = SEARCH_EXCLUDED_NS;

  matches(site: WikiSite): boolean {
    return site.name === 'rakuen-database';
  }

  createInvokeHandler(): InvokeHandler | null {
    return new RakuenModuleHost();
  }

  /** 站点前端 JS 交互地图的占位 div → 离线版静态地图模块调用
   *  （div 在模板体内，一阶段展开后 {{FULLPAGENAME}} 已求值，此处改写后再展开一次） */
  rewriteWikitext(text: string): string {
    return text.replace(ITEM_MAP_DIV_RE, '{{#invoke:collection|itemMap|$1}}');
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
        default:
          return PLACEHOLDER_MARK + 'Lua 模块 ' + module + ' 未实现（离线版暂不支持）' + '\u0000';
      }
    } catch (e) {
      Logger.warn(TAG, 'invoke failed: ' + module + '.' + func + ' ' + JSON.stringify(e));
      return PLACEHOLDER_MARK + '模块 ' + module + ' 执行出错' + '\u0000';
    }
  }
}
