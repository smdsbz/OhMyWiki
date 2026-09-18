import { describe, it, expect } from '@ohos/hypium';
import { DataSource } from '../main/ets/data/DataSource';
import { WikiIndex } from '../main/ets/data/WikiIndex';
import { NodeType, WikiNode } from '../main/ets/model/WikiTypes';
import { HtmlParser } from '../main/ets/wiki/parser/HtmlParser';
import { HtmlPageConfig, HtmlInlineStyle, HtmlHeadingRule } from '../main/ets/wiki/siteadapter/HtmlPageConfig';

/** 最小 MHXX 形态配置（与 MhxxSiteAdapter 同规则） */
const TEST_CONFIG: HtmlPageConfig = {
  rootId: 'main_1',
  skipIds: ['bread', 'navi1'],
  skipTags: ['script', 'style', 'noscript', 'head'],
  skipClasses: ['box2', 'box_off', 'box_on', 'pnl_base', 'panel_btn'],
  hiddenClasses: ['pc_only', 'pc2_only'],
  skipHeadingTags: ['h2'],
  headingTagLevels: { 'h3': 2, 'h4': 3 },
  headingClassRules: [{ cls: 'panel-heading', level: 2 } as HtmlHeadingRule],
  inlineClassStyles: [
    { cls: 'c_g', color: '#008000' } as HtmlInlineStyle,
    { cls: 'b', bold: true } as HtmlInlineStyle,
    { cls: 'kr0', color: '#bc0b43' } as HtmlInlineStyle,
    { cls: 'kr7', color: '#555555' } as HtmlInlineStyle,
  ],
  gaugeBarColors: {
    'progress-bar-success': '#5cb85c',
    'progress-bar-warning': '#f0ad4e',
  },
  gaugeDefaultColor: '#337ab7',
  gaugeContainerClass: 'progress',
  gaugeBarClass: 'progress-bar',
  sharpnessClass: 'kireage',
  internalPathPattern: /^(index\.html|(data|ida)\/\d+\.html)$/,
  assetPrefix: 'images/',
};

/** 内存 DataSource stub：只服务 manifest.json */
class StubSource implements DataSource {
  key: string = 'stub';
  private files: Map<string, string> = new Map();

  add(rel: string, content: string): void {
    this.files.set(rel, content);
  }

  describe(): string {
    return 'stub';
  }

  async isAvailable(): Promise<boolean> {
    return true;
  }

  async listSubDirs(rel: string): Promise<string[]> {
    return [];
  }

  async listAllFiles(rel: string): Promise<string[]> {
    return Array.from(this.files.keys());
  }

  async readText(rel: string): Promise<string> {
    const v = this.files.get(rel);
    if (v === undefined) {
      throw new Error('ENOENT: ' + rel);
    }
    return v;
  }

  async readBinary(rel: string): Promise<Uint8Array> {
    throw new Error('not used: ' + rel);
  }

  async exists(rel: string): Promise<boolean> {
    return this.files.has(rel);
  }

  async isDir(rel: string): Promise<boolean> {
    return false;
  }

  async statSize(rel: string): Promise<number> {
    return (this.files.get(rel) ?? '').length;
  }
}

async function mkIndex(): Promise<WikiIndex> {
  const src = new StubSource();
  src.add('monster-hunter-web-data-html/manifest.json', JSON.stringify([
    { title: '首页', ns: 0, pageid: 0, path: 'index.html', bytes: 1 },
    { title: '怪物:斩龙', ns: 100, pageid: 1829, path: 'data/1829.html', bytes: 1 },
    { title: '地图:古代林', ns: 100, pageid: 2400, path: 'data/2400.html', bytes: 1 },
    { title: '任务:村★3波乱的萌芽', ns: 100, pageid: 220173, path: 'ida/220173.html', bytes: 1 },
    { title: '怪物:跳狗龙', ns: 100, pageid: 1836, path: 'data/1836.html', bytes: 1 },
  ]));
  const index = new WikiIndex(src, 'monster-hunter-web-data-html');
  await index.load();
  return index;
}

/** 斩龙页「出现任务」表真实结构片段（清洗后） */
const QUEST_TABLE_HTML = `
<!doctype html>
<html lang="ja"><body id="body_game">
<div id="main_1"><div class="data1">
<h2 class="c_black">斩龙 - 【MHXX】怪物猎人双十字</h2>
<h3>出现任务</h3>
<div class="box1">
<span style="background-color:#FFE8E0;">赤色</span>背景は乱入时に出现
</div>
<table class="t1">
<tbody>
<tr>
<th width="43%" class="sp_only">任务名</th>
<th width="17%" class="sp_only">強さ</th>
<th width="40%" class="sp_only">怪物</th>
<th width="15%" class="pc_only">种类</th>
<th width="30%" class="pc_only">任务名</th>
<th width="10%" class="pc_only">区域</th>
<th width="15%" class="pc_only">強さ</th>
<th width="30%" class="pc_only">怪物</th>
</tr>
<tr>
<td style="background-color:#FFE8E0;color:green;" class="pc_only"> 村下3 </td>
<td style="background-color:#FFE8E0;padding-left:10px;" class="left"> <img alt="采集" title="采集" src="../images/quest/quest4.png" width="16px" height="16px"> <span class="sp_only"> <span style="color:green;">村下3</span> [<a href="../data/2400.html">古代林</a>]<br> </span> <a href="../ida/220173.html">波乱的萌芽</a> </td>
<td style="background-color:#F0FFF0" class="pc_only"> <a href="../data/2400.html">古代林</a> </td>
<td style="background-color:#FFE8E0;">
<div class="progress" style="height:3px;margin:3px;">
<div class="progress-bar progress-bar-success" role="progressbar" style="width:30%;height:3px;"></div>
</div>
<div class="progress" style="height:3px;margin:3px;">
<div class="progress-bar progress-bar-warning" role="progressbar" style="width:35%;height:3px;"></div>
</div> </td>
<td style="background-color:#FFE8E0;"> <img src="../images/monster_color/rannyu1.png" width="16px" height="16px"> <span style="background-color:#fff0a0;"><a href="../data/1836.html#id182544">跳狗龙</a></span><br> </td>
</tr>
</tbody>
</table>
</div></div>
</body></html>
`;

function findTable(nodes: WikiNode[]): WikiNode | null {
  for (const n of nodes) {
    if (n.type === NodeType.Table) {
      return n;
    }
    if (n.children !== undefined) {
      const r = findTable(n.children);
      if (r !== null) {
        return r;
      }
    }
  }
  return null;
}

function gaugesOf(nodes: WikiNode[]): WikiNode[] {
  const out: WikiNode[] = [];
  const walk = (list: WikiNode[]): void => {
    for (const n of list) {
      if (n.type === NodeType.Gauge) {
        out.push(n);
      }
      if (n.inline !== undefined) {
        walk(n.inline);
      }
    }
  };
  walk(nodes);
  return out;
}

export default function htmlParserTest() {
  describe('HtmlParserTest', () => {
    it('questTableMobileLayout', 0, async () => {
      const index = await mkIndex();
      expect(index.resolvePathLink('ida/220173.html')).assertEqual('任务:村★3波乱的萌芽');
      expect(index.findPath('怪物:斩龙')).assertEqual('pages/data/1829.html');
      const parser = new HtmlParser(index, '怪物:斩龙', TEST_CONFIG);
      const nodes = parser.parse(QUEST_TABLE_HTML);
      // h2 跳过，h3 → level 2 标题
      const headings = nodes.filter((n: WikiNode) => n.type === NodeType.Heading);
      expect(headings.length).assertEqual(1);
      expect(headings[0].level).assertEqual(2);
      const table = findTable(nodes);
      expect(table === null ? 0 : (table.children as WikiNode[]).length).assertEqual(2);
      const rows = table !== null ? table.children as WikiNode[] : [];
      // 表头：8 列过滤 pc_only 后剩 3 列 sp_only，widthPct 43/17/40，colIndex 0/1/2
      const headerCells = rows[0].children as WikiNode[];
      expect(headerCells.length).assertEqual(3);
      expect(headerCells[0].type).assertEqual(NodeType.TableHeaderCell);
      expect(headerCells[0].widthPct).assertEqual(43);
      expect(headerCells[1].widthPct).assertEqual(17);
      expect(headerCells[2].widthPct).assertEqual(40);
      expect(headerCells[0].colIndex).assertEqual(0);
      expect(headerCells[1].colIndex).assertEqual(1);
      expect(headerCells[2].colIndex).assertEqual(2);
      // 数据行：过滤后 3 格（任务/強さ/怪物）
      const dataCells = rows[1].children as WikiNode[];
      expect(dataCells.length).assertEqual(3);
      expect(dataCells[0].colIndex).assertEqual(0);
      expect(dataCells[1].colIndex).assertEqual(1);
      expect(dataCells[2].colIndex).assertEqual(2);
      // 強さ格：两个 Gauge（30% 绿 + 35% 橙）
      expect(dataCells[1].bgColor).assertEqual('#FFE8E0');
      const gauges = gaugesOf(dataCells[1].inline as WikiNode[]);
      expect(gauges.length).assertEqual(2);
      const g0 = (gauges[0].gaugeSegs ?? [{ pct: -1, color: '' }])[0];
      const g1 = (gauges[1].gaugeSegs ?? [{ pct: -1, color: '' }])[0];
      expect(g0.pct).assertEqual(30);
      expect(g0.color).assertEqual('#5cb85c');
      expect(g1.pct).assertEqual(35);
      expect(g1.color).assertEqual('#f0ad4e');
    });

    it('questCellLinksAndImages', 0, async () => {
      const index = await mkIndex();
      const parser = new HtmlParser(index, '怪物:斩龙', TEST_CONFIG);
      const nodes = parser.parse(QUEST_TABLE_HTML);
      const table = findTable(nodes);
      const rows = table !== null ? table.children as WikiNode[] : [];
      const cells = rows[1].children as WikiNode[];
      const inline = cells[0].inline as WikiNode[];
      // 图片：子目录路径保留
      const imgs = inline.filter((n: WikiNode) => n.type === NodeType.FileImage);
      expect(imgs.length).assertEqual(1);
      expect(imgs[0].fileName).assertEqual('quest/quest4.png');
      expect(imgs[0].fileWidth).assertEqual(16);
      // 站内链接：../ida/220173.html → 任务:村★3波乱的萌芽（sp_only span 内）
      const links = inline.filter((n: WikiNode) => n.type === NodeType.Link);
      let questLink: WikiNode | null = null;
      const walk = (list: WikiNode[]): void => {
        for (const n of list) {
          if (n.type === NodeType.Link && n.target === '任务:村★3波乱的萌芽') {
            questLink = n;
          }
          if (n.inline !== undefined) {
            walk(n.inline);
          }
        }
      };
      walk(inline);
      expect(links.length).assertEqual(2); // sp_only span 透明展开：古代林 + 波乱的萌芽 都在顶层
      expect(questLink !== null).assertTrue();
      // 怪物列：乱入黄底 Color 包裹跳狗龙链接
      const monsterInline = cells[2].inline as WikiNode[];
      let bgSpan: WikiNode | null = null;
      for (const n of monsterInline) {
        if (n.type === NodeType.Color && n.bgColor === '#fff0a0') {
          bgSpan = n;
        }
      }
      expect(bgSpan !== null).assertTrue();
      expect(cells[2].bgColor).assertEqual('#FFE8E0');
    });

    it('rowspanColspanPlacement', 0, () => {
      const html = '<div id="main_1"><table><tbody>'
        + '<tr><td rowspan="2">A</td><td>B</td><td colspan="2">C</td></tr>'
        + '<tr><td>b1</td><td>b2</td><td>b3</td></tr>'
        + '</tbody></table></div>';
      const parser = new HtmlParser(null, '首页', TEST_CONFIG);
      const nodes = parser.parse(html);
      const table = findTable(nodes);
      expect(table !== null).assertTrue();
      const rows = (table as WikiNode).children as WikiNode[];
      const r0 = rows[0].children as WikiNode[];
      const r1 = rows[1].children as WikiNode[];
      expect(r0[0].colIndex).assertEqual(0);
      expect(r0[1].colIndex).assertEqual(1);
      expect(r0[2].colIndex).assertEqual(2);
      expect(r0[2].colSpan).assertEqual(2);
      // 第二行：列 0 被 rowspan 占用 → b1 从列 1 开始
      expect(r1[0].colIndex).assertEqual(1);
      expect(r1[1].colIndex).assertEqual(2);
      expect(r1[2].colIndex).assertEqual(3);
    });

    it('sharpnessGauge', 0, () => {
      const html = '<div id="main_1"><table><tbody><tr><td>'
        + '<div class="kireage"><span class="kr0">.........</span><span class="kr7">..............................</span>\n'
        + '<span class="kr0">.........</span><span class="kr7">.........................</span>\n'
        + '</div></td></tr></tbody></table></div>';
      const parser = new HtmlParser(null, '首页', TEST_CONFIG);
      const nodes = parser.parse(html);
      const table = findTable(nodes);
      const cell = ((table as WikiNode).children as WikiNode[])[0].children as WikiNode[];
      const gauges = gaugesOf(cell[0].inline as WikiNode[]);
      // 两行两条 Gauge；行长 35 vs 31 点，按最长行归一
      expect(gauges.length).assertEqual(2);
      const row0 = gauges[0].gaugeSegs ?? [];
      const row1 = gauges[1].gaugeSegs ?? [];
      expect(row0[0].color).assertEqual('#bc0b43');
      expect(row0[1].color).assertEqual('#555555');
      // 两行长度 39 与 34 点，按最长行 39 归一：9/39→23、30/39→77、25/39→64
      expect(row0[0].pct).assertEqual(23);
      expect(row0[1].pct).assertEqual(77);
      expect(row1[1].pct).assertEqual(64);
    });
  });
}
