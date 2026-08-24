import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/**
 * 轻量持久化：保存用户选择的文件夹 URI 等。
 */
export class Prefs {
  private static prefs: preferences.Preferences | null = null;
  private static readonly STORE = 'ohmywiki';
  static readonly KEY_FOLDER_URI = 'folderUri';

  static async init(context: common.UIAbilityContext): Promise<void> {
    if (Prefs.prefs !== null) {
      return;
    }
    Prefs.prefs = await preferences.getPreferences(context, Prefs.STORE);
  }

  static getString(key: string): string {
    if (Prefs.prefs === null) {
      return '';
    }
    const v = Prefs.prefs.getSync(key, '') as string;
    return v;
  }

  static async putString(key: string, value: string): Promise<void> {
    if (Prefs.prefs === null) {
      return;
    }
    await Prefs.prefs.put(key, value);
    await Prefs.prefs.flush();
  }
}
