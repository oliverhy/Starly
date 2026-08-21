import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { scanBarcode } from '@kit.ScanKit';
import { hdsEffect } from '@kit.UIDesignKit';
import { vibrator } from '@kit.SensorServiceKit';
import { PairingConfig, PublicPairingRequest, parsePairingUri,
  parsePublicPairingUri } from '../model/PairingConfig';
import {
  CodexActivity, CodexGoal, CodexMessage, CodexModelOption, CodexQueueItem, CodexQuota,
  CodexReasoningOption,
  CodexSnapshot, CodexTask, CodexThreadDetail,
  isCodexTerminalStatus, normalizeCodexDetailStatus, parseCodexSnapshot, parseCodexThread,
  resolveCodexDisplayStatus
} from '../model/CodexModels';
import pairingStore from '../service/PairingStore';
import pairingDiscoveryService, { DiscoveredComputer } from '../service/PairingDiscoveryService';
import remoteInputClient, {
  CodexApprovalRequest, GatewayPeerDevice, RemoteClientListener
} from '../service/RemoteInputClient';
import speechService, { SpeechListener } from '../service/SpeechService';
import imageTransferService from '../service/ImageTransferService';
import taskNotificationService from '../service/TaskNotificationService';
import notificationNavigationService from '../service/NotificationNavigationService';
import codexUiStateStore, { CodexUiState } from '../service/CodexUiStateStore';
import publicPairingService from '../service/PublicPairingService';

enum VoiceGestureAction {
  Keep,
  Send,
  Edit
}

class PopupVisibilityEvent {
  isVisible: boolean = false;
}

class PendingCodexSend {
  requestId: string = '';
  threadId: string = '';
  text: string = '';
  image: string = '';
  timer: number = -1;
}

class PageRemoteListener implements RemoteClientListener {
  private connectionCallback: (isConnected: boolean, message: string) => void;
  private acknowledgeCallback: (messageId: string, operation: string, message: string) => void;
  private errorCallback: (message: string, messageId?: string, operation?: string) => void;
  private snapshotCallback: (snapshot: CodexSnapshot) => void;
  private threadCallback: (detail: CodexThreadDetail) => void;
  private eventCallback: (event: string, threadId: string) => void;
  private queueSnapshotCallback: (items: CodexQueueItem[]) => void;
  private queueEventCallback: (item: CodexQueueItem) => void;
  private approvalCallback: (approval: CodexApprovalRequest) => void;
  private createdCallback: (threadId: string) => void;
  private gatewaySequenceCallback: (lastReceivedSeq: number) => void;
  private gatewayCryptoCallback: (sendCounter: number, peerCounter: number,
    peerCountersJson: string) => void;
  private gatewayDevicesCallback: (devices: GatewayPeerDevice[], selectedDeviceId: string) => void;
  private gatewayIdentityCallback: (privateKey: string, publicKey: string,
    peerKeysJson: string, sessionToken: string, deviceCredential: string) => void;

  constructor(connectionCallback: (isConnected: boolean, message: string) => void,
    acknowledgeCallback: (messageId: string, operation: string, message: string) => void,
    errorCallback: (message: string, messageId?: string, operation?: string) => void,
    snapshotCallback: (snapshot: CodexSnapshot) => void,
    threadCallback: (detail: CodexThreadDetail) => void,
    eventCallback: (event: string, threadId: string) => void,
    queueSnapshotCallback: (items: CodexQueueItem[]) => void,
    queueEventCallback: (item: CodexQueueItem) => void,
    approvalCallback: (approval: CodexApprovalRequest) => void,
    createdCallback: (threadId: string) => void,
    gatewaySequenceCallback: (lastReceivedSeq: number) => void,
    gatewayCryptoCallback: (sendCounter: number, peerCounter: number,
      peerCountersJson: string) => void,
    gatewayDevicesCallback: (devices: GatewayPeerDevice[], selectedDeviceId: string) => void,
    gatewayIdentityCallback: (privateKey: string, publicKey: string,
      peerKeysJson: string, sessionToken: string, deviceCredential: string) => void) {
    this.connectionCallback = connectionCallback;
    this.acknowledgeCallback = acknowledgeCallback;
    this.errorCallback = errorCallback;
    this.snapshotCallback = snapshotCallback;
    this.threadCallback = threadCallback;
    this.eventCallback = eventCallback;
    this.queueSnapshotCallback = queueSnapshotCallback;
    this.queueEventCallback = queueEventCallback;
    this.approvalCallback = approvalCallback;
    this.createdCallback = createdCallback;
    this.gatewaySequenceCallback = gatewaySequenceCallback;
    this.gatewayCryptoCallback = gatewayCryptoCallback;
    this.gatewayDevicesCallback = gatewayDevicesCallback;
    this.gatewayIdentityCallback = gatewayIdentityCallback;
  }

  onConnectionChanged(isConnected: boolean, message: string): void {
    this.connectionCallback(isConnected, message);
  }

  onAcknowledged(messageId: string, operation: string, message: string): void {
    this.acknowledgeCallback(messageId, operation, message);
  }

  onError(message: string, messageId?: string, operation?: string): void {
    this.errorCallback(message, messageId, operation);
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

  onCodexQueueSnapshot(items: CodexQueueItem[]): void {
    this.queueSnapshotCallback(items);
  }

  onCodexQueueEvent(item: CodexQueueItem): void {
    this.queueEventCallback(item);
  }

  onCodexApproval(approval: CodexApprovalRequest): void {
    this.approvalCallback(approval);
  }

  onCodexCreated(threadId: string): void {
    this.createdCallback(threadId);
  }

  onGatewaySequence(lastReceivedSeq: number): void {
    this.gatewaySequenceCallback(lastReceivedSeq);
  }

  onGatewayCryptoCounters(sendCounter: number, peerCounter: number,
    peerCountersJson: string): void {
    this.gatewayCryptoCallback(sendCounter, peerCounter, peerCountersJson);
  }

  onGatewayDevices(devices: GatewayPeerDevice[], selectedDeviceId: string): void {
    this.gatewayDevicesCallback(devices, selectedDeviceId);
  }

  onGatewayIdentity(privateKey: string, publicKey: string, peerKeysJson: string,
    sessionToken: string, deviceCredential: string): void {
    this.gatewayIdentityCallback(privateKey, publicKey, peerKeysJson, sessionToken,
      deviceCredential);
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
  @State connectionMode: string = 'lan';
  @State activeConnectionTransport: string = '';
  private gatewayUrl: string = '';
  private gatewayToken: string = '';
  private gatewayPairingId: string = '';
  private phoneDeviceId: string = '';
  private gatewayLastReceivedSeq: number = 0;
  private gatewaySendCounter: number = 0;
  private gatewayPeerCounter: number = 0;
  private gatewayPeerCountersJson: string = '{}';
  private gatewayPrivateKey: string = '';
  private gatewayPublicKey: string = '';
  private gatewayPeerPublicKeysJson: string = '{}';
  private gatewaySessionToken: string = '';
  private gatewayDeviceCredential: string = '';
  @State gatewayBridgeDevices: GatewayPeerDevice[] = [];
  @State selectedGatewayBridgeId: string = '';
  @State gatewayDeviceName: string = '';
  @State gatewayRevokeConfirm: boolean = false;
  @State gatewaySwitchConfirmId: string = '';
  @State draft: string = '';
  @State isConnected: boolean = false;
  @State isPairingExpanded: boolean = false;
  @State isPairingOverlayMounted: boolean = false;
  @State pairingPanelOffsetX: number = 0;
  @State pairingPanelOffsetY: number = 0;
  @State pairingPanelHeight: number = 320;
  @State discoveredComputers: DiscoveredComputer[] = [];
  @State selectedComputerKey: string = '';
  @State pairingCode: string = '';
  @State isDiscoveringComputers: boolean = false;
  @State isPairingWithCode: boolean = false;
  @State pairingNetworkMode: string = 'lan';
  @State publicPairingCode: string = '';
  @State publicPairingStatus: string = '在电脑端生成公网配对码后，手机扫码或手动输入';
  @State publicPairingVerification: string = '';
  @State isPublicPairing: boolean = false;
  @State pairingDiscoveryMessage: string = '正在查找同一局域网内的电脑…';
  @State showManualPairing: boolean = false;
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
  @State codexModels: CodexModelOption[] = [];
  @State codexRelativeTimeNow: number = Date.now();
  @State codexInitialSyncPending: boolean = true;
  private pendingNotificationThreadId: string = '';
  @State codexSearchText: string = '';
  @State selectedCodexProject: string = '';
  @State codexNewTaskMode: boolean = false;
  @State codexSettingsMenu: string = '';
  @State selectedCodexModel: string = '';
  @State selectedCodexEffort: string = 'medium';
  @State codexPermissionMode: string = 'default';
  @State selectedCodexServiceTier: string = '';
  @State codexDeliveryMode: string = 'background';
  @State desktopSubmitMode: string = 'enter';
  @State codexFullAccessConfirm: boolean = false;
  @State codexVoiceListening: boolean = false;
  @State keyboardInset: number = 0;
  @State showArchivedCodexTasks: boolean = false;
  @State codexArchivedTasksLoaded: boolean = false;
  @State pinnedCodexThreadIds: string[] = [];
  @State expandedCodexProjects: string[] = [];
  @State codexTaskMenuId: string = '';
  @State codexTaskRenameMode: boolean = false;
  @State codexTaskRenameText: string = '';
  @State codexTaskMenuX: number = 12;
  @State codexTaskMenuY: number = 120;
  @State codexTaskMenuExpanded: boolean = false;
  @State codexQueueItems: CodexQueueItem[] = [];
  @State codexQueueMenuId: string = '';
  @State codexQueueMenuX: number = 12;
  @State codexQueueMenuY: number = 120;
  @State codexQueueMenuExpanded: boolean = false;
  @State areCodexTasksExpanded: boolean = true;
  @State codexTaskDisplayLimit: number = 10;
  @State selectedCodexTaskId: string = '';
  @State selectedCodexTitle: string = '';
  @State selectedCodexCwd: string = '';
  @State selectedCodexArchived: boolean = false;
  @State selectedCodexStatus: string = 'notLoaded';
  @State selectedCodexActiveTurnId: string = '';
  @State selectedCodexMessages: CodexMessage[] = [];
  @State selectedCodexActivities: CodexActivity[] = [];
  @State selectedCodexGoal: CodexGoal = new CodexGoal();
  @State codexGoalExpanded: boolean = false;
  @State codexActivityExpanded: boolean = false;
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
  @State approvalId: string = '';
  @State approvalKind: string = '';
  @State approvalCommand: string = '';
  @State approvalCwd: string = '';
  @State approvalReason: string = '';
  @State approvalPermissions: string = '';
  @State approvalRiskReason: string = '';
  @State approvalHighRisk: boolean = false;
  @State approvalSecondConfirm: boolean = false;
  @State voiceGestureAction: VoiceGestureAction = VoiceGestureAction.Keep;
  private voiceStartX: number = 0;
  private voiceStartY: number = 0;
  private voicePressSequence: number = 0;
  private pendingVoiceSend: boolean = false;
  private codexVoiceTarget: boolean = false;
  private lastCodexTaskTapId: string = '';
  private lastCodexTaskTapAt: number = 0;
  private codexAutoRefreshTimer: number = -1;
  private codexAutoRefreshInFlight: boolean = false;
  private codexReconcileTick: number = 0;
  private pendingDraftSendId: string = '';
  private pendingCodexSends: Map<string, PendingCodexSend> = new Map<string, PendingCodexSend>();
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
  private isCodexDetailTouching: boolean = false;
  private isMainSectionSwipeBlocked: boolean = false;
  private pairingOverlayShowTimer: number = -1;
  private pairingPanelDragStartX: number = 0;
  private pairingPanelDragStartY: number = 0;
  private closePairingAfterConnect: boolean = false;
  private approvalSecondConfirmTimer: number = -1;
  private codexUiStateSaveTimer: number = -1;
  private gatewaySwitchConfirmTimer: number = -1;
  private keyboardChatScrollTimer: number = -1;
  private codexTaskMenuAnimationTimer: number = -1;
  private codexQueueMenuAnimationTimer: number = -1;
  private keyboardHeightListener: ((height: number) => void) | null = null;
  private codexUiComputerKey: string = 'unpaired';
  private codexComputerSwitchGeneration: number = 0;
  private restoredCodexTaskId: string = '';
  private codexCacheRestored: boolean = false;
  private codexLastSeenMessageIds: Record<string, string> = {};
  @State codexUnreadCounts: Record<string, number> = {};
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
    this.registerKeyboardHeightListener();
    notificationNavigationService.setListener((threadId: string): void => {
      this.handleNotificationTaskOpen(threadId);
    });
    remoteInputClient.setListener(new PageRemoteListener(
      (isConnected: boolean, message: string): void => {
        this.isConnected = isConnected;
        this.activeConnectionTransport = remoteInputClient.getActiveTransport();
        this.statusText = message;
        this.statusIsError = false;
        if (isConnected) {
          this.openPendingNotificationTask();
          if (this.mainSection === 'codex') {
            this.codexInitialSyncPending = true;
            this.startCodexAutoRefresh();
          }
          if (this.closePairingAfterConnect) {
            this.closePairingAfterConnect = false;
            this.closePairingPanel();
          }
        } else {
          this.stopCodexAutoRefresh();
          this.clearCodexDetailTimers();
        }
      },
      (messageId: string, operation: string, message: string): void => {
        this.lastAction = message;
        if (this.isCodexSendOperation(operation) && messageId.length > 0) {
          const pending = this.pendingCodexSends.get(messageId);
          this.updatePendingCodexMessage(messageId, 'sent');
          this.clearAcknowledgedCodexComposer(messageId);
          const acknowledgedThreadId = pending?.threadId ?? this.selectedCodexTaskId;
          this.statusText = acknowledgedThreadId.length > 0 ?
            '指令已加入电脑队列' : '电脑已收到指令';
        } else if (operation === 'input' && messageId === this.pendingDraftSendId) {
          this.draft = '';
          this.pendingDraftSendId = '';
        }
        this.statusIsError = false;
      },
      (message: string, messageId?: string, operation?: string): void => {
        const shouldRetryCodexDetail = this.codexDetailLoading &&
          this.selectedCodexTaskId.length > 0 && this.mainSection === 'codex';
        this.statusText = message;
        this.statusIsError = true;
        if (messageId !== undefined && messageId.length > 0 &&
          this.pendingCodexSends.has(messageId) && this.isCodexSendOperation(operation ?? '')) {
          this.updatePendingCodexMessage(messageId, 'failed');
          this.clearPendingCodexAcknowledgement(messageId);
        } else if (message.includes('Codex')) {
          this.pendingCodexThreadId = '';
          this.updateLatestPendingCodexMessage('failed');
        }
        if (messageId !== undefined && messageId === this.pendingDraftSendId) {
          this.pendingDraftSendId = '';
        }
        this.codexHistoryLoadingOlder = false;
        this.codexDetailLoading = false;
        this.codexLoading = false;
        if (shouldRetryCodexDetail) {
          this.scheduleCodexDetailRetry(this.selectedCodexTaskId, 450);
        }
      },
      (snapshot: CodexSnapshot): void => {
        const wasCacheRestored = this.codexCacheRestored;
        this.codexCacheRestored = false;
        this.codexInitialSyncPending = false;
        this.codexAvailable = snapshot.available;
        this.codexError = snapshot.error;
        if (snapshot.models.length > 0) {
          this.codexModels = snapshot.models;
          if (this.selectedCodexModel.length === 0 || !snapshot.models.some(
            (model: CodexModelOption): boolean => model.model === this.selectedCodexModel)) {
            const preferred = snapshot.models.find(
              (model: CodexModelOption): boolean => model.isDefault) ?? snapshot.models[0];
            this.selectedCodexModel = preferred.model;
            this.selectedCodexEffort = preferred.defaultReasoningEffort || 'medium';
            this.scheduleCodexUiStateSave();
          }
        }
        if (!this.sameCodexQuota(this.codexQuota, snapshot.quota)) {
          this.codexQuota = snapshot.quota;
        }
        const mergedTasks = this.mergeCodexTaskStatuses(snapshot.threads);
        this.codexArchivedTasksLoaded = snapshot.threads.some(
          (task: CodexTask): boolean => task.archived);
        if (!this.sameCodexTasks(this.codexTasks, mergedTasks)) {
          this.codexTasks = mergedTasks;
        }
        if (this.selectedCodexProject.length > 0 &&
          this.selectedCodexProject !== '__starly_chats__' &&
          !this.codexProjects().includes(this.selectedCodexProject)) {
          this.selectedCodexProject = '';
          this.scheduleCodexUiStateSave();
        }
        for (let index = 0; index < mergedTasks.length; index += 1) {
          const task = mergedTasks[index];
          this.clearFinishedCodexActivity(task.id, task.status);
          if (task.id === this.selectedCodexTaskId) {
            const contentChanged = this.selectedCodexUpdatedAt > 0 &&
              task.updatedAt > this.selectedCodexUpdatedAt;
            this.selectedCodexUpdatedAt = task.updatedAt;
            this.selectedCodexStatus = this.resolvedCodexStatus(task.id, task.status);
            if (contentChanged && this.isCodexConversationOpen) {
              this.requestSelectedCodexThread();
            }
            break;
          }
        }
        this.codexLoading = false;
        if (this.selectedCodexTaskId.length > 0 && !snapshot.threads.some(
          (task: CodexTask): boolean => task.id === this.selectedCodexTaskId)) {
          this.selectedCodexTaskId = '';
          this.selectedCodexMessages = [];
          this.selectedCodexActivities = [];
          this.selectedCodexActiveTurnId = '';
        }
        if (this.selectedCodexTaskId.length === 0 && snapshot.threads.length > 0) {
          const restoredExists = snapshot.threads.some(
            (task: CodexTask): boolean => task.id === this.restoredCodexTaskId);
          const nextThreadId = restoredExists ? this.restoredCodexTaskId : snapshot.threads[0].id;
          this.restoredCodexTaskId = '';
          this.selectCodexTask(nextThreadId);
        } else if (wasCacheRestored && this.selectedCodexTaskId.length > 0) {
          this.requestSelectedCodexThread(true);
        }
        this.scheduleCodexUiStateSave();
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
          taskNotificationService.publish(
            'Codex 任务已完成', this.codexTaskNotificationLabel(threadId),
            `complete-${threadId}-${Date.now()}`, threadId);
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
          shouldRefreshThread = threadId === this.selectedCodexTaskId;
        } else if (event === 'turn/failed' && threadId.length > 0) {
          taskNotificationService.publish(
            'Codex 任务失败', this.codexTaskNotificationLabel(threadId),
            `failed-${threadId}-${Date.now()}`, threadId);
          this.rememberCodexTaskStatus(threadId, 'systemError');
          if (threadId === this.selectedCodexTaskId) {
            this.selectedCodexStatus = 'systemError';
          }
          shouldRefreshSnapshot = true;
        } else if (event === 'codex/refreshReady') {
          shouldRefreshThread = true;
        } else if (event === 'thread/archived' || event === 'thread/unarchived' ||
          event === 'thread/renamed') {
          shouldRefreshSnapshot = true;
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
      },
      (items: CodexQueueItem[]): void => {
        this.applyCodexQueueSnapshot(items);
      },
      (item: CodexQueueItem): void => {
        this.applyCodexQueueEvent(item);
      },
      (approval: CodexApprovalRequest): void => {
        this.approvalId = approval.id;
        this.approvalKind = approval.method;
        this.approvalCommand = approval.command;
        this.approvalCwd = approval.cwd;
        this.approvalReason = approval.reason;
        this.approvalPermissions = approval.permissions;
        this.approvalRiskReason = approval.riskReason;
        this.approvalHighRisk = approval.highRisk;
        this.clearApprovalSecondConfirmTimer();
        this.approvalSecondConfirm = false;
        this.statusText = 'Codex 正在等待手机审批';
        this.statusIsError = approval.highRisk;
        taskNotificationService.publish(
          'Codex 等待审批',
          approval.highRisk ? '高风险操作，请打开 Starly 查看并处理' : '请打开 Starly 查看并处理',
          `approval-${approval.id}`, approval.threadId);
      },
      (threadId: string): void => {
        if (threadId.length === 0) {
          return;
        }
        const pendingText = this.codexCommand.trim();
        const pendingImage = this.codexImagePreviewUri;
        this.codexCommand = '';
        this.codexNewTaskMode = false;
        this.clearCodexImage();
        this.pendingCodexThreadId = threadId;
        this.statusText = '新 Codex 任务已创建';
        this.statusIsError = false;
        remoteInputClient.requestCodexSnapshot();
        setTimeout(() => this.selectCodexTask(threadId, pendingText, pendingImage), 500);
      },
      (lastReceivedSeq: number): void => {
        this.gatewayLastReceivedSeq = Math.max(this.gatewayLastReceivedSeq, lastReceivedSeq);
        const config = this.readConfigFromForm();
        pairingStore.save(this.getContext(), config).catch((): void => {});
      },
      (sendCounter: number, peerCounter: number, peerCountersJson: string): void => {
        this.gatewaySendCounter = Math.max(this.gatewaySendCounter, sendCounter);
        this.gatewayPeerCounter = Math.max(this.gatewayPeerCounter, peerCounter);
        this.gatewayPeerCountersJson = peerCountersJson;
        const config = this.readConfigFromForm();
        pairingStore.save(this.getContext(), config).catch((): void => {});
      },
      (devices: GatewayPeerDevice[], selectedDeviceId: string): void => {
        this.gatewayBridgeDevices = devices;
        this.selectedGatewayBridgeId = selectedDeviceId;
        const selected = devices.find(
          (device: GatewayPeerDevice): boolean => device.deviceId === selectedDeviceId);
        this.gatewayDeviceName = selected?.displayName ?? '';
        this.gatewayRevokeConfirm = false;
        this.gatewaySwitchConfirmId = '';
        const nextComputerKey = this.gatewayCodexUiComputerKey(selectedDeviceId);
        if (nextComputerKey !== this.codexUiComputerKey) {
          this.activateCodexComputer(nextComputerKey);
        }
        const config = this.readConfigFromForm();
        pairingStore.save(this.getContext(), config).catch((): void => {});
      },
      (privateKey: string, publicKey: string, peerKeysJson: string,
        sessionToken: string, deviceCredential: string): void => {
        this.gatewayPrivateKey = privateKey;
        this.gatewayPublicKey = publicKey;
        this.gatewayPeerPublicKeysJson = peerKeysJson;
        this.gatewaySessionToken = sessionToken;
        this.gatewayDeviceCredential = deviceCredential;
        const config = this.readConfigFromForm();
        pairingStore.save(this.getContext(), config).catch((): void => {});
      }
    ));
    speechService.setListener(new PageSpeechListener(
      (isListening: boolean, message: string): void => {
        if (this.codexVoiceTarget) {
          this.codexVoiceListening = isListening;
          if (!isListening && message === '识别完成') {
            this.codexVoiceTarget = false;
          }
        }
        this.statusText = message;
        this.statusIsError = false;
        if (!isListening && message === '识别完成' && this.pendingVoiceSend) {
          this.pendingVoiceSend = false;
          this.sendDraft();
        }
      },
      (text: string, isFinal: boolean): void => {
        if (this.codexVoiceTarget) {
          this.codexCommand = text;
        } else {
          this.draft = text;
        }
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
    this.initializePage();
  }

  aboutToDisappear(): void {
    this.unregisterKeyboardHeightListener();
    this.stopCodexAutoRefresh();
    if (this.pairingOverlayShowTimer >= 0) {
      clearTimeout(this.pairingOverlayShowTimer);
      this.pairingOverlayShowTimer = -1;
    }
    if (this.codexChatScrollTimer >= 0) {
      clearTimeout(this.codexChatScrollTimer);
      this.codexChatScrollTimer = -1;
    }
    if (this.keyboardChatScrollTimer >= 0) {
      clearTimeout(this.keyboardChatScrollTimer);
      this.keyboardChatScrollTimer = -1;
    }
    if (this.codexTaskMenuAnimationTimer >= 0) {
      clearTimeout(this.codexTaskMenuAnimationTimer);
      this.codexTaskMenuAnimationTimer = -1;
    }
    this.clearAllPendingCodexAcknowledgements();
    if (this.codexQueueMenuAnimationTimer >= 0) {
      clearTimeout(this.codexQueueMenuAnimationTimer);
      this.codexQueueMenuAnimationTimer = -1;
    }
    this.clearApprovalSecondConfirmTimer();
    this.clearGatewaySwitchConfirmTimer();
    this.flushCodexUiState();
    notificationNavigationService.setListener(null);
    remoteInputClient.setListener(null);
    speechService.setListener(null);
  }

  onBackPress(): boolean {
    // Close the deepest visible layer first. Returning false is reserved for
    // the real home level, where HarmonyOS may minimize/close the ability.
    if (this.codexQueueMenuId.length > 0) {
      this.closeCodexQueueMenu();
      return true;
    }
    if (this.codexTaskRenameMode && this.codexTaskMenuId.length > 0) {
      this.codexTaskRenameMode = false;
      this.codexTaskRenameText = '';
      this.codexTaskMenuExpanded = true;
      return true;
    }
    if (this.codexTaskMenuId.length > 0) {
      this.closeCodexTaskMenu();
      return true;
    }
    if (this.approvalId.length > 0) {
      if (this.approvalSecondConfirm) {
        this.clearApprovalSecondConfirmTimer();
        this.approvalSecondConfirm = false;
      } else {
        this.statusText = '请先允许或拒绝当前审批';
        this.statusIsError = true;
      }
      return true;
    }
    if (this.isPairingOverlayMounted) {
      if (this.showManualPairing) {
        this.showManualPairing = false;
      } else {
        this.closePairingPanel();
      }
      return true;
    }
    if (this.codexSettingsMenu.length > 0 || this.codexFullAccessConfirm) {
      this.codexSettingsMenu = '';
      this.codexFullAccessConfirm = false;
      return true;
    }
    if (this.isCodexConversationOpen) {
      this.closeRemoteCodexConversation();
      return true;
    }
    if (this.selectedCodexProject.length > 0) {
      this.selectedCodexProject = '';
      return true;
    }
    return false;
  }

  private registerKeyboardHeightListener(): void {
    if (this.keyboardHeightListener !== null) {
      return;
    }
    this.keyboardHeightListener = (height: number): void => {
      this.keyboardInset = Math.max(0, px2vp(height));
      if (height <= 0 || !this.isCodexConversationOpen) {
        return;
      }
      if (this.keyboardChatScrollTimer >= 0) {
        clearTimeout(this.keyboardChatScrollTimer);
      }
      // Wait until the keyboard/inset animation has finished, then anchor the
      // latest message directly above the composer.
      this.keyboardChatScrollTimer = setTimeout(() => {
        this.keyboardChatScrollTimer = -1;
        if (this.keyboardInset > 0 && this.isCodexConversationOpen) {
          this.scrollCodexChatToBottom(false);
        }
      }, 180);
    };
    const listener = this.keyboardHeightListener;
    window.getLastWindow(this.getContext()).then((mainWindow: window.Window): void => {
      mainWindow.on('keyboardHeightChange', listener);
    }).catch((): void => {});
  }

  private unregisterKeyboardHeightListener(): void {
    const listener = this.keyboardHeightListener;
    if (listener === null) {
      return;
    }
    this.keyboardHeightListener = null;
    this.keyboardInset = 0;
    if (this.keyboardChatScrollTimer >= 0) {
      clearTimeout(this.keyboardChatScrollTimer);
      this.keyboardChatScrollTimer = -1;
    }
    window.getLastWindow(this.getContext()).then((mainWindow: window.Window): void => {
      mainWindow.off('keyboardHeightChange', listener);
    }).catch((): void => {});
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
      if (this.approvalId.length > 0) {
        this.buildApprovalOverlay();
      }
      if (this.codexTaskMenuId.length > 0) {
        this.buildCodexTaskMenuOverlay();
      }
      if (this.codexQueueMenuId.length > 0 && !this.isCodexConversationOpen) {
        this.buildCodexQueueMenuOverlay();
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
    // Phones keep the full-width Remote flow. Wide screens reuse that same
    // Remote module in a compact left pane and show the selected chat beside it.
    if (section === 'codex' && this.useTwoPaneCodexLayout()) {
      Row() {
        this.buildDesktopCodexWorkspace();
      }
      .width('100%')
      .height('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ top: 134, bottom: 18 })
      .clip(true)
      .translate({ x: this.mainSectionPageTranslate(section) })
    } else if (section === 'codex') {
      Column() {
        this.buildCodexRemoteHome(false)
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 126, bottom: 12 })
      .clip(true)
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
      .clip(true)
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
          .backgroundColor('#705B8CFF')
          .blur(138)
          .position({ x: -150, y: -170 })
        Column()
          .width(500)
          .height(500)
          .borderRadius(250)
          .backgroundColor('#64BB84FF')
          .blur(150)
          .position({ x: '66%', y: 90 })
        Column()
          .width(600)
          .height(600)
          .borderRadius(300)
          .backgroundColor('#58A36BFF')
          .blur(160)
          .position({ x: -190, y: 560 })
        Column()
          .width(520)
          .height(520)
          .borderRadius(260)
          .backgroundColor('#4CD4B5FF')
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
      Text(this.titleConnectionIcon())
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.titleConnectionColor())
      Text(this.titleConnectionLabel())
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
    }
    .width(108)
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

  private hasPairingConfiguration(): boolean {
    return this.readConfigFromForm().isComplete();
  }

  private titleConnectionLabel(): string {
    if (!this.hasPairingConfiguration()) {
      return '未配对';
    }
    if (this.activeConnectionTransport === 'gateway') {
      if (!this.isConnected) {
        return '中继未连接';
      }
      return this.selectedGatewayDeviceOnline() ? '电脑在线' : '电脑离线';
    }
    if (this.isConnected) {
      return '电脑在线';
    }
    return this.connectionMode === 'lan' ? '电脑离线' : '中继未连接';
  }

  private titleConnectionIcon(): string {
    const label = this.titleConnectionLabel();
    if (label === '电脑在线') return '✓';
    if (label === '电脑离线') return '●';
    if (label === '中继未连接') return '!';
    return '•';
  }

  private titleConnectionColor(): string {
    const label = this.titleConnectionLabel();
    if (label === '电脑在线') return '#067647';
    if (label === '电脑离线') return '#B54708';
    if (label === '中继未连接') return '#B42318';
    return '#667085';
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
      Scroll() {
        Column({ space: 10 }) {
          Column({ space: 8 }) {
            Row() {
              Column({ space: 2 }) {
                Text('Codex 发送方式')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('选择手机指令如何进入电脑端 Codex')
                  .fontSize(10)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
            }
            .width('100%')
            Row({ space: 8 }) {
              Button('默认模式')
                .layoutWeight(1)
                .height(38)
                .fontSize(12)
                .fontColor(this.codexDeliveryMode === 'background' ? Color.White : '#FF344054')
                .backgroundColor(this.codexDeliveryMode === 'background' ? '#FF175CD3' :
                  $r('app.color.input_background'))
                .borderRadius(12)
                .onClick(() => this.selectCodexDeliveryMode('background'))
              Button('桌面输入框')
                .layoutWeight(1)
                .height(38)
                .fontSize(12)
                .fontColor(this.codexDeliveryMode === 'desktop' ? Color.White : '#FF344054')
                .backgroundColor(this.codexDeliveryMode === 'desktop' ? '#FF175CD3' :
                  $r('app.color.input_background'))
                .borderRadius(12)
                .onClick(() => this.selectCodexDeliveryMode('desktop'))
            }
            .width('100%')
            Text(this.codexDeliveryMode === 'desktop' ?
              '打开对应桌面任务，定位模型、推理强度和权限后，通过输入框发送文字或图片。新建任务仍使用默认模式。' :
              '通过 Starly 的后台可靠通道发送，电脑端可能需要刷新后才能显示。')
              .width('100%')
              .fontSize(10)
              .fontColor(this.codexDeliveryMode === 'desktop' ? '#FF175CD3' :
                $r('app.color.text_secondary'))
              .lineHeight(15)
            if (this.codexDeliveryMode === 'desktop') {
              Column({ space: 6 }) {
                Text('发送按钮快捷键')
                  .width('100%')
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Row({ space: 8 }) {
                  Button('回车发送')
                    .layoutWeight(1)
                    .height(34)
                    .fontSize(11)
                    .fontColor(this.desktopSubmitMode === 'enter' ? Color.White : '#FF344054')
                    .backgroundColor(this.desktopSubmitMode === 'enter' ? '#FF175CD3' :
                      $r('app.color.input_background'))
                    .borderRadius(11)
                    .onClick(() => this.selectDesktopSubmitMode('enter'))
                  Button('Ctrl + 回车发送')
                    .layoutWeight(1)
                    .height(34)
                    .fontSize(11)
                    .fontColor(this.desktopSubmitMode === 'ctrl_enter' ? Color.White : '#FF344054')
                    .backgroundColor(this.desktopSubmitMode === 'ctrl_enter' ? '#FF175CD3' :
                      $r('app.color.input_background'))
                    .borderRadius(11)
                    .onClick(() => this.selectDesktopSubmitMode('ctrl_enter'))
                }
                .width('100%')
              }
              .width('100%')
              .padding({ top: 2 })
            }
          }
          .width('100%')
          .padding(12)
          .backgroundColor('#12FFFFFF')
          .border({ width: 1, color: $r('app.color.glass_border') })
          .borderRadius(14)

          Column({ space: 7 }) {
            Row() {
              Text('连接通道')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Blank()
              Text(this.activeConnectionTransport === 'lan' ? '当前：局域网直连' :
                (this.activeConnectionTransport === 'gateway' ? '当前：公网中继' : '当前：未连接'))
                .fontSize(10)
                .fontColor(this.isConnected ? '#FF067647' : $r('app.color.text_secondary'))
            }
            .width('100%')
            Row({ space: 6 }) {
              Button('自动')
                .layoutWeight(1)
                .height(34)
                .fontSize(11)
                .fontColor(this.connectionMode === 'auto' ? Color.White : '#FF344054')
                .backgroundColor(this.connectionMode === 'auto' ? '#FF175CD3' :
                  $r('app.color.input_background'))
                .borderRadius(11)
                .onClick(() => this.selectConnectionMode('auto'))
              Button('仅局域网')
                .layoutWeight(1)
                .height(34)
                .fontSize(11)
                .fontColor(this.connectionMode === 'lan' ? Color.White : '#FF344054')
                .backgroundColor(this.connectionMode === 'lan' ? '#FF175CD3' :
                  $r('app.color.input_background'))
                .borderRadius(11)
                .onClick(() => this.selectConnectionMode('lan'))
              Button('仅公网')
                .layoutWeight(1)
                .height(34)
                .fontSize(11)
                .fontColor(this.connectionMode === 'gateway' ? Color.White : '#FF344054')
                .backgroundColor(this.connectionMode === 'gateway' ? '#FF175CD3' :
                  $r('app.color.input_background'))
                .borderRadius(11)
                .onClick(() => this.selectConnectionMode('gateway'))
            }
            .width('100%')
            Text('自动模式优先使用局域网；局域网不可用时切换公网，恢复后自动切回。')
              .width('100%')
              .fontSize(10)
              .lineHeight(15)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding(12)
          .backgroundColor('#12FFFFFF')
          .border({ width: 1, color: $r('app.color.glass_border') })
          .borderRadius(14)

          Row({ space: 8 }) {
            Button('局域网配对')
              .layoutWeight(1)
              .height(38)
              .fontSize(12)
              .fontColor(this.pairingNetworkMode === 'lan' ? Color.White : '#FF344054')
              .backgroundColor(this.pairingNetworkMode === 'lan' ? '#FF175CD3' :
                $r('app.color.input_background'))
              .borderRadius(12)
              .onClick(() => this.selectPairingNetworkMode('lan'))
            Button('公网配对')
              .layoutWeight(1)
              .height(38)
              .fontSize(12)
              .fontColor(this.pairingNetworkMode === 'public' ? Color.White : '#FF344054')
              .backgroundColor(this.pairingNetworkMode === 'public' ? '#FF175CD3' :
                $r('app.color.input_background'))
              .borderRadius(12)
              .onClick(() => this.selectPairingNetworkMode('public'))
          }
          .width('100%')

          if (this.pairingNetworkMode === 'lan') {
            Row({ space: 8 }) {
            Text(this.pairingDiscoveryMessage)
              .layoutWeight(1)
              .fontSize(12)
              .fontColor(this.isDiscoveringComputers ? '#175CD3' : $r('app.color.text_secondary'))
              .maxLines(2)
            Button(this.isDiscoveringComputers ? '搜索中…' : '重新搜索')
              .height(34)
              .fontSize(12)
              .fontColor('#175CD3')
              .backgroundColor('#EAF2FF')
              .borderRadius(17)
              .enabled(!this.isDiscoveringComputers && !this.isPairingWithCode)
              .onClick(() => this.discoverPairingComputers())
          }
          .width('100%')

          if (this.discoveredComputers.length === 0 && !this.isDiscoveringComputers) {
            Text('暂未发现电脑。请确认桥接程序已启动，并且双方连接同一个局域网。')
              .width('100%')
              .padding(12)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.input_background'))
              .borderRadius(12)
          }
          ForEach(this.discoveredComputers, (computer: DiscoveredComputer) => {
            Row({ space: 10 }) {
              Stack({ alignContent: Alignment.Center }) {
                Text('')
                  .width(18)
                  .height(18)
                  .borderRadius(9)
                  .border({ width: 1, color: '#75175CD3' })
                if (this.selectedComputerKey === computer.key()) {
                  Text('')
                    .width(9)
                    .height(9)
                    .borderRadius(5)
                    .backgroundColor('#175CD3')
                }
              }
              Column({ space: 2 }) {
                Text(computer.name)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text(`${computer.host}:${computer.port}`)
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
              Text(this.selectedComputerKey === computer.key() ? '已选择' : '选择')
                .fontSize(11)
                .fontColor('#175CD3')
            }
            .width('100%')
            .padding(12)
            .backgroundColor(this.selectedComputerKey === computer.key() ? '#DDEBFF' :
              $r('app.color.input_background'))
            .border({ width: 1, color: this.selectedComputerKey === computer.key() ? '#73175CD3' :
              $r('app.color.glass_border') })
            .borderRadius(14)
            .onClick(() => {
              this.selectedComputerKey = computer.key();
            })
          }, (computer: DiscoveredComputer): string => computer.key())

          TextInput({ text: this.pairingCode, placeholder: '输入电脑端显示的 6 位配对码' })
            .height(48)
            .type(InputType.Number)
            .maxLength(6)
            .fontSize(18)
            .letterSpacing(4)
            .backgroundColor($r('app.color.input_background'))
            .border({ width: 1, color: $r('app.color.glass_border') })
            .borderRadius(12)
            .onChange((value: string) => {
              this.pairingCode = value;
            })
          Button(this.isPairingWithCode ? '正在配对…' : '配对并连接')
            .width('100%')
            .height(46)
            .fontColor(Color.White)
            .backgroundColor('#175CD3')
            .borderRadius(12)
            .enabled(this.selectedComputerKey.length > 0 && this.pairingCode.length === 6 &&
              !this.isPairingWithCode && !this.isDiscoveringComputers)
            .onClick(() => this.pairSelectedComputer())

          Row() {
            Text('扫码或手动输入')
              .fontSize(12)
              .fontColor('#175CD3')
            Blank()
            Text(this.showManualPairing ? '收起⌃' : '展开⌄')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .onClick(() => {
            this.showManualPairing = !this.showManualPairing;
          })

            if (this.showManualPairing) {
            if (canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')) {
              Button('扫描原有配对二维码')
                .width('100%')
                .height(40)
                .fontSize(13)
                .fontColor('#175CD3')
                .backgroundColor('#EAF2FF')
                .borderRadius(12)
                .onClick(() => this.scanPairingCode())
            }
            TextInput({ text: this.host, placeholder: '电脑 IP，例如 192.168.1.20' })
              .height(44)
              .backgroundColor($r('app.color.input_background'))
              .border({ width: 1, color: $r('app.color.glass_border') })
              .borderRadius(12)
              .onChange((value: string) => {
                this.host = value;
              })
            TextInput({ text: this.portText, placeholder: '端口' })
              .height(44)
              .type(InputType.Number)
              .backgroundColor($r('app.color.input_background'))
              .border({ width: 1, color: $r('app.color.glass_border') })
              .borderRadius(12)
              .onChange((value: string) => {
                this.portText = value;
              })
            TextInput({ text: this.token, placeholder: '长期配对密钥' })
              .height(44)
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
                .height(44)
                .fontColor(Color.White)
                .backgroundColor('#175CD3')
                .borderRadius(12)
                .onClick(() => this.saveAndConnect())
              Button('清除')
                .width(82)
                .height(44)
                .fontColor('#B42318')
                .backgroundColor('#FEF3F2')
                .borderRadius(12)
                .onClick(() => this.clearPairing())
            }
            }
          } else {
            Text(this.publicPairingStatus)
              .width('100%')
              .fontSize(12)
              .fontColor(this.isPublicPairing ? '#175CD3' : $r('app.color.text_secondary'))
              .padding(12)
              .backgroundColor($r('app.color.input_background'))
              .borderRadius(12)
            if (this.publicPairingVerification.length > 0) {
              Text(`安全校验码：${this.publicPairingVerification}`)
                .width('100%')
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor('#175CD3')
                .textAlign(TextAlign.Center)
                .padding(10)
            }
            if (canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')) {
              Button('扫描电脑端公网配对二维码')
                .width('100%')
                .height(46)
                .fontColor(Color.White)
                .backgroundColor('#175CD3')
                .borderRadius(12)
                .enabled(!this.isPublicPairing)
                .onClick(() => this.scanPublicPairingCode())
            }
            TextInput({ text: this.publicPairingCode,
              placeholder: '输入电脑端显示的 8 位公网配对码' })
              .height(48)
              .maxLength(9)
              .fontSize(18)
              .letterSpacing(2)
              .backgroundColor($r('app.color.input_background'))
              .border({ width: 1, color: $r('app.color.glass_border') })
              .borderRadius(12)
              .onChange((value: string) => this.publicPairingCode = value.toUpperCase())
            Button(this.isPublicPairing ? '正在等待电脑允许…' : '使用短码配对')
              .width('100%')
              .height(46)
              .fontColor(Color.White)
              .backgroundColor('#175CD3')
              .borderRadius(12)
              .enabled(!this.isPublicPairing &&
                this.publicPairingCode.replace('-', '').length === 8)
              .onClick(() => this.pairPublicGateway(null))
            Text('公网短码只能使用一次，2 分钟过期；配对必须在电脑端明确允许。')
              .width('100%')
              .fontSize(10)
              .lineHeight(15)
              .fontColor($r('app.color.text_secondary'))
          }
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: Math.max(280, this.layoutViewportHeight - 190) })
      .scrollBar(BarState.Auto)
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
  buildCodexRemoteHome(compact: boolean) {
    Column() {
      this.buildCodexRemoteHeader(true)

      Scroll() {
        Column({ space: 4 }) {
          if (this.selectedCodexProject.length === 0) {
            Row({ space: 7 }) {
              Text(this.isConnected ? '●' : '○')
                .fontSize(10)
                .fontColor(this.isConnected ? '#12B76A' : '#98A2B3')
              Text(this.selectedGatewayDevice()?.displayName || '当前电脑')
                .fontSize(12)
                .fontColor($r('app.color.text_primary'))
            }
            .width('100%')
            .padding({ left: 4, top: 4, bottom: 12 })

            Text('项目')
              .width('100%')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 4, top: 4, bottom: 5 })
            Row({ space: 10 }) {
              Text('对话')
                .fontSize(11)
                .fontColor('#344054')
              Text('聊天')
                .layoutWeight(1)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
              Text('›')
                .fontSize(18)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ left: 4, right: 4, top: 10, bottom: 10 })
            .onClick(() => this.selectedCodexProject = '__starly_chats__')
            ForEach(this.codexHomeProjects(), (project: string) => {
              Row({ space: 10 }) {
                Text('项目')
                  .fontSize(11)
                  .fontColor('#344054')
                Text(this.codexProjectName(project))
                  .layoutWeight(1)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding({ left: 4, right: 4, top: 10, bottom: 10 })
              .onClick(() => this.selectedCodexProject = project)
            }, (project: string): string => project)
          }

          Text(this.selectedCodexProject === '__starly_chats__' ? '聊天' :
            (this.selectedCodexProject.length > 0 ? '项目任务' : '最近'))
            .width('100%')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 4, top: 14, bottom: 5 })
          if (this.codexRemoteHomeTasks().length === 0) {
            Text(this.codexLoading ? '正在同步任务…' : '没有匹配的任务')
              .width('100%')
              .textAlign(TextAlign.Center)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .padding({ top: 32, bottom: 32 })
          }
          ForEach(this.codexRemoteHomeTasks(), (task: CodexTask) => {
            Row({ space: 10 }) {
              Column({ space: 3 }) {
                Text(task.title || 'Codex 任务')
                  .width('100%')
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.selectedCodexProject.length > 0 && task.preview.length > 0) {
                  Text(task.preview)
                    .width('100%')
                    .fontSize(10)
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              if (this.isCodexTaskPinned(task.id)) {
                Text('置顶')
                  .fontSize(9)
                  .fontColor('#175CD3')
              }
              if (this.effectiveCodexStatus(task) === 'active') {
                Text('正在执行')
                  .fontSize(10)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#067647')
              } else if (this.codexTaskUnreadCount(task.id) > 0) {
                Text(`${this.codexTaskUnreadCount(task.id)} 未读`)
                  .fontSize(9)
                  .fontColor('#175CD3')
              } else {
                Text(this.codexInitialSyncPending ? '同步中' :
                  this.formatCodexRelativeTime(task.updatedAt))
                  .fontSize(10)
                  .fontColor($r('app.color.text_secondary'))
              }
            }
            .width('100%')
            .padding({ left: 4, right: 4, top: 11, bottom: 11 })
            .border({ width: { bottom: 1 }, color: '#10000000' })
            .onClick(() => this.openRemoteCodexTask(task.id))
            .gesture(
              LongPressGesture({ repeat: false })
                .onAction((event: GestureEvent) => this.openCodexTaskMenu(task.id, event))
            )
          }, (task: CodexTask): string => this.codexTaskRenderKey(task, 'remote'))
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .padding({ left: 16, right: 16, bottom: 20 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      this.buildCodexRemoteFooter()
    }
    .width(compact ? this.codexSidebarWidth() : this.codexRemoteHomeWidth())
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .linearGradient({
      angle: 145,
      colors: [['#78FDFEFF', 0.0], ['#58EAF5FF', 0.42], ['#68F4E9FF', 1.0]]
    })
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT,
      scale: 0.9
    })
    .border({ width: 1, color: '#B8FFFFFF' })
    .borderRadius(26)
    .shadow({ radius: 32, color: '#303B82F6', offsetY: 10 })
    .clip(true)
  }

  @Builder
  buildCodexRemoteHeader(showProjectNavigation: boolean) {
    Row({ space: 10 }) {
      if (showProjectNavigation && this.selectedCodexProject.length > 0) {
        Button('‹')
          .width(40)
          .height(40)
          .padding(0)
          .fontSize(28)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor(Color.Transparent)
          .onClick(() => this.selectedCodexProject = '')
      }
      Column({ space: 2 }) {
        Text(showProjectNavigation && this.selectedCodexProject.length > 0 ?
          this.codexProjectName(this.selectedCodexProject) : 'Remote')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
        Text(this.selectedGatewayDeviceStatusText())
          .fontSize(10)
          .fontColor(this.isConnected ? '#067647' : $r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Column({ space: 1 }) {
        Text(this.codexAvailable ?
          `订阅剩余 ${Math.round(this.codexQuota.remainingPercent)}%` : '订阅额度 --')
          .fontSize(9)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.codexAvailable ? '#175CD3' : $r('app.color.text_secondary'))
        Text(this.codexAvailable ? `重置 ${this.codexQuota.resetCredits} 次` : '重置 --')
          .fontSize(8)
          .fontColor($r('app.color.text_secondary'))
      }
      .padding({ left: 9, right: 9, top: 5, bottom: 5 })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor('#7AFFFFFF')
      .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT,
        scale: 0.88
      })
      .border({ width: 1, color: '#8AFFFFFF' })
      .borderRadius(12)
      Button('⋮')
        .width(40)
        .height(40)
        .padding(0)
        .fontSize(24)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor('#88FFFFFF')
        .borderRadius(20)
        .onClick(() => this.togglePairingPanel())
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 4, bottom: 8 })
  }

  @Builder
  buildCodexRemoteFooter() {
    Row({ space: 8 }) {
      Row({ space: 7 }) {
        Text('⌕')
          .fontSize(20)
          .fontColor($r('app.color.text_secondary'))
        TextInput({ text: this.codexSearchText, placeholder: '搜索聊天' })
          .layoutWeight(1)
          .height(42)
          .fontSize(13)
          .backgroundColor(Color.Transparent)
          .onChange((value: string) => this.codexSearchText = value)
      }
      .layoutWeight(1)
      .height(48)
      .padding({ left: 12, right: 8 })
      .backgroundColor('#FFFFFFFF')
      .border({ width: 1, color: '#18000000' })
      .borderRadius(24)
      Button('✎  聊天')
        .height(48)
        .padding({ left: 17, right: 17 })
        .fontSize(13)
        .fontColor('#FFFFFFFF')
        .backgroundColor('#FF111111')
        .borderRadius(24)
        .enabled(this.codexProjects().length > 0 && this.isConnected)
        .onClick(() => this.openNewCodexTask())
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 4 })
    .backgroundColor('#5EFFFFFF')
  }

  @Builder
  buildDesktopCodexWorkspace() {
    Row({ space: 18 }) {
      this.buildCodexRemoteHome(true);
      Column() {
        if (this.selectedCodexTaskId.length > 0) {
          this.buildCodexDetailCard();
        } else {
          this.buildDesktopCodexEmptyDetail();
        }
      }
      .layoutWeight(1)
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  buildDesktopCodexSidebar() {
    Column() {
      this.buildCodexRemoteHeader(false)
      Scroll() {
        Column({ space: 4 }) {
          Row({ space: 7 }) {
            Text(this.isConnected ? '●' : '○')
              .fontSize(10)
              .fontColor(this.isConnected ? '#12B76A' : '#98A2B3')
            Text(this.selectedGatewayDevice()?.displayName || '当前电脑')
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
          }
          .width('100%')
          .padding({ left: 4, top: 4, bottom: 12 })

          Row() {
            Text('项目')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text(`${this.codexTasks.length} 个任务`)
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ left: 4, right: 4, top: 4, bottom: 5 })

          ForEach(this.codexDesktopProjects(), (project: string) => {
            Column({ space: 2 }) {
              Row({ space: 10 }) {
                Text('▱')
                  .fontSize(16)
                  .fontColor('#344054')
                Text(this.codexProjectName(project))
                  .layoutWeight(1)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${this.codexTasksForDesktopProject(project).length}`)
                  .fontSize(10)
                  .fontColor($r('app.color.text_secondary'))
                Text(this.isCodexProjectExpanded(project) ? '⌄' : '›')
                  .fontSize(16)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .padding({ left: 4, right: 4, top: 10, bottom: 10 })
              .backgroundColor(this.isCodexProjectExpanded(project) ?
                '#18FFFFFF' : Color.Transparent)
              .borderRadius(12)
              .onClick(() => this.toggleCodexProject(project))
              if (this.isCodexProjectExpanded(project)) {
                ForEach(this.codexTasksForDesktopProject(project), (task: CodexTask) => {
                  Row({ space: 10 }) {
                    Column({ space: 3 }) {
                      Text(task.title || 'Codex 任务')
                        .width('100%')
                        .fontSize(14)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      if (task.preview.length > 0) {
                        Text(task.preview)
                          .width('100%')
                          .fontSize(10)
                          .fontColor($r('app.color.text_secondary'))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    if (this.isCodexTaskPinned(task.id)) {
                      Text('置顶')
                        .fontSize(9)
                        .fontColor('#175CD3')
                    }
                    if (this.effectiveCodexStatus(task) === 'active') {
                      Text('正在执行')
                        .fontSize(10)
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#067647')
                    } else if (this.codexTaskUnreadCount(task.id) > 0) {
                      Text(`${this.codexTaskUnreadCount(task.id)} 未读`)
                        .fontSize(9)
                        .fontColor('#175CD3')
                    } else {
                      Text(this.codexInitialSyncPending ? '同步中' :
                        this.formatCodexRelativeTime(task.updatedAt))
                        .fontSize(10)
                        .fontColor($r('app.color.text_secondary'))
                    }
                  }
                  .width('100%')
                  .padding({ left: 28, right: 4, top: 11, bottom: 11 })
                  .backgroundColor(this.selectedCodexTaskId === task.id ?
                    '#32FFFFFF' : Color.Transparent)
                  .border({ width: { bottom: 1 }, color: '#10000000' })
                  .borderRadius(12)
                  .onClick(() => this.openDesktopCodexTask(task.id, project))
                  .gesture(
                    LongPressGesture({ repeat: false })
                      .onAction((event: GestureEvent) => this.openCodexTaskMenu(task.id, event))
                  )
                }, (task: CodexTask): string => this.codexTaskRenderKey(task, 'desktop'))
              }
            }
            .width('100%')
          }, (project: string): string => `desktop-project-${project}`)
          if (this.codexDesktopProjects().length === 0) {
            Text(this.codexLoading ? '正在同步任务…' : '暂无项目任务')
              .width('100%')
              .textAlign(TextAlign.Center)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .padding({ top: 30, bottom: 30 })
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .padding({ left: 16, right: 16, bottom: 20 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      this.buildCodexRemoteFooter()
    }
    .width(this.codexSidebarWidth())
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .linearGradient({
      angle: 145,
      colors: [['#78FDFEFF', 0.0], ['#58EAF5FF', 0.42], ['#68F4E9FF', 1.0]]
    })
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT,
      scale: 0.9
    })
    .border({ width: 1, color: '#B8FFFFFF' })
    .borderRadius(26)
    .shadow({ radius: 32, color: '#303B82F6', offsetY: 10 })
    .clip(true)
  }

  @Builder
  buildDesktopCodexEmptyDetail() {
    Column({ space: 12 }) {
      Text('选择一个任务')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('从左侧项目中展开并选择任务，右侧将显示完整聊天记录和任务操作。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height(this.codexDetailCardHeight())
    .justifyContent(FlexAlign.Center)
    .padding(24)
    .backgroundColor(this.codexGlassSurfaceColor())
    .border({ width: 1, color: this.codexGlassBorderColor() })
    .borderRadius(28)
    .shadow({ radius: 28, color: this.codexGlassShadowColor(), offsetY: 10 })
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
  buildApprovalOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
      Column({ space: 14 }) {
        Text(this.approvalHighRisk ? '高风险操作审批' : 'Codex 请求审批')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.approvalHighRisk ? '#FFD7D2' : '#FFFFFFFF')
        Text(this.approvalDisplayKind())
          .fontSize(14)
          .fontColor('#B8FFFFFF')
        if (this.approvalCommand.length > 0) {
          Text(this.approvalCommand)
            .fontSize(14)
            .fontFamily('monospace')
            .fontColor('#FFFFFFFF')
            .width('100%')
            .maxLines(6)
        }
        if (this.approvalCwd.length > 0) {
          Text(`目录：${this.approvalCwd}`)
            .fontSize(13)
            .fontColor('#C8FFFFFF')
            .width('100%')
        }
        if (this.approvalReason.length > 0) {
          Text(this.approvalReason)
            .fontSize(13)
            .fontColor('#C8FFFFFF')
            .width('100%')
        }
        if (this.approvalPermissions.length > 0) {
          Text(`权限：${this.approvalPermissions}`)
            .fontSize(13)
            .fontColor('#FFFFD7A8')
            .width('100%')
            .maxLines(4)
        }
        if (this.approvalRiskReason.length > 0) {
          Text(`风险提示：${this.approvalRiskReason}`)
            .fontSize(13)
            .fontColor(this.approvalHighRisk ? '#FFFFC2BC' : '#C8FFFFFF')
            .width('100%')
            .maxLines(4)
        }
        Row({ space: 12 }) {
          Button('拒绝')
            .layoutWeight(1)
            .onClick(() => this.submitApprovalDecision('decline'))
          Button(this.approvalHighRisk && !this.approvalSecondConfirm ? '继续确认' : '允许一次')
            .layoutWeight(1)
            .backgroundColor(this.approvalHighRisk ? '#FFC93D3D' : '#FF3578E5')
            .onClick(() => {
              if (this.approvalHighRisk && !this.approvalSecondConfirm) {
                this.armApprovalSecondConfirm();
                return;
              }
              this.submitApprovalDecision('accept');
            })
        }
        .width('100%')
        if (this.approvalHighRisk && this.approvalSecondConfirm) {
          Text('请再次点击“允许一次”确认高风险操作')
            .fontSize(12)
            .fontColor('#FFFFC2BC')
        }
      }
      .width(Math.min(520, this.layoutViewportWidth - 32))
      .padding(22)
      .borderRadius(24)
      .backgroundColor('#F01E2430')
    }
    .width('100%')
    .height('100%')
    .zIndex(100)
  }

  @Builder
  buildCodexTaskMenuOverlay() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.codexTaskRenameMode ? '#32000000' : '#08000000')
        .onClick(() => this.closeCodexTaskMenu())
      if (this.codexTaskRenameMode) {
        Column({ space: 16 }) {
          Text('重命名任务')
            .width('100%')
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          TextInput({ text: this.codexTaskRenameText, placeholder: '输入新的任务名称' })
            .width('100%')
            .height(48)
            .fontSize(15)
            .maxLength(80)
            .backgroundColor($r('app.color.input_background'))
            .borderRadius(14)
            .onChange((value: string) => this.codexTaskRenameText = value)
          Row({ space: 10 }) {
            Button('取消')
              .layoutWeight(1)
              .height(44)
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.input_background'))
              .onClick(() => this.closeCodexTaskMenu())
            Button('保存')
              .layoutWeight(1)
              .height(44)
              .fontColor('#FFFFFFFF')
              .backgroundColor('#175CD3')
              .enabled(this.codexTaskRenameText.trim().length > 0)
              .onClick(() => this.renameCodexTaskFromMenu())
          }
          .width('100%')
        }
        .width(Math.min(440, this.layoutViewportWidth - 32))
        .padding(20)
        .backgroundColor($r('app.color.page_background'))
        .borderRadius(24)
        .position({
          x: Math.max(16, (this.layoutViewportWidth - Math.min(440,
            this.layoutViewportWidth - 32)) / 2),
          y: Math.max(80, this.layoutViewportHeight / 2 - 110)
        })
      } else {
        Column({ space: 2 }) {
          Row() {
            Text(this.isCodexTaskPinned(this.codexTaskMenuId) ? '取消置顶' : '置顶')
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
          }
            .width('100%')
            .height(40)
            .padding({ left: 12, right: 12 })
            .backgroundColor(Color.Transparent)
            .onClick(() => this.toggleCodexTaskPinned(this.codexTaskMenuId))
          Row() {
            Text('标记为未读')
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
          }
            .width('100%')
            .height(40)
            .padding({ left: 12, right: 12 })
            .backgroundColor(Color.Transparent)
            .onClick(() => this.markCodexTaskUnread(this.codexTaskMenuId))
          Row() {
            Text('重命名')
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
          }
            .width('100%')
            .height(40)
            .padding({ left: 12, right: 12 })
            .backgroundColor(Color.Transparent)
            .onClick(() => this.openCodexTaskRename())
          Row() {
            Text('归档')
              .fontSize(14)
              .fontColor(this.isCodexTaskMenuRunning() ? '#98A2B3' : '#C4320A')
          }
            .width('100%')
            .height(40)
            .padding({ left: 12, right: 12 })
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              if (!this.isCodexTaskMenuRunning()) {
                this.archiveCodexTaskFromMenu();
              }
            })
        }
        .width(176)
        .padding(8)
        .position({ x: this.codexTaskMenuX, y: this.codexTaskMenuY })
        .backgroundColor('#C8FFFFFF')
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
          colorMode: ThemeColorMode.SYSTEM,
          adaptiveColor: AdaptiveColor.DEFAULT,
          scale: 0.92
        })
        .border({ width: 1, color: '#A8FFFFFF' })
        .borderRadius(16)
        .shadow({ radius: 24, color: '#38000000', offsetY: 8 })
        .scale({
          x: this.codexTaskMenuExpanded ? 1 : 0.84,
          y: this.codexTaskMenuExpanded ? 1 : 0.84,
          centerX: 0,
          centerY: 0
        })
        .opacity(this.codexTaskMenuExpanded ? 1 : 0)
        .translate({ y: this.codexTaskMenuExpanded ? 0 : -6 })
        .animation({ duration: 170, curve: Curve.FastOutSlowIn })
      }
    }
    .width('100%')
    .height('100%')
    .zIndex(120)
  }

  @Builder
  buildCodexQueueMenuOverlay() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#08000000')
        .onClick(() => this.closeCodexQueueMenu())
      Column() {
        Row() {
          Text('取消排队')
            .fontSize(14)
            .fontColor('#C4320A')
        }
        .width('100%')
        .height(42)
        .padding({ left: 13, right: 13 })
        .backgroundColor(Color.Transparent)
        .onClick(() => this.cancelCodexQueueFromMenu())
      }
      .width(136)
      .padding(7)
      .position({ x: this.codexQueueMenuX, y: this.codexQueueMenuY })
      .backgroundColor('#C8FFFFFF')
      .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT,
        scale: 0.92
      })
      .border({ width: 1, color: '#A8FFFFFF' })
      .borderRadius(15)
      .shadow({ radius: 22, color: '#34000000', offsetY: 7 })
      .scale({
        x: this.codexQueueMenuExpanded ? 1 : 0.82,
        y: this.codexQueueMenuExpanded ? 1 : 0.82,
        centerX: 0,
        centerY: 0
      })
      .opacity(this.codexQueueMenuExpanded ? 1 : 0)
      .translate({ y: this.codexQueueMenuExpanded ? 0 : -5 })
      .animation({ duration: 165, curve: Curve.FastOutSlowIn })
    }
    .width('100%')
    .height('100%')
    .zIndex(130)
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
    .backgroundColor(this.codexGlassSurfaceColor())
    .backgroundBlurStyle(this.useTwoPaneCodexLayout() ? BlurStyle.NONE :
      BlurStyle.COMPONENT_ULTRA_THIN, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT,
      scale: 0.9
    })
    .border({ width: 1, color: this.codexGlassBorderColor() })
    .borderRadius(28)
    .shadow({ radius: 28, color: this.codexGlassShadowColor(), offsetY: 10 })
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
      if (this.areCodexTasksExpanded) {
        Row({ space: 8 }) {
          TextInput({ text: this.codexSearchText, placeholder: '搜索任务、目录或内容' })
            .layoutWeight(1)
            .height(38)
            .fontSize(13)
            .backgroundColor($r('app.color.input_background'))
            .borderRadius(12)
            .onChange((value: string) => {
              this.codexSearchText = value;
              this.codexTaskDisplayLimit = 10;
            })
          Button(this.showArchivedCodexTasks ? '含已归档' : '仅当前')
            .height(38)
            .fontSize(11)
            .padding({ left: 10, right: 10 })
            .backgroundColor(this.showArchivedCodexTasks ? '#1A175CD3' : Color.Transparent)
            .fontColor('#175CD3')
            .border({ width: 1, color: '#4D175CD3' })
            .borderRadius(12)
            .onClick(() => this.toggleArchivedCodexTasks())
        }
        .width('100%')
      }
      if (this.connectionMode !== 'lan') {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.visibleGatewayDevices(), (device: GatewayPeerDevice) => {
              Button(`${device.online ? '●' : '○'} ${device.displayName || device.deviceId}`)
                .height(34)
                .fontSize(11)
                .fontColor(device.deviceId === this.selectedGatewayBridgeId ? '#FFFFFFFF' : '#175CD3')
                .backgroundColor(device.deviceId === this.selectedGatewayBridgeId ?
                  '#FF175CD3' : '#14175CD3')
                .borderRadius(12)
                .onClick(() => {
                  this.handleGatewayDeviceTap(device);
                })
            }, (device: GatewayPeerDevice): string => device.deviceId)
          }
        }
        .width('100%')
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        Text(this.selectedGatewayDeviceStatusText())
          .width('100%')
          .fontSize(11)
          .fontColor(this.selectedGatewayDeviceOnline() ? '#067647' : '#B54708')
          .maxLines(2)
        if (this.gatewaySwitchConfirmId.length > 0) {
          Text(this.gatewaySwitchConfirmationText())
            .width('100%')
            .fontSize(11)
            .fontColor('#B54708')
            .padding({ left: 9, right: 9, top: 7, bottom: 7 })
            .backgroundColor('#FFFFFAEB')
            .borderRadius(10)
        }
        Row({ space: 8 }) {
          TextInput({ text: this.gatewayDeviceName, placeholder: '给这台电脑命名' })
            .layoutWeight(1)
            .height(34)
            .fontSize(12)
            .onChange((value: string) => this.gatewayDeviceName = value)
          Button('保存名称')
            .height(34)
            .fontSize(11)
            .onClick(() => this.renameSelectedGatewayDevice())
          Button(this.gatewayRevokeConfirm ? '再次点按撤销' : '撤销设备')
            .height(34)
            .fontSize(11)
            .fontColor('#B42318')
            .backgroundColor('#FFF1F0')
            .onClick(() => this.revokeSelectedGatewayDevice())
        }
        .width('100%')
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
      } else if (this.displayedCodexTasks().length === 0) {
        Text(this.codexAvailable ? '暂时没有可显示的 Codex 任务' : '连接电脑后读取 Codex 任务')
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .padding({ top: 24, bottom: 24 })
      } else {
        List({ space: 4 }) {
          ForEach(this.displayedCodexTasks().slice(0, this.codexTaskDisplayLimit), (task: CodexTask) => {
            ListItem() {
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
              if (task.archived) {
                Text('已归档')
                  .fontSize(10)
                  .fontColor('#B54708')
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            if (this.isCodexTaskPinned(task.id)) {
              Text('置顶')
                .fontSize(9)
                .fontColor('#175CD3')
            }
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
                if (this.codexTaskUnreadCount(task.id) > 0) {
                  Text(`${this.codexTaskUnreadCount(task.id)} 未读`)
                    .fontSize(10)
                    .fontColor('#FFFFFF')
                    .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                    .backgroundColor('#175CD3')
                    .borderRadius(9)
                }
              }
              .alignItems(HorizontalAlign.End)
            } else {
              Column({ space: 4 }) {
                Text(this.codexStatusLabel(this.effectiveCodexStatus(task)))
                  .fontSize(11)
                  .fontColor(this.codexStatusColor(this.effectiveCodexStatus(task)))
                  .maxLines(1)
                if (this.codexTaskUnreadCount(task.id) > 0) {
                  Text(`${this.codexTaskUnreadCount(task.id)} 未读`)
                    .fontSize(10)
                    .fontColor('#FFFFFF')
                    .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                    .backgroundColor('#175CD3')
                    .borderRadius(9)
                }
              }
              .alignItems(HorizontalAlign.End)
            }
              }
              .width(this.selectedCodexTaskId === task.id ? '94%' : '100%')
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
              .translate({ y: 0 })
              .scale({ x: 1, y: 1 })
              .margin({
                left: this.selectedCodexTaskId === task.id ? 10 : 0,
                right: this.selectedCodexTaskId === task.id ? 10 : 0,
                top: this.selectedCodexTaskId === task.id ? 5 : 0,
                bottom: this.selectedCodexTaskId === task.id ? 11 : 0
              })
              .zIndex(this.selectedCodexTaskId === task.id ? 2 : 0)
              .animation({ duration: 260, curve: Curve.EaseOut })
              .onClick(() => this.handleCodexTaskTap(task.id))
              .gesture(
                LongPressGesture({ repeat: false })
                  .onAction((event: GestureEvent) => this.openCodexTaskMenu(task.id, event))
              )
            }
          }, (task: CodexTask): string => this.codexTaskRenderKey(task, 'list'))
          if (this.codexTaskDisplayLimit < this.displayedCodexTasks().length) {
            ListItem() {
              Text('继续向下滑动，加载更多')
                .width('100%')
                .textAlign(TextAlign.Center)
                .fontSize(11)
                .fontColor('#175CD3')
                .padding({ top: 12, bottom: 12 })
            }
          }
        }
        .width('100%')
        .height(this.codexTaskListViewportHeight())
        .padding({ left: 5, right: 5, top: 9, bottom: 14 })
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .onReachEnd(() => this.loadMoreCodexTasks())
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.codexGlassSurfaceColor())
    .backgroundBlurStyle(this.useTwoPaneCodexLayout() ? BlurStyle.NONE :
      BlurStyle.COMPONENT_ULTRA_THIN, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT,
      scale: 0.88
    })
    .border({ width: 1, color: this.codexGlassBorderColor() })
    .borderRadius(28)
    .shadow({ radius: 28, color: this.codexGlassShadowColor(), offsetY: 10 })
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
        } else {
          Text(this.selectedCodexArchived ? '恢复' : '归档')
            .fontSize(12)
            .fontColor(this.selectedCodexArchived ? '#175CD3' : '#B54708')
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .onClick(() => this.toggleSelectedCodexArchived())
        }
      }
      .width('100%')
      if (this.selectedCodexActivities.length > 0) {
        this.buildCodexActivityTimeline()
      }
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
        if (this.codexHistoryReady && this.isCodexConversationOpen) {
          this.markSelectedCodexRead();
        }
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
      // Wide-screen and phone conversations intentionally share one Remote
      // composer so their model/permission controls and send behavior stay
      // visually and functionally identical.
      this.buildCodexRemoteComposer()
    }
    .width('100%')
    .height(this.codexDetailCardHeight())
    .padding(16)
    .backgroundColor(this.codexGlassSurfaceColor())
    .backgroundBlurStyle(this.useTwoPaneCodexLayout() ? BlurStyle.NONE :
      BlurStyle.COMPONENT_ULTRA_THIN, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT,
      scale: 0.9
    })
    .border({ width: 1, color: this.codexGlassBorderColor() })
    .borderRadius(28)
    .shadow({ radius: 28, color: this.codexGlassShadowColor(), offsetY: 10 })
    .onTouch((event: TouchEvent) => {
      this.handleCodexDetailTouch(event);
    })
  }

  @Builder
  buildCodexActivityTimeline() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('执行过程')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FF344054')
        Text(`${this.selectedCodexActivities.length} 条`)
          .fontSize(10)
          .fontColor('#FF667085')
        Blank()
        Text(this.codexActivityExpanded ? '收起⌃' : '展开⌄')
          .fontSize(10)
          .fontColor('#FF175CD3')
      }
      .width('100%')
      .onClick(() => this.codexActivityExpanded = !this.codexActivityExpanded)
      if (this.codexActivityExpanded) {
        ForEach(this.visibleCodexActivities(), (activity: CodexActivity) => {
          Row({ space: 9 }) {
            Text(this.codexActivityIcon(activity))
              .width(22)
              .fontSize(13)
              .textAlign(TextAlign.Center)
              .fontColor(this.codexActivityColor(activity))
            Column({ space: 2 }) {
              Row() {
                Text(activity.title)
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#FF344054')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Blank()
                Text(this.formatMessageTimestamp(activity.timestamp))
                  .fontSize(8)
                  .fontColor('#FF98A2B3')
              }
              .width('100%')
              if (activity.text.trim().length > 0) {
                Text(this.codexDisplayText(activity.text))
                  .width('100%')
                  .fontSize(10)
                  .lineHeight(16)
                  .fontColor('#FF667085')
                  .maxLines(4)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
        }, (activity: CodexActivity): string => `activity-${activity.id}`)
        Text('仅显示公开执行摘要；密钥、工具参数和加密内部推理不会同步。')
          .width('100%')
          .fontSize(9)
          .lineHeight(14)
          .fontColor('#FF98A2B3')
      } else {
        Row({ space: 8 }) {
          Text(this.codexActivityIcon(this.latestCodexActivity()))
            .fontSize(12)
            .fontColor(this.codexActivityColor(this.latestCodexActivity()))
          Text(this.latestCodexActivity().title)
            .layoutWeight(1)
            .fontSize(11)
            .fontColor('#FF667085')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor('#0F175CD3')
    .border({ width: 1, color: '#24175CD3' })
    .borderRadius(14)
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
            .copyOption(CopyOptions.LocalDevice)
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
          Text(this.codexMessageDeliveryLabel(message))
            .width('100%')
            .textAlign(TextAlign.End)
            .fontSize(9)
            .fontColor(this.codexMessageDeliveryColor(message, true))
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
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction((event: GestureEvent) => this.openCodexQueueMenu(message, event))
    )
  }

  @Builder
  buildCodexConversationCover() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
      Row({ space: 10 }) {
        Button('‹')
          .width(40)
          .height(40)
          .padding(0)
          .fontSize(28)
          .fontColor('#FF111111')
          .backgroundColor('#FFFFFFFF')
          .borderRadius(20)
          .onClick(() => this.closeRemoteCodexConversation())
        Column({ space: 2 }) {
          Text(this.codexNewTaskMode ? '新任务' : (this.selectedCodexTitle || 'Codex 任务'))
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FF111111')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`项目 · ${this.codexProjectName(this.selectedCodexCwd)}  电脑 · ${this.gatewayDeviceName || '当前电脑'}`)
            .fontSize(9)
            .fontColor('#FF667085')
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button(this.codexLoading || this.codexDetailLoading ? '◌' : '↻')
          .width(40)
          .height(40)
          .padding(0)
          .fontSize(21)
          .fontColor('#FF344054')
          .backgroundColor('#FFFFFFFF')
          .borderRadius(20)
          .enabled(!this.codexNewTaskMode)
          .onClick(() => this.requestSelectedCodexThread(true))
        Button('⋮')
          .width(40)
          .height(40)
          .padding(0)
          .fontSize(23)
          .fontColor('#FF111111')
          .backgroundColor('#FFFFFFFF')
          .borderRadius(20)
          .onClick(() => this.codexSettingsMenu =
            this.codexSettingsMenu === 'actions' ? '' : 'actions')
          .bindPopup(this.codexSettingsMenu === 'actions', {
            builder: this.buildCodexRemoteSettingsMenu,
            placement: Placement.BottomRight,
            popupColor: '#B8FFFFFF',
            backgroundBlurStyle: BlurStyle.COMPONENT_ULTRA_THIN,
            enableArrow: false,
            autoCancel: true,
            mask: false,
            targetSpace: 6,
            onStateChange: (event: PopupVisibilityEvent): void => {
              if (!event.isVisible) this.codexSettingsMenu = '';
            }
          })
      }
      .width('100%')
      .height(64)
      .padding({ left: 10, right: 10, top: 8, bottom: 6 })
      .backgroundColor('#FAFFFFFF')

      if (this.codexNewTaskMode) {
        Scroll() {
          Row({ space: 7 }) {
            ForEach(this.codexProjects(), (project: string) => {
              Button(this.codexProjectName(project))
                .height(32)
                .fontSize(10)
                .fontColor(project === this.selectedCodexCwd ? '#FFFFFFFF' : '#FF344054')
                .backgroundColor(project === this.selectedCodexCwd ? '#FF111111' : '#FFF2F4F7')
                .borderRadius(16)
                .onClick(() => this.selectedCodexCwd = project)
            }, (project: string): string => `new-${project}`)
          }
          .padding({ left: 12, right: 12 })
        }
        .width('100%')
        .height(38)
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
      }

      List({ space: 12, scroller: this.codexChatScroller }) {
        if (!this.codexNewTaskMode && this.codexDetailLoading &&
          this.selectedCodexMessages.length === 0) {
          ForEach([1, 2, 3], (item: number) => {
            ListItem() {
              Column({ space: 10 }) {
                Text('')
                  .width(item === 1 ? '48%' : '70%')
                  .height(34)
                  .backgroundColor('#FFEDEDED')
                  .borderRadius(8)
                Text('')
                  .width(item === 2 ? '92%' : '78%')
                  .height(item === 2 ? 88 : 58)
                  .backgroundColor('#FFE7E7E7')
                  .borderRadius(8)
              }
              .width('100%')
              .alignItems(item === 1 ? HorizontalAlign.End : HorizontalAlign.Start)
            }
          }, (item: number): string => `skeleton-${item}`)
        } else if (this.codexNewTaskMode) {
          ListItem() {
            Column({ space: 8 }) {
              Text('开始一个新的 Codex 任务')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FF111111')
              Text('选择项目，在下方输入你的要求。模型、智能强度和权限可在输入框上方调整。')
                .fontSize(12)
                .lineHeight(19)
                .fontColor('#FF667085')
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .padding({ top: 72 })
          }
        }
        if (!this.codexNewTaskMode && this.selectedCodexActivities.length > 0) {
          ListItem() {
            this.buildCodexActivityTimeline()
          }
        }
        if (this.codexHistoryHasMore && !this.codexNewTaskMode) {
          ListItem() {
            Button(this.codexHistoryLoadingOlder ? '正在载入…' : `前 ${Math.min(15, this.selectedCodexMessages.length)} 条消息 ›`)
              .height(34)
              .fontSize(11)
              .fontColor('#FF667085')
              .backgroundColor(Color.Transparent)
              .enabled(!this.codexHistoryLoadingOlder)
              .onClick(() => this.loadOlderCodexMessages())
          }
        }
        ForEach(this.selectedCodexMessages, (message: CodexMessage) => {
          ListItem() {
            this.buildCodexRemoteMessage(message)
          }
        }, (message: CodexMessage): string => `remote-${message.id}`)
        if (!this.codexNewTaskMode && this.isSelectedCodexRunning()) {
          ListItem() {
            Row({ space: 6 }) {
              Text('◌')
                .fontSize(16)
                .fontColor('#FF667085')
              Text('Codex 正在处理…')
                .fontSize(11)
                .fontColor('#FF667085')
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onReachStart(() => this.loadOlderCodexMessages())
      .onReachEnd(() => {
        this.codexChatPinnedToBottom = true;
        this.markSelectedCodexRead();
      })

      this.buildCodexRemoteComposer()
      }
      .width('100%')
      .height('100%')
      .padding({ top: 38, bottom: this.keyboardInset })
      .backgroundColor('#FFF8F8F7')
      if (this.codexQueueMenuId.length > 0) {
        this.buildCodexQueueMenuOverlay();
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  buildCodexRemoteMessage(message: CodexMessage) {
    Row() {
      if (message.role === 'user') {
        Blank()
      }
      Column({ space: 6 }) {
        if (message.text.trim().length > 0) {
          Text(this.codexDisplayText(message.text))
            .width('100%')
            .fontSize(13)
            .lineHeight(21)
            .fontColor('#FF202124')
            .copyOption(CopyOptions.LocalDevice)
        }
        if (message.images.length > 0) {
          ForEach(message.images, (source: string, index: number) => {
            Image(source)
              .width('100%')
              .height(180)
              .objectFit(ImageFit.Contain)
              .backgroundColor('#0F000000')
              .borderRadius(12)
          }, (_source: string, index: number): string => `${message.id}-${index}`)
        }
        if (message.deliveryState.length > 0) {
          Text(this.codexMessageDeliveryLabel(message))
            .fontSize(9)
            .fontColor(this.codexMessageDeliveryColor(message, false))
        }
        Text(this.formatMessageTimestamp(message.timestamp))
          .width('100%')
          .textAlign(message.role === 'user' ? TextAlign.End : TextAlign.Start)
          .fontSize(9)
          .fontColor('#FF98A2B3')
      }
      .width(message.role === 'user' ? '72%' : '100%')
      .alignItems(HorizontalAlign.Start)
      .padding(message.role === 'user' ? 12 : 2)
      .backgroundColor(message.role === 'user' ? '#FFEDEDED' : Color.Transparent)
      .borderRadius(message.role === 'user' ? 16 : 0)
      if (message.role !== 'user') {
        Blank()
      }
    }
    .width('100%')
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction((event: GestureEvent) => this.openCodexQueueMenu(message, event))
    )
  }

  @Builder
  buildCodexRemoteComposer() {
    Column({ space: 6 }) {
      if (!this.codexNewTaskMode && this.selectedCodexGoal.goalId.length > 0) {
        this.buildCodexGoalBar()
      }
      if (this.codexImagePreviewUri.length > 0) {
        Row({ space: 8 }) {
          Image(this.codexImagePreviewUri)
            .width(58)
            .height(48)
            .objectFit(ImageFit.Cover)
            .borderRadius(9)
          Text(this.codexImagePicking ? '正在处理图片…' : '图片已添加')
            .layoutWeight(1)
            .fontSize(11)
            .fontColor('#FF667085')
          Button('移除')
            .height(30)
            .fontSize(10)
            .fontColor('#FFD92D20')
            .backgroundColor(Color.Transparent)
            .onClick(() => this.clearCodexImage())
        }
        .width('100%')
      }
      Row({ space: 6 }) {
        Button(`${this.selectedCodexModelLabel()}  ›`)
          .height(28)
          .fontSize(9)
          .fontColor('#FF344054')
          .backgroundColor('#FFF2F4F7')
          .borderRadius(14)
          .onClick(() => this.codexSettingsMenu =
            this.codexSettingsMenu === 'main' ? '' : 'main')
          .bindPopup(this.isCodexModelSettingsMenu(), {
            builder: this.buildCodexRemoteSettingsMenu,
            placement: Placement.TopLeft,
            popupColor: '#B8FFFFFF',
            backgroundBlurStyle: BlurStyle.COMPONENT_ULTRA_THIN,
            enableArrow: false,
            autoCancel: true,
            mask: false,
            targetSpace: 6,
            onStateChange: (event: PopupVisibilityEvent): void => {
              if (!event.isVisible) this.codexSettingsMenu = '';
            }
          })
        Button(this.codexPermissionLabel())
          .height(28)
          .fontSize(9)
          .fontColor(this.codexPermissionMode === 'fullAccess' ? '#FFB42318' : '#FF344054')
          .backgroundColor('#FFF2F4F7')
          .borderRadius(14)
          .onClick(() => this.codexSettingsMenu =
            this.codexSettingsMenu === 'permissions' ? '' : 'permissions')
          .bindPopup(this.codexSettingsMenu === 'permissions', {
            builder: this.buildCodexRemoteSettingsMenu,
            placement: Placement.TopLeft,
            popupColor: '#B8FFFFFF',
            backgroundBlurStyle: BlurStyle.COMPONENT_ULTRA_THIN,
            enableArrow: false,
            autoCancel: true,
            mask: false,
            targetSpace: 6,
            onStateChange: (event: PopupVisibilityEvent): void => {
              if (!event.isVisible) this.codexSettingsMenu = '';
            }
          })
        Blank()
      }
      .width('100%')
      Row({ space: 6 }) {
        Button('+')
          .width(38)
          .height(38)
          .padding(0)
          .fontSize(23)
          .fontColor('#FF111111')
          .backgroundColor('#FFF2F4F7')
          .borderRadius(19)
          .enabled(this.isConnected && !this.codexImagePicking)
          .onClick(() => this.chooseCodexImage())
        TextArea({ text: this.codexCommand, placeholder: this.codexNewTaskMode ?
          '向 Codex 提问' : '继续向 Codex 提问' })
          .layoutWeight(1)
          .height(48)
          .fontSize(13)
          .backgroundColor(Color.Transparent)
          .padding({ left: 4, right: 4, top: 2, bottom: 2 })
          .onChange((value: string) => this.codexCommand = value)
        if (this.codexVoiceListening) {
          Button('■')
            .width(38)
            .height(38)
            .padding(0)
            .fontSize(15)
            .fontColor('#FFD92D20')
            .backgroundColor('#FFFFE4E0')
            .borderRadius(19)
            .onClick(() => this.toggleCodexVoiceInput())
        } else {
          Button() {
            Image($r('app.media.microphone_icon'))
              .width(21)
              .height(21)
              .objectFit(ImageFit.Contain)
          }
          .width(32)
          .height(32)
          .padding(0)
          .backgroundColor('#FF344054')
          .borderRadius(16)
          .onClick(() => this.toggleCodexVoiceInput())
        }
        if (this.selectedCodexActiveTurnId.length > 0 && !this.codexNewTaskMode &&
          !this.canSendRemoteCodexComposer()) {
          Button() {
            Image($r('app.media.stop_button_icon'))
              // The source has slightly more transparent padding than the
              // send icon, so compensate inside the same 38vp hit target.
              .width(42)
              .height(42)
              .objectFit(ImageFit.Contain)
          }
            .width(38)
            .height(38)
            .padding(0)
            .backgroundColor(Color.Transparent)
            .borderRadius(19)
            .onClick(() => this.stopCodexTask())
        } else {
          Button() {
            Image($r('app.media.send_arrow_icon'))
              .width(38)
              .height(38)
              .objectFit(ImageFit.Contain)
          }
            .width(38)
            .height(38)
            .padding(0)
            .opacity(this.canSendRemoteCodexComposer() ? 1 : 0.42)
            .backgroundColor(Color.Transparent)
            .borderRadius(19)
            .enabled(this.canSendRemoteCodexComposer())
            .onClick(() => this.sendRemoteCodexComposer())
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 7, bottom: 8 })
    .backgroundColor('#FFFFFFFF')
    .border({ width: 1, color: '#18000000' })
    .borderRadius(20)
    .margin({ left: 8, right: 8, bottom: 4 })
  }

  @Builder
  buildCodexGoalBar() {
    Column({ space: 5 }) {
      Row({ space: 6 }) {
        Text('◎')
          .fontSize(13)
          .fontColor('#FF667085')
        Text('目标')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FF202124')
        Text(this.codexGoalStatusLabel())
          .fontSize(10)
          .fontColor(this.codexGoalStatusColor())
        if (!this.codexGoalExpanded) {
          Text(this.selectedCodexGoal.objective)
            .layoutWeight(1)
            .fontSize(10)
            .fontColor('#FF667085')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          Blank()
        }
        Text(this.formatCodexGoalElapsed())
          .fontSize(9)
          .fontColor('#FF98A2B3')
        Text(this.codexGoalExpanded ? '⌃' : '›')
          .fontSize(15)
          .fontColor('#FF98A2B3')
      }
      .width('100%')
      if (this.codexGoalExpanded) {
        Text(this.selectedCodexGoal.objective)
          .width('100%')
          .fontSize(11)
          .lineHeight(17)
          .fontColor('#FF475467')
          .maxLines(5)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 7, bottom: 7 })
    .backgroundColor('#FFF9FAFB')
    .border({ width: 1, color: '#FFE4E7EC' })
    .borderRadius(11)
    .onClick(() => this.codexGoalExpanded = !this.codexGoalExpanded)
  }

  @Builder
  buildCodexRemoteSettingsMenu() {
    Column({ space: 3 }) {
      if (this.codexSettingsMenu === 'actions') {
        Button(this.selectedCodexArchived ? '恢复任务' : '归档任务')
          .width('100%')
          .height(40)
          .fontSize(12)
          .fontColor('#FF344054')
          .backgroundColor(Color.Transparent)
          .enabled(!this.codexNewTaskMode && !this.isSelectedCodexRunning())
          .onClick(() => {
            this.codexSettingsMenu = '';
            this.toggleSelectedCodexArchived();
          })
      } else if (this.codexSettingsMenu === 'models') {
        Row() {
          Text('选择模型')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
          Blank()
          Button('‹')
            .width(28)
            .height(28)
            .fontSize(18)
            .padding(0)
            .backgroundColor(Color.Transparent)
            .onClick(() => this.codexSettingsMenu = 'main')
        }
        .width('100%')
        Scroll() {
          Column({ space: 3 }) {
            ForEach(this.codexModels, (model: CodexModelOption) => {
              Button(`${model.displayName}${model.model === this.selectedCodexModel ? '  ✓' : ''}`)
                .width('100%')
                .height(34)
                .fontSize(11)
                .fontColor('#FF111111')
                .backgroundColor(Color.Transparent)
                .onClick(() => this.selectCodexModel(model))
            }, (model: CodexModelOption): string => model.model)
          }
          .width('100%')
        }
        .width('100%')
        .height(Math.min(this.codexModels.length * 37, 216))
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      } else if (this.codexSettingsMenu === 'effort') {
        ForEach(this.codexReasoningEfforts(), (effort: string) => {
          Button(`${this.codexEffortLabelFor(effort)}${effort === this.selectedCodexEffort ? '  ✓' : ''}`)
            .width('100%')
            .height(34)
            .fontSize(11)
            .fontColor('#FF111111')
            .backgroundColor(Color.Transparent)
            .onClick(() => this.selectCodexEffort(effort))
        }, (effort: string): string => effort)
      } else if (this.codexSettingsMenu === 'permissions') {
        ForEach(['default', 'autoApprove', 'readOnly', 'fullAccess'], (mode: string) => {
          Button(`${this.codexPermissionLabelFor(mode)}${mode === this.codexPermissionMode ? '  ✓' : ''}`)
            .width('100%')
            .height(mode === 'fullAccess' && this.codexFullAccessConfirm ? 42 : 34)
            .fontSize(11)
            .fontColor(mode === 'fullAccess' ? '#FFB42318' : '#FF111111')
            .backgroundColor(Color.Transparent)
            .onClick(() => this.selectCodexPermission(mode))
        }, (mode: string): string => mode)
      } else if (this.codexSettingsMenu === 'speed') {
        ForEach(this.codexServiceTierOptions(), (tier: string) => {
          Button(`${this.codexServiceTierLabel(tier)}${tier === this.selectedCodexServiceTier ? '  ✓' : ''}`)
            .width('100%')
            .height(34)
            .fontSize(11)
            .fontColor('#FF111111')
            .backgroundColor(Color.Transparent)
            .onClick(() => this.selectCodexServiceTier(tier))
        }, (tier: string): string => tier || 'standard')
      } else {
        Row({ space: 6 }) {
          Text('模型')
            .fontSize(11)
            .fontColor('#FF344054')
          Blank()
          Text(this.selectedCodexModelLabel())
            .fontSize(10)
            .fontColor('#FF98A2B3')
            .maxLines(1)
          Text('›')
            .fontSize(18)
            .fontColor('#FF98A2B3')
        }
          .width('100%')
          .height(36)
          .padding({ left: 9, right: 7 })
          .onClick(() => this.codexSettingsMenu = 'models')
        Row({ space: 6 }) {
          Text('推理强度')
            .fontSize(11)
            .fontColor('#FF344054')
          Blank()
          Text(this.codexEffortLabel())
            .fontSize(10)
            .fontColor('#FF98A2B3')
          Text('›')
            .fontSize(18)
            .fontColor('#FF98A2B3')
        }
          .width('100%')
          .height(36)
          .padding({ left: 9, right: 7 })
          .backgroundColor('#0A000000')
          .borderRadius(7)
          .onClick(() => this.codexSettingsMenu = 'effort')
        Row({ space: 6 }) {
          Text('速度')
            .fontSize(11)
            .fontColor('#FF344054')
          Blank()
          Text(this.codexServiceTierLabel(this.selectedCodexServiceTier))
            .fontSize(10)
            .fontColor('#FF98A2B3')
          Text('›')
            .fontSize(18)
            .fontColor('#FF98A2B3')
        }
          .width('100%')
          .height(36)
          .padding({ left: 9, right: 7 })
          .onClick(() => this.codexSettingsMenu = 'speed')
      }
    }
    .width(this.codexSettingsMenu === 'models' ? 176 :
      (this.codexSettingsMenu === 'permissions' ? 140 :
        (this.codexSettingsMenu === 'actions' ? 140 : 152)))
    .constraintSize({ maxHeight: 260 })
    .padding(6)
    .backgroundColor(Color.Transparent)
  }

  @Builder
  buildLegacyCodexConversationCover() {
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
                  .copyOption(CopyOptions.LocalDevice)
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
        .fontColor($r('app.color.text_primary'))
        .placeholderColor(this.voiceSecondaryTextColor())
        .backgroundColor(this.voiceInnerSurfaceColor())
        .border({ width: 1, color: this.codexGlassBorderColor() })
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
                .fontColor(this.voiceSecondaryTextColor())
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }
            .width('100%')
            .height(66)
            .padding(0)
            .backgroundColor(this.voiceActionSurfaceColor())
            .backgroundBlurStyle(this.useTwoPaneCodexLayout() ? BlurStyle.NONE : BlurStyle.COMPONENT_ULTRA_THIN, {
              colorMode: ThemeColorMode.SYSTEM,
              adaptiveColor: AdaptiveColor.DEFAULT,
              scale: 0.82
            })
            .border({ width: 1, color: this.codexGlassBorderColor() })
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
                .backgroundColor(this.voiceActionSurfaceColor())
                .border({
                  width: this.voiceGestureAction === VoiceGestureAction.Send ? 2 : 1,
                  color: this.voiceGestureAction === VoiceGestureAction.Send ? '#FFFFFFFF' : this.codexGlassBorderColor()
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
                .backgroundColor(this.voiceActionSurfaceColor())
                .border({
                  width: this.voiceGestureAction === VoiceGestureAction.Edit ? 2 : 1,
                  color: this.voiceGestureAction === VoiceGestureAction.Edit ? '#FFFFFFFF' : this.codexGlassBorderColor()
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
            .fontColor(this.voiceSecondaryTextColor())
        }
        .tabBar(this.buildSubmitModeTab(0, 'Ctrl + 回车'))

        TabContent() {
          Text('发送文字后只按一次回车')
            .width('100%')
            .height(30)
            .textAlign(TextAlign.Center)
            .fontSize(12)
            .fontColor(this.voiceSecondaryTextColor())
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
      .backgroundColor(this.voiceInnerSurfaceColor())
      .backgroundBlurStyle(this.useTwoPaneCodexLayout() ? BlurStyle.NONE : BlurStyle.COMPONENT_ULTRA_THIN, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT,
        scale: 0.72
      })
      .border({ width: 1, color: this.codexGlassBorderColor() })
      .borderRadius(22)
      Row({ space: 10 }) {
        Button('发送文字')
          .layoutWeight(1)
          .height(50)
          .fontSize(16)
          .fontColor(this.isConnected ? $r('app.color.accent_primary') : this.voiceSecondaryTextColor())
          .backgroundColor(this.isConnected ? this.voiceActionSurfaceColor() : '#80D0D5DD')
          .backgroundBlurStyle(this.useTwoPaneCodexLayout() ? BlurStyle.NONE : BlurStyle.COMPONENT_ULTRA_THIN, {
            colorMode: ThemeColorMode.SYSTEM,
            adaptiveColor: AdaptiveColor.DEFAULT,
            scale: 0.78
          })
          .border({ width: 1, color: this.codexGlassBorderColor() })
          .borderRadius(13)
          .shadow({ radius: 14, color: $r('app.color.glass_shadow'), offsetY: 5 })
          .enabled(this.isConnected)
          .onClick(() => this.sendDraft())
        Button('仅按回车')
          .width(104)
          .height(50)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor(this.voiceActionSurfaceColor())
          .border({ width: 1, color: this.codexGlassBorderColor() })
          .borderRadius(13)
          .enabled(this.isConnected)
          .onClick(() => remoteInputClient.sendEnter())
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.codexGlassSurfaceColor())
    .backgroundBlurStyle(this.useTwoPaneCodexLayout() ? BlurStyle.NONE : BlurStyle.COMPONENT_ULTRA_THIN, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT,
      scale: 0.92
    })
    .border({ width: 1, color: this.codexGlassBorderColor() })
    .borderRadius(28)
    .shadow({ radius: 30, color: this.codexGlassShadowColor(), offsetY: 12 })
  }

  @Builder
  buildSubmitModeTab(index: number, label: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontWeight(this.submitMode === (index === 0 ? 'ctrl_enter' : 'enter') ?
          FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.submitMode === (index === 0 ? 'ctrl_enter' : 'enter') ?
          $r('app.color.text_primary') : this.voiceSecondaryTextColor())
        .animation({ duration: 240, curve: Curve.EaseOut })
    }
    .width('94%')
    .height(38)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.submitMode === (index === 0 ? 'ctrl_enter' : 'enter') ?
      this.voiceActionSurfaceColor() : Color.Transparent)
    .border({
      width: 1,
      color: this.submitMode === (index === 0 ? 'ctrl_enter' : 'enter') ?
        this.codexGlassBorderColor() : Color.Transparent
    })
    .borderRadius(19)
    .shadow({
      radius: this.submitMode === (index === 0 ? 'ctrl_enter' : 'enter') ? 10 : 0,
      color: this.codexGlassShadowColor(),
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
      .fontColor(this.voiceSecondaryTextColor())
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor(this.codexGlassSurfaceColor())
      .backgroundBlurStyle(this.useTwoPaneCodexLayout() ? BlurStyle.NONE : BlurStyle.COMPONENT_ULTRA_THIN, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT,
        scale: 0.7
      })
      .border({ width: 1, color: this.codexGlassBorderColor() })
      .borderRadius(18)
  }

  private mainShellWidth(): number {
    if (this.layoutViewportWidth < 600) {
      return Math.max(280, this.layoutViewportWidth - 36);
    }
    if (this.layoutViewportWidth < 900) {
      return Math.min(880, Math.max(520, this.layoutViewportWidth - 32));
    }
    if (this.layoutViewportWidth < 1280) {
      return Math.min(1120, Math.max(760, this.layoutViewportWidth - 48));
    }
    // On 2-in-1/desktop windows keep a readable maximum while using the
    // additional horizontal space for the task sidebar and chat pane.
    return Math.min(1480, Math.max(960, this.layoutViewportWidth - 96));
  }

  private voiceContentWidth(): number {
    const maxWidth = this.layoutViewportWidth >= 1280 ? 1040 :
      (this.layoutViewportWidth >= 900 ? 880 : 760);
    return Math.min(this.mainSectionViewportWidth, maxWidth);
  }

  private mainTabsWidth(): number {
    return Math.min(this.mainSectionViewportWidth, 480);
  }

  private pairingPanelWidth(): number {
    const maxWidth = this.layoutViewportWidth >= 1100 ? 640 : 520;
    const outerPadding = this.layoutViewportWidth < 600 ? 36 : 48;
    return Math.min(maxWidth, Math.max(280, this.layoutViewportWidth - outerPadding));
  }

  private conversationPanelWidth(): number {
    const outerPadding = this.layoutViewportWidth < 600 ? 36 : 72;
    const maxWidth = this.layoutViewportWidth >= 1280 ? 1200 : 960;
    return Math.min(maxWidth, Math.max(280, this.layoutViewportWidth - outerPadding));
  }

  private codexRemoteHomeWidth(): number {
    // The Remote card lives inside the centered main shell. Using the full
    // window width here makes the card wider than its clipped parent on
    // phones, cutting off both rounded sides and the edge content.
    const shellWidth = this.mainShellWidth();
    const measuredWidth = this.mainSectionViewportWidth > 0 ?
      this.mainSectionViewportWidth : shellWidth;
    const availableWidth = Math.min(shellWidth, measuredWidth);
    if (availableWidth < 900) {
      return Math.max(280, availableWidth);
    }
    const maxWidth = availableWidth >= 1280 ? 1240 : 960;
    return Math.min(maxWidth, Math.max(520, availableWidth - 48));
  }

  private useTwoPaneCodexLayout(): boolean {
    // Use the measured content width when available, but allow the layout to
    // settle from the window width during the first render. This avoids a
    // desktop briefly rendering the phone layout after a resize.
    const measuredWidth = Math.max(this.mainSectionViewportWidth, this.layoutViewportWidth);
    return measuredWidth >= 900;
  }

  private codexSidebarWidth(): number {
    return this.mainSectionViewportWidth >= 1180 ? 420 : 360;
  }

  private codexGlassSurfaceColor(): ResourceColor {
    return this.useTwoPaneCodexLayout() ?
      $r('app.color.codex_glass_surface_wide') : $r('app.color.glass_surface');
  }

  private codexGlassBorderColor(): ResourceColor {
    return this.useTwoPaneCodexLayout() ?
      $r('app.color.codex_glass_border_wide') : $r('app.color.glass_border');
  }

  private codexGlassShadowColor(): ResourceColor {
    return this.useTwoPaneCodexLayout() ?
      $r('app.color.codex_glass_shadow_wide') : $r('app.color.glass_shadow');
  }

  private voiceInnerSurfaceColor(): ResourceColor {
    return this.useTwoPaneCodexLayout() ?
      $r('app.color.voice_inner_surface_wide') : $r('app.color.input_background');
  }

  private voiceActionSurfaceColor(): ResourceColor {
    return this.useTwoPaneCodexLayout() ?
      $r('app.color.voice_action_surface_wide') : $r('app.color.glass_surface_strong');
  }

  private voiceSecondaryTextColor(): ResourceColor {
    return this.useTwoPaneCodexLayout() ?
      $r('app.color.voice_text_secondary_wide') : $r('app.color.text_secondary');
  }

  private codexTaskListViewportHeight(): number {
    const loadedCount = Math.min(this.codexTaskDisplayLimit, this.displayedCodexTasks().length);
    const visibleRows = Math.min(loadedCount, this.useTwoPaneCodexLayout() ? 7 : 5);
    const preferredHeight = visibleRows * 64;
    if (!this.useTwoPaneCodexLayout()) {
      return Math.max(68, preferredHeight);
    }
    // Quota card, task-card chrome and vertical gaps consume roughly 300vp
    // above the list in the wide sidebar. Cap the list so short tablet/PC
    // windows keep the sidebar and detail pane inside the viewport.
    const availableHeight = Math.max(180, this.layoutViewportHeight - 300);
    return Math.max(180, Math.min(preferredHeight, availableHeight));
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

  private approvalDisplayKind(): string {
    if (this.approvalKind.includes('commandExecution')) {
      return '命令执行';
    }
    if (this.approvalKind.includes('fileChange')) {
      return '文件修改';
    }
    if (this.approvalKind.includes('permissions')) {
      return '权限提升';
    }
    return '待确认操作';
  }

  private codexTaskNotificationLabel(threadId: string): string {
    for (let index = 0; index < this.codexTasks.length; index += 1) {
      if (this.codexTasks[index].id === threadId) {
        return this.codexTasks[index].title || this.shortPath(this.codexTasks[index].cwd);
      }
    }
    return '请打开 Starly 查看详情';
  }

  private async submitApprovalDecision(decision: string): Promise<void> {
    const approvalId = this.approvalId;
    if (approvalId.length === 0) {
      return;
    }
    const sent = await remoteInputClient.decideCodexApproval(approvalId, decision);
    if (sent) {
      this.clearApprovalSecondConfirmTimer();
      this.approvalId = '';
      this.approvalSecondConfirm = false;
      this.statusText = decision === 'accept' ? '已允许 Codex 操作' : '已拒绝 Codex 操作';
      this.statusIsError = false;
    }
  }

  private armApprovalSecondConfirm(): void {
    this.clearApprovalSecondConfirmTimer();
    this.approvalSecondConfirm = true;
    this.approvalSecondConfirmTimer = setTimeout(() => {
      this.approvalSecondConfirmTimer = -1;
      this.approvalSecondConfirm = false;
    }, 8000);
  }

  private clearApprovalSecondConfirmTimer(): void {
    if (this.approvalSecondConfirmTimer >= 0) {
      clearTimeout(this.approvalSecondConfirmTimer);
      this.approvalSecondConfirmTimer = -1;
    }
  }

  private async initializePage(): Promise<void> {
    try {
      const config = await pairingStore.load(this.getContext());
      this.applyConfig(config);
      this.codexUiComputerKey = this.codexUiKey(config);
      const state = await codexUiStateStore.load(this.getContext(), this.codexUiComputerKey);
      this.applyCodexUiState(state);
      this.preparePendingNotificationTask();
      if (config.isComplete()) {
        this.statusText = '正在连接电脑…';
        await remoteInputClient.connect(config);
      }
    } catch (error) {
      this.statusText = `读取配对信息失败：${JSON.stringify(error)}`;
      this.statusIsError = true;
    }
  }

  private applyCodexUiState(state: CodexUiState): void {
    this.restoredCodexTaskId = state.selectedThreadId;
    this.mainSection = state.mainSection;
    this.codexLastSeenMessageIds = state.lastSeenMessageIds;
    this.codexUnreadCounts = state.unreadCounts;
    this.pinnedCodexThreadIds = state.pinnedThreadIds;
    this.selectedCodexModel = state.selectedModel;
    this.selectedCodexEffort = state.selectedEffort || 'medium';
    this.codexPermissionMode = state.permissionMode || 'default';
    this.selectedCodexServiceTier = state.selectedServiceTier;
    this.codexDeliveryMode = state.deliveryMode === 'desktop' ? 'desktop' : 'background';
    this.desktopSubmitMode = state.desktopSubmitMode === 'ctrl_enter' ? 'ctrl_enter' : 'enter';
    this.restoreCodexDataCache(state);
  }

  private currentCodexUiState(): CodexUiState {
    const state = new CodexUiState();
    state.selectedThreadId = this.selectedCodexTaskId || this.restoredCodexTaskId;
    state.mainSection = this.mainSection;
    state.lastSeenMessageIds = this.codexLastSeenMessageIds;
    state.unreadCounts = this.codexUnreadCounts;
    state.pinnedThreadIds = this.pinnedCodexThreadIds;
    state.selectedModel = this.selectedCodexModel;
    state.selectedEffort = this.selectedCodexEffort;
    state.permissionMode = this.codexPermissionMode;
    state.selectedServiceTier = this.selectedCodexServiceTier;
    state.deliveryMode = this.codexDeliveryMode;
    state.desktopSubmitMode = this.desktopSubmitMode;
    state.cacheSavedAt = Date.now();
    if (this.codexTasks.length > 0 || this.codexModels.length > 0) {
      state.cachedSnapshotJson = JSON.stringify({
        available: this.codexAvailable,
        error: '',
        quota: this.codexQuota,
        threads: this.codexTasks,
        models: this.codexModels
      });
    }
    if (this.selectedCodexTaskId.length > 0) {
      state.cachedThreadJson = JSON.stringify({
        id: this.selectedCodexTaskId,
        title: this.selectedCodexTitle,
        preview: this.codexTaskPreview(this.selectedCodexTaskId),
        status: this.selectedCodexStatus,
        cwd: this.selectedCodexCwd,
        updatedAt: this.selectedCodexUpdatedAt,
        archived: this.selectedCodexArchived,
        messages: this.selectedCodexMessages.slice(-15),
        activities: this.selectedCodexActivities.slice(-30),
        activeTurnId: this.selectedCodexActiveTurnId,
        hasMoreBefore: this.codexHistoryHasMore,
        updateMode: 'latest',
        model: this.selectedCodexModel,
        effort: this.selectedCodexEffort,
        permissionMode: this.codexPermissionMode,
        serviceTier: this.selectedCodexServiceTier
      });
    }
    return state;
  }

  private restoreCodexDataCache(state: CodexUiState): void {
    if (state.cacheSavedAt <= 0 || Date.now() - state.cacheSavedAt > 30 * 24 * 60 * 60 * 1000) {
      return;
    }
    try {
      if (state.cachedSnapshotJson.length > 0) {
        const snapshotSource = JSON.parse(state.cachedSnapshotJson) as Record<string, Object>;
        const snapshot = parseCodexSnapshot(snapshotSource);
        if (snapshot.threads.length > 0 || snapshot.models.length > 0) {
          this.codexTasks = snapshot.threads;
          this.codexModels = snapshot.models;
          this.codexQuota = snapshot.quota;
          this.codexAvailable = snapshot.available;
          this.codexError = '';
          this.codexArchivedTasksLoaded = snapshot.threads.some(
            (task: CodexTask): boolean => task.archived);
          this.codexCacheRestored = true;
        }
      }
      const cachedSelection = this.codexTasks.some(
        (task: CodexTask): boolean => task.id === this.restoredCodexTaskId) ?
        this.restoredCodexTaskId : (this.codexTasks[0]?.id ?? '');
      if (cachedSelection.length > 0) {
        this.selectedCodexTaskId = cachedSelection;
        this.prepareSelectedCodexTask(cachedSelection);
      }
      if (state.cachedThreadJson.length > 0 && this.selectedCodexTaskId.length > 0) {
        const detailSource = JSON.parse(state.cachedThreadJson) as Object;
        const detail = parseCodexThread(detailSource);
        if (detail.id === this.selectedCodexTaskId) {
          detail.updateMode = 'latest';
          this.applyCodexThreadDetail(detail);
        }
      }
      this.codexInitialSyncPending = this.codexCacheRestored;
    } catch (_error) {
      this.codexCacheRestored = false;
    }
  }

  private scheduleCodexUiStateSave(): void {
    if (this.codexUiStateSaveTimer >= 0) {
      clearTimeout(this.codexUiStateSaveTimer);
    }
    this.codexUiStateSaveTimer = setTimeout(() => {
      this.codexUiStateSaveTimer = -1;
      codexUiStateStore.save(this.getContext(), this.codexUiComputerKey,
        this.currentCodexUiState()).catch((): void => {});
    }, 150);
  }

  private flushCodexUiState(): void {
    if (this.codexUiStateSaveTimer >= 0) {
      clearTimeout(this.codexUiStateSaveTimer);
      this.codexUiStateSaveTimer = -1;
    }
    codexUiStateStore.save(this.getContext(), this.codexUiComputerKey,
      this.currentCodexUiState()).catch((): void => {});
  }

  private async discoverPairingComputers(): Promise<void> {
    if (this.isDiscoveringComputers || this.isPairingWithCode) {
      return;
    }
    this.isDiscoveringComputers = true;
    this.pairingDiscoveryMessage = '正在查找同一局域网内的电脑…';
    try {
      const computers = await pairingDiscoveryService.discover();
      this.discoveredComputers = [...computers];
      if (computers.length === 0) {
        this.selectedComputerKey = '';
        this.pairingDiscoveryMessage = '没有发现电脑';
      } else {
        let selectionStillExists = false;
        for (let index = 0; index < computers.length; index += 1) {
          if (computers[index].key() === this.selectedComputerKey) {
            selectionStillExists = true;
            break;
          }
        }
        if (!selectionStillExists) {
          this.selectedComputerKey = computers[0].key();
        }
        this.pairingDiscoveryMessage = `已发现 ${computers.length} 台电脑`;
      }
    } catch (error) {
      this.discoveredComputers = [];
      this.selectedComputerKey = '';
      this.pairingDiscoveryMessage = `搜索失败：${error}`;
    } finally {
      this.isDiscoveringComputers = false;
    }
  }

  private selectedPairingComputer(): DiscoveredComputer | null {
    for (let index = 0; index < this.discoveredComputers.length; index += 1) {
      const computer = this.discoveredComputers[index];
      if (computer.key() === this.selectedComputerKey) {
        return computer;
      }
    }
    return null;
  }

  private async pairSelectedComputer(): Promise<void> {
    if (this.isPairingWithCode) {
      return;
    }
    const computer = this.selectedPairingComputer();
    if (computer === null) {
      this.pairingDiscoveryMessage = '请先选择要连接的电脑';
      return;
    }
    this.isPairingWithCode = true;
    this.pairingDiscoveryMessage = `正在与 ${computer.name} 配对…`;
    try {
      const lanConfig = await pairingDiscoveryService.pair(computer, this.pairingCode);
      const config = this.mergeLanPairing(lanConfig);
      this.applyConfig(config);
      await pairingStore.save(this.getContext(), config);
      this.pairingCode = '';
      this.statusText = '配对成功，正在连接电脑…';
      this.statusIsError = false;
      this.closePairingAfterConnect = true;
      const connected = await remoteInputClient.connect(config);
      if (!connected) {
        this.pairingDiscoveryMessage = '配对信息已保存，但连接电脑失败';
      }
    } catch (error) {
      this.pairingDiscoveryMessage = `${error}`.replace('Error: ', '');
      this.statusText = this.pairingDiscoveryMessage;
      this.statusIsError = true;
    } finally {
      this.isPairingWithCode = false;
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
      const scannedConfig = parsePairingUri(result.originalValue);
      if (scannedConfig === null) {
        this.statusText = '这不是有效的 Starly 配对二维码';
        this.statusIsError = true;
        return;
      }
      const config = scannedConfig.mode === 'gateway' ?
        this.mergeGatewayPairing(scannedConfig) : this.mergeLanPairing(scannedConfig);
      this.applyConfig(config);
      await this.saveAndConnect();
    } catch (_error) {
      this.statusText = '扫码已取消或不可用，可手动填写配对信息';
      this.statusIsError = false;
    }
  }

  private async saveAndConnect(): Promise<void> {
    const config = this.readConfigFromForm();
    config.mode = config.hasGateway() ? 'auto' : 'lan';
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
    this.closePairingAfterConnect = true;
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
    this.gatewayPairingId = '';
    this.gatewayToken = '';
    this.phoneDeviceId = '';
    this.gatewayDeviceCredential = '';
    this.gatewaySessionToken = '';
    this.gatewayPrivateKey = '';
    this.gatewayPublicKey = '';
    this.gatewayPeerPublicKeysJson = '{}';
    this.gatewayBridgeDevices = [];
    this.selectedGatewayBridgeId = '';
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
    this.isMainSectionSwipeBlocked = this.mainSection === 'codex' && this.isCodexDetailTouching;
    if (this.isMainSectionSwipeBlocked) {
      this.mainSectionDragOffset = 0;
      return;
    }
    if (this.mainSectionAnimating || this.isVoicePressing || this.isPairingExpanded) {
      return;
    }
    this.mainSectionDragOffset = 0;
  }

  private updateMainSectionSwipe(offsetX: number): void {
    if (this.isMainSectionSwipeBlocked || this.mainSectionAnimating || this.isVoicePressing || this.isPairingExpanded ||
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
    if (this.isMainSectionSwipeBlocked) {
      this.isMainSectionSwipeBlocked = false;
      this.mainSectionDragOffset = 0;
      return;
    }
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
    if (this.isMainSectionSwipeBlocked) {
      this.isMainSectionSwipeBlocked = false;
      this.mainSectionDragOffset = 0;
      return;
    }
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
    this.scheduleCodexUiStateSave();
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
    this.discoverPairingComputers();
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
    this.closePairingAfterConnect = false;
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

  private selectPairingNetworkMode(mode: string): void {
    this.pairingNetworkMode = mode === 'public' ? 'public' : 'lan';
    this.publicPairingVerification = '';
    if (this.pairingNetworkMode === 'lan' && this.discoveredComputers.length === 0) {
      this.discoverPairingComputers();
    }
  }

  private async selectConnectionMode(mode: string): Promise<void> {
    const nextMode = mode === 'gateway' ? 'gateway' : (mode === 'lan' ? 'lan' : 'auto');
    const config = this.readConfigFromForm();
    if (nextMode === 'lan' && !config.hasLan()) {
      this.statusText = '尚未完成局域网配对';
      this.statusIsError = true;
      return;
    }
    if (nextMode === 'gateway' && !config.hasGateway()) {
      this.statusText = '尚未完成公网配对';
      this.statusIsError = true;
      return;
    }
    if (!config.hasLan() && !config.hasGateway()) {
      this.statusText = '请先完成至少一种配对';
      this.statusIsError = true;
      return;
    }
    config.mode = nextMode;
    this.connectionMode = nextMode;
    await pairingStore.save(this.getContext(), config);
    this.statusText = nextMode === 'auto' ? '已启用局域网优先、公网兜底' :
      (nextMode === 'lan' ? '已切换为仅局域网' : '已切换为仅公网');
    this.statusIsError = false;
    await remoteInputClient.connect(config);
  }

  private async scanPublicPairingCode(): Promise<void> {
    if (!canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')) {
      this.publicPairingStatus = '当前设备不支持扫码，请输入 8 位公网配对码';
      return;
    }
    try {
      const result = await scanBarcode.startScanForResult(this.getContext());
      const request = parsePublicPairingUri(result.originalValue);
      if (request === null) {
        this.publicPairingStatus = '这不是有效的 Starly 公网配对二维码';
        this.statusIsError = true;
        return;
      }
      await this.pairPublicGateway(request);
    } catch (_error) {
      if (!this.isPublicPairing) {
        this.publicPairingStatus = '扫码已取消或不可用';
      }
    }
  }

  private async pairPublicGateway(request: PublicPairingRequest | null): Promise<void> {
    if (this.isPublicPairing) {
      return;
    }
    this.isPublicPairing = true;
    this.publicPairingVerification = '';
    this.publicPairingStatus = '正在连接公网配对服务…';
    try {
      const gatewayConfig = await publicPairingService.pair(
        request, this.publicPairingCode, this.gatewayUrl,
        (message: string, verificationCode: string): void => {
          this.publicPairingStatus = message;
          this.publicPairingVerification = verificationCode;
        });
      const config = this.mergeGatewayPairing(gatewayConfig);
      this.applyConfig(config);
      await pairingStore.save(this.getContext(), config);
      this.publicPairingCode = '';
      this.publicPairingVerification = '';
      this.publicPairingStatus = '公网配对成功，正在连接电脑…';
      this.statusText = '公网配对成功';
      this.statusIsError = false;
      this.closePairingAfterConnect = true;
      await remoteInputClient.connect(config);
    } catch (error) {
      this.publicPairingStatus = `${error}`.replace('Error: ', '');
      this.statusText = this.publicPairingStatus;
      this.statusIsError = true;
    } finally {
      this.isPublicPairing = false;
    }
  }

  private handleCodexDetailTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.isCodexDetailTouching = true;
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.isCodexDetailTouching = false;
    }
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
    this.codexRelativeTimeNow = Date.now();
    this.codexReconcileTick = 0;
    this.codexAutoRefreshTimer = setInterval(() => {
      // Date.now() alone is not reactive in ArkUI. Advance State so relative
      // task times are recomputed while the Codex task list is visible.
      this.codexRelativeTimeNow = Date.now();
      if (!this.isConnected || this.mainSection !== 'codex') {
        return;
      }
      if (this.isCodexConversationOpen && this.selectedCodexGoal.goalId.length > 0 &&
        this.selectedCodexTaskId.length > 0) {
        // Goal state is tiny and independent from the full task list. Refresh
        // the selected detail every tick so pause/limit/completion is reflected
        // on the phone within roughly five seconds.
        remoteInputClient.requestCodexThread(this.selectedCodexTaskId, '', 15);
      }
      this.codexReconcileTick += 1;
      if (this.codexReconcileTick < 6) {
        return;
      }
      this.codexReconcileTick = 0;
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
    if (this.selectedCodexTaskId.length === 0) {
      return false;
    }
    return this.isCodexConversationOpen || this.selectedCodexStatus === 'active' ||
      this.selectedCodexActiveTurnId.length > 0 ||
      this.pendingCodexThreadId === this.selectedCodexTaskId;
  }

  private async refreshCodexAutomatically(): Promise<void> {
    if (this.codexAutoRefreshInFlight || !this.isConnected || this.mainSection !== 'codex') {
      return;
    }
    this.codexAutoRefreshInFlight = true;
    try {
      // The bridge rate-limits requests that arrive within 120 ms. Read the
      // list first, then read the selected task after a short gap so the
      // detail response is not rejected as a burst request.
      await remoteInputClient.requestCodexSnapshot();
      if (!this.codexDetailLoading && this.shouldPollSelectedCodexDetail()) {
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
    if (!force && this.codexDetailLoading) {
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
    const requestId = remoteInputClient.createRequestId();
    this.pendingDraftSendId = requestId;
    const sent = await remoteInputClient.sendText(this.draft, this.submitMode, requestId);
    if (sent) {
      this.statusText = '已发送，等待电脑确认…';
      this.statusIsError = false;
    } else if (this.pendingDraftSendId === requestId) {
      this.pendingDraftSendId = '';
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
    await remoteInputClient.requestCodexQueueSnapshot();
  }

  private async selectCodexTask(threadId: string, pendingText: string = '',
    pendingImage: string = ''): Promise<void> {
    this.clearCodexDetailTimers();
    this.codexDetailRetryCount = 0;
    const previousThreadId = this.selectedCodexTaskId;
    if (previousThreadId.length > 0 && this.selectedCodexStatus !== 'notLoaded') {
      this.rememberCodexTaskStatus(previousThreadId, this.selectedCodexStatus);
    }
    if (previousThreadId.length > 0) {
      this.codexUnreadCounts[previousThreadId] = this.codexUnreadMessages;
    }
    this.selectedCodexTaskId = threadId;
    this.prepareSelectedCodexTask(threadId);
    this.selectedCodexGoal = new CodexGoal();
    this.codexGoalExpanded = false;
    this.selectedCodexMessages = [];
    this.selectedCodexActivities = [];
    this.codexActivityExpanded = false;
    this.selectedCodexActiveTurnId = '';
    this.codexHistoryHasMore = false;
    this.codexHistoryLoadingOlder = false;
    this.codexHistoryReady = false;
    this.codexChatPinnedToBottom = true;
    this.codexUnreadMessages = this.codexUnreadCounts[threadId] ?? 0;
    if (pendingText.length > 0 || pendingImage.length > 0) {
      this.appendPendingCodexMessage(pendingText, pendingImage);
    }
    this.reconcileSelectedCodexQueueMessages();
    this.codexDetailVersion += 1;
    this.codexDetailLoading = false;
    this.codexLoading = false;
    this.scheduleCodexUiStateSave();
    await this.requestSelectedCodexThread(true);
  }

  private async sendCodexCommand(submitMode: string): Promise<void> {
    if (this.selectedCodexTaskId.length === 0 || this.codexImagePicking) {
      return;
    }
    const pendingText = this.codexCommand.trim();
    const pendingImage = this.codexImagePreviewUri;
    const requestId = remoteInputClient.createRequestId();
    const pending = new PendingCodexSend();
    pending.requestId = requestId;
    pending.threadId = this.selectedCodexTaskId;
    pending.text = pendingText;
    pending.image = pendingImage;
    this.pendingCodexSends.set(requestId, pending);
    const sent = this.codexImageDataUrl.length > 0 ?
      await remoteInputClient.sendImageToCodex(
        this.selectedCodexTaskId, this.codexCommand, this.codexImageDataUrl,
        this.codexImageMimeType || 'image/jpeg', submitMode, this.selectedCodexModel,
        this.selectedCodexEffort, this.codexPermissionMode, this.selectedCodexServiceTier,
        this.codexDeliveryMode, requestId) :
      await remoteInputClient.sendToCodex(
        this.selectedCodexTaskId, this.codexCommand, submitMode, this.selectedCodexModel,
        this.selectedCodexEffort, this.codexPermissionMode, this.selectedCodexServiceTier,
        this.codexDeliveryMode, requestId);
    if (sent) {
      this.appendPendingCodexMessage(pendingText, pendingImage, requestId);
      if (this.pendingCodexSends.has(requestId)) {
        this.scheduleCodexAcknowledgementCheck(requestId, this.selectedCodexTaskId);
        this.statusText = '正在加入电脑队列…';
      } else {
        this.updatePendingCodexMessage(requestId, 'sent');
        this.statusText = '指令已加入电脑队列';
      }
      this.statusIsError = false;
    } else if (this.pendingCodexSends.has(requestId)) {
      this.clearPendingCodexAcknowledgement(requestId);
    }
  }

  private async createCodexTask(): Promise<void> {
    if (this.selectedCodexCwd.length === 0 || this.codexCommand.trim().length === 0) {
      return;
    }
    const sent = await remoteInputClient.createCodexTask(
      this.selectedCodexCwd, this.codexCommand, this.selectedCodexModel,
      this.selectedCodexEffort, this.codexPermissionMode, this.selectedCodexServiceTier,
      this.codexImageDataUrl, this.codexImageMimeType || 'image/jpeg', 'background');
    if (sent) {
      this.statusText = '正在所选工作区创建 Codex 任务…';
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
        this.selectedCodexArchived = task.archived;
        this.selectedCodexStatus = this.resolvedCodexStatus(task.id, task.status);
        this.selectedCodexUpdatedAt = task.updatedAt;
        if (this.useTwoPaneCodexLayout() && task.cwd.length > 0 &&
          !this.expandedCodexProjects.includes(task.cwd)) {
          this.expandedCodexProjects = [...this.expandedCodexProjects, task.cwd];
        }
        return;
      }
    }
    this.selectedCodexTitle = '任务详情';
    this.selectedCodexCwd = '';
    this.selectedCodexArchived = false;
    this.selectedCodexStatus = 'notLoaded';
    this.selectedCodexUpdatedAt = 0;
  }

  private codexTaskPreview(threadId: string): string {
    const task = this.codexTasks.find(
      (item: CodexTask): boolean => item.id === threadId);
    return task?.preview ?? '';
  }

  private async toggleArchivedCodexTasks(): Promise<void> {
    const next = !this.showArchivedCodexTasks;
    this.showArchivedCodexTasks = next;
    this.codexTaskDisplayLimit = 10;
    if (!next || this.codexArchivedTasksLoaded || !this.isConnected) {
      return;
    }
    this.codexLoading = true;
    const requested = await remoteInputClient.requestCodexSnapshot(true);
    if (requested) {
      this.codexArchivedTasksLoaded = true;
    } else {
      this.codexLoading = false;
    }
  }

  private toggleCodexTasks(): void {
    this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseOut }, () => {
      this.areCodexTasksExpanded = !this.areCodexTasksExpanded;
    });
  }

  private loadMoreCodexTasks(): void {
    const displayedCount = this.displayedCodexTasks().length;
    if (!this.areCodexTasksExpanded || this.codexTaskDisplayLimit >= displayedCount) {
      return;
    }
    this.codexTaskDisplayLimit = Math.min(this.codexTaskDisplayLimit + 10, displayedCount);
  }

  private displayedCodexTasks(): CodexTask[] {
    const query = this.codexSearchText.trim().toLowerCase();
    return this.sortCodexTasksWithPinned(this.codexTasks.filter((task: CodexTask): boolean => {
      if (task.archived && !this.showArchivedCodexTasks) {
        return false;
      }
      if (query.length === 0) {
        return true;
      }
      return `${task.title}\n${task.preview}\n${task.cwd}`.toLowerCase().includes(query);
    }));
  }

  private codexProjects(): string[] {
    const projects: string[] = [];
    this.codexTasks.forEach((task: CodexTask): void => {
      const cwd = task.cwd.trim();
      if (cwd.length > 0 && !this.isCodexGeneratedChatWorkspace(cwd) && !projects.includes(cwd)) {
        projects.push(cwd);
      }
    });
    return projects;
  }

  private isCodexGeneratedChatWorkspace(cwd: string): boolean {
    const normalized = cwd.trim().replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase();
    return /\/documents\/codex\/\d{4}-\d{2}-\d{2}\/[^/]+$/.test(normalized);
  }

  private isCodexSendOperation(operation: string): boolean {
    return operation === 'codex_send' || operation === 'codex_image_send';
  }

  private clearAcknowledgedCodexComposer(requestId: string): void {
    const pending = this.pendingCodexSends.get(requestId);
    if (pending === undefined) {
      return;
    }
    if (this.codexCommand.trim() === pending.text) {
      this.codexCommand = '';
    }
    if (pending.image.length > 0 && this.codexImagePreviewUri === pending.image) {
      this.clearCodexImage();
    }
    this.clearPendingCodexAcknowledgement(requestId);
  }

  private clearPendingCodexAcknowledgement(requestId: string): void {
    const pending = this.pendingCodexSends.get(requestId);
    if (pending === undefined) {
      return;
    }
    if (pending.timer >= 0) {
      clearTimeout(pending.timer);
    }
    this.pendingCodexSends.delete(requestId);
  }

  private clearAllPendingCodexAcknowledgements(): void {
    this.pendingCodexSends.forEach((pending: PendingCodexSend): void => {
      if (pending.timer >= 0) {
        clearTimeout(pending.timer);
      }
    });
    this.pendingCodexSends.clear();
  }

  private scheduleCodexAcknowledgementCheck(requestId: string, threadId: string): void {
    const pending = this.pendingCodexSends.get(requestId);
    if (pending === undefined) {
      return;
    }
    if (pending.timer >= 0) {
      clearTimeout(pending.timer);
    }
    pending.timer = setTimeout((): void => {
      const active = this.pendingCodexSends.get(requestId);
      if (active === undefined || threadId.length === 0) {
        return;
      }
      active.timer = -1;
      remoteInputClient.requestCodexThread(threadId);
      remoteInputClient.requestCodexQueueSnapshot();
      remoteInputClient.requestCodexSnapshot();
      this.statusText = '正在核对电脑端发送结果…';
      this.statusIsError = false;
    }, 8000);
  }

  private codexHomeProjects(): string[] {
    const projects = [...this.codexProjects()];
    projects.sort((left: string, right: string): number =>
      this.codexProjectTaskCount(right) - this.codexProjectTaskCount(left));
    return projects.slice(0, 5);
  }

  private codexProjectTaskCount(cwd: string): number {
    return this.codexTasks.filter((task: CodexTask): boolean => task.cwd === cwd).length;
  }

  private codexProjectName(cwd: string): string {
    if (cwd.length === 0 || cwd === '__starly_chats__') {
      return '聊天';
    }
    const normalized = cwd.replace(/\\/g, '/');
    const parts = normalized.split('/').filter((part: string): boolean => part.length > 0);
    return parts.length > 0 ? parts[parts.length - 1] : cwd;
  }

  private codexRemoteHomeTasks(): CodexTask[] {
    const query = this.codexSearchText.trim().toLowerCase();
    return this.sortCodexTasksWithPinned(this.codexTasks.filter((task: CodexTask): boolean => {
      if (task.archived && !this.showArchivedCodexTasks) {
        return false;
      }
      if (this.selectedCodexProject === '__starly_chats__') {
        if (!this.isCodexGeneratedChatWorkspace(task.cwd)) {
          return false;
        }
      } else if (this.selectedCodexProject.length > 0 && task.cwd !== this.selectedCodexProject) {
        return false;
      }
      return query.length === 0 ||
        `${task.title}\n${task.preview}\n${task.cwd}`.toLowerCase().includes(query);
    }));
  }

  private codexDesktopProjects(): string[] {
    const query = this.codexSearchText.trim().toLowerCase();
    const projects = this.codexProjects().filter((project: string): boolean => {
      if (query.length === 0) {
        return true;
      }
      return this.codexTasks.some((task: CodexTask): boolean =>
        task.cwd === project &&
        `${task.title}\n${task.preview}\n${project}`.toLowerCase().includes(query));
    });
    projects.sort((left: string, right: string): number => {
      const countDifference = this.codexProjectTaskCount(right) - this.codexProjectTaskCount(left);
      return countDifference !== 0 ? countDifference :
        this.codexProjectName(left).localeCompare(this.codexProjectName(right));
    });
    return projects;
  }

  private codexTasksForDesktopProject(project: string): CodexTask[] {
    const query = this.codexSearchText.trim().toLowerCase();
    const tasks = this.codexTasks.filter((task: CodexTask): boolean => {
      if (task.cwd !== project || (task.archived && !this.showArchivedCodexTasks)) {
        return false;
      }
      return query.length === 0 ||
        `${task.title}\n${task.preview}\n${task.cwd}`.toLowerCase().includes(query);
    });
    return this.sortCodexTasksWithPinned(tasks);
  }

  private isCodexProjectExpanded(project: string): boolean {
    return this.expandedCodexProjects.includes(project);
  }

  private toggleCodexProject(project: string): void {
    const expanded = [...this.expandedCodexProjects];
    const index = expanded.indexOf(project);
    if (index >= 0) {
      expanded.splice(index, 1);
    } else {
      expanded.push(project);
    }
    this.expandedCodexProjects = expanded;
  }

  private async openDesktopCodexTask(threadId: string, project: string): Promise<void> {
    if (!this.isCodexProjectExpanded(project)) {
      this.toggleCodexProject(project);
    }
    this.codexNewTaskMode = false;
    this.codexSettingsMenu = '';
    await this.selectCodexTask(threadId);
  }

  private sortCodexTasksWithPinned(tasks: CodexTask[]): CodexTask[] {
    const result = [...tasks];
    result.sort((left: CodexTask, right: CodexTask): number => {
      const leftIndex = this.pinnedCodexThreadIds.indexOf(left.id);
      const rightIndex = this.pinnedCodexThreadIds.indexOf(right.id);
      if (leftIndex >= 0 && rightIndex >= 0) {
        return leftIndex - rightIndex;
      }
      if (leftIndex >= 0) {
        return -1;
      }
      if (rightIndex >= 0) {
        return 1;
      }
      return right.updatedAt - left.updatedAt;
    });
    return result;
  }

  private codexTaskRenderKey(task: CodexTask, prefix: string): string {
    const pinned = this.isCodexTaskPinned(task.id) ? 1 : 0;
    const selected = this.selectedCodexTaskId === task.id ? 1 : 0;
    const syncing = this.codexInitialSyncPending ? 1 : 0;
    return `${prefix}:${task.id}:${task.updatedAt}:${this.effectiveCodexStatus(task)}:` +
      `${task.title}:${task.preview}:${task.cwd}:${task.archived ? 1 : 0}:` +
      `${pinned}:${this.codexTaskUnreadCount(task.id)}:${selected}:${syncing}`;
  }

  private formatCodexRelativeTime(timestamp: number): string {
    if (timestamp <= 0) {
      return '';
    }
    const seconds = timestamp > 100000000000 ? Math.floor(timestamp / 1000) : timestamp;
    const elapsed = Math.max(0, Math.floor(this.codexRelativeTimeNow / 1000) - seconds);
    if (elapsed < 60) {
      return '刚刚';
    }
    if (elapsed < 3600) {
      return `${Math.floor(elapsed / 60)}分钟`;
    }
    if (elapsed < 86400) {
      return `${Math.floor(elapsed / 3600)}小时`;
    }
    return `${Math.floor(elapsed / 86400)}天`;
  }

  private codexGoalStatusLabel(): string {
    const labels: Record<string, string> = {
      'active': '进行中',
      'paused': '已暂停',
      'blocked': '已阻塞',
      'usage_limited': '使用受限',
      'budget_limited': '预算受限',
      'complete': '已完成'
    };
    return labels[this.selectedCodexGoal.status] ?? '目标';
  }

  private codexGoalStatusColor(): string {
    if (this.selectedCodexGoal.status === 'complete') {
      return '#FF067647';
    }
    if (this.selectedCodexGoal.status === 'blocked') {
      return '#FFB42318';
    }
    if (this.selectedCodexGoal.status === 'usage_limited' ||
      this.selectedCodexGoal.status === 'budget_limited') {
      return '#FFB54708';
    }
    if (this.selectedCodexGoal.status === 'active') {
      return '#FF175CD3';
    }
    return '#FF667085';
  }

  private formatCodexGoalElapsed(): string {
    let seconds = Math.max(0, this.selectedCodexGoal.timeUsedSeconds);
    if (this.selectedCodexGoal.status === 'active' && this.selectedCodexGoal.updatedAt > 0) {
      seconds += Math.max(0, Math.floor(
        (this.codexRelativeTimeNow - this.selectedCodexGoal.updatedAt) / 1000));
    }
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    if (hours > 0) {
      return `${hours}小时${minutes}分`;
    }
    if (minutes > 0) {
      return `${minutes}分钟`;
    }
    return `${seconds}秒`;
  }

  private cloneCodexGoal(source: CodexGoal): CodexGoal {
    const goal = new CodexGoal();
    goal.goalId = source.goalId;
    goal.objective = source.objective;
    goal.status = source.status;
    goal.tokenBudget = source.tokenBudget;
    goal.tokensUsed = source.tokensUsed;
    goal.timeUsedSeconds = source.timeUsedSeconds;
    goal.createdAt = source.createdAt;
    goal.updatedAt = source.updatedAt;
    return goal;
  }

  private codexDisplayText(value: string): string {
    return value
      .replace(/^#{1,6}\s+/gm, '')
      .replace(/\[([^\]]+)\]\([^\)]+\)/g, '$1')
      .replace(/::codex-inline-vis\{[^\}]+\}/g, '可视化内容请在电脑端查看')
      .replace(/`([^`]+)`/g, '$1')
      .replace(/\*\*([^*]+)\*\*/g, '$1');
  }

  private openRemoteCodexTask(threadId: string): void {
    this.codexNewTaskMode = false;
    this.codexSettingsMenu = '';
    if (this.useTwoPaneCodexLayout()) {
      this.isCodexConversationOpen = false;
      this.selectCodexTask(threadId);
      setTimeout(() => {
        if (!this.isCodexConversationOpen && this.selectedCodexTaskId === threadId) {
          this.scrollCodexChatToBottom(false);
        }
      }, 320);
      return;
    }
    this.isCodexConversationOpen = true;
    this.selectCodexTask(threadId);
    // The content cover has its own entrance animation. Re-anchor once it is
    // fully laid out even when the thread response arrived immediately.
    setTimeout(() => {
      if (this.isCodexConversationOpen && this.selectedCodexTaskId === threadId) {
        this.scrollCodexChatToBottom(false);
      }
    }, 520);
  }

  private handleNotificationTaskOpen(threadId: string): void {
    if (threadId.length === 0) {
      return;
    }
    this.pendingNotificationThreadId = threadId;
    this.preparePendingNotificationTask();
    this.openPendingNotificationTask();
  }

  private preparePendingNotificationTask(): void {
    if (this.pendingNotificationThreadId.length === 0) {
      return;
    }
    if (this.mainSection !== 'codex') {
      this.mainSection = 'codex';
      this.mainSectionDragOffset = 0;
      this.scheduleCodexUiStateSave();
    }
  }

  private openPendingNotificationTask(): void {
    if (!this.isConnected || this.pendingNotificationThreadId.length === 0) {
      return;
    }
    const threadId = this.pendingNotificationThreadId;
    this.pendingNotificationThreadId = '';
    this.openRemoteCodexTask(threadId);
    remoteInputClient.requestCodexSnapshot();
    this.startCodexAutoRefresh();
  }

  private openNewCodexTask(): void {
    const selectedProject = this.selectedCodexProject === '__starly_chats__' ? '' :
      this.selectedCodexProject;
    const project = selectedProject || this.codexProjects()[0] || '';
    if (project.length === 0) {
      this.statusText = '请先在电脑 Codex 中打开一个项目';
      this.statusIsError = true;
      return;
    }
    this.codexNewTaskMode = true;
    this.selectedCodexTaskId = '';
    this.selectedCodexTitle = '新任务';
    this.selectedCodexCwd = project;
    this.selectedCodexGoal = new CodexGoal();
    this.codexGoalExpanded = false;
    this.selectedCodexMessages = [];
    this.codexCommand = '';
    this.codexSettingsMenu = '';
    this.isCodexConversationOpen = true;
  }

  private closeRemoteCodexConversation(): void {
    this.codexSettingsMenu = '';
    this.codexFullAccessConfirm = false;
    this.codexVoiceTarget = false;
    this.codexVoiceListening = false;
    speechService.stop().catch((): void => {});
    this.isCodexConversationOpen = false;
    if (this.codexNewTaskMode) {
      this.codexNewTaskMode = false;
      this.selectedCodexTaskId = '';
      this.selectedCodexMessages = [];
    } else {
      this.markSelectedCodexRead();
    }
  }

  private clearCodexImage(): void {
    this.codexImagePreviewUri = '';
    this.codexImageDataUrl = '';
    this.codexImageMimeType = '';
  }

  private canSendRemoteCodexComposer(): boolean {
    const hasContent = this.codexCommand.trim().length > 0 || this.codexImageDataUrl.length > 0;
    if (!hasContent || !this.isConnected || this.codexImagePicking) {
      return false;
    }
    return this.codexNewTaskMode ? this.selectedCodexCwd.length > 0 &&
      this.codexCommand.trim().length > 0 : this.selectedCodexTaskId.length > 0;
  }

  private async sendRemoteCodexComposer(): Promise<void> {
    this.codexSettingsMenu = '';
    if (this.codexNewTaskMode) {
      await this.createCodexTask();
    } else {
      const submitMode = this.codexDeliveryMode === 'desktop' ? this.desktopSubmitMode : 'enter';
      await this.sendCodexCommand(submitMode);
    }
  }

  private async toggleCodexVoiceInput(): Promise<void> {
    if (this.codexVoiceListening) {
      await speechService.stop();
      return;
    }
    this.codexVoiceTarget = true;
    const started = await speechService.start();
    if (!started) {
      this.codexVoiceTarget = false;
      this.codexVoiceListening = false;
    }
  }

  private selectedCodexModelOption(): CodexModelOption | undefined {
    return this.codexModels.find(
      (model: CodexModelOption): boolean => model.model === this.selectedCodexModel);
  }

  private isCodexModelSettingsMenu(): boolean {
    return this.codexSettingsMenu === 'main' || this.codexSettingsMenu === 'models' ||
      this.codexSettingsMenu === 'effort' || this.codexSettingsMenu === 'speed';
  }

  private selectedCodexModelLabel(): string {
    const model = this.selectedCodexModelOption();
    return model?.displayName || this.selectedCodexModel || '默认模型';
  }

  private codexReasoningEfforts(): string[] {
    const model = this.selectedCodexModelOption();
    const efforts = model?.supportedReasoningEfforts.map(
      (option: CodexReasoningOption): string => option.effort) ?? [];
    if (efforts.length > 0) {
      return efforts;
    }
    const fallback = this.selectedCodexEffort || model?.defaultReasoningEffort || 'medium';
    return [fallback];
  }

  private codexEffortLabel(): string {
    return this.codexEffortLabelFor(this.selectedCodexEffort);
  }

  private codexEffortLabelFor(effort: string): string {
    if (effort === 'low') return '低';
    if (effort === 'medium') return '中';
    if (effort === 'high') return '高';
    if (effort === 'xhigh') return '超高';
    if (effort === 'max') return '最高';
    if (effort === 'ultra') return 'Ultra（自动委派）';
    return effort;
  }

  private selectCodexModel(model: CodexModelOption): void {
    this.selectedCodexModel = model.model;
    if (!model.supportedReasoningEfforts.some(
      (option: CodexReasoningOption): boolean => option.effort === this.selectedCodexEffort)) {
      this.selectedCodexEffort = model.defaultReasoningEffort || 'medium';
    }
    this.selectedCodexServiceTier = '';
    this.codexSettingsMenu = '';
    this.scheduleCodexUiStateSave();
  }

  private selectCodexEffort(effort: string): void {
    this.selectedCodexEffort = effort;
    this.codexSettingsMenu = '';
    this.scheduleCodexUiStateSave();
  }

  private codexPermissionLabel(): string {
    return this.codexPermissionLabelFor(this.codexPermissionMode);
  }

  private codexPermissionLabelFor(mode: string): string {
    if (mode === 'autoApprove') return '自动审批';
    if (mode === 'readOnly') return '只读';
    if (mode === 'fullAccess') return this.codexFullAccessConfirm ? '再次点按：完全访问' : '完全访问权限';
    return '默认权限';
  }

  private selectCodexPermission(mode: string): void {
    if (mode === 'fullAccess' && !this.codexFullAccessConfirm) {
      this.codexFullAccessConfirm = true;
      this.statusText = '完全访问将取消沙箱和审批；请再次点按确认';
      this.statusIsError = true;
      return;
    }
    this.codexPermissionMode = mode;
    this.codexFullAccessConfirm = false;
    this.codexSettingsMenu = '';
    this.statusText = mode === 'fullAccess' ? '已启用完全访问权限' : '运行权限已更新';
    this.statusIsError = mode === 'fullAccess';
    this.scheduleCodexUiStateSave();
  }

  private codexServiceTierOptions(): string[] {
    const available = this.selectedCodexModelOption()?.serviceTiers ?? [];
    const result: string[] = [''];
    for (let index = 0; index < available.length; index += 1) {
      const tier = available[index];
      if (tier.length > 0 && tier !== 'default' && !result.includes(tier)) {
        result.push(tier);
      }
    }
    return result;
  }

  private codexServiceTierLabel(tier: string): string {
    if (tier.length === 0 || tier === 'default') return '标准';
    if (tier === 'priority' || tier === 'fast') return '快速（1.5×）';
    return tier;
  }

  private selectCodexServiceTier(tier: string): void {
    this.selectedCodexServiceTier = tier;
    this.codexSettingsMenu = '';
    this.scheduleCodexUiStateSave();
  }

  private selectCodexDeliveryMode(mode: string): void {
    this.codexDeliveryMode = mode === 'desktop' ? 'desktop' : 'background';
    this.statusText = this.codexDeliveryMode === 'desktop' ?
      '已切换为桌面输入框发送' : '已切换为默认发送模式';
    this.statusIsError = false;
    this.scheduleCodexUiStateSave();
  }

  private selectDesktopSubmitMode(mode: string): void {
    this.desktopSubmitMode = mode === 'ctrl_enter' ? 'ctrl_enter' : 'enter';
    this.statusText = this.desktopSubmitMode === 'ctrl_enter' ?
      '桌面发送按钮将使用 Ctrl + 回车' : '桌面发送按钮将使用回车';
    this.statusIsError = false;
    this.scheduleCodexUiStateSave();
  }

  private async toggleSelectedCodexArchived(): Promise<void> {
    if (this.selectedCodexTaskId.length === 0 || this.isSelectedCodexRunning()) {
      return;
    }
    const next = !this.selectedCodexArchived;
    const sent = await remoteInputClient.setCodexArchived(this.selectedCodexTaskId, next);
    if (sent) {
      this.selectedCodexArchived = next;
      this.statusText = next ? '正在归档任务…' : '正在恢复任务…';
      this.statusIsError = false;
      setTimeout(() => remoteInputClient.requestCodexSnapshot(), 350);
    }
  }

  private codexTaskForMenu(): CodexTask | undefined {
    return this.codexTasks.find(
      (task: CodexTask): boolean => task.id === this.codexTaskMenuId);
  }

  private codexTaskMenuTitle(): string {
    return this.codexTaskForMenu()?.title || 'Codex 任务';
  }

  private openCodexTaskMenu(threadId: string, event: GestureEvent): void {
    const menuWidth = 176;
    const menuHeight = 184;
    const finger = event.fingerList.length > 0 ? event.fingerList[0] : undefined;
    const touchX = finger?.globalX ?? this.layoutViewportWidth / 2;
    const touchY = finger?.globalY ?? this.layoutViewportHeight / 2;
    this.codexTaskMenuX = touchX + menuWidth + 16 <= this.layoutViewportWidth ?
      touchX + 8 : Math.max(8, touchX - menuWidth - 8);
    this.codexTaskMenuY = touchY + menuHeight + 16 <= this.layoutViewportHeight ?
      touchY + 8 : Math.max(8, touchY - menuHeight - 8);
    if (this.codexTaskMenuAnimationTimer >= 0) {
      clearTimeout(this.codexTaskMenuAnimationTimer);
      this.codexTaskMenuAnimationTimer = -1;
    }
    this.codexTaskMenuExpanded = false;
    this.codexTaskMenuId = threadId;
    this.codexTaskRenameMode = false;
    this.codexTaskRenameText = '';
    this.triggerCodexTaskMenuHaptic();
    this.codexTaskMenuAnimationTimer = setTimeout(() => {
      this.codexTaskMenuAnimationTimer = -1;
      this.codexTaskMenuExpanded = true;
    }, 12);
  }

  private openCodexQueueMenu(message: CodexMessage, event: GestureEvent): void {
    const item = this.codexQueueItemForMessage(message);
    if (item === undefined || !this.isCodexQueueItemCancelable(item)) {
      return;
    }
    const menuWidth = 136;
    const menuHeight = 56;
    const finger = event.fingerList.length > 0 ? event.fingerList[0] : undefined;
    const touchX = finger?.globalX ?? this.layoutViewportWidth / 2;
    const touchY = finger?.globalY ?? this.layoutViewportHeight / 2;
    this.codexQueueMenuX = touchX + menuWidth + 16 <= this.layoutViewportWidth ?
      touchX + 8 : Math.max(8, touchX - menuWidth - 8);
    this.codexQueueMenuY = touchY + menuHeight + 16 <= this.layoutViewportHeight ?
      touchY + 8 : Math.max(8, touchY - menuHeight - 8);
    if (this.codexQueueMenuAnimationTimer >= 0) {
      clearTimeout(this.codexQueueMenuAnimationTimer);
    }
    this.codexQueueMenuExpanded = false;
    this.codexQueueMenuId = item.queueId;
    this.triggerCodexTaskMenuHaptic();
    this.codexQueueMenuAnimationTimer = setTimeout((): void => {
      this.codexQueueMenuAnimationTimer = -1;
      this.codexQueueMenuExpanded = true;
    }, 12);
  }

  private closeCodexQueueMenu(): void {
    if (this.codexQueueMenuId.length === 0) {
      return;
    }
    if (this.codexQueueMenuAnimationTimer >= 0) {
      clearTimeout(this.codexQueueMenuAnimationTimer);
    }
    this.codexQueueMenuExpanded = false;
    this.codexQueueMenuAnimationTimer = setTimeout((): void => {
      this.codexQueueMenuAnimationTimer = -1;
      this.codexQueueMenuId = '';
    }, 145);
  }

  private async cancelCodexQueueFromMenu(): Promise<void> {
    const queueId = this.codexQueueMenuId;
    if (queueId.length === 0) {
      return;
    }
    this.closeCodexQueueMenu();
    const sent = await remoteInputClient.cancelCodexQueueItem(queueId);
    if (sent) {
      this.statusText = '正在取消排队任务…';
      this.statusIsError = false;
    }
  }

  private closeCodexTaskMenu(): void {
    if (this.codexTaskMenuId.length === 0) {
      return;
    }
    if (this.codexTaskMenuAnimationTimer >= 0) {
      clearTimeout(this.codexTaskMenuAnimationTimer);
    }
    this.codexTaskMenuExpanded = false;
    this.codexTaskMenuAnimationTimer = setTimeout(() => {
      this.codexTaskMenuAnimationTimer = -1;
      this.codexTaskMenuId = '';
      this.codexTaskRenameMode = false;
      this.codexTaskRenameText = '';
    }, 150);
  }

  private triggerCodexTaskMenuHaptic(): void {
    const effect: vibrator.VibratePreset = {
      type: 'preset',
      effectId: vibrator.HapticFeedback.EFFECT_SOFT,
      count: 1
    };
    const attribute: vibrator.VibrateAttribute = { usage: 'touch' };
    try {
      vibrator.startVibration(effect, attribute).catch((): void => {});
    } catch (_error) {
      // Some tablets and emulators do not include a vibrator.
    }
  }

  private isCodexTaskPinned(threadId: string): boolean {
    return this.pinnedCodexThreadIds.includes(threadId);
  }

  private toggleCodexTaskPinned(threadId: string): void {
    const next = [...this.pinnedCodexThreadIds];
    const index = next.indexOf(threadId);
    if (index >= 0) {
      next.splice(index, 1);
      this.statusText = '已取消置顶';
    } else {
      next.unshift(threadId);
      this.statusText = '任务已置顶';
    }
    this.pinnedCodexThreadIds = next;
    this.statusIsError = false;
    this.scheduleCodexUiStateSave();
    this.closeCodexTaskMenu();
  }

  private markCodexTaskUnread(threadId: string): void {
    const next: Record<string, number> = {};
    Object.keys(this.codexUnreadCounts).forEach((key: string): void => {
      next[key] = this.codexUnreadCounts[key];
    });
    next[threadId] = Math.max(1, next[threadId] ?? 0);
    this.codexUnreadCounts = next;
    this.codexLastSeenMessageIds[threadId] = '';
    if (threadId === this.selectedCodexTaskId) {
      this.codexUnreadMessages = next[threadId];
    }
    this.statusText = '已标记为未读';
    this.statusIsError = false;
    this.scheduleCodexUiStateSave();
    this.closeCodexTaskMenu();
  }

  private openCodexTaskRename(): void {
    this.codexTaskRenameText = this.codexTaskMenuTitle();
    this.codexTaskRenameMode = true;
  }

  private async renameCodexTaskFromMenu(): Promise<void> {
    const threadId = this.codexTaskMenuId;
    const name = this.codexTaskRenameText.trim();
    if (threadId.length === 0 || name.length === 0) {
      return;
    }
    const sent = await remoteInputClient.renameCodexTask(threadId, name);
    if (!sent) {
      return;
    }
    const tasks = [...this.codexTasks];
    const taskIndex = tasks.findIndex((task: CodexTask): boolean => task.id === threadId);
    if (taskIndex >= 0) {
      const task = this.cloneCodexTask(tasks[taskIndex]);
      task.title = name;
      tasks[taskIndex] = task;
      this.codexTasks = tasks;
    }
    if (threadId === this.selectedCodexTaskId) {
      this.selectedCodexTitle = name;
    }
    this.statusText = '正在重命名任务…';
    this.statusIsError = false;
    this.closeCodexTaskMenu();
    setTimeout(() => remoteInputClient.requestCodexSnapshot(), 350);
  }

  private isCodexTaskMenuRunning(): boolean {
    const task = this.codexTaskForMenu();
    return task !== undefined && this.effectiveCodexStatus(task) === 'active';
  }

  private async archiveCodexTaskFromMenu(): Promise<void> {
    const threadId = this.codexTaskMenuId;
    if (threadId.length === 0 || this.isCodexTaskMenuRunning()) {
      return;
    }
    const sent = await remoteInputClient.setCodexArchived(threadId, true);
    if (!sent) {
      return;
    }
    if (threadId === this.selectedCodexTaskId) {
      this.selectedCodexArchived = true;
    }
    this.statusText = '正在归档任务…';
    this.statusIsError = false;
    this.closeCodexTaskMenu();
    setTimeout(() => remoteInputClient.requestCodexSnapshot(), 350);
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

  private applyCodexQueueSnapshot(items: CodexQueueItem[]): void {
    const previous = this.codexQueueItems;
    this.codexQueueItems = [...items];
    this.reconcileSelectedCodexQueueMessages(previous);
  }

  private applyCodexQueueEvent(item: CodexQueueItem): void {
    const items = [...this.codexQueueItems];
    const existingIndex = items.findIndex(
      (current: CodexQueueItem): boolean => current.queueId === item.queueId);
    if (existingIndex >= 0) {
      items[existingIndex] = item;
    } else {
      items.push(item);
    }
    this.codexQueueItems = items;
    if (item.state === 'running') {
      this.pendingCodexThreadId = item.threadId;
      this.rememberCodexTaskStatus(item.threadId, 'active');
      if (item.threadId === this.selectedCodexTaskId) {
        this.selectedCodexStatus = 'active';
      }
    } else if (item.state === 'completed' || item.state === 'failed' || item.state === 'canceled') {
      if (!this.hasRunningCodexQueueItem(item.threadId) && this.pendingCodexThreadId === item.threadId) {
        this.pendingCodexThreadId = '';
      }
      if (item.state === 'failed') {
        this.statusText = item.error.length > 0 ? `排队任务失败：${item.error}` : '排队任务执行失败';
        this.statusIsError = true;
      } else if (item.state === 'canceled') {
        this.statusText = '已取消排队任务';
        this.statusIsError = false;
      }
    }
    this.reconcileSelectedCodexQueueMessages();
    if (item.state === 'completed' && item.threadId === this.selectedCodexTaskId) {
      setTimeout((): void => {
        if (item.threadId === this.selectedCodexTaskId && this.isConnected) {
          this.requestSelectedCodexThread(true);
          remoteInputClient.requestCodexSnapshot();
        }
      }, 120);
    }
  }

  private hasRunningCodexQueueItem(threadId: string): boolean {
    return this.codexQueueItems.some(
      (item: CodexQueueItem): boolean => item.threadId === threadId && item.state === 'running');
  }

  private isCodexQueueItemVisible(item: CodexQueueItem): boolean {
    return item.state === 'queued' || item.state === 'running' ||
      item.state === 'waiting_unlock' || item.state === 'failed' || item.state === 'canceled';
  }

  private isCodexQueueItemCancelable(item: CodexQueueItem): boolean {
    return item.state === 'queued' || item.state === 'waiting_unlock';
  }

  private normalizedCodexQueueTimestamp(item: CodexQueueItem): number {
    const timestamp = item.enqueuedAt > 0 ? item.enqueuedAt :
      (item.startedAt > 0 ? item.startedAt : Date.now());
    return timestamp > 100000000000 ? Math.floor(timestamp / 1000) : timestamp;
  }

  private codexQueueItemForMessage(message: CodexMessage): CodexQueueItem | undefined {
    if (message.id.startsWith('local-')) {
      const queueId = message.id.substring('local-'.length);
      const exact = this.codexQueueItems.find(
        (item: CodexQueueItem): boolean => item.queueId === queueId);
      if (exact !== undefined) {
        return exact;
      }
    }
    if (message.role !== 'user' || this.selectedCodexTaskId.length === 0) {
      return undefined;
    }
    const messageText = message.text.trim();
    let closest: CodexQueueItem | undefined = undefined;
    let closestDistance = Number.MAX_SAFE_INTEGER;
    for (let index = 0; index < this.codexQueueItems.length; index += 1) {
      const item = this.codexQueueItems[index];
      if (item.threadId !== this.selectedCodexTaskId || item.text.trim() !== messageText) {
        continue;
      }
      const distance = Math.abs(this.normalizedCodexQueueTimestamp(item) - message.timestamp);
      if (distance <= 180 && distance < closestDistance) {
        closest = item;
        closestDistance = distance;
      }
    }
    return closest;
  }

  private cloneCodexMessage(source: CodexMessage): CodexMessage {
    const message = new CodexMessage();
    message.id = source.id;
    message.role = source.role;
    message.text = source.text;
    message.images = [...source.images];
    message.timestamp = source.timestamp;
    message.turnId = source.turnId;
    message.deliveryState = source.deliveryState;
    return message;
  }

  private queueMessageFromItem(item: CodexQueueItem): CodexMessage {
    const message = new CodexMessage();
    message.id = `local-${item.queueId}`;
    message.role = 'user';
    message.text = item.text.trim().length > 0 ? item.text : (item.hasImage ? '图片' : '排队指令');
    message.timestamp = this.normalizedCodexQueueTimestamp(item);
    message.turnId = message.id;
    message.deliveryState = item.state;
    return message;
  }

  private reconcileSelectedCodexQueueMessages(previousItems: CodexQueueItem[] = []): void {
    const threadId = this.selectedCodexTaskId;
    if (threadId.length === 0) {
      return;
    }
    const currentItems = this.codexQueueItems.filter(
      (item: CodexQueueItem): boolean => item.threadId === threadId);
    const hasQueueDeliveryState = this.selectedCodexMessages.some((message: CodexMessage): boolean =>
      message.deliveryState === 'queued' || message.deliveryState === 'running' ||
        message.deliveryState === 'waiting_unlock' || message.deliveryState === 'canceled');
    if (currentItems.length === 0 && previousItems.length === 0 && !hasQueueDeliveryState) {
      return;
    }
    const currentIds = new Set<string>();
    currentItems.forEach((item: CodexQueueItem): void => {
      currentIds.add(item.queueId);
    });
    const previousIds = new Set<string>();
    previousItems.forEach((item: CodexQueueItem): void => {
      if (item.threadId === threadId) previousIds.add(item.queueId);
    });
    const messages: CodexMessage[] = [];
    for (let index = 0; index < this.selectedCodexMessages.length; index += 1) {
      const source = this.selectedCodexMessages[index];
      const localQueueId = source.id.startsWith('local-') ?
        source.id.substring('local-'.length) : '';
      if (localQueueId.length > 0 && previousIds.has(localQueueId) && !currentIds.has(localQueueId)) {
        continue;
      }
      const copy = this.cloneCodexMessage(source);
      if (!copy.id.startsWith('local-') &&
        (copy.deliveryState === 'queued' || copy.deliveryState === 'running' ||
        copy.deliveryState === 'waiting_unlock' || copy.deliveryState === 'canceled')) {
        copy.deliveryState = '';
      }
      messages.push(copy);
    }
    const matchedPersistedIndexes = new Set<number>();
    for (let itemIndex = 0; itemIndex < currentItems.length; itemIndex += 1) {
      const item = currentItems[itemIndex];
      let messageIndex = messages.findIndex(
        (message: CodexMessage): boolean => message.id === `local-${item.queueId}`);
      if (messageIndex < 0) {
        messageIndex = messages.findIndex((message: CodexMessage, index: number): boolean => {
          if (matchedPersistedIndexes.has(index)) {
            return false;
          }
          if (message.role !== 'user' || message.id.startsWith('local-') ||
            message.text.trim() !== item.text.trim()) {
            return false;
          }
          return Math.abs(message.timestamp - this.normalizedCodexQueueTimestamp(item)) <= 180;
        });
        if (messageIndex >= 0) {
          matchedPersistedIndexes.add(messageIndex);
        }
      }
      if (item.state === 'completed') {
        if (messageIndex >= 0 && messages[messageIndex].id.startsWith('local-')) {
          messages.splice(messageIndex, 1);
        } else if (messageIndex >= 0) {
          messages[messageIndex].deliveryState = '';
        }
        continue;
      }
      if (!this.isCodexQueueItemVisible(item)) {
        continue;
      }
      if (messageIndex >= 0) {
        messages[messageIndex].deliveryState = item.state;
      } else {
        messages.push(this.queueMessageFromItem(item));
      }
    }
    this.selectedCodexMessages = messages;
    this.codexDetailVersion += 1;
    if (this.codexChatPinnedToBottom) {
      this.scrollCodexChatToBottom(true);
    }
  }

  private applyCodexThreadDetail(detail: CodexThreadDetail): void {
    detail.status = normalizeCodexDetailStatus(detail.status, detail.activeTurnId);
    this.applyCodexTaskDelta(detail);
    this.rememberCodexTaskStatus(detail.id, detail.status);
    if (detail.id !== this.selectedCodexTaskId) {
      return;
    }
    this.selectedCodexTitle = detail.title;
    this.selectedCodexCwd = detail.cwd;
    this.selectedCodexArchived = detail.archived;
    this.selectedCodexStatus = detail.status;
    this.selectedCodexActiveTurnId = detail.activeTurnId;
    this.selectedCodexUpdatedAt = detail.updatedAt;
    if (this.selectedCodexGoal.goalId !== detail.goal.goalId) {
      this.codexGoalExpanded = false;
    }
    this.selectedCodexGoal = this.cloneCodexGoal(detail.goal);
    if (detail.model.length > 0) {
      this.selectedCodexModel = detail.model;
    }
    if (detail.effort.length > 0) {
      this.selectedCodexEffort = detail.effort;
    }
    if (detail.permissionMode.length > 0) {
      this.codexPermissionMode = detail.permissionMode;
      this.codexFullAccessConfirm = false;
    }
    this.selectedCodexServiceTier = detail.serviceTier;
    if (detail.updateMode === 'delta') {
      this.mergeLatestCodexActivities(detail.activities);
    } else if (detail.updateMode !== 'older') {
      this.selectedCodexActivities = [...detail.activities];
    }
    this.scheduleCodexUiStateSave();
    if (detail.updateMode === 'older') {
      this.prependOlderCodexMessages(detail.messages, detail.hasMoreBefore);
    } else {
      if (detail.updateMode !== 'delta') {
        this.clearCodexDetailTimers();
        this.codexDetailRetryCount = 0;
      }
      if (detail.updateMode === 'latest' && !this.codexHistoryReady) {
        if (this.pendingCodexSends.size > 0) {
          for (let index = 0; index < detail.messages.length; index += 1) {
            const incoming = detail.messages[index];
            const matchedIndex = incoming.role === 'user' ?
              this.matchPendingCodexMessage(this.selectedCodexMessages, incoming) : -1;
            if (matchedIndex >= 0) {
              const localId = this.selectedCodexMessages[matchedIndex].id;
              const requestId = localId.startsWith('local-') ?
                localId.substring('local-'.length) : '';
              this.clearAcknowledgedCodexComposer(requestId);
              this.statusText = '电脑端已收到并执行';
              this.statusIsError = false;
            }
          }
        }
        this.reconcileRestoredCodexUnread(detail.messages);
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
    this.reconcileSelectedCodexQueueMessages();
    this.codexDetailLoading = false;
    this.codexLoading = false;
  }

  private applyCodexTaskDelta(detail: CodexThreadDetail): void {
    if (detail.id.length === 0) {
      return;
    }
    const tasks = [...this.codexTasks];
    let index = tasks.findIndex((task: CodexTask): boolean => task.id === detail.id);
    const task = index >= 0 ? this.cloneCodexTask(tasks[index]) : new CodexTask();
    task.id = detail.id;
    if (detail.title.length > 0) {
      task.title = detail.title;
    }
    if (detail.preview.length > 0) {
      task.preview = detail.preview;
    }
    if (detail.cwd.length > 0) {
      task.cwd = detail.cwd;
    }
    task.status = detail.status;
    task.archived = detail.archived;
    if (detail.updatedAt > 0) {
      task.updatedAt = detail.updatedAt;
    }
    if (index >= 0) {
      tasks[index] = task;
    } else {
      tasks.push(task);
      index = tasks.length - 1;
    }
    this.codexTasks = tasks;
  }

  private cloneCodexTask(source: CodexTask): CodexTask {
    const task = new CodexTask();
    task.id = source.id;
    task.title = source.title;
    task.preview = source.preview;
    task.status = source.status;
    task.cwd = source.cwd;
    task.updatedAt = source.updatedAt;
    task.archived = source.archived;
    return task;
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
        const matchedLocalId = merged[existingIndex].id;
        if (matchedLocalId.startsWith('local-')) {
          const requestId = matchedLocalId.substring('local-'.length);
          if (this.pendingCodexSends.has(requestId)) {
            this.clearAcknowledgedCodexComposer(requestId);
            this.statusText = '电脑端已收到并执行';
            this.statusIsError = false;
          }
        }
        if (!this.sameCodexMessage(merged[existingIndex], next)) {
          merged[existingIndex] = next;
          changed = true;
        }
      } else {
        merged.push(next);
        if (next.role !== 'user') {
          appended += 1;
        }
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
      if (this.mainSection === 'codex' && this.isCodexConversationOpen) {
        this.scrollCodexChatToBottom(true);
      } else if (appended > 0) {
        this.setSelectedCodexUnread(this.codexUnreadMessages + appended);
      }
    } else if (appended > 0) {
      this.setSelectedCodexUnread(this.codexUnreadMessages + appended);
    }
  }

  private mergeLatestCodexActivities(incoming: CodexActivity[]): void {
    if (incoming.length === 0) {
      return;
    }
    const merged = [...this.selectedCodexActivities];
    let changed = false;
    for (let incomingIndex = 0; incomingIndex < incoming.length; incomingIndex += 1) {
      const next = incoming[incomingIndex];
      const existingIndex = merged.findIndex(
        (activity: CodexActivity): boolean => activity.id === next.id);
      if (existingIndex >= 0) {
        if (!this.sameCodexActivity(merged[existingIndex], next)) {
          merged[existingIndex] = next;
          changed = true;
        }
      } else {
        merged.push(next);
        changed = true;
      }
    }
    if (changed) {
      this.selectedCodexActivities = merged.slice(-30);
    }
  }

  private sameCodexActivity(left: CodexActivity, right: CodexActivity): boolean {
    return left.id === right.id && left.kind === right.kind && left.title === right.title &&
      left.text === right.text && left.status === right.status &&
      left.timestamp === right.timestamp && left.turnId === right.turnId;
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

  private appendPendingCodexMessage(text: string, previewImage: string,
    requestId: string = ''): void {
    const pending = new CodexMessage();
    pending.id = requestId.length > 0 ? `local-${requestId}` : `local-${Date.now()}`;
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

  private updatePendingCodexMessage(requestId: string, deliveryState: string): void {
    if (requestId.length === 0) {
      return;
    }
    const localId = `local-${requestId}`;
    const messages = [...this.selectedCodexMessages];
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      if (messages[index].id === localId) {
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

  private latestPersistedCodexMessageId(messages: CodexMessage[]): string {
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      if (!messages[index].id.startsWith('local-')) {
        return messages[index].id;
      }
    }
    return '';
  }

  private reconcileRestoredCodexUnread(messages: CodexMessage[]): void {
    const threadId = this.selectedCodexTaskId;
    const latestId = this.latestPersistedCodexMessageId(messages);
    if (threadId.length === 0 || latestId.length === 0) {
      return;
    }
    const lastSeenId = this.codexLastSeenMessageIds[threadId] ?? '';
    if (lastSeenId.length === 0) {
      this.codexLastSeenMessageIds[threadId] = latestId;
      this.setSelectedCodexUnread(this.codexUnreadCounts[threadId] ?? 0);
      return;
    }
    const lastSeenIndex = this.codexMessageIndexById(messages, lastSeenId);
    const firstUnreadIndex = lastSeenIndex >= 0 ? lastSeenIndex + 1 : 0;
    let newCount = 0;
    for (let index = firstUnreadIndex; index < messages.length; index += 1) {
      if (messages[index].role !== 'user') {
        newCount += 1;
      }
    }
    const restoredCount = lastSeenIndex >= 0 ? newCount :
      Math.max(this.codexUnreadCounts[threadId] ?? 0, newCount);
    this.setSelectedCodexUnread(restoredCount);
  }

  private setSelectedCodexUnread(count: number): void {
    if (this.selectedCodexTaskId.length === 0) {
      return;
    }
    this.codexUnreadMessages = Math.max(0, Math.floor(count));
    if (this.codexUnreadMessages > 0) {
      this.codexUnreadCounts[this.selectedCodexTaskId] = this.codexUnreadMessages;
    } else {
      this.codexUnreadCounts[this.selectedCodexTaskId] = 0;
    }
    this.scheduleCodexUiStateSave();
  }

  private markSelectedCodexRead(): void {
    if (this.selectedCodexTaskId.length === 0) {
      return;
    }
    const latestId = this.latestPersistedCodexMessageId(this.selectedCodexMessages);
    if (latestId.length > 0) {
      this.codexLastSeenMessageIds[this.selectedCodexTaskId] = latestId;
    }
    this.setSelectedCodexUnread(0);
  }

  private scheduleInitialCodexChatScroll(): void {
    this.codexHistoryReady = false;
    this.codexChatPinnedToBottom = true;
    if (this.codexChatScrollTimer >= 0) {
      clearTimeout(this.codexChatScrollTimer);
    }
    this.codexChatScrollTimer = setTimeout(() => {
      this.codexChatScrollTimer = -1;
      this.performCodexChatBottomScroll(false);
      // A second pass runs after the content-cover transition and message
      // bubble measurement, which prevents opening halfway through a thread.
      this.codexChatScrollTimer = setTimeout(() => {
        this.codexChatScrollTimer = -1;
        this.performCodexChatBottomScroll(false);
        this.codexHistoryReady = true;
      }, 260);
    }, 100);
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
    this.markSelectedCodexRead();
    this.codexChatScrollTimer = setTimeout(() => {
      this.codexChatScrollTimer = -1;
      this.performCodexChatBottomScroll(smooth);
      // Keyboard and content-cover animations can resize the List after the
      // first pass. Re-anchor once more after their final layout frame.
      this.codexChatScrollTimer = setTimeout(() => {
        this.codexChatScrollTimer = -1;
        this.performCodexChatBottomScroll(false);
      }, 240);
    }, 24);
  }

  private performCodexChatBottomScroll(smooth: boolean): void {
    try {
      this.codexChatScroller.scrollEdge(Edge.Bottom);
      return;
    } catch (_error) {
    }
    let itemCount = this.selectedCodexMessages.length;
    if (this.codexHistoryHasMore && !this.codexNewTaskMode) {
      itemCount += 1;
    }
    if (!this.codexNewTaskMode && this.isSelectedCodexRunning()) {
      itemCount += 1;
    }
    try {
      this.codexChatScroller.scrollToIndex(Math.max(0, itemCount - 1), smooth, ScrollAlign.END);
    } catch (_error) {
    }
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
        left.cwd !== right.cwd || left.updatedAt !== right.updatedAt ||
        left.archived !== right.archived) {
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
    const tasks = [...this.codexTasks];
    const taskIndex = tasks.findIndex((task: CodexTask): boolean => task.id === threadId);
    if (taskIndex >= 0 && tasks[taskIndex].status !== status) {
      const task = this.cloneCodexTask(tasks[taskIndex]);
      task.status = status;
      tasks[taskIndex] = task;
      this.codexTasks = tasks;
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

  private codexQueuePosition(item: CodexQueueItem): number {
    if (item.position > 0) {
      return item.position;
    }
    const queued = this.codexQueueItems.filter(
      (candidate: CodexQueueItem): boolean => candidate.threadId === item.threadId &&
        candidate.state === 'queued');
    queued.sort((left: CodexQueueItem, right: CodexQueueItem): number =>
      this.normalizedCodexQueueTimestamp(left) - this.normalizedCodexQueueTimestamp(right));
    const index = queued.findIndex(
      (candidate: CodexQueueItem): boolean => candidate.queueId === item.queueId);
    return index >= 0 ? index + 1 : 1;
  }

  private codexMessageDeliveryLabel(message: CodexMessage): string {
    const item = this.codexQueueItemForMessage(message);
    const state = item?.state ?? message.deliveryState;
    if (state === 'queued') return `排队中 · 第 ${item === undefined ? 1 : this.codexQueuePosition(item)} 个`;
    if (state === 'running') return '正在执行';
    if (state === 'waiting_unlock') return '等待电脑解锁';
    if (state === 'failed') return '失败';
    if (state === 'canceled') return '已取消';
    if (state === 'sent') return '已发送';
    return '发送中…';
  }

  private codexMessageDeliveryColor(message: CodexMessage, darkSurface: boolean): ResourceColor {
    const item = this.codexQueueItemForMessage(message);
    const state = item?.state ?? message.deliveryState;
    if (darkSurface) {
      if (state === 'failed') return '#FFFFD7D3';
      if (state === 'canceled') return '#FFD0D5DD';
      return '#E6FFFFFF';
    }
    if (state === 'failed') return '#FFD92D20';
    if (state === 'waiting_unlock') return '#FFB54708';
    if (state === 'running') return '#FF067647';
    if (state === 'queued') return '#FF175CD3';
    return '#FF98A2B3';
  }

  private effectiveCodexStatus(task: CodexTask): string {
    if (this.hasRunningCodexQueueItem(task.id)) {
      return 'active';
    }
    const currentStatus = task.id === this.selectedCodexTaskId ? this.selectedCodexStatus : task.status;
    const resolvedStatus = this.resolvedCodexStatus(task.id, currentStatus);
    return resolveCodexDisplayStatus(resolvedStatus, task.id === this.pendingCodexThreadId);
  }

  private collapsedSelectedCodexStatus(): string {
    if (this.hasRunningCodexQueueItem(this.selectedCodexTaskId)) {
      return 'active';
    }
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
    if (this.hasRunningCodexQueueItem(this.selectedCodexTaskId)) {
      return true;
    }
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
    if (timestamp <= 0) {
      return '时间未知';
    }
    const milliseconds = timestamp > 100000000000 ? timestamp : timestamp * 1000;
    const date = new Date(milliseconds);
    const now = new Date();
    const year = date.getFullYear().toString();
    const month = (date.getMonth() + 1).toString().padStart(2, '0');
    const day = date.getDate().toString().padStart(2, '0');
    const hour = date.getHours().toString().padStart(2, '0');
    const minute = date.getMinutes().toString().padStart(2, '0');
    const second = date.getSeconds().toString().padStart(2, '0');
    const time = `${hour}:${minute}:${second}`;
    if (date.getFullYear() === now.getFullYear() &&
      date.getMonth() === now.getMonth() && date.getDate() === now.getDate()) {
      return time;
    }
    if (date.getFullYear() === now.getFullYear()) {
      return `${month}-${day} ${time}`;
    }
    return `${year}-${month}-${day} ${time}`;
  }

  private visibleCodexActivities(): CodexActivity[] {
    return this.selectedCodexActivities.slice(-30);
  }

  private latestCodexActivity(): CodexActivity {
    if (this.selectedCodexActivities.length > 0) {
      return this.selectedCodexActivities[this.selectedCodexActivities.length - 1];
    }
    const fallback = new CodexActivity();
    fallback.title = '正在准备执行过程';
    return fallback;
  }

  private codexActivityIcon(activity: CodexActivity): string {
    if (activity.status === 'failed') return '×';
    if (activity.status === 'running') return '◌';
    if (activity.kind === 'reasoning') return '✦';
    if (activity.kind === 'file') return '▧';
    if (activity.kind === 'web') return '⌕';
    if (activity.kind === 'image') return '◇';
    return '✓';
  }

  private codexActivityColor(activity: CodexActivity): ResourceColor {
    if (activity.status === 'failed') return '#FFD92D20';
    if (activity.status === 'running') return '#FFB54708';
    if (activity.kind === 'reasoning') return '#FF6941C6';
    return '#FF067647';
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

  private codexTaskUnreadCount(threadId: string): number {
    if (threadId === this.selectedCodexTaskId) {
      return this.codexUnreadMessages;
    }
    return this.codexUnreadCounts[threadId] ?? 0;
  }

  private codexUiKey(config: PairingConfig): string {
    if (config.hasGateway() && config.targetDeviceId.length > 0) {
      return this.gatewayCodexUiComputerKey(config.targetDeviceId);
    }
    return `lan:${config.host.trim()}:${config.port}`;
  }

  private gatewayCodexUiComputerKey(deviceId: string): string {
    return deviceId.length > 0 ? `gateway:${deviceId}` : 'gateway:unselected';
  }

  private async activateCodexComputer(nextComputerKey: string): Promise<void> {
    if (nextComputerKey === this.codexUiComputerKey) {
      return;
    }
    const generation = this.codexComputerSwitchGeneration + 1;
    this.codexComputerSwitchGeneration = generation;
    const previousKey = this.codexUiComputerKey;
    const previousState = this.currentCodexUiState();
    if (this.codexUiStateSaveTimer >= 0) {
      clearTimeout(this.codexUiStateSaveTimer);
      this.codexUiStateSaveTimer = -1;
    }
    await codexUiStateStore.save(this.getContext(), previousKey, previousState);
    if (generation !== this.codexComputerSwitchGeneration) {
      return;
    }
    this.codexUiComputerKey = nextComputerKey;
    this.resetCodexComputerView();
    const state = await codexUiStateStore.load(this.getContext(), nextComputerKey);
    if (generation !== this.codexComputerSwitchGeneration) {
      return;
    }
    this.applyCodexUiState(state);
    if (this.isConnected && this.selectedGatewayBridgeId.length > 0) {
      this.codexLoading = true;
      await remoteInputClient.requestCodexSnapshot();
    }
  }

  private resetCodexComputerView(): void {
    this.stopCodexAutoRefresh();
    this.clearCodexDetailTimers();
    this.codexAvailable = false;
    this.codexError = '';
    this.codexQuota = new CodexQuota();
    this.codexTasks = [];
    this.codexModels = [];
    this.codexArchivedTasksLoaded = false;
    this.codexCacheRestored = false;
    this.selectedCodexTaskId = '';
    this.selectedCodexTitle = '';
    this.selectedCodexCwd = '';
    this.selectedCodexArchived = false;
    this.selectedCodexStatus = 'notLoaded';
    this.selectedCodexActiveTurnId = '';
    this.selectedCodexGoal = new CodexGoal();
    this.codexGoalExpanded = false;
    this.selectedCodexMessages = [];
    this.selectedCodexActivities = [];
    this.codexQueueItems = [];
    this.codexActivityExpanded = false;
    this.pendingCodexThreadId = '';
    this.isCodexConversationOpen = false;
    this.codexUnreadMessages = 0;
    this.codexCommand = '';
    this.codexImagePreviewUri = '';
    this.codexImageDataUrl = '';
    this.codexImageMimeType = '';
    this.codexLoading = false;
    this.restoredCodexTaskId = '';
    this.codexLastSeenMessageIds = {};
    this.codexUnreadCounts = {};
    this.pinnedCodexThreadIds = [];
    this.closeCodexTaskMenu();
    this.codexResolvedStatuses.clear();
    this.clearApprovalSecondConfirmTimer();
    this.approvalId = '';
    this.approvalSecondConfirm = false;
  }

  private handleGatewayDeviceTap(device: GatewayPeerDevice): void {
    this.gatewayDeviceName = device.displayName;
    this.gatewayRevokeConfirm = false;
    if (device.deviceId === this.selectedGatewayBridgeId) {
      this.clearGatewaySwitchConfirmTimer();
      this.gatewaySwitchConfirmId = '';
      return;
    }
    if (this.gatewaySwitchConfirmId !== device.deviceId) {
      this.clearGatewaySwitchConfirmTimer();
      this.gatewaySwitchConfirmId = device.deviceId;
      this.statusText = device.online ? '再次点击这台电脑确认切换' :
        '这台电脑当前离线；再次点击后切换，消息会等待它上线';
      this.statusIsError = !device.online;
      this.gatewaySwitchConfirmTimer = setTimeout(() => {
        this.gatewaySwitchConfirmTimer = -1;
        this.gatewaySwitchConfirmId = '';
      }, 8000);
      return;
    }
    this.clearGatewaySwitchConfirmTimer();
    this.gatewaySwitchConfirmId = '';
    remoteInputClient.selectGatewayDevice(device.deviceId);
    this.statusText = device.online ? '已切换电脑，正在同步任务…' :
      '已切换到离线电脑，消息将在它上线后发送';
    this.statusIsError = false;
  }

  private clearGatewaySwitchConfirmTimer(): void {
    if (this.gatewaySwitchConfirmTimer >= 0) {
      clearTimeout(this.gatewaySwitchConfirmTimer);
      this.gatewaySwitchConfirmTimer = -1;
    }
  }

  private selectedGatewayDevice(): GatewayPeerDevice | undefined {
    return this.visibleGatewayDevices().find(
      (device: GatewayPeerDevice): boolean => device.deviceId === this.selectedGatewayBridgeId);
  }

  private visibleGatewayDevices(): GatewayPeerDevice[] {
    if (this.gatewayBridgeDevices.length > 0 || this.selectedGatewayBridgeId.length === 0) {
      return this.gatewayBridgeDevices;
    }
    const selected = new GatewayPeerDevice();
    selected.deviceId = this.selectedGatewayBridgeId;
    selected.online = this.isConnected;
    return [selected];
  }

  private selectedGatewayDeviceOnline(): boolean {
    return this.selectedGatewayDevice()?.online ?? false;
  }

  private selectedGatewayDeviceStatusText(): string {
    const device = this.selectedGatewayDevice();
    if (this.activeConnectionTransport === 'lan') {
      const lanName = device?.displayName || this.gatewayDeviceName || '当前电脑';
      return `当前电脑：${lanName} · 局域网直连`;
    }
    if (device === undefined) {
      return this.isConnected ? '当前电脑：局域网电脑 · 在线' : '尚未选择电脑';
    }
    const name = device.displayName || device.deviceId;
    if (device.online) {
      return `当前电脑：${name} · 在线`;
    }
    if (device.lastSeenAt <= 0) {
      return `当前电脑：${name} · 离线`;
    }
    const elapsedSeconds = Math.max(0, Math.floor(Date.now() / 1000) - device.lastSeenAt);
    if (elapsedSeconds < 60) {
      return `当前电脑：${name} · 刚刚离线`;
    }
    if (elapsedSeconds < 3600) {
      return `当前电脑：${name} · ${Math.floor(elapsedSeconds / 60)} 分钟前在线`;
    }
    return `当前电脑：${name} · ${Math.floor(elapsedSeconds / 3600)} 小时前在线`;
  }

  private gatewaySwitchConfirmationText(): string {
    const device = this.gatewayBridgeDevices.find(
      (item: GatewayPeerDevice): boolean => item.deviceId === this.gatewaySwitchConfirmId);
    if (device === undefined) {
      return '';
    }
    const name = device.displayName || device.deviceId;
    return device.online ? `再次点击“${name}”确认切换` :
      `“${name}”当前离线；再次点击仍可切换并等待上线`;
  }

  private async renameSelectedGatewayDevice(): Promise<void> {
    if (this.selectedGatewayBridgeId.length === 0) {
      return;
    }
    const ok = await remoteInputClient.renameGatewayDevice(
      this.selectedGatewayBridgeId, this.gatewayDeviceName);
    this.statusText = ok ? '电脑名称已保存' : '保存电脑名称失败';
    this.statusIsError = !ok;
  }

  private async revokeSelectedGatewayDevice(): Promise<void> {
    if (this.selectedGatewayBridgeId.length === 0) {
      return;
    }
    if (!this.gatewayRevokeConfirm) {
      this.gatewayRevokeConfirm = true;
      this.statusText = '再次点按“撤销设备”确认';
      return;
    }
    const ok = await remoteInputClient.revokeGatewayDevice(this.selectedGatewayBridgeId);
    this.gatewayRevokeConfirm = false;
    this.statusText = ok ? '已撤销这台电脑' : '撤销设备失败';
    this.statusIsError = !ok;
  }

  private mergeLanPairing(lanConfig: PairingConfig): PairingConfig {
    const merged = this.readConfigFromForm();
    merged.host = lanConfig.host.trim();
    merged.port = lanConfig.port;
    merged.token = lanConfig.token;
    merged.mode = merged.hasGateway() ? 'auto' : 'lan';
    return merged;
  }

  private mergeGatewayPairing(gatewayConfig: PairingConfig): PairingConfig {
    const merged = this.readConfigFromForm();
    merged.gatewayUrl = gatewayConfig.gatewayUrl;
    merged.gatewayToken = gatewayConfig.gatewayToken;
    merged.pairingId = gatewayConfig.pairingId;
    merged.deviceId = gatewayConfig.deviceId;
    merged.targetDeviceId = gatewayConfig.targetDeviceId;
    merged.lastReceivedSeq = gatewayConfig.lastReceivedSeq;
    merged.gatewaySendCounter = gatewayConfig.gatewaySendCounter;
    merged.gatewayPeerCounter = gatewayConfig.gatewayPeerCounter;
    merged.gatewayPeerCounters = gatewayConfig.gatewayPeerCounters;
    merged.gatewayPrivateKey = gatewayConfig.gatewayPrivateKey;
    merged.gatewayPublicKey = gatewayConfig.gatewayPublicKey;
    merged.gatewayPeerPublicKeys = gatewayConfig.gatewayPeerPublicKeys;
    merged.gatewaySessionToken = gatewayConfig.gatewaySessionToken;
    merged.gatewayDeviceCredential = gatewayConfig.gatewayDeviceCredential;
    merged.mode = merged.hasLan() ? 'auto' : 'gateway';
    return merged;
  }

  private readConfigFromForm(): PairingConfig {
    const config = new PairingConfig();
    config.mode = this.connectionMode;
    config.host = this.host.trim();
    config.port = Number(this.portText);
    config.token = this.token;
    config.gatewayUrl = this.gatewayUrl;
    config.gatewayToken = this.gatewayToken;
    config.pairingId = this.gatewayPairingId;
    config.deviceId = this.phoneDeviceId;
    config.targetDeviceId = this.selectedGatewayBridgeId;
    config.lastReceivedSeq = this.gatewayLastReceivedSeq;
    config.gatewaySendCounter = this.gatewaySendCounter;
    config.gatewayPeerCounter = this.gatewayPeerCounter;
    try {
      config.gatewayPeerCounters = JSON.parse(this.gatewayPeerCountersJson) as Record<string, number>;
    } catch (_error) {
      config.gatewayPeerCounters = {};
    }
    config.gatewayPrivateKey = this.gatewayPrivateKey;
    config.gatewayPublicKey = this.gatewayPublicKey;
    try {
      config.gatewayPeerPublicKeys = JSON.parse(
        this.gatewayPeerPublicKeysJson) as Record<string, string>;
    } catch (_error) {
      config.gatewayPeerPublicKeys = {};
    }
    config.gatewaySessionToken = this.gatewaySessionToken;
    config.gatewayDeviceCredential = this.gatewayDeviceCredential;
    return config;
  }

  private applyConfig(config: PairingConfig): void {
    this.connectionMode = config.mode;
    this.host = config.host;
    this.portText = config.port.toString();
    this.token = config.token;
    this.gatewayUrl = config.gatewayUrl;
    this.gatewayToken = config.gatewayToken;
    this.gatewayPairingId = config.pairingId;
    this.phoneDeviceId = config.deviceId;
    this.selectedGatewayBridgeId = config.targetDeviceId;
    this.gatewayLastReceivedSeq = config.lastReceivedSeq;
    this.gatewaySendCounter = config.gatewaySendCounter;
    this.gatewayPeerCounter = config.gatewayPeerCounter;
    this.gatewayPeerCountersJson = JSON.stringify(config.gatewayPeerCounters);
    this.gatewayPrivateKey = config.gatewayPrivateKey;
    this.gatewayPublicKey = config.gatewayPublicKey;
    this.gatewayPeerPublicKeysJson = JSON.stringify(config.gatewayPeerPublicKeys);
    this.gatewaySessionToken = config.gatewaySessionToken;
    this.gatewayDeviceCredential = config.gatewayDeviceCredential;
  }
}
