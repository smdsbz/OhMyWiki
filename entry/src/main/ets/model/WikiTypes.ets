/**
 * 数据模型：站点信息与 wikitext 节点树类型
 */

/** 一个 wiki 站点（Download/OhMyWiki 下的一个顶层文件夹） */
export interface WikiSite {
  /** 顶层文件夹名 */
  name: string;
  /** 显示名（优先使用 summary.json 的 site 字段） */
  displayName: string;
  /** 数据源 key：'sandbox' | 'public' */
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
