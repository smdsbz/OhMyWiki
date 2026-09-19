import { Logger } from '../../../common/Logger';
import { TemplateContext } from '../../template/TemplateEngine';
import { JsonDataReader } from '../../module/JsonDataReader';
import { BdatEnums } from './BdatEnums';

const TAG = 'EnemyModule';

// ---------- JSON 结构 ----------

/** CHR_EnArrange 结构 */
interface EnArrangeJson {
  id: number;
  ParamID: number;
  Name: string;
  Lv: number;
  LvRand: number;
  ExpRev: number;
  GoldRev: number;
  WPRev: number;
  SPRev: number;
  Scale: number;
  EnhanceID1: number;
  EnhanceID2: number;
  EnhanceID3: number;
  ParamRev: number;
  ZoneID: number;
  IgnoreLevPow: boolean;
  DropTableID: number;
  DropTableID3: number;
  PreciousID: Object;
  EnemyBladeID: number;
  BladeID: number;
}

/** CHR_EnParam 结构 */
interface EnParamJson {
  id: number;
  ResourceID: number;
  HpMaxRev: number;
  StrengthRev: number;
  PowEtherRev: number;
  DexRev: number;
  AgilityRev: number;
  LuckRev: number;
  RstPower: number;
  RstEther: number;
  Atr: string;
  CriticalRate: number;
  GuardRate: number;
  IvdFiCombo: number;
  RstFiCombo: number;
  Aura: number;
  ArtsNum1: number;
  ArtsNum2: number;
  ArtsNum3: number;
  ArtsNum4: number;
  ArtsNum5: number;
  ArtsNum6: number;
  ArtsNum7: number;
  ArtsNum8: number;
  ArtsNum9: number;
  ArtsNum10: number;
  ArtsNum11: number;
  ArtsNum12: number;
  ArtsNum13: number;
  ArtsNum14: number;
  ArtsNum15: number;
  ArtsNum16: number;
}

/** CHR_EnParamTable 结构 */
interface EnParamTableJson {
  id: number;
  HpMaxBase: number;
  StrengthBase: number;
  PowEtherBase: number;
  DexBase: number;
  AgilityBase: number;
  LuckBase: number;
}

/** CHR_EnParam_Rev 结构（珍稀种能力修正） */
interface EnParamRevJson {
  HpMaxRev: number;
  StrengthRev: number;
  PowEtherRev: number;
  DexRev: number;
  AgilityRev: number;
  LuckRev: number;
}

/** RSC_En 结构 */
interface RscEnJson {
  id: number;
  TypeFamily: string;
}

/** BTL_Grow 结构 */
interface GrowJson {
  id: number;
  EnemyExp: number;
  EnemyGold: number;
  EnemyWP: number;
  EnemySP: number;
}

/** BTL_Enhance 结构 */
interface EnhanceJson {
  id: number;
  CaptionText: string;
}

/** BTL_Aura 结构 */
interface AuraJson {
  id: number;
  Name: string;
  Enhance1: number;
  Enhance2: number;
  Enhance3: number;
  ChangeAtr: string;
}

/** BTL_Buff 结构 */
interface BuffJson {
  Name: string;
}

/** BTL_Summon 结构 */
interface SummonJson {
  EnemyID: number[];
}

/** BTL_EnDropItem 结构（ItemIDx 预渲染为物品名，空槽为 0） */
interface EnDropItemJson {
  ItemID1: Object;
  ItemID2: Object;
  ItemID3: Object;
  ItemID4: Object;
  ItemID5: Object;
  ItemID6: Object;
  ItemID7: Object;
  ItemID8: Object;
  DropProb1: number;
  DropProb2: number;
  DropProb3: number;
  DropProb4: number;
  DropProb5: number;
  DropProb6: number;
  DropProb7: number;
  DropProb8: number;
  FirstNamed1: number;
  FirstNamed2: number;
  FirstNamed3: number;
  FirstNamed4: number;
  FirstNamed5: number;
  FirstNamed6: number;
  FirstNamed7: number;
  FirstNamed8: number;
}

/** CHR_Bl 结构（敌方携带异刃） */
interface ChrBlJson {
  Atr: string;
  BArts1: number;
  BArts2: number;
  BArts3: number;
}

/** EnemyIdMap 值元素 */
interface EnemyIdEntry {
  id: number;
  title?: string;
}

/** Gmk/enemy 条目（敌人放置点） */
interface GmkEnemyJson {
  Name: string;
  PosX?: number;
  PosY?: number;
  PosZ?: number;
  areas?: string[];
  POP_TIME?: number;
  popWeather?: number;
  ZoneID?: number;
}

/** Mapinfo 条目（底图世界坐标范围） */
interface MapinfoJson {
  Name: string;
  mapName?: string;
  menuGroup?: string;
  Width?: number;
  Height?: number;
  LowerX?: number;
  LowerZ?: number;
  UpperX?: number;
  UpperZ?: number;
}

/** 武技行（解析 BTL_Arts_En / BTL_Arts_Bl 的产物） */
interface ArtRow {
  mainCells: string[];
  detailLines: string[];
  /** 行级折叠 key（原站 mw-customtoggle-<artId>） */
  key: string;
}

/** 技能判定逐 hit 计算结果 */
interface HitResult {
  hitText: string;
  dmgTotal: number;
}

/**
 * Enemy 模块（Module:Enemy 的 ArkTS 移植）。
 * 敌人页核心数据：基本信息/六维/抗性/反应抗性/被动/愤怒光环/武技（行级折叠明细）/
 * 异刃必杀/击杀奖励掉落/出现方式/地图位置；并捕获 SMW 属性供 #ask 查询。
 */
export class EnemyModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const f = func.toLowerCase();
    if (f === 'main') {
      return await EnemyModule.renderMain(ctx);
    }
    return '';
  }

  private static async renderMain(ctx: TemplateContext): Promise<string> {
    // BdatEnums（武技枚举查表）随转储动态加载
    await BdatEnums.ensure(ctx);
    const fullTitle = ctx.pageTitle;
    const torna = fullTitle.startsWith('黄金之国');
    let name = fullTitle;
    const ci = name.indexOf(':');
    if (ci >= 0) {
      name = name.substring(ci + 1);
    }
    name = name.trim();
    if (name.length === 0) {
      return '';
    }
    const entries = await EnemyModule.lookupIds(ctx, name, torna);
    if (entries.length === 0) {
      return '{{#omw-note:未找到该敌人的数据}}';
    }
    const sb: string[] = [];
    for (const e of entries) {
      if (entries.length > 1) {
        const subtitle = e.title !== undefined && e.title.length > 0 ? e.title : String(e.id);
        sb.push('== ' + subtitle + ' ==');
      }
      const section = await EnemyModule.renderSingle(ctx, e.id, fullTitle, torna);
      sb.push(section);
    }
    return sb.join('\n');
  }

  private static async renderSingle(ctx: TemplateContext, id: number, fullTitle: string,
    torna: boolean): Promise<string> {
    try {
      const arrange = await JsonDataReader.read(ctx, 'CHR_EnArrange/' + id) as EnArrangeJson | null;
      if (arrange === null) {
        return '';
      }
      const categoryMap = await JsonDataReader.read(ctx, 'EnemyCategory') as Record<string, string>;
      const category = categoryMap !== null && categoryMap[String(id)] !== undefined ? categoryMap[String(id)] : '普通敌人';

      const param = await JsonDataReader.read(ctx, 'CHR_EnParam/' + arrange.ParamID) as EnParamJson | null;
      const paramBase = await JsonDataReader.read(ctx, 'CHR_EnParamTable/' + arrange.Lv) as EnParamTableJson | null;
      const rsc = param !== null ? await JsonDataReader.read(ctx, 'RSC_En/' + param.ResourceID) as RscEnJson | null : null;
      const grow = await JsonDataReader.read(ctx, 'BTL_Grow/' + arrange.Lv) as GrowJson | null;

      const enh1 = await EnemyModule.loadEnhance(ctx, arrange.EnhanceID1);
      const enh2 = await EnemyModule.loadEnhance(ctx, arrange.EnhanceID2);
      const enh3 = await EnemyModule.loadEnhance(ctx, arrange.EnhanceID3);

      let hp = ((paramBase?.HpMaxBase ?? 0) * (param?.HpMaxRev ?? 0)) / 1000;
      let str = ((paramBase?.StrengthBase ?? 0) * (param?.StrengthRev ?? 0)) / 1000;
      let ether = ((paramBase?.PowEtherBase ?? 0) * (param?.PowEtherRev ?? 0)) / 1000;
      let dex = ((paramBase?.DexBase ?? 0) * (param?.DexRev ?? 0)) / 1000;
      let agi = ((paramBase?.AgilityBase ?? 0) * (param?.AgilityRev ?? 0)) / 1000;
      let luck = ((paramBase?.LuckBase ?? 0) * (param?.LuckRev ?? 0)) / 1000;

      // 珍稀种能力修正（CHR_EnParam_Rev 二次乘算）
      if (arrange.ParamRev > 0) {
        const rev = await JsonDataReader.read(ctx, 'CHR_EnParam_Rev/' + arrange.ParamRev) as EnParamRevJson | null;
        if (rev !== null) {
          hp = hp * rev.HpMaxRev / 1000;
          str = str * rev.StrengthRev / 1000;
          ether = ether * rev.PowEtherRev / 1000;
          dex = dex * rev.DexRev / 1000;
          agi = agi * rev.AgilityRev / 1000;
          luck = luck * rev.LuckRev / 1000;
        }
      }
      hp = Math.floor(hp);
      str = Math.floor(str);
      ether = Math.floor(ether);
      dex = Math.floor(dex);
      agi = Math.floor(agi);
      luck = Math.floor(luck);

      const exp = Math.floor((grow?.EnemyExp ?? 0) * (arrange.ExpRev ?? 100) / 100);
      const gold = Math.floor((grow?.EnemyGold ?? 0) * (arrange.GoldRev ?? 100) / 100);
      const wp = Math.floor((grow?.EnemyWP ?? 0) * (arrange.WPRev ?? 100) / 100);
      const sp = Math.floor((grow?.EnemySP ?? 0) * (arrange.SPRev ?? 100) / 100);

      const reactions = EnemyModule.calcReactions(param !== null ? param.IvdFiCombo : 0, param !== null ? param.RstFiCombo : 0);

      await EnemyModule.captureSmw(ctx, arrange, category, param, rsc, hp, str, ether, dex, agi, luck,
        exp, gold, wp, sp, reactions);

      const sb: string[] = [];
      // 基本信息（转置；任务敌人多一列任务）
      const lvFloat = (arrange.LvRand ?? 0) === 0 ? '' : ' ( +' + arrange.LvRand + ' )';
      const basic: Array<Array<string>> = [];
      if (category === '任务敌人') {
        const quests = await EnemyModule.askTitles(ctx, '[[任务敌人::' + fullTitle + ']]');
        basic.push(['等级', String(arrange.Lv) + lvFloat]);
        basic.push(['属性', param?.Atr ?? '']);
        basic.push(['分类', category]);
        basic.push(['任务', quests.join('<br>')]);
        basic.push(['种族', rsc?.TypeFamily ?? '']);
        basic.push(['体型', String(arrange.Scale) + '%']);
      } else {
        basic.push(['等级', String(arrange.Lv) + lvFloat]);
        basic.push(['属性', param?.Atr ?? '']);
        basic.push(['分类', category]);
        basic.push(['种族', rsc?.TypeFamily ?? '']);
        basic.push(['体型', String(arrange.Scale) + '%']);
      }
      sb.push(EnemyModule.transpose(basic));
      if (arrange.IgnoreLevPow === true) {
        sb.push('<div class="card">无视等级差补正</div>');
      }
      // 六维
      sb.push(EnemyModule.rowTable(['HP', '力量', '以太力', '敏捷', '灵巧', '运气'],
        [String(hp), String(str), String(ether), String(agi), String(dex), String(luck)]));
      // 抗性
      sb.push(EnemyModule.rowTable(['物理抗性', '以太抗性', '暴击率', '格挡率'],
        [String(param?.RstPower ?? 0) + '%', String(param?.RstEther ?? 0) + '%',
          String(param?.CriticalRate ?? 0) + '%', String(param?.GuardRate ?? 0) + '%']));
      // 反应动作抗性
      sb.push(EnemyModule.rowTable(['吹飞', '击退', '破防', '倒地', '浮空', '猛击'],
        [reactions[0], reactions[1], reactions[2], reactions[3], reactions[4], reactions[5]]));
      // 被动能力
      const enhList: string[] = [];
      if (enh1.length > 0) {
        enhList.push(enh1);
      }
      if (enh2.length > 0) {
        enhList.push(enh2);
      }
      if (enh3.length > 0) {
        enhList.push(enh3);
      }
      if (enhList.length > 0) {
        sb.push(EnemyModule.singleCellTable('被动能力', enhList.join('<br>')));
      }
      // 愤怒光环卡片
      if (param !== null && param.Aura > 0) {
        const aura = await JsonDataReader.read(ctx, 'BTL_Aura/' + param.Aura) as AuraJson | null;
        if (aura !== null) {
          const auraEnh: string[] = [];
          const ae1 = await EnemyModule.loadEnhance(ctx, aura.Enhance1);
          const ae2 = await EnemyModule.loadEnhance(ctx, aura.Enhance2);
          const ae3 = await EnemyModule.loadEnhance(ctx, aura.Enhance3);
          for (const t of [ae1, ae2, ae3]) {
            if (t.length > 0) {
              auraEnh.push(t);
            }
          }
          const auraName = aura.Name !== undefined && aura.Name.length > 0 ? aura.Name : '愤怒';
          sb.push('<div class="card">');
          sb.push('<div class="title">' + auraName + '</div>');
          if (auraEnh.length > 0) {
            sb.push(EnemyModule.singleCellTable('被动能力', auraEnh.join('<br>')));
          }
          sb.push(EnemyModule.transpose([['属性变化', aura.ChangeAtr ?? '']]));
          sb.push('</div>');
        }
      }
      // 武技
      const artsRows = await EnemyModule.loadArts(ctx, param, false, torna);
      if (artsRows.length > 0) {
        sb.push('=== 武技 ===');
        sb.push(EnemyModule.artsTable(['名称', '类型', '释放对象', '判定范围', '伤害倍率', '冷却时间'], artsRows));
      }
      // 异刃必杀
      const bladeSection = await EnemyModule.buildBlade(ctx, arrange, torna);
      if (bladeSection.length > 0) {
        sb.push(bladeSection);
      }
      // 击杀奖励（掉落 + 经验金币）
      const dropSection = await EnemyModule.buildDrops(ctx, arrange, category, torna);
      if (exp > 0 || gold > 0 || wp > 0 || sp > 0) {
        dropSection.push(EnemyModule.rowTable(['EXP', 'Gold', 'WP', 'SP'],
          [String(exp), String(gold), String(wp), String(sp)]));
      }
      if (dropSection.length > 0) {
        sb.push('=== 击杀奖励 ===');
        for (const d of dropSection) {
          sb.push(d);
        }
      }
      // 出现方式 / 地图位置
      if (category === '打捞敌人' || category === '召唤敌人') {
        // Lua 无条件输出标题（打捞点/召唤反查为空时也保留空段，与原站一致）
        sb.push('=== 出现方式 ===');
        const appear = await EnemyModule.buildAppear(ctx, fullTitle);
        for (const a of appear) {
          sb.push(a);
        }
      } else {
        const mapSection = await EnemyModule.buildMapSection(ctx, id, category);
        if (mapSection.length > 0) {
          sb.push(mapSection);
        }
      }
      return sb.join('\n');
    } catch (e) {
      Logger.warn(TAG, 'renderSingle error: ' + JSON.stringify(e));
      return '';
    }
  }

  /** 装载敌人武技（BTL_Arts_En）并解析为行 */
  private static async loadArts(ctx: TemplateContext, param: EnParamJson | null,
    isBlade: boolean, torna: boolean): Promise<ArtRow[]> {
    if (param === null) {
      return [];
    }
    const artsIds: number[] = [param.ArtsNum1, param.ArtsNum2, param.ArtsNum3, param.ArtsNum4,
      param.ArtsNum5, param.ArtsNum6, param.ArtsNum7, param.ArtsNum8,
      param.ArtsNum9, param.ArtsNum10, param.ArtsNum11, param.ArtsNum12,
      param.ArtsNum13, param.ArtsNum14, param.ArtsNum15, param.ArtsNum16];
    const rows: ArtRow[] = [];
    for (const artsId of artsIds) {
      if (artsId <= 0) {
        continue;
      }
      const sub = isBlade ? 'BTL_Arts_Bl/' : 'BTL_Arts_En/';
      const arts = await JsonDataReader.read(ctx, sub + artsId) as Record<string, Object> | null;
      if (arts === null) {
        continue;
      }
      const row = await EnemyModule.parseArt(ctx, arts, artsId, isBlade, torna);
      if (row !== null) {
        rows.push(row);
      }
    }
    return rows;
  }

  /** 单条武技解析（对应 Lua parseArtsEn / parseArtsBl） */
  private static async parseArt(ctx: TemplateContext, arts: Record<string, Object>,
    artsId: number, isBlade: boolean, torna: boolean): Promise<ArtRow | null> {
    const artsType = BdatEnums.get('ArtsType', EnemyModule.num(arts['ArtsType']));
    const buffId = EnemyModule.num(arts['ArtsBuff']);
    const artsBuff = buffId > 0 ? BdatEnums.get('ArtsBuff', buffId) : '';
    let deBuff = '';
    const deBuffId = EnemyModule.num(arts['ArtsDeBuff']);
    if (deBuffId > 0) {
      const buff = await JsonDataReader.read(ctx, 'BTL_Buff/' + deBuffId) as BuffJson | null;
      deBuff = buff?.Name ?? '';
    }
    const target = BdatEnums.get('ArtsTarget', EnemyModule.num(arts['Target']));
    // 伤害倍率：敌方武技 DmgMgn / 异刃必杀 DmgMgn6；自身/减益类为 0
    let dmgBase = EnemyModule.num(arts[isBlade ? 'DmgMgn6' : 'DmgMgn']);
    if (target === '自身' || artsType === '减益效果') {
      dmgBase = 0;
    }
    const hits = EnemyModule.buildHits(arts, dmgBase);
    const resist: string[] = [];
    if (arts['SArmor1'] === true) {
      resist.push('吹飞');
      resist.push('击退');
    }
    if (arts['SArmor2'] === true) {
      resist.push('破防');
      resist.push('倒地');
      resist.push('浮空');
      resist.push('猛击');
    }
    // 召唤（仅敌方武技）
    let summonText = '';
    if (!isBlade) {
      const summonId = EnemyModule.num(arts['Summon']);
      if (summonId > 0) {
        const summon = await JsonDataReader.read(ctx, 'BTL_Summon/' + summonId) as SummonJson | null;
        if (summon !== null && summon.EnemyID !== undefined) {
          const parts: string[] = [];
          for (const sid of summon.EnemyID) {
            if (sid <= 0) {
              continue;
            }
            const sub = await JsonDataReader.read(ctx, 'CHR_EnArrange/' + sid) as EnArrangeJson | null;
            if (sub === null) {
              continue;
            }
            const ns = torna ? '黄金之国敌人' : '敌人';
            const t = ns + ':' + sub.Name;
            parts.push('[[' + t + '|' + sub.Name + ']]');
            EnemyModule.captureOne(ctx, 'SummonEnemy', t);
          }
          summonText = parts.join('<br>');
        }
      }
    }
    const enhanceId = EnemyModule.num(arts[isBlade ? 'Enhance5' : 'Enhance']);
    const enhanceText = await EnemyModule.loadEnhance(ctx, enhanceId);
    const dmgTotal = hits.dmgTotal > 0 ? String(Math.round(hits.dmgTotal * 100) / 100) : '';

    const mainCells: string[] = [];
    const detailLines: string[] = [];
    const name = EnemyModule.strOrEmpty(arts['Name']);
    mainCells.push(name);
    mainCells.push(artsType);
    mainCells.push(target);
    mainCells.push(BdatEnums.get('ArtsRangeType', EnemyModule.num(arts['RangeType'])));
    mainCells.push(dmgTotal);
    if (!isBlade) {
      mainCells.push(String(Math.round(EnemyModule.num(arts['Recast']) / 30 * 100) / 100) + '秒');
    }
    detailLines.push('攻击属性：' + EnemyModule.strOrEmpty(arts['Atr']));
    detailLines.push('使用距离：' + String(EnemyModule.num(arts['Distance'])));
    if (!isBlade) {
      detailLines.push('初始冷却：' + String(EnemyModule.num(arts['StartRecast'])) + '%');
    }
    detailLines.push('命中修正：' + String(EnemyModule.num(arts['HitRevise'])) + '%');
    detailLines.push('暴击修正：' + String(EnemyModule.num(arts['CriRevise'])) + '%');
    detailLines.push('技能使用中状态：' + artsBuff);
    detailLines.push('减益效果：' + deBuff);
    detailLines.push('特效：' + enhanceText);
    detailLines.push('技能判定：' + hits.hitText);
    if (!isBlade) {
      detailLines.push('召唤：' + summonText);
    }
    detailLines.push('反应动作无效：' + resist.join(' '));
    const row: ArtRow = { mainCells: mainCells, detailLines: detailLines, key: String(artsId) };
    return row;
  }

  /** 技能判定（HitFrm/DmgRt/ReAct 逐 hit 计算，对应 Lua 同名逻辑） */
  private static buildHits(arts: Record<string, Object>, dmgBase: number): HitResult {
    const hitFrm: number[] = [];
    let hitNum = 0;
    for (let i = 1; i <= 16; i++) {
      const f = EnemyModule.num(arts['HitFrm' + i]);
      hitFrm.push(f);
      if (f > 0) {
        hitNum++;
      }
    }
    const dmgRt: number[] = [];
    let dmgRtTotal = 0;
    for (let i = 1; i <= 16; i++) {
      let p = EnemyModule.num(arts['DmgRt' + i]);
      if (p === 255) {
        p = -1;
      }
      dmgRt.push(p);
      if (p > 0) {
        dmgRtTotal += p;
      }
    }
    const reAct: string[] = [];
    for (let i = 1; i <= 16; i++) {
      const r = EnemyModule.num(arts['ReAct' + i]);
      reAct.push(r > 0 ? BdatEnums.get('ReActType', r) : '');
    }
    const hitLines: string[] = [];
    let dmgTotal = 0;
    for (let i = 0; i < 16; i++) {
      let dmgPerHit = 0;
      if (dmgRtTotal > 0) {
        if (dmgRt[i] > 0) {
          dmgPerHit = dmgBase * dmgRt[i] / dmgRtTotal;
        }
      } else {
        if (hitFrm[i] > 0 && dmgRt[i] === 0) {
          dmgPerHit = dmgBase / hitNum;
        }
      }
      if (hitFrm[i] > 0 || dmgPerHit > 0 || reAct[i].length > 0) {
        const t = Math.round(hitFrm[i] / 30 * 100) / 100;
        const d = dmgPerHit > 0 ? String(Math.round(dmgPerHit * 100) / 100) : '';
        hitLines.push(String(t) + '秒 ' + d + (reAct[i].length > 0 ? ' ' + reAct[i] : ''));
        dmgTotal += dmgPerHit;
      }
    }
    const out: HitResult = { hitText: hitLines.join('<br>'), dmgTotal: dmgTotal };
    return out;
  }

  /** 武技表（主行 + 行级折叠明细行，对应原站 mw-customtoggle 行交互） */
  private static artsTable(headers: string[], rows: ArtRow[]): string {
    const sb: string[] = ['{| class="wikitable"', '|-'];
    sb.push('! ' + headers.join(' !! '));
    for (const r of rows) {
      sb.push('|- class="mw-customtoggle-' + r.key + '"');
      sb.push('| ' + r.mainCells.join(' || '));
      sb.push('|- class="mw-collapsible mw-collapsed" id="mw-customcollapsible-' + r.key + '"');
      sb.push('|colspan="' + headers.length + '"| ' + r.detailLines.join('<br>'));
    }
    sb.push('|}');
    return sb.join('\n');
  }

  /** 敌方携带异刃段（CHR_Bl → BTL_Arts_Bl） */
  private static async buildBlade(ctx: TemplateContext, arrange: EnArrangeJson,
    torna: boolean): Promise<string> {
    if (arrange.EnemyBladeID <= 0) {
      return '';
    }
    const bladeArrange = await JsonDataReader.read(ctx, 'CHR_EnArrange/' + arrange.EnemyBladeID) as EnArrangeJson | null;
    if (bladeArrange === null || bladeArrange.BladeID <= 0) {
      return '';
    }
    const bl = await JsonDataReader.read(ctx, 'CHR_Bl/' + bladeArrange.BladeID) as ChrBlJson | null;
    if (bl === null) {
      return '';
    }
    const artsIds: number[] = [bl.BArts1, bl.BArts2, bl.BArts3];
    const rows: ArtRow[] = [];
    for (const aid of artsIds) {
      if (aid <= 0) {
        continue;
      }
      const arts = await JsonDataReader.read(ctx, 'BTL_Arts_Bl/' + aid) as Record<string, Object> | null;
      if (arts === null) {
        continue;
      }
      const row = await EnemyModule.parseArt(ctx, arts, aid, true, torna);
      if (row !== null) {
        rows.push(row);
      }
    }
    if (rows.length === 0) {
      return '';
    }
    const sb: string[] = ['=== 异刃必杀 ==='];
    sb.push(EnemyModule.transpose([['属性', bl.Atr ?? '']]));
    sb.push(EnemyModule.artsTable(['名称', '类型', '释放对象', '判定范围', '伤害倍率'], rows));
    return sb.join('\n');
  }

  /** 击杀奖励掉落表（BTL_EnDropItem ×2 + 贵重品）+ 掉落属性捕获 */
  private static async buildDrops(ctx: TemplateContext, arrange: EnArrangeJson,
    category: string, torna: boolean): Promise<string[]> {
    const out: string[] = [];
    const showFirst = category === '剧情敌人' || category === '珍稀种';
    const headers = showFirst ? ['掉落物品', '概率', '初次'] : ['掉落物品', '概率'];
    const tableIds: number[] = [arrange.DropTableID, arrange.DropTableID3];
    for (const tid of tableIds) {
      if (tid <= 0) {
        continue;
      }
      const drop = await JsonDataReader.read(ctx, 'BTL_EnDropItem/' + tid) as Record<string, Object> | null;
      if (drop === null) {
        continue;
      }
      const sb: string[] = ['{| class="wikitable"', '|-', '! ' + headers.join(' !! '), '|-'];
      let any = false;
      for (let i = 1; i <= 8; i++) {
        const itemName = EnemyModule.strOrEmpty(drop['ItemID' + i]);
        if (itemName.length === 0) {
          continue;
        }
        // mw.title.new(name,"物品")：黄金之国页优先黄金之国物品 ns
        let fullText = '物品:' + itemName;
        if (torna && ctx.index !== null && ctx.index.pageExists('黄金之国物品:' + itemName)) {
          fullText = '黄金之国物品:' + itemName;
        }
        const prob = EnemyModule.num(drop['DropProb' + i]) / 10;
        const first = EnemyModule.num(drop['FirstNamed' + i]) === 1;
        sb.push('| [[' + fullText + '|' + itemName + ']] || ' + String(prob) + '%' +
          (showFirst ? ' || ' + (first ? '✔' : '') : ''));
        sb.push('|-');
        any = true;
        EnemyModule.captureOne(ctx, '掉落', fullText);
        EnemyModule.captureOne(ctx, fullText + '掉率',
          String(prob) + '%' + (first ? '(初次100%)' : ''));
      }
      if (any) {
        sb.push('|}');
        out.push(sb.join('\n'));
      }
    }
    // 固定贵重品掉落
    const precious = EnemyModule.strOrEmpty(arrange.PreciousID);
    if (precious.length > 0) {
      let fullText = '物品:' + precious;
      if (torna && ctx.index !== null && ctx.index.pageExists('黄金之国物品:' + precious)) {
        fullText = '黄金之国物品:' + precious;
      }
      out.push(EnemyModule.singleCellTable('贵重品', '[[' + fullText + '|' + precious + ']]'));
      EnemyModule.captureOne(ctx, '掉落', fullText);
      EnemyModule.captureOne(ctx, fullText + '掉率', '100%');
    }
    return out;
  }

  /** 出现方式（打捞/召唤敌人）：SMW 反查 */
  private static async buildAppear(ctx: TemplateContext, fullTitle: string): Promise<string[]> {
    const out: string[] = [];
    const salvage = await EnemyModule.askTitles(ctx, '[[打捞点:+]][[SalvageEnemyPop::' + fullTitle + ']]');
    if (salvage.length > 0) {
      const sb: string[] = ['{| class="wikitable"', '|-', '! 打捞点', '|-'];
      for (const s of salvage) {
        sb.push('| [[' + s + ']]');
        sb.push('|-');
      }
      sb.push('|}');
      out.push(sb.join('\n'));
    }
    const summoners = await EnemyModule.askTitles(ctx, '[[SummonEnemy::' + fullTitle + ']]');
    if (summoners.length > 0) {
      const sb: string[] = ['{| class="wikitable"', '|-', '! 召唤', '|-'];
      for (const s of summoners) {
        sb.push('| [[' + s + ']]');
        sb.push('|-');
      }
      sb.push('|}');
      out.push(sb.join('\n'));
    }
    return out;
  }

  /** 结构化 #ask（仅取结果页标题） */
  private static async askTitles(ctx: TemplateContext, cond: string): Promise<string[]> {
    if (ctx.askHandler === undefined || ctx.askHandler === null || ctx.askHandler.queryRows === undefined) {
      return [];
    }
    try {
      const rows = await ctx.askHandler.queryRows([cond], ctx);
      const out: string[] = [];
      for (const r of rows) {
        if (r.title.length > 0) {
          out.push(r.title);
        }
      }
      return out;
    } catch (e) {
      Logger.warn(TAG, 'askTitles error: ' + JSON.stringify(e));
      return [];
    }
  }

  /**
   * 捕获 SMW 语义属性（对应 Module:Enemy 的 mw.smw.set），供 #ask 查询过滤/排序。
   * 仅在 ctx.capture 存在时生效（SmwQueryEngine 提取属性时传入）。
   */
  private static async captureSmw(ctx: TemplateContext, arrange: EnArrangeJson, category: string,
    param: EnParamJson | null, rsc: RscEnJson | null, hp: number, str: number, ether: number,
    dex: number, agi: number, luck: number, exp: number, gold: number, wp: number, sp: number,
    reactions: string[]): Promise<void> {
    const capt = ctx.capture;
    if (capt === undefined || capt === null) {
      return;
    }
    const set = (prop: string, value: string): void => {
      if (value.length > 0) {
        capt(prop, value);
      }
    };
    set('ZoneID', String(arrange.ZoneID));
    set('敌人分类', category);
    if (arrange.ZoneID > 0) {
      const fl = await JsonDataReader.read(ctx, 'FLD_maplist/' + arrange.ZoneID) as Record<string, Object> | null;
      if (fl !== null && fl.nameID !== undefined) {
        set('地域', String(fl.nameID));
      }
    }
    set('等级', String(arrange.Lv));
    set('等级浮动', String(arrange.LvRand ?? 0));
    set('无视等级差补正', arrange.IgnoreLevPow ? '✔' : '✘');
    set('种族', rsc?.TypeFamily ?? '');
    set('EXP', String(exp));
    set('Gold', String(gold));
    set('WP', String(wp));
    set('SP', String(sp));
    set('HP', String(hp));
    set('力量', String(str));
    set('以太力', String(ether));
    set('灵巧', String(dex));
    set('敏捷', String(agi));
    set('运气', String(luck));
    set('物理抗性', String(param?.RstPower ?? 0) + '%');
    set('以太抗性', String(param?.RstEther ?? 0) + '%');
    set('暴击率', String(param?.CriticalRate ?? 0) + '%');
    set('格挡率', String(param?.GuardRate ?? 0) + '%');
    set('击退', reactions[0]);
    set('吹飞', reactions[1]);
    set('破防', reactions[2]);
    set('倒地', reactions[3]);
    set('浮空', reactions[4]);
    set('猛击', reactions[5]);
  }

  private static captureOne(ctx: TemplateContext, prop: string, value: string): void {
    if (ctx.capture !== undefined && ctx.capture !== null && value.length > 0) {
      ctx.capture(prop, value);
    }
  }

  /**
   * 构建地图位置段：EnemyGmkMap → Gmk/enemy 坐标 → Mapinfo 世界范围 → 百分比标记。
   * 输出 `@@WIKIMAP|底图文件名|标题|宽|高|left,top;...@@` 行，由 WikitextParser 转 Map 节点。
   * 打捞/召唤敌人无地面放置点，跳过（对应原站的"出现方式"）。
   */
  private static async buildMapSection(ctx: TemplateContext, id: number, category: string): Promise<string> {
    if (category === '打捞敌人' || category === '召唤敌人') {
      return '';
    }
    try {
      const gmkMap = await JsonDataReader.read(ctx, 'EnemyGmkMap') as Record<string, Object> | null;
      if (gmkMap === null) {
        return '';
      }
      const raw = gmkMap[String(id)];
      if (raw === undefined) {
        return '';
      }
      const names: string[] = raw as string[];
      if (names.length === 0) {
        return '';
      }
      const nameSet: Set<string> = new Set(names);
      const gmkList = await JsonDataReader.read(ctx, 'Gmk/enemy') as Object[] | null;
      if (gmkList === null) {
        return '';
      }
      // 按区域分组放置点
      const byArea: Map<string, GmkEnemyJson[]> = new Map();
      for (const o of gmkList) {
        const g = o as GmkEnemyJson;
        if (!nameSet.has(g.Name) || g.areas === undefined || g.areas.length === 0) {
          continue;
        }
        const area = g.areas[0];
        if (area.length === 0 || g.PosX === undefined || g.PosZ === undefined) {
          continue;
        }
        const arr = byArea.get(area);
        if (arr === undefined) {
          byArea.set(area, [g]);
        } else {
          arr.push(g);
        }
      }
      if (byArea.size === 0) {
        return '';
      }
      const sb: string[] = ['== 地图位置 =='];
      for (const area of byArea.keys()) {
        const info = await JsonDataReader.read(ctx, 'Mapinfo/' + area) as MapinfoJson | null;
        if (info === null || info.LowerX === undefined || info.UpperX === undefined ||
          info.LowerZ === undefined || info.UpperZ === undefined ||
          info.Width === undefined || info.Height === undefined || info.Height <= 0) {
          continue;
        }
        const spanX = info.UpperX - info.LowerX;
        const spanZ = info.UpperZ - info.LowerZ;
        if (spanX <= 0 || spanZ <= 0) {
          continue;
        }
        const marks: string[] = [];
        for (const g of byArea.get(area) as GmkEnemyJson[]) {
          // 世界坐标 → 图内百分比。原站 Xb2map.js：底图 bounds（经角点交换）lat∈[-UpperZ,-LowerZ]、
          // lng∈[-UpperX,-LowerX]，标记 latLng(-PosZ, PosX-(LowerX+UpperX))，
          // 展开得 left=(PosX-LowerX)/spanX（X 向右增）、top=(PosZ-LowerZ)/spanZ（Z 向下增）
          const leftPct = ((g.PosX as number) - info.LowerX) / spanX * 100;
          const topPct = ((g.PosZ as number) - info.LowerZ) / spanZ * 100;
          if (leftPct < -5 || leftPct > 105 || topPct < -5 || topPct > 105) {
            continue;
          }
          marks.push(Math.max(0, Math.min(100, leftPct)).toFixed(1) + ',' +
            Math.max(0, Math.min(100, topPct)).toFixed(1));
        }
        if (marks.length === 0) {
          continue;
        }
        const title = (info.mapName ?? '') + (info.menuGroup !== undefined && info.menuGroup.length > 0 &&
          info.menuGroup !== info.mapName ? '・' + info.menuGroup : '');
        sb.push('@@WIKIMAP|' + (area.charAt(0).toUpperCase() + area.substring(1) + '_map_0.png') +
          '|' + title + '|' + info.Width + '|' + info.Height +
          '|' + marks.join(';') + '@@');
      }
      if (sb.length <= 1) {
        return '';
      }
      return sb.join('\n');
    } catch (e) {
      Logger.warn(TAG, 'buildMapSection error: ' + JSON.stringify(e));
      return '';
    }
  }

  /** EnemyIdMap → 本页 id 列表（黄金之国伊拉 id∈(1427,1673)，本体在区间外） */
  private static async lookupIds(ctx: TemplateContext, name: string, torna: boolean): Promise<EnemyIdEntry[]> {
    const map = await JsonDataReader.read(ctx, 'EnemyIdMap') as Record<string, Object> | null;
    if (map === null) {
      return [];
    }
    const raw = map[name];
    if (raw === undefined) {
      return [];
    }
    const arr = raw as Array<Object>;
    if (arr.length === 0) {
      return [];
    }
    const out: EnemyIdEntry[] = [];
    for (const o of arr) {
      let id = 0;
      let title = '';
      if (typeof o === 'number') {
        id = o as number;
      } else {
        const e = o as EnemyIdEntry;
        id = e.id;
        title = e.title ?? '';
      }
      const inTorna = id > 1427 && id < 1673;
      if (inTorna === torna) {
        const entry: EnemyIdEntry = { id: id, title: title };
        out.push(entry);
      }
    }
    return out;
  }

  private static async loadEnhance(ctx: TemplateContext, id: number): Promise<string> {
    if (id <= 0) {
      return '';
    }
    const data = await JsonDataReader.read(ctx, 'BTL_Enhance/' + id) as EnhanceJson | null;
    if (data === null) {
      return '';
    }
    const text = data.CaptionText ?? '';
    // Lua：空文案渲染 Unknown 占位链接（数据缺口显式可见，不静默丢弃）
    if (text.length === 0) {
      return 'Unknown Enhance: ' + String(id);
    }
    return text;
  }

  private static num(v: Object | undefined): number {
    return typeof v === 'number' ? v as number : 0;
  }

  private static strOrEmpty(v: Object | undefined): string {
    return typeof v === 'string' ? v as string : '';
  }

  private static bitExtract(n: number, field: number): number {
    return (n >> field) & 1;
  }

  private static calcReactions(ivd: number, rst: number): string[] {
    const names = ['击退', '吹飞', '破防', '倒地', '浮空', '猛击'];
    const out: string[] = [];
    for (let i = 0; i < names.length; i++) {
      const I = EnemyModule.bitExtract(ivd, i);
      const R = EnemyModule.bitExtract(rst, i);
      if (I === 1) {
        out.push('无效');
      } else if (R === 1) {
        out.push('40%');
      } else {
        out.push('100%');
      }
    }
    return out;
  }

  /** 生成转置表格（每行：! 标签 | 值） */
  private static transpose(rows: Array<Array<string>>): string {
    const sb: string[] = ['{| class="wikitable"'];
    for (const r of rows) {
      sb.push('|-');
      sb.push('! ' + r[0]);
      sb.push('| ' + r[1]);
    }
    sb.push('|}');
    return sb.join('\n');
  }

  /** 生成单行表格（表头 + 一行数据） */
  private static rowTable(headers: string[], values: string[]): string {
    const sb: string[] = ['{| class="wikitable"', '|-'];
    sb.push('! ' + headers.join(' !! '));
    sb.push('|-');
    sb.push('| ' + values.join(' || '));
    sb.push('|}');
    return sb.join('\n');
  }

  /** 单列表格 */
  private static singleCellTable(label: string, value: string): string {
    const sb: string[] = ['{| class="wikitable"', '|-', '! ' + label, '|-' ];
    // 单元格内容可能含 <br>，保持原样
    sb.push('| ' + value);
    sb.push('|}');
    return sb.join('\n');
  }
}
