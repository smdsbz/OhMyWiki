import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0A01;

/**
 * 统一日志工具
 */
export class Logger {
  static info(tag: string, msg: string): void {
    hilog.info(DOMAIN, tag, '%{public}s', msg);
  }

  static warn(tag: string, msg: string): void {
    hilog.warn(DOMAIN, tag, '%{public}s', msg);
  }

  static error(tag: string, msg: string): void {
    hilog.error(DOMAIN, tag, '%{public}s', msg);
  }
}
