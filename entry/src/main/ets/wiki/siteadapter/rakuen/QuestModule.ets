import { TemplateContext } from '../../template/TemplateEngine';

/**
 * 模块:Quest 的 ArkTS 移植（原 Lua 见 rakuen-database pages/模块/Quest.wiki）。
 * questRewardRow(物品名, 数量?) → 任务报酬物品链接行；
 * 多行输出的换行按 SalvageModule 先例用 <br>（表格单元格内联渲染，div 块级标签会被丢弃）。
 */
export class QuestModule {
  static async invoke(func: string, args: string[], ctx: TemplateContext): Promise<string> {
    if (func === 'questRewardRow') {
      return QuestModule.questRewardRow(args, ctx);
    }
    return '';
  }

  private static questRewardRow(args: string[], ctx: TemplateContext): string {
    const itemName = (args[0] ?? '').trim();
    const itemNum = (args[1] ?? '').trim();
    if (itemName.length === 0) {
      return '';
    }
    const numString = itemNum.length > 0 ? ' ×' + itemNum : '';
    // mw.title.new(itemName, "物品").exists：存在则链到物品命名空间，否则主命名空间
    let target = itemName;
    if (ctx.index !== null && ctx.index.pageExists('物品:' + itemName)) {
      target = '物品:' + itemName;
    }
    // 模块输出不会流经 TemplateEngine 的 [[属性::目标]] 转换（那是主展开循环的事），
    //  属性捕获与普通链接须在此自理（同 TboxModule.capture 先例）——
    //  物品页「获得方式」的 [[任务报酬物品::X]] 查询依赖此捕获
    if (ctx.capture !== undefined && ctx.capture !== null) {
      ctx.capture('任务报酬物品', target);
    }
    return '[[' + target + '|' + itemName + ']]' + numString + '<br>';
  }
}
