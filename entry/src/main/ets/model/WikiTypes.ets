/**
 * 数据模型：站点信息与 wikitext 节点树类型
 */

/** 一个 wiki 站点（Download/OhMyWiki 下的一个顶层文件夹） */
export interface WikiSite {
  /** 顶层文件夹名 */
  name: string;
  /** 显示名（优先使用 summary.json 的 site 字段） */
  displayName: string;
  /** 数据源 key：'public' */
  sourceKey: string;
  /** 站点根目录相对路径（相对数据源根） */
  rootRel: string;
  /** 总页数（来自 summary.json，可能为 0） */
  totalPages: number;
  /** 首页标题（Main 命名空间） */
  homeTitle: string;
}

/** 文件/目录信息 */
export interface FileInfo {
  name: string;
  isDir: boolean;
  size: number;
}

/** 节点类型 */
export enum NodeType {
  Root = 'root',
  Text = 'text',
  Bold = 'bold',
  Italic = 'italic',
  BoldItalic = 'boldItalic',
  Color = 'color',
  Heading = 'heading',
  Paragraph = 'paragraph',
  UnorderedList = 'ul',
  OrderedList = 'ol',
  ListItem = 'li',
  Indent = 'indent',
  Table = 'table',
  TableRow = 'tr',
  TableHeaderCell = 'th',
  TableCell = 'td',
  Link = 'link',
  FileImage = 'file',
  ExternalLink = 'extlink',
  Hr = 'hr',
  Pre = 'pre',
  RawHtml = 'rawhtml',
  LineBreak = 'br',
  Placeholder = 'placeholder',
  Container = 'container',
  /** 进度/量表（HTML 直渲染：強さ双色条、斩位多色段） */
  Gauge = 'gauge',
  /** 敌人地图位置（底图 + 标记点） */
  /** 通用地图节点（模块输出 @@WIKIMAP 协议行） */
  Map = 'map',
}

/** 地图标记点（相对底图的百分比坐标） */
export interface MapMarker {
  /** 距左侧百分比 0-100 */
  left: number;
  /** 距顶部百分比 0-100 */
  top: number;
}

/** 量表色段（顺序并排渲染） */
export interface GaugeSeg {
  /** 占比 0-100 */
  pct: number;
  color: string;
}

/** wikitext 解析后的节点 */
export interface WikiNode {
  type: NodeType;
  /** 纯文本内容（Text / Pre / RawHtml） */
  text?: string;
  /** 标题级别或列表嵌套深度 */
  level?: number;
  /** 行内子节点（段落、标题、单元格、列表项） */
  inline?: WikiNode[];
  /** 行内颜色（Color 节点：#rrggbb） */
  color?: string;
  /** 行内字号（Color 节点承载 <small>/<big>：<small> 固定 12） */
  fontSize?: number;
  /** 块级子节点（列表、表格、模板展开结果） */
  children?: WikiNode[];
  /** 链接解析后的目标标题 */
  target?: string;
  /** 链接原始显示文本 */
  display?: string;
  /** 外部链接 url */
  href?: string;
  /** 图片文件名 */
  fileName?: string;
  /** 图片宽度（px） */
  fileWidth?: number;
  /** 图片高度（px，x400px 限高注释） */
  fileHeight?: number;
  /** 图片对齐：left/center/right */
  fileAlign?: string;
  /** 图片点击链接目标标题 */
  fileLink?: string;
  /** 图片说明 */
  caption?: WikiNode[];
  /** 占位原因 */
  reason?: string;
  /** 单元格对齐 */
  align?: string;
  /** 单元格跨列 */
  colSpan?: number;
  /** 单元格跨行 */
  rowSpan?: number;
  /** 单元格列位置（解析表格时按 rowspan 占位计算） */
  colIndex?: number;
  /** 表头声明的列宽百分比（如 width="50%"），按比例分配列宽 */
  widthPct?: number;
  /** 背景色（HTML 直渲染：单元格/行内 #rrggbb，如乱入标记赤底） */
  bgColor?: string;
  /** 链接 fragment（HTML 直渲染锚点，如 #id182540；MVP 跳转时忽略） */
  anchor?: string;
  /** 量表色段（Gauge 节点） */
  gaugeSegs?: GaugeSeg[];
  /** 量表条高（vp，缺省 4） */
  gaugeHeight?: number;
  /** 地图区域名（对应 Mapinfo Name，如 ma02a_f01） */
  /** 地图底图文件名（由模块输出时拼好，引擎不感知站点命名规则） */
  mapImage?: string;
  /** 地图标题（mapName・menuGroup） */
  mapTitle?: string;
  /** 地图宽高比（宽/高） */
  mapRatio?: number;
  /** 地图标记点 */
  mapMarkers?: MapMarker[];
}

/** 行内 token 类型 */
export enum InlineType {
  Text = 'text',
  Bold = 'bold',
  Italic = 'italic',
  BoldItalic = 'boldItalic',
  Link = 'link',
  File = 'file',
  ExternalLink = 'extlink',
  LineBreak = 'br',
  RawHtml = 'rawhtml',
  Nowiki = 'nowiki',
}

/** 行内 token */
export interface InlineToken {
  type: InlineType;
  text?: string;
  /** 链接目标（未解析） */
  target?: string;
  /** 显示文本（未解析） */
  display?: string;
  /** 图片选项 */
  fileOptions?: string[];
  href?: string;
}
