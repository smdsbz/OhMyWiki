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
  height?: number;
  align?: string;
  reason?: string;
  style: number; // 1=bold 2=italic
}

/** 表格行 + 原始行号（过滤后保持稳定 key） */
interface TableRowPair {
  row: WikiNode;
  ri: number;
}

/** 富文本 Span：文本片段（可带链接） */
interface RichSpan {
  text: string;
  bold: boolean;
  italic: boolean;
  link: boolean;
  target: string;
}

/** 行内渲染段：连续 text/link 合并为一个 rich 段（单个 Text 内多 Span，支持段内自然换行） */
interface InlineSeg {
  kind: string; // 'rich' | 'image' | 'placeholder' | 'break'
  spans?: RichSpan[];
  fileName?: string;
  width?: number;
  height?: number;
  align?: string;
  reason?: string;
}

/** 行数达到该阈值的表格自动显示搜索框（任务/物品等 #ask 查询大表） */
const TABLE_FILTER_MIN_ROWS = 10;

/**
 * wiki 节点树渲染器：把 WikiNode[] 渲染为 ArkUI 组件。
 * 行内文本用 Flex wrap + 分段 Text（链接为独立可点击 Text）。
 */
@Component
export struct WikiContentView {
  @Prop nodes: WikiNode[] = [];
  @Prop @Watch('onRenderKeyChange') renderKey: number = 0;
  @State tableFilters: Map<string, string> = new Map();
  onNavigate: (title: string) => void = (title: string) => {
  };

  /** 页面切换（renderKey 变化）时清空表格过滤状态 */
  onRenderKeyChange(): void {
    if (this.tableFilters.size > 0) {
      this.tableFilters = new Map();
    }
  }

  build() {
    Column({ space: 0 }) {
      ForEach(this.nodes, (node: WikiNode, index: number) => {
        this.renderBlock(node, 'b' + index)
      }, (node: WikiNode, index: number) => 'k' + this.renderKey + '_' + index)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ---------- 表格搜索过滤 ----------

  private setTableFilter(key: string, v: string): void {
    const cur = this.tableFilters.get(key) ?? '';
    if (cur === v) {
      return;
    }
    const m = new Map(this.tableFilters);
    m.set(key, v);
    this.tableFilters = m;
  }

  private tableFilterOf(key: string): string {
    return (this.tableFilters.get(key) ?? '').trim().toLowerCase();
  }

  private clearTableFilter(key: string): void {
    if ((this.tableFilters.get(key) ?? '').length === 0) {
      return;
    }
    const m = new Map(this.tableFilters);
    m.set(key, '');
    this.tableFilters = m;
  }

  /** 递归收集节点全部文本（含链接目标/文件名），用于行过滤匹配 */
  private collectNodeText(node: WikiNode, sb: string[]): void {
    if (node.text !== undefined && node.text !== null) {
      sb.push(node.text);
    }
    if (node.target !== undefined && node.target !== null) {
      sb.push(node.target);
    }
    const inline = node.inline;
    if (inline !== undefined && inline !== null) {
      for (const n of inline) {
        this.collectNodeText(n, sb);
      }
    }
    const children = node.children;
    if (children !== undefined && children !== null) {
      for (const n of children) {
        this.collectNodeText(n, sb);
      }
    }
  }

  /** 行匹配：关键词按空白分词，全部包含才显示（大小写不敏感） */
  private rowMatches(row: WikiNode, terms: string[]): boolean {
    const sb: string[] = [];
    this.collectNodeText(row, sb);
    const hay = sb.join(' ').toLowerCase();
    for (const t of terms) {
      if (hay.indexOf(t) < 0) {
        return false;
      }
    }
    return true;
  }

  /** 该表格是否显示搜索框 */
  private tableFilterable(node: WikiNode): boolean {
    const rows = (node.children ?? []) as WikiNode[];
    return rows.length >= TABLE_FILTER_MIN_ROWS && !this.hasRowSpan(node);
  }

  /** 过滤后的行列表（首行表头始终保留） */
  private visibleRows(node: WikiNode, tKey: string): TableRowPair[] {
    const allRows = (node.children ?? []) as WikiNode[];
    const out: TableRowPair[] = [];
    const kw = this.tableFilterOf(tKey);
    if (kw.length === 0 || !this.tableFilterable(node)) {
      for (let i = 0; i < allRows.length; i++) {
        out.push({ row: allRows[i], ri: i });
      }
      return out;
    }
    const terms = kw.split(/\s+/).filter((s: string) => s.length > 0);
    for (let i = 0; i < allRows.length; i++) {
      if (i === 0 || this.rowMatches(allRows[i], terms)) {
        out.push({ row: allRows[i], ri: i });
      }
    }
    return out;
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
          height: tok.fileHeight,
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
  renderBlock(node: WikiNode, tKey: string) {
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
            this.renderBlock(n, tKey + 'p' + idx)
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
          this.renderListItem(item, '• ', idx, tKey + 'u')
        }, (item: WikiNode, idx: number) => 'ul' + idx)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 4, bottom: 4 })
    } else if (node.type === NodeType.OrderedList) {
      Column({ space: 4 }) {
        ForEach(node.children ?? [], (item: WikiNode, idx: number) => {
          this.renderListItem(item, (idx + 1) + '. ', idx, tKey + 'o')
        }, (item: WikiNode, idx: number) => 'ol' + idx)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 4, bottom: 4 })
    } else if (node.type === NodeType.ListItem || node.type === NodeType.Indent) {
      this.renderListItem(node, node.type === NodeType.Indent ? '　' : '• ', 0, tKey + 'i')
    } else if (node.type === NodeType.Table) {
      this.renderTable(node, tKey + 't')
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
          this.renderBlock(n, tKey + 'c' + idx)
        }, (n: WikiNode, idx: number) => 'c' + idx)
      }
      .width('100%')
      .alignItems(node.align === 'center' ? HorizontalAlign.Center : HorizontalAlign.Start)
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
  renderListItem(item: WikiNode, marker: string, index: number, lKey: string) {
    Column({ space: 2 }) {
      this.renderInlineFlow(item.inline ?? [], marker)
      if (item.children !== undefined && item.children.length > 0) {
        Column({ space: 2 }) {
          ForEach(item.children ?? [], (n: WikiNode, idx: number) => {
            this.renderBlock(n, lKey + '_' + index + '_' + idx)
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
  renderTable(node: WikiNode, tKey: string) {
    if ((node.children ?? []).length > 0) {
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
      if (this.tableFilterable(node)) {
        // 大表格搜索框：实时过滤行
        Row({ space: 8 }) {
          TextInput({ placeholder: '搜索表格内容…', text: this.tableFilters.get(tKey) ?? '' })
            .layoutWeight(1)
            .height(38)
            .fontSize(14)
            .padding({ left: 12, right: 12 })
            .backgroundColor('#f2f2f7')
            .borderRadius(10)
            .onChange((v: string) => {
              this.setTableFilter(tKey, v);
            })
          if (this.tableFilterOf(tKey).length > 0) {
            Text((this.visibleRows(node, tKey).length - 1) + '/' + ((node.children ?? []).length - 1))
              .fontSize(12)
              .fontColor('#8a8a8e')
            Text('✕')
              .fontSize(14)
              .fontColor('#8a8a8e')
              .padding(6)
              .onClick(() => {
                this.clearTableFilter(tKey);
              })
          }
        }
        .width('100%')
        .margin({ top: 8, bottom: 4 })
      }
      if (this.hasRowSpan(node)) {
        this.renderTableGrid(node)
      } else {
        Column() {
          ForEach(this.visibleRows(node, tKey), (item: TableRowPair, vIdx: number) => {
            // Stretch：同行单元格拉伸到最高格的高度，保持行内等高（对齐 HTML 表格行为）
            Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Stretch }) {
              ForEach(item.row.children ?? [], (cell: WikiNode, cIdx: number) => {
                Column() {
                  this.renderInlineFlow(cell.inline ?? [], '')
                }
                .layoutWeight(cell.colSpan ?? 1)
                .padding(6)
                .backgroundColor(cell.type === NodeType.TableHeaderCell ? '#eef1f6' : '#ffffff')
                .border({ width: 1, color: '#d5d8dd' })
                .alignItems(HorizontalAlign.Start)
              }, (cell: WikiNode, cIdx: number) => 'cell' + item.ri + '_' + cIdx)
            }
            .width('100%')
          }, (item: TableRowPair, vIdx: number) => 'frow_' + item.ri)
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
  }

  /** 表格是否含 rowspan 单元格（需要 Grid 显式跨行渲染） */
  private hasRowSpan(node: WikiNode): boolean {
    const rows = (node.children ?? []) as WikiNode[];
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
    const rows = (node.children ?? []) as WikiNode[];
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
    const rows = (node.children ?? []) as WikiNode[];
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
    const n = ((node.children ?? []) as WikiNode[]).length;
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
    const rows = (node.children ?? []) as WikiNode[];
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
          fileWidth: this.gridIconVp(cell.rowSpan !== undefined ? cell.rowSpan : 1), block: false })
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
      WikiImage({ fileName: node.fileName ?? '', fileWidth: node.fileWidth ?? 0,
        fileHeight: node.fileHeight ?? 0, block: true })
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
    // 块级图片：容器全宽居中，固定宽（限宽/限高注释）图片与说明文字水平居中
    .width('100%')
    .alignItems(HorizontalAlign.Center)
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
      this.renderSegments(this.buildSegments(inline, prefix))
    }
    .width('100%')
  }

  /** 把 run 列表分组成渲染段：连续 text/link/break 合并为单个 rich 段（一个 Text 多 Span，
   *  换行发生在文字内部而非元素边界，修复"链接/标号独占一行"）；<br> 忠实渲染为换行，
   *  以 Span('\n') 并入同一 Text（仅调整换行的渲染方式，不改数据语义）；图片/占位保持独立段 */
  private buildSegments(inline: WikiNode[], prefix: string): InlineSeg[] {
    const runs = this.buildRuns(inline, 0);
    const segs: InlineSeg[] = [];
    let buf: RichSpan[] = [];
    const flushRich = (): void => {
      if (buf.length > 0) {
        segs.push({ kind: 'rich', spans: this.normalizeSpans(buf) });
        buf = [];
      }
    };
    for (const r of runs) {
      if (r.kind === 'text' || r.kind === 'link') {
        const isLink = r.kind === 'link';
        const spans = this.flattenRich(r.inline ?? [], r.style, isLink, isLink ? (r.target ?? '') : '');
        for (const s of spans) {
          buf.push(s);
        }
      } else if (r.kind === 'break') {
        // <br>：并入当前 rich 段为换行符（同一 Text 内换行，行高一致）
        buf.push({ text: '\n', bold: false, italic: false, link: false, target: '' });
      } else {
        flushRich();
        if (r.kind === 'image') {
          segs.push({ kind: 'image', fileName: r.fileName, width: r.width, height: r.height, align: r.align });
        } else if (r.kind === 'placeholder') {
          segs.push({ kind: 'placeholder', reason: r.reason });
        } else if (r.kind === 'break') {
          segs.push({ kind: 'break' });
        }
      }
    }
    flushRich();
    // 列表标号并入首个 rich 段（避免标号单独占一行）
    if (prefix.length > 0) {
      const mk: RichSpan = { text: prefix, bold: false, italic: false, link: false, target: '' };
      const first = segs.length > 0 ? segs[0] : null;
      if (first !== null && first.kind === 'rich' && first.spans !== undefined) {
        first.spans.unshift(mk);
      } else {
        segs.unshift({ kind: 'rich', spans: [mk] });
      }
    }
    return segs;
  }

  /** 合并相邻同样式 Span（仅结构归并，文本内容忠实于源数据——空格等原样保留）。
   *  注：中文避头尾（行首不出、。・等） ArkUI Text 引擎不支持：U+2060 joiner、
   *  lineBreakStrategy(HIGH_QUALITY)、wordBreak(BREAK_WORD) 均实测无效，勿再尝试 */
  private normalizeSpans(spans: RichSpan[]): RichSpan[] {
    const merged: RichSpan[] = [];
    for (const s of spans) {
      const last = merged.length > 0 ? merged[merged.length - 1] : null;
      if (last !== null && last.bold === s.bold && last.italic === s.italic &&
        last.link === s.link && last.target === s.target) {
        last.text += s.text;
      } else {
        merged.push({ text: s.text, bold: s.bold, italic: s.italic, link: s.link, target: s.target });
      }
    }
    return merged;
  }

  /** 展平行内节点为富文本 Span（保留链接标记与样式） */
  private flattenRich(inline: WikiNode[], style: number, link: boolean, target: string): RichSpan[] {
    const out: RichSpan[] = [];
    const bold = (style & 1) !== 0;
    const italic = (style & 2) !== 0;
    for (const tok of inline) {
      const t = tok.type;
      if (t === NodeType.Text) {
        out.push({ text: tok.text ?? '', bold: bold, italic: italic, link: link, target: target });
      } else if (t === NodeType.Bold || t === NodeType.Italic || t === NodeType.BoldItalic) {
        let cs = style;
        if (t === NodeType.Bold || t === NodeType.BoldItalic) {
          cs |= 1;
        }
        if (t === NodeType.Italic || t === NodeType.BoldItalic) {
          cs |= 2;
        }
        const sub = this.flattenRich(tok.inline ?? [], cs, link, target);
        for (const s of sub) {
          out.push(s);
        }
      } else if (t === NodeType.Link) {
        const sub = this.flattenRich(tok.inline ?? [], style, true, tok.target ?? '');
        for (const s of sub) {
          out.push(s);
        }
      } else {
        out.push({ text: tok.text ?? '', bold: bold, italic: italic, link: link, target: target });
      }
    }
    return out;
  }

  @Builder
  renderSegments(segs: InlineSeg[]) {
    ForEach(segs, (seg: InlineSeg, idx: number) => {
      if (seg.kind === 'rich') {
        Text() {
          ForEach(seg.spans ?? [], (sp: RichSpan, si: number) => {
            Span(sp.text)
              .fontWeight(sp.bold ? FontWeight.Bold : FontWeight.Normal)
              .fontStyle(sp.italic ? FontStyle.Italic : FontStyle.Normal)
              .fontColor(sp.link ? '#2f6fed' : '#3a3a3c')
              .decoration(sp.link
                ? { type: TextDecorationType.Underline, color: '#2f6fed' }
                : { type: TextDecorationType.None })
              .onClick(() => {
                if (sp.link && sp.target.length > 0) {
                  this.onNavigate(sp.target);
                }
              })
          }, (sp: RichSpan, si: number) => 'sp' + idx + '_' + si)
        }
        .fontSize(15)
        .lineHeight(22)
      } else if (seg.kind === 'image') {
        // 块级图片：全宽容器居中，固定宽（限宽/限高注释）图片水平居中，铺满图不受影响
        Column() {
          WikiImage({ fileName: seg.fileName ?? '', fileWidth: seg.width ?? 0,
            fileHeight: seg.height ?? 0, block: true })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      } else if (seg.kind === 'placeholder') {
        Text('⚠ ' + (seg.reason ?? '内容暂不支持渲染'))
          .fontSize(12)
          .fontColor('#8a6d1a')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('#fdf6e3')
          .borderRadius(6)
          .margin({ top: 2, bottom: 2 })
      } else if (seg.kind === 'break') {
        Column() {
        }
        .width('100%')
        .height(0)
      } else {
        Text('')
      }
    }, (seg: InlineSeg, idx: number) => 'seg' + idx)
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
