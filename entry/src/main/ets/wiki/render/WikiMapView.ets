import { image } from '@kit.ImageKit';
import { ImageLoader } from '../../common/ImageLoader';
import { MapMarker } from '../../model/WikiTypes';

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
          Image(this.pm as image.PixelMap)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Fill)
            .interpolation(ImageInterpolation.High)
          ForEach(this.markers, (m: MapMarker, idx: number) => {
            // 百分比占位定位（空容器加 fontSize 确保参与布局）
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
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .height('100%')
          }, (m: MapMarker, idx: number) => 'mk' + idx + '_' + m.left.toFixed(2) + '_' + m.top.toFixed(2))
        }
        .width('100%')
        .aspectRatio(this.ratio > 0 ? this.ratio : 1)
        .borderRadius(6)
        .clip(true)
      } else {
        Column() {
          Text('地图加载中…')
            .fontSize(12)
            .fontColor($r('app.color.img_missing_text'))
        }
        .width('100%')
        .aspectRatio(this.ratio > 0 ? this.ratio : 1)
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
