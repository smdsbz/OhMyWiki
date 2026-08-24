/**
 * 数据源抽象：统一提供对「某个 wiki 数据根目录」下文件的读写。
 * 每个实现对应一种存放方式（公共 Download 目录）。
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
