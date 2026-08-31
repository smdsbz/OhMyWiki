import { common } from '@kit.AbilityKit';
import { fileUri, fileIo } from '@kit.CoreFileKit';
import { Logger } from './Logger';
import { PathUtil } from '../data/DataSource';
import { PublicDirSource } from '../data/PublicDirSource';
import { WikiIndex } from '../data/WikiIndex';
import { SmwQueryEngine } from '../wiki/smw/SmwQueryEngine';
import { ZipExtractor, ProgressCallback } from '../data/ZipExtractor';
import { WikiSite } from '../model/WikiTypes';
import { DataSource } from '../data/DataSource';
import { JsonDataReader } from '../wiki/module/JsonDataReader';
import { PropsCacheStore } from '../wiki/smw/PropsCacheStore';
import { InvokeHandler } from '../wiki/template/TemplateEngine';
import { SiteAdapter, SiteAdapterFactory } from '../wiki/siteadapter/SiteAdapter';
import { RakuenSiteAdapter } from '../wiki/siteadapter/rakuen/RakuenSiteAdapter';

const TAG = 'AppStore';

/**
 * 全局应用状态：持有 UIAbilityContext、数据源、当前站点与索引。
 * 数据源 = 公共下载目录（Download/...，探测用）。
 */
export class AppStore {
  private static ctx: common.UIAbilityContext | null = null;
  private static sources: DataSource[] = [];
  private static activeSource: DataSource | null = null;
  private static activeSite: WikiSite | null = null;
  private static activeIndex: WikiIndex | null = null;
  private static activeAdapter: SiteAdapter | null = null;
  /** SMW 属性快照持久化（cacheDir/smwc，可再生缓存） */
  private static propStore: PropsCacheStore | null = null;

  static init(context: common.UIAbilityContext): void {
    if (AppStore.ctx !== null) {
      return;
    }
    AppStore.ctx = context;
    // 站点适配包挂载点：新站点在此注册（引擎不 import 任何具体适配器）
    SiteAdapterFactory.register(new RakuenSiteAdapter());
    AppStore.sources = [];
    AppStore.sources.push(new PublicDirSource(context));
    AppStore.propStore = new PropsCacheStore(context.cacheDir + '/smwc');
    Logger.info(TAG, 'AppStore initialized (public download)');
  }

  static getPublicSource(): PublicDirSource | null {
    for (const s of AppStore.sources) {
      if (s.key === 'public') {
        return s as PublicDirSource;
      }
    }
    return null;
  }

  /** 确保公共下载目录（Download/<包名>/）存在并可访问 */
  static async ensurePublicDir(): Promise<boolean> {
    const pub = AppStore.getPublicSource();
    if (pub === null) {
      return false;
    }
    const ok = await pub.ensureDir();
    return ok && await pub.isAvailable();
  }

  /** 供 UI 展示：Download/<包名> */
  static getPublicDisplayPath(): string {
    const pub = AppStore.getPublicSource();
    if (pub === null) {
      return '';
    }
    const root = pub.getRootUri();
    const prefix = 'file://docs/storage/Users/currentUser/';
    return root.startsWith(prefix) ? root.substring(prefix.length) : root;
  }

  /** 导入 wiki 压缩包：解压到公共下载目录 Download/<包名>/<zip名>/（用户可见，与手动解压一致）。
   *  onProgress 报告解压进度。 */
  static async importWikiZip(zipUri: string, onProgress?: ProgressCallback): Promise<string> {
    const pub = AppStore.getPublicSource();
    if (pub === null) {
      throw new Error('公共下载目录不可用');
    }
    Logger.info(TAG, 'importWikiZip: step1 getPublicSource ok');
    const ok = await pub.ensureDir();
    Logger.info(TAG, 'importWikiZip: step2 ensureDir ok=' + ok);
    if (!ok) {
      throw new Error('公共下载目录不可写，请先点击「保存文件」授权');
    }
    const rootDir = pub.getRootPath();
    const fu = new fileUri.FileUri(zipUri);
    const srcPath = fu.path;
    Logger.info(TAG, 'importWikiZip: step3 srcPath=' + srcPath);
    // 从 zip 文件名推断目录名（去掉 .zip），如 rakuen-database.zip → rakuen-database
    const baseName = srcPath.substring(srcPath.lastIndexOf('/') + 1);
    const dirName = baseName.toLowerCase().endsWith('.zip')
      ? baseName.substring(0, baseName.length - 4) : baseName;
    const destDir = PathUtil.join(rootDir, dirName);
    Logger.info(TAG, 'importWikiZip: step4 destDir=' + destDir);
    // 清理：仅删除目标子目录旧内容（不碰根目录其他文件）
    await AppStore.cleanupDir(destDir);
    Logger.info(TAG, 'importWikiZip: step5 cleanupDir done');
    // 目录已存在则跳过创建（mkdir 对已存在目录抛 13900015 File exists）
    try {
      await fileIo.access(destDir);
    } catch (e) {
      await fileIo.mkdir(destDir, true);
    }
    Logger.info(TAG, 'importWikiZip: step6 mkdir done');
    Logger.info(TAG, 'importWikiZip: ' + srcPath + ' -> ' + destDir);
    if (onProgress !== undefined) {
      await ZipExtractor.extract(srcPath, destDir, onProgress);
    } else {
      await ZipExtractor.extract(srcPath, destDir, (done: number, total: number, name: string) => {
        Logger.info(TAG, 'extract progress: ' + done + '/' + total + ' ' + name);
      });
    }
    Logger.info(TAG, 'importWikiZip done');
    return destDir;
  }

  /** 递归删除目录（含内容）。用异步 fileIo API（listFile/stat/unlink/rmdir），不阻塞主线程；权限受限项跳过 */
  private static async cleanupDir(dir: string): Promise<void> {
    try {
      let names: string[];
      try {
        names = await fileIo.listFile(dir);
      } catch (e) {
        // 目录不存在或不可访问，直接返回
        return;
      }
      for (const n of names) {
        const p = PathUtil.join(dir, n);
        try {
          const st = await fileIo.stat(p);
          if (st.isDirectory()) {
            await AppStore.cleanupDir(p);
            try {
              await fileIo.rmdir(p);
            } catch (e2) {
              Logger.warn(TAG, 'cleanup skip dir: ' + p);
            }
          } else {
            try {
              await fileIo.unlink(p);
            } catch (e3) {
              Logger.warn(TAG, 'cleanup skip file: ' + p);
            }
          }
        } catch (e) {
          // stat 失败（权限受限等），跳过该项，不递归
          Logger.warn(TAG, 'cleanup skip item: ' + p);
        }
      }
    } catch (e) {
      Logger.warn(TAG, 'cleanupDir failed: ' + dir + ' ' + JSON.stringify(e));
    }
  }

  static getSources(): DataSource[] {
    return AppStore.sources;
  }

  static getActiveSource(): DataSource | null {
    return AppStore.activeSource;
  }

  static getActiveSite(): WikiSite | null {
    return AppStore.activeSite;
  }

  static getActiveIndex(): WikiIndex | null {
    return AppStore.activeIndex;
  }

  /** 获取 SMW 语义查询引擎（单例，站点切换时清空属性缓存） */
  static getSmwQueryEngine(): SmwQueryEngine {
    return SmwQueryEngine.get();
  }

  /** 获取当前站点的 #invoke 处理器（站点适配器提供；无适配能力的站点返回 null → 占位） */
  static getActiveInvokeHandler(): InvokeHandler | null {
    return AppStore.activeAdapter !== null ? AppStore.activeAdapter.createInvokeHandler() : null;
  }

  /** 发现所有可用站点（遍历各数据源的顶层文件夹） */
  static async discoverSites(): Promise<WikiSite[]> {
    const result: WikiSite[] = [];
    for (const src of AppStore.sources) {
      const ok = await src.isAvailable();
      if (!ok) {
        continue;
      }
      const dirs = await src.listSubDirs('');
      for (const d of dirs) {
        // 忽略缓存/隐藏目录
        if (d.startsWith('.') || d === 'cache') {
          continue;
        }
        const site = await WikiIndex.probeSite(src, d);
        if (site !== null) {
          result.push(site);
        }
      }
    }
    return result;
  }

  /** 打开站点并建立索引 */
  static async openSite(site: WikiSite): Promise<boolean> {
    const src = AppStore.findSource(site.sourceKey);
    if (src === null) {
      Logger.warn(TAG, 'source not found: ' + site.sourceKey);
      return false;
    }
    AppStore.activeSource = src;
    AppStore.activeSite = site;
    const idx = new WikiIndex(src, site.rootRel);
    await idx.load();
    AppStore.activeIndex = idx;
    AppStore.activeAdapter = SiteAdapterFactory.forSite(site);
    // 站点切换：清空 SMW 属性缓存与 JSON 数据缓存
    SmwQueryEngine.get().clear();
    JsonDataReader.clear();
    // 注入属性快照并预热（必须在 clear 之后；站点目录名作为缓存归属标识）
    if (AppStore.propStore !== null) {
      await SmwQueryEngine.get().setPropsCacheStore(AppStore.propStore, site.name);
    }
    Logger.info(TAG, 'opened site: ' + site.name + ' (' + idx.pageCount() + ' pages)');
    return true;
  }

  /** 根据 sourceKey + 站点名打开站点（供 Reader 使用） */
  static async openSiteByKeyName(siteKey: string, siteName: string): Promise<boolean> {
    if (AppStore.activeSite !== null && AppStore.activeSite.sourceKey === siteKey &&
      AppStore.activeSite.name === siteName && AppStore.activeIndex !== null) {
      return true;
    }
    const sites = await AppStore.discoverSites();
    for (const s of sites) {
      if (s.sourceKey === siteKey && s.name === siteName) {
        return await AppStore.openSite(s);
      }
    }
    Logger.warn(TAG, 'site not found: ' + siteKey + '/' + siteName);
    return false;
  }

  private static findSource(key: string): DataSource | null {
    for (const s of AppStore.sources) {
      if (s.key === key) {
        return s;
      }
    }
    return null;
  }
}
