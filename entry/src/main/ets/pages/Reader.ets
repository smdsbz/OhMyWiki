import { AppStore } from '../common/AppStore';
import { Logger } from '../common/Logger';
import { WikiNode } from '../model/WikiTypes';
import { TemplateEngine, TemplateContext } from '../wiki/template/TemplateEngine';
import { ModuleHost } from '../wiki/module/ModuleHost';
import { SmwQueryEngine } from '../wiki/smw/SmwQueryEngine';
import { WikitextParser } from '../wiki/parser/WikitextParser';
import { WikiContentView } from '../wiki/render/WikiContentView';

const TAG = 'Reader';

/** Reader 路由参数：title 缺省为首页 */
export interface ReaderParams {
  siteKey: string;
  siteName: string;
  title?: string;
}

@Component
export struct Reader {
  @Prop siteKey: string = 'public';
  @Prop siteName: string = '';
  @Prop startTitle: string = '首页';
  @State pageTitle: string = '';
  @State nodes: WikiNode[] = [];
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State pageSeq: number = 0;
  private redirectDepth: number = 0;
  private pathStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.init(this.siteKey, this.siteName);
  }

  async init(siteKey: string, siteName: string): Promise<void> {
    try {
      const ok = await AppStore.openSiteByKeyName(siteKey, siteName);
      if (!ok) {
        this.errorMsg = '无法打开站点：' + siteName;
        this.loading = false;
        return;
      }
      await this.loadPage(this.startTitle);
    } catch (e) {
      Logger.error(TAG, 'init error: ' + JSON.stringify(e));
      this.errorMsg = '初始化失败：' + JSON.stringify(e);
      this.loading = false;
    }
  }

  async loadPage(title: string): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      const index = AppStore.getActiveIndex();
      if (index === null) {
        this.errorMsg = '索引未就绪';
        this.loading = false;
        return;
      }
      const raw = await index.readPage(title);
      if (raw === null) {
        this.pageTitle = title;
        this.nodes = [];
        this.errorMsg = '页面不存在：' + title;
        this.loading = false;
        return;
      }
      // 重定向
      if (this.redirectDepth < 5) {
        const rm = raw.match(/^\s*#REDIRECT\s*\[\[(.*?)\]\]/);
        if (rm !== null) {
          const target = rm[1].split('|')[0].trim();
          const resolved = index.resolveLink(target, title);
          if (resolved !== null) {
            this.redirectDepth++;
            await this.loadPage(resolved);
            this.redirectDepth--;
            return;
          }
        }
      }
      this.redirectDepth = 0;

      const ctx: TemplateContext = {
        pageTitle: title,
        index: index,
        invokeHandler: new ModuleHost(),
        askHandler: SmwQueryEngine.get(),
      };
      const engine = new TemplateEngine(ctx);
      const expanded = await engine.expand(raw);
      Logger.info(TAG, 'EXPANDED [' + title + ']:\n' + expanded);
      const finalText = await this.appendShopLocation(expanded, raw);
      const parser = new WikitextParser(index, title);
      const nodes = parser.parse(finalText);
      Logger.info(TAG, 'loadPage [' + title + '] nodes=' + nodes.length);
      Logger.info(TAG, 'NODES [' + title + ']: ' + JSON.stringify(nodes).substring(0, 3000));
      this.pageTitle = title;
      this.nodes = nodes;
      this.loading = false;
      this.pageSeq++;
    } catch (e) {
      Logger.error(TAG, 'loadPage error: ' + JSON.stringify(e));
      this.errorMsg = '渲染失败：' + JSON.stringify(e);
      this.loading = false;
    }
  }

  /** 跳转到 wiki 页面：压入新 NavDestination，自带转场动画且新页从顶部开始 */
  navigate(title: string): void {
    if (title.length === 0) {
      return;
    }
    const index = AppStore.getActiveIndex();
    if (index === null || !index.pageExists(title)) {
      return;
    }
    const params: ReaderParams = {
      siteKey: this.siteKey,
      siteName: this.siteName,
      title: title,
    };
    this.pathStack.pushPathByName('Reader', params);
  }

  back(): void {
    this.pathStack.pop();
  }

  goHome(): void {
    this.pathStack.popToName('Reader');
  }

  /** 异刃页增强：在信息框后追加「喜欢的物品获取地点」（商店 + 地区/位置） */
  private async appendShopLocation(expanded: string, raw: string): Promise<string> {
    if (raw.indexOf('{{BladeInfo') < 0) {
      return expanded;
    }
    const finder = AppStore.getShopFinder();
    if (finder === null) {
      return expanded;
    }
    const items: string[] = [];
    const m1 = raw.match(/\|\s*喜欢的物品1\s*=\s*([^\n|]+)/);
    if (m1 !== null) {
      items.push(this.cleanItemName(m1[1]));
    }
    const m2 = raw.match(/\|\s*喜欢的物品2\s*=\s*([^\n|]+)/);
    if (m2 !== null) {
      items.push(this.cleanItemName(m2[1]));
    }
    if (items.length === 0) {
      return expanded;
    }
    let section = '\n== 喜欢的物品获取地点 ==\n';
    for (const it of items) {
      if (it.length === 0) {
        continue;
      }
      const shops = await finder.find(it);
      section += '\n* ' + it + '：';
      if (shops.length === 0) {
        section += '未在商店数据中找到';
        continue;
      }
      const parts: string[] = [];
      for (const s of shops) {
        const ci = s.title.indexOf(':');
        const name = ci >= 0 ? s.title.substring(ci + 1) : s.title;
        const locParts: string[] = [];
        if (s.region.length > 0) {
          locParts.push(s.region);
        }
        if (s.location.length > 0) {
          locParts.push(s.location);
        }
        const loc = locParts.length > 0 ? '（' + locParts.join('・') + '）' : '';
        parts.push('[[' + s.title + '|' + name + ']]' + loc);
      }
      section += parts.join('／');
    }
    section += '\n';
    // 插到第一个二级标题前（信息框之后）；没有标题则追加到末尾
    const hi = expanded.indexOf('\n==');
    if (hi >= 0) {
      return expanded.substring(0, hi) + section + expanded.substring(hi);
    }
    return expanded + '\n' + section;
  }

  /** 清洗 BladeInfo 参数值（去 wikilink / 模板包裹） */
  private cleanItemName(v: string): string {
    let s = v.trim();
    const m = s.match(/\[\[([^\]|]*)/);
    if (m !== null) {
      s = m[1];
    }
    s = s.replace(/\{\{[^}]*\}\}/g, '').trim();
    return s;
  }

  private displayTitle(): string {
    if (this.pageTitle.length === 0) {
      return '';
    }
    const ci = this.pageTitle.indexOf(':');
    if (ci >= 0) {
      return this.pageTitle.substring(ci + 1);
    }
    return this.pageTitle;
  }

  build() {
    NavDestination() {
      Column() {
      // 顶栏
      Row() {
        Button('‹')
          .width(40)
          .height(40)
          .fontSize(24)
          .fontColor('#1c1c1e')
          .backgroundColor('#00000000')
          .onClick(() => {
            this.back();
          })
        Text(this.displayTitle())
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1c1c1e')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Button() {
          Image($r('app.media.ic_home'))
            .width(20)
            .height(20)
            .fillColor('#1c1c1e')
        }
        .width(40)
        .height(40)
        .padding(0)
        .backgroundColor('#00000000')
        .onClick(() => {
          this.goHome();
        })
      }
      .width('100%')
      .height(52)
      .padding({ left: 4, right: 4 })
      .backgroundColor('#ffffff')

      if (this.loading) {
        Column({ space: 8 }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color('#2f6fed')
          Text('加载页面…')
            .fontSize(13)
            .fontColor('#8a8a8e')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMsg.length > 0) {
        Column({ space: 10 }) {
          Text(this.errorMsg)
            .fontSize(14)
            .fontColor('#d0021b')
            .textAlign(TextAlign.Center)
            .padding(20)
          Button('返回首页')
            .fontSize(14)
            .backgroundColor('#2f6fed')
            .onClick(() => {
              this.goHome();
            })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            WikiContentView({ nodes: this.nodes, renderKey: this.pageSeq, onNavigate: (t: string): void => {
              this.navigate(t)
            } })
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 8, bottom: 32 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .align(Alignment.Top)
        .key('page_' + this.pageSeq)
      }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#ffffff')
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}
