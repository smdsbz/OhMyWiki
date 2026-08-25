import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { Logger } from '../common/Logger';
import { DataSource, PathUtil } from './DataSource';

const TAG = 'PublicDirSource';

/**
 * 公共下载目录数据源（DOWNLOAD 模式授权）。
 * 机制：
 *   应用通过 DOWNLOAD 模式保存（DownloadFileButton 安全控件 / DocumentViewPicker.save）
 *   获得 Download/<自己包名>/ 目录的持久化访问权限（无需声明任何文件权限、无需选择器）。
 *   之后可直接访问 file://docs/storage/Users/currentUser/Download/<bundleName>/，
 *   用户把 wiki 数据文件夹复制进该目录即可被识别。
 * 注意：应用只能访问 Download 下自己包名对应的目录，无法访问整个 Download。
 */
export class PublicDirSource implements DataSource {
  readonly key: string = 'public';
  private rootUri: string = '';
  private rootPath: string = '';

  constructor(context: common.UIAbilityContext) {
    const bundleName = context.abilityInfo.bundleName;
    this.rootUri = 'file://docs/storage/Users/currentUser/Download/' + bundleName;
    try {
      const fu = new fileUri.FileUri(this.rootUri);
      this.rootPath = fu.path;
    } catch (e) {
      Logger.warn(TAG, 'FileUri failed: ' + JSON.stringify(e));
      this.rootPath = '';
    }
    Logger.info(TAG, 'public root: ' + this.rootUri + ' -> ' + this.rootPath);
  }

  describe(): string {
    return '公共下载目录（Download/<包名>/，把数据文件夹复制进去）';
  }

  getRootUri(): string {
    return this.rootUri;
  }

  getRootPath(): string {
    return this.rootPath;
  }

  /** 尝试创建公共下载目录（应用可直接创建/访问自己包名的目录则成功） */
  async ensureDir(): Promise<boolean> {
    if (this.rootPath.length === 0) {
      return false;
    }
    try {
      if (!await fileIo.access(this.rootPath)) {
        await fileIo.mkdir(this.rootPath);
        Logger.info(TAG, 'created public dir: ' + this.rootPath);
      }
      return true;
    } catch (e) {
      Logger.warn(TAG, 'ensureDir failed: ' + JSON.stringify(e));
      return false;
    }
  }

  async isAvailable(): Promise<boolean> {
    if (this.rootPath.length === 0) {
      return false;
    }
    try {
      return await fileIo.access(this.rootPath);
    } catch (e) {
      return false;
    }
  }

  async listSubDirs(rel: string): Promise<string[]> {
    const dirs: string[] = [];
    try {
      const names: string[] = await fileIo.listFile(PathUtil.join(this.rootPath, rel));
      for (const n of names) {
        try {
          const st = await fileIo.stat(PathUtil.join(PathUtil.join(this.rootPath, rel), n));
          if (st.isDirectory()) {
            dirs.push(n);
          }
        } catch (e) {
          // 忽略
        }
      }
    } catch (e) {
      Logger.warn(TAG, 'listSubDirs failed: ' + rel + ' ' + JSON.stringify(e));
    }
    return dirs;
  }

  async listAllFiles(rel: string): Promise<string[]> {
    const fullPath = PathUtil.join(this.rootPath, rel);
    // 公共下载目录的 listFile recursion 不生效（权限限制），需手动递归
    const result: string[] = [];
    await PublicDirSource.collectFiles(fullPath, '', result);
    Logger.info(TAG, 'listAllFiles: ' + fullPath + ' -> ' + result.length + ' files');
    return result;
  }

  /** 手动递归收集文件（返回相对路径） */
  private static async collectFiles(dirPath: string, relPrefix: string, out: string[]): Promise<void> {
    let names: string[];
    try {
      names = await fileIo.listFile(dirPath);
    } catch (e) {
      Logger.warn(TAG, 'collectFiles: listFile failed: ' + dirPath + ' ' + JSON.stringify(e));
      return;
    }
    Logger.info(TAG, 'collectFiles: ' + dirPath + ' -> ' + names.length + ' items');
    for (const n of names) {
      const childPath = PathUtil.join(dirPath, n);
      const childRel = relPrefix.length > 0 ? relPrefix + '/' + n : n;
      try {
        const st = await fileIo.stat(childPath);
        if (st.isDirectory()) {
          await PublicDirSource.collectFiles(childPath, childRel, out);
        } else {
          out.push(childRel);
        }
      } catch (e) {
        Logger.warn(TAG, 'collectFiles: stat failed: ' + childPath + ' ' + JSON.stringify(e));
      }
    }
  }

  async readText(rel: string): Promise<string> {
    const fullPath = PathUtil.join(this.rootPath, rel);
    try {
      const data = await this.readBinary(rel);
      const buf = buffer.from(data.buffer, data.byteOffset, data.byteLength);
      const text = buf.toString('utf-8');
      Logger.info(TAG, 'readText: ' + fullPath + ' -> ' + text.length + ' chars');
      return text;
    } catch (e) {
      Logger.warn(TAG, 'readText failed: ' + fullPath + ' ' + JSON.stringify(e));
      throw new Error('readText failed: ' + fullPath + ' ' + JSON.stringify(e));
    }
  }

  async readBinary(rel: string): Promise<Uint8Array> {
    const fullPath = PathUtil.join(this.rootPath, rel);
    const file = await fileIo.open(fullPath, fileIo.OpenMode.READ_ONLY);
    try {
      const st = await fileIo.stat(file.fd);
      const buf = new ArrayBuffer(st.size);
      const bytes = new Uint8Array(buf);
      let total = 0;
      while (total < st.size) {
        const n = await fileIo.read(file.fd, buf, { offset: total });
        if (n <= 0) {
          break;
        }
        total += n;
      }
      return bytes;
    } finally {
      await fileIo.close(file);
    }
  }

  async exists(rel: string): Promise<boolean> {
    try {
      return await fileIo.access(PathUtil.join(this.rootPath, rel));
    } catch (e) {
      return false;
    }
  }

  async isDir(rel: string): Promise<boolean> {
    try {
      return (await fileIo.stat(PathUtil.join(this.rootPath, rel))).isDirectory();
    } catch (e) {
      return false;
    }
  }

  async statSize(rel: string): Promise<number> {
    try {
      return (await fileIo.stat(PathUtil.join(this.rootPath, rel))).size;
    } catch (e) {
      return 0;
    }
  }
}
