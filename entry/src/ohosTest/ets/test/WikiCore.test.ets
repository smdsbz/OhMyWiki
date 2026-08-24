import { describe, it, expect } from '@ohos/hypium';
import { WikitextParser } from '../../../main/ets/wiki/parser/WikitextParser';
import { TemplateEngine, TemplateContext } from '../../../main/ets/wiki/template/TemplateEngine';
import { EnemyModule } from '../../../main/ets/wiki/module/EnemyModule';
import { WikiIndex } from '../../../main/ets/data/WikiIndex';
import { ShopFinder } from '../../../main/ets/data/ShopFinder';
import { DataSource } from '../../../main/ets/data/DataSource';
import { NodeType, WikiNode } from '../../../main/ets/model/WikiTypes';

/** 内存数据源：以 rel 路径 → 内容 的 Map 提供数据 */
class FakeSource implements DataSource {
  readonly key: string = 'fake';
  private files: Map<string, string> = new Map();

  constructor(files: Map<string, string>) {
    this.files = files;
  }

  describe(): string {
    return 'fake';
  }

  async isAvailable(): Promise<boolean> {
    return true;
  }

  async listSubDirs(rel: string): Promise<string[]> {
    return [];
  }

  async listAllFiles(rel: string): Promise<string[]> {
    const out: string[] = [];
    const prefix = rel.length > 0 ? rel + '/' : '';
    for (const k of this.files.keys()) {
      if (prefix.length === 0 || k.startsWith(prefix)) {
        out.push(k);
      }
    }
    return out;
  }

  async readText(rel: string): Promise<string> {
    return this.files.get(rel) ?? '';
  }

  async readBinary(rel: string): Promise<Uint8Array> {
    return new Uint8Array(0);
  }

  async exists(rel: string): Promise<boolean> {
    return this.files.has(rel);
  }

  async isDir(rel: string): Promise<boolean> {
    return false;
  }

  async statSize(rel: string): Promise<number> {
    return 0;
  }
}

const BLADEINFO = `{{返回|异刃|异刃一览}}
<div style="display:flex;flex-wrap:wrap-reverse;justify-content:space-between;">
{| class="wikitable"
! 战斗类别
| {{{战斗类别}}}
|-
! 属性
| [[元素属性::{{{属性}}}]]
|-
! 武器
| [[武器种类::{{{武器}}}]]
|-
! 加入方法
| {{{加入方法}}}
|}
<div>
[[文件:{{{立绘}}}|center|x400px]]
</div>
</div>`;

const HOMEPAGE = `__NOTITLE__

编辑群：291964224

[[文件:N2e封面图.jpg|1000px|居中|link=Nintendo Switch 2 Edition]]

{| class="wikitable" style="margin: auto; width: 100%;"
|-
!流程
|[[流程攻略|主线攻略]]<nowiki> | </nowiki>[[Advanced New Game]]
|-
!异刃
|[[异刃]]<nowiki> | </nowiki>[[武器种类|武器]]
|}

== 测试标题 ==

* [[异刃:焰|焰]]
* [[敌人:一骑当千的萨克森|一骑当千的萨克森]]`;

const YAN = `{{BladeInfo
|战斗类别=攻击
|属性=火
|武器=圣杯之剑
|物理防御=5
|以太防御=10
|初始强度=24
|冷却时间=20
|御刃者能力修正=力量10%
|初始牵绊值=500
|牵绊上升=0
|牵绊降低=0
|辅助核心插槽数=2
|喜欢的类别1=蔬菜
|喜欢的类别2=书籍
|喜欢的物品1=塞利奥茶
|喜欢的物品2=木纹阿尔卑斯长号
|加入方法=第一章主线剧情
|立绘=fim_bl_001_0.png
}}

== 人物简介 ==

“带我，去乐园好吗？”

{{剧透|在洛修利亚为了保护莱克斯他们，献出了自己。}}`;

const LIUGONG = `基于1.3.0版本，Normal难度，简体中文

* [[/第一章/]]
* [[/第二章/]]
* [[/第三章/]]
* [[/第四章/]]
* [[/第五章/]]
* [[/第六章/]]
* [[/第七章/]]
* [[/第八章/]]
* [[/第九章/]]
* [[/最终章/]]`;

const BLADE_COMBO_TBL = `{| class="blade-combo-table"
| rowspan="4" | {{icon|火|60px}}
| rowspan="2" | {{icon|火|42px}}
| {{icon|火|30px}}
|-
| {{icon|光|30px}}
|-
| rowspan="2" | {{icon|水|42px}}
| {{icon|火|30px}}
|-
| {{icon|冰|30px}}
|}`;

const ICON = `[[File:icon-{{{1}}}.png | {{{2|}}} | {{{3 | {{{1}}} }}} | link= ]]`;

const SHOP_FISH = `{{商店
|地区=斯佩比亚
|位置=斯佩比亚帝国・帝都阿尔巴马格・爱比尔商业区
|店主=萨拉
|商店条件=
}}
{| class="wikitable"
|-
! 名称 !! 稀有度 !! 价格 !! 所需契约书 !! 其他条件
{{ShopGoodsPouchItemRow|香烤沙鲑||}}
{{ShopGoodsPouchItemRow|云海蟹奶油土豆饼||}}
{{ShopGoodsDeedsRow|汉努恩店铺产权证}}
|}`;

const SHOP_ART = `{{商店
|地区=洛修利亚
|位置=洛修利亚王国・王都特奥斯奥莱・特奥斯奥莱居住区
|店主=特弗罗尼奥
|商店条件=
}}
{| class="wikitable"
|-
! 名称 !! 稀有度 !! 价格 !! 所需契约书 !! 其他条件
{{ShopGoodsPouchItemRow|最后的合唱||第8章阿卡狄亚事件后}}
{{ShopGoodsDeedsRow|美好回忆店铺产权证}}
|}`;

const ARRANGE_926 = `{"id":926,"ParamID":688,"Name":"一骑当千的萨克森","Lv":99,"LvRand":0,"ExpRev":600,"GoldRev":360,"WPRev":200,"SPRev":200,"Scale":100,"EnhanceID1":0,"EnhanceID2":0,"EnhanceID3":0,"ParamRev":0,"ZoneID":0,"IgnoreLevPow":false}`;
const PARAM_688 = `{"id":688,"ResourceID":329,"HpMaxRev":1740,"StrengthRev":1050,"PowEtherRev":960,"DexRev":1200,"AgilityRev":840,"LuckRev":780,"RstPower":15,"RstEther":5,"Atr":"无","CriticalRate":8,"GuardRate":2,"IvdFiCombo":0,"RstFiCombo":7}`;
const PARAMTABLE_99 = `{"id":99,"HpMaxBase":340850,"StrengthBase":737,"PowEtherBase":737,"DexBase":306,"AgilityBase":306,"LuckBase":360}`;
const GROW_99 = `{"id":99,"EnemyExp":1474,"EnemyGold":888,"EnemyWP":44,"EnemySP":17}`;
const RSC_329 = `{"id":329,"TypeFamily":"人型"}`;

const MANIFEST = JSON.stringify([
  { title: '首页', ns: 0, pageid: 1, path: 'Main/首页.wiki' },
  { title: '异刃', ns: 0, pageid: 2, path: 'Main/异刃.wiki' },
  { title: '异刃:焰', ns: 0, pageid: 3, path: '异刃/焰.wiki' },
  { title: '敌人:一骑当千的萨克森', ns: 0, pageid: 4, path: '敌人/一骑当千的萨克森.wiki' },
  { title: '模板:BladeInfo', ns: 10, pageid: 5, path: '模板/BladeInfo.wiki' },
  { title: '模板:返回', ns: 10, pageid: 6, path: '模板/返回.wiki' },
  { title: '模板:剧透', ns: 10, pageid: 7, path: '模板/剧透.wiki' },
  { title: 'JSON:EnemyIdMap', ns: 828, pageid: 8, path: 'JSON/EnemyIdMap.wiki' },
  { title: 'JSON:EnemyCategory', ns: 828, pageid: 9, path: 'JSON/EnemyCategory.wiki' },
  { title: 'JSON:CHR_EnArrange/926', ns: 828, pageid: 10, path: 'JSON/CHR EnArrange/926.wiki' },
  { title: 'JSON:CHR_EnParam/688', ns: 828, pageid: 11, path: 'JSON/CHR EnParam/688.wiki' },
  { title: 'JSON:CHR_EnParamTable/99', ns: 828, pageid: 12, path: 'JSON/CHR EnParamTable/99.wiki' },
  { title: 'JSON:BTL_Grow/99', ns: 828, pageid: 13, path: 'JSON/BTL Grow/99.wiki' },
  { title: 'JSON:RSC_En/329', ns: 828, pageid: 14, path: 'JSON/RSC En/329.wiki' },
  { title: '流程攻略', ns: 0, pageid: 20, path: 'Main/流程攻略.wiki' },
  { title: '流程攻略/第一章', ns: 0, pageid: 21, path: 'Main/流程攻略/第一章.wiki' },
  { title: '流程攻略/第二章', ns: 0, pageid: 22, path: 'Main/流程攻略/第二章.wiki' },
  { title: '模板:Icon', ns: 10, pageid: 23, path: '模板/Icon.wiki' },
  { title: '商店:汉努恩鱼店', ns: 0, pageid: 30, path: '商店/汉努恩鱼店.wiki' },
  { title: '商店:美好回忆美术店', ns: 0, pageid: 31, path: '商店/美好回忆美术店.wiki' },
]);

function buildIndex(): WikiIndex {
  const files = new Map<string, string>();
  files.set('manifest.json', MANIFEST);
  files.set('summary.json', '{"site":"测试站"}');
  files.set('pages/Main/首页.wiki', HOMEPAGE);
  files.set('pages/Main/异刃.wiki', '== 异刃 ==\n[[异刃:焰|焰]]');
  files.set('pages/异刃/焰.wiki', YAN);
  files.set('pages/敌人/一骑当千的萨克森.wiki', '{{enemy}}');
  files.set('pages/模板/BladeInfo.wiki', BLADEINFO);
  files.set('pages/模板/返回.wiki',
    '<div><small><span style="color:#666"><</span> [[{{{1}}}|' + '{{{2|' + '{{{1}}}' + '}}}' + ']]</small></div>');
  files.set('pages/模板/剧透.wiki', '<span class="spoiler">{{{1}}}</span>');
  files.set('pages/JSON/EnemyIdMap.wiki', '{"一骑当千的萨克森": [926]}');
  files.set('pages/JSON/EnemyCategory.wiki', '{}');
  files.set('pages/JSON/CHR EnArrange/926.wiki', ARRANGE_926);
  files.set('pages/JSON/CHR EnParam/688.wiki', PARAM_688);
  files.set('pages/JSON/CHR EnParamTable/99.wiki', PARAMTABLE_99);
  files.set('pages/JSON/BTL Grow/99.wiki', GROW_99);
  files.set('pages/JSON/RSC En/329.wiki', RSC_329);
  files.set('pages/Main/流程攻略.wiki', LIUGONG);
  files.set('pages/Main/流程攻略/第一章.wiki', '第一章　相遇\n\n战斗：Lv1 王冠铠虾');
  files.set('pages/Main/流程攻略/第二章.wiki', '第二章');
  files.set('pages/模板/Icon.wiki', ICON);
  files.set('pages/商店/汉努恩鱼店.wiki', SHOP_FISH);
  files.set('pages/商店/美好回忆美术店.wiki', SHOP_ART);
  files.set('images/N2e封面图.jpg', 'x');
  files.set('images/流程攻略_1519546820_11115.jpg', 'x');
  files.set('images/Fim_bl_002_0.png', 'x');
  return new WikiIndex(new FakeSource(files), '');
}

function countNodes(nodes: WikiNode[], type: NodeType): number {
  let c = 0;
  for (const n of nodes) {
    if (n.type === type) {
      c++;
    }
    if (n.inline !== undefined) {
      c += countNodes(n.inline as WikiNode[], type);
    }
    if (n.children !== undefined) {
      c += countNodes(n.children as WikiNode[], type);
    }
  }
  return c;
}

export default function wikiCoreTest() {
  describe('WikiCoreTest', () => {
    it('parser_homepage', 0, async () => {
      const idx = buildIndex();
      await idx.load();
      const parser = new WikitextParser(idx, '首页');
      const nodes = parser.parse(HOMEPAGE);
      expect(countNodes(nodes, NodeType.Table)).assertLarger(0);
      expect(countNodes(nodes, NodeType.FileImage)).assertLarger(0);
      expect(countNodes(nodes, NodeType.Link)).assertLarger(0);
      expect(countNodes(nodes, NodeType.Heading)).assertLarger(0);
      expect(countNodes(nodes, NodeType.ListItem)).assertLarger(0);
    });

    it('template_bladeinfo_expand', 0, async () => {
      const idx = buildIndex();
      await idx.load();
      const ctx: TemplateContext = { pageTitle: '异刃:焰', index: idx, invokeHandler: null };
      const engine = new TemplateEngine(ctx);
      const expanded = await engine.expand(YAN);
      expect(expanded).assertContain('火');
      expect(expanded).assertContain('圣杯之剑');
      expect(expanded).assertContain('第一章主线剧情');
      expect(expanded).assertContain('异刃一览');
      expect(expanded.includes('{{')).assertFalse();
    });

    it('parser_list_not_duplicated', 0, async () => {
      const idx = buildIndex();
      await idx.load();
      const parser = new WikitextParser(idx, '流程攻略');
      const nodes = parser.parse(LIUGONG);
      // 列表应解析为单个 UnorderedList（回归：不能因重复挂接包成 paragraph 双份）
      expect(nodes.length).assertEqual(2);
      expect(nodes[1].type).assertEqual(NodeType.UnorderedList);
      const items = nodes[1].children as WikiNode[];
      expect(items.length).assertEqual(10);
    });

    it('resolve_subpage_link_slashes', 0, async () => {
      const idx = buildIndex();
      await idx.load();
      const resolved = idx.resolveLink('/第一章/', '流程攻略');
      expect(resolved).assertEqual('流程攻略/第一章');
    });

    it('resolve_image_name_normalization', 0, async () => {
      const idx = buildIndex();
      await idx.load();
      // 子页面前缀冒号 + 空格 → 存储名（下划线）
      const resolved = idx.resolveImageFileName('流程攻略:1519546820 11115.jpg');
      expect(resolved).assertEqual('流程攻略_1519546820_11115.jpg');
      expect(idx.imageExists('流程攻略:1519546820 11115.jpg')).assertTrue();
      // 普通无空格名
      expect(idx.resolveImageFileName('N2e封面图.jpg')).assertEqual('N2e封面图.jpg');
    });

    it('resolve_image_name_first_char_case', 0, async () => {
      const idx = buildIndex();
      await idx.load();
      // MediaWiki：文件/页面标题首字母大小写不敏感（引用小写 fim_...，存储大写 Fim_...）
      const resolved = idx.resolveImageFileName('fim_bl_002_0.png');
      expect(resolved).assertEqual('Fim_bl_002_0.png');
      expect(idx.imageExists('fim_bl_002_0.png')).assertTrue();
      // 首字母小写的引用也能匹配
      expect(idx.resolveImageFileName('Fim_bl_002_0.png')).assertEqual('Fim_bl_002_0.png');
    });

    it('template_name_case_insensitive', 0, async () => {
      const idx = buildIndex();
      await idx.load();
      // {{icon}} 小写调用 → 应命中模板:Icon（MediaWiki 模板名首字母大小写不敏感）
      const src = await idx.readTemplate('icon');
      expect(src).assertContain('File:icon-');
      // 完整展开
      const ctx: TemplateContext = { pageTitle: '异刃连击路线', index: idx, invokeHandler: null };
      const engine = new TemplateEngine(ctx);
      const out = await engine.expand('{{icon|火|60px}}');
      expect(out).assertContain('File:icon-火.png');
      expect(out.includes('{{')).assertFalse();
    });

    it('table_rowspan_colindex', 0, async () => {
      const idx = buildIndex();
      await idx.load();
      const parser = new WikitextParser(idx, '异刃连击路线');
      const nodes = parser.parse(BLADE_COMBO_TBL);
      expect(nodes.length).assertEqual(1);
      const table = nodes[0];
      expect(table.type).assertEqual(NodeType.Table);
      const rows = table.children as WikiNode[];
      expect(rows.length).assertEqual(4);
      // 行0：火60px(rowspan4,列0)、火42px(rowspan2,列1)、火30px(列2)
      const r0 = (rows[0] as WikiNode).children as WikiNode[];
      expect(r0.length).assertEqual(3);
      expect((r0[0] as WikiNode).colIndex).assertEqual(0);
      expect((r0[0] as WikiNode).rowSpan).assertEqual(4);
      expect((r0[1] as WikiNode).colIndex).assertEqual(1);
      expect((r0[1] as WikiNode).rowSpan).assertEqual(2);
      expect((r0[2] as WikiNode).colIndex).assertEqual(2);
      // 回归：makeCell 剥离 rowspan 属性后不得残留前导空格（否则 inline=[Text(" "),FileImage] 使 isSingleImage 失效、渲染不一致）
      const inl0 = (r0[0] as WikiNode).inline as WikiNode[];
      expect((inl0[0] as WikiNode).text ?? '').assertEqual('{{icon|火|60px}}');
      const inl1 = (r0[1] as WikiNode).inline as WikiNode[];
      expect((inl1[0] as WikiNode).text ?? '').assertEqual('{{icon|火|42px}}');
      // 行1：光30px 应位于第3列（前两列被上方 rowspan 占用）
      const r1 = (rows[1] as WikiNode).children as WikiNode[];
      expect(r1.length).assertEqual(1);
      expect((r1[0] as WikiNode).colIndex).assertEqual(2);
      // 行2：水42px(rowspan2,列1)、火30px(列2)
      const r2 = (rows[2] as WikiNode).children as WikiNode[];
      expect(r2.length).assertEqual(2);
      expect((r2[0] as WikiNode).colIndex).assertEqual(1);
      expect((r2[0] as WikiNode).rowSpan).assertEqual(2);
      expect((r2[1] as WikiNode).colIndex).assertEqual(2);
      // 行3：冰30px 应在第3列
      const r3 = (rows[3] as WikiNode).children as WikiNode[];
      expect(r3.length).assertEqual(1);
      expect((r3[0] as WikiNode).colIndex).assertEqual(2);
    });

    it('shopfinder_finds_item_shops', 0, async () => {
      const idx = buildIndex();
      await idx.load();
      const finder = new ShopFinder(idx);
      const fish = await finder.find('云海蟹奶油土豆饼');
      expect(fish.length).assertEqual(1);
      expect(fish[0].title).assertEqual('商店:汉努恩鱼店');
      expect(fish[0].region).assertEqual('斯佩比亚');
      expect(fish[0].location).assertContain('阿尔巴马格');
      const art = await finder.find('最后的合唱');
      expect(art.length).assertEqual(1);
      expect(art[0].title).assertEqual('商店:美好回忆美术店');
      expect(art[0].region).assertEqual('洛修利亚');
      // 不在任何商店出售的物品 → 空数组
      const none = await finder.find('不存在的东西');
      expect(none.length).assertEqual(0);
    });

    it('enemy_module_stats', 0, async () => {
      const idx = buildIndex();
      await idx.load();
      const ctx: TemplateContext = { pageTitle: '敌人:一骑当千的萨克森', index: idx, invokeHandler: null };
      const out = await EnemyModule.invoke('main', [], ctx);
      expect(out).assertContain('等级');
      expect(out).assertContain('99');
      expect(out).assertContain('无');
      expect(out).assertContain('人型');
      expect(out).assertContain('普通敌人');
      expect(out).assertContain('593079');
      expect(out).assertContain('8844');
      expect(out).assertContain('40%');
    });
  });
}
