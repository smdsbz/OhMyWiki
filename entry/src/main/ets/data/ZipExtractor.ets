import { zlib } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { Logger } from '../common/Logger';
import { PathUtil } from './DataSource';

const TAG = 'ZipExtractor';

/** zip 中央目录条目 */
interface ZipEntry {
  name: string;
  method: number; // 0=stored 8=deflate
  compressedSize: number;
  uncompressedSize: number;
  localHeaderOffset: number;
}

/** 解压进度回调：doneCount 已处理文件数，totalCount 总文件数，fileName 当前文件 */
export type ProgressCallback = (doneCount: number, totalCount: number, fileName: string) => void;

/**
 * 手动解析 zip 并逐文件解压（带进度回调）。
 * zlib.decompressFile 无进度回调，这里解析中央目录后逐文件用 zlib.uncompress 解压。
 */
export class ZipExtractor {
  /** 解压 zip 到目标目录，带进度回调 */
  static async extract(zipPath: string, destDir: string, onProgress: ProgressCallback): Promise<void> {
    const file = fileIo.openSync(zipPath, fileIo.OpenMode.READ_ONLY);
    try {
      const st = fileIo.statSync(file.fd);
      const fileSize = st.size;
      const entries = ZipExtractor.parseCentralDirectory(file.fd, fileSize);
      let doneCount = 0;
      for (const e of entries) {
        try {
          await ZipExtractor.extractEntry(file.fd, e, destDir);
        } catch (err) {
          Logger.error(TAG, 'extractEntry failed: ' + e.name + ' method=' + e.method +
            ' comp=' + e.compressedSize + ' uncomp=' + e.uncompressedSize +
            ' err=' + JSON.stringify(err));
          throw new Error('解压失败: ' + e.name + ' ' + JSON.stringify(err));
        }
        doneCount++;
        onProgress(doneCount, entries.length, e.name);
        // 让出主线程，避免长时间阻塞导致 ANR/闪退（THREAD_BLOCK_6S）
        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 0);
        });
      }
      Logger.info(TAG, 'extract done: ' + entries.length + ' entries, ' + doneCount + ' files');
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** 解析 zip 中央目录（EOCD + Central Directory），返回全部条目 */
  private static parseCentralDirectory(fd: number, fileSize: number): ZipEntry[] {
    // 读文件末尾（最多 64KB）找 EOCD 签名 0x06054b50
    const tailLen = Math.min(fileSize, 65536);
    const tail = new ArrayBuffer(tailLen);
    fileIo.readSync(fd, tail, { offset: fileSize - tailLen });
    const dv = new DataView(tail);
    let eocdPos = -1;
    for (let i = tailLen - 22; i >= 0; i--) {
      if (dv.getUint32(i, true) === 0x06054b50) {
        eocdPos = i;
        break;
      }
    }
    if (eocdPos < 0) {
      throw new Error('无效的 zip 文件（找不到 EOCD）');
    }
    const entryCount = dv.getUint16(eocdPos + 10, true);
    const cdSize = dv.getUint32(eocdPos + 12, true);
    const cdOffset = dv.getUint32(eocdPos + 16, true);
    // 读中央目录
    const cd = new ArrayBuffer(cdSize);
    fileIo.readSync(fd, cd, { offset: cdOffset });
    const cdv = new DataView(cd);
    const entries: ZipEntry[] = [];
    let pos = 0;
    for (let i = 0; i < entryCount; i++) {
      if (cdv.getUint32(pos, true) !== 0x02014b50) {
        break;
      }
      const method = cdv.getUint16(pos + 10, true);
      const compressedSize = cdv.getUint32(pos + 20, true);
      const uncompressedSize = cdv.getUint32(pos + 24, true);
      const nameLen = cdv.getUint16(pos + 28, true);
      const extraLen = cdv.getUint16(pos + 30, true);
      const commentLen = cdv.getUint16(pos + 32, true);
      const localHeaderOffset = cdv.getUint32(pos + 42, true);
      const nameBytes = new Uint8Array(cd, pos + 46, nameLen);
      const name = buffer.from(nameBytes.buffer, nameBytes.byteOffset, nameBytes.byteLength).toString('utf-8');
      entries.push({
        name: name,
        method: method,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        localHeaderOffset: localHeaderOffset,
      });
      pos += 46 + nameLen + extraLen + commentLen;
    }
    Logger.info(TAG, 'central dir: ' + entries.length + ' entries');
    return entries;
  }

  /** 解压单个条目到目标目录 */
  private static async extractEntry(fd: number, entry: ZipEntry, destDir: string): Promise<void> {
    // 读本地文件头，计算数据偏移
    const lh = new ArrayBuffer(30);
    fileIo.readSync(fd, lh, { offset: entry.localHeaderOffset });
    const lv = new DataView(lh);
    const nameLen = lv.getUint16(26, true);
    const extraLen = lv.getUint16(28, true);
    const dataOffset = entry.localHeaderOffset + 30 + nameLen + extraLen;

    const relPath = entry.name.replace(/\\/g, '/');
    const outPath = PathUtil.join(destDir, relPath);
    // 目录条目
    if (relPath.endsWith('/')) {
      if (!fileIo.accessSync(outPath)) {
        fileIo.mkdirSync(outPath, true);
      }
      return;
    }
    // 确保父目录存在（mkdirSync 对已存在目录抛 13900015 File exists，需先检查）
    const idx = outPath.lastIndexOf('/');
    if (idx > 0) {
      const parent = outPath.substring(0, idx);
      if (!fileIo.accessSync(parent)) {
        fileIo.mkdirSync(parent, true);
      }
    }
    // 读压缩数据
    const comp = new ArrayBuffer(entry.compressedSize);
    fileIo.readSync(fd, comp, { offset: dataOffset });
    // 解压
    let data: ArrayBuffer;
    if (entry.method === 0) {
      data = comp;
    } else if (entry.method === 8) {
      if (entry.uncompressedSize === 0) {
        // 空文件（deflate 但原始大小 0），直接写空，避免 inflate 报 17800004
        data = new ArrayBuffer(0);
      } else {
        // zip 内是 raw deflate（无 zlib header），uncompress 不支持，需用 inflateInit2(-15) + inflate
        data = await ZipExtractor.inflateRaw(comp, entry.uncompressedSize);
      }
    } else {
      throw new Error('不支持的压缩方法: ' + entry.method + ' (' + relPath + ')');
    }
    // 写入目标文件（若 outPath 已被创建为目录，尝试递归删除；删除失败则跳过该文件，不中断整个解压）
    try {
      const st = fileIo.statSync(outPath);
      if (st.isDirectory()) {
        ZipExtractor.removeDir(outPath);
        // 删除后确认目录是否已移除；若仍存在（权限受限删不掉），跳过该文件
        try {
          const st2 = fileIo.statSync(outPath);
          if (st2.isDirectory()) {
            Logger.warn(TAG, 'skip file (dir not removable): ' + relPath);
            return;
          }
        } catch (e2) {
          // 目录已删除，继续写入
        }
      }
    } catch (e) {
      // statSync 失败 = 文件不存在（正常），继续写入
    }
    const out = fileIo.openSync(outPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(out.fd, data);
    } finally {
      fileIo.closeSync(out);
    }
  }

  /** 递归删除目录（含内容） */
  private static removeDir(dir: string): void {
    try {
      const names: string[] = fileIo.listFileSync(dir);
      for (const n of names) {
        const p = PathUtil.join(dir, n);
        try {
          const st = fileIo.statSync(p);
          if (st.isDirectory()) {
            ZipExtractor.removeDir(p);
            fileIo.rmdirSync(p);
          } else {
            fileIo.unlinkSync(p);
          }
        } catch (e) {
          Logger.warn(TAG, 'removeDir item failed: ' + p + ' ' + JSON.stringify(e));
        }
      }
      fileIo.rmdirSync(dir);
    } catch (e) {
      Logger.warn(TAG, 'removeDir failed: ' + dir + ' ' + JSON.stringify(e));
    }
  }

  /** 解压 raw deflate 数据（zip 内 deflate 无 zlib header，需 inflateInit2(-15) + inflate） */
  private static async inflateRaw(comp: ArrayBuffer, uncompressedSize: number): Promise<ArrayBuffer> {
    const zip = await zlib.createZip();
    // 自己初始化 ZStream（getZStream() 返回的是只读内部状态，不能直接赋值）
    const strm: zlib.ZStream = {};
    strm.nextIn = comp;
    strm.availableIn = comp.byteLength;
    const dest = new ArrayBuffer(uncompressedSize);
    strm.nextOut = dest;
    strm.availableOut = uncompressedSize;
    await zip.inflateInit2(strm, -15); // -15 = raw deflate
    try {
      const status = await zip.inflate(strm, zlib.CompressFlushMode.FINISH);
      if (status !== zlib.ReturnStatus.STREAM_END) {
        throw new Error('inflate failed status=' + status);
      }
    } finally {
      await zip.inflateEnd(strm);
    }
    return dest;
  }
}