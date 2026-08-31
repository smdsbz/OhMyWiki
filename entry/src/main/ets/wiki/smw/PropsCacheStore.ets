import { fileIo } from '@kit.CoreFileKit';
import { Logger } from '../../common/Logger';

const TAG = 'PropsCacheStore';
const SCHEMA_VERSION = 1;
/** 同站点写盘节流间隔（ms）：#show 密集页多次 flush 合并为末次 */
const SAVE_THROTTLE_MS = 2000;

/** 快照文件结构 */
interface SnapshotFile {
  v: number;
  site: string;
  props: Record<string, Record<string, string[]>>;
}

/**
 * SMW 属性快照持久化（机制层）：
 * 站点级单文件 JSON 快照，写入应用沙箱 cacheDir（可再生数据——系统清空缓存/
 * 空间不足自动清理后，下次扫描自动重建）。零站点知识：siteKey 由调用方传入运行时值。
 * 原子写（.tmp→rename）+ 全静默容错（任何失败降级为无缓存）。
 */
export class PropsCacheStore {
  private rootDir: string;
  /** 同 siteKey 节流：待写定时器 */
  private pendingTimers: Map<string, number> = new Map();
  /** 节流期间暂存的末次数据 */
  private pendingData: Map<string, Map<string, Map<string, string[]>>> = new Map();
  /** 根目录懒创建（一次性，缓存其 Promise） */
  private ensurePromise: Promise<void> | null = null;

  constructor(rootDir: string) {
    this.rootDir = rootDir;
  }

  /** 懒建根目录（全异步；失败静默——后续写盘自然失败，降级为无缓存） */
  private ensureDir(): Promise<void> {
    if (this.ensurePromise === null) {
      this.ensurePromise = fileIo.mkdir(this.rootDir, true).catch((e: Object) => {
        Logger.warn(TAG, 'mkdir failed: ' + JSON.stringify(e));
      });
    }
    return this.ensurePromise;
  }

  private fileName(siteKey: string): string {
    // 站点目录名天然合法；替换仅防御性保留
    const safe = siteKey.replace(/[/:\\ ]/g, '_');
    return this.rootDir + '/' + safe + '.json';
  }

  /** 读取站点快照；不存在/损坏/版本不符/site 自校验不匹配 → null（静默） */
  async load(siteKey: string): Promise<Map<string, Map<string, string[]>> | null> {
    const path = this.fileName(siteKey);
    try {
      try {
        await fileIo.access(path);
      } catch (e) {
        return null; // 快照不存在（首扫/被清理）
      }
      const text = await fileIo.readText(path);
      const parsed = JSON.parse(text) as SnapshotFile;
      if (parsed.v !== SCHEMA_VERSION || parsed.site !== siteKey) {
        return null;
      }
      const out = new Map<string, Map<string, string[]>>();
      const props = parsed.props;
      const titles = Object.keys(props);
      for (const t of titles) {
        const m = new Map<string, string[]>();
        const inner = props[t];
        const keys = Object.keys(inner);
        for (const k of keys) {
          m.set(k, inner[k]);
        }
        out.set(t, m);
      }
      Logger.info(TAG, 'load: ' + siteKey + ' -> ' + out.size + ' titles');
      return out;
    } catch (e) {
      Logger.warn(TAG, 'load failed: ' + siteKey + ' ' + JSON.stringify(e));
      return null;
    }
  }

  /** 落盘（fire-and-forget，节流合并；任何失败丢弃本次不抛出） */
  save(siteKey: string, props: Map<string, Map<string, string[]>>): void {
    const prev = this.pendingTimers.get(siteKey);
    if (prev !== undefined) {
      clearTimeout(prev);
    }
    this.pendingData.set(siteKey, props);
    const timer = setTimeout(() => {
      this.pendingTimers.delete(siteKey);
      const data = this.pendingData.get(siteKey);
      this.pendingData.delete(siteKey);
      if (data !== undefined) {
        this.writeNow(siteKey, data);
      }
    }, SAVE_THROTTLE_MS);
    this.pendingTimers.set(siteKey, timer as number);
  }

  private async writeNow(siteKey: string, props: Map<string, Map<string, string[]>>): Promise<void> {
    const path = this.fileName(siteKey);
    const tmp = path + '.tmp';
    try {
      const obj: Record<string, Record<string, string[]>> = {};
      props.forEach((m: Map<string, string[]>, title: string) => {
        const inner: Record<string, string[]> = {};
        m.forEach((vals: string[], k: string) => {
          inner[k] = vals;
        });
        obj[title] = inner;
      });
      const file: SnapshotFile = { v: SCHEMA_VERSION, site: siteKey, props: obj };
      await this.ensureDir();
      const tmpFile = await fileIo.open(tmp, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE |
        fileIo.OpenMode.TRUNC);
      try {
        await fileIo.write(tmpFile.fd, JSON.stringify(file));
      } finally {
        await fileIo.close(tmpFile);
      }
      await fileIo.rename(tmp, path);
      Logger.info(TAG, 'save: ' + siteKey + ' ' + props.size + ' titles');
    } catch (e) {
      Logger.warn(TAG, 'write failed: ' + siteKey + ' ' + JSON.stringify(e));
    }
  }

  /** 清空全部快照（预留，本期无调用方） */
  async clearAll(): Promise<void> {
    this.pendingTimers.forEach((t: number) => {
      clearTimeout(t);
    });
    this.pendingTimers.clear();
    this.pendingData.clear();
    this.ensurePromise = null;
    try {
      await fileIo.rmdir(this.rootDir);
      await fileIo.mkdir(this.rootDir, true);
    } catch (e) {
      Logger.warn(TAG, 'clearAll failed: ' + JSON.stringify(e));
    }
  }
}
