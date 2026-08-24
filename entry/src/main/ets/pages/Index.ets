import { common } from '@kit.AbilityKit';
import { DownloadFileButton, DownloadIconStyle, DownloadDescription, DownloadLayoutDirection, promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppStore } from '../common/AppStore';
import { Logger } from '../common/Logger';
import { Prefs } from '../common/Prefs';
import { WikiSite } from '../model/WikiTypes';
import { Reader, ReaderParams } from './Reader';

const TAG = 'Index';

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
  @State sandboxPath: string = '';
  @State publicPath: string = '';
  @State importing: boolean = false;
  @State importMsg: string = '';
  @State importProgress: number = 0;
  @State importFileName: string = '';

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppStore.init(ctx);
    Prefs.init(ctx);
    this.sandboxPath = AppStore.getSandboxPath();
    this.publicPath = AppStore.getPublicDisplayPath();
    this.refresh();
  }

  async refresh(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      await AppStore.ensurePublicDir();
      this.publicPath = AppStore.getPublicDisplayPath();
      const list = await AppStore.discoverSites();
      const items: SiteItem[] = [];
      for (const s of list) {
        items.push({ site: s, key: s.sourceKey + '/' + s.name });
      }
      this.sites = items;
      Logger.info(TAG, 'discovered ' + items.length + ' sites');
    } catch (e) {
      this.errorMsg = '扫描失败：' + JSON.stringify(e);
      Logger.error(TAG, this.errorMsg);
    }
    this.loading = false;
  }

  /** 点击下载按钮（安全控件），通过 DOWNLOAD 模式保存获取公共下载目录持久化授权 */
  async setupPublicDir(): Promise<void> {
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
      Logger.error(TAG, 'setupPublicDir error: ' + JSON.stringify(err));
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
      promptAction.showToast({ message: '导入失败：' + JSON.stringify(err), duration: 3000 });
    }
    Logger.info(TAG, 'importWikiZip: importing=false');
  }

  async openSite(item: SiteItem): Promise<void> {
    const ok = await AppStore.openSite(item.site);
    if (!ok) {
      this.errorMsg = '打开站点失败：' + item.site.name;
      return;
    }
    const params: ReaderParams = {
      siteKey: item.site.sourceKey,
      siteName: item.site.name,
    };
    this.pathStack.pushPathByName('Reader', params);
  }

  sourceBadgeText(key: string): string {
    return key === 'public' ? '公共下载' : '沙箱';
  }

  build() {
    Navigation(this.pathStack) {
      Column() {
      // 标题栏
      Row() {
        Text('OhMyWiki')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1c1c1e')
        Blank()
        Button('导入')
          .height(36)
          .fontSize(14)
          .fontColor('#2f6fed')
          .backgroundColor('#e8f0fe')
          .margin({ right: 8 })
          .enabled(!this.importing)
          .onClick(() => {
            this.importWikiZip();
          })
        Button('刷新')
          .height(36)
          .fontSize(14)
          .backgroundColor('#2f6fed')
          .onClick(() => {
            this.refresh();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor('#ffffff')

      if (this.loading) {
        Column({ space: 8 }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color('#2f6fed')
          Text('正在扫描 Wiki 数据…')
            .fontSize(14)
            .fontColor('#8a8a8e')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.importing) {
        Column({ space: 12 }) {
          Text(this.importMsg)
            .fontSize(14)
            .fontColor('#8a8a8e')
          Progress({ value: this.importProgress, total: 100, type: ProgressType.Linear })
            .width('70%')
            .color('#2f6fed')
            .backgroundColor('#e8f0fe')
          Text(this.importProgress + '%')
            .fontSize(13)
            .fontColor('#2f6fed')
          if (this.importFileName.length > 0) {
            Text(this.importFileName)
              .fontSize(11)
              .fontColor('#8a8a8e')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('70%')
          }
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 12 }) {
            if (this.errorMsg.length > 0) {
              Text(this.errorMsg)
                .fontSize(13)
                .fontColor('#d0021b')
                .padding(12)
            }

            if (this.sites.length === 0) {
              this.EmptyGuide()
            } else {
              Text(`共发现 ${this.sites.length} 个 Wiki 数据文件夹`)
                .fontSize(13)
                .fontColor('#8a8a8e')
                .width('100%')
                .padding({ left: 16, right: 16 })

              ForEach(this.sites, (item: SiteItem) => {
                this.SiteCard(item)
              }, (item: SiteItem) => item.key)
            }

            if (this.importMsg.length > 0) {
              Text(this.importMsg)
                .fontSize(13)
                .fontColor(this.importMsg.startsWith('导入失败') ? '#d0021b' : '#2f6fed')
                .width('100%')
                .padding({ left: 16, right: 16, top: 4 })
            }
          }
          .width('100%')
          .padding({ top: 8, bottom: 24 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#f2f3f5')
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
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
  SiteCard(item: SiteItem) {
    Column() {
      Row() {
        Column({ space: 4 }) {
          Text(item.site.displayName)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1c1c1e')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(item.site.name)
            .fontSize(12)
            .fontColor('#8a8a8e')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.sourceBadgeText(item.site.sourceKey))
          .fontSize(11)
          .fontColor('#2f6fed')
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor('#e8f0fe')
          .borderRadius(10)
      }
      .width('100%')

      if (item.site.totalPages > 0) {
        Text(`${item.site.totalPages} 个页面`)
          .fontSize(12)
          .fontColor('#8a8a8e')
          .margin({ top: 6 })
      }

      Row() {
        Blank()
        Text('打开 ›')
          .fontSize(14)
          .fontColor('#2f6fed')
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#ffffff')
    .borderRadius(12)
    .onClick(() => {
      this.openSite(item);
    })
  }

  @Builder
  EmptyGuide() {
    Column({ space: 10 }) {
      Text('未找到 Wiki 数据')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1c1c1e')
        .margin({ top: 32 })

      Text('把 wiki 数据文件夹放进公共下载目录或应用沙箱，每个顶层文件夹即一个 MediaWiki 站点（含 pages/ 与 images/）。')
        .fontSize(14)
        .fontColor('#3a3a3c')
        .textAlign(TextAlign.Center)
        .lineHeight(22)
        .padding({ left: 24, right: 24 })

      this.GuideBlock('方式一：公共下载目录（推荐）',
        '1. 点击下方按钮启用本应用的公共下载目录（仅首次需要，点击后系统自动完成）。\n' +
        '2. 在手机「文件管理」中进入：我的手机 → ' + this.publicPath + '\n' +
        '3. 把 wiki 数据文件夹（如 rakuen-database）整体复制/移动到该目录下。\n' +
        '   提示：如果你已在 Download 根目录放了 rakuen-database，把它移进上面的文件夹即可。\n' +
        '4. 回到本应用点「重新扫描」。')

      DownloadFileButton({
        contentOptions: {
          icon: DownloadIconStyle.FULL_FILLED,
          text: DownloadDescription.SAVE_FILE
        },
        styleOptions: {
          fontSize: '15vp',
          layoutDirection: DownloadLayoutDirection.HORIZONTAL,
          fontColor: '#ffffff',
          iconColor: '#ffffff',
          textIconSpace: '6vp'
        }
      })
        .height(42)
        .backgroundColor('#2f6fed')
        .borderRadius(21)
        .onClick(() => {
          this.setupPublicDir();
        })

      this.GuideBlock('方式二：应用沙箱',
        '1. 在 DevEco Studio 的 Device File Browser 打开本应用的「应用沙箱」视图。\n' +
        '2. 把 rakuen-database 文件夹整体复制到沙箱的 files 或 files/Download 目录下。\n' +
        '   参考路径：' + this.sandboxPath + '\n' +
        '3. 复制后点「重新扫描」。')

      this.GuideBlock('方式三：导入 Wiki 压缩包（推荐，无需手动复制）',
        '1. 点击下方「选择压缩包」按钮。\n' +
        '2. 在文件选择器中选择 wiki 数据压缩包（如 rakuen-database.zip）。\n' +
        '3. 应用会自动解压到沙箱目录并扫描站点。')

      Button('选择压缩包并导入')
        .height(42)
        .fontSize(15)
        .fontColor('#ffffff')
        .backgroundColor('#2f6fed')
        .borderRadius(21)
        .width('100%')
        .margin({ top: 4 })
        .onClick(() => {
          this.importWikiZip();
        })

      Button('重新扫描')
        .height(36)
        .fontSize(13)
        .fontColor('#2f6fed')
        .backgroundColor('#e8f0fe')
        .margin({ top: 6 })
        .onClick(() => {
          this.refresh();
        })
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
        .fontColor('#1c1c1e')
        .width('100%')
      Text(body)
        .fontSize(13)
        .fontColor('#5a5a5e')
        .lineHeight(20)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor('#ffffff')
    .borderRadius(10)
  }
}