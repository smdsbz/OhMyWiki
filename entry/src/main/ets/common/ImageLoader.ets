import { image } from '@kit.ImageKit';
import { Logger } from './Logger';
import { AppStore } from './AppStore';
import { PathUtil } from '../data/DataSource';

const TAG = 'ImageLoader';

/**
 * 图片加载器：从当前站点读取图片字节 → 采样解码为 PixelMap → LRU 缓存。
 */
export class ImageLoader {
  private static cache: Map<string, image.PixelMap> = new Map();
  private static MAX_CACHE = 120;

  static async load(fileName: string): Promise<image.PixelMap | null> {
    const cached = ImageLoader.cache.get(fileName);
    if (cached !== undefined) {
      return cached;
    }
    const index = AppStore.getActiveIndex();
    if (index === null) {
      return null;
    }
    try {
      const bytes = await index.readImageBinary(fileName);
      if (bytes === null) {
        return null;
      }
      const ab = bytes.buffer as ArrayBuffer;
      const src = image.createImageSource(ab);
      const info = await src.getImageInfo();
      let w = info.size.width;
      let h = info.size.height;
      const cap = 1280;
      if (w > cap && w > 0) {
        h = Math.round(h * cap / w);
        w = cap;
      }
      const pm = await src.createPixelMap({
        desiredSize: { width: w, height: h },
      });
      src.release();
      if (ImageLoader.cache.size >= ImageLoader.MAX_CACHE) {
        ImageLoader.cache.clear();
      }
      ImageLoader.cache.set(fileName, pm);
      return pm;
    } catch (e) {
      Logger.warn(TAG, 'load image failed: ' + fileName + ' ' + JSON.stringify(e));
      return null;
    }
  }

  static clear(): void {
    ImageLoader.cache.clear();
  }
}
