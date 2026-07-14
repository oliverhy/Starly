import { AbilityConstant, ConfigurationConstant, UIAbility, Want, abilityAccessCtrl } from '@kit.AbilityKit';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import pairingStore from '../service/PairingStore';
import speechService from '../service/SpeechService';
import remoteInputClient from '../service/RemoteInputClient';

type AppPermission = 'ohos.permission.MICROPHONE';

export default class EntryAbility extends UIAbility {
  private hasEnteredForeground: boolean = false;
  private isRestoringConnection: boolean = false;

  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (_error) {
    }
    this.requestMicrophonePermission();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', () => {
      try {
        windowStage.getMainWindowSync().getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
      } catch (_error) {
      }
    });
  }

  onForeground(): void {
    if (!this.hasEnteredForeground) {
      this.hasEnteredForeground = true;
      return;
    }
    this.restoreRemoteConnection();
  }

  onDestroy(): void {
    speechService.release();
    remoteInputClient.disconnect();
  }

  private async restoreRemoteConnection(): Promise<void> {
    if (this.isRestoringConnection) {
      return;
    }
    this.isRestoringConnection = true;
    try {
      const config = await pairingStore.load(this.context);
      if (config.isComplete()) {
        await remoteInputClient.connect(config);
      }
    } catch (_error) {
    } finally {
      this.isRestoringConnection = false;
    }
  }

  private async requestMicrophonePermission(): Promise<void> {
    const permission: AppPermission = 'ohos.permission.MICROPHONE';
    try {
      await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.context, [permission]);
    } catch (_error) {
    }
  }
}
