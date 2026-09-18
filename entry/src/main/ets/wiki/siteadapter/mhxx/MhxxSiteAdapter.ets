import { SiteAdapter } from '../SiteAdapter';
import { WikiSite } from '../../../model/WikiTypes';
import { HtmlPageConfig, HtmlInlineStyle, HtmlHeadingRule } from '../HtmlPageConfig';

/**
 * monster-hunter-web-data（angrychocobo MHXX 攻略大全）站点适配器。
 * 站点为纯静态 HTML：由 scripts/monster-hunter-web-data/pack.py 从上游仓库
 * （github.com/AngryChocobo/monster-hunter-web-data）清洗打包成 HTML 转储
 * （pages/data|ida/*.html，manifest path=站内原路径），应用内 HtmlParser 直渲染。
 * 全部站点知识（类名/颜色/跳过规则/白名单）集中在下方配置，颜色取自原站 index.css。
 */
const MHXX_HTML_CONFIG: HtmlPageConfig = {
  rootId: 'main_1',
  skipIds: ['bread', 'navi1'],
  skipTags: ['script', 'style', 'noscript', 'head', 'meta', 'link', 'title',
    'input', 'select', 'option', 'iframe', 'ins', 'form', 'button'],
  // box2=JS 折叠控件、box_off/box_on=rank 切换按钮（离线无意义）；box1 是图例说明，保留渲染
  skipClasses: ['box2', 'box_off', 'box_on', 'adslot', 'pnl_base', 'panel_btn'],
  // 响应式（index.css 实证）：pc_only ≤767px 隐藏、pc2_only ≤479px 隐藏；手机视口两者皆隐藏
  hiddenClasses: ['pc_only', 'pc2_only'],
  // h2 = <title> 重复的页面标题
  skipHeadingTags: ['h2'],
  headingTagLevels: { 'h3': 2, 'h4': 3, 'h5': 4, 'h6': 4 },
  headingClassRules: [
    { cls: 'panel-heading', level: 2 } as HtmlHeadingRule,
  ],
  inlineClassStyles: [
    // 类色表（index.css，2026-09-14 验证）+ 粗体类
    { cls: 'c_g', color: '#008000' } as HtmlInlineStyle,
    { cls: 'gb', color: '#008000' } as HtmlInlineStyle,
    { cls: 'c_gb', color: '#008000', bold: true } as HtmlInlineStyle,
    { cls: 'c_p', color: '#9c27b0' } as HtmlInlineStyle,
    { cls: 'rp', color: '#9c27b0' } as HtmlInlineStyle,
    { cls: 'c_r', color: '#ff0000' } as HtmlInlineStyle,
    { cls: 'rb', color: '#ff0000' } as HtmlInlineStyle,
    { cls: 'c_b', color: '#666666' } as HtmlInlineStyle,
    { cls: 'c_bb', color: '#666666' } as HtmlInlineStyle,
    { cls: 'c_o', color: '#ffa500' } as HtmlInlineStyle,
    { cls: 'c_ob', color: '#ffa500', bold: true } as HtmlInlineStyle,
    { cls: 'b', bold: true } as HtmlInlineStyle,
    // 派生树符号（┗ ┣ ┃）小一号
    { cls: 'hasei', fontSize: 12 } as HtmlInlineStyle,
    // 斩位色段 kr0..kr7；kr5 原站白色（衬 #ccc 单元格底）白底不可见 → 浅灰
    { cls: 'kr0', color: '#bc0b43' } as HtmlInlineStyle,
    { cls: 'kr1', color: '#f45600' } as HtmlInlineStyle,
    { cls: 'kr2', color: '#ffc836' } as HtmlInlineStyle,
    { cls: 'kr3', color: '#4de200' } as HtmlInlineStyle,
    { cls: 'kr4', color: '#4068fa' } as HtmlInlineStyle,
    { cls: 'kr5', color: '#d0d0d0' } as HtmlInlineStyle,
    { cls: 'kr6', color: '#cc33cc' } as HtmlInlineStyle,
    { cls: 'kr7', color: '#555555' } as HtmlInlineStyle,
  ],
  // Bootstrap 进度条色（強さ双色条：绿=体力倍率、橙=全体防御率）
  gaugeBarColors: {
    'progress-bar-success': '#5cb85c',
    'progress-bar-warning': '#f0ad4e',
    'progress-bar-danger': '#d9534f',
  },
  gaugeDefaultColor: '#337ab7',
  gaugeContainerClass: 'progress',
  gaugeBarClass: 'progress-bar',
  sharpnessClass: 'kireage',
  // 站内页面白名单（与 pack.py PAGE_RE 一致；cat.html 是 2832 页的重复聚合页）
  internalPathPattern: /^(index\.html|(data|ida)\/\d+\.html)$/,
  assetPrefix: 'images/',
};

export class MhxxSiteAdapter implements SiteAdapter {
  matches(site: WikiSite): boolean {
    // html 转储（pack.py 产出）与历史 wikitext 转储目录名都可能存在
    return site.name === 'monster-hunter-web-data-html' || site.name === 'monster-hunter-web-data';
  }

  createInvokeHandler(): null {
    return null;
  }

  pageFormat: 'wikitext' | 'html' = 'html';
  htmlConfig: HtmlPageConfig = MHXX_HTML_CONFIG;
}
