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
  /** 期望宽度（px，0 表示自动/撑满） */
  fileWidth: number = 0;
  /** 是否占满整行（块级图片） */
  block: boolean = false;
  @State pm: image.PixelMap | null = null;
  @State failed: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    const result = await ImageLoader.load(this.fileName);
    if (result !== null) {
      this.pm = result;
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

  build() {
    if (this.failed) {
      Column() {
        Text('⚠ 图片缺失')
          .fontSize(12)
          .fontColor('#b0b0b4')
      }
      .width('100%')
      .height(80)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#f0f0f2')
      .borderRadius(6)
      .margin({ top: 6, bottom: 6 })
    } else if (this.pm !== null) {
      if (this.block) {
        if (this.widthVp() > 0) {
          Image(this.pm as image.PixelMap)
            .width(this.widthVp())
            .objectFit(ImageFit.Contain)
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
          .fontColor('#b0b0b4')
      }
      .width(this.widthVp() > 0 ? this.widthVp() : 160)
      .height(80)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#f5f5f7')
      .borderRadius(6)
      .margin({ top: 6, bottom: 6 })
    }
  }
}
