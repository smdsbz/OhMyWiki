import { InvokeHandler } from '../template/TemplateEngine';
import { WikiSite } from '../../model/WikiTypes';

/**
 * 站点适配器：提供某站点自身所需的能力（Lua 模块实现等）。
 * 引擎主流程只依赖本接口，不感知任何具体站点概念；
 * 站点特有实现放在 siteadapter/<站点名>/ 目录下，由工厂按站点构造。
 */
export interface SiteAdapter {
  /** 是否适用于该站点（识别规则由适配器自定：站点名/数据特征等） */
  matches(site: WikiSite): boolean;
  /** 创建该站点的 {{#invoke:模块|函数|...}} 处理器；null 表示无模块能力（#invoke 走占位） */
  createInvokeHandler(): InvokeHandler | null;
  /** 站点 wikitext 重写（可选，默认原样返回）：在一阶段模板展开后调用，
   *  用于把站点特有的前端组件占位（如交互地图 div）改写为 #invoke 模块调用 */
  rewriteWikitext?(text: string): string;
  /** 搜索直达排除的命名空间前缀（可选，默认不过滤）：站点自行声明哪些命名空间
   *  是基础设施（模板/模块/文件/数据页等），引擎不内置任何站点知识 */
  searchExcludedNs?: string[];
}

/**
 * 站点适配器工厂（注册表模式）。
 * 适配包在应用初始化时自注册（见 AppStore.init 的挂载点）；
 * 打开站点时 forSite() 选出适配器，引擎据此获得站点能力。
 */
export class SiteAdapterFactory {
  private static adapters: SiteAdapter[] = [];

  static register(adapter: SiteAdapter): void {
    SiteAdapterFactory.adapters.push(adapter);
  }

  static forSite(site: WikiSite): SiteAdapter | null {
    for (const a of SiteAdapterFactory.adapters) {
      if (a.matches(site)) {
        return a;
      }
    }
    return null;
  }
}
