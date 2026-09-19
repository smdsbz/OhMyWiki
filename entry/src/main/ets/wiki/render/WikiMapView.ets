import { image } from '@kit.ImageKit';
import { ImageLoader } from '../../common/ImageLoader';
import { MapMarker } from '../../model/WikiTypes';

/** 容器高上限 = 1.5×宽。普通比例底图全宽原样渲染（高=宽/ratio）；
 * 超高底图（ratio < 2/3，全站 90 张中 22 张，最窄 120×540）在此高度内
 * contain 等比缩小居中，打点相对底图矩形定位。
 * 原站 setContainerHeight 统一 0.618×宽是交互地图（可缩放）的容器规则，
 * 静态图照搬会让普通图过小留白过多，不适合手机布局（2026-09-19 用户拍板） */
const TALL_MAP_MAX_H_W = 1.5;

/**
 * 地图组件：按给定底图文件名渲染 + 百分比标记（引擎不感知底图命名规则）。
 * 标记坐标为相对底图的百分比。
 */
@Component
export struct WikiMapView {
  /** 底图文件名（由模块输出时拼好） */
  image: string = '';
  /** 标题（mapName・menuGroup） */
  title: string = '';
  /** 底图宽高比 */
  ratio: number = 1;
  markers: MapMarker[] = [];
  @State pm: image.PixelMap | null = null;
  @State failed: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    const result = await ImageLoader.load(this.image);
    if (result !== null) {
      this.pm = result;
    } else {
      this.failed = true;
    }
  }

  /** 容器宽高比（w/h）：普通底图=自然比例；超高底图封顶 1/TALL_MAP_MAX_H_W */
  private containerAspect(): number {
    const r = this.ratio > 0 ? this.ratio : 1;
    return Math.max(r, 1 / TALL_MAP_MAX_H_W);
  }

  /** contain 适配后底图显示宽占容器宽的比例（普通图恒为 1） */
  private dispWUnit(): number {
    const r = this.ratio > 0 ? this.ratio : 1;
    return Math.min(1, r / this.containerAspect());
  }

  /** 底图矩形相对容器的尺寸（百分比串）——inner Stack 居中承载底图与打点 */
  private innerWidthPct(): string {
    return (this.dispWUnit() * 100).toFixed(3) + '%';
  }

  private innerHeightPct(): string {
    const r = this.ratio > 0 ? this.ratio : 1;
    return (this.dispWUnit() * this.containerAspect() / r * 100).toFixed(3) + '%';
  }

  build() {
    Column() {
      Text(this.title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 8, bottom: 4 })
      if (this.failed) {
        Column() {
          Text('⚠ 地图图片缺失：' + this.image)
            .fontSize(12)
            .fontColor($r('app.color.img_missing_text'))
        }
        .width('100%')
        .height(120)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.img_missing_bg'))
        .borderRadius(6)
      } else if (this.pm !== null) {
        Stack() {
          Stack() {
            Image(this.pm as image.PixelMap)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Fill)
              .interpolation(ImageInterpolation.High)
            ForEach(this.markers, (m: MapMarker, idx: number) => {
              // 百分比占位定位（空容器加 fontSize 确保参与布局）。
              // Row 必须显式占满整宽：wrap-content 会被 Column 默认水平居中，
              // left% 将相对居中后的半宽空间解析，打点整体右偏（真机实测：x = 左缘 + W/2 + L·W/200）
              Column() {
                Text('')
                  .fontSize(1)
                  .height(m.top.toString() + '%')
                  .width('100%')
                Row() {
                  Text('')
                    .fontSize(1)
                    .width(m.left.toString() + '%')
                    .height(1)
                  Circle({ width: 16, height: 16 })
                    .fill('#e5484d')
                    .stroke('#ffffff')
                    .strokeWidth(2.5)
                    .shadow({ radius: 3, color: '#66000000', offsetX: 0, offsetY: 1 })
                    .margin({ left: -8 })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
              }
              .width('100%')
              .height('100%')
              .alignItems(HorizontalAlign.Start)
            }, (m: MapMarker, idx: number) => 'mk' + idx + '_' + m.left.toFixed(2) + '_' + m.top.toFixed(2))
          }
          .width(this.innerWidthPct())
          .height(this.innerHeightPct())
        }
        .width('100%')
        .aspectRatio(this.containerAspect())
        .borderRadius(6)
        .clip(true)
      } else {
        Column() {
          Text('地图加载中…')
            .fontSize(12)
            .fontColor($r('app.color.img_missing_text'))
        }
        .width('100%')
        .aspectRatio(this.containerAspect())
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.surface_deep'))
        .borderRadius(6)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 4, bottom: 8 })
  }
}
