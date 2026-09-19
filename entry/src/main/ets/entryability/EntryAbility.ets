import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // 调试直达：aa start --ps pageB64 <base64(UTF-8 页名)> [--ps siteB64 <base64(站点名)>]，站点加载后 Index 自动跳转
    try {
      const p = want.parameters;
      if (p !== undefined && p !== null) {
        const helper = new util.Base64Helper();
        const decoder = new util.TextDecoder('utf-8');
        const b64 = p.pageB64;
        if (typeof b64 === 'string' && b64.length > 0) {
          const text = decoder.decodeWithStream(helper.decodeSync(b64));
          if (text.trim().length > 0) {
            AppStorage.setOrCreate('debugJumpPage', text.trim());
            hilog.info(DOMAIN, 'testTag', 'debugJumpPage=%{public}s', text);
          }
        }
        const site = p.siteB64;
        if (typeof site === 'string' && site.length > 0) {
          const siteName = decoder.decodeWithStream(helper.decodeSync(site));
          if (siteName.trim().length > 0) {
            AppStorage.setOrCreate('debugJumpSite', siteName.trim());
          }
        }
      }
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'debugJump parse failed: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    this.windowStage = windowStage;
    // 页面构建前写入深浅色标记，避免深色模式首帧用浅色适配（源数据颜色换算用）
    this.syncDarkFlag();

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      this.syncWindowBg();
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  private windowStage: window.WindowStage | null = null;

  /** 窗口底色与页面背景（comp_background_gray）同步：状态栏区域显同色，无接缝 */
  private syncWindowBg(cfg?: Configuration): void {
    const dark = this.syncDarkFlag(cfg);
    if (this.windowStage === null) {
      return;
    }
    try {
      this.windowStage.getMainWindowSync().setWindowBackgroundColor(dark ? '#000000' : '#F0F3F5');
    } catch (err) {
      hilog.warn(DOMAIN, 'testTag', 'setWindowBackgroundColor failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 系统深浅色 → AppStorage（源数据颜色按模式换算的渲染依赖）。
   *  onConfigurationUpdate 时 this.context.config 仍是旧快照，必须用入参 newConfig */
  private syncDarkFlag(cfg?: Configuration): boolean {
    try {
      const config = cfg ?? this.context.config;
      const dark = config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      AppStorage.setOrCreate('isDark', dark);
      return dark;
    } catch (err) {
      hilog.warn(DOMAIN, 'testTag', 'syncDarkFlag failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 深浅色切换时重新同步窗口底色
    this.syncWindowBg(newConfig);
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}