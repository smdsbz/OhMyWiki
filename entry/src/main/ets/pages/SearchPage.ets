import { HdsNavDestination } from '@kit.UIDesignKit';
import { AppStore } from '../common/AppStore';
import { Logger } from '../common/Logger';
import { ReaderParams } from './Reader';

const TAG = 'SearchPage';
/** 单次搜索结果上限：列表够长又不至于卡顿 */
const RESULT_LIMIT: number = 50;

interface ResultItem {
  title: string;
  key: string;
}

/** 站内页面搜索：顶栏放大镜进入，按标题搜索并直达 */
@Component
export struct SearchPage {
  @Prop siteKey: string = 'public';
  @Prop siteName: string = '';
  @State query: string = '';
  @State results: ResultItem[] = [];
  @State indexReady: boolean = false;
  private pathStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.ensureIndex();
  }

  /** 站点索引懒加载：正常从 Reader 进入时站点已打开，冷启动直达时兜底 */
  private async ensureIndex(): Promise<void> {
    if (AppStore.getActiveIndex() !== null) {
      this.indexReady = true;
      return;
    }
    const ok = await AppStore.openSiteByKeyName(this.siteKey, this.siteName);
    this.indexReady = ok;
    if (!ok) {
      Logger.warn(TAG, 'open site failed: ' + this.siteName);
    }
  }

  private doSearch(): void {
    if (!this.indexReady) {
      this.ensureIndex();
      return;
    }
    const index = AppStore.getActiveIndex();
    if (index === null) {
      this.results = [];
      return;
    }
    const titles = index.searchTitles(this.query, RESULT_LIMIT,
      AppStore.getActiveAdapter()?.searchExcludedNs);
    const items: ResultItem[] = [];
    for (const t of titles) {
      items.push({ title: t, key: t });
    }
    this.results = items;
  }

  /** 键盘「搜索」：直达首个结果 */
  private submitFirst(): void {
    if (this.results.length > 0) {
      this.openTitle(this.results[0].title);
    }
  }

  private openTitle(title: string): void {
    const params: ReaderParams = {
      siteKey: this.siteKey,
      siteName: this.siteName,
      title: title,
    };
    this.pathStack.pushPathByName('Reader', params);
  }

  private nsOf(title: string): string {
    const ci = title.indexOf(':');
    return ci >= 0 ? title.substring(0, ci + 1) : '';
  }

  private nameOf(title: string): string {
    const ci = title.indexOf(':');
    return ci >= 0 ? title.substring(ci + 1) : title;
  }

  build() {
    HdsNavDestination() {
      Column() {
        Search({ placeholder: '输入页面名称…', value: this.query })
          .onChange((v: string) => {
            this.query = v;
            this.doSearch();
          })
          .onSubmit(() => {
            this.submitFirst();
          })
          .searchButton('搜索')
          .defaultFocus(true)
          .height(40)
          .backgroundColor($r('sys.color.comp_background_primary'))
          .margin({ left: 16, right: 16, top: 10 })
          .padding({ left: 12, right: 12 })

        if (this.query.trim().length === 0) {
          Column({ space: 8 }) {
            Text('按名称搜索站内页面')
              .fontSize(14)
              .fontColor($r('sys.color.font_tertiary'))
            Text('支持命名空间内匹配，如输入「铃铛蔓越莓」直达物品页')
              .fontSize(12)
              .fontColor($r('sys.color.font_fourth'))
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.results.length === 0) {
          Column() {
            Text('没有匹配「' + this.query.trim() + '」的页面')
              .fontSize(14)
              .fontColor($r('sys.color.font_tertiary'))
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List() {
            ForEach(this.results, (r: ResultItem) => {
              ListItem() {
                Row({ space: 6 }) {
                  if (this.nsOf(r.title).length > 0) {
                    Text(this.nsOf(r.title))
                      .fontSize(13)
                      .fontColor($r('sys.color.font_tertiary'))
                  }
                  Text(this.nameOf(r.title))
                    .fontSize(16)
                    .fontColor($r('sys.color.font_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .onClick(() => {
                  this.openTitle(r.title);
                })
              }
            }, (r: ResultItem) => r.key)
          }
          .layoutWeight(1)
          .divider({
            strokeWidth: 0.5,
            color: $r('sys.color.comp_divider'),
            startMargin: 16,
            endMargin: 16
          })
          .scrollBar(BarState.Auto)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.comp_background_gray'))
      // 与 Reader 同款让位：ignoreLayoutSafeArea 后视口含状态栏，内容让出「状态栏+迷你标题栏」全高
      .padding({ top: 104 })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .titleBar({
      content: {
        title: { mainTitle: '搜索' }
      },
      style: {
        originalStyle: {
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
            menuStyle: { iconColor: $r('sys.color.font_primary'), textColor: $r('sys.color.font_primary') },
            backIconStyle: { iconColor: $r('sys.color.font_primary') }
          }
        }
      }
    })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}
