import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, TextStyleMode, HdsListItemCard, SuffixArrow } from '@kit.UIDesignKit';
import { picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppStore } from '../common/AppStore';
import { Logger } from '../common/Logger';
import { Prefs } from '../common/Prefs';
import { WikiSite } from '../model/WikiTypes';
import { Reader, ReaderParams } from './Reader';

const TAG = 'Index';
/** HDS 大标题（FULL 模式）标题栏高度：内容区需让出此高度，滚动时从模糊标题栏下方穿过 */
const TITLE_BAR_HEIGHT_FULL: number = 138;

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
  /** 站点列表滚动控制器（HDS 标题栏滚动模糊/大标题收起绑定） */
  private scroller: ListScroller = new ListScroller();

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
            .color($r('app.color.link'))
          Text('正在扫描 Wiki 数据…')
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.importing) {
        Column({ space: 12 }) {
          Text(this.importMsg)
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))
          Progress({ value: this.importProgress, total: 100, type: ProgressType.Linear })
            .width('70%')
            .color($r('app.color.link'))
            .backgroundColor($r('app.color.accent_bg'))
          Text(this.importProgress + '%')
            .fontSize(13)
            .fontColor($r('app.color.link'))
          if (this.importFileName.length > 0) {
            Text(this.importFileName)
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('70%')
          }
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 12, scroller: this.scroller }) {
          if (this.errorMsg.length > 0) {
            ListItem() {
              Text(this.errorMsg)
                .fontSize(13)
                .fontColor($r('app.color.error'))
                .padding(12)
            }
          }

          if (this.sites.length === 0) {
            ListItem() {
              this.EmptyGuide()
            }
          } else {
            ListItem() {
              Text(`共发现 ${this.sites.length} 个 Wiki 数据文件夹`)
                .fontSize(13)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .padding({ left: 16, right: 16 })
            }

            ForEach(this.sites, (item: SiteItem) => {
              ListItem() {
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
                  // 页面为 page_bg 纯白/纯黑（与 Reader 统一），卡片用 surface 衬托色保持可辨识
                  cardBackgroundColor: $r('app.color.surface'),
                  onClick: (): void => {
                    this.openSite(item);
                  }
                })
              }
            }, (item: SiteItem) => item.key)
          }

          if (this.importMsg.length > 0) {
            ListItem() {
              Text(this.importMsg)
                .fontSize(13)
                .fontColor(this.importMsg.startsWith('导入失败') ? $r('app.color.error') : $r('app.color.link'))
                .width('100%')
                .padding({ left: 16, right: 16, top: 4 })
            }
          }
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        // 顶部让出 HDS 大标题栏（FULL 模式 138vp）
        .padding({ top: TITLE_BAR_HEIGHT_FULL, bottom: 32 })
        // 滚动视口本身延伸到物理屏幕底部：内容从半透明导航条下方滑过
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      }
      }
      .width('100%')
      .height('100%')
      // 页面背景与站点页（Reader）统一为 page_bg：窗口底色即 page_bg，状态栏区域无接缝
      .backgroundColor($r('app.color.page_bg'))
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
      }
    })
    .titleMode(HdsNavigationTitleMode.FULL)
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
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 32 })

      Text('把 wiki 数据文件夹放进公共下载目录，每个顶层文件夹即一个 MediaWiki 站点（含 pages/ 与 images/）。')
        .fontSize(14)
        .fontColor($r('app.color.text_body'))
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
          .fontColor($r('app.color.page_bg'))
          .backgroundColor($r('app.color.link'))
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
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text(body)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(20)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(10)
  }
}