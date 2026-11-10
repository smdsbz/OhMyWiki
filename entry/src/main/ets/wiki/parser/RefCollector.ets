import { WikiNode, RefEntry } from '../../model/WikiTypes';

/**
 * Cite 脚注收集器（单页生命周期，随 WikitextParser 实例创建）。
 * 顺序无关两段式：RefMark 节点只存 name/seq，编号显示在渲染期由条目终态决定——
 * `<references>` 可出现在任意 `<ref>` 之前。
 */
export class RefCollector {
  entries: RefEntry[] = [];
  byName: Map<string, RefEntry> = new Map();

  /**
   * 登记脚注。
   * @param name ref name 属性（可空）
   * @param rawText ref 标签内原始内容（空 = 自闭合复用，如 <ref name=x/>）
   * @param parseInline 内容解析回调
   * @returns 该脚注的登记条目（自闭合且从未定义过时返回 null）
   */
  register(name: string | null, rawText: string,
    parseInline: (text: string) => WikiNode[]): RefEntry | null {
    if (name !== null && name.length > 0) {
      const existing = this.byName.get(name);
      if (existing !== undefined) {
        if (rawText.trim().length > 0 && existing.inline.length === 0) {
          existing.inline = parseInline(rawText);
        }
        return existing;
      }
    }
    const entry: RefEntry = {
      name: name !== null && name.length > 0 ? name : null,
      inline: rawText.trim().length > 0 ? parseInline(rawText) : [],
      seq: this.entries.length + 1,
    };
    this.entries.push(entry);
    if (entry.name !== null) {
      this.byName.set(entry.name, entry);
    }
    return entry;
  }
}
