import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, TextStyleMode, HdsListItemCard, SuffixArrow, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { LengthMetrics } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppStore } from '../common/AppStore';
import { Logger } from '../common/Logger';
import { Prefs } from '../common/Prefs';
import { WikiSite } from '../model/WikiTypes';
import { Reader, ReaderParams } from './Reader';

const TAG = 'Index';
/** 内容顶部让位量：ignoreLayoutSafeArea(TOP) 后视口含状态栏，
 *  需让出「状态栏+迷你标题栏」全高（实测 104vp → 内容起于 y316，栏底 304 之下） */
const TITLE_INSET_TOTAL: number = 104;

interface SiteItem {
  site: WikiSite;
  key: string;
}

@Entry
@Component
struct Index {
  private pathStack: NavPathStack = new NavPathStack();
  @State sites: SiteItem[] = [];
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State publicPath: string = '';
  @State publicDirReady: boolean = false;
  @State importing: boolean = false;
  @State importMsg: string = '';
  @State importProgress: number = 0;
  @State importFileName: string = '';
  /** 站点列表滚动控制器（HDS 标题栏滚动模糊绑定；Scroll 同 Reader） */
  private scroller: Scroller = new Scroller();


  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppStore.init(ctx);
    Prefs.init(ctx);
    this.publicPath = AppStore.getPublicDisplayPath();
    this.refresh();
  }

  async refresh(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      this.publicDirReady = await AppStore.ensurePublicDir();
      this.publicPath = AppStore.getPublicDisplayPath();
      const list = await AppStore.discoverSites();
      const items: SiteItem[] = [];
      for (const s of list) {
        items.push({ site: s, key: s.sourceKey + '/' + s.name });
      }
      this.sites = items;
      Logger.info(TAG, 'discovered ' + items.length + ' sites');
      await this.tryDebugJump(items);
    } catch (e) {
      this.errorMsg = '扫描失败：' + JSON.stringify(e);
      Logger.error(TAG, this.errorMsg);
    }
    this.loading = false;
  }

  /** 点击下载按钮（安全控件），通过 DOWNLOAD 模式保存获取公共下载目录持久化授权 */
  async grantPublicDirAccess(): Promise<void> {
    try {
      const options = new picker.DocumentSaveOptions();
      options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      options.newFileNames = ['.ohmywiki-setup'];
      const dp = new picker.DocumentViewPicker();
      const uris: string[] = await dp.save(options);
      if (uris.length > 0) {
        Prefs.putString(Prefs.KEY_FOLDER_URI, uris[0]);
        Logger.info(TAG, 'public dir granted: ' + uris[0]);
        this.publicPath = AppStore.getPublicDisplayPath();
        await this.refresh();
      }
    } catch (e) {
      const err = e as BusinessError;
      Logger.error(TAG, 'grantPublicDirAccess error: ' + JSON.stringify(err));
      this.errorMsg = '启用公共下载目录失败：' + JSON.stringify(err);
    }
  }

  /** 选择 wiki 压缩包并解压到公共下载目录 */
  async importWikiZip(): Promise<void> {
    // 先进入导入状态：进度条立即渲染（选完文件后无需再等一帧，避免回主页傻等几秒）
    this.importing = true;
    this.importProgress = 0;
    this.importFileName = '';
    this.importMsg = '正在选择 wiki 压缩包…';
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const dp = new picker.DocumentViewPicker();
      const uris: string[] = await dp.select(options);
      if (uris.length === 0) {
        // 用户取消选择，恢复主页
        this.importing = false;
        this.importMsg = '';
        return;
      }
      this.importMsg = '正在解压 wiki 压缩包…';
      // 让 UI 渲染 importing 状态（确保进度条先出现）
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, 50);
      });
      Logger.info(TAG, 'importWikiZip: importing=true');
      const dest = await AppStore.importWikiZip(uris[0], (done: number, total: number, name: string) => {
        this.importProgress = total > 0 ? Math.floor(done * 100 / total) : 0;
        this.importFileName = name;
      });
      Logger.info(TAG, 'importWikiZip: done dest=' + dest);
      // 先结束导入状态，再刷新站点列表（否则 importing 分支挡住刷新结果）
      this.importing = false;
      this.importMsg = '';
      await this.refresh();
      Logger.info(TAG, 'importWikiZip: refresh done');
      promptAction.showToast({ message: '导入成功：' + dest, duration: 2500 });
    } catch (e) {
      const err = e as BusinessError;
      Logger.error(TAG, 'importWikiZip catch: ' + JSON.stringify(err));
      this.importing = false;
      this.importMsg = '';
      try {
        promptAction.showToast({ message: '导入失败：' + JSON.stringify(err), duration: 3000 });
      } catch (e2) {
        Logger.error(TAG, 'showToast failed: ' + JSON.stringify(e2));
      }
    }
    Logger.info(TAG, 'importWikiZip: importing=false');
  }

  async openSite(item: SiteItem, startTitle?: string): Promise<void> {
    const ok = await AppStore.openSite(item.site);
    if (!ok) {
      this.errorMsg = '打开站点失败：' + item.site.name;
      return;
    }
    const params: ReaderParams = {
      siteKey: item.site.sourceKey,
      siteName: item.site.name,
      title: startTitle,
    };
    this.pathStack.pushPathByName('Reader', params);
  }

  /** 调试直达：EntryAbility 启动参数指定的页面，站点扫描完成后自动跳转（仅消费一次） */
  private async tryDebugJump(items: SiteItem[]): Promise<void> {
    const page = AppStorage.get<string>('debugJumpPage') ?? '';
    if (page.length === 0) {
      return;
    }
    AppStorage.setOrCreate('debugJumpPage', '');
    let target: SiteItem | null = items.length > 0 ? items[0] : null;
    if (target !== null) {
      Logger.info(TAG, 'debug jump -> ' + page);
      await this.openSite(target, page);
    }
  }

  build() {
    HdsNavigation(this.pathStack) {
      Column() {
      if (this.loading) {
        Column({ space: 8 }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color($r('sys.color.brand'))
          Text('正在扫描 Wiki 数据…')
            .fontSize(14)
            .fontColor($r('sys.color.font_tertiary'))
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.importing) {
        Column({ space: 12 }) {
          Text(this.importMsg)
            .fontSize(14)
            .fontColor($r('sys.color.font_tertiary'))
          Progress({ value: this.importProgress, total: 100, type: ProgressType.Linear })
            .width('70%')
            .color($r('sys.color.brand'))
            .backgroundColor($r('sys.color.comp_background_secondary'))
          Text(this.importProgress + '%')
            .fontSize(13)
            .fontColor($r('sys.color.brand'))
          if (this.importFileName.length > 0) {
            Text(this.importFileName)
              .fontSize(11)
              .fontColor($r('sys.color.font_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('70%')
          }
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll(this.scroller) {
          Column({ space: 12 }) {
            if (this.errorMsg.length > 0) {
              Text(this.errorMsg)
                .fontSize(13)
                .fontColor($r('app.color.error'))
                .padding(12)
            }

            if (this.sites.length === 0) {
              this.EmptyGuide()
            } else {
              Text(`共发现 ${this.sites.length} 个 Wiki 数据文件夹`)
                .fontSize(13)
                .fontColor($r('sys.color.font_tertiary'))
                .width('100%')
                .padding({ left: 16, right: 16 })

              ForEach(this.sites, (item: SiteItem) => {
                // HDS 系统列表卡片：标题/副标题/描述 + 右箭头，边距按压态由系统接管
                HdsListItemCard({
                  textItem: {
                    primaryText: { text: item.site.displayName },
                    // 存储属性（公共下载）与站点 id 同行
                    secondaryText: { text: `${item.site.name} · 公共下载` },
                    description: item.site.totalPages > 0
                      ? { text: `${item.site.totalPages} 个页面` }
                      : undefined
                  },
                  suffixItem: new SuffixArrow(),
                  onClick: (): void => {
                    this.openSite(item);
                  }
                })
              }, (item: SiteItem) => item.key)
            }

            if (this.importMsg.length > 0) {
              Text(this.importMsg)
                .fontSize(13)
                .fontColor(this.importMsg.startsWith('导入失败') ? $r('app.color.error') : $r('sys.color.brand'))
                .width('100%')
                .padding({ left: 16, right: 16, top: 4 })
            }
          }
          .width('100%')
          // 顶部让出「状态栏+标题栏」全高（ignoreLayoutSafeArea 后视口含状态栏）
          .padding({ top: TITLE_INSET_TOTAL, bottom: 32 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        // 内容短于视口时 Scroll 默认居中子组件——单站点时会把列表吊到屏幕中部，须顶部对齐
        .align(Alignment.Top)
        // 滚动视口本身延伸到物理屏幕底部：内容从半透明导航条下方滑过
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      }
      }
      .width('100%')
      .height('100%')
      // 页面背景对齐系统设置：comp_background_gray（浅 #F0F3F5 / 深 #000000）
      .backgroundColor($r('sys.color.comp_background_gray'))
      // 根容器背景延伸到导航条之下（内容视口的延伸由上方 Scroll 自己负责）
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    // HDS 系统标题栏：大标题 + 菜单（文字型按钮），滚动时标题栏动态模糊、大标题收起
    .titleBar({
      content: {
        title: { mainTitle: 'OhMyWiki' },
        menu: {
          value: [{
            content: {
              label: '导入',
              type: TextStyleMode.NORMAL,
              isEnabled: !this.importing,
              action: (): void => {
                this.importWikiZip();
              }
            }
          }, {
            content: {
              label: '刷新',
              type: TextStyleMode.NORMAL,
              action: (): void => {
                this.refresh();
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
          // maskExtraHeight 官方示例 56.0（蒙版延伸到栏外，衰减零点在栏下方）
          backgroundStyle: { backgroundColor: $r('sys.color.comp_background_gray'), blurRadius: 24, maskExtraHeight: 100 },
          // IMMERSIVE_GRADIENT_BLUR 默认标题为白色（图文沉浸场景假设），
          // 页面为浅灰底需显式改深色，否则白底白字
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
            menuStyle: { iconColor: $r('sys.color.font_primary'), textColor: $r('sys.color.font_primary') }
          }
        },
        scrollEffectStyle: {
          // maskExtraHeight 100：蒙版延伸到栏外，强模糊区覆盖全栏（含标题带）。
          // 注：背景板色渲染在内容图层之下，半透明纱罩罩不住内容文字（实测），勿再尝试
          backgroundStyle: { backgroundColor: Color.Transparent, blurRadius: 24, maskExtraHeight: 100 },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
            menuStyle: { iconColor: $r('sys.color.font_primary'), textColor: $r('sys.color.font_primary') }
          }
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    // 首页为导航栈根节点，无上级页面可返回：隐藏标题栏回退按钮
    .hideBackButton(true)
    // 官方沉浸式完整配方：TOP+BOTTOM 一起放行（示例如此搭配），使首页内容区
    // 与 Reader 一致地延伸进底部导航条之下
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindToScrollable([this.scroller])
    .mode(NavigationMode.Stack)
    .navDestination(this.PageMap)
  }

  @Builder
  PageMap(name: string, param: ESObject) {
    if (name === 'Reader') {
      Reader({
        siteKey: (param as ReaderParams).siteKey,
        siteName: (param as ReaderParams).siteName,
        startTitle: (param as ReaderParams).title ?? '首页'
      })
    }
  }

  @Builder
  EmptyGuide() {
    Column({ space: 10 }) {
      Text('未找到 Wiki 数据')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .margin({ top: 32 })

      Text('把 wiki 数据文件夹放进公共下载目录，每个顶层文件夹即一个 MediaWiki 站点（含 pages/ 与 images/）。')
        .fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
        .textAlign(TextAlign.Start)
        .lineHeight(22)
        .padding({ left: 24, right: 24 })

      // 授权提示：与使用方式正交，仅未授权时显示
      if (!this.publicDirReady) {
        this.GuideBlock('需要授权',
          '本应用需要访问公共下载目录才能读取或导入 wiki 数据。\n' +
          '点击下方按钮授权（仅首次需要，授权后自动生效）。')

        Button('授权访问公共下载目录')
          .height(48)
          .fontSize(16)
          .fontColor(Color.White)
          .backgroundColor($r('sys.color.brand'))
          .borderRadius(24)
          .padding({ left: 24, right: 24 })
          .onClick(() => {
            this.grantPublicDirAccess();
          })
      }

      // 使用方式：始终显示
      this.GuideBlock('方式一：公共下载目录',
        '1. 在手机「文件管理」中进入：我的手机 → ' + this.publicPath + '\n' +
        '2. 把 wiki 数据文件夹（如 rakuen-database）整体复制/移动到该目录下。\n' +
        '   提示：如果你已在 Download 根目录放了 rakuen-database，把它移进上面的文件夹即可。\n' +
        '3. 回到本应用点右上角「刷新」。')

      this.GuideBlock('方式二：导入 Wiki 压缩包',
        '1. 点击右上角「导入」按钮。\n' +
        '2. 在文件选择器中选择 wiki 数据压缩包（如 rakuen-database.zip）。\n' +
        '3. 应用会自动解压到公共下载目录并扫描站点。')
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 32 })
  }

  @Builder
  GuideBlock(title: string, body: string) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      Text(body)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .lineHeight(20)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(10)
  }
}