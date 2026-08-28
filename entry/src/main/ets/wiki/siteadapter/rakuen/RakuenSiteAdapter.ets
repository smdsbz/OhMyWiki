import { Logger } from '../../../common/Logger';
import { InvokeHandler, TemplateContext, PLACEHOLDER_MARK } from '../../template/TemplateEngine';
import { SiteAdapter } from '../SiteAdapter';
import { WikiSite } from '../../../model/WikiTypes';
import { EnemyModule } from './EnemyModule';

const TAG = 'RakuenSiteAdapter';

/**
 * rakuen-database（xenoblade2.cn 转储）站点适配器。
 * 该站点的 {{#invoke}} 模块以 ArkTS 移植实现注册于此；
 * 后续通用 Lua 虚拟机落地后，可替换为数据驱动实现而不动引擎。
 */
export class RakuenSiteAdapter implements SiteAdapter {
  matches(site: WikiSite): boolean {
    return site.name === 'rakuen-database';
  }

  createInvokeHandler(): InvokeHandler | null {
    return new RakuenModuleHost();
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
        default:
          return PLACEHOLDER_MARK + 'Lua 模块 ' + module + ' 未实现（离线版暂不支持）' + '\u0000';
      }
    } catch (e) {
      Logger.warn(TAG, 'invoke failed: ' + module + '.' + func + ' ' + JSON.stringify(e));
      return PLACEHOLDER_MARK + '模块 ' + module + ' 执行出错' + '\u0000';
    }
  }
}
