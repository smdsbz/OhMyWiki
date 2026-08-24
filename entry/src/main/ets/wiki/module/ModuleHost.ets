import { Logger } from '../../common/Logger';
import { InvokeHandler, TemplateContext, PLACEHOLDER_MARK } from '../template/TemplateEngine';
import { EnemyModule } from './EnemyModule';

const TAG = 'ModuleHost';

/**
 * Lua 模块宿主：把 {{#invoke:模块|函数|...}} 分发到 ArkTS 实现的模块。
 * 已实现：Enemy（基础统计）；未实现的返回占位。
 */
export class ModuleHost implements InvokeHandler {
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
