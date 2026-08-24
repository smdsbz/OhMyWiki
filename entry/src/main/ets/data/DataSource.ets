import { common } from '@kit.AbilityKit';
import { fileIo, ListFileOptions } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { Logger } from '../common/Logger';
import { FileInfo } from '../model/WikiTypes';

const TAG = 'DataSource';

/**
 * 数据源抽象：统一提供对「某个 wiki 数据根目录」下文件的读写。
 * 每个实现对应一种存放方式（应用沙箱 / 公共 Download 目录）。
 * 所有 rel 路径使用 '/' 分隔，相对数据源根目录。
 */
export interface DataSource {
  key: string;
  describe(): string;
  /** 数据源是否可用（存在且可访问） */
  isAvailable(): Promise<boolean>;
  /** 列出 rel 目录下的直接子目录名 */
  listSubDirs(rel: string): Promise<string[]>;
  /** 列出 rel 目录下所有文件名（递归，含子目录，用 '/' 相对路径） */
  listAllFiles(rel: string): Promise<string[]>;
  readText(rel: string): Promise<string>;
  readBinary(rel: string): Promise<Uint8Array>;
  exists(rel: string): Promise<boolean>;
  /** 判断 rel 是否为目录（不存在返回 false） */
  isDir(rel: string): Promise<boolean>;
  statSize(rel: string): Promise<number>;
}

/** 路径工具 */
export class PathUtil {
  /** 拼接相对路径（base 为空时不产生前导斜杠） */
  static join(base: string, rel: string): string {
    if (rel.length === 0) {
      return base;
    }
    if (base.length === 0) {
      return rel.startsWith('/') ? rel.substring(1) : rel;
    }
    const b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    const r = rel.startsWith('/') ? rel.substring(1) : rel;
    return b + '/' + r;
  }
}

/** 沙箱数据源：数据在应用沙箱目录下（优先 files/Download，也兼容 files 与应用级 files）。
 *  开发期用 DevEco Device File Browser 或 hdc 手动复制/推送数据文件夹到沙箱，
 *  每个顶层文件夹（含 pages/）即一个站点。 */
export class SandboxSource implements DataSource {
  readonly key: string = 'sandbox';
  private roots: string[] = [];

  constructor(context: common.UIAbilityContext) {
    const appFiles = context.getApplicationContext().filesDir;
    const candidates: string[] = [
      context.filesDir + '/Download',
      context.filesDir,
      appFiles + '/Download',
      appFiles,
    ];
    for (const c of candidates) {
      if (this.roots.indexOf(c) < 0) {
        this.roots.push(c);
      }
    }
    for (const r of this.roots) {
      try {
        if (!fileIo.accessSync(r)) {
          fileIo.mkdirSync(r);
        }
      } catch (e) {
        // 目录创建失败时忽略，读取时会再次校验
      }
    }
  }

  describe(): string {
    return '应用沙箱（files/Download 等；用 DevEco Device File Browser / hdc 推送数据）';
  }

  /** 首选沙箱数据根目录（供 UI 展示，方便用户定位复制位置） */
  getBase(): string {
    return this.roots.length > 0 ? this.roots[0] : '';
  }

  /** 找到能访问 rel 的根目录 */
  private rootFor(rel: string): string {
    for (const r of this.roots) {
      try {
        if (fileIo.accessSync(PathUtil.join(r, rel))) {
          return r;
        }
      } catch (e) {
        // 继续
      }
    }
    return this.roots.length > 0 ? this.roots[0] : '';
  }

  async isAvailable(): Promise<boolean> {
    for (const r of this.roots) {
      try {
        if (fileIo.accessSync(r)) {
          return true;
        }
      } catch (e) {
        // 继续
      }
    }
    return false;
  }

  async listSubDirs(rel: string): Promise<string[]> {
    const dirs: string[] = [];
    const seen: Set<string> = new Set();
    for (const r of this.roots) {
      try {
        const names: string[] = fileIo.listFileSync(PathUtil.join(r, rel));
        for (const n of names) {
          if (seen.has(n)) {
            continue;
          }
          try {
            const st = fileIo.statSync(PathUtil.join(PathUtil.join(r, rel), n));
            if (st.isDirectory()) {
              seen.add(n);
              dirs.push(n);
            }
          } catch (e) {
            // 忽略单个失败
          }
        }
      } catch (e) {
        Logger.warn(TAG, 'listSubDirs failed: ' + rel + ' ' + JSON.stringify(e));
      }
    }
    return dirs;
  }

  async listAllFiles(rel: string): Promise<string[]> {
    const out: string[] = [];
    const seen: Set<string> = new Set();
    for (const r of this.roots) {
      try {
        const opts: ListFileOptions = { recursion: true, listNum: 0 };
        const names = fileIo.listFileSync(PathUtil.join(r, rel), opts);
        for (const n of names) {
          if (!seen.has(n)) {
            seen.add(n);
            out.push(n);
          }
        }
      } catch (e) {
        Logger.warn(TAG, 'listAllFiles failed: ' + rel + ' ' + JSON.stringify(e));
      }
    }
    return out;
  }

  async readText(rel: string): Promise<string> {
    const data = await this.readBinary(rel);
    const buf = buffer.from(data.buffer, data.byteOffset, data.byteLength);
    return buf.toString('utf-8');
  }

  async readBinary(rel: string): Promise<Uint8Array> {
    const root = this.rootFor(rel);
    const file = fileIo.openSync(PathUtil.join(root, rel), fileIo.OpenMode.READ_ONLY);
    try {
      const st = fileIo.statSync(file.fd);
      const buf = new ArrayBuffer(st.size);
      fileIo.readSync(file.fd, buf);
      return new Uint8Array(buf);
    } finally {
      fileIo.closeSync(file);
    }
  }

  async exists(rel: string): Promise<boolean> {
    for (const r of this.roots) {
      try {
        if (fileIo.accessSync(PathUtil.join(r, rel))) {
          return true;
        }
      } catch (e) {
        // 继续
      }
    }
    return false;
  }

  async isDir(rel: string): Promise<boolean> {
    for (const r of this.roots) {
      try {
        if (fileIo.statSync(PathUtil.join(r, rel)).isDirectory()) {
          return true;
        }
      } catch (e) {
        // 继续
      }
    }
    return false;
  }

  async statSize(rel: string): Promise<number> {
    const root = this.rootFor(rel);
    try {
      return fileIo.statSync(PathUtil.join(root, rel)).size;
    } catch (e) {
      return 0;
    }
  }
}
