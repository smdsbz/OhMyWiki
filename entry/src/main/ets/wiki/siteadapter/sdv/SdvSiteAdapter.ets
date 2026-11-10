import { Logger } from '../../../common/Logger';
import { InvokeHandler, TemplateContext, PLACEHOLDER_MARK } from '../../template/TemplateEngine';
import { HtmlBoxStyle, SiteAdapter } from '../SiteAdapter';
import { WikiSite } from '../../../model/WikiTypes';
import { CalcsellpriceModule, CalcgrangepointsModule, CalcedibilityModule,
  TcartpriceModule, BannerModule } from './SdvCalcModules';
import { NpcModule, NpcDispositionsModule } from './SdvNpcModules';
import { ItemsModule } from './SdvItemsModule';
import { ArrayModule, HatnoteModule, OverlayimgModule } from './SdvTextModules';
import { MapModule, TabsModule } from './SdvMapTabsModules';
import { GiftsByItemModule } from './SdvGiftsModule';

const TAG = 'SdvSiteAdapter';

/** 搜索排除：本站命名空间用英文规范名（Template:/Module:），中英别名都列（无害） */
const SEARCH_EXCLUDED_NS: string[] = [
  'File:', '文件:', 'Template:', '模板:', 'Module:', '模块:',
  'Category:', '分类:', 'Help:', '帮助:', 'MediaWiki:',
  'User:', '用户:', 'Template talk:', 'Module talk:',
];

/** 站点皮肤盒样式（Vector 皮肤 .wikitable 一族；验收期从 load.php 取证后校准） */
const SDV_BOX_STYLES: Map<string, HtmlBoxStyle> = new Map<string, HtmlBoxStyle>([
  ['wikitable', {
    bgLight: '#f8f9fa', bgDark: 'rgba(44,44,46,0.6)',
    borderLight: '#a2a9b1', borderDark: '#545456',
    radiusVp: 2, padVp: 6,
  }],
]);

/**
 * sdv-zh（zh.stardewvalleywiki.com 转储）站点适配器。
 * {{#invoke}} 模块以 ArkTS 移植实现分发（见 SdvModuleHost）。
 */
export class SdvSiteAdapter implements SiteAdapter {
  readonly searchExcludedNs: string[] = SEARCH_EXCLUDED_NS;
  readonly htmlBoxStyles: Map<string, HtmlBoxStyle> = SDV_BOX_STYLES;

  matches(site: WikiSite): boolean {
    return site.name === 'sdv-zh';
  }

  createInvokeHandler(): InvokeHandler | null {
    return new SdvModuleHost();
  }
}

/** 该站点的 #invoke 分发宿主：模块名 → ArkTS 实现；未实现返回占位 */
class SdvModuleHost implements InvokeHandler {
  async invoke(module: string, func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const lower = module.trim().toLowerCase();
    try {
      switch (lower) {
        case 'calcsellprice':
          return await CalcsellpriceModule.invoke(func, args, ctx);
        case 'calcgrangepoints':
          return await CalcgrangepointsModule.invoke(func, args, ctx);
        case 'calcedibility':
          return await CalcedibilityModule.invoke(func, args, ctx);
        case 'tcartprice':
          return await TcartpriceModule.invoke(func, args, ctx);
        case 'banner':
          return await BannerModule.invoke(func, args, ctx);
        case 'npc':
          return await NpcModule.invoke(func, args, ctx);
        case 'npcdispositions':
          return await NpcDispositionsModule.invoke(func, args, ctx);
        case 'items':
          return await ItemsModule.invoke(func, args, ctx);
        case 'array':
          return await ArrayModule.invoke(func, args, ctx);
        case 'hatnote':
          return await HatnoteModule.invoke(func, args, ctx);
        case 'overlayimg':
          return await OverlayimgModule.invoke(func, args, ctx);
        case 'map':
          return await MapModule.invoke(func, args, ctx);
        case 'tabs':
          return await TabsModule.invoke(func, args, ctx);
        case 'giftsbyitem':
          return await GiftsByItemModule.invoke(func, args, ctx);
        default:
          return PLACEHOLDER_MARK + 'Lua 模块 ' + module + ' 未实现（离线版暂不支持）' + '\u0000';
      }
    } catch (e) {
      Logger.warn(TAG, 'invoke failed: ' + module + '.' + func + ' ' + JSON.stringify(e));
      return PLACEHOLDER_MARK + '模块 ' + module + ' 执行出错' + '\u0000';
    }
  }
}
