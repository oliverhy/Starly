import { common } from '@kit.AbilityKit';
import { scanBarcode } from '@kit.ScanKit';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, hdsEffect, hdsMaterial } from '@kit.UIDesignKit';
import { PairingConfig, parsePairingUri } from '../model/PairingConfig';
import pairingStore from '../service/PairingStore';
import remoteInputClient, { RemoteClientListener } from '../service/RemoteInputClient';
import speechService, { SpeechListener } from '../service/SpeechService';

enum VoiceGestureAction {
  Keep,
  Send,
  Edit
}

class PageRemoteListener implements RemoteClientListener {
  private connectionCallback: (isConnected: boolean, message: string) => void;
  private acknowledgeCallback: (message: string) => void;
  private errorCallback: (message: string) => void;

  constructor(connectionCallback: (isConnected: boolean, message: string) => void,
    acknowledgeCallback: (message: string) => void, errorCallback: (message: string) => void) {
    this.connectionCallback = connectionCallback;
    this.acknowledgeCallback = acknowledgeCallback;
    this.errorCallback = errorCallback;
  }

  onConnectionChanged(isConnected: boolean, message: string): void {
    this.connectionCallback(isConnected, message);
  }

  onAcknowledged(message: string): void {
    this.acknowledgeCallback(message);
  }

  onError(message: string): void {
    this.errorCallback(message);
  }
}

class PageSpeechListener implements SpeechListener {
  private stateCallback: (isListening: boolean, message: string) => void;
  private resultCallback: (text: string, isFinal: boolean) => void;
  private errorCallback: (message: string) => void;

  constructor(stateCallback: (isListening: boolean, message: string) => void,
    resultCallback: (text: string, isFinal: boolean) => void, errorCallback: (message: string) => void) {
    this.stateCallback = stateCallback;
    this.resultCallback = resultCallback;
    this.errorCallback = errorCallback;
  }

  onStateChanged(isListening: boolean, message: string): void {
    this.stateCallback(isListening, message);
  }

  onResult(text: string, isFinal: boolean): void {
    this.resultCallback(text, isFinal);
  }

  onError(message: string): void {
    this.errorCallback(message);
  }
}

@Entry
@Component
struct Index {
  @State host: string = '';
  @State portText: string = '8765';
  @State token: string = '';
  @State draft: string = '';
  @State isConnected: boolean = false;
  @State isPairingExpanded: boolean = true;
  @State submitMode: string = 'ctrl_enter';
  @State statusText: string = '请先与电脑配对';
  @State statusIsError: boolean = false;
  @State lastAction: string = '';
  @State isVoicePressing: boolean = false;
  @State voiceGestureAction: VoiceGestureAction = VoiceGestureAction.Keep;
  private voiceStartX: number = 0;
  private voiceStartY: number = 0;
  private voicePressSequence: number = 0;
  private pendingVoiceSend: boolean = false;
  private pageScroller: Scroller = new Scroller();
  private voiceRestEffect = new hdsEffect.HdsEffectBuilder()
    .pressShadow(hdsEffect.PressShadowType.BLEND_GRADIENT)
    .pointLight({
      sourceType: hdsEffect.PointLightSourceType.SOFT,
      illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER,
      options: { color: '#FFFFFFFF', intensity: 0.52, height: 42, bloom: 0.28 }
    })
    .buildEffect();
  private voiceActiveEffect = new hdsEffect.HdsEffectBuilder()
    .pressShadow(hdsEffect.PressShadowType.BLEND_GRADIENT)
    .pointLight({
      sourceType: hdsEffect.PointLightSourceType.BRIGHT,
      illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT,
      options: { color: '#FFFFFFFF', intensity: 0.92, height: 64, bloom: 0.68 }
    })
    .buildEffect();
  private targetLightEffect = new hdsEffect.HdsEffectBuilder()
    .pointLight({
      sourceType: hdsEffect.PointLightSourceType.BRIGHT,
      illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT,
      options: { color: '#FFFFFFFF', intensity: 0.88, height: 48, bloom: 0.72 }
    })
    .buildEffect();

  aboutToAppear(): void {
    remoteInputClient.setListener(new PageRemoteListener(
      (isConnected: boolean, message: string): void => {
        this.isConnected = isConnected;
        this.statusText = message;
        this.statusIsError = false;
        if (isConnected) {
          this.isPairingExpanded = false;
        }
      },
      (message: string): void => {
        this.lastAction = message;
        this.draft = '';
        this.statusText = '电脑已执行';
        this.statusIsError = false;
      },
      (message: string): void => {
        this.statusText = message;
        this.statusIsError = true;
      }
    ));
    speechService.setListener(new PageSpeechListener(
      (isListening: boolean, message: string): void => {
        this.statusText = message;
        this.statusIsError = false;
        if (!isListening && message === '识别完成' && this.pendingVoiceSend) {
          this.pendingVoiceSend = false;
          this.sendDraft();
        }
      },
      (text: string, isFinal: boolean): void => {
        this.draft = text;
        if (isFinal && this.pendingVoiceSend) {
          this.pendingVoiceSend = false;
          this.sendDraft();
        }
      },
      (message: string): void => {
        this.statusText = message;
        this.statusIsError = true;
      }
    ));
    this.loadPairing();
  }

  aboutToDisappear(): void {
    remoteInputClient.setListener(null);
    speechService.setListener(null);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.buildAmbientBackground();
      HdsNavigation() {
        Scroll(this.pageScroller) {
          Column({ space: 16 }) {
            this.buildStatusCard();
            if (this.isPairingExpanded) {
              this.buildPairingCard();
            }
            this.buildComposerCard();
            this.buildSafetyHint();
          }
          .width('100%')
          .padding({ left: 18, right: 18, top: 12, bottom: 36 })
        }
        .width('100%')
        .height('100%')
      }
      .titleBar({
        content: {
          title: {
            mainTitle: 'Starly',
            subTitle: '把声音送到电脑光标处'
          }
        },
        style: {
          scrollEffectOpts: {
            enableScrollEffect: true,
            scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
          },
          originalStyle: {
            backgroundStyle: {
              backgroundColor: '#00FFFFFF',
              blurRadius: 56
            }
          },
          scrollEffectStyle: {
            backgroundStyle: {
              backgroundColor: $r('app.color.glass_surface_strong'),
              blurRadius: 72
            }
          },
          thermoCtrl: true,
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
          }
        },
        enableComponentSafeArea: true
      })
      .titleMode(HdsNavigationTitleMode.FREE)
      .hideBackButton(true)
      .mode(NavigationMode.Stack)
      .bindToScrollable([this.pageScroller])
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  buildAmbientBackground() {
    Stack() {
      Column()
        .width(260)
        .height(260)
        .borderRadius(130)
        .backgroundColor('#475B8CFF')
        .blur(72)
        .position({ x: -72, y: -48 })
      Column()
        .width(230)
        .height(230)
        .borderRadius(115)
        .backgroundColor('#3DBB84FF')
        .blur(82)
        .position({ x: '68%', y: 250 })
      Column()
        .width(280)
        .height(280)
        .borderRadius(140)
        .backgroundColor('#35A36BFF')
        .blur(92)
        .position({ x: -92, y: 760 })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  buildStatusCard() {
    Row() {
      Text(this.statusIsError ? '!' : (this.isConnected ? '✓' : '•'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.statusIsError ? '#B42318' : '#175CD3')
      Column() {
        Text(this.statusText)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.statusIsError ? '#B42318' : $r('app.color.text_primary'))
        if (this.lastAction.length > 0) {
          Text(this.lastAction)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 3 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 10 })
      Blank()
      Text(this.isPairingExpanded ? '收起' : '配对')
        .fontSize(13)
        .fontColor('#175CD3')
        .onClick(() => {
          this.isPairingExpanded = !this.isPairingExpanded;
        })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.statusIsError ? '#D9FEF3F2' : $r('app.color.glass_surface'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT,
      scale: 0.88
    })
    .border({ width: 1, color: $r('app.color.glass_border') })
    .borderRadius(22)
    .shadow({ radius: 24, color: $r('app.color.glass_shadow'), offsetY: 10 })
  }

  @Builder
  buildPairingCard() {
    Column({ space: 12 }) {
      Row() {
        Text('连接电脑')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Button('扫码配对')
          .height(36)
          .fontSize(13)
          .fontColor('#175CD3')
          .backgroundColor('#EAF2FF')
          .borderRadius(18)
          .onClick(() => this.scanPairingCode())
      }
      TextInput({ text: this.host, placeholder: '电脑 IP，例如 192.168.1.20' })
        .height(48)
        .backgroundColor($r('app.color.input_background'))
        .border({ width: 1, color: $r('app.color.glass_border') })
        .borderRadius(12)
        .onChange((value: string) => {
          this.host = value;
        })
      TextInput({ text: this.portText, placeholder: '端口' })
        .height(48)
        .type(InputType.Number)
        .backgroundColor($r('app.color.input_background'))
        .border({ width: 1, color: $r('app.color.glass_border') })
        .borderRadius(12)
        .onChange((value: string) => {
          this.portText = value;
        })
      TextInput({ text: this.token, placeholder: '配对密钥' })
        .height(48)
        .type(InputType.Password)
        .backgroundColor($r('app.color.input_background'))
        .border({ width: 1, color: $r('app.color.glass_border') })
        .borderRadius(12)
        .onChange((value: string) => {
          this.token = value;
        })
      Row({ space: 10 }) {
        Button('保存并连接')
          .layoutWeight(1)
          .height(46)
          .fontColor(Color.White)
          .backgroundColor('#175CD3')
          .borderRadius(12)
          .onClick(() => this.saveAndConnect())
        Button('清除')
          .width(82)
          .height(46)
          .fontColor('#B42318')
          .backgroundColor('#FEF3F2')
          .borderRadius(12)
          .onClick(() => this.clearPairing())
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.glass_surface'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT,
      scale: 0.88
    })
    .border({ width: 1, color: $r('app.color.glass_border') })
    .borderRadius(26)
    .shadow({ radius: 28, color: $r('app.color.glass_shadow'), offsetY: 12 })
  }

  @Builder
  buildComposerCard() {
    Column({ space: 14 }) {
      Row() {
        Text('语音文字')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        if (this.draft.length > 0) {
          Text('清空')
            .fontSize(13)
            .fontColor('#B42318')
            .onClick(() => {
              this.draft = '';
            })
        }
      }
      TextArea({ text: this.draft, placeholder: '按住下方按钮说话，也可以直接输入文字' })
        .id('voiceDraftEditor')
        .height(150)
        .fontSize(17)
        .backgroundColor($r('app.color.input_background'))
        .border({ width: 1, color: $r('app.color.glass_border') })
        .borderRadius(20)
        .padding(12)
        .onChange((value: string) => {
          this.draft = value;
        })
      Column({ space: 10 }) {
        Stack({ alignContent: Alignment.Center }) {
          Button() {
            Column({ space: 2 }) {
              Text(this.voiceButtonText())
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('按住说话，松手停止识别')
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }
            .width('100%')
            .height(66)
            .padding(0)
            .backgroundColor($r('app.color.glass_surface_strong'))
            .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
              colorMode: ThemeColorMode.SYSTEM,
              adaptiveColor: AdaptiveColor.DEFAULT,
              scale: 0.82
            })
            .border({ width: 1, color: $r('app.color.glass_border') })
            .borderRadius(33)
            .visualEffect(this.isVoicePressing ? this.voiceActiveEffect : this.voiceRestEffect)
            .shadow({
              radius: this.isVoicePressing ? 34 : 24,
              color: this.voiceLightShadow(),
              offsetY: this.isVoicePressing ? 4 : 10
            })
            .zIndex(1)
            .onTouch((event: TouchEvent) => {
              this.handleVoiceTouch(event);
            })

          Row() {
            Stack({ alignContent: Alignment.Center }) {
              Text('发送')
                .width(104)
                .height(48)
                .textAlign(TextAlign.Center)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.glass_surface_strong'))
                .border({
                  width: this.voiceGestureAction === VoiceGestureAction.Send ? 2 : 1,
                  color: this.voiceGestureAction === VoiceGestureAction.Send ? '#FFFFFFFF' : $r('app.color.glass_border')
                })
                .borderRadius(24)
                .visualEffect(this.voiceGestureAction === VoiceGestureAction.Send ?
                  this.targetLightEffect : this.voiceRestEffect)
                .shadow({
                  radius: this.voiceGestureAction === VoiceGestureAction.Send ? 28 : 18,
                  color: this.voiceGestureAction === VoiceGestureAction.Send ? '#8FFFFFFF' : '#26000000',
                  offsetY: 6
                })
                .zIndex(1)
            }
              .width(104)
              .height(48)
            Blank()
            Stack({ alignContent: Alignment.Center }) {
              Text('编辑')
                .width(104)
                .height(48)
                .textAlign(TextAlign.Center)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.glass_surface_strong'))
                .border({
                  width: this.voiceGestureAction === VoiceGestureAction.Edit ? 2 : 1,
                  color: this.voiceGestureAction === VoiceGestureAction.Edit ? '#FFFFFFFF' : $r('app.color.glass_border')
                })
                .borderRadius(24)
                .visualEffect(this.voiceGestureAction === VoiceGestureAction.Edit ?
                  this.targetLightEffect : this.voiceRestEffect)
                .shadow({
                  radius: this.voiceGestureAction === VoiceGestureAction.Edit ? 28 : 18,
                  color: this.voiceGestureAction === VoiceGestureAction.Edit ? '#8FFFFFFF' : '#26000000',
                  offsetY: 6
                })
                .zIndex(1)
            }
              .width(104)
              .height(48)
          }
          .width('88%')
          .opacity(this.isVoicePressing ? 1 : 0)
          .translate({ y: this.isVoicePressing ? -70 : -48 })
          .scale({ x: this.isVoicePressing ? 1 : 0.92, y: this.isVoicePressing ? 1 : 0.92 })
          .animation({ duration: 180, curve: Curve.EaseOut })
          .hitTestBehavior(HitTestMode.None)
          .zIndex(2)
        }
        .width('100%')
        .height(66)
      }
      .width('100%')
      Tabs({
        barPosition: BarPosition.Start,
        index: this.submitMode === 'ctrl_enter' ? 0 : 1
      }) {
        TabContent() {
          Text('发送文字后使用 Ctrl + 回车')
            .width('100%')
            .height(30)
            .textAlign(TextAlign.Center)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .tabBar(this.buildSubmitModeTab(0, 'Ctrl + 回车'))

        TabContent() {
          Text('发送文字后只按一次回车')
            .width('100%')
            .height(30)
            .textAlign(TextAlign.Center)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .tabBar(this.buildSubmitModeTab(1, '回车'))
      }
      .width('100%')
      .height(82)
      .barHeight(46)
      .barMode(BarMode.Fixed)
      .scrollable(true)
      .animationDuration(180)
      .onChange((index: number) => {
        this.submitMode = index === 0 ? 'ctrl_enter' : 'enter';
      })
      .padding({ top: 4, bottom: 2, left: 6, right: 6 })
      .backgroundColor($r('app.color.input_background'))
      .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT,
        scale: 0.72
      })
      .border({ width: 1, color: $r('app.color.glass_border') })
      .borderRadius(22)
      Row({ space: 10 }) {
        Button('发送文字')
          .layoutWeight(1)
          .height(50)
          .fontSize(16)
          .fontColor(this.isConnected ? $r('app.color.accent_primary') : $r('app.color.text_secondary'))
          .backgroundColor(this.isConnected ? $r('app.color.glass_surface_strong') : '#80D0D5DD')
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
            colorMode: ThemeColorMode.SYSTEM,
            adaptiveColor: AdaptiveColor.DEFAULT,
            scale: 0.78
          })
          .border({ width: 1, color: $r('app.color.glass_border') })
          .borderRadius(13)
          .shadow({ radius: 14, color: $r('app.color.glass_shadow'), offsetY: 5 })
          .enabled(this.isConnected)
          .onClick(() => this.sendDraft())
        Button('仅按回车')
          .width(104)
          .height(50)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.glass_surface_strong'))
          .border({ width: 1, color: $r('app.color.glass_border') })
          .borderRadius(13)
          .enabled(this.isConnected)
          .onClick(() => remoteInputClient.sendEnter())
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.glass_surface'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT,
      scale: 0.92
    })
    .border({ width: 1, color: $r('app.color.glass_border') })
    .borderRadius(28)
    .shadow({ radius: 30, color: $r('app.color.glass_shadow'), offsetY: 12 })
  }

  @Builder
  buildSubmitModeTab(index: number, label: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontWeight(this.submitMode === (index === 0 ? 'ctrl_enter' : 'enter') ?
          FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.submitMode === (index === 0 ? 'ctrl_enter' : 'enter') ?
          $r('app.color.text_primary') : $r('app.color.text_secondary'))
    }
    .width('94%')
    .height(38)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.submitMode === (index === 0 ? 'ctrl_enter' : 'enter') ?
      $r('app.color.glass_surface_strong') : Color.Transparent)
    .border({
      width: 1,
      color: this.submitMode === (index === 0 ? 'ctrl_enter' : 'enter') ?
        $r('app.color.glass_border') : Color.Transparent
    })
    .borderRadius(19)
    .shadow({
      radius: this.submitMode === (index === 0 ? 'ctrl_enter' : 'enter') ? 10 : 0,
      color: $r('app.color.glass_shadow'),
      offsetY: 3
    })
  }

  @Builder
  buildSafetyHint() {
    Text('发送前请先在电脑上点中目标输入框。Starly 不会主动切换窗口，也不会读取电脑上的文字。')
      .fontSize(12)
      .lineHeight(19)
      .fontColor($r('app.color.text_secondary'))
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor($r('app.color.glass_surface'))
      .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT,
        scale: 0.7
      })
      .border({ width: 1, color: $r('app.color.glass_border') })
      .borderRadius(18)
  }

  private getContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private async loadPairing(): Promise<void> {
    try {
      const config = await pairingStore.load(this.getContext());
      this.applyConfig(config);
      if (config.isComplete()) {
        this.statusText = '正在连接电脑…';
        await remoteInputClient.connect(config);
      }
    } catch (error) {
      this.statusText = `读取配对信息失败：${JSON.stringify(error)}`;
      this.statusIsError = true;
    }
  }

  private async scanPairingCode(): Promise<void> {
    try {
      const result = await scanBarcode.startScanForResult(this.getContext());
      const config = parsePairingUri(result.originalValue);
      if (config === null) {
        this.statusText = '这不是有效的 Starly 配对二维码';
        this.statusIsError = true;
        return;
      }
      this.applyConfig(config);
      await this.saveAndConnect();
    } catch (_error) {
      this.statusText = '扫码已取消或不可用，可手动填写配对信息';
      this.statusIsError = false;
    }
  }

  private async saveAndConnect(): Promise<void> {
    const config = this.readConfigFromForm();
    if (!config.isComplete()) {
      this.statusText = '请填写有效的电脑地址、端口和配对密钥';
      this.statusIsError = true;
      return;
    }
    try {
      await pairingStore.save(this.getContext(), config);
    } catch (error) {
      this.statusText = `${error}`;
      this.statusIsError = true;
      return;
    }
    this.statusText = '正在连接电脑…';
    this.statusIsError = false;
    await remoteInputClient.connect(config);
  }

  private async clearPairing(): Promise<void> {
    await remoteInputClient.disconnect();
    try {
      await pairingStore.clear(this.getContext());
    } catch (error) {
      this.statusText = `${error}`;
      this.statusIsError = true;
      return;
    }
    this.host = '';
    this.portText = '8765';
    this.token = '';
    this.isConnected = false;
    this.statusText = '配对信息已清除';
    this.statusIsError = false;
  }

  private handleVoiceTouch(event: TouchEvent): void {
    if (event.changedTouches.length === 0) {
      return;
    }
    const point = event.changedTouches[0];
    if (event.type === TouchType.Down) {
      this.voiceStartX = point.x;
      this.voiceStartY = point.y;
      this.voiceGestureAction = VoiceGestureAction.Keep;
      this.isVoicePressing = true;
      this.pendingVoiceSend = false;
      this.draft = '';
      this.voicePressSequence += 1;
      this.beginVoiceHold(this.voicePressSequence);
      return;
    }
    if (event.type === TouchType.Move && this.isVoicePressing) {
      const deltaX = point.x - this.voiceStartX;
      const deltaY = point.y - this.voiceStartY;
      if (deltaY < -36 && deltaX < -28) {
        this.voiceGestureAction = VoiceGestureAction.Send;
      } else if (deltaY < -36 && deltaX > 28) {
        this.voiceGestureAction = VoiceGestureAction.Edit;
      } else {
        this.voiceGestureAction = VoiceGestureAction.Keep;
      }
      return;
    }
    if ((event.type === TouchType.Up || event.type === TouchType.Cancel) && this.isVoicePressing) {
      const action = event.type === TouchType.Cancel ? VoiceGestureAction.Keep : this.voiceGestureAction;
      this.finishVoiceHold(action);
    }
  }

  private async beginVoiceHold(sequence: number): Promise<void> {
    const started = await speechService.start();
    if (!started) {
      this.isVoicePressing = false;
      return;
    }
    if (!this.isVoicePressing || sequence !== this.voicePressSequence) {
      await speechService.stop();
    }
  }

  private async finishVoiceHold(action: VoiceGestureAction): Promise<void> {
    this.isVoicePressing = false;
    this.voiceGestureAction = VoiceGestureAction.Keep;
    this.pendingVoiceSend = action === VoiceGestureAction.Send;
    if (action === VoiceGestureAction.Send) {
      this.statusText = '正在整理并发送语音…';
    } else if (action === VoiceGestureAction.Edit) {
      this.statusText = '正在整理识别文字…';
    } else {
      this.statusText = '正在整理识别结果…';
    }
    await speechService.stop();
    if (action === VoiceGestureAction.Edit) {
      try {
        this.getUIContext().getFocusController().requestFocus('voiceDraftEditor');
      } catch (_error) {
      }
    }
  }

  private voiceButtonText(): string {
    if (!this.isVoicePressing) {
      return '按住说话';
    }
    if (this.voiceGestureAction === VoiceGestureAction.Send) {
      return '松手发送';
    }
    if (this.voiceGestureAction === VoiceGestureAction.Edit) {
      return '松手编辑';
    }
    return '松手停止识别';
  }

  private voiceLightShadow(): ResourceColor {
    return this.isVoicePressing ? '#A6FFFFFF' : '#2E000000';
  }

  private async sendDraft(): Promise<void> {
    const sent = await remoteInputClient.sendText(this.draft, this.submitMode);
    if (sent) {
      this.statusText = '已发送，等待电脑确认…';
      this.statusIsError = false;
    }
  }

  private readConfigFromForm(): PairingConfig {
    const config = new PairingConfig();
    config.host = this.host.trim();
    config.port = Number(this.portText);
    config.token = this.token;
    return config;
  }

  private applyConfig(config: PairingConfig): void {
    this.host = config.host;
    this.portText = config.port.toString();
    this.token = config.token;
  }
}
