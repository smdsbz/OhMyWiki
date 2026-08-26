import { NodeType, WikiNode } from '../../model/WikiTypes';
import { WikiImage } from './WikiImage';
import { WikiMapView } from './WikiMapView';

/** 行内渲染单元 */
interface InlineRun {
  kind: string; // 'text' | 'link' | 'image' | 'placeholder' | 'break'
  inline?: WikiNode[];
  target?: string;
  fileName?: string;
  width?: number;
  align?: string;
  reason?: string;
  style: number; // 1=bold 2=italic
}

/**
 * wiki 节点树渲染器：把 WikiNode[] 渲染为 ArkUI 组件。
 * 行内文本用 Flex wrap + 分段 Text（链接为独立可点击 Text）。
 */
@Component
export struct WikiContentView {
  @Prop nodes: WikiNode[] = [];
  @Prop renderKey: number = 0;
  onNavigate: (title: string) => void = (title: string) => {
  };

  build() {
    Column({ space: 0 }) {
      ForEach(this.nodes, (node: WikiNode, index: number) => {
        this.renderBlock(node)
      }, (node: WikiNode, index: number) => 'k' + this.renderKey + '_' + index)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private headingSize(level: number): number {
    if (level <= 1) {
      return 22;
    }
    if (level === 2) {
      return 19;
    }
    if (level === 3) {
      return 17;
    }
    if (level === 4) {
      return 16;
    }
    return 15;
  }

  private isSingleImage(inline: WikiNode[]): boolean {
    // 容忍前导空白文本（如 `rowspan="4" | {{icon|...}}` 剥离属性后残留的空格）
    let idx = 0;
    while (idx < inline.length && inline[idx].type === NodeType.Text &&
      (inline[idx].text ?? '').trim().length === 0) {
      idx++;
    }
    return (inline.length - idx) === 1 && inline[idx].type === NodeType.FileImage;
  }

  /** 构建行内渲染单元（按链接/图片/占位/换行切分） */
  private buildRuns(inline: WikiNode[], style: number): InlineRun[] {
    const runs: InlineRun[] = [];
    let current: WikiNode[] = [];

    const flush = (): void => {
      if (current.length > 0) {
        runs.push({ kind: 'text', inline: current, style: style });
        current = [];
      }
    };

    for (const tok of inline) {
      const t = tok.type;
      if (t === NodeType.Text) {
        current.push(tok);
      } else if (t === NodeType.Bold || t === NodeType.Italic || t === NodeType.BoldItalic) {
        if (this.containsInteractive(tok.inline ?? [])) {
          flush();
          let childStyle = style;
          if (t === NodeType.Bold) {
            childStyle |= 1;
          }
          if (t === NodeType.Italic) {
            childStyle |= 2;
          }
          const childRuns = this.buildRuns(tok.inline ?? [], childStyle);
          for (const r of childRuns) {
            runs.push(r);
          }
        } else {
          current.push(tok);
        }
      } else if (t === NodeType.Link) {
        flush();
        runs.push({ kind: 'link', inline: tok.inline ?? [], target: tok.target, style: style });
      } else if (t === NodeType.FileImage) {
        flush();
        runs.push({
          kind: 'image',
          fileName: tok.fileName,
          width: tok.fileWidth,
          align: tok.fileAlign,
          style: style,
        });
      } else if (t === NodeType.Placeholder) {
        flush();
        runs.push({ kind: 'placeholder', reason: tok.reason, style: style });
      } else if (t === NodeType.LineBreak) {
        flush();
        runs.push({ kind: 'break', style: style });
      } else {
        current.push(tok);
      }
    }
    flush();
    return runs;
  }

  private containsInteractive(inline: WikiNode[]): boolean {
    for (const tok of inline) {
      const t = tok.type;
      if (t === NodeType.Link || t === NodeType.FileImage || t === NodeType.Placeholder ||
        t === NodeType.LineBreak) {
        return true;
      }
      if ((t === NodeType.Bold || t === NodeType.Italic || t === NodeType.BoldItalic) &&
        this.containsInteractive(tok.inline ?? [])) {
        return true;
      }
    }
    return false;
  }

  // ---------- 块级渲染 ----------

  @Builder
  renderBlock(node: WikiNode) {
    if (node.type === NodeType.Heading) {
      Text() {
        this.renderSpans(node.inline ?? [])
      }
      .fontSize(this.headingSize(node.level ?? 2))
      .fontWeight(FontWeight.Bold)
      .fontColor('#1c1c1e')
      .width('100%')
      .lineHeight(this.headingSize(node.level ?? 2) + 8)
      .margin({ top: 14, bottom: 6 })
    } else if (node.type === NodeType.Paragraph) {
      if (this.isSingleImage(node.inline ?? [])) {
        this.renderImageNode((node.inline as WikiNode[])[0])
      } else if (node.children !== undefined && (node.children as WikiNode[]).length > 0) {
        // 带块级 children 的段落（如解析兜底产生的多列表）：逐块渲染
        Column({ space: 0 }) {
          ForEach(node.children as WikiNode[], (n: WikiNode, idx: number) => {
            this.renderBlock(n)
          }, (n: WikiNode, idx: number) => 'pc' + this.renderKey + '_' + idx)
        }
        .width('100%')
      } else {
        this.renderInlineFlow(node.inline ?? [], '')
      }
    } else if (node.type === NodeType.Hr) {
      Divider().color('#d8d8dc').margin({ top: 10, bottom: 10 })
    } else if (node.type === NodeType.UnorderedList) {
      Column({ space: 4 }) {
        ForEach(node.children ?? [], (item: WikiNode, idx: number) => {
          this.renderListItem(item, '• ', idx)
        }, (item: WikiNode, idx: number) => 'ul' + idx)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 4, bottom: 4 })
    } else if (node.type === NodeType.OrderedList) {
      Column({ space: 4 }) {
        ForEach(node.children ?? [], (item: WikiNode, idx: number) => {
          this.renderListItem(item, (idx + 1) + '. ', idx)
        }, (item: WikiNode, idx: number) => 'ol' + idx)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 4, bottom: 4 })
    } else if (node.type === NodeType.ListItem || node.type === NodeType.Indent) {
      this.renderListItem(node, node.type === NodeType.Indent ? '　' : '• ', 0)
    } else if (node.type === NodeType.Table) {
      this.renderTable(node)
    } else if (node.type === NodeType.EnemyMap) {
      WikiMapView({
        area: node.mapArea ?? '',
        title: node.mapTitle ?? '',
        ratio: node.mapRatio ?? 1,
        markers: node.mapMarkers ?? [],
      })
    } else if (node.type === NodeType.FileImage) {
      this.renderImageNode(node)
    } else if (node.type === NodeType.Pre) {
      Text(node.text ?? '')
        .fontFamily('monospace')
        .fontSize(12)
        .fontColor('#3a3a3c')
        .backgroundColor('#f5f5f7')
        .padding(10)
        .width('100%')
        .borderRadius(6)
        .margin({ top: 4, bottom: 4 })
    } else if (node.type === NodeType.Placeholder) {
      this.renderPlaceholder(node)
    } else if (node.type === NodeType.Container) {
      Column({ space: 0 }) {
        ForEach(node.children ?? [], (n: WikiNode, idx: number) => {
          this.renderBlock(n)
        }, (n: WikiNode, idx: number) => 'c' + idx)
      }
      .width('100%')
      .alignItems(node.align === 'center' ? HorizontalAlign.Center : HorizontalAlign.Start)
      .padding(node.align === 'center' ? 0 : { left: 8 })
    } else if (node.type === NodeType.Link) {
      Text() {
        this.renderSpans(node.inline ?? [])
      }
      .fontSize(15)
      .fontColor('#2f6fed')
      .decoration({ type: TextDecorationType.Underline, color: '#2f6fed' })
      .onClick(() => {
        this.onNavigate(node.target ?? '')
      })
    } else if (node.type === NodeType.Text) {
      Text(node.text ?? '').fontSize(15).fontColor('#3a3a3c')
    } else {
      Text(node.text ?? '').fontSize(15).fontColor('#3a3a3c')
    }
  }

  @Builder
  renderListItem(item: WikiNode, marker: string, index: number) {
    Column({ space: 2 }) {
      this.renderInlineFlow(item.inline ?? [], marker)
      if (item.children !== undefined && item.children.length > 0) {
        Column({ space: 2 }) {
          ForEach(item.children ?? [], (n: WikiNode, idx: number) => {
            this.renderBlock(n)
          }, (n: WikiNode, idx: number) => 'li' + index + '_' + idx)
        }
        .width('100%')
        .margin({ left: 18 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  renderTable(node: WikiNode) {
    Column() {
      if (node.caption !== undefined && (node.caption as WikiNode[]).length > 0) {
        Text() {
          this.renderSpans(node.caption as WikiNode[])
        }
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#5a5a5e')
        .margin({ top: 6, bottom: 2 })
      }
      if (this.hasRowSpan(node)) {
        this.renderTableGrid(node)
      } else {
        Column() {
          ForEach(node.children ?? [], (row: WikiNode, rIdx: number) => {
            // Stretch：同行单元格拉伸到最高格的高度，保持行内等高（对齐 HTML 表格行为）
            Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Stretch }) {
              ForEach(row.children ?? [], (cell: WikiNode, cIdx: number) => {
                Column() {
                  this.renderInlineFlow(cell.inline ?? [], '')
                }
                .layoutWeight(cell.colSpan ?? 1)
                .padding(6)
                .backgroundColor(cell.type === NodeType.TableHeaderCell ? '#eef1f6' : '#ffffff')
                .border({ width: 1, color: '#d5d8dd' })
                .alignItems(HorizontalAlign.Start)
              }, (cell: WikiNode, cIdx: number) => 'cell' + rIdx + '_' + cIdx)
            }
            .width('100%')
          }, (row: WikiNode, rIdx: number) => 'row' + rIdx)
        }
        .border({ width: 1, color: '#c5c8cd' })
        .borderRadius(4)
        .margin({ top: 8, bottom: 8 })
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 表格是否含 rowspan 单元格（需要 Grid 显式跨行渲染） */
  private hasRowSpan(node: WikiNode): boolean {
    const rows = node.children ?? [];
    for (let r = 0; r < rows.length; r++) {
      const cells = (rows[r] as WikiNode).children ?? [];
      for (let c = 0; c < cells.length; c++) {
        if ((cells[c] as WikiNode).rowSpan !== undefined && (cells[c] as WikiNode).rowSpan as number > 1) {
          return true;
        }
      }
    }
    return false;
  }

  /** 展平表格为 (cell,row) 列表，供 Grid 渲染 */
  private flattenCells(node: WikiNode): TableCellItem[] {
    const out: TableCellItem[] = [];
    const rows = node.children ?? [];
    for (let r = 0; r < rows.length; r++) {
      const cells = (rows[r] as WikiNode).children ?? [];
      for (let c = 0; c < cells.length; c++) {
        out.push({ cell: cells[c] as WikiNode, row: r });
      }
    }
    return out;
  }

  private tableCols(node: WikiNode): number {
    let max = 0;
    const rows = node.children ?? [];
    for (let r = 0; r < rows.length; r++) {
      const cells = (rows[r] as WikiNode).children ?? [];
      for (let c = 0; c < cells.length; c++) {
        const cell = cells[c] as WikiNode;
        const end = (cell.colIndex ?? 0) + (cell.colSpan ?? 1);
        if (end > max) {
          max = end;
        }
      }
    }
    return max;
  }

  private colsTemplate(node: WikiNode): string {
    const n = this.tableCols(node);
    let t = '';
    for (let k = 0; k < n; k++) {
      t += (k > 0 ? ' ' : '') + '1fr';
    }
    return t;
  }

  private rowsTemplate(node: WikiNode): string {
    const n = (node.children ?? []).length;
    let t = '';
    for (let k = 0; k < n; k++) {
      t += (k > 0 ? ' ' : '') + '1fr';
    }
    return t;
  }

  /** 网格表格内图标尺寸（vp）：按单元格纵向跨行数缩放——跨行越多可用空间越大，图标越大。
   *  对齐 wiki 源 60/42/30px 的层级（起始属性：左列跨行多最大，右列单行最小；收尾属性则反之，按空间自适应） */
  private gridIconVp(rs: number): number {
    if (rs >= 3) {
      return 56;
    }
    if (rs === 2) {
      return 44;
    }
    return 32;
  }

  /** 估算表格高度（vp）：按行内容，rowspan 单元格高度分摊到每行；预留图标标签(caption)高度 */
  private gridHeightVp(node: WikiNode): number {
    const rows = node.children ?? [];
    let total = 0;
    for (let r = 0; r < rows.length; r++) {
      let rh = 68;
      const cells = (rows[r] as WikiNode).children ?? [];
      for (let c = 0; c < cells.length; c++) {
        const cell = cells[c] as WikiNode;
        const rs = cell.rowSpan !== undefined ? cell.rowSpan : 1;
        // 图标按跨行数缩放，高度分摊到每行
        const perRow = Math.ceil(this.gridIconVp(rs) / rs) + 36;
        if (perRow > rh) {
          rh = perRow;
        }
      }
      total += rh;
    }
    return total;
  }

  /** Grid 单元格内容：单个图标 → 图标+元素名标签；否则行内渲染 */
  @Builder
  gridCellContent(cell: WikiNode) {
    if (this.isSingleImage(cell.inline ?? [])) {
      Column() {
        WikiImage({ fileName: (cell.inline as WikiNode[])[0].fileName ?? '',
          fileWidth: this.gridIconVp(cell.rowSpan !== undefined ? cell.rowSpan : 1), block: true })
        if ((cell.inline as WikiNode[])[0].caption !== undefined &&
          ((cell.inline as WikiNode[])[0].caption as WikiNode[]).length > 0) {
          Text() {
            this.renderSpans((cell.inline as WikiNode[])[0].caption as WikiNode[])
          }
          .fontSize(12)
          .fontColor('#8a8a8e')
          .textAlign(TextAlign.Center)
          .margin({ top: 2 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    } else {
      this.renderInlineFlow(cell.inline ?? [], '')
    }
  }

  @Builder
  renderTableGrid(node: WikiNode) {
    Grid() {
      ForEach(this.flattenCells(node), (item: TableCellItem, idx: number) => {
        GridItem() {
          Column() {
            this.gridCellContent(item.cell)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .padding(4)
        }
        .backgroundColor(item.cell.type === NodeType.TableHeaderCell ? '#eef1f6' : '#ffffff')
        .border({ width: 1, color: '#c5c8cd' })
        .rowStart(item.row)
        .rowEnd(item.row + (item.cell.rowSpan ?? 1) - 1)
        .columnStart(item.cell.colIndex ?? 0)
        .columnEnd((item.cell.colIndex ?? 0) + (item.cell.colSpan ?? 1) - 1)
      }, (item: TableCellItem, idx: number) => 'grid' + idx)
    }
    .columnsTemplate(this.colsTemplate(node))
    .rowsTemplate(this.rowsTemplate(node))
    .height(this.gridHeightVp(node))
    .width('100%')
    .borderRadius(4)
    .margin({ top: 8, bottom: 8 })
  }

  @Builder
  renderImageNode(node: WikiNode) {
    Column() {
      WikiImage({ fileName: node.fileName ?? '', fileWidth: node.fileWidth ?? 0, block: true })
      if (node.caption !== undefined && (node.caption as WikiNode[]).length > 0) {
        Text() {
          this.renderSpans(node.caption as WikiNode[])
        }
        .fontSize(12)
        .fontColor('#8a8a8e')
        .textAlign(TextAlign.Center)
        .margin({ top: 2 })
      }
    }
    .width('100%')
    .alignItems(node.fileAlign === 'center' ? HorizontalAlign.Center : HorizontalAlign.Start)
    .margin({ top: 6, bottom: 6 })
  }

  @Builder
  renderPlaceholder(node: WikiNode) {
    Text('⚠ ' + (node.reason ?? '内容暂不支持渲染'))
      .fontSize(12)
      .fontColor('#8a6d1a')
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor('#fdf6e3')
      .borderRadius(6)
      .width('100%')
      .margin({ top: 4, bottom: 4 })
  }

  // ---------- 行内渲染 ----------

  @Builder
  renderInlineFlow(inline: WikiNode[], prefix: string) {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Baseline }) {
      if (prefix.length > 0) {
        Text(prefix)
          .fontSize(15)
          .lineHeight(22)
          .fontColor('#3a3a3c')
      }
      this.renderRuns(this.buildRuns(inline, 0))
    }
    .width('100%')
  }

  @Builder
  renderRuns(runs: InlineRun[]) {
    ForEach(runs, (run: InlineRun, idx: number) => {
      if (run.kind === 'text') {
        Text() {
          this.renderSpans(run.inline ?? [])
        }
        .fontSize(15)
        .lineHeight(22)
        .fontColor('#3a3a3c')
        .fontWeight((run.style & 1) !== 0 ? FontWeight.Bold : FontWeight.Normal)
        .fontStyle((run.style & 2) !== 0 ? FontStyle.Italic : FontStyle.Normal)
      } else if (run.kind === 'link') {
        Text() {
          this.renderSpans(run.inline ?? [])
        }
        .fontSize(15)
        .lineHeight(22)
        .fontColor('#2f6fed')
        .decoration({ type: TextDecorationType.Underline, color: '#2f6fed' })
        .onClick(() => {
          this.onNavigate(run.target ?? '')
        })
      } else if (run.kind === 'image') {
        if (run.align === 'center') {
          Column() {
            WikiImage({ fileName: run.fileName ?? '', fileWidth: run.width ?? 0, block: true })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
        } else {
          WikiImage({ fileName: run.fileName ?? '', fileWidth: run.width ?? 0, block: false })
        }
      } else if (run.kind === 'placeholder') {
        Text('⚠ ' + (run.reason ?? '内容暂不支持渲染'))
          .fontSize(12)
          .fontColor('#8a6d1a')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('#fdf6e3')
          .borderRadius(6)
          .margin({ top: 2, bottom: 2 })
      } else if (run.kind === 'break') {
        Column() {
        }
        .width('100%')
        .height(0)
      } else {
        Text('')
      }
    }, (run: InlineRun, idx: number) => 'r' + idx)
  }

  /** 把行内节点展平为带样式的文本片段 */
  private flattenInline(inline: WikiNode[], bold: boolean, italic: boolean): StyledText[] {
    const out: StyledText[] = [];
    for (const tok of inline) {
      const t = tok.type;
      if (t === NodeType.Text) {
        out.push({ text: tok.text ?? '', bold: bold, italic: italic });
      } else if (t === NodeType.Bold) {
        const sub = this.flattenInline(tok.inline ?? [], true, italic);
        for (const s of sub) {
          out.push(s);
        }
      } else if (t === NodeType.Italic) {
        const sub = this.flattenInline(tok.inline ?? [], bold, true);
        for (const s of sub) {
          out.push(s);
        }
      } else if (t === NodeType.BoldItalic) {
        const sub = this.flattenInline(tok.inline ?? [], true, true);
        for (const s of sub) {
          out.push(s);
        }
      } else {
        out.push({ text: tok.text ?? '', bold: bold, italic: italic });
      }
    }
    return out;
  }

  @Builder
  renderSpans(inline: WikiNode[]) {
    ForEach(this.flattenInline(inline, false, false), (frag: StyledText, idx: number) => {
      Span(frag.text)
        .fontWeight(frag.bold ? FontWeight.Bold : FontWeight.Normal)
        .fontStyle(frag.italic ? FontStyle.Italic : FontStyle.Normal)
    }, (frag: StyledText, idx: number) => 's' + idx)
  }
}

/** 带样式的文本片段（Span 仅支持叶子文本） */
interface StyledText {
  text: string;
  bold: boolean;
  italic: boolean;
}

/** 表格单元格（含所在行号，供 Grid 显式定位） */
interface TableCellItem {
  cell: WikiNode;
  row: number;
}
