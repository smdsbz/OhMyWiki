import { HdsNavDestination, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { LengthMetrics, KeyboardAvoidMode } from '@kit.ArkUI';
import { AppStore } from '../common/AppStore';
import { Logger } from '../common/Logger';
import { ReaderParams } from './Reader';

const TAG = 'SearchPage';
/** 单次搜索结果上限：列表够长又不至于卡顿 */
const RESULT_LIMIT: number = 50;
/** 标题栏全高（状态栏+迷你标题栏，ignoreLayoutSafeArea 后内容让位量，与 Reader 一致） */
const TITLE_INSET: number = 104;
/** 结果行文字与分隔线的统一水平缩进 */
const ROW_INSET: number = 16;

interface ResultItem {
  title: string;
  key: string;
}

/** 站内页面搜索：顶栏放大镜进入，按标题搜索并直达。
 *  输入条内嵌于 HDS 标题栏（stackBuilder 自定义区，官方推荐做法），
 *  标题栏与 Reader 同款液态玻璃配方 */
@Component
export struct SearchPage {
  @Prop siteKey: string = 'public';
  @Prop siteName: string = '';
  @State query: string = '';
  @State results: ResultItem[] = [];
  @State indexReady: boolean = false;
  /** 当前按压的结果行下标（-1 无）：整行按压高亮 */
  @State pressedIdx: number = -1;
  private pathStack: NavPathStack = new NavPathStack();
  /** 结果列表滚动控制器（HDS 标题栏滚动模糊绑定） */
  private listScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.ensureIndex();
    // 键盘避让用压缩模式（默认为整页上抬）：内容区高度被压缩到键盘上方，
    // 列表底缘自动避让输入法，藏在键盘后的末尾条目可滚动可见、可点击
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
  }

  aboutToDisappear(): void {
    // 还原默认上抬模式，不影响其他页面
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
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


  /** 标题栏自定义区：搜索输入条（TextInput 自绘，padding 完全可控、左右对称；
   *  无背景无图标，融于玻璃顶栏；即时搜索，带清除按钮） */
  @Builder
  SearchBarBuilder() {
    Row() {
      TextInput({ text: this.query, placeholder: '搜索页面名称…' })
        .onChange((v: string) => {
          this.query = v;
          this.doSearch();
        })
        .onSubmit(() => {
          this.submitFirst();
        })
        .enterKeyType(EnterKeyType.Search)
        .defaultFocus(true)
        .height(40)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .backgroundColor(Color.Transparent)
        .underlineColor(Color.Transparent)
        .borderRadius(20)
        .padding({ left: 4, right: 4 })
        .layoutWeight(1)
        .margin({ top: 1 })
      if (this.query.length > 0) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor([$r('sys.color.font_tertiary')])
          // 细线图标比左侧实心返回按钮更贴边，右侧多留呼吸（视觉等距）
          .padding({ left: 4, right: 10 })
          .onClick(() => {
            this.query = '';
            this.results = [];
          })
      }
    }
    .width('100%')
    .height(40)
    .padding({ left: 64, right: 8 })
  }

  build() {
    HdsNavDestination() {
      Column() {
        if (this.query.trim().length === 0) {
          Column({ space: 8 }) {
            Text('按名称搜索站内页面')
              .fontSize(14)
              .fontColor($r('sys.color.font_tertiary'))
            Text('支持命名空间内匹配，如输入「铃铛蔓越莓」直达物品页')
              .fontSize(12)
              .fontColor($r('sys.color.font_fourth'))
          }
          .width('100%')
          .height('80%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: TITLE_INSET })
        } else if (this.results.length === 0) {
          Column() {
            Text('没有匹配「' + this.query.trim() + '」的页面')
              .fontSize(14)
              .fontColor($r('sys.color.font_tertiary'))
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .padding({ top: TITLE_INSET })
        } else {
          List({ scroller: this.listScroller }) {
            ForEach(this.results, (r: ResultItem, idx: number) => {
              ListItem() {
                // 自绘行：文字 inset 对齐分隔线；按压高亮整行（backgroundColor 含 padding 区）；
                // 跳页前复位按压态，避免返回时残留
                Row() {
                  Text(r.title)
                    .fontSize(16)
                    .fontWeight(FontWeight.Normal)
                    .fontColor($r('sys.color.font_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .padding({ left: ROW_INSET, right: ROW_INSET, top: 12, bottom: 12 })
                .backgroundColor(this.pressedIdx === idx
                  ? $r('app.color.search_row_pressed') : Color.Transparent)
                .onTouch((e: TouchEvent) => {
                  if (e.type === TouchType.Down) {
                    this.pressedIdx = idx;
                  } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                    this.pressedIdx = -1;
                  }
                })
                .onClick(() => {
                  this.pressedIdx = -1;
                  this.openTitle(r.title);
                })
              }
            }, (r: ResultItem) => r.key)
          }
          .layoutWeight(1)
          // 内容起始偏移让位标题栏：内容可从玻璃顶栏下方滚过（触发动态模糊），
          // 但不产生占位条目——避免首条前多出空白与分隔线
          .contentStartOffset(TITLE_INSET)
          // 末端避让底部系统导航条（~32vp）+ 呼吸空隙：滚动到底时最后条目完整可见
          .contentEndOffset(40)
          .divider({
            strokeWidth: 0.5,
            color: $r('sys.color.comp_divider'),
            startMargin: ROW_INSET,
            endMargin: ROW_INSET
          })
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.comp_background_gray'))
      // 滚动视口延伸到物理屏幕底部：内容从半透明导航条下方滑过
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    // HDS 系统标题栏：搜索输入条内嵌于标题行（stackBuilder），
    // 返回按钮/玻璃材质与 Reader 一致；列表从玻璃顶栏下方穿过（ignoreLayoutSafeArea）
    .titleBar({
      content: {
        title: { mainTitle: '' },
        stackBuilder: (): void => {
          this.SearchBarBuilder()
        }
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(20),
          blurEffectiveEndOffset: LengthMetrics.vp(60)
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        },
        blurStrategy: BlurStrategy.ENABLE,
        originalStyle: {
          backgroundStyle: { backgroundColor: $r('sys.color.comp_background_gray'), blurRadius: 12, maskExtraHeight: 24 },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
            menuStyle: { iconColor: $r('sys.color.font_primary'), textColor: $r('sys.color.font_primary') },
            backIconStyle: { iconColor: $r('sys.color.font_primary') }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: { backgroundColor: Color.Transparent, blurRadius: 12, maskExtraHeight: 24 },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
            menuStyle: { iconColor: $r('sys.color.font_primary'), textColor: $r('sys.color.font_primary') },
            backIconStyle: { iconColor: $r('sys.color.font_primary') }
          }
        }
      }
    })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindToScrollable([this.listScroller])
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}
