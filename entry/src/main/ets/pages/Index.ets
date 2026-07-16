import { common } from '@kit.AbilityKit';
import { scanBarcode } from '@kit.ScanKit';
import { hdsEffect } from '@kit.UIDesignKit';
import { PairingConfig, parsePairingUri } from '../model/PairingConfig';
import {
  CodexMessage, CodexQuota, CodexSnapshot, CodexTask, CodexThreadDetail,
  isCodexTerminalStatus, normalizeCodexDetailStatus, resolveCodexDisplayStatus
} from '../model/CodexModels';
import pairingStore from '../service/PairingStore';
import remoteInputClient, { RemoteClientListener } from '../service/RemoteInputClient';
import speechService, { SpeechListener } from '../service/SpeechService';
import imageTransferService from '../service/ImageTransferService';

enum VoiceGestureAction {
  Keep,
  Send,
  Edit
}

class PageRemoteListener implements RemoteClientListener {
  private connectionCallback: (isConnected: boolean, message: string) => void;
  private acknowledgeCallback: (message: string) => void;
  private errorCallback: (message: string) => void;
  private snapshotCallback: (snapshot: CodexSnapshot) => void;
  private threadCallback: (detail: CodexThreadDetail) => void;
  private eventCallback: (event: string, threadId: string) => void;

  constructor(connectionCallback: (isConnected: boolean, message: string) => void,
    acknowledgeCallback: (message: string) => void, errorCallback: (message: string) => void,
    snapshotCallback: (snapshot: CodexSnapshot) => void,
    threadCallback: (detail: CodexThreadDetail) => void,
    eventCallback: (event: string, threadId: string) => void) {
    this.connectionCallback = connectionCallback;
    this.acknowledgeCallback = acknowledgeCallback;
    this.errorCallback = errorCallback;
    this.snapshotCallback = snapshotCallback;
    this.threadCallback = threadCallback;
    this.eventCallback = eventCallback;
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

  onCodexSnapshot(snapshot: CodexSnapshot): void {
    this.snapshotCallback(snapshot);
  }

  onCodexThread(detail: CodexThreadDetail): void {
    this.threadCallback(detail);
  }

  onCodexEvent(event: string, threadId: string): void {
    this.eventCallback(event, threadId);
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
  @State isPairingExpanded: boolean = false;
  @State isPairingOverlayMounted: boolean = false;
  @State pairingPanelOffsetX: number = 0;
  @State pairingPanelOffsetY: number = 0;
  @State pairingPanelHeight: number = 320;
  @State submitMode: string = 'ctrl_enter';
  @State statusText: string = '请先与电脑配对';
  @State statusIsError: boolean = false;
  @State lastAction: string = '';
  @State isVoicePressing: boolean = false;
  @State mainSection: string = 'voice';
  @State mainSectionDragOffset: number = 0;
  @State mainSectionViewportWidth: number = 360;
  @State mainSectionTabsViewportWidth: number = 360;
  @State layoutViewportWidth: number = 360;
  @State layoutViewportHeight: number = 720;
  @State codexAvailable: boolean = false;
  @State codexError: string = '';
  @State codexQuota: CodexQuota = new CodexQuota();
  @State codexTasks: CodexTask[] = [];
  @State areCodexTasksExpanded: boolean = true;
  @State codexTaskDisplayLimit: number = 10;
  @State selectedCodexTaskId: string = '';
  @State selectedCodexTitle: string = '';
  @State selectedCodexCwd: string = '';
  @State selectedCodexStatus: string = 'notLoaded';
  @State selectedCodexActiveTurnId: string = '';
  @State selectedCodexMessages: CodexMessage[] = [];
  @State pendingCodexThreadId: string = '';
  @State isCodexConversationOpen: boolean = false;
  @State codexConversationLimit: number = 5;
  @State codexDetailVersion: number = 0;
  @State codexDetailLoading: boolean = false;
  @State codexHistoryHasMore: boolean = false;
  @State codexHistoryLoadingOlder: boolean = false;
  @State codexHistoryReady: boolean = false;
  @State codexChatPinnedToBottom: boolean = true;
  @State codexUnreadMessages: number = 0;
  @State codexCommand: string = '';
  @State codexImagePreviewUri: string = '';
  @State codexImageDataUrl: string = '';
  @State codexImageMimeType: string = '';
  @State codexImagePicking: boolean = false;
  @State codexLoading: boolean = false;
  @State voiceGestureAction: VoiceGestureAction = VoiceGestureAction.Keep;
  private voiceStartX: number = 0;
  private voiceStartY: number = 0;
  private voicePressSequence: number = 0;
  private pendingVoiceSend: boolean = false;
  private lastCodexTaskTapId: string = '';
  private lastCodexTaskTapAt: number = 0;
  private codexAutoRefreshTimer: number = -1;
  private codexAutoRefreshInFlight: boolean = false;
  private codexDetailRetryTimer: number = -1;
  private codexDetailWatchdogTimer: number = -1;
  private codexDetailRetryCount: number = 0;
  private codexDetailRequestToken: number = 0;
  private selectedCodexUpdatedAt: number = 0;
  private codexResolvedStatuses: Map<string, string> = new Map<string, string>();
  private voicePageScroller: Scroller = new Scroller();
  private codexPageScroller: Scroller = new Scroller();
  private codexChatScroller: Scroller = new Scroller();
  private codexChatScrollTimer: number = -1;
  private mainSectionAnimating: boolean = false;
  private pairingOverlayShowTimer: number = -1;
  private pairingPanelDragStartX: number = 0;
  private pairingPanelDragStartY: number = 0;
  private submitTabsController: TabsController = new TabsController();
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
          this.closePairingPanel();
        } else {
          this.stopCodexAutoRefresh();
          this.clearCodexDetailTimers();
        }
      },
      (message: string): void => {
        this.lastAction = message;
        if (message.startsWith('消息已发送给 Codex')) {
          this.updateLatestPendingCodexMessage('sent');
          this.codexCommand = '';
          this.codexImagePreviewUri = '';
          this.codexImageDataUrl = '';
          this.codexImageMimeType = '';
          const acknowledgedThreadId = this.pendingCodexThreadId.length > 0 ?
            this.pendingCodexThreadId : this.selectedCodexTaskId;
          this.pendingCodexThreadId = acknowledgedThreadId;
          this.rememberCodexTaskStatus(acknowledgedThreadId, 'active');
          if (acknowledgedThreadId === this.selectedCodexTaskId) {
            this.selectedCodexStatus = 'active';
          }
        } else {
          this.draft = '';
        }
        this.statusText = '电脑已执行';
        this.statusIsError = false;
      },
      (message: string): void => {
        const shouldRetryCodexDetail = this.codexDetailLoading &&
          this.selectedCodexTaskId.length > 0 && this.mainSection === 'codex';
        this.statusText = message;
        this.statusIsError = true;
        if (message.includes('Codex')) {
          this.pendingCodexThreadId = '';
          this.updateLatestPendingCodexMessage('failed');
        }
        this.codexHistoryLoadingOlder = false;
        this.codexDetailLoading = false;
        this.codexLoading = false;
        if (shouldRetryCodexDetail) {
          this.scheduleCodexDetailRetry(this.selectedCodexTaskId, 450);
        }
      },
      (snapshot: CodexSnapshot): void => {
        this.codexAvailable = snapshot.available;
        this.codexError = snapshot.error;
        if (!this.sameCodexQuota(this.codexQuota, snapshot.quota)) {
          this.codexQuota = snapshot.quota;
        }
        const mergedTasks = this.mergeCodexTaskStatuses(snapshot.threads);
        if (!this.sameCodexTasks(this.codexTasks, mergedTasks)) {
          this.codexTasks = mergedTasks;
        }
        for (let index = 0; index < mergedTasks.length; index += 1) {
          const task = mergedTasks[index];
          this.clearFinishedCodexActivity(task.id, task.status);
          if (task.id === this.selectedCodexTaskId) {
            const contentChanged = this.selectedCodexUpdatedAt > 0 &&
              task.updatedAt > this.selectedCodexUpdatedAt;
            this.selectedCodexUpdatedAt = task.updatedAt;
            this.selectedCodexStatus = this.resolvedCodexStatus(task.id, task.status);
            if (contentChanged && !this.isCodexConversationOpen) {
              this.requestSelectedCodexThread();
            }
            break;
          }
        }
        this.codexLoading = false;
        if (this.selectedCodexTaskId.length === 0 && snapshot.threads.length > 0) {
          this.selectCodexTask(snapshot.threads[0].id);
        }
      },
      (detail: CodexThreadDetail): void => {
        this.applyCodexThreadDetail(detail);
      },
      (event: string, threadId: string): void => {
        let shouldRefreshSnapshot = false;
        let shouldRefreshThread = false;
        if (event === 'desktop/opened' && threadId === this.selectedCodexTaskId) {
          this.statusText = '任务已完成，电脑端已打开';
          this.statusIsError = false;
        } else if (event === 'desktop/openFailed' && threadId === this.selectedCodexTaskId) {
          this.statusText = '任务已完成，但电脑端未能自动打开';
          this.statusIsError = true;
        } else if (event === 'turn/started' && threadId.length > 0) {
          this.pendingCodexThreadId = threadId;
          this.rememberCodexTaskStatus(threadId, 'active');
          if (threadId === this.selectedCodexTaskId) {
            this.selectedCodexStatus = 'active';
          }
          shouldRefreshSnapshot = true;
          shouldRefreshThread = true;
        } else if (event === 'turn/completed' && threadId.length > 0) {
          if (threadId === this.pendingCodexThreadId) {
            this.pendingCodexThreadId = '';
          }
          this.rememberCodexTaskStatus(threadId, 'idle');
          if (threadId === this.selectedCodexTaskId) {
            this.selectedCodexStatus = 'idle';
          }
          // Refresh the list immediately. The auto-refresh timer below also
          // reads the selected thread again after the desktop has persisted
          // the final assistant message.
          shouldRefreshSnapshot = true;
        } else if (event === 'turn/failed' && threadId.length > 0) {
          this.rememberCodexTaskStatus(threadId, 'systemError');
          if (threadId === this.selectedCodexTaskId) {
            this.selectedCodexStatus = 'systemError';
          }
          shouldRefreshSnapshot = true;
        } else if (event === 'codex/refreshReady') {
          shouldRefreshThread = true;
        } else if (event === 'thread/status/changed' ||
          event === 'account/rateLimits/updated') {
          shouldRefreshSnapshot = true;
        }
        if (shouldRefreshSnapshot) {
          remoteInputClient.requestCodexSnapshot();
        }
        if (shouldRefreshThread && this.selectedCodexTaskId.length > 0) {
          this.requestSelectedCodexThread();
        }
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
    this.stopCodexAutoRefresh();
    if (this.pairingOverlayShowTimer >= 0) {
      clearTimeout(this.pairingOverlayShowTimer);
      this.pairingOverlayShowTimer = -1;
    }
    if (this.codexChatScrollTimer >= 0) {
      clearTimeout(this.codexChatScrollTimer);
      this.codexChatScrollTimer = -1;
    }
    remoteInputClient.setListener(null);
    speechService.setListener(null);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.buildAmbientBackground();
      Row() {
        Column() {
          Stack({ alignContent: Alignment.TopStart }) {
            this.buildMainSectionPage('codex', this.codexPageScroller);
            this.buildMainSectionPage('voice', this.voicePageScroller);
            Column({ space: 12 }) {
              this.buildFixedHeader();
              this.buildMainSectionTabs();
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 8, bottom: 12 })
            .zIndex(10)
          }
          .width('100%')
          .height('100%')
          .clip(true)
          .onAreaChange((_oldArea: Area, newArea: Area) => {
            const width = Number(newArea.width);
            if (width > 0 && Math.abs(width - this.mainSectionViewportWidth) > 0.5) {
              this.mainSectionViewportWidth = width;
            }
          })
          .parallelGesture(
            PanGesture({ direction: PanDirection.Horizontal, distance: 10 })
              .onActionStart(() => {
                this.beginMainSectionSwipe();
              })
              .onActionUpdate((event: GestureEvent) => {
                this.updateMainSectionSwipe(event.offsetX);
              })
              .onActionEnd((event: GestureEvent) => {
                this.finishMainSectionSwipe(event.offsetX);
              })
              .onActionCancel(() => {
                this.cancelMainSectionSwipe();
              })
          )
        }
        .width(this.mainShellWidth())
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      if (this.isPairingOverlayMounted) {
        this.buildPairingOverlay();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.useTwoPaneCodexLayout() ?
      $r('app.color.wide_page_background') : $r('app.color.page_background'))
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const width = Number(newArea.width);
      const height = Number(newArea.height);
      if (width > 0 && Math.abs(width - this.layoutViewportWidth) > 0.5) {
        this.layoutViewportWidth = width;
      }
      if (height > 0 && Math.abs(height - this.layoutViewportHeight) > 0.5) {
        this.layoutViewportHeight = height;
      }
    })
    .bindContentCover($$this.isCodexConversationOpen, this.buildCodexConversationCover(), {
      modalTransition: ModalTransition.DEFAULT
    })
  }

  @Builder
  buildMainSectionPage(section: string, scroller: Scroller) {
    if (section === 'codex' && this.useTwoPaneCodexLayout() && this.selectedCodexTaskId.length > 0) {
      Row() {
        this.buildFixedWideCodexDashboard();
      }
      .width('100%')
      .height('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ top: 134, bottom: 18 })
      .translate({ x: this.mainSectionPageTranslate(section) })
    } else {
      Scroll(scroller) {
        Row() {
          if (section === 'voice') {
            Column({ space: 16 }) {
              this.buildComposerCard();
              this.buildSafetyHint();
            }
            .width(this.voiceContentWidth())
          } else {
            Column({ space: 16 }) {
              this.buildCodexDashboard();
            }
            .width('100%')
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .justifyContent(FlexAlign.Center)
        .padding({ top: 134, bottom: 36 })
      }
      .width('100%')
      .height('100%')
      .translate({ x: this.mainSectionPageTranslate(section) })
    }
  }

  @Builder
  buildAmbientBackground() {
    Stack() {
      if (this.useTwoPaneCodexLayout()) {
        Column()
          .width(520)
          .height(520)
          .borderRadius(260)
          .backgroundColor('#525B8CFF')
          .blur(138)
          .position({ x: -150, y: -170 })
        Column()
          .width(500)
          .height(500)
          .borderRadius(250)
          .backgroundColor('#48BB84FF')
          .blur(150)
          .position({ x: '66%', y: 90 })
        Column()
          .width(600)
          .height(600)
          .borderRadius(300)
          .backgroundColor('#40A36BFF')
          .blur(160)
          .position({ x: -190, y: 560 })
        Column()
          .width(520)
          .height(520)
          .borderRadius(260)
          .backgroundColor('#36D4B5FF')
          .blur(155)
          .position({ x: '70%', y: 610 })
      } else {
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
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  buildFixedHeader() {
    Row() {
      if (this.useTwoPaneCodexLayout()) {
        Text('Starly')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      } else {
        Text('Starly')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .backgroundEffect({
            radius: 20,
            saturation: 1.1,
            brightness: 1.03,
            adaptiveColor: AdaptiveColor.DEFAULT
          })
      }
      Blank()
      this.buildTitleConnectionStatus();
    }
    .width('100%')
    .height(52)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildTitleConnectionStatus() {
    Row({ space: 6 }) {
      Text(this.isConnected ? '✓' : '•')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isConnected ? '#175CD3' : $r('app.color.text_secondary'))
      Text(this.isConnected ? '已配对' : '未配对')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
    }
    .width(92)
    .height(36)
    .padding({ left: 11, right: 11 })
    .clip(true)
    .backgroundColor($r('app.color.glass_surface'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT,
      scale: 0.84
    })
    .border({ width: 1, color: $r('app.color.glass_border') })
    .borderRadius(18)
    .shadow({ radius: 14, color: $r('app.color.glass_shadow'), offsetY: 5 })
    .animation({ duration: 220, curve: Curve.FastOutSlowIn })
    .onClick(() => {
      this.togglePairingPanel();
    })
  }

  @Builder
  buildPairingOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#1A0B1830')
        .onClick(() => {
          this.closePairingPanel();
        })
      Column() {
        this.buildPairingCard();
      }
      .width(this.pairingPanelWidth())
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const height = Number(newArea.height);
        if (height > 0 && Math.abs(height - this.pairingPanelHeight) > 0.5) {
          this.pairingPanelHeight = height;
          this.clampPairingPanelOffset();
        }
      })
      .scale({ x: this.isPairingExpanded ? 1 : 0.94, y: this.isPairingExpanded ? 1 : 0.94 })
      .translate({
        x: this.pairingPanelOffsetX,
        y: this.pairingPanelOffsetY + (this.isPairingExpanded ? 0 : -14)
      })
    }
    .width('100%')
    .height('100%')
    .opacity(this.isPairingExpanded ? 1 : 0)
    .animation({ duration: 280, curve: Curve.FastOutSlowIn })
    .zIndex(25)
  }

  @Builder
  buildPairingCard() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 2 }) {
          Text('连接电脑')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('按住标题栏可拖动')
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Row({ space: 8 }) {
          if (canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')) {
            Button('扫码配对')
              .height(36)
              .fontSize(13)
              .fontColor('#175CD3')
              .backgroundColor('#EAF2FF')
              .borderRadius(18)
              .onClick(() => this.scanPairingCode())
          }
          Button('关闭')
            .height(36)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.input_background'))
            .borderRadius(18)
            .onClick(() => this.closePairingPanel())
        }
      }
      .width('100%')
      .parallelGesture(
        PanGesture({ direction: PanDirection.All, distance: 5 })
          .onActionStart(() => {
            this.beginPairingPanelDrag();
          })
          .onActionUpdate((event: GestureEvent) => {
            this.updatePairingPanelDrag(event.offsetX, event.offsetY);
          })
          .onActionEnd((event: GestureEvent) => {
            this.updatePairingPanelDrag(event.offsetX, event.offsetY);
          })
      )
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
  buildMainSectionTabs() {
    Stack({ alignContent: Alignment.Start }) {
      Column()
        .width('50%')
        .height(40)
        .backgroundColor($r('app.color.glass_surface_strong'))
        .border({ width: 1, color: $r('app.color.glass_border') })
        .borderRadius(20)
        .shadow({ radius: 12, color: $r('app.color.glass_shadow'), offsetY: 4 })
        .translate({ x: this.mainSection === 'codex' ? (this.mainSectionTabsViewportWidth - 10) / 2 : 0 })
        .animation({ duration: 320, curve: Curve.FastOutSlowIn })
      Row() {
        this.buildMainSectionButton('voice', '语音输入')
        this.buildMainSectionButton('codex', 'Codex 任务')
      }
      .width('100%')
      .height(40)
      .zIndex(1)
    }
    .width(this.mainTabsWidth())
    .height(50)
    .padding(5)
    .backgroundEffect({
      radius: 28,
      saturation: 1.12,
      brightness: 1.04,
      color: $r('app.color.top_overlay_surface'),
      adaptiveColor: AdaptiveColor.DEFAULT
    })
    .border({ width: 1, color: $r('app.color.glass_border') })
    .borderRadius(25)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const width = Number(newArea.width);
      if (width > 0 && Math.abs(width - this.mainSectionTabsViewportWidth) > 0.5) {
        this.mainSectionTabsViewportWidth = width;
      }
    })
  }

  @Builder
  buildMainSectionButton(value: string, label: string) {
    Button(label)
      .layoutWeight(1)
      .height(40)
      .fontSize(15)
      .fontWeight(this.mainSection === value ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.mainSection === value ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
      .backgroundColor(Color.Transparent)
      .border({ width: 0, color: Color.Transparent })
      .borderRadius(20)
      .animation({ duration: 260, curve: Curve.EaseOut })
      .onClick(() => {
        this.animateMainSectionTo(value);
      })
      .priorityGesture(
        TapGesture()
          .onAction(() => {
            this.animateMainSectionTo(value);
          })
      )
  }

  @Builder
  buildCodexDashboard() {
    if (this.useTwoPaneCodexLayout() && this.selectedCodexTaskId.length > 0) {
      Row({ space: 18 }) {
        Column({ space: 16 }) {
          this.buildCodexQuotaCard();
          this.buildCodexTaskCard();
        }
        .width(this.codexSidebarWidth())
        Column() {
          this.buildCodexDetailCard();
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    } else {
      Column({ space: 16 }) {
        this.buildCodexQuotaCard();
        this.buildCodexTaskCard();
        if (this.selectedCodexTaskId.length > 0) {
          this.buildCodexDetailCard();
        }
      }
      .width('100%')
    }
  }

  @Builder
  buildFixedWideCodexDashboard() {
    Row({ space: 18 }) {
      Column({ space: 16 }) {
        this.buildCodexQuotaCard();
        Scroll() {
          Column() {
            this.buildCodexTaskCard();
          }
          .width('100%')
          .padding({ bottom: 2 })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.TopStart)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .clip(true)
        .borderRadius(28)
      }
      .width(this.codexSidebarWidth())
      .height('100%')

      Column() {
        Column() {
          this.buildCodexDetailCard();
        }
        .width('100%')
      }
      .layoutWeight(1)
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  buildCodexQuotaCard() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 3 }) {
          Text('Codex 剩余额度')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.codexQuotaSubtitle())
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Blank()
        Text(this.codexAvailable ? `${Math.round(this.codexQuota.remainingPercent)}%` : '--')
          .fontSize(34)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.codexAvailable ? '#175CD3' : $r('app.color.text_secondary'))
      }
      .width('100%')
      Progress({ value: this.codexAvailable ? this.codexQuota.remainingPercent : 0,
        total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(10)
        .color('#175CD3')
        .backgroundColor('#335C82D8')
        .borderRadius(5)
      Row() {
        Text(this.codexAvailable ? this.codexResetText() : (this.codexError || '等待电脑端 Codex'))
          .fontSize(12)
          .fontColor(this.codexAvailable ? $r('app.color.text_secondary') : '#B42318')
          .maxLines(2)
          .layoutWeight(1)
        Text(this.codexAvailable ? this.codexUsageText() : '')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
    }
    .width('100%')
    .padding(18)
    .backgroundColor($r('app.color.glass_surface'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT,
      scale: 0.9
    })
    .border({ width: 1, color: $r('app.color.glass_border') })
    .borderRadius(28)
    .shadow({ radius: 28, color: $r('app.color.glass_shadow'), offsetY: 10 })
  }

  @Builder
  buildCodexTaskCard() {
    Column({ space: 6 }) {
      Row() {
        Text('最近任务')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Row({ space: 16 }) {
          Text(this.codexLoading ? '刷新中…' : '刷新')
            .fontSize(13)
            .fontColor('#175CD3')
            .onClick(() => this.refreshCodex())
          Text(this.areCodexTasksExpanded ? '收起 ︿' : '展开 ﹀')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#175CD3')
            .onClick(() => this.toggleCodexTasks())
        }
      }
      .width('100%')
      if (this.areCodexTasksExpanded && this.codexTasks.length > 10) {
        Row({ space: 5 }) {
          Text('显示')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .margin({ right: 3 })
          ForEach([10, 20, 30], (limit: number) => {
            Button(`${limit} 个`)
              .layoutWeight(1)
              .height(30)
              .fontSize(11)
              .fontWeight(this.codexTaskDisplayLimit === limit ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.codexTaskDisplayLimit === limit ? '#175CD3' :
                $r('app.color.text_secondary'))
              .backgroundColor(this.codexTaskDisplayLimit === limit ? '#1A175CD3' : Color.Transparent)
              .border({
                width: 1,
                color: this.codexTaskDisplayLimit === limit ? '#52175CD3' :
                  $r('app.color.glass_border')
              })
              .borderRadius(15)
              .animation({ duration: 220, curve: Curve.EaseOut })
              .onClick(() => {
                this.codexTaskDisplayLimit = limit;
              })
          }, (limit: number): string => `codex-task-limit-${limit}`)
        }
        .width('100%')
        .padding({ top: 5, bottom: 7 })
      }
      if (!this.areCodexTasksExpanded) {
        if (this.selectedCodexTaskId.length > 0) {
          Row({ space: 11 }) {
            Stack({ alignContent: Alignment.Center }) {
              Text('')
                .width(18)
                .height(18)
                .borderRadius(9)
                .backgroundColor('#1A175CD3')
                .border({ width: 1, color: '#52175CD3' })
              Text('')
                .width(8)
                .height(8)
                .borderRadius(4)
                .backgroundColor(this.codexStatusColor(this.collapsedSelectedCodexStatus()))
                .shadow({ radius: 8, color: this.codexStatusColor(this.collapsedSelectedCodexStatus()) })
            }
            .width(20)
            .height(20)
            Column({ space: 3 }) {
              Text(this.selectedCodexTitle || '当前任务')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.selectedCodexTaskSubtitle())
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Column({ space: 3 }) {
              Text('当前')
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor('#175CD3')
                .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                .backgroundColor('#1A175CD3')
                .border({ width: 1, color: '#4D175CD3' })
                .borderRadius(11)
              Text(this.codexStatusLabel(this.collapsedSelectedCodexStatus()))
                .fontSize(10)
                .fontColor(this.codexStatusColor(this.collapsedSelectedCodexStatus()))
            }
            .alignItems(HorizontalAlign.End)
          }
          .width('98%')
          .padding({ left: 12, right: 12, top: 12, bottom: 12 })
          .backgroundColor($r('app.color.glass_surface_strong'))
          .border({ width: 2, color: '#73175CD3' })
          .borderRadius(21)
          .shadow({ radius: 22, color: '#4A175CD3', offsetY: 8 })
          .translate({ y: -2 })
          .scale({ x: 1.015, y: 1.015 })
          .animation({ duration: 260, curve: Curve.EaseOut })
          .onClick(() => this.handleCodexTaskTap(this.selectedCodexTaskId))
        } else {
          Row() {
            Text('暂未选择任务')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text('点击展开')
              .fontSize(12)
              .fontColor('#175CD3')
          }
          .width('100%')
          .padding({ top: 10, bottom: 8 })
          .onClick(() => this.toggleCodexTasks())
        }
      } else if (this.codexTasks.length === 0) {
        Text(this.codexAvailable ? '暂时没有可显示的 Codex 任务' : '连接电脑后读取 Codex 任务')
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .padding({ top: 24, bottom: 24 })
      } else {
        ForEach(this.codexTasks.slice(0, this.codexTaskDisplayLimit), (task: CodexTask) => {
          Row({ space: 11 }) {
            if (this.selectedCodexTaskId === task.id) {
              Stack({ alignContent: Alignment.Center }) {
                Text('')
                  .width(18)
                  .height(18)
                  .borderRadius(9)
                  .backgroundColor('#1A175CD3')
                  .border({ width: 1, color: '#52175CD3' })
                Text('')
                  .width(8)
                  .height(8)
                  .borderRadius(4)
                  .backgroundColor(this.codexStatusColor(this.effectiveCodexStatus(task)))
                  .shadow({ radius: 8, color: this.codexStatusColor(this.effectiveCodexStatus(task)) })
              }
              .width(20)
              .height(20)
            } else {
              Text('')
                .width(9)
                .height(9)
                .borderRadius(5)
                .backgroundColor(this.codexStatusColor(this.effectiveCodexStatus(task)))
                .shadow({ radius: this.effectiveCodexStatus(task) === 'active' ? 8 : 0,
                  color: this.codexStatusColor(this.effectiveCodexStatus(task)) })
            }
            Column({ space: 3 }) {
              Text(task.title)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(task.preview.length > 0 ? task.preview : this.shortPath(task.cwd))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            if (this.selectedCodexTaskId === task.id) {
              Column({ space: 3 }) {
                Text('当前')
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#175CD3')
                  .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                  .backgroundColor('#1A175CD3')
                  .border({ width: 1, color: '#4D175CD3' })
                  .borderRadius(11)
                Text(this.codexStatusLabel(this.effectiveCodexStatus(task)))
                  .fontSize(10)
                  .fontColor(this.codexStatusColor(this.effectiveCodexStatus(task)))
              }
              .alignItems(HorizontalAlign.End)
            } else {
              Text(this.codexStatusLabel(this.effectiveCodexStatus(task)))
                .fontSize(11)
                .fontColor(this.codexStatusColor(this.effectiveCodexStatus(task)))
                .maxLines(1)
            }
          }
          .width(this.selectedCodexTaskId === task.id ? '98%' : '100%')
          .padding({ left: 12, right: 12, top: 12, bottom: 12 })
          .backgroundColor(this.selectedCodexTaskId === task.id ?
            $r('app.color.glass_surface_strong') : Color.Transparent)
          .border({
            width: this.selectedCodexTaskId === task.id ? 2 : 1,
            color: this.selectedCodexTaskId === task.id ? '#73175CD3' : Color.Transparent
          })
          .borderRadius(this.selectedCodexTaskId === task.id ? 21 : 17)
          .shadow({
            radius: this.selectedCodexTaskId === task.id ? 22 : 0,
            color: this.selectedCodexTaskId === task.id ? '#4A175CD3' : Color.Transparent,
            offsetY: this.selectedCodexTaskId === task.id ? 8 : 0
          })
          .translate({ y: this.selectedCodexTaskId === task.id ? -2 : 0 })
          .scale({
            x: this.selectedCodexTaskId === task.id ? 1.015 : 1,
            y: this.selectedCodexTaskId === task.id ? 1.015 : 1
          })
          .zIndex(this.selectedCodexTaskId === task.id ? 2 : 0)
          .animation({ duration: 260, curve: Curve.EaseOut })
          .onClick(() => this.handleCodexTaskTap(task.id))
        }, (task: CodexTask): string => task.id)
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
    .borderRadius(28)
    .shadow({ radius: 28, color: $r('app.color.glass_shadow'), offsetY: 10 })
  }

  @Builder
  buildCodexDetailCard() {
    Column({ space: 13 }) {
      Row() {
        Column({ space: 3 }) {
          Text(this.selectedCodexTitle || '任务详情')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.shortPath(this.selectedCodexCwd))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.isSelectedCodexRunning()) {
          Text('正在执行')
            .fontSize(12)
            .fontColor('#067647')
        }
      }
      .width('100%')
      Row() {
        Text(`聊天记录 · 已加载 ${this.selectedCodexMessages.length} 条`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        if (this.codexHistoryLoadingOlder) {
          Text('正在加载更早记录…')
            .fontSize(11)
            .fontColor('#175CD3')
        } else if (this.codexHistoryHasMore) {
          Text('滑到顶部加载前 15 条')
            .fontSize(11)
            .fontColor('#175CD3')
        }
      }
      .width('100%')
      List({ space: 10, scroller: this.codexChatScroller }) {
        if (this.codexDetailLoading && this.selectedCodexMessages.length === 0) {
          ListItem() {
            Text('正在加载聊天记录…')
              .width('100%')
              .textAlign(TextAlign.Center)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .padding({ top: 28, bottom: 28 })
          }
        } else if (this.selectedCodexMessages.length === 0) {
          ListItem() {
            Text('还没有聊天记录')
              .width('100%')
              .textAlign(TextAlign.Center)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .padding({ top: 28, bottom: 28 })
          }
        }
        ForEach(this.selectedCodexMessages, (message: CodexMessage) => {
          ListItem() {
            this.buildCodexMessageBubble(message)
          }
        }, (message: CodexMessage): string => message.id)
        if (this.isSelectedCodexRunning()) {
          ListItem() {
            Row() {
              Text('Codex 正在输入…')
                .fontSize(12)
                .fontColor('#067647')
                .padding({ left: 14, right: 14, top: 10, bottom: 10 })
                .backgroundColor($r('app.color.glass_surface_strong'))
                .border({ width: 1, color: $r('app.color.glass_border') })
                .borderRadius(18)
              Blank()
            }
            .width('100%')
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .onScrollStart(() => {
        if (this.codexHistoryReady) {
          this.codexChatPinnedToBottom = false;
        }
      })
      .onReachStart(() => {
        this.loadOlderCodexMessages();
      })
      .onReachEnd(() => {
        this.codexChatPinnedToBottom = true;
        this.codexUnreadMessages = 0;
      })
      if (this.codexUnreadMessages > 0) {
        Button(`↓ ${this.codexUnreadMessages} 条新消息`)
          .height(34)
          .fontSize(11)
          .fontColor('#175CD3')
          .backgroundColor('#EAF2FF')
          .borderRadius(17)
          .onClick(() => this.scrollCodexChatToBottom(true))
      }
      Column({ space: 8 }) {
        if (this.codexImagePreviewUri.length > 0) {
          Row({ space: 10 }) {
            Image(this.codexImagePreviewUri)
              .width(92)
              .height(72)
              .objectFit(ImageFit.Contain)
              .borderRadius(10)
              .backgroundColor('#12000000')
            Text(this.codexImagePicking ? '正在处理图片…' : '图片已就绪，可继续输入文字')
              .layoutWeight(1)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
            Button('移除')
              .height(34)
              .fontSize(12)
              .fontColor('#B42318')
              .backgroundColor('#14FEF3F2')
              .borderRadius(12)
              .enabled(!this.codexImagePicking)
              .onClick(() => {
                this.codexImagePreviewUri = '';
                this.codexImageDataUrl = '';
                this.codexImageMimeType = '';
              })
          }
          .width('100%')
        }
        TextArea({ text: this.codexCommand, placeholder: '继续给这个 Codex 任务发送要求…' })
          .height(72)
          .fontSize(15)
          .backgroundColor(Color.Transparent)
          .padding(4)
          .onChange((value: string) => {
            this.codexCommand = value;
          })
      }
      .width('100%')
      .padding(12)
      .backgroundColor($r('app.color.input_background'))
      .border({ width: 1, color: $r('app.color.glass_border') })
      .borderRadius(18)
      Row({ space: 8 }) {
        Button('+')
          .width(48)
          .height(48)
          .padding(0)
          .fontSize(25)
          .fontWeight(FontWeight.Normal)
          .fontColor('#175CD3')
          .backgroundColor($r('app.color.glass_surface_strong'))
          .border({ width: 1, color: $r('app.color.glass_border') })
          .borderRadius(24)
          .enabled(this.isConnected && !this.codexImagePicking)
          .onClick(() => this.chooseCodexImage())
        Button('发送后按回车')
          .layoutWeight(1)
          .height(48)
          .padding({ left: 4, right: 4 })
          .fontSize(this.useTwoPaneCodexLayout() ? 12 : 10)
          .fontColor(this.codexCommand.trim().length > 0 || this.codexImageDataUrl.length > 0 ?
            '#175CD3' : $r('app.color.text_secondary'))
          .backgroundColor($r('app.color.glass_surface_strong'))
          .border({ width: 1, color: $r('app.color.glass_border') })
          .borderRadius(14)
          .enabled((this.codexCommand.trim().length > 0 || this.codexImageDataUrl.length > 0) &&
            this.isConnected && !this.codexImagePicking)
          .onClick(() => this.sendCodexCommand('enter'))
        Button('发送后按Ctrl+回车')
          .layoutWeight(1)
          .height(48)
          .padding({ left: 4, right: 4 })
          .fontSize(this.useTwoPaneCodexLayout() ? 12 : 10)
          .fontColor(this.codexCommand.trim().length > 0 || this.codexImageDataUrl.length > 0 ?
            '#175CD3' : $r('app.color.text_secondary'))
          .backgroundColor($r('app.color.glass_surface_strong'))
          .border({ width: 1, color: $r('app.color.glass_border') })
          .borderRadius(14)
          .enabled((this.codexCommand.trim().length > 0 || this.codexImageDataUrl.length > 0) &&
            this.isConnected && !this.codexImagePicking)
          .onClick(() => this.sendCodexCommand('ctrl_enter'))
        if (this.selectedCodexActiveTurnId.length > 0) {
          Button() {
            Text('■')
              .fontSize(17)
              .fontColor('#D92D20')
          }
          .width(48)
          .height(48)
          .padding(0)
          .backgroundColor('#24F04438')
          .border({ width: 1, color: '#55F04438' })
          .borderRadius(24)
          .onClick(() => this.stopCodexTask())
        }
      }
    }
    .width('100%')
    .height(this.codexDetailCardHeight())
    .padding(16)
    .backgroundColor($r('app.color.glass_surface'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT,
      scale: 0.9
    })
    .border({ width: 1, color: $r('app.color.glass_border') })
    .borderRadius(28)
    .shadow({ radius: 28, color: $r('app.color.glass_shadow'), offsetY: 10 })
  }

  @Builder
  buildCodexMessageBubble(message: CodexMessage) {
    Row() {
      if (message.role === 'user') {
        Blank()
      }
      Column({ space: 7 }) {
        Row() {
          Text(message.role === 'user' ? '你' : 'Codex')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(message.role === 'user' ? '#E6FFFFFF' : '#067647')
          Blank()
          Text(this.formatMessageTimestamp(message.timestamp))
            .fontSize(9)
            .fontColor(message.role === 'user' ? '#BFFFFFFF' : $r('app.color.text_secondary'))
        }
        .width('100%')
        if (message.text.trim().length > 0) {
          Text(message.text)
            .width('100%')
            .fontSize(13)
            .lineHeight(20)
            .fontColor(message.role === 'user' ? Color.White : $r('app.color.text_primary'))
        }
        if (message.images.length > 0) {
          ForEach(message.images, (source: string, imageIndex: number) => {
            Image(source)
              .width('100%')
              .height(this.useTwoPaneCodexLayout() ? 190 : 150)
              .objectFit(ImageFit.Contain)
              .backgroundColor('#16000000')
              .borderRadius(12)
          }, (_source: string, imageIndex: number): string => `${message.id}-image-${imageIndex}`)
        }
        if (message.deliveryState.length > 0) {
          Text(message.deliveryState === 'failed' ? '发送失败' :
            (message.deliveryState === 'sent' ? '已发送' : '发送中…'))
            .width('100%')
            .textAlign(TextAlign.End)
            .fontSize(9)
            .fontColor(message.deliveryState === 'failed' ? '#FFD7D3' : '#BFFFFFFF')
        }
      }
      .width(this.codexChatBubbleWidth())
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 14, right: 14, top: 11, bottom: 11 })
      .backgroundColor(message.role === 'user' ? '#E65B5CE2' : $r('app.color.glass_surface_strong'))
      .border({
        width: 1,
        color: message.role === 'user' ? '#66FFFFFF' : $r('app.color.glass_border')
      })
      .borderRadius(19)
      .shadow({
        radius: 16,
        color: message.role === 'user' ? '#365B5CE2' : $r('app.color.glass_shadow'),
        offsetY: 5
      })
      if (message.role !== 'user') {
        Blank()
      }
    }
    .width('100%')
  }

  @Builder
  buildCodexConversationCover() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.buildAmbientBackground();
      Row() {
        Column({ space: 14 }) {
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text(this.selectedCodexTitle || 'Codex 完整对话')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`显示最近 ${this.visibleCodexMessageCount()} 条 · 可上下滑动查看`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Button('关闭')
            .height(40)
            .fontColor('#175CD3')
            .backgroundColor($r('app.color.glass_surface_strong'))
            .border({ width: 1, color: $r('app.color.glass_border') })
            .borderRadius(14)
            .onClick(() => {
              this.isCodexConversationOpen = false;
              this.requestSelectedCodexThread(true);
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          ForEach([5, 10, 15], (limit: number) => {
            Button(`${limit} 条`)
              .layoutWeight(1)
              .height(42)
              .fontSize(13)
              .fontWeight(this.codexConversationLimit === limit ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.codexConversationLimit === limit ? '#175CD3' :
                $r('app.color.text_secondary'))
              .backgroundColor(this.codexConversationLimit === limit ?
                $r('app.color.glass_surface_strong') : Color.Transparent)
              .border({
                width: 1,
                color: this.codexConversationLimit === limit ? '#52175CD3' :
                  $r('app.color.glass_border')
              })
              .borderRadius(14)
              .onClick(() => {
                this.codexConversationLimit = limit;
              })
          }, (limit: number): string => `codex-message-limit-${limit}`)
        }
        .width('100%')
        .padding(4)
        .backgroundColor($r('app.color.input_background'))
        .borderRadius(18)

        Scroll() {
          Column({ space: 12 }) {
            ForEach(this.visibleCodexMessages(), (message: CodexMessage, index: number) => {
              Column({ space: 8 }) {
                Row() {
                  Text(message.role === 'user' ? '你' : 'Codex')
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(message.role === 'user' ? '#175CD3' : '#067647')
                  Blank()
                  Text(this.formatMessageTimestamp(message.timestamp))
                    .fontSize(11)
                    .fontColor($r('app.color.text_secondary'))
                }
                .width('100%')
                Text(message.text)
                  .width('100%')
                  .fontSize(15)
                  .lineHeight(23)
                  .fontColor($r('app.color.text_primary'))
                if (message.images.length > 0) {
                  ForEach(message.images, (source: string, imageIndex: number) => {
                    Image(source)
                      .width('100%')
                      .height(280)
                      .objectFit(ImageFit.Contain)
                      .backgroundColor('#12000000')
                      .borderRadius(16)
                  }, (_source: string, imageIndex: number): string =>
                    `${message.turnId}-full-image-${imageIndex}`)
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(15)
              .backgroundColor($r('app.color.glass_surface'))
              .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
                colorMode: ThemeColorMode.SYSTEM,
                adaptiveColor: AdaptiveColor.DEFAULT,
                scale: 0.9
              })
              .border({ width: 1, color: $r('app.color.glass_border') })
              .borderRadius(20)
            }, (message: CodexMessage, index: number): string =>
              `${message.turnId}-${message.role}-${index}`)
          }
          .width('100%')
          .padding({ bottom: 24 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        }
        .width(this.conversationPanelWidth())
        .height('100%')
        .padding({ top: 58, bottom: 12 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
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
        index: this.submitMode === 'ctrl_enter' ? 0 : 1,
        controller: this.submitTabsController
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
      .animationDuration(280)
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
        .animation({ duration: 240, curve: Curve.EaseOut })
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
    .scale({
      x: this.submitMode === (index === 0 ? 'ctrl_enter' : 'enter') ? 1 : 0.94,
      y: this.submitMode === (index === 0 ? 'ctrl_enter' : 'enter') ? 1 : 0.94
    })
    .opacity(this.submitMode === (index === 0 ? 'ctrl_enter' : 'enter') ? 1 : 0.72)
    .translate({
      y: this.submitMode === (index === 0 ? 'ctrl_enter' : 'enter') ? 0 : 1
    })
    .animation({ duration: 260, curve: Curve.EaseOut })
    .parallelGesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 8 })
        .onActionEnd((event: GestureEvent) => {
          this.changeSubmitModeByTabSwipe(event.offsetX);
        })
    )
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

  private mainShellWidth(): number {
    if (this.layoutViewportWidth < 600) {
      return Math.max(280, this.layoutViewportWidth - 36);
    }
    if (this.layoutViewportWidth < 1100) {
      return Math.min(960, Math.max(520, this.layoutViewportWidth - 48));
    }
    return Math.min(1280, Math.max(760, this.layoutViewportWidth - 72));
  }

  private voiceContentWidth(): number {
    return Math.min(this.mainSectionViewportWidth, this.layoutViewportWidth >= 1100 ? 820 : 760);
  }

  private mainTabsWidth(): number {
    return Math.min(this.mainSectionViewportWidth, 480);
  }

  private pairingPanelWidth(): number {
    return Math.min(520, Math.max(280, this.layoutViewportWidth - 36));
  }

  private conversationPanelWidth(): number {
    const outerPadding = this.layoutViewportWidth < 600 ? 36 : 72;
    return Math.min(960, Math.max(280, this.layoutViewportWidth - outerPadding));
  }

  private useTwoPaneCodexLayout(): boolean {
    return this.mainSectionViewportWidth >= 900;
  }

  private codexSidebarWidth(): number {
    return this.mainSectionViewportWidth >= 1180 ? 420 : 360;
  }

  private codexDetailCardHeight(): number {
    if (this.useTwoPaneCodexLayout()) {
      return Math.max(500, this.layoutViewportHeight - 152);
    }
    return 720;
  }

  private codexChatBubbleWidth(): number {
    if (this.useTwoPaneCodexLayout()) {
      const detailWidth = this.mainSectionViewportWidth - this.codexSidebarWidth() - 68;
      return Math.min(680, Math.max(240, detailWidth * 0.78));
    }
    return Math.min(560, Math.max(220, (this.mainSectionViewportWidth - 32) * 0.82));
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
    if (!canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')) {
      this.statusText = '当前设备不支持扫码，请手动填写配对信息';
      this.statusIsError = false;
      return;
    }
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

  private changeSubmitModeByTabSwipe(offsetX: number): void {
    if (Math.abs(offsetX) < 18) {
      return;
    }
    const targetIndex = offsetX > 0 ? 1 : 0;
    const targetMode = targetIndex === 0 ? 'ctrl_enter' : 'enter';
    if (this.submitMode === targetMode) {
      return;
    }
    this.submitTabsController.changeIndex(targetIndex);
  }

  private mainSectionPageTranslate(section: string): number {
    const currentIndex = this.mainSection === 'codex' ? 0 : 1;
    const pageIndex = section === 'codex' ? 0 : 1;
    return (pageIndex - currentIndex) * this.mainSectionViewportWidth + this.mainSectionDragOffset;
  }

  private beginMainSectionSwipe(): void {
    if (this.mainSectionAnimating || this.isVoicePressing || this.isPairingExpanded) {
      return;
    }
    this.mainSectionDragOffset = 0;
  }

  private updateMainSectionSwipe(offsetX: number): void {
    if (this.mainSectionAnimating || this.isVoicePressing || this.isPairingExpanded ||
      this.mainSectionViewportWidth <= 0) {
      return;
    }
    let nextOffset = offsetX;
    const isOutsideEdge = (this.mainSection === 'voice' && nextOffset > 0) ||
      (this.mainSection === 'codex' && nextOffset < 0);
    if (isOutsideEdge) {
      nextOffset *= 0.12;
    }
    const limit = this.mainSectionViewportWidth;
    this.mainSectionDragOffset = Math.max(-limit, Math.min(limit, nextOffset));
  }

  private finishMainSectionSwipe(offsetX: number): void {
    if (this.mainSectionAnimating || this.isVoicePressing || this.isPairingExpanded) {
      this.mainSectionDragOffset = 0;
      return;
    }
    this.updateMainSectionSwipe(offsetX);
    const threshold = Math.min(72, this.mainSectionViewportWidth * 0.2);
    if (this.mainSection === 'voice' && this.mainSectionDragOffset < -threshold) {
      this.settleMainSection('codex');
      return;
    }
    if (this.mainSection === 'codex' && this.mainSectionDragOffset > threshold) {
      this.settleMainSection('voice');
      return;
    }
    this.cancelMainSectionSwipe();
  }

  private cancelMainSectionSwipe(): void {
    if (this.mainSectionAnimating || this.mainSectionDragOffset === 0) {
      return;
    }
    this.mainSectionAnimating = true;
    this.getUIContext().animateTo({
      duration: 220,
      curve: Curve.Friction,
      onFinish: () => {
        this.mainSectionDragOffset = 0;
        this.mainSectionAnimating = false;
      }
    }, () => {
      this.mainSectionDragOffset = 0;
    });
  }

  private animateMainSectionTo(targetSection: string): void {
    if (targetSection === this.mainSection || this.mainSectionAnimating) {
      return;
    }
    this.settleMainSection(targetSection);
  }

  private settleMainSection(targetSection: string): void {
    const currentDragOffset = this.mainSectionDragOffset;
    const adjustedOffset = targetSection === 'codex' ?
      currentDragOffset + this.mainSectionViewportWidth :
      currentDragOffset - this.mainSectionViewportWidth;
    this.mainSectionAnimating = true;
    this.mainSection = targetSection;
    this.mainSectionDragOffset = adjustedOffset;
    this.onMainSectionChanged(targetSection);
    this.getUIContext().animateTo({
      duration: 320,
      curve: Curve.FastOutSlowIn,
      onFinish: () => {
        this.mainSectionDragOffset = 0;
        this.mainSectionAnimating = false;
      }
    }, () => {
      this.mainSectionDragOffset = 0;
    });
  }

  private openCodexConversation(): void {
    if (this.mainSection !== 'codex') {
      this.mainSection = 'codex';
      this.mainSectionDragOffset = 0;
      this.onMainSectionChanged('codex');
    }
    this.isCodexConversationOpen = true;
  }

  private onMainSectionChanged(targetSection: string): void {
    if (targetSection === 'codex') {
      this.refreshCodex();
      this.startCodexAutoRefresh();
    } else {
      this.stopCodexAutoRefresh();
    }
  }

  private togglePairingPanel(): void {
    if (this.isPairingOverlayMounted) {
      this.closePairingPanel();
      return;
    }
    this.pairingPanelOffsetX = 0;
    this.pairingPanelOffsetY = 0;
    this.isPairingOverlayMounted = true;
    if (this.pairingOverlayShowTimer >= 0) {
      clearTimeout(this.pairingOverlayShowTimer);
    }
    this.pairingOverlayShowTimer = setTimeout(() => {
      this.pairingOverlayShowTimer = -1;
      if (!this.isPairingOverlayMounted) {
        return;
      }
      this.getUIContext().animateTo({
        duration: 280,
        curve: Curve.FastOutSlowIn
      }, () => {
        this.isPairingExpanded = true;
      });
    }, 16);
  }

  private closePairingPanel(): void {
    if (!this.isPairingOverlayMounted) {
      return;
    }
    if (this.pairingOverlayShowTimer >= 0) {
      clearTimeout(this.pairingOverlayShowTimer);
      this.pairingOverlayShowTimer = -1;
    }
    if (!this.isPairingExpanded) {
      this.isPairingOverlayMounted = false;
      return;
    }
    this.getUIContext().animateTo({
      duration: 260,
      curve: Curve.FastOutSlowIn,
      onFinish: () => {
        this.isPairingOverlayMounted = false;
      }
    }, () => {
      this.isPairingExpanded = false;
    });
  }

  private beginPairingPanelDrag(): void {
    this.pairingPanelDragStartX = this.pairingPanelOffsetX;
    this.pairingPanelDragStartY = this.pairingPanelOffsetY;
  }

  private updatePairingPanelDrag(offsetX: number, offsetY: number): void {
    const horizontalLimit = Math.max(0,
      (this.layoutViewportWidth - this.pairingPanelWidth()) / 2 - 12);
    const verticalLimit = Math.max(0,
      (this.layoutViewportHeight - this.pairingPanelHeight) / 2 - 12);
    this.pairingPanelOffsetX = Math.max(-horizontalLimit,
      Math.min(horizontalLimit, this.pairingPanelDragStartX + offsetX));
    this.pairingPanelOffsetY = Math.max(-verticalLimit,
      Math.min(verticalLimit, this.pairingPanelDragStartY + offsetY));
  }

  private clampPairingPanelOffset(): void {
    const horizontalLimit = Math.max(0,
      (this.layoutViewportWidth - this.pairingPanelWidth()) / 2 - 12);
    const verticalLimit = Math.max(0,
      (this.layoutViewportHeight - this.pairingPanelHeight) / 2 - 12);
    this.pairingPanelOffsetX = Math.max(-horizontalLimit,
      Math.min(horizontalLimit, this.pairingPanelOffsetX));
    this.pairingPanelOffsetY = Math.max(-verticalLimit,
      Math.min(verticalLimit, this.pairingPanelOffsetY));
  }

  private startCodexAutoRefresh(): void {
    if (this.codexAutoRefreshTimer >= 0) {
      return;
    }
    this.codexAutoRefreshTimer = setInterval(() => {
      if (!this.isConnected || this.mainSection !== 'codex') {
        return;
      }
      this.refreshCodexAutomatically();
    }, 5000);
  }

  private stopCodexAutoRefresh(): void {
    if (this.codexAutoRefreshTimer < 0) {
      return;
    }
    clearInterval(this.codexAutoRefreshTimer);
    this.codexAutoRefreshTimer = -1;
  }

  private shouldPollSelectedCodexDetail(): boolean {
    if (this.isCodexConversationOpen || this.selectedCodexTaskId.length === 0) {
      return false;
    }
    return this.selectedCodexStatus === 'active' ||
      this.selectedCodexActiveTurnId.length > 0 ||
      this.pendingCodexThreadId === this.selectedCodexTaskId;
  }

  private async refreshCodexAutomatically(): Promise<void> {
    if (this.codexAutoRefreshInFlight || !this.isConnected || this.mainSection !== 'codex' ||
      this.isCodexConversationOpen) {
      return;
    }
    this.codexAutoRefreshInFlight = true;
    try {
      // The bridge rate-limits requests that arrive within 120 ms. Read the
      // list first, then read the selected task after a short gap so the
      // detail response is not rejected as a burst request.
      await remoteInputClient.requestCodexSnapshot();
      if (this.shouldPollSelectedCodexDetail()) {
        await new Promise<void>((resolve: () => void) => {
          setTimeout(resolve, 180);
        });
        if (this.isConnected && this.mainSection === 'codex') {
          await this.requestSelectedCodexThread();
        }
      }
    } finally {
      this.codexAutoRefreshInFlight = false;
    }
  }

  private async requestSelectedCodexThread(force: boolean = false): Promise<void> {
    const threadId = this.selectedCodexTaskId;
    if (!this.isConnected || this.mainSection !== 'codex' || threadId.length === 0) {
      return;
    }
    if (!force && (this.codexDetailLoading || this.isCodexConversationOpen)) {
      return;
    }
    this.codexDetailLoading = this.selectedCodexMessages.length === 0;
    this.codexLoading = true;
    const requestToken = ++this.codexDetailRequestToken;
    this.clearCodexDetailWatchdog();
    this.codexDetailWatchdogTimer = setTimeout(() => {
      if (requestToken !== this.codexDetailRequestToken ||
        threadId !== this.selectedCodexTaskId || !this.codexDetailLoading) {
        return;
      }
      this.codexDetailWatchdogTimer = -1;
      this.codexDetailLoading = false;
      this.codexLoading = false;
      this.statusText = 'Codex 任务加载超时，正在重试';
      this.statusIsError = true;
      this.scheduleCodexDetailRetry(threadId, 300);
    }, 12000);
    const requested = await remoteInputClient.requestCodexThread(threadId, '', 15);
    if (!requested && requestToken === this.codexDetailRequestToken &&
      this.selectedCodexTaskId === threadId) {
      this.clearCodexDetailWatchdog();
      this.codexDetailLoading = false;
      this.codexLoading = false;
      this.scheduleCodexDetailRetry(threadId, 300);
    }
  }

  private scheduleCodexDetailRetry(threadId: string, delayMs: number): void {
    if (threadId.length === 0 || threadId !== this.selectedCodexTaskId ||
      this.mainSection !== 'codex' || !this.isConnected ||
      this.codexDetailRetryTimer >= 0 || this.codexDetailRetryCount >= 3) {
      return;
    }
    this.codexDetailRetryCount += 1;
    this.codexDetailRetryTimer = setTimeout(() => {
      this.codexDetailRetryTimer = -1;
      if (threadId === this.selectedCodexTaskId && this.mainSection === 'codex' &&
        this.isConnected) {
        this.requestSelectedCodexThread(true);
      }
    }, delayMs);
  }

  private clearCodexDetailWatchdog(): void {
    if (this.codexDetailWatchdogTimer >= 0) {
      clearTimeout(this.codexDetailWatchdogTimer);
      this.codexDetailWatchdogTimer = -1;
    }
  }

  private clearCodexDetailTimers(): void {
    this.clearCodexDetailWatchdog();
    if (this.codexDetailRetryTimer >= 0) {
      clearTimeout(this.codexDetailRetryTimer);
      this.codexDetailRetryTimer = -1;
    }
    this.codexDetailRequestToken += 1;
  }

  private async sendDraft(): Promise<void> {
    const sent = await remoteInputClient.sendText(this.draft, this.submitMode);
    if (sent) {
      this.statusText = '已发送，等待电脑确认…';
      this.statusIsError = false;
    }
  }

  private async refreshCodex(): Promise<void> {
    if (!this.isConnected) {
      this.codexAvailable = false;
      this.codexError = '请先连接电脑';
      return;
    }
    this.codexLoading = true;
    await remoteInputClient.requestCodexSnapshot();
  }

  private async selectCodexTask(threadId: string): Promise<void> {
    this.clearCodexDetailTimers();
    this.codexDetailRetryCount = 0;
    const previousThreadId = this.selectedCodexTaskId;
    if (previousThreadId.length > 0 && this.selectedCodexStatus !== 'notLoaded') {
      this.rememberCodexTaskStatus(previousThreadId, this.selectedCodexStatus);
    }
    this.selectedCodexTaskId = threadId;
    this.prepareSelectedCodexTask(threadId);
    this.selectedCodexMessages = [];
    this.selectedCodexActiveTurnId = '';
    this.codexHistoryHasMore = false;
    this.codexHistoryLoadingOlder = false;
    this.codexHistoryReady = false;
    this.codexChatPinnedToBottom = true;
    this.codexUnreadMessages = 0;
    this.codexDetailVersion += 1;
    this.codexDetailLoading = false;
    this.codexLoading = false;
    await this.requestSelectedCodexThread(true);
  }

  private async sendCodexCommand(submitMode: string): Promise<void> {
    if (this.selectedCodexTaskId.length === 0 || this.codexImagePicking) {
      return;
    }
    const pendingText = this.codexCommand.trim();
    const pendingImage = this.codexImagePreviewUri;
    const sent = this.codexImageDataUrl.length > 0 ?
      await remoteInputClient.sendImageToCodex(
        this.selectedCodexTaskId, this.codexCommand, this.codexImageDataUrl,
        this.codexImageMimeType || 'image/jpeg', submitMode) :
      await remoteInputClient.sendToCodex(this.selectedCodexTaskId, this.codexCommand, submitMode);
    if (sent) {
      this.appendPendingCodexMessage(pendingText, pendingImage);
      this.pendingCodexThreadId = this.selectedCodexTaskId;
      this.statusText = '正在恢复任务并发送…';
      this.statusIsError = false;
    }
  }

  private async chooseCodexImage(): Promise<void> {
    if (!this.isConnected || this.codexImagePicking) {
      return;
    }
    this.codexImagePicking = true;
    try {
      const uri = await imageTransferService.pickImage();
      if (uri === null) {
        return;
      }
      this.codexImagePreviewUri = uri;
      this.codexImageDataUrl = '';
      this.codexImageMimeType = '';
      this.statusText = '正在处理所选图片…';
      this.statusIsError = false;
      const encoded = await imageTransferService.encodeImage(uri);
      this.codexImageDataUrl = encoded.dataUrl;
      this.codexImageMimeType = encoded.mimeType;
      this.statusText = `图片已就绪（${Math.ceil(encoded.byteLength / 1024)} KB），可继续输入文字`;
      this.statusIsError = false;
    } catch (error) {
      this.codexImagePreviewUri = '';
      this.codexImageDataUrl = '';
      this.codexImageMimeType = '';
      this.statusText = `读取图片失败：${JSON.stringify(error)}`;
      this.statusIsError = true;
    } finally {
      this.codexImagePicking = false;
    }
  }

  private async stopCodexTask(): Promise<void> {
    if (this.selectedCodexActiveTurnId.length === 0) {
      return;
    }
    await remoteInputClient.interruptCodex(
      this.selectedCodexTaskId, this.selectedCodexActiveTurnId);
  }

  private prepareSelectedCodexTask(threadId: string): void {
    for (let index = 0; index < this.codexTasks.length; index += 1) {
      const task = this.codexTasks[index];
      if (task.id === threadId) {
        this.selectedCodexTitle = task.title;
        this.selectedCodexCwd = task.cwd;
        this.selectedCodexStatus = this.resolvedCodexStatus(task.id, task.status);
        this.selectedCodexUpdatedAt = task.updatedAt;
        return;
      }
    }
    this.selectedCodexTitle = '任务详情';
    this.selectedCodexCwd = '';
    this.selectedCodexStatus = 'notLoaded';
    this.selectedCodexUpdatedAt = 0;
  }

  private toggleCodexTasks(): void {
    this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseOut }, () => {
      this.areCodexTasksExpanded = !this.areCodexTasksExpanded;
    });
  }

  private handleCodexTaskTap(threadId: string): void {
    const now = Date.now();
    const isDoubleTap = threadId === this.lastCodexTaskTapId &&
      now - this.lastCodexTaskTapAt <= 450;
    this.lastCodexTaskTapId = threadId;
    this.lastCodexTaskTapAt = now;
    if (isDoubleTap && threadId === this.selectedCodexTaskId) {
      this.lastCodexTaskTapId = '';
      this.lastCodexTaskTapAt = 0;
      this.toggleCodexTasks();
      return;
    }
    if (threadId !== this.selectedCodexTaskId) {
      this.selectCodexTask(threadId);
    }
  }

  private applyCodexThreadDetail(detail: CodexThreadDetail): void {
    detail.status = normalizeCodexDetailStatus(detail.status, detail.activeTurnId);
    this.rememberCodexTaskStatus(detail.id, detail.status);
    if (detail.id !== this.selectedCodexTaskId) {
      return;
    }
    this.selectedCodexTitle = detail.title;
    this.selectedCodexCwd = detail.cwd;
    this.selectedCodexStatus = detail.status;
    this.selectedCodexActiveTurnId = detail.activeTurnId;
    this.selectedCodexUpdatedAt = detail.updatedAt;
    if (detail.updateMode === 'older') {
      this.prependOlderCodexMessages(detail.messages, detail.hasMoreBefore);
    } else {
      if (detail.updateMode !== 'delta') {
        this.clearCodexDetailTimers();
        this.codexDetailRetryCount = 0;
      }
      if (detail.updateMode === 'latest' && !this.codexHistoryReady) {
        this.selectedCodexMessages = [...detail.messages];
        this.codexHistoryHasMore = detail.hasMoreBefore;
        this.codexDetailVersion += 1;
        this.scheduleInitialCodexChatScroll();
      } else {
        this.mergeLatestCodexMessages(detail.messages);
      }
    }
    if (detail.activeTurnId.length > 0) {
      this.pendingCodexThreadId = detail.id;
    } else if (this.pendingCodexThreadId === detail.id) {
      this.pendingCodexThreadId = '';
    }
    this.codexDetailLoading = false;
    this.codexLoading = false;
  }

  private mergeLatestCodexMessages(incoming: CodexMessage[]): void {
    if (incoming.length === 0) {
      return;
    }
    const merged = [...this.selectedCodexMessages];
    let changed = false;
    let appended = 0;
    for (let incomingIndex = 0; incomingIndex < incoming.length; incomingIndex += 1) {
      const next = incoming[incomingIndex];
      let existingIndex = this.codexMessageIndexById(merged, next.id);
      if (existingIndex < 0 && next.role === 'user') {
        existingIndex = this.matchPendingCodexMessage(merged, next);
      }
      if (existingIndex >= 0) {
        if (!this.sameCodexMessage(merged[existingIndex], next)) {
          merged[existingIndex] = next;
          changed = true;
        }
      } else {
        merged.push(next);
        appended += 1;
        changed = true;
      }
    }
    if (!changed) {
      return;
    }
    const keepPinned = this.codexChatPinnedToBottom;
    this.selectedCodexMessages = merged;
    this.codexDetailVersion += 1;
    if (keepPinned) {
      this.scrollCodexChatToBottom(true);
    } else if (appended > 0) {
      this.codexUnreadMessages += appended;
    }
  }

  private prependOlderCodexMessages(older: CodexMessage[], hasMoreBefore: boolean): void {
    this.codexHistoryLoadingOlder = false;
    this.codexHistoryHasMore = hasMoreBefore;
    const uniqueOlder: CodexMessage[] = [];
    for (let index = 0; index < older.length; index += 1) {
      if (this.codexMessageIndexById(this.selectedCodexMessages, older[index].id) < 0) {
        uniqueOlder.push(older[index]);
      }
    }
    if (uniqueOlder.length === 0) {
      return;
    }
    this.selectedCodexMessages = [...uniqueOlder, ...this.selectedCodexMessages];
    this.codexDetailVersion += 1;
    this.scheduleCodexChatAnchorRestore(uniqueOlder.length);
  }

  private async loadOlderCodexMessages(): Promise<void> {
    if (!this.codexHistoryReady || !this.codexHistoryHasMore || this.codexHistoryLoadingOlder ||
      this.selectedCodexMessages.length === 0 || !this.isConnected) {
      return;
    }
    let firstMessageId = '';
    for (let index = 0; index < this.selectedCodexMessages.length; index += 1) {
      const message = this.selectedCodexMessages[index];
      if (!message.id.startsWith('local-')) {
        firstMessageId = message.id;
        break;
      }
    }
    if (firstMessageId.length === 0) {
      return;
    }
    this.codexHistoryLoadingOlder = true;
    this.codexChatPinnedToBottom = false;
    const requested = await remoteInputClient.requestCodexThread(
      this.selectedCodexTaskId, firstMessageId, 15);
    if (!requested) {
      this.codexHistoryLoadingOlder = false;
    }
  }

  private appendPendingCodexMessage(text: string, previewImage: string): void {
    const pending = new CodexMessage();
    pending.id = `local-${Date.now()}`;
    pending.role = 'user';
    pending.text = text.length > 0 ? text : '图片';
    pending.images = previewImage.length > 0 ? [previewImage] : [];
    pending.timestamp = Math.floor(Date.now() / 1000);
    pending.turnId = pending.id;
    pending.deliveryState = 'sending';
    this.selectedCodexMessages = [...this.selectedCodexMessages, pending];
    this.codexDetailVersion += 1;
    this.scrollCodexChatToBottom(true);
  }

  private updateLatestPendingCodexMessage(deliveryState: string): void {
    const messages = [...this.selectedCodexMessages];
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      if (messages[index].id.startsWith('local-')) {
        messages[index].deliveryState = deliveryState;
        this.selectedCodexMessages = messages;
        this.codexDetailVersion += 1;
        return;
      }
    }
  }

  private matchPendingCodexMessage(messages: CodexMessage[], incoming: CodexMessage): number {
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      const pending = messages[index];
      if (!pending.id.startsWith('local-') || pending.role !== 'user') {
        continue;
      }
      const pendingText = pending.text.trim();
      const incomingText = incoming.text.trim();
      const textMatches = pendingText === incomingText || pendingText === '图片' ||
        (pendingText.length > 0 && incomingText.includes(pendingText));
      if (textMatches && Math.abs(incoming.timestamp - pending.timestamp) <= 180) {
        return index;
      }
    }
    return -1;
  }

  private codexMessageIndexById(messages: CodexMessage[], messageId: string): number {
    for (let index = 0; index < messages.length; index += 1) {
      if (messages[index].id === messageId) {
        return index;
      }
    }
    return -1;
  }

  private scheduleInitialCodexChatScroll(): void {
    this.codexHistoryReady = false;
    this.codexChatPinnedToBottom = true;
    this.codexUnreadMessages = 0;
    if (this.codexChatScrollTimer >= 0) {
      clearTimeout(this.codexChatScrollTimer);
    }
    this.codexChatScrollTimer = setTimeout(() => {
      this.codexChatScrollTimer = -1;
      const typingOffset = this.isSelectedCodexRunning() ? 1 : 0;
      const targetIndex = Math.max(0, this.selectedCodexMessages.length - 1 + typingOffset);
      try {
        this.codexChatScroller.scrollToIndex(targetIndex, false, ScrollAlign.END);
      } catch (_error) {
      }
      this.codexHistoryReady = true;
    }, 72);
  }

  private scheduleCodexChatAnchorRestore(prependedCount: number): void {
    if (this.codexChatScrollTimer >= 0) {
      clearTimeout(this.codexChatScrollTimer);
    }
    this.codexChatScrollTimer = setTimeout(() => {
      this.codexChatScrollTimer = -1;
      try {
        this.codexChatScroller.scrollToIndex(prependedCount, false, ScrollAlign.START);
      } catch (_error) {
      }
    }, 32);
  }

  private scrollCodexChatToBottom(smooth: boolean): void {
    if (this.codexChatScrollTimer >= 0) {
      clearTimeout(this.codexChatScrollTimer);
    }
    this.codexChatPinnedToBottom = true;
    this.codexUnreadMessages = 0;
    this.codexChatScrollTimer = setTimeout(() => {
      this.codexChatScrollTimer = -1;
      const typingOffset = this.isSelectedCodexRunning() ? 1 : 0;
      const targetIndex = Math.max(0, this.selectedCodexMessages.length - 1 + typingOffset);
      try {
        this.codexChatScroller.scrollToIndex(targetIndex, smooth, ScrollAlign.END);
      } catch (_error) {
      }
    }, 24);
  }

  private sameCodexMessage(left: CodexMessage, right: CodexMessage): boolean {
    if (left.id !== right.id || left.role !== right.role || left.text !== right.text ||
      left.timestamp !== right.timestamp || left.turnId !== right.turnId ||
      left.images.length !== right.images.length || left.deliveryState !== right.deliveryState) {
      return false;
    }
    for (let imageIndex = 0; imageIndex < left.images.length; imageIndex += 1) {
      if (left.images[imageIndex] !== right.images[imageIndex]) {
        return false;
      }
    }
    return true;
  }

  private sameCodexTasks(current: CodexTask[], next: CodexTask[]): boolean {
    if (current.length !== next.length) {
      return false;
    }
    for (let index = 0; index < current.length; index += 1) {
      const left = current[index];
      const right = next[index];
      if (left.id !== right.id || left.title !== right.title ||
        left.preview !== right.preview || left.status !== right.status ||
        left.cwd !== right.cwd) {
        return false;
      }
    }
    return true;
  }

  private sameCodexQuota(current: CodexQuota, next: CodexQuota): boolean {
    return current.remainingPercent === next.remainingPercent &&
      current.usedPercent === next.usedPercent && current.resetAt === next.resetAt &&
      current.windowMinutes === next.windowMinutes &&
      current.secondaryRemainingPercent === next.secondaryRemainingPercent &&
      current.secondaryResetAt === next.secondaryResetAt && current.plan === next.plan &&
      current.credits === next.credits && current.resetCredits === next.resetCredits &&
      current.lifetimeTokens === next.lifetimeTokens;
  }

  private sameCodexMessages(current: CodexMessage[], next: CodexMessage[]): boolean {
    if (current.length !== next.length) {
      return false;
    }
    for (let index = 0; index < current.length; index += 1) {
      const left = current[index];
      const right = next[index];
      if (left.role !== right.role || left.text !== right.text ||
        left.timestamp !== right.timestamp || left.turnId !== right.turnId ||
        left.images.length !== right.images.length) {
        return false;
      }
      for (let imageIndex = 0; imageIndex < left.images.length; imageIndex += 1) {
        if (left.images[imageIndex] !== right.images[imageIndex]) {
          return false;
        }
      }
    }
    return true;
  }

  private mergeCodexTaskStatuses(tasks: CodexTask[]): CodexTask[] {
    for (let index = 0; index < tasks.length; index += 1) {
      const task = tasks[index];
      const cachedStatus = this.codexResolvedStatuses.get(task.id);
      if (task.status === 'notLoaded' && cachedStatus !== undefined) {
        task.status = cachedStatus;
      } else if (task.status !== 'notLoaded') {
        this.codexResolvedStatuses.set(task.id, task.status);
      }
    }
    return tasks;
  }

  private rememberCodexTaskStatus(threadId: string, status: string): void {
    if (threadId.length === 0 || status.length === 0) {
      return;
    }
    this.clearFinishedCodexActivity(threadId, status);
    const cachedStatus = this.codexResolvedStatuses.get(threadId);
    if (status === 'notLoaded' && cachedStatus !== undefined && cachedStatus !== 'notLoaded') {
      return;
    }
    this.codexResolvedStatuses.set(threadId, status);
    let changed = false;
    for (let index = 0; index < this.codexTasks.length; index += 1) {
      if (this.codexTasks[index].id === threadId && this.codexTasks[index].status !== status) {
        this.codexTasks[index].status = status;
        changed = true;
        break;
      }
    }
    if (changed) {
      this.codexTasks = [...this.codexTasks];
    }
  }

  private clearFinishedCodexActivity(threadId: string, status: string): void {
    if (threadId.length === 0 || !isCodexTerminalStatus(status)) {
      return;
    }
    if (this.pendingCodexThreadId === threadId) {
      this.pendingCodexThreadId = '';
    }
    if (this.selectedCodexTaskId === threadId) {
      this.selectedCodexActiveTurnId = '';
    }
  }

  private codexStatusLabel(status: string): string {
    if (status === 'active') {
      return '正在执行';
    }
    if (status === 'idle') {
      return '已完成';
    }
    if (status === 'systemError') {
      return '异常';
    }
    return '未载入';
  }

  private effectiveCodexStatus(task: CodexTask): string {
    const currentStatus = task.id === this.selectedCodexTaskId ? this.selectedCodexStatus : task.status;
    const resolvedStatus = this.resolvedCodexStatus(task.id, currentStatus);
    return resolveCodexDisplayStatus(resolvedStatus, task.id === this.pendingCodexThreadId);
  }

  private collapsedSelectedCodexStatus(): string {
    const resolvedStatus = this.resolvedCodexStatus(
      this.selectedCodexTaskId, this.selectedCodexStatus);
    return resolveCodexDisplayStatus(
      resolvedStatus, this.selectedCodexTaskId === this.pendingCodexThreadId);
  }

  private selectedCodexTaskSubtitle(): string {
    for (let index = 0; index < this.codexTasks.length; index++) {
      const task = this.codexTasks[index];
      if (task.id === this.selectedCodexTaskId) {
        return task.preview.length > 0 ? task.preview : this.shortPath(task.cwd);
      }
    }
    const cwd = this.shortPath(this.selectedCodexCwd);
    return cwd.length > 0 ? cwd : '点击展开查看任务';
  }

  private resolvedCodexStatus(threadId: string, status: string): string {
    if (status !== 'notLoaded') {
      return status;
    }
    const cachedStatus = this.codexResolvedStatuses.get(threadId);
    return cachedStatus !== undefined ? cachedStatus : status;
  }

  private isSelectedCodexRunning(): boolean {
    const resolvedStatus = this.resolvedCodexStatus(
      this.selectedCodexTaskId, this.selectedCodexStatus);
    if (isCodexTerminalStatus(resolvedStatus)) {
      return false;
    }
    return this.selectedCodexActiveTurnId.length > 0 ||
      this.pendingCodexThreadId === this.selectedCodexTaskId;
  }

  private codexStatusColor(status: string): ResourceColor {
    if (status === 'active') {
      return '#12B76A';
    }
    if (status === 'systemError') {
      return '#F04438';
    }
    if (status === 'idle') {
      return '#175CD3';
    }
    return '#98A2B3';
  }

  private codexQuotaSubtitle(): string {
    const plan = this.codexQuota.plan.trim();
    if (plan.length === 0) {
      return '当前使用窗口';
    }
    const minutes = this.codexQuota.windowMinutes;
    if (minutes >= 1440 && minutes % 1440 === 0) {
      return `${plan} · ${minutes / 1440} 天窗口`;
    }
    if (minutes >= 60 && minutes % 60 === 0) {
      return `${plan} · ${minutes / 60} 小时窗口`;
    }
    return `${plan} · ${minutes} 分钟窗口`;
  }

  private codexResetText(): string {
    if (this.codexQuota.resetAt <= 0) {
      return '重置时间暂不可用';
    }
    return `预计 ${this.formatTimestamp(this.codexQuota.resetAt)} 重置`;
  }

  private codexUsageText(): string {
    const tokens = this.codexQuota.lifetimeTokens;
    if (tokens >= 1000000000) {
      return `累计 ${(tokens / 1000000000).toFixed(1)}B tokens`;
    }
    if (tokens >= 1000000) {
      return `累计 ${(tokens / 1000000).toFixed(1)}M tokens`;
    }
    return tokens > 0 ? `累计 ${tokens} tokens` : '';
  }

  private formatTimestamp(timestamp: number): string {
    const date = new Date(timestamp * 1000);
    const month = (date.getMonth() + 1).toString().padStart(2, '0');
    const day = date.getDate().toString().padStart(2, '0');
    const hour = date.getHours().toString().padStart(2, '0');
    const minute = date.getMinutes().toString().padStart(2, '0');
    return `${month}-${day} ${hour}:${minute}`;
  }

  private formatMessageTimestamp(timestamp: number): string {
    return timestamp > 0 ? this.formatTimestamp(timestamp) : '时间未知';
  }

  private visibleCodexMessages(): CodexMessage[] {
    return this.selectedCodexMessages.slice(-this.codexConversationLimit);
  }

  private visibleCodexMessageCount(): number {
    return Math.min(this.codexConversationLimit, this.selectedCodexMessages.length);
  }

  private shortPath(path: string): string {
    if (path.length <= 44) {
      return path;
    }
    return `…${path.slice(path.length - 43)}`;
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
