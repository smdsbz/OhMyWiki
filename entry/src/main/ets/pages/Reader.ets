import { HdsNavDestination, TextStyleMode, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { LengthMetrics } from '@kit.ArkUI';
import { AppStore } from '../common/AppStore';
import { Logger } from '../common/Logger';
import { WikiIndex } from '../data/WikiIndex';
import { WikiNode } from '../model/WikiTypes';
import { TemplateEngine, TemplateContext, PendingAsk, PLACEHOLDER_MARK } from '../wiki/template/TemplateEngine';
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
  /** 渐进渲染阶段 2 协程令牌：递增使旧协程失效 */
  private askRunId: number = 0;
  @State progressDone: number = 0;
  @State progressTotal: number = 0;
  /** 阶段 2（后台 #ask 回填）进行中：顶栏下方显示细进度条 */
  @State asking: boolean = false;
  /** 内容滚动控制器（HDS 标题栏滚动模糊绑定） */
  private scroller: Scroller = new Scroller();
  private redirectDepth: number = 0;
  private pathStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.init(this.siteKey, this.siteName);
  }

  /** 页面销毁（pop 返回）时使阶段 2 协程失效，终止后台全站扫描（防孤儿协程堆积） */
  aboutToDisappear(): void {
    this.askRunId++;
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
    this.progressDone = 0;
    this.progressTotal = 0;
    // 标题先行：HDS 标题栏在加载期间即显示目标页名
    this.pageTitle = title;
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

      const pending: PendingAsk[] = [];
      const ctx: TemplateContext = {
        pageTitle: title,
        index: index,
        invokeHandler: AppStore.getActiveInvokeHandler(),
        askHandler: SmwQueryEngine.get(),
        lazyAsk: true,
        pendingAsks: pending,
      };
      const engine = new TemplateEngine(ctx);
      const expanded = await engine.expand(raw);
      Logger.info(TAG, 'EXPANDED [' + title + ']:\n' + expanded);
      const finalText = expanded;
      const parser = new WikitextParser(index, title);
      const nodes = parser.parse(finalText);
      Logger.info(TAG, 'loadPage [' + title + '] nodes=' + nodes.length);
      Logger.info(TAG, 'NODES [' + title + ']: ' + JSON.stringify(nodes).substring(0, 3000));
      this.pageTitle = title;
      this.nodes = nodes;
      this.loading = false;
      this.pageSeq++;
      // 阶段 2：后台执行惰性登记的查询，完成后回填刷新（渐进渲染）
      if (pending.length > 0) {
        this.runPendingAsks(title, index, expanded, pending);
      }
    } catch (e) {
      Logger.error(TAG, 'loadPage error: ' + JSON.stringify(e));
      this.errorMsg = '渲染失败：' + JSON.stringify(e);
      this.loading = false;
    }
  }

  /** 渐进渲染阶段 2：后台逐条执行惰性 #ask/#show，回填占位标记后一次性重新渲染。
   *  askRunId 防重入：用户跳转到新页后旧协程丢弃结果 */
  private async runPendingAsks(title: string, index: WikiIndex, expanded: string,
    pending: PendingAsk[]): Promise<void> {
    this.askRunId++;
    const runId = this.askRunId;
    this.asking = true;
    this.progressDone = 0;
    this.progressTotal = 0;
    let text = expanded;
    const ctx: TemplateContext = {
      pageTitle: title,
      index: index,
      invokeHandler: AppStore.getActiveInvokeHandler(),
      askHandler: SmwQueryEngine.get(),
      cancelled: (): boolean => this.askRunId !== runId,
      onProgress: (done: number, total: number): void => {
        this.progressDone = done;
        this.progressTotal = total;
      },
    };
    try {
      for (const pa of pending) {
        if (this.askRunId !== runId) {
          Logger.info(TAG, 'runPendingAsks [' + title + '] cancelled, ask #' + pa.id + '/' + pending.length);
          return;
        }
        let result = '';
        try {
          result = await SmwQueryEngine.get().query(pa.args, ctx, pa.isShow);
        } catch (e) {
          Logger.warn(TAG, 'pending ask failed #' + pa.id + ' ' + JSON.stringify(e));
        }
        const mark = PLACEHOLDER_MARK + 'ASK:' + pa.id + '\u0000';
        // 块级结果（#ask 表格）前后补换行：同一行多个结果拼接时不粘连
        //（`|}{|` 会破坏表格解析，`</div>` 需独占行才能闭合容器）；
        // #show 内联值不补，避免句中断行被折成空格
        const pad = pa.isShow ? '' : '\n';
        text = text.split(mark).join(pad + result + pad);
      }
      if (this.askRunId !== runId) {
        Logger.info(TAG, 'runPendingAsks [' + title + '] cancelled before render');
        return;
      }
      const parser = new WikitextParser(index, title);
      this.nodes = parser.parse(text);
      this.pageSeq++;
      Logger.info(TAG, 'runPendingAsks [' + title + '] done, asks=' + pending.length);
    } finally {
      this.asking = false;
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

  goHome(): void {
    this.pathStack.popToName('Reader');
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
    HdsNavDestination() {
      Column() {
      if (this.loading) {
        Column({ space: 10 }) {
          if (this.progressTotal >= 30) {
            // 大查询：进度条 + 计数
            Progress({ value: this.progressDone, total: this.progressTotal, type: ProgressType.Linear })
              .width('70%')
              .height(6)
              .color($r('sys.color.brand'))
              .backgroundColor($r('sys.color.comp_background_secondary'))
            Text(`正在筛选 ${this.progressDone}/${this.progressTotal} 个页面…`)
              .fontSize(13)
              .fontColor($r('sys.color.font_tertiary'))
          } else {
            LoadingProgress()
              .width(40)
              .height(40)
              .color($r('sys.color.brand'))
            Text('加载页面…')
              .fontSize(13)
              .fontColor($r('sys.color.font_tertiary'))
          }
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMsg.length > 0) {
        Column({ space: 10 }) {
          Text(this.errorMsg)
            .fontSize(14)
            .fontColor($r('app.color.error'))
            .textAlign(TextAlign.Center)
            .padding(20)
          Button('返回首页')
            .fontSize(14)
            .fontColor(Color.White)
            .backgroundColor($r('sys.color.brand'))
            .onClick(() => {
              this.goHome();
            })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Column() {
          Scroll(this.scroller) {
            Column() {
              // 阶段 2 后台查询进度（非阻塞细条，随内容滚动，查询期间页面仍可阅读）
              if (this.asking) {
                Row({ space: 8 }) {
                  if (this.progressTotal > 0) {
                    Progress({ value: this.progressDone, total: this.progressTotal, type: ProgressType.Linear })
                      .layoutWeight(1)
                      .height(4)
                      .color($r('sys.color.brand'))
                      .backgroundColor($r('sys.color.comp_background_secondary'))
                    Text(`${this.progressDone}/${this.progressTotal} 页`)
                      .fontSize(11)
                      .fontColor($r('sys.color.font_tertiary'))
                  } else {
                    LoadingProgress()
                      .width(16)
                      .height(16)
                      .color($r('sys.color.brand'))
                    Text('正在查询…')
                      .fontSize(11)
                      .fontColor($r('sys.color.font_tertiary'))
                  }
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 2, bottom: 6 })
              }
              WikiContentView({ nodes: this.nodes, renderKey: this.pageSeq, onNavigate: (t: string): void => {
                this.navigate(t)
              } })
            }
            .width('100%')
            // 顶部让出「状态栏+迷你标题栏」全高（ignoreLayoutSafeArea 后视口含状态栏，
            // 实测 104vp → 内容起于 y316；滚动时内容从模糊标题栏下方穿过）
            .padding({ left: 14, right: 14, top: 104, bottom: 32 })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .align(Alignment.Top)
          .key('page_' + this.pageSeq)
          // 滚动视口本身延伸到物理屏幕底部：内容从半透明导航条下方滑过
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        }
        .layoutWeight(1)
      }
      }
      .width('100%')
      .height('100%')
      // 页面背景对齐系统设置：comp_background_gray（浅 #F0F3F5 / 深 #000000）
      .backgroundColor($r('sys.color.comp_background_gray'))
      // 根容器背景延伸到导航条之下（内容视口的延伸由上方 Scroll 自己负责）
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    // HDS 系统标题栏：返回按钮/标题/菜单由系统样式接管，滚动时标题栏动态模糊
    .titleBar({
      content: {
        title: { mainTitle: this.displayTitle() },
        menu: {
          value: [{
            content: {
              label: '首页',
              type: TextStyleMode.NORMAL,
              action: (): void => {
                this.goHome();
              }
            }
          }]
        }
      },
      style: {
        // 官方沉浸式完整配方（指令要求强制最高档，无降级）：
        // IMMERSIVE_GRADIENT_BLUR + 液态玻璃材质 IMMERSIVE/EXQUISITE（精致，最高级）
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
          // 过渡窗口 20→60vp：静止时保持纯净 originalStyle（默认 0 起步会让
          // 材质尾带在零滚动时就罩住栏下首行内容）
          blurEffectiveStartOffset: LengthMetrics.vp(20),
          blurEffectiveEndOffset: LengthMetrics.vp(60)
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        },
        blurStrategy: BlurStrategy.ENABLE,
        originalStyle: {
          // 对齐官方默认：blurRadius 配 systemMaterialEffect 时默认 12.0；
          backgroundStyle: { backgroundColor: $r('sys.color.comp_background_gray'), blurRadius: 12, maskExtraHeight: 24 },
          // IMMERSIVE_GRADIENT_BLUR 默认标题为白色（图文沉浸场景假设），
          // 页面为浅灰底需显式改深色，否则白底白字
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
            menuStyle: { iconColor: $r('sys.color.font_primary'), textColor: $r('sys.color.font_primary') },
            backIconStyle: { iconColor: $r('sys.color.font_primary') }
          }
        },
        scrollEffectStyle: {
          // 注：背景板色渲染在内容图层之下，半透明纱罩罩不住内容文字（实测），勿再尝试
          backgroundStyle: { backgroundColor: Color.Transparent, blurRadius: 12, maskExtraHeight: 24 },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
            menuStyle: { iconColor: $r('sys.color.font_primary'), textColor: $r('sys.color.font_primary') },
            backIconStyle: { iconColor: $r('sys.color.font_primary') }
          }
        }
      }
    })
    // 官方沉浸式配方：放行安全区，内容才能延伸进底部导航条之下
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindToScrollable([this.scroller])
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}
