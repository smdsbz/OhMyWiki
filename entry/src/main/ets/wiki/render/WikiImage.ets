import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { ImageLoader } from '../../common/ImageLoader';

/**
 * 图片组件：按需加载站点图片，加载失败显示占位。
 */
@Component
export struct WikiImage {
  /** 图片文件名（images/ 下） */
  fileName: string = '';
  /** 期望宽度（px，0 表示自动/铺满） */
  fileWidth: number = 0;
  /** 期望高度（px，x400px 限高注释；0 表示不限） */
  fileHeight: number = 0;
  /** 是否占满整行（块级图片） */
  block: boolean = false;
  @State pm: image.PixelMap | null = null;
  @State failed: boolean = false;
  /** 原图宽高比（width/height），用于铺满宽时按比例定高 */
  @State ratio: number = 0;

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    const result = await ImageLoader.load(this.fileName);
    if (result !== null) {
      this.pm = result;
      try {
        const info = await result.getImageInfo();
        if (info.size.height > 0) {
          this.ratio = info.size.width / info.size.height;
        }
      } catch (e) {
        this.ratio = 0;
      }
    } else {
      this.failed = true;
    }
  }

  private widthVp(): number {
    if (this.fileWidth <= 0) {
      return 0;
    }
    // wiki 的 px 是密度无关单位（等同 vp），不能再用 px2vp 缩小；钳制到屏幕宽度避免溢出
    const screenVp = px2vp(display.getDefaultDisplaySync().width);
    return Math.min(this.fileWidth, screenVp);
  }

  /** 限高注释（x400px）下的显示宽度：高固定×比例，钳制到屏宽；非限高返回 0 */
  private heightLimitedWidthVp(): number {
    if (this.fileHeight <= 0 || this.fileWidth > 0 || this.ratio <= 0) {
      return 0;
    }
    const screenVp = px2vp(display.getDefaultDisplaySync().width);
    return Math.min(this.fileHeight * this.ratio, screenVp);
  }

  build() {
    if (this.failed) {
      Column() {
        Text('⚠ 图片缺失')
          .fontSize(12)
          .fontColor($r('app.color.img_missing_text'))
      }
      .width('100%')
      .height(80)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.img_missing_bg'))
      .borderRadius(6)
      .margin({ top: 6, bottom: 6 })
    } else if (this.pm !== null) {
      if (this.block) {
        // 宽度注释优先（屏幕不够时钳制到屏宽）；其次高度限定；都无注释则居中铺满容器宽
        if (this.heightLimitedWidthVp() > 0) {
          // 限高注释（x400px）：高度固定，宽度按比例（同时不超出屏宽）
          Image(this.pm as image.PixelMap)
            .width(this.heightLimitedWidthVp())
            .aspectRatio(this.ratio)
            .objectFit(ImageFit.Fill)
            .margin({ top: 6, bottom: 6 })
        } else if (this.widthVp() > 0) {
          // 宽度注释：按注释宽度（widthVp 已钳制屏宽）
          Image(this.pm as image.PixelMap)
            .width(this.widthVp())
            .aspectRatio(this.ratio > 0 ? this.ratio : 1)
            .objectFit(ImageFit.Fill)
            .margin({ top: 6, bottom: 6 })
        } else if (this.ratio > 0) {
          // 无注释：铺满容器宽，按原图比例定高
          Image(this.pm as image.PixelMap)
            .width('100%')
            .aspectRatio(this.ratio)
            .objectFit(ImageFit.Fill)
            .margin({ top: 6, bottom: 6 })
        } else {
          Image(this.pm as image.PixelMap)
            .width('100%')
            .height(240)
            .objectFit(ImageFit.Contain)
            .margin({ top: 6, bottom: 6 })
        }
      } else {
        Image(this.pm as image.PixelMap)
          .width(this.widthVp() > 0 ? this.widthVp() : 120)
          .constraintSize({ maxHeight: 360 })
          .objectFit(ImageFit.Contain)
      }
    } else {
      Column() {
        Text('加载中…')
          .fontSize(12)
          .fontColor($r('app.color.img_missing_text'))
      }
      .width(this.widthVp() > 0 ? this.widthVp() : 160)
      .height(80)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.surface_deep'))
      .borderRadius(6)
      .margin({ top: 6, bottom: 6 })
    }
  }
}
