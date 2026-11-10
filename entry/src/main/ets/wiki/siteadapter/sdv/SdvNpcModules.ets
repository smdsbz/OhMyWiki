import { TemplateContext } from '../../template/TemplateEngine';
import { SdvArgs } from './SdvArgs';

/** 中英人名映射（Module:NPC 静态表，52 人） */
const CHARACTERS: string[][] = [
  ['亚历克斯', 'Alex'], ['艾利欧特', 'Elliott'], ['哈维', 'Harvey'], ['山姆', 'Sam'],
  ['塞巴斯蒂安', 'Sebastian'], ['谢恩', 'Shane'], ['阿比盖尔', 'Abigail'],
  ['艾米丽', 'Emily'], ['海莉', 'Haley'], ['莉亚', 'Leah'], ['玛鲁', 'Maru'],
  ['潘妮', 'Penny'], ['卡洛琳', 'Caroline'], ['克林特', 'Clint'],
  ['德米特里厄斯', 'Demetrius'], ['矮人', 'Dwarf'], ['艾芙琳', 'Evelyn'],
  ['乔治', 'George'], ['格斯', 'Gus'], ['贾斯', 'Jas'], ['乔迪', 'Jodi'],
  ['肯特', 'Kent'], ['科罗布斯', 'Krobus'], ['刘易斯', 'Lewis'], ['莱纳斯', 'Linus'],
  ['玛妮', 'Marnie'], ['潘姆', 'Pam'], ['皮埃尔', 'Pierre'], ['罗宾', 'Robin'],
  ['桑迪', 'Sandy'], ['文森特', 'Vincent'], ['威利', 'Willy'], ['法师', 'Wizard'],
  ['吉尔', 'Gil'], ['冈瑟', 'Gunther'], ['仆从', 'Henchman'], ['马龙', 'Marlon'],
  ['莫里斯', 'Morris'], ['齐先生', 'Mr. Qi'], ['雷欧', 'Leo'], ['贝啼', 'Birdie'],
  ['蜗牛教授', 'Professor Snail'], ['姜岛商人', 'Island Trader'],
  ['沙漠商人', 'Desert Trader'], ['女巫', 'Witch'], ['州长', 'Governor'],
  ['门卫', 'Bouncer'], ['菲兹', 'Fizz'], ['老水手', 'Mariner'], ['爷爷', 'Grandpa'],
];

const ZH_TO_EN: Map<string, string> = new Map(CHARACTERS.map((p: string[]): [string, string] => [p[0], p[1]]));
const EN_TO_ZH: Map<string, string> = new Map(CHARACTERS.map((p: string[]): [string, string] => [p[1], p[0]]));

/** {{#invoke:NPC|getEnglishName/getChineseName}}：人名中英互转 */
export class NpcModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const name = SdvArgs.pos(args, 0).trim();
    const f = func.toLowerCase();
    if (f === 'getenglishname') {
      return ZH_TO_EN.get(name) ?? name;
    }
    if (f === 'getchinesename') {
      return EN_TO_ZH.get(name) ?? name;
    }
    return '';
  }
}

const FEMALE = new Set(['Abigail', '阿比盖尔', 'Emily', '艾米丽', 'Haley', '海莉', 'Leah', '莉亚',
  'Maru', '玛鲁', 'Penny', '潘妮', 'Caroline', '卡洛琳', 'Evelyn', '艾芙琳', 'Jas', '贾斯',
  'Jodi', '乔迪', 'Marnie', '玛妮', 'Pam', '潘姆', 'Robin', '罗宾', 'Sandy', '桑迪']);
const MALE = new Set(['Alex', '亚历克斯', 'Elliott', '艾利欧特', 'Harvey', '哈维', 'Leo', '雷欧',
  'Sam', '山姆', 'Sebastian', '塞巴斯蒂安', 'Shane', '谢恩', 'Clint', '克林特',
  'Demetrius', '德米特里厄斯', 'George', '乔治', 'Gus', '格斯', 'Kent', '肯特',
  'Krobus', '科罗布斯', 'Lewis', '刘易斯', 'Linus', '莱纳斯', 'Pierre', '皮埃尔',
  'Vincent', '文森特', 'Willy', '威利', 'Wizard', '法师', 'Dwarf', '矮人']);
const RUDE = new Set(['Abigail', '阿比盖尔', 'Alex', '亚历克斯', 'Clint', '克林特',
  'George', '乔治', 'Haley', '海莉', 'Pam', '潘姆', 'Sebastian', '塞巴斯蒂安',
  'Shane', '谢恩', 'Wizard', '法师']);
/** 季节出生人名单 */
interface SeasonSet {
  season: string;
  names: string[];
}

/** 生日（日号 → 人名单） */
interface BirthdaySet {
  day: string;
  names: string[];
}

const SEASON_SETS: SeasonSet[] = [
  { season: 'spring', names: ['Kent', '肯特', 'Lewis', '刘易斯', 'Vincent', '文森特',
    'Haley', '海莉', 'Pam', '潘姆', 'Shane', '谢恩', 'Pierre', '皮埃尔', 'Emily', '艾米丽'] },
  { season: 'summer', names: ['Leo', '雷欧', 'Jas', '贾斯', 'Gus', '格斯', 'Maru', '玛鲁',
    'Alex', '亚历克斯', 'Sam', '山姆', 'Demetrius', '德米特里厄斯', 'Dwarf', '矮人',
    'Willy', '威利'] },
  { season: 'fall', names: ['Penny', '潘妮', 'Elliott', '艾利欧特', 'Jodi', '乔迪',
    'Abigail', '阿比盖尔', 'Sandy', '桑迪', 'Marnie', '玛妮', 'Robin', '罗宾',
    'George', '乔治'] },
  { season: 'winter', names: ['Krobus', '科罗布斯', 'Linus', '莱纳斯', 'Caroline', '卡洛琳',
    'Sebastian', '塞巴斯蒂安', 'Harvey', '哈维', 'Wizard', '法师', 'Evelyn', '艾芙琳',
    'Leah', '莉亚', 'Clint', '克林特'] },
];

const BIRTHDAY: BirthdaySet[] = [
  { day: '1', names: ['Krobus', '科罗布斯'] },
  { day: '2', names: ['Penny', '潘妮'] },
  { day: '3', names: ['Linus', '莱纳斯'] },
  { day: '4', names: ['Kent', '肯特', 'Jas', '贾斯'] },
  { day: '5', names: ['Elliott', '艾利欧特'] },
  { day: '7', names: ['Lewis', '刘易斯', 'Caroline', '卡洛琳'] },
  { day: '8', names: ['Gus', '格斯'] },
  { day: '10', names: ['Vincent', '文森特', 'Maru', '玛鲁', 'Sebastian', '塞巴斯蒂安'] },
  { day: '11', names: ['Jodi', '乔迪'] },
  { day: '13', names: ['Abigail', '阿比盖尔', 'Alex', '亚历克斯'] },
  { day: '14', names: ['Haley', '海莉', 'Harvey', '哈维'] },
  { day: '15', names: ['Sandy', '桑迪'] },
  { day: '17', names: ['Sam', '山姆', 'Wizard', '法师'] },
  { day: '18', names: ['Marnie', '玛妮', 'Pam', '潘姆'] },
  { day: '19', names: ['Demetrius', '德米特里厄斯'] },
  { day: '20', names: ['Evelyn', '艾芙琳', 'Shane', '谢恩'] },
  { day: '21', names: ['Robin', '罗宾'] },
  { day: '22', names: ['Dwarf', '矮人'] },
  { day: '23', names: ['Leah', '莉亚'] },
  { day: '24', names: ['George', '乔治', 'Willy', '威利'] },
  { day: '26', names: ['Pierre', '皮埃尔', 'Clint', '克林特', 'Leo', '雷欧'] },
  { day: '27', names: ['Emily', '艾米丽'] },
];

/** {{#invoke:NPCDispositions|getgender/getdisposition/getbirthseason/getbirthday}} */
export class NpcDispositionsModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    const npc = SdvArgs.pos(args, 0).trim();
    const f = func.toLowerCase();
    if (f === 'getgender') {
      if (FEMALE.has(npc)) {
        return 'female';
      }
      if (MALE.has(npc)) {
        return 'male';
      }
      return 'undefined';
    }
    if (f === 'getdisposition') {
      return RUDE.has(npc) ? 'rude' : 'polite';
    }
    if (f === 'getbirthseason') {
      for (const set of SEASON_SETS) {
        if (set.names.indexOf(npc) >= 0) {
          return set.season;
        }
      }
      return '';
    }
    if (f === 'getbirthday') {
      for (const set of BIRTHDAY) {
        if (set.names.indexOf(npc) >= 0) {
          return set.day;
        }
      }
      return '';
    }
    return '';
  }
}
