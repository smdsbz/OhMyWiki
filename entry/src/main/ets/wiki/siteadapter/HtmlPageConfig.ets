/**
 * HTML 直渲染站点的声明式渲染配置（站点知识载体）。
 * HtmlParser 只认本接口，不内置任何站点概念；
 * 具体站点的类名/颜色/跳过规则全部由其 SiteAdapter 提供。
 */

/** 行内 class 样式叠加规则（一个元素可命中多条，效果合并） */
export interface HtmlInlineStyle {
  cls: string;
  /** 行内颜色 #rrggbb */
  color?: string;
  bold?: boolean;
  /** 字号（vp），如 <small> 语义用 12 */
  fontSize?: number;
}

/** class 命中 → 标题级别 */
export interface HtmlHeadingRule {
  cls: string;
  /** WikiNode.level（2 起，对齐 wikitext == 级） */
  level: number;
}

export interface HtmlPageConfig {
  /** 内容根元素 id（找不到时回退 body） */
  rootId: string;
  /** 命中 id 的元素整棵跳过 */
  skipIds: string[];
  /** 命中 tag 的元素整棵跳过 */
  skipTags: string[];
  /** 命中 class 的元素整棵跳过（站点控件/说明框，非响应式语义） */
  skipClasses: string[];
  /** 响应式隐藏类：当前视口（手机）不可见，整棵子树跳过 */
  hiddenClasses: string[];
  /** 页面级重复标题 tag（如 h2 = <title> 重复）整棵跳过 */
  skipHeadingTags: string[];
  /** tag → 标题级别 */
  headingTagLevels: Record<string, number>;
  /** class → 标题级别 */
  headingClassRules: HtmlHeadingRule[];
  /** 行内 class 样式（颜色/粗体/字号） */
  inlineClassStyles: HtmlInlineStyle[];
  /** 进度条 class → 条色（progress-bar 的颜色） */
  gaugeBarColors: Record<string, string>;
  /** 进度条无命中类时的默认色 */
  gaugeDefaultColor: string;
  /** 进度条外层容器 class（容器内找 bar 子元素，width% 为值） */
  gaugeContainerClass: string;
  /** 进度条 bar 元素 class */
  gaugeBarClass: string;
  /** 斩位多色段容器 class（子 span 色段文本点数为长度） */
  sharpnessClass: string;
  /** 站内页面链接白名单（作用于归一化后的站内相对路径） */
  internalPathPattern: RegExp;
  /** 图片路径前缀（src 归一化后剥掉此前缀存 fileName，保留子目录） */
  assetPrefix: string;
}
