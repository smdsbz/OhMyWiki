import { NodeType, WikiNode, GaugeSeg } from '../../model/WikiTypes';
import { HtmlBoxStyle } from '../siteadapter/SiteAdapter';
import { adaptSourceBg, adaptSourceFg } from './SourceColor';
import { WikiImage } from './WikiImage';
import { WikiMapView } from './WikiMapView';

/** 行内渲染单元 */
interface InlineRun {
  kind: string; // 'text' | 'link' | 'image' | 'placeholder' | 'break' | 'gauge' | 'toggle'
  inline?: WikiNode[];
  target?: string;
  fileName?: string;
  width?: number;
  height?: number;
  align?: string;
  reason?: string;
  gaugeSegs?: GaugeSeg[];
  gaugeHeight?: number;
  style: number; // 1=bold 2=italic
  color?: string; // 行内颜色（继承自 Color 节点）
  fontSize?: number; // 行内字号（继承自 <small>/<big>）
  bgColor?: string; // 行内背景色（继承自 Color 节点，如乱入黄底）
  toggleId?: string; // 折叠开关目标（mw-customtoggle-X）
}

/** 表格行 + 原始行号（过滤后保持稳定 key） */
interface TableRowPair {
  row: WikiNode;
  ri: number;
}

/** 渲染项：普通块 / 巨型表拆分后的表头与行 / 首尾安全区留白 / 后台查询进度条（LazyForEach 数据单元） */
interface RenderItem {
  kind: 'block' | 'thead' | 'trow' | 'pad' | 'ask';
  /** 所属顶层块在 nodes 中的下标（key 与过滤键的组成部分） */
  ti: number;
  block?: WikiNode;
  /** thead/trow 所属表格节点 */
  table?: WikiNode;
  /** trow 行节点 */
  row?: WikiNode;
  /** trow 原始行号（key 稳定） */
  ri?: number;
  /** trow 是否为可见首/末行（外边框与圆角归属） */
  first?: boolean;
  last?: boolean;
  /** pad：留白高度（vp）。List 自身不能设 padding——那是视口内缩，
   *  内容会被裁在标题栏/导航条之外（沉浸失效），留白必须作为内容滚动 */
  padVp?: number;
}

/** LazyForEach 数据源：块/拆分行渲染项 */
class RenderItemSource implements IDataSource {
  private items: RenderItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): RenderItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  reload(items: RenderItem[]): void {
    this.items = items;
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }

  /** thead(ti) 的下标；不存在返回 -1 */
  headIndex(ti: number): number {
    for (let i = 0; i < this.items.length; i++) {
      const it = this.items[i];
      if (it.kind === 'thead' && it.ti === ti) {
        return i;
      }
    }
    return -1;
  }

  /** thead(ti) 之后连续 trow(ti) 的数量 */
  rowCountAfter(ti: number): number {
    let n = 0;
    for (let i = this.headIndex(ti) + 1; i < this.items.length; i++) {
      const it = this.items[i];
      if (it.kind === 'trow' && it.ti === ti) {
        n++;
      } else {
        break;
      }
    }
    return n;
  }

  /** 区间替换（过滤增删行）：thead 不在区间内 → 不重建、搜索框焦点不丢 */
  replaceRange(start: number, oldCount: number, newItems: RenderItem[]): void {
    if (oldCount > 0) {
      this.items.splice(start, oldCount);
      for (let i = start + oldCount - 1; i >= start; i--) {
        for (const l of this.listeners) {
          l.onDataDelete(i);
        }
      }
    }
    if (newItems.length > 0) {
      for (let i = 0; i < newItems.length; i++) {
        this.items.splice(start + i, 0, newItems[i]);
      }
      for (let i = 0; i < newItems.length; i++) {
        for (const l of this.listeners) {
          l.onDataAdd(start + i);
        }
      }
    }
  }

  /** 单点插入/删除（进度条项的出现与消失） */
  insertAt(idx: number, item: RenderItem): void {
    this.items.splice(idx, 0, item);
    for (const l of this.listeners) {
      l.onDataAdd(idx);
    }
  }

  removeAt(idx: number): void {
    this.items.splice(idx, 1);
    for (const l of this.listeners) {
      l.onDataDelete(idx);
    }
  }
}

/** 富文本 Span：文本片段（可带链接） */
interface RichSpan {
  text: string;
  bold: boolean;
  italic: boolean;
  link: boolean;
  target: string;
  color: string; // 行内颜色（'' = 默认）
  fontSize?: number; // 行内字号（0/未设 = 默认）
  bgColor?: string; // 行内背景色（'' /未设 = 透明）
}

/** 行内渲染段：连续 text/link 合并为一个 rich 段（单个 Text 内多 Span，支持段内自然换行） */
interface InlineSeg {
  kind: string; // 'rich' | 'image' | 'placeholder' | 'break' | 'gauge' | 'toggle'
  spans?: RichSpan[];
  fileName?: string;
  width?: number;
  height?: number;
  align?: string;
  reason?: string;
  gaugeSegs?: GaugeSeg[];
  gaugeHeight?: number;
  toggleId?: string;
}

/** 行数达到该阈值的表格自动显示搜索框（任务/物品等 #ask 查询大表） */
const TABLE_FILTER_MIN_ROWS = 10;
/** 列数超过该阈值的宽表启用横向滚动（如采集点一览 10 列），避免列宽被压到逐字换行 */
const WIDE_TABLE_MIN_COLS = 7;
/** 宽表单列最小宽度（vp） */
const TABLE_COL_MIN_VP = 86;
/** 宽表冻结首列宽度（vp） */
const WIDE_TABLE_FROZEN_W = 120;
/** 无 rowspan 非宽表超过该行数 → 按行拆分为独立渲染项（武器派生单表 400-600 行，
 *  整表一个块会让任何按块分批/懒加载失效） */
const TABLE_SPLIT_MIN_ROWS = 40;
/** 顶部留白：状态栏+迷你标题栏全高（ignoreLayoutSafeArea 后视口含状态栏，实测 104vp） */
const TOP_PAD_VP = 104;
/** 底部留白（vp） */
const BOTTOM_PAD_VP = 32;

/**
 * wiki 节点树渲染器：把 WikiNode[] 渲染为 ArkUI 组件。
 * 外层 List + LazyForEach 按视口懒构建（大页面 5-15 万组件不再一次性全量构建）；
 * 巨型普通表（武器派生单表数百行）拆成 thead + 独立行渲染项。
 * 行内文本用 Flex wrap + 分段 Text（链接为独立可点击 Text）。
 */
@Component
export struct WikiContentView {
  /** 节点树按引用共享（@Prop 会在每次同步时深拷贝整棵树，大页面不可承受） */
  @Link nodes: WikiNode[];
  @Prop @Watch('onRenderKeyChange') renderKey: number = 0;
  /** 阶段 2 后台查询进度：作为列表首项渲染（页面内容顶端、随内容滚动） */
  @Prop @Watch('onAskingChange') asking: boolean = false;
  @Prop progressDone: number = 0;
  @Prop progressTotal: number = 0;
  /** 外部滚动控制器（HDS 标题栏模糊绑定） */
  scroller: Scroller | null = null;
  private source: RenderItemSource = new RenderItemSource();
  /** 渲染项代数：每次 rebuild 递增并入 key。LazyForEach 的 onDataReloaded
   *  按 key 复用旧条目——key 不变就不重建（阶段2回填后旧占位条目残留），
   *  换代 key 强制全量重建 */
  private itemGen: number = 0;
  @State tableFilters: Map<string, string> = new Map();
  /** 宽表冻结列行高同步表（key: 表key_行号 → 滚动区实测行高 vp） */
  @State wideRowH: Map<string, number> = new Map();
  /** 折叠容器展开状态（key: collapsibleId；缺省值由节点 collapsed 字段决定，rebuild 时播种） */
  @State expandedMap: Map<string, boolean> = new Map();
  /** 系统深浅色（EntryAbility 写入）：源数据颜色按显示模式换算 */
  @StorageProp('isDark') @Watch('onDarkChange') isDark: boolean = false;
  /** 站点 HTML class → 盒样式表（Reader 从适配器解析传入；引擎不内置站点 CSS 知识） */
  boxStyles: Map<string, HtmlBoxStyle> | null = null;
  onNavigate: (title: string) => void = (title: string) => {
  };

  aboutToAppear(): void {
    this.rebuildItems();
  }

  /** 深浅色切换：源数据字符串色绑定需整树重建（$r 资源色系统自动刷新） */
  onDarkChange(): void {
    this.rebuildItems();
  }

  /** 查询开始/结束 → 进度条项插入/移除（紧跟顶部留白之后，index 1） */
  onAskingChange(): void {
    if (this.asking) {
      if (!(this.source.totalCount() > 1 && this.source.getData(1).kind === 'ask')) {
        this.source.insertAt(1, { kind: 'ask', ti: 0 });
      }
    } else if (this.source.totalCount() > 1 && this.source.getData(1).kind === 'ask') {
      this.source.removeAt(1);
    }
  }

  /** 页面切换（renderKey 变化）时清空表格过滤状态与行高同步表并重建渲染项 */
  onRenderKeyChange(): void {
    if (this.tableFilters.size > 0) {
      this.tableFilters = new Map();
    }
    if (this.wideRowH.size > 0) {
      this.wideRowH = new Map();
    }
    this.rebuildItems();
  }

  /** 播种折叠容器默认展开态（mw-collapsed → 收起）：发生在任何 UI 读取前，直接写入即可 */
  private seedCollapsibleDefaults(nodes: WikiNode[]): void {
    const walk = (list: WikiNode[]): void => {
      for (const n of list) {
        if (n.collapsibleId !== undefined && !this.expandedMap.has(n.collapsibleId)) {
          this.expandedMap.set(n.collapsibleId, !(n.collapsed === true));
        }
        if (n.children !== undefined) {
          walk(n.children);
        }
        if (n.inline !== undefined) {
          walk(n.inline);
        }
        if (n.caption !== undefined) {
          walk(n.caption);
        }
      }
    };
    walk(nodes);
  }

  private collapsibleOpen(node: WikiNode): boolean {
    return this.expandedMap.get(node.collapsibleId ?? '') ?? !(node.collapsed === true);
  }

  private toggleCollapse(id: string): void {
    const m = new Map(this.expandedMap);
    m.set(id, !(m.get(id) ?? false));
    this.expandedMap = m;
  }

  /** 节点 htmlClass（可多 token）逐 token 查站点样式表 */
  private boxStyleFor(node: WikiNode): HtmlBoxStyle | null {
    if (this.boxStyles === null || node.htmlClass === undefined || node.htmlClass.length === 0) {
      return null;
    }
    for (const token of node.htmlClass.split(/\s+/)) {
      const st = this.boxStyles.get(token);
      if (st !== undefined) {
        return st;
      }
    }
    return null;
  }

  private boxBgOf(node: WikiNode): ResourceColor {
    const st = this.boxStyleFor(node);
    if (st === null) {
      return Color.Transparent;
    }
    const v = this.isDark ? st.bgDark : st.bgLight;
    return v !== undefined && v.length > 0 ? v : Color.Transparent;
  }

  private boxBorderOf(node: WikiNode): BorderOptions {
    const st = this.boxStyleFor(node);
    if (st === null) {
      return { width: 0 };
    }
    const v = this.isDark ? st.borderDark : st.borderLight;
    if (v === undefined || v.length === 0) {
      return { width: 0 };
    }
    if (st.underline === true) {
      return { width: { bottom: 2 }, color: v };
    }
    return { width: 1, color: v };
  }

  private boxRadiusOf(node: WikiNode): number {
    const st = this.boxStyleFor(node);
    return st !== null && st.radiusVp !== undefined ? st.radiusVp : 0;
  }

  private boxPadOf(node: WikiNode): number | Padding {
    const st = this.boxStyleFor(node);
    return st !== null && st.padVp !== undefined ? st.padVp : 0;
  }

  build() {
    List({ scroller: this.scroller === null ? new Scroller() : this.scroller, space: 0 }) {
      LazyForEach(this.source, (item: RenderItem) => {
        this.renderItem(item)
      }, (item: RenderItem) => this.itemKey(item))
    }
    .width('100%')
    .height('100%')
    .edgeEffect(EdgeEffect.None)
    .scrollBar(BarState.Auto)
    // 滚动视口延伸到物理屏幕底部：内容从半透明导航条下方滑过。
    // 必须挂在 List 本体（挂自定义组件用法上不传导进内部 List）
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  // ---------- 渲染项（LazyForEach 单元） ----------

  private itemKey(item: RenderItem): string {
    if (item.kind === 'block') {
      return 'b' + this.itemGen + '_' + item.ti;
    }
    if (item.kind === 'thead') {
      return 'th' + this.itemGen + '_' + item.ti;
    }
    if (item.kind === 'trow') {
      return 'tr' + this.itemGen + '_' + item.ti + '_' + (item.ri ?? 0);
    }
    if (item.kind === 'ask') {
      return 'ask';
    }
    return 'p' + (item.padVp ?? 0);
  }

  @Builder
  renderItem(item: RenderItem) {
    if (item.kind === 'pad') {
      ListItem() {
        Column() {
        }
        .height(item.padVp ?? 0)
      }
    } else if (item.kind === 'ask') {
      ListItem() {
        this.renderAskBar()
      }
    } else if (item.kind === 'thead') {
      ListItem() {
        Column() {
          this.renderSplitHead(item.table as WikiNode, item.ti)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14 })
      }
    } else if (item.kind === 'trow') {
      ListItem() {
        Column() {
          this.renderSplitRow(item.table as WikiNode, item.row as WikiNode,
            item.first === true, item.last === true)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14 })
      }
    } else {
      ListItem() {
        Column() {
          this.renderBlock(item.block as WikiNode, 'b' + item.ti)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14 })
      }
    }
  }

  /** 阶段 2 后台查询进度（非阻塞细条，查询期间页面仍可阅读） */
  @Builder
  renderAskBar() {
    Row({ space: 8 }) {
      if (this.progressTotal > 0) {
        Progress({ value: this.progressDone, total: this.progressTotal, type: ProgressType.Linear })
          .layoutWeight(1)
          .height(4)
          .color($r('sys.color.brand'))
          .backgroundColor($r('sys.color.comp_background_secondary'))
        Text(`${this.progressDone}/${this.progressTotal} 页`)
          .fontSize(11)
          .fontColor($r('sys.color.font_tertiary'))
      } else {
        LoadingProgress()
          .width(16)
          .height(16)
          .color($r('sys.color.brand'))
        Text('正在查询…')
          .fontSize(11)
          .fontColor($r('sys.color.font_tertiary'))
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 2, bottom: 6 })
  }

  /** 巨型表（>TABLE_SPLIT_MIN_ROWS 行、无 rowspan、非宽表）拆行：整表一个块时任何懒加载都救不了 */
  private shouldSplitTable(node: WikiNode): boolean {
    const rows = (node.children ?? []) as WikiNode[];
    if (rows.length <= TABLE_SPLIT_MIN_ROWS) {
      return false;
    }
    return !this.hasRowSpan(node) && this.wideTableWidthVp(node) === 0;
  }

  /** 拆分表的可见行（行 0 是表头，常驻 thead；其余按关键词过滤） */
  private splitVisibleRows(node: WikiNode, tKey: string): TableRowPair[] {
    const allRows = (node.children ?? []) as WikiNode[];
    const out: TableRowPair[] = [];
    const kw = this.tableFilterOf(tKey);
    if (kw.length === 0) {
      for (let i = 1; i < allRows.length; i++) {
        out.push({ row: allRows[i], ri: i });
      }
      return out;
    }
    const terms = kw.split(/\s+/).filter((s: string) => s.length > 0);
    for (let i = 1; i < allRows.length; i++) {
      if (this.rowMatches(allRows[i], terms)) {
        out.push({ row: allRows[i], ri: i });
      }
    }
    return out;
  }

  /** nodes → 渲染项列表（首尾安全区留白 + 查询进度条 + 块级 + 巨型表拆行），整体 reload */
  private rebuildItems(): void {
    this.itemGen++;
    this.seedCollapsibleDefaults(this.nodes);
    const items: RenderItem[] = [{ kind: 'pad', ti: 0, padVp: TOP_PAD_VP }];
    if (this.asking) {
      items.push({ kind: 'ask', ti: 0 });
    }
    const nodes = this.nodes;
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i];
      if (n.type === NodeType.Table && this.shouldSplitTable(n)) {
        items.push({ kind: 'thead', ti: i, table: n });
        const vis = this.splitVisibleRows(n, 'sp' + i);
        for (let k = 0; k < vis.length; k++) {
          items.push({
            kind: 'trow', ti: i, table: n, row: vis[k].row, ri: vis[k].ri,
            first: k === 0, last: k === vis.length - 1,
          });
        }
      } else {
        items.push({ kind: 'block', ti: i, block: n });
      }
    }
    items.push({ kind: 'pad', ti: 0, padVp: BOTTOM_PAD_VP });
    this.source.reload(items);
  }

  /** 拆分表过滤词变化 → 区间替换行渲染项（thead 不动，搜索框焦点不丢） */
  private refreshSplitRows(ti: number): void {
    const head = this.source.headIndex(ti);
    if (head < 0) {
      return;
    }
    const node = this.nodes[ti];
    const vis = this.splitVisibleRows(node, 'sp' + ti);
    const newItems: RenderItem[] = [];
    for (let k = 0; k < vis.length; k++) {
      newItems.push({
        kind: 'trow', ti: ti, table: node, row: vis[k].row, ri: vis[k].ri,
        first: k === 0, last: k === vis.length - 1,
      });
    }
    this.source.replaceRange(head + 1, this.source.rowCountAfter(ti), newItems);
  }

  @Builder
  renderSplitHead(node: WikiNode, ti: number) {
    // caption + 搜索框在表格外（与整表路径一致）；边框只包行区域（表头行起）。
    // 过滤命中 0 行时表头行自闭合底边框
    Column() {
      if (node.caption !== undefined && (node.caption as WikiNode[]).length > 0) {
        Text() {
          this.renderSpans(node.caption as WikiNode[])
        }
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 6, bottom: 2 })
      }
      if (this.tableFilterable(node)) {
        Row({ space: 8 }) {
          TextInput({ placeholder: '搜索表格内容…', text: this.tableFilters.get('sp' + ti) ?? '' })
            .layoutWeight(1)
            .height(38)
            .fontSize(14)
            .padding({ left: 12, right: 12 })
            .backgroundColor($r('app.color.surface'))
            .borderRadius(10)
            .onChange((v: string) => {
              this.setTableFilter('sp' + ti, v);
            })
          if (this.tableFilterOf('sp' + ti).length > 0) {
            Text((this.splitVisibleRows(node, 'sp' + ti).length) + '/' +
              (((node.children ?? []) as WikiNode[]).length - 1))
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
            Text('✕')
              .fontSize(14)
              .fontColor($r('app.color.text_tertiary'))
              .padding(6)
              .onClick(() => {
                this.clearTableFilter('sp' + ti);
              })
          }
        }
        .width('100%')
        .margin({ top: 8, bottom: 4 })
      }
      // 行 0 = 表头行
      if (((node.children ?? []) as WikiNode[]).length > 0) {
        Column() {
          this.renderTableRow(node, ((node.children ?? []) as WikiNode[])[0])
        }
        .width('100%')
        .border({
          width: this.splitVisibleRows(node, 'sp' + ti).length === 0 ?
          { left: 1, right: 1, top: 1, bottom: 1 } : { left: 1, right: 1, top: 1, bottom: 0 },
          color: $r('app.color.table_border_outer')
        })
        .borderRadius({
          topLeft: 4, topRight: 4,
          bottomLeft: this.splitVisibleRows(node, 'sp' + ti).length === 0 ? 4 : 0,
          bottomRight: this.splitVisibleRows(node, 'sp' + ti).length === 0 ? 4 : 0
        })
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  renderSplitRow(node: WikiNode, row: WikiNode, first: boolean, last: boolean) {
    Column() {
      this.renderTableRow(node, row)
    }
    .width('100%')
    .border({
      width: { left: 1, right: 1, top: 0, bottom: last ? 1 : 0 },
      color: $r('app.color.table_border_outer')
    })
    .borderRadius({ bottomLeft: last ? 4 : 0, bottomRight: last ? 4 : 0 })
    .margin({ bottom: last ? 8 : 0 })
  }

  /** 普通表行渲染（整表路径与拆分行路径共用；列宽按表头声明比例） */
  @Builder
  renderTableRow(node: WikiNode, row: WikiNode) {
    Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Stretch }) {
      ForEach(row.children ?? [], (cell: WikiNode, cIdx: number) => {
        Column() {
          this.renderInlineFlow(cell.inline ?? [], '')
        }
        .layoutWeight(this.colWeight(node, cell))
        .padding(6)
        .backgroundColor(this.cellBg(cell))
        .border({ width: 1, color: $r('app.color.table_border') })
        .alignItems(HorizontalAlign.Start)
      }, (cell: WikiNode, cIdx: number) => 'cell' + (cell.colIndex ?? 0))
    }
    .width('100%')
    .onClick(() => {
      // 行级折叠开关（|- class="mw-customtoggle-X"，如敌人武技行点击展开明细）
      if (row.toggleFor !== undefined && row.toggleFor.length > 0) {
        this.toggleCollapse(row.toggleFor as string);
      }
    })
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
    // 拆分表的行是独立渲染项，需区间替换；整表的行由其内部 ForEach 自行刷新
    if (key.startsWith('sp')) {
      this.refreshSplitRows(parseInt(key.substring(2), 10));
    }
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
    if (key.startsWith('sp')) {
      this.refreshSplitRows(parseInt(key.substring(2), 10));
    }
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
    const collapseSkip = (r: WikiNode): boolean => {
      return r.collapsibleId !== undefined && !this.collapsibleOpen(r);
    };
    if (kw.length === 0 || !this.tableFilterable(node)) {
      for (let i = 0; i < allRows.length; i++) {
        if (!collapseSkip(allRows[i])) {
          out.push({ row: allRows[i], ri: i });
        }
      }
      return out;
    }
    const terms = kw.split(/\s+/).filter((s: string) => s.length > 0);
    for (let i = 0; i < allRows.length; i++) {
      if (collapseSkip(allRows[i])) {
        continue;
      }
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

  /** 单元格背景：源数据 bgColor（如乱入标记赤底）优先（按显示模式换算），否则表头/表体主题色 */
  private cellBg(cell: WikiNode): ResourceColor {
    if (cell.bgColor !== undefined && cell.bgColor.length > 0) {
      return adaptSourceBg(cell.bgColor, this.isDark);
    }
    return cell.type === NodeType.TableHeaderCell
      ? $r('app.color.table_header_bg') : $r('app.color.table_bg');
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
  private buildRuns(inline: WikiNode[], style: number, color: string,
    fontSize: number, bg: string = ''): InlineRun[] {
    const runs: InlineRun[] = [];
    let current: WikiNode[] = [];

    const flush = (): void => {
      if (current.length > 0) {
        runs.push({ kind: 'text', inline: current, style: style, color: color,
          fontSize: fontSize > 0 ? fontSize : undefined, bgColor: bg });
        current = [];
      }
    };

    for (const tok of inline) {
      const t = tok.type;
      if (t === NodeType.Text) {
        current.push(tok);
      } else if (t === NodeType.Bold || t === NodeType.Italic || t === NodeType.BoldItalic ||
        t === NodeType.Color) {
        if (tok.toggleFor !== undefined) {
          // 折叠开关（mw-customtoggle）：独立 run，渲染期接点击切换折叠容器
          flush();
          runs.push({ kind: 'toggle', inline: tok.inline ?? [], toggleId: tok.toggleFor,
            style: style, color: tok.color !== undefined ? tok.color : color,
            fontSize: fontSize > 0 ? fontSize : undefined, bgColor: bg });
        } else if (this.containsInteractive(tok.inline ?? [])) {
          flush();
          let childStyle = style;
          if (t === NodeType.Bold || t === NodeType.BoldItalic) {
            childStyle |= 1;
          }
          if (t === NodeType.Italic || t === NodeType.BoldItalic) {
            childStyle |= 2;
          }
          const childColor = t === NodeType.Color && tok.color !== undefined ? tok.color : color;
          const childSize = t === NodeType.Color && tok.fontSize !== undefined ? tok.fontSize : fontSize;
          const childBg = t === NodeType.Color && tok.bgColor !== undefined ? tok.bgColor : bg;
          const childRuns = this.buildRuns(tok.inline ?? [], childStyle, childColor, childSize, childBg);
          for (const r of childRuns) {
            runs.push(r);
          }
        } else {
          current.push(tok);
        }
      } else if (t === NodeType.Link) {
        flush();
        runs.push({ kind: 'link', inline: tok.inline ?? [], target: tok.target, style: style,
          color: color, fontSize: fontSize > 0 ? fontSize : undefined, bgColor: bg });
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
      } else if (t === NodeType.Gauge) {
        flush();
        runs.push({ kind: 'gauge', gaugeSegs: tok.gaugeSegs, gaugeHeight: tok.gaugeHeight, style: style });
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
      if (tok.toggleFor !== undefined) {
        return true;
      }
      const t = tok.type;
      if (t === NodeType.Link || t === NodeType.FileImage || t === NodeType.Placeholder ||
        t === NodeType.LineBreak || t === NodeType.Gauge) {
        return true;
      }
      if ((t === NodeType.Bold || t === NodeType.Italic || t === NodeType.BoldItalic ||
        t === NodeType.Color) && this.containsInteractive(tok.inline ?? [])) {
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
      .fontColor($r('app.color.text_primary'))
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
      Divider().color($r('app.color.table_border')).margin({ top: 10, bottom: 10 })
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
    } else if (node.type === NodeType.Map) {
      WikiMapView({
        image: node.mapImage ?? '',
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
        .fontColor($r('app.color.text_body'))
        .backgroundColor($r('app.color.surface_deep'))
        .padding(10)
        .width('100%')
        .borderRadius(6)
        .margin({ top: 4, bottom: 4 })
    } else if (node.type === NodeType.Placeholder) {
      this.renderPlaceholder(node)
    } else if (node.type === NodeType.Container) {
      if (node.collapsibleId !== undefined && !this.collapsibleOpen(node)) {
        // 收起态（mw-collapsed）：内容整体隐藏，与原站 display:none 一致
        Column() {
        }
        .width('100%')
      } else {
        Column({ space: 0 }) {
          ForEach(node.children ?? [], (n: WikiNode, idx: number) => {
            this.renderBlock(n, tKey + 'c' + idx)
          }, (n: WikiNode, idx: number) => 'c' + idx)
        }
        .width('100%')
        .alignItems(node.align === 'center' ? HorizontalAlign.Center : HorizontalAlign.Start)
        .backgroundColor(this.boxBgOf(node))
        .border(this.boxBorderOf(node))
        .borderRadius(this.boxRadiusOf(node))
        .padding(this.boxPadOf(node))
      }
    } else if (node.type === NodeType.Link) {
      Text() {
        this.renderSpans(node.inline ?? [])
      }
      .fontSize(15)
      .fontColor($r('app.color.link'))
      .decoration({ type: TextDecorationType.Underline, color: $r('app.color.link') })
      .onClick(() => {
        this.onNavigate(node.target ?? '')
      })
    } else if (node.type === NodeType.Text) {
      Text(node.text ?? '').fontSize(15).fontColor($r('app.color.text_body'))
    } else {
      Text(node.text ?? '').fontSize(15).fontColor($r('app.color.text_body'))
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
        .fontColor($r('app.color.text_secondary'))
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
            .backgroundColor($r('app.color.surface'))
            .borderRadius(10)
            .onChange((v: string) => {
              this.setTableFilter(tKey, v);
            })
          if (this.tableFilterOf(tKey).length > 0) {
            Text((this.visibleRows(node, tKey).length - 1) + '/' + ((node.children ?? []).length - 1))
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
            Text('✕')
              .fontSize(14)
              .fontColor($r('app.color.text_tertiary'))
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
        if (this.wideTableWidthVp(node) > 0) {
          Scroll() {
            Column() {
              this.renderTableGrid(node)
            }
            .width(this.wideTableWidthVp(node))
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Auto)
          .width('100%')
        } else {
          this.renderTableGrid(node)
        }
      } else if (this.wideTableWidthVp(node) > 0) {
        // 宽表：冻结首列 + 其余列横向滚动（ArkUI Scroll 无内建 sticky 列，
        //  行高由滚动区 onAreaChange 量测回填冻结列，保证两侧行对齐）
        Column() {
          // 整幅横幅行（单格跨满全列，如 colspan="10"）不属于冻结/滚动任一侧，全宽渲染
          ForEach(this.wideLeadRows(node, tKey), (item: TableRowPair) => {
            Column() {
              this.renderInlineFlow(this.frozenCellOf(item.row)?.inline ?? [], '',
                this.frozenCellOf(item.row)?.type === NodeType.TableHeaderCell)
            }
            .width('100%')
            .padding(6)
            .backgroundColor(this.frozenCellOf(item.row)?.type === NodeType.TableHeaderCell ?
              $r('app.color.table_header_bg') : $r('app.color.table_bg'))
            .border({
              width: { left: 1, right: 1, top: 1, bottom: 0 },
              color: $r('app.color.table_border_outer')
            })
            .borderRadius({ topLeft: 4, topRight: 4 })
            .margin({ top: 8 })
          }, (item: TableRowPair) => 'lead_' + item.ri)

          Row() {
            Column() {
              ForEach(this.wideBodyRows(node, tKey), (item: TableRowPair, vIdx: number) => {
                Column() {
                  this.renderInlineFlow(this.frozenCellOf(item.row)?.inline ?? [], '')
                }
                .width('100%')
                .height(this.frozenRowH(tKey, item.ri))
                .padding(6)
                .backgroundColor(this.frozenCellOf(item.row) !== null
                  ? this.cellBg(this.frozenCellOf(item.row) as WikiNode)
                  : $r('app.color.table_bg'))
                .border({ width: 1, color: $r('app.color.table_border') })
                .alignItems(HorizontalAlign.Start)
              }, (item: TableRowPair, vIdx: number) => 'fcell_' + item.ri)
            }
            .width(WIDE_TABLE_FROZEN_W)
            .border({ width: 1, color: $r('app.color.table_border_outer') })
            .borderRadius({ topLeft: 4, bottomLeft: 4, topRight: 0, bottomRight: 0 })
            .margin({ top: this.wideLeadRows(node, tKey).length > 0 ? 0 : 8, bottom: 8 })

            Scroll() {
              Column() {
                ForEach(this.wideBodyRows(node, tKey), (item: TableRowPair, vIdx: number) => {
                  // Stretch：同行单元格拉伸到最高格的高度，保持行内等高（对齐 HTML 表格行为）
                  Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Stretch }) {
                    ForEach(this.bodyCellsOf(item.row), (cell: WikiNode, cIdx: number) => {
                      Column() {
                        this.renderInlineFlow(cell.inline ?? [], '')
                      }
                      .layoutWeight(cell.colSpan ?? 1)
                      .padding(6)
                      .backgroundColor(this.cellBg(cell))
                      .border({ width: 1, color: $r('app.color.table_border') })
                      .alignItems(HorizontalAlign.Start)
                    }, (cell: WikiNode, cIdx: number) => 'cell' + item.ri + '_' + (cell.colIndex ?? 0))
                  }
                  .width('100%')
                  .onAreaChange((oldArea: Area, newArea: Area) => {
                    this.syncRowH(tKey, item.ri, newArea.height);
                  })
                }, (item: TableRowPair, vIdx: number) => 'frow_' + item.ri)
              }
              .width(this.wideBodyWidthVp(node))
              .border({ width: 1, color: $r('app.color.table_border_outer') })
              .borderRadius({ topLeft: 0, bottomLeft: 0, topRight: 4, bottomRight: 4 })
              .margin({ top: this.wideLeadRows(node, tKey).length > 0 ? 0 : 8, bottom: 8 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Auto)
            .layoutWeight(1)
          }
          .width('100%')
        }
        .width('100%')
      } else {
        Column() {
          ForEach(this.visibleRows(node, tKey), (item: TableRowPair, vIdx: number) => {
            this.renderTableRow(node, item.row)
          }, (item: TableRowPair, vIdx: number) => 'frow_' + item.ri)
        }
        .border({ width: 1, color: $r('app.color.table_border_outer') })
        .borderRadius(4)
        .margin({ top: 8, bottom: 8 })
        .width('100%')
      }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** rich 段行高：普通正文 22；纯小字号段（斩位条等装饰）收紧到 13（忽略换行 span） */
  private segLineHeight(spans: RichSpan[]): number {
    let allSmall = false;
    let sawText = false;
    for (const sp of spans) {
      if (sp.text.trim().length === 0) {
        continue;
      }
      sawText = true;
      if ((sp.fontSize ?? 0) === 0 || (sp.fontSize as number) > 12) {
        allSmall = false;
        break;
      }
      allSmall = true;
    }
    return sawText && allSmall ? 13 : 22;
  }

  /** 单元格布局权重：优先用表头声明的列宽百分比（width="50%"），
   *  按 colIndex 匹配（跨列格累加跨度内各列宽）；无声明回退跨列数。
   *  单列宽度下限 14：窄屏下 4%~8% 的列连三位数/粗体数字都会竖排折行 */
  private colWeight(node: WikiNode, cell: WikiNode): number {
    const rows = (node.children ?? []) as WikiNode[];
    if (rows.length === 0) {
      return cell.colSpan ?? 1;
    }
    const headerCells = (rows[0].children ?? []) as WikiNode[];
    const span = cell.colSpan ?? 1;
    const ci = cell.colIndex ?? 0;
    let w = 0;
    let found = false;
    for (const h of headerCells) {
      const hci = h.colIndex ?? 0;
      if (hci >= ci && hci < ci + span && h.widthPct !== undefined) {
        w += Math.max(h.widthPct as number, 14);
        found = true;
      }
    }
    return found && w > 0 ? w : span;
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

  /** 宽表判定：超过阈值列数时返回滚动内容总宽（vp），否则 0（不启用横向滚动） */
  private wideTableWidthVp(node: WikiNode): number {
    const cols = this.tableCols(node);
    return cols > WIDE_TABLE_MIN_COLS ? cols * TABLE_COL_MIN_VP : 0;
  }

  /** 宽表滚动区内容宽度（vp）：除冻结首列外的列（rowspan Grid 路径无冻结列，用全宽） */
  private wideBodyWidthVp(node: WikiNode): number {
    const cols = this.tableCols(node);
    return Math.max(1, cols - 1) * TABLE_COL_MIN_VP;
  }

  /** 冻结首列单元格（colIndex 0 的格；行内无首格时返回 null 渲染为空占位） */
  private frozenCellOf(row: WikiNode): WikiNode | null {
    const cells = (row.children ?? []) as WikiNode[];
    for (let i = 0; i < cells.length; i++) {
      if ((cells[i].colIndex ?? 0) === 0) {
        return cells[i];
      }
    }
    return null;
  }

  /** 整幅横幅行：单格且跨满全部列（无法归属冻结列或滚动区，需全宽渲染） */
  private isFullWidthRow(row: WikiNode, cols: number): boolean {
    const cells = (row.children ?? []) as WikiNode[];
    return cells.length === 1 && (cells[0].colIndex ?? 0) === 0 &&
      (cells[0].colSpan ?? 1) >= cols;
  }

  /** 宽表开头连续的整幅横幅行 */
  private wideLeadRows(node: WikiNode, tKey: string): TableRowPair[] {
    const cols = this.tableCols(node);
    const vis = this.visibleRows(node, tKey);
    const out: TableRowPair[] = [];
    for (let i = 0; i < vis.length && this.isFullWidthRow(vis[i].row, cols); i++) {
      out.push(vis[i]);
    }
    return out;
  }

  /** 宽表正文行（跳过开头整幅横幅行） */
  private wideBodyRows(node: WikiNode, tKey: string): TableRowPair[] {
    const cols = this.tableCols(node);
    const vis = this.visibleRows(node, tKey);
    let i = 0;
    while (i < vis.length && this.isFullWidthRow(vis[i].row, cols)) {
      i++;
    }
    return vis.slice(i);
  }

  /** 滚动区单元格（除冻结首列外） */
  private bodyCellsOf(row: WikiNode): WikiNode[] {
    const cells = (row.children ?? []) as WikiNode[];
    const out: WikiNode[] = [];
    for (let i = 0; i < cells.length; i++) {
      if ((cells[i].colIndex ?? 0) !== 0) {
        out.push(cells[i]);
      }
    }
    return out;
  }

  /** 冻结列行高：优先用滚动区实测值（vp），未量测到时自适应 */
  private frozenRowH(tKey: string, ri: number): Length {
    const h = this.wideRowH.get(tKey + '_r' + ri);
    return h === undefined ? 'auto' : h;
  }

  /** 滚动区行高量测回填（冻结列与滚动区分属两棵子树，需同步行高保持对齐） */
  private syncRowH(tKey: string, ri: number, h: Length): void {
    const hv = typeof h === 'number' ? h : parseFloat(h as string);
    if (isNaN(hv)) {
      return;
    }
    const k = tKey + '_r' + ri;
    const cur = this.wideRowH.get(k);
    if (cur !== undefined && Math.abs(cur - hv) < 0.5) {
      return;
    }
    const m = new Map(this.wideRowH);
    m.set(k, hv);
    this.wideRowH = m;
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
    // 按各行内容估算的比例分配行高（fr 权重）：总高由 gridHeightVp 控制
    const hs = this.gridRowHeightsVp(node);
    let t = '';
    for (let k = 0; k < hs.length; k++) {
      t += (k > 0 ? ' ' : '') + Math.max(1, Math.round(hs[k])) + 'fr';
    }
    return t;
  }

  /** 行内文本行数统计（LineBreak 分行；长段按列宽估折行；CJK 记 1、ASCII/空格记 0.5） */
  private countLines(inline: WikiNode[], charsPerLine: number, acc: number[]): void {
    for (const tok of inline) {
      const t = tok.type;
      if (t === NodeType.Text) {
        let w = 0;
        const s = tok.text ?? '';
        for (let i = 0; i < s.length; i++) {
          const c = s.charCodeAt(i);
          w += c > 0x2E7F ? 1 : 0.5;
        }
        acc[1] += w;
        while (acc[1] > charsPerLine) {
          acc[0]++;
          acc[1] -= charsPerLine;
        }
      } else if (t === NodeType.LineBreak) {
        acc[0]++;
        acc[1] = 0;
      } else if (t === NodeType.FileImage) {
        acc[1] += 2;
        while (acc[1] > charsPerLine) {
          acc[0]++;
          acc[1] -= charsPerLine;
        }
      } else if (tok.inline !== undefined) {
        this.countLines(tok.inline, charsPerLine, acc);
      }
    }
  }

  /** 估算单元格内容高度（vp）：纯文本格按行数估；仅含单图的格用图标模型
   *（图标+标签格无行数可估，且图标随跨行数放大——文字格不得套用图标下限，
   *  否则跨行文字列会把每行撑到 ~55vp，单行内容行高虚胖 4 倍） */
  private estCellHeightVp(cell: WikiNode, colVp: number): number {
    const rs = cell.rowSpan !== undefined ? cell.rowSpan : 1;
    if (this.isSingleImage(cell.inline ?? [])) {
      return (Math.ceil(this.gridIconVp(rs) / rs) + 36) * rs;
    }
    const charsPerLine = Math.max(4, Math.floor(colVp / 13));
    const acc: number[] = [1, 0];
    this.countLines(cell.inline ?? [], charsPerLine, acc);
    return Math.min(60, acc[0]) * 22 + 10;
  }

  /** 逐行高度估算（vp）：本行各格内容高按 rowspan 分摊取最大，下限 26。
   *  列宽优先取表头 widthPct 实际比例（无声明回退等分）；
   *  表宽必须与实际渲染宽一致——宽表（>6 列）走横向滚动路径，实际宽为
   *  cols×TABLE_COL_MIN_VP，若仍按屏宽 380vp 估，列宽被低估 3 倍、折行数虚高、行高虚胖 */
  private gridRowHeightsVp(node: WikiNode): number[] {
    const rows = (node.children ?? []) as WikiNode[];
    const cols = this.tableCols(node);
    const tableVp = Math.max(380, this.wideTableWidthVp(node));
    const equalVp = tableVp / Math.max(1, cols);
    // 表头 widthPct → 每列宽度
    const colPct: Map<number, number> = new Map();
    const firstRow = rows.length > 0 ? (rows[0].children ?? []) as WikiNode[] : [];
    for (const h of firstRow) {
      if (h.widthPct !== undefined) {
        const cs = h.colSpan ?? 1;
        const per = h.widthPct / 100 * tableVp / cs;
        for (let k = 0; k < cs; k++) {
          colPct.set((h.colIndex ?? 0) + k, per);
        }
      }
    }
    const cellColVp = (cell: WikiNode): number => {
      let w = 0;
      const cs = cell.colSpan ?? 1;
      for (let k = 0; k < cs; k++) {
        const p = colPct.get((cell.colIndex ?? 0) + k);
        w += p !== undefined ? p : equalVp;
      }
      return w;
    };
    const out: number[] = [];
    for (const row of rows) {
      let rh = 26;
      for (const cell of (row.children ?? []) as WikiNode[]) {
        const rs = cell.rowSpan !== undefined ? cell.rowSpan : 1;
        const share = Math.ceil(this.estCellHeightVp(cell, cellColVp(cell)) / rs);
        if (share > rh) {
          rh = share;
        }
      }
      out.push(rh);
    }
    return out;
  }

  /** 估算表格高度（vp）：逐行高度之和（行高按 rowsTemplate 的 fr 权重比例分配） */
  private gridHeightVp(node: WikiNode): number {
    const hs = this.gridRowHeightsVp(node);
    let total = 0;
    for (const h of hs) {
      total += h;
    }
    return total;
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
          .fontColor($r('app.color.text_tertiary'))
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
  gridItems(node: WikiNode) {
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
      .backgroundColor(this.cellBg(item.cell))
      .border({ width: 1, color: $r('app.color.table_border_outer') })
      .rowStart(item.row)
      .rowEnd(item.row + (item.cell.rowSpan ?? 1) - 1)
      .columnStart(item.cell.colIndex ?? 0)
      .columnEnd((item.cell.colIndex ?? 0) + (item.cell.colSpan ?? 1) - 1)
    }, (item: TableCellItem, idx: number) => 'grid' + idx)
  }

  @Builder
  renderTableGrid(node: WikiNode) {
    Grid() {
      this.gridItems(node)
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
        .fontColor($r('app.color.text_tertiary'))
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
    if (WikiContentView.isPendingReason(node.reason)) {
      // 渐进渲染：查询/模块延迟调用后台执行中的占位
      Text('⏳ 数据加载中…')
        .fontSize(12)
        .fontColor($r('app.color.loading_text'))
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
    } else {
      Text('⚠ ' + (node.reason ?? '内容暂不支持渲染'))
        .fontSize(12)
        .fontColor($r('app.color.warn_text'))
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor($r('app.color.warn_bg'))
        .borderRadius(6)
        .width('100%')
        .margin({ top: 4, bottom: 4 })
    }
  }

  /** 渐进渲染占位（ASK: 查询 / INV: 模块延迟调用）→ 加载态展示 */
  private static isPendingReason(reason: string | undefined): boolean {
    return (reason ?? '').startsWith('ASK:') || (reason ?? '').startsWith('INV:');
  }

  // ---------- 行内渲染 ----------

  @Builder
  renderInlineFlow(inline: WikiNode[], prefix: string, center: boolean = false) {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Baseline,
      justifyContent: center ? FlexAlign.Center : FlexAlign.Start }) {
      this.renderSegments(this.buildSegments(inline, prefix))
    }
    .width('100%')
  }

  /** 把 run 列表分组成渲染段：连续 text/link/break 合并为单个 rich 段（一个 Text 多 Span，
   *  换行发生在文字内部而非元素边界，修复"链接/标号独占一行"）；<br> 忠实渲染为换行，
   *  以 Span('\n') 并入同一 Text（仅调整换行的渲染方式，不改数据语义）；图片/占位保持独立段 */
  private buildSegments(inline: WikiNode[], prefix: string): InlineSeg[] {
    const runs = this.buildRuns(inline, 0, '', 0);
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
        const spans = this.flattenRich(r.inline ?? [], r.style, isLink,
          isLink ? (r.target ?? '') : '', r.color ?? '', r.fontSize ?? 0, r.bgColor ?? '');
        for (const s of spans) {
          buf.push(s);
        }
      } else if (r.kind === 'break') {
        // <br>：并入当前 rich 段为换行符（同一 Text 内换行，行高一致）
        buf.push({ text: '\n', bold: false, italic: false, link: false, target: '', color: '' });
      } else if (r.kind === 'toggle') {
        flushRich();
        segs.push({
          kind: 'toggle',
          toggleId: r.toggleId,
          spans: this.normalizeSpans(this.flattenRich(r.inline ?? [], r.style, false, '',
            r.color ?? '', r.fontSize ?? 0, r.bgColor ?? '')),
        });
      } else {
        // 连续 gauge 之间的 <br> 冗余（gauge 全宽自然换行）
        if (r.kind === 'gauge' && buf.length > 0 && segs.length > 0 &&
          segs[segs.length - 1].kind === 'gauge' &&
          buf.every((s: RichSpan): boolean => s.text === '\n')) {
          buf = [];
        }
        flushRich();
        if (r.kind === 'image') {
          segs.push({ kind: 'image', fileName: r.fileName, width: r.width, height: r.height, align: r.align });
        } else if (r.kind === 'gauge') {
          segs.push({ kind: 'gauge', gaugeSegs: r.gaugeSegs, gaugeHeight: r.gaugeHeight });
        } else if (r.kind === 'placeholder') {
          // 连续的查询占位（同一处登记的多个 #ask/#invoke）合并为一个加载提示，避免成串冗余
          const isAsk = WikiContentView.isPendingReason(r.reason);
          const last = segs.length > 0 ? segs[segs.length - 1] : null;
          const merged = isAsk && last !== null && last.kind === 'placeholder' &&
            WikiContentView.isPendingReason(last.reason);
          if (!merged) {
            segs.push({ kind: 'placeholder', reason: r.reason });
          }
        } else if (r.kind === 'break') {
          segs.push({ kind: 'break' });
        }
      }
    }
    flushRich();
    // 列表标号并入首个 rich/toggle 段（避免标号单独占一行；折叠开关文字同理）
    if (prefix.length > 0) {
      const mk: RichSpan = { text: prefix, bold: false, italic: false, link: false, target: '', color: '' };
      const first = segs.length > 0 ? segs[0] : null;
      if (first !== null && (first.kind === 'rich' || first.kind === 'toggle') && first.spans !== undefined) {
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
        last.link === s.link && last.target === s.target && last.color === s.color &&
        (last.fontSize ?? 0) === (s.fontSize ?? 0) &&
        (last.bgColor ?? '') === (s.bgColor ?? '')) {
        last.text += s.text;
      } else {
        merged.push({ text: s.text, bold: s.bold, italic: s.italic, link: s.link,
          target: s.target, color: s.color, fontSize: s.fontSize, bgColor: s.bgColor });
      }
    }
    return merged;
  }

  /** 展平行内节点为富文本 Span（保留链接标记与样式） */
  private flattenRich(inline: WikiNode[], style: number, link: boolean, target: string,
    color: string, fontSize: number, bg: string = ''): RichSpan[] {
    const out: RichSpan[] = [];
    const bold = (style & 1) !== 0;
    const italic = (style & 2) !== 0;
    const size = fontSize > 0 ? fontSize : undefined;
    const bgSet = bg.length > 0 ? bg : undefined;
    for (const tok of inline) {
      const t = tok.type;
      if (t === NodeType.Text) {
        out.push({ text: tok.text ?? '', bold: bold, italic: italic, link: link, target: target,
          color: color, fontSize: size, bgColor: bgSet });
      } else if (t === NodeType.Bold || t === NodeType.Italic || t === NodeType.BoldItalic ||
        t === NodeType.Color) {
        let cs = style;
        if (t === NodeType.Bold || t === NodeType.BoldItalic) {
          cs |= 1;
        }
        if (t === NodeType.Italic || t === NodeType.BoldItalic) {
          cs |= 2;
        }
        const cc = t === NodeType.Color && tok.color !== undefined ? tok.color : color;
        const csize = t === NodeType.Color && tok.fontSize !== undefined ? tok.fontSize : fontSize;
        const cbg = t === NodeType.Color && tok.bgColor !== undefined ? tok.bgColor : bg;
        const sub = this.flattenRich(tok.inline ?? [], cs, link, target, cc, csize, cbg);
        for (const s of sub) {
          out.push(s);
        }
      } else if (t === NodeType.Link) {
        const sub = this.flattenRich(tok.inline ?? [], style, true, tok.target ?? '', color, fontSize, bg);
        for (const s of sub) {
          out.push(s);
        }
      } else if (t === NodeType.LineBreak) {
        // 样式容器内嵌的 <br>（如折叠开关文字的多行说明）：并入同一 Text 为换行
        out.push({ text: '\n', bold: bold, italic: italic, link: link, target: target,
          color: color, fontSize: size, bgColor: bgSet });
      } else {
        out.push({ text: tok.text ?? '', bold: bold, italic: italic, link: link, target: target,
          color: color, fontSize: size, bgColor: bgSet });
      }
    }
    return out;
  }

  @Builder
  renderSegments(segs: InlineSeg[]) {
    ForEach(segs, (seg: InlineSeg, idx: number) => {
      if (seg.kind === 'rich') {
        Text() {
          this.renderSpanList(seg.spans ?? [])
        }
        .fontSize(15)
        .lineHeight(this.segLineHeight(seg.spans ?? []))
      } else if (seg.kind === 'toggle') {
        // 折叠开关（mw-customtoggle）：整段文字可点，切换对应折叠容器
        Text() {
          this.renderSpanList(seg.spans ?? [])
        }
        .fontSize(15)
        .lineHeight(this.segLineHeight(seg.spans ?? []))
        .onClick(() => {
          if ((seg.toggleId ?? '').length > 0) {
            this.toggleCollapse(seg.toggleId as string);
          }
        })
      } else if (seg.kind === 'image') {
        if ((seg.width ?? 0) === 0 || ((seg.width as number) > 0 && (seg.width as number) <= 64)) {
          // 小尺寸注释（≤64px）的行内图标随文字流内联；无注释图由 WikiImage 按自然宽自适应
          //（HTML 直渲染站点的小图标常无 width 属性：≤48px 原宽内联，大图自动整行）
          WikiImage({ fileName: seg.fileName ?? '', fileWidth: seg.width ?? 0,
            fileHeight: seg.height ?? 0, block: false })
        } else {
          // 块级图片：全宽容器居中，固定宽（限宽/限高注释）图片水平居中，铺满图不受影响
          Column() {
            WikiImage({ fileName: seg.fileName ?? '', fileWidth: seg.width ?? 0,
              fileHeight: seg.height ?? 0, block: true })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
        }
      } else if (seg.kind === 'placeholder') {
        if (WikiContentView.isPendingReason(seg.reason)) {
          // 渐进渲染：查询/模块延迟调用后台执行中的占位（与块级 renderPlaceholder 同样式）
          Text('⏳ 数据加载中…')
            .fontSize(12)
            .fontColor($r('app.color.loading_text'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        } else {
          Text('⚠ ' + (seg.reason ?? '内容暂不支持渲染'))
            .fontSize(12)
            .fontColor($r('app.color.warn_text'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor($r('app.color.warn_bg'))
            .borderRadius(6)
            .margin({ top: 2, bottom: 2 })
        }
      } else if (seg.kind === 'gauge') {
        // 量表色段条（強さ双色条/斩位多色段）：全宽轨道，段宽=百分比
        Row({ space: 0 }) {
          ForEach(seg.gaugeSegs ?? [], (g: GaugeSeg, gi: number) => {
            Row()
              .width(Math.min(100, Math.max(0, g.pct)) + '%')
              .height(seg.gaugeHeight ?? 4)
              .backgroundColor(g.color)
              .borderRadius(1)
          }, (g: GaugeSeg, gi: number) => 'g' + gi)
        }
        .width('100%')
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
  private flattenInline(inline: WikiNode[], bold: boolean, italic: boolean,
    color: string, fontSize: number): StyledText[] {
    const out: StyledText[] = [];
    for (const tok of inline) {
      const t = tok.type;
      if (t === NodeType.Text) {
        out.push({ text: tok.text ?? '', bold: bold, italic: italic, color: color,
          fontSize: fontSize > 0 ? fontSize : 0 });
      } else if (t === NodeType.Bold) {
        const sub = this.flattenInline(tok.inline ?? [], true, italic, color, fontSize);
        for (const s of sub) {
          out.push(s);
        }
      } else if (t === NodeType.Italic) {
        const sub = this.flattenInline(tok.inline ?? [], bold, true, color, fontSize);
        for (const s of sub) {
          out.push(s);
        }
      } else if (t === NodeType.BoldItalic) {
        const sub = this.flattenInline(tok.inline ?? [], true, true, color, fontSize);
        for (const s of sub) {
          out.push(s);
        }
      } else if (t === NodeType.Color) {
        const sub = this.flattenInline(tok.inline ?? [], bold, italic,
          tok.color !== undefined ? tok.color : color,
          tok.fontSize !== undefined ? tok.fontSize : fontSize);
        for (const s of sub) {
          out.push(s);
        }
      } else {
        out.push({ text: tok.text ?? '', bold: bold, italic: italic, color: color,
          fontSize: fontSize > 0 ? fontSize : 0 });
      }
    }
    return out;
  }

  @Builder
  renderSpanList(spans: RichSpan[]) {
    ForEach(spans, (sp: RichSpan, si: number) => {
      if (sp.link) {
        Span(sp.text)
          .fontWeight(sp.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(sp.italic ? FontStyle.Italic : FontStyle.Normal)
          .fontColor(sp.color.length > 0 ? adaptSourceFg(sp.color, this.isDark) :
            (sp.link ? $r('app.color.link') : $r('app.color.text_body')))
          .fontSize((sp.fontSize ?? 0) > 0 ? sp.fontSize : 15)
          .textBackgroundStyle(sp.bgColor !== undefined && sp.bgColor.length > 0
            ? { color: adaptSourceBg(sp.bgColor, this.isDark), radius: 2 }
            : { color: Color.Transparent, radius: 0 })
          .decoration(sp.link
            ? { type: TextDecorationType.Underline, color: $r('app.color.link') }
            : { type: TextDecorationType.None })
          .onClick(() => {
            if (sp.link && sp.target.length > 0) {
              this.onNavigate(sp.target);
            }
          })
      } else {
        // 非 link 的 Span 不挂 onClick：Span 事件不冒泡，会吞掉所在 Text（折叠开关）的点击
        Span(sp.text)
          .fontWeight(sp.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(sp.italic ? FontStyle.Italic : FontStyle.Normal)
          .fontColor(sp.color.length > 0 ? adaptSourceFg(sp.color, this.isDark) :
            (sp.link ? $r('app.color.link') : $r('app.color.text_body')))
          .fontSize((sp.fontSize ?? 0) > 0 ? sp.fontSize : 15)
          .textBackgroundStyle(sp.bgColor !== undefined && sp.bgColor.length > 0
            ? { color: adaptSourceBg(sp.bgColor, this.isDark), radius: 2 }
            : { color: Color.Transparent, radius: 0 })
          .decoration(sp.link
            ? { type: TextDecorationType.Underline, color: $r('app.color.link') }
            : { type: TextDecorationType.None })
      }
    }, (sp: RichSpan, si: number) => 'sp' + si)
  }

  @Builder
  renderSpans(inline: WikiNode[]) {
    ForEach(this.flattenInline(inline, false, false, '', 0), (frag: StyledText, idx: number) => {
      if (frag.color.length > 0) {
        Span(frag.text)
          .fontWeight(frag.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(frag.italic ? FontStyle.Italic : FontStyle.Normal)
          .fontColor(adaptSourceFg(frag.color, this.isDark))
      } else if ((frag.fontSize ?? 0) > 0) {
        Span(frag.text)
          .fontWeight(frag.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(frag.italic ? FontStyle.Italic : FontStyle.Normal)
          .fontSize(frag.fontSize)
      } else {
        Span(frag.text)
          .fontWeight(frag.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(frag.italic ? FontStyle.Italic : FontStyle.Normal)
      }
    }, (frag: StyledText, idx: number) => 's' + idx)
  }
}

/** 带样式的文本片段（Span 仅支持叶子文本） */
interface StyledText {
  text: string;
  bold: boolean;
  italic: boolean;
  color: string;
  fontSize: number;
}

/** 表格单元格（含所在行号，供 Grid 显式定位） */
interface TableCellItem {
  cell: WikiNode;
  row: number;
}
