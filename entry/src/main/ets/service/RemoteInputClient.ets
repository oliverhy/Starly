import { webSocket } from '@kit.NetworkKit';
import { PairingConfig } from '../model/PairingConfig';
import {
  CodexQueueItem,
  CodexSnapshot,
  CodexThreadDetail,
  parseCodexQueueItem,
  parseCodexQueueItems,
  parseCodexSnapshot,
  parseCodexThread
} from '../model/CodexModels';
import gatewayCryptoService from './GatewayCryptoService';

class CodexWireMessage {
  type: string = '';
  id: string = '';
  threadId: string = '';
  turnId: string = '';
  text: string = '';
  name: string = '';
  submitMode: string = 'enter';
  imageData: string = '';
  imageMimeType: string = '';
  beforeMessageId: string = '';
  limit: number = 15;
  cwd: string = '';
  approvalId: string = '';
  decision: string = '';
  permissions: Record<string, Object> = {};
  includeArchived: boolean = false;
  archived: boolean = false;
  model: string = '';
  effort: string = '';
  permissionMode: string = 'default';
  serviceTier: string = '';
  deliveryMode: string = 'background';
  queueId: string = '';
}

class GatewayAuthMessage {
  type: string = 'gateway_auth';
  protocol: number = 1;
  role: string = 'phone';
  pairingId: string = '';
  deviceId: string = '';
  token: string = '';
  deviceCredential: string = '';
  sessionToken: string = '';
  devicePublicKey: string = '';
  lastReceivedSeq: number = 0;
}

class GatewayDeviceControlMessage {
  type: string = '';
  deviceId: string = '';
  displayName: string = '';
}

export class CodexApprovalRequest {
  id: string = '';
  method: string = '';
  threadId: string = '';
  cwd: string = '';
  command: string = '';
  reason: string = '';
  details: string = '';
  permissions: string = '';
  riskLevel: string = 'low';
  riskReason: string = '';
  highRisk: boolean = false;
}

export class GatewayPeerDevice {
  deviceId: string = '';
  displayName: string = '';
  online: boolean = false;
  lastSeenAt: number = 0;
}

export interface RemoteClientListener {
  onConnectionChanged(isConnected: boolean, message: string): void;
  onAcknowledged(messageId: string, operation: string, message: string): void;
  onError(message: string, messageId?: string, operation?: string): void;
  onCodexSnapshot(snapshot: CodexSnapshot): void;
  onCodexThread(detail: CodexThreadDetail): void;
  onCodexEvent(event: string, threadId: string): void;
  onCodexQueueSnapshot(items: CodexQueueItem[]): void;
  onCodexQueueEvent(item: CodexQueueItem): void;
  onCodexApproval(approval: CodexApprovalRequest): void;
  onCodexCreated(threadId: string): void;
  onGatewaySequence(lastReceivedSeq: number): void;
  onGatewayCryptoCounters(sendCounter: number, peerCounter: number,
    peerCountersJson: string): void;
  onGatewayDevices(devices: GatewayPeerDevice[], selectedDeviceId: string): void;
  onGatewayIdentity(privateKey: string, publicKey: string, peerKeysJson: string,
    sessionToken: string, deviceCredential: string): void;
}

class RemoteInputClient {
  private socket: webSocket.WebSocket | null = null;
  private listener: RemoteClientListener | null = null;
  private connected: boolean = false;
  // The PC bridge deliberately rate-limits requests. Keep Codex reads in a
  // small serial queue so a snapshot and its selected-thread detail never
  // arrive as a burst and get rejected.
  private codexRequestChain: Promise<boolean> = Promise.resolve(true);
  private lastCodexRequestAt: number = 0;
  private codexRequestGeneration: number = 0;
  private codexSnapshotInFlight: boolean = false;
  private codexSnapshotIncludesArchived: boolean = false;
  private codexSnapshotNeedsArchived: boolean = false;
  private codexSnapshotTimeoutTimer: number = -1;
  private currentConfig: PairingConfig | null = null;
  private shouldReconnect: boolean = false;
  private reconnectAttempt: number = 0;
  private reconnectTimer: number = -1;
  private transportReadyTimer: number = -1;
  private lanProbeTimer: number = -1;
  private lanProbeTimeoutTimer: number = -1;
  private lanProbeSocket: webSocket.WebSocket | null = null;
  private activeTransport: string = '';
  private gatewayRetryTimer: number = -1;
  private pendingGatewayMessages: Map<string, string> = new Map<string, string>();
  private pendingRequestOperations: Map<string, string> = new Map<string, string>();
  private gatewayDevices: GatewayPeerDevice[] = [];
  private messageSequence: number = 0;

  setListener(listener: RemoteClientListener | null): void {
    this.listener = listener;
  }

  getActiveTransport(): string {
    return this.activeTransport;
  }

  createRequestId(): string {
    this.messageSequence = (this.messageSequence + 1) % 1000000;
    const deviceId = this.currentConfig?.deviceId.trim() ?? '';
    const source = deviceId.length > 0 ? deviceId : 'phone';
    return `${source}-${Date.now()}-${this.messageSequence}`;
  }

  async connect(config: PairingConfig): Promise<boolean> {
    const previousConfig = this.currentConfig;
    if (previousConfig !== null && (previousConfig.pairingId !== config.pairingId ||
      previousConfig.deviceId !== config.deviceId)) {
      this.clearPendingGatewayMessages();
    }
    this.shouldReconnect = false;
    this.clearReconnectTimer();
    await this.closeSocket();
    if (config.hasGateway()) {
      await gatewayCryptoService.ensureIdentity(config);
      this.listener?.onGatewayIdentity(config.gatewayPrivateKey, config.gatewayPublicKey,
        JSON.stringify(config.gatewayPeerPublicKeys), config.gatewaySessionToken,
        config.gatewayDeviceCredential);
    }
    if (!config.isComplete()) {
      this.listener?.onError('配对信息不完整');
      return false;
    }
    this.currentConfig = config;
    this.shouldReconnect = true;
    const preferredTransport = config.mode === 'gateway' ? 'gateway' :
      (config.hasLan() ? 'lan' : 'gateway');
    return await this.switchTransport(preferredTransport, false);
  }

  private async openSocket(config: PairingConfig, transport: string): Promise<boolean> {
    const socket = webSocket.createWebSocket();
    this.socket = socket;
    this.activeTransport = transport;
    socket.on('open', (error, _value) => {
      if (this.socket !== socket) {
        return;
      }
      if (error) {
        this.listener?.onError(`连接失败：${error.message}`);
        return;
      }
      if (transport === 'gateway') {
        const authMessage = new GatewayAuthMessage();
        authMessage.pairingId = config.pairingId;
        authMessage.deviceId = config.deviceId;
        authMessage.devicePublicKey = config.gatewayPublicKey;
        authMessage.lastReceivedSeq = config.lastReceivedSeq;
        if (config.gatewaySessionToken.length > 0) {
          authMessage.sessionToken = config.gatewaySessionToken;
        } else if (config.gatewayDeviceCredential.length > 0) {
          authMessage.deviceCredential = config.gatewayDeviceCredential;
        } else {
          authMessage.token = config.gatewayToken;
        }
        socket.send(JSON.stringify(authMessage)).catch((): boolean => false);
      }
    });
    socket.on('message', (error, value) => {
      if (this.socket !== socket || error || typeof value !== 'string') {
        return;
      }
      this.handleMessage(value, transport);
    });
    socket.on('close', (_error, _value) => {
      if (this.socket !== socket) {
        return;
      }
      this.clearTransportReadyTimer();
      this.connected = false;
      if (transport === 'gateway' && config.gatewaySessionToken.length > 0) {
        config.gatewaySessionToken = '';
        this.listener?.onGatewayIdentity(config.gatewayPrivateKey, config.gatewayPublicKey,
          JSON.stringify(config.gatewayPeerPublicKeys), '', config.gatewayDeviceCredential);
      }
      this.listener?.onConnectionChanged(false,
        config.mode === 'auto' ? '连接已断开，正在切换通道…' : '连接已断开');
      this.scheduleReconnect();
    });
    socket.on('error', (error) => {
      if (this.socket !== socket) {
        return;
      }
      this.connected = false;
      this.listener?.onError(`网络错误：${error.message}`);
    });
    try {
      const opened = await socket.connect(config.getWebSocketUrl(transport));
      if (opened) {
        this.scheduleTransportReadyTimeout(transport);
      } else {
        this.connected = false;
        this.scheduleReconnect();
      }
      return opened;
    } catch (error) {
      this.connected = false;
      this.listener?.onError(`无法连接电脑：${JSON.stringify(error)}`);
      this.scheduleReconnect();
      return false;
    }
  }

  private async switchTransport(transport: string, announce: boolean): Promise<boolean> {
    const config = this.currentConfig;
    if (config === null || !this.shouldReconnect) {
      return false;
    }
    const resolved = transport === 'gateway' ? 'gateway' : 'lan';
    if ((resolved === 'lan' && !config.hasLan()) ||
      (resolved === 'gateway' && !config.hasGateway())) {
      return false;
    }
    this.clearReconnectTimer();
    this.clearTransportReadyTimer();
    this.clearLanProbe();
    await this.closeSocket();
    this.activeTransport = resolved;
    if (announce) {
      this.listener?.onConnectionChanged(false,
        resolved === 'lan' ? '正在切换到局域网直连…' : '正在切换到公网中继…');
    }
    return await this.openSocket(config, resolved);
  }

  private scheduleTransportReadyTimeout(transport: string): void {
    this.clearTransportReadyTimer();
    this.transportReadyTimer = setTimeout((): void => {
      this.transportReadyTimer = -1;
      if (!this.connected && this.activeTransport === transport) {
        this.scheduleReconnect(true);
      }
    }, transport === 'lan' ? 2800 : 5000);
  }

  private clearTransportReadyTimer(): void {
    if (this.transportReadyTimer >= 0) {
      clearTimeout(this.transportReadyTimer);
      this.transportReadyTimer = -1;
    }
  }

  async sendText(text: string, submitMode: string, requestId: string = ''): Promise<boolean> {
    if (!this.connected || this.socket === null) {
      this.listener?.onError('电脑未连接');
      return false;
    }
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      this.listener?.onError('没有可发送的文字');
      return false;
    }
    const message = new CodexWireMessage();
    message.type = 'input';
    message.id = requestId || this.createRequestId();
    message.text = trimmed;
    message.submitMode = submitMode;
    return await this.sendObject(message);
  }

  async sendEnter(): Promise<boolean> {
    if (!this.connected || this.socket === null) {
      this.listener?.onError('电脑未连接');
      return false;
    }
    const message = new CodexWireMessage();
    message.type = 'enter';
    message.id = `${Date.now()}`;
    return await this.sendObject(message);
  }

  async requestCodexSnapshot(includeArchived: boolean = false): Promise<boolean> {
    if (this.codexSnapshotInFlight) {
      if (includeArchived && !this.codexSnapshotIncludesArchived) {
        this.codexSnapshotNeedsArchived = true;
      }
      return true;
    }
    this.codexSnapshotInFlight = true;
    this.codexSnapshotIncludesArchived = includeArchived;
    const message = new CodexWireMessage();
    message.type = 'codex_snapshot_request';
    message.id = `${Date.now()}`;
    message.includeArchived = includeArchived;
    const sent = await this.enqueueCodexRequest(message);
    if (!sent) {
      this.resetCodexSnapshotRequest();
      return false;
    }
    this.codexSnapshotTimeoutTimer = setTimeout((): void => {
      this.codexSnapshotTimeoutTimer = -1;
      this.codexSnapshotInFlight = false;
      this.codexSnapshotIncludesArchived = false;
    }, 12000);
    return true;
  }

  async requestCodexQueueSnapshot(): Promise<boolean> {
    const message = new CodexWireMessage();
    message.type = 'codex_queue_snapshot_request';
    message.id = this.createRequestId();
    return await this.enqueueCodexRequest(message);
  }

  async cancelCodexQueueItem(queueId: string): Promise<boolean> {
    const normalizedQueueId = queueId.trim();
    if (normalizedQueueId.length === 0) {
      this.listener?.onError('缺少排队任务编号');
      return false;
    }
    const message = new CodexWireMessage();
    message.type = 'codex_queue_cancel';
    message.id = this.createRequestId();
    message.queueId = normalizedQueueId;
    return await this.enqueueCodexRequest(message);
  }

  async setCodexArchived(threadId: string, archived: boolean): Promise<boolean> {
    const message = new CodexWireMessage();
    message.type = 'codex_archive';
    message.id = `${Date.now()}`;
    message.threadId = threadId;
    message.archived = archived;
    return await this.enqueueCodexRequest(message);
  }

  async renameCodexTask(threadId: string, name: string): Promise<boolean> {
    const trimmed = name.trim();
    if (trimmed.length === 0 || trimmed.length > 80) {
      this.listener?.onError('任务名称应为 1 到 80 个字符');
      return false;
    }
    const message = new CodexWireMessage();
    message.type = 'codex_rename';
    message.id = `${Date.now()}`;
    message.threadId = threadId;
    message.name = trimmed;
    return await this.enqueueCodexRequest(message);
  }

  async requestCodexThread(threadId: string, beforeMessageId: string = '', limit: number = 15): Promise<boolean> {
    const message = new CodexWireMessage();
    message.type = 'codex_thread_request';
    message.id = `${Date.now()}`;
    message.threadId = threadId;
    message.beforeMessageId = beforeMessageId;
    message.limit = limit;
    return await this.enqueueCodexRequest(message);
  }

  async sendToCodex(threadId: string, text: string, submitMode: string,
    model: string = '', effort: string = '', permissionMode: string = 'default',
    serviceTier: string = '', deliveryMode: string = 'background',
    requestId: string = ''): Promise<boolean> {
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      this.listener?.onError('请输入要发送给 Codex 的内容');
      return false;
    }
    const message = new CodexWireMessage();
    message.type = 'codex_send';
    message.id = requestId || this.createRequestId();
    message.threadId = threadId;
    message.text = trimmed;
    message.submitMode = submitMode;
    message.model = model;
    message.effort = effort;
    message.permissionMode = permissionMode;
    message.serviceTier = serviceTier;
    message.deliveryMode = deliveryMode === 'desktop' ? 'desktop' : 'background';
    return await this.enqueueCodexRequest(message);
  }

  async createCodexTask(cwd: string, text: string, model: string = '', effort: string = '',
    permissionMode: string = 'default', serviceTier: string = '', imageData: string = '',
    imageMimeType: string = '', deliveryMode: string = 'background'): Promise<boolean> {
    if (cwd.trim().length === 0 || text.trim().length === 0) {
      this.listener?.onError('请选择工作区并输入新任务内容');
      return false;
    }
    const message = new CodexWireMessage();
    message.type = 'codex_create';
    message.id = `${Date.now()}`;
    message.cwd = cwd.trim();
    message.text = text.trim();
    message.model = model;
    message.effort = effort;
    message.permissionMode = permissionMode;
    message.serviceTier = serviceTier;
    message.imageData = imageData;
    message.imageMimeType = imageMimeType;
    message.deliveryMode = deliveryMode === 'desktop' ? 'desktop' : 'background';
    return await this.enqueueCodexRequest(message);
  }

  async sendImageToCodex(threadId: string, text: string, dataUrl: string,
    mimeType: string, submitMode: string, model: string = '', effort: string = '',
    permissionMode: string = 'default', serviceTier: string = '',
    deliveryMode: string = 'background', requestId: string = ''): Promise<boolean> {
    const trimmed = text.trim();
    if (dataUrl.trim().length === 0) {
      this.listener?.onError('请先选择要发送的图片');
      return false;
    }
    const message = new CodexWireMessage();
    message.type = 'codex_image_send';
    message.id = requestId || this.createRequestId();
    message.threadId = threadId;
    message.text = trimmed;
    message.imageData = dataUrl;
    message.imageMimeType = mimeType;
    message.submitMode = submitMode;
    message.model = model;
    message.effort = effort;
    message.permissionMode = permissionMode;
    message.serviceTier = serviceTier;
    message.deliveryMode = deliveryMode === 'desktop' ? 'desktop' : 'background';
    return await this.enqueueCodexRequest(message);
  }

  async interruptCodex(threadId: string, turnId: string): Promise<boolean> {
    const message = new CodexWireMessage();
    message.type = 'codex_interrupt';
    message.id = `${Date.now()}`;
    message.threadId = threadId;
    message.turnId = turnId;
    return await this.enqueueCodexRequest(message);
  }

  async decideCodexApproval(approvalId: string, decision: string): Promise<boolean> {
    const message = new CodexWireMessage();
    message.type = 'codex_approval_decision';
    message.id = `${Date.now()}`;
    message.approvalId = approvalId;
    message.decision = decision;
    return await this.sendObject(message);
  }

  async disconnect(): Promise<void> {
    this.shouldReconnect = false;
    this.currentConfig = null;
    this.activeTransport = '';
    this.clearPendingGatewayMessages();
    this.clearReconnectTimer();
    this.clearTransportReadyTimer();
    this.clearLanProbe();
    this.codexRequestGeneration += 1;
    this.codexRequestChain = Promise.resolve(true);
    this.lastCodexRequestAt = 0;
    this.resetCodexSnapshotRequest();
    await this.closeSocket();
  }

  selectGatewayDevice(deviceId: string): void {
    const config = this.currentConfig;
    if (config === null || !config.hasGateway()) {
      return;
    }
    if (!this.gatewayDevices.some((device: GatewayPeerDevice): boolean =>
      device.deviceId === deviceId)) {
      return;
    }
    if (config.targetDeviceId === deviceId) {
      return;
    }
    this.clearPendingGatewayMessages();
    this.codexRequestGeneration += 1;
    this.codexRequestChain = Promise.resolve(true);
    this.lastCodexRequestAt = 0;
    this.resetCodexSnapshotRequest();
    config.targetDeviceId = deviceId;
    this.listener?.onGatewayDevices([...this.gatewayDevices], deviceId);
    const selected = this.gatewayDevices.find(
      (device: GatewayPeerDevice): boolean => device.deviceId === deviceId);
    if (selected?.online ?? false) {
      this.requestCodexSnapshot().catch((): boolean => false);
      this.requestCodexQueueSnapshot().catch((): boolean => false);
    }
  }

  async renameGatewayDevice(deviceId: string, displayName: string): Promise<boolean> {
    const message = new GatewayDeviceControlMessage();
    message.type = 'gateway_device_rename';
    message.deviceId = deviceId;
    message.displayName = displayName.trim();
    return await this.sendGatewayControl(message);
  }

  async revokeGatewayDevice(deviceId: string): Promise<boolean> {
    const message = new GatewayDeviceControlMessage();
    message.type = 'gateway_device_revoke';
    message.deviceId = deviceId;
    return await this.sendGatewayControl(message);
  }

  private async sendGatewayControl(message: Object): Promise<boolean> {
    if (!this.connected || this.socket === null || this.activeTransport !== 'gateway') {
      return false;
    }
    return await this.socket.send(JSON.stringify(message));
  }

  private async handleMessage(raw: string, transport: string): Promise<void> {
    try {
      const config = this.currentConfig;
      const message = JSON.parse(raw) as Record<string, Object>;
      const type = String(message['type'] ?? '');
      if (type === 'gateway_ready') {
        if (transport !== 'gateway') {
          return;
        }
        this.connected = true;
        this.clearTransportReadyTimer();
        this.reconnectAttempt = 0;
        const peerOnline = Boolean(message['peerOnline'] ?? false);
        if (config !== null) {
          config.gatewaySessionToken = String(message['sessionToken'] ?? config.gatewaySessionToken);
          const renewedCredential = String(message['deviceCredential'] ?? '');
          if (renewedCredential.length > 0) {
            config.gatewayDeviceCredential = renewedCredential;
          }
        }
        this.gatewayDevices = [];
        const known = (message['knownPeerDevices'] ?? []) as Object[];
        const onlineIds = (message['peerDevices'] ?? []) as string[];
        known.forEach((item: Object) => {
          const source = item as Record<string, Object>;
          const device = new GatewayPeerDevice();
          device.deviceId = String(source['deviceId'] ?? '');
          device.displayName = String(source['displayName'] ?? '');
          device.lastSeenAt = Number(source['lastSeenAt'] ?? 0);
          if (config !== null) {
            gatewayCryptoService.updatePeerPublicKey(
              config, device.deviceId, String(source['publicKey'] ?? ''));
          }
          device.online = onlineIds.includes(device.deviceId);
          if (device.deviceId.length > 0) {
            this.gatewayDevices.push(device);
          }
        });
        onlineIds.forEach((deviceId: string): void => {
          if (deviceId.length > 0 && !this.gatewayDevices.some(
            (device: GatewayPeerDevice): boolean => device.deviceId === deviceId)) {
            const device = new GatewayPeerDevice();
            device.deviceId = deviceId;
            device.online = true;
            this.gatewayDevices.push(device);
          }
        });
        if (config !== null && config.targetDeviceId.length > 0 &&
          !this.gatewayDevices.some((device: GatewayPeerDevice): boolean =>
            device.deviceId === config.targetDeviceId)) {
          const device = new GatewayPeerDevice();
          device.deviceId = config.targetDeviceId;
          device.online = peerOnline;
          this.gatewayDevices.push(device);
        }
        if (config !== null && (config.targetDeviceId.length === 0 ||
          !this.gatewayDevices.some((device: GatewayPeerDevice): boolean =>
            device.deviceId === config.targetDeviceId))) {
          const preferred = this.gatewayDevices.find(
            (device: GatewayPeerDevice): boolean => device.online) ?? this.gatewayDevices[0];
          config.targetDeviceId = preferred?.deviceId ?? '';
        }
        this.listener?.onGatewayDevices([...this.gatewayDevices], config?.targetDeviceId ?? '');
        this.listener?.onGatewayIdentity(config?.gatewayPrivateKey ?? '',
          config?.gatewayPublicKey ?? '', JSON.stringify(config?.gatewayPeerPublicKeys ?? {}),
          config?.gatewaySessionToken ?? '', config?.gatewayDeviceCredential ?? '');
        this.listener?.onConnectionChanged(true,
          peerOnline ? '公网电脑已连接' : '公网中继已连接，电脑当前离线');
        this.scheduleLanProbe();
        this.retryPendingGatewayMessages();
        // Gateway does not push a Codex snapshot as part of its ready
        // handshake. Pull one now so cold starts also establish the relay path
        // and repair stale task states without waiting for the UI timer.
        if (peerOnline && config !== null && config.targetDeviceId.length > 0) {
          this.requestCodexSnapshot().catch((): boolean => false);
          this.requestCodexQueueSnapshot().catch((): boolean => false);
        }
        return;
      }
      if (type === 'gateway_accepted') {
        if (transport !== 'gateway') {
          return;
        }
        const clientMessageId = String(message['clientMessageId'] ?? '');
        if (clientMessageId.length > 0) {
          this.pendingGatewayMessages.delete(clientMessageId);
          if (this.pendingGatewayMessages.size === 0) {
            this.clearGatewayRetryTimer();
          }
        }
        return;
      }
      if (type === 'gateway_message') {
        if (transport !== 'gateway') {
          return;
        }
        await this.handleGatewayMessage(message);
        return;
      }
      if (type === 'gateway_devices') {
        if (transport !== 'gateway') {
          return;
        }
        const onlineDeviceIds = this.gatewayDevices.filter(
          (known: GatewayPeerDevice): boolean => known.online).map(
          (known: GatewayPeerDevice): string => known.deviceId);
        this.gatewayDevices = [];
        const devices = (message['devices'] ?? []) as Object[];
        devices.forEach((item: Object) => {
          const source = item as Record<string, Object>;
          const device = new GatewayPeerDevice();
          device.deviceId = String(source['deviceId'] ?? '');
          device.displayName = String(source['displayName'] ?? '');
          device.lastSeenAt = Number(source['lastSeenAt'] ?? 0);
          device.online = onlineDeviceIds.includes(device.deviceId);
          if (device.deviceId.length > 0) {
            this.gatewayDevices.push(device);
          }
        });
        if (config !== null && !this.gatewayDevices.some(
          (device: GatewayPeerDevice): boolean => device.deviceId === config.targetDeviceId)) {
          config.targetDeviceId = this.gatewayDevices[0]?.deviceId ?? '';
        }
        this.listener?.onGatewayDevices([...this.gatewayDevices], config?.targetDeviceId ?? '');
        return;
      }
      if (type === 'gateway_presence') {
        if (transport !== 'gateway') {
          return;
        }
        const role = String(message['role'] ?? '');
        const online = Boolean(message['online'] ?? false);
        if (role === 'bridge') {
          const deviceId = String(message['deviceId'] ?? '');
          if (config !== null) {
            gatewayCryptoService.updatePeerPublicKey(
              config, deviceId, String(message['devicePublicKey'] ?? ''));
          }
          let device = this.gatewayDevices.find(
            (item: GatewayPeerDevice): boolean => item.deviceId === deviceId);
          if (device === undefined && deviceId.length > 0) {
            device = new GatewayPeerDevice();
            device.deviceId = deviceId;
            this.gatewayDevices.push(device);
          }
          if (device !== undefined) {
            device.online = online;
            device.lastSeenAt = Math.floor(Date.now() / 1000);
          }
          this.listener?.onGatewayDevices([...this.gatewayDevices], config?.targetDeviceId ?? '');
          this.listener?.onConnectionChanged(true,
            online ? '电脑已上线' : '电脑当前离线，消息可排队等待上线');
          if (online && config !== null && deviceId === config.targetDeviceId) {
            // The Bridge may have restarted while the phone stayed connected.
            // Recreate its relay connection and reconcile task terminal states.
            this.requestCodexSnapshot().catch((): boolean => false);
            this.requestCodexQueueSnapshot().catch((): boolean => false);
          }
        }
        return;
      }
      this.handlePayload(message, transport);
    } catch (_error) {
      this.listener?.onError('收到无法识别的电脑响应');
    }
  }

  private handlePayload(message: Record<string, Object>, transport: string = this.activeTransport): void {
    const type = String(message['type'] ?? '');
      if (type === 'ack') {
        const messageId = String(message['id'] ?? '');
        const operation = String(message['operation'] ??
          this.pendingRequestOperations.get(messageId) ?? '');
        if (messageId.length > 0) {
          this.pendingRequestOperations.delete(messageId);
        }
        this.listener?.onAcknowledged(
          messageId, operation, String(message['message'] ?? '电脑已执行'));
      } else if (type === 'error') {
        const messageId = String(message['id'] ?? '');
        const operation = String(message['operation'] ??
          this.pendingRequestOperations.get(messageId) ?? '');
        if (messageId.length > 0) {
          this.pendingRequestOperations.delete(messageId);
        }
        // Queue support is additive. An older Bridge can reject this automatic
        // capability probe; ignore that response without disturbing the
        // existing task synchronization path.
        if (operation === 'codex_queue_snapshot_request') {
          return;
        }
        this.listener?.onError(
          String(message['message'] ?? '电脑执行失败'), messageId, operation);
      } else if (type === 'hello') {
        if (transport !== 'lan') {
          return;
        }
        this.connected = true;
        this.clearTransportReadyTimer();
        this.clearLanProbe();
        this.reconnectAttempt = 0;
        this.requestCodexQueueSnapshot().catch((): boolean => false);
        this.listener?.onConnectionChanged(true,
          `局域网直连 · ${String(message['computer'] ?? '电脑已连接')}`);
      } else if (type === 'codex_snapshot') {
        const requestArchivedAfterCurrent = this.codexSnapshotNeedsArchived &&
          !this.codexSnapshotIncludesArchived;
        this.resetCodexSnapshotRequest();
        this.listener?.onCodexSnapshot(parseCodexSnapshot(message));
        if (requestArchivedAfterCurrent) {
          setTimeout((): void => {
            this.requestCodexSnapshot(true).catch((): boolean => false);
          }, 80);
        }
      } else if (type === 'codex_thread') {
        this.listener?.onCodexThread(parseCodexThread(message['thread'] ?? new CodexThreadDetail()));
      } else if (type === 'codex_event') {
        const params = (message['params'] ?? {}) as Record<string, Object>;
        this.listener?.onCodexEvent(
          String(message['event'] ?? ''), String(params['threadId'] ?? ''));
      } else if (type === 'codex_queue_snapshot') {
        const messageId = String(message['id'] ?? '');
        if (messageId.length > 0) {
          this.pendingRequestOperations.delete(messageId);
        }
        this.listener?.onCodexQueueSnapshot(parseCodexQueueItems(message['items']));
      } else if (type === 'codex_queue_event') {
        const item = parseCodexQueueItem(message['item'] ?? new CodexQueueItem());
        if (item.queueId.length > 0) {
          this.listener?.onCodexQueueEvent(item);
        }
      } else if (type === 'codex_approval') {
        const source = (message['approval'] ?? {}) as Record<string, Object>;
        const approval = new CodexApprovalRequest();
        approval.id = String(source['approvalId'] ?? '');
        approval.method = String(source['approvalMethod'] ?? '');
        approval.threadId = String(source['threadId'] ?? '');
        approval.cwd = String(source['cwd'] ?? source['workingDirectory'] ?? '');
        const commandValue = source['command'] ?? source['cmd'] ?? '';
        approval.command = Array.isArray(commandValue) ? commandValue.join(' ') : String(commandValue);
        approval.reason = String(source['reason'] ?? source['message'] ?? '');
        approval.details = JSON.stringify(source);
        approval.permissions = String(source['permissionsSummary'] ?? '');
        approval.riskLevel = String(source['riskLevel'] ?? '');
        const riskReasons = (source['riskReasons'] ?? []) as Object[];
        approval.riskReason = riskReasons.map((value: Object): string => String(value)).join('；');
        const riskText = `${approval.method} ${approval.command}`.toLowerCase();
        approval.highRisk = Boolean(source['highRisk'] ?? false) || approval.riskLevel === 'high' ||
          approval.method.includes('permissions') ||
          /\b(rm|del|erase|format|shutdown|reboot|sudo|runas)\b/.test(riskText);
        this.listener?.onCodexApproval(approval);
      } else if (type === 'codex_created') {
        this.pendingRequestOperations.delete(String(message['id'] ?? ''));
        this.listener?.onCodexCreated(String(message['threadId'] ?? ''));
      }
  }

  private async handleGatewayMessage(message: Record<string, Object>): Promise<void> {
    const config = this.currentConfig;
    if (config === null) {
      return;
    }
    const seq = Number(message['seq'] ?? 0);
    if (seq <= 0) {
      return;
    }
    if (seq <= config.lastReceivedSeq) {
      this.sendGatewayAck(seq);
      return;
    }
    const encrypted = message['payload'] as Record<string, Object>;
    if (encrypted === undefined) {
      return;
    }
    const fromDeviceId = String(message['fromDeviceId'] ?? '');
    gatewayCryptoService.updatePeerPublicKey(config,
      fromDeviceId, String(message['fromDevicePublicKey'] ?? ''));
    const payload = await gatewayCryptoService.decrypt(encrypted, config);
    // Always decrypt and acknowledge valid messages so the gateway can advance,
    // but never let a response from a previously selected PC replace this PC's UI.
    if (fromDeviceId === config.targetDeviceId) {
      this.handlePayload(payload);
    }
    config.lastReceivedSeq = seq;
    this.listener?.onGatewaySequence(seq);
    this.listener?.onGatewayCryptoCounters(
      config.gatewaySendCounter, config.gatewayPeerCounter,
      JSON.stringify(config.gatewayPeerCounters));
    this.sendGatewayAck(seq);
  }

  private sendGatewayAck(seq: number): void {
    const socket = this.socket;
    if (socket === null) {
      return;
    }
    socket.send(JSON.stringify({ type: 'gateway_ack', seq: seq })).catch((): boolean => false);
  }

  private async sendObject(message: Object): Promise<boolean> {
    if (!this.connected || this.socket === null) {
      this.listener?.onError('电脑未连接');
      return false;
    }
    const request = message as Record<string, Object>;
    const requestId = String(request['id'] ?? '');
    const operation = String(request['type'] ?? '');
    const trackedOperations = ['input', 'enter', 'codex_send', 'codex_image_send',
      'codex_create', 'codex_interrupt', 'codex_approval_decision',
      'codex_archive', 'codex_rename', 'codex_queue_snapshot_request',
      'codex_queue_cancel'];
    if (requestId.length > 0 && trackedOperations.includes(operation)) {
      this.pendingRequestOperations.set(requestId, operation);
    }
    try {
      const config = this.currentConfig;
      if (config !== null && this.activeTransport === 'gateway') {
        if (config.targetDeviceId.length === 0) {
          this.listener?.onError('请先选择一台电脑');
          return false;
        }
        const encrypted = await gatewayCryptoService.encrypt(
          message, config, config.targetDeviceId);
        this.listener?.onGatewayCryptoCounters(
          config.gatewaySendCounter, config.gatewayPeerCounter,
          JSON.stringify(config.gatewayPeerCounters));
        const clientMessageId = requestId;
        const wire = JSON.stringify({
          type: 'gateway_send',
          clientMessageId: clientMessageId,
          targetDeviceId: config.targetDeviceId,
          payload: encrypted
        });
        if (clientMessageId.length > 0) {
          this.pendingGatewayMessages.set(clientMessageId, wire);
          this.scheduleGatewayRetry();
        }
        const sent = await this.socket.send(wire);
        if (!sent && clientMessageId.length === 0) {
          this.pendingRequestOperations.delete(requestId);
          return false;
        }
        return sent || clientMessageId.length > 0;
      }
      const sent = await this.socket.send(JSON.stringify(message));
      if (!sent) {
        this.pendingRequestOperations.delete(requestId);
      }
      return sent;
    } catch (error) {
      this.pendingRequestOperations.delete(requestId);
      this.listener?.onError(`发送失败：${JSON.stringify(error)}`);
      return false;
    }
  }

  private scheduleReconnect(immediate: boolean = false): void {
    if (!this.shouldReconnect || this.currentConfig === null || this.reconnectTimer >= 0) {
      return;
    }
    const delay = immediate ? 0 : Math.min(30000, 1000 * Math.pow(2, this.reconnectAttempt));
    this.reconnectAttempt = Math.min(this.reconnectAttempt + 1, 5);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      const config = this.currentConfig;
      if (this.shouldReconnect && config !== null) {
        let nextTransport = this.activeTransport;
        if (config.mode === 'auto') {
          if (this.activeTransport === 'lan' && config.hasGateway()) {
            nextTransport = 'gateway';
          } else if (this.activeTransport === 'gateway' && config.hasLan()) {
            nextTransport = 'lan';
          }
        }
        this.switchTransport(nextTransport, true).catch((): boolean => false);
      }
    }, delay);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
  }

  private scheduleLanProbe(): void {
    const config = this.currentConfig;
    if (!this.shouldReconnect || !this.connected || config === null ||
      config.mode !== 'auto' || this.activeTransport !== 'gateway' || !config.hasLan() ||
      this.lanProbeTimer >= 0 || this.lanProbeSocket !== null) {
      return;
    }
    this.lanProbeTimer = setTimeout((): void => {
      this.lanProbeTimer = -1;
      this.startLanProbe();
    }, 12000);
  }

  private startLanProbe(): void {
    const config = this.currentConfig;
    if (!this.shouldReconnect || !this.connected || config === null ||
      config.mode !== 'auto' || this.activeTransport !== 'gateway' || !config.hasLan()) {
      return;
    }
    const probe = webSocket.createWebSocket();
    this.lanProbeSocket = probe;
    let promoted = false;
    const finishFailedProbe = (): void => {
      if (promoted || this.lanProbeSocket !== probe) {
        return;
      }
      this.lanProbeSocket = null;
      if (this.lanProbeTimeoutTimer >= 0) {
        clearTimeout(this.lanProbeTimeoutTimer);
        this.lanProbeTimeoutTimer = -1;
      }
      try {
        probe.off('open');
        probe.off('message');
        probe.off('close');
        probe.off('error');
        probe.close().catch((): boolean => false);
      } catch (_error) {
      }
      this.scheduleLanProbe();
    };
    probe.on('message', (error, value): void => {
      if (error || typeof value !== 'string' || this.lanProbeSocket !== probe) {
        return;
      }
      try {
        const message = JSON.parse(value) as Record<string, Object>;
        if (String(message['type'] ?? '') !== 'hello') {
          return;
        }
        promoted = true;
        this.promoteLanProbe(probe, config, message);
      } catch (_error) {
      }
    });
    probe.on('close', (): void => finishFailedProbe());
    probe.on('error', (): void => finishFailedProbe());
    probe.connect(config.getWebSocketUrl('lan')).then((opened: boolean): void => {
      if (!opened) {
        finishFailedProbe();
      }
    }).catch((): void => finishFailedProbe());
    this.lanProbeTimeoutTimer = setTimeout((): void => finishFailedProbe(), 2600);
  }

  private promoteLanProbe(probe: webSocket.WebSocket, config: PairingConfig,
    hello: Record<string, Object>): void {
    if (this.lanProbeSocket !== probe || this.activeTransport !== 'gateway') {
      return;
    }
    this.lanProbeSocket = null;
    if (this.lanProbeTimeoutTimer >= 0) {
      clearTimeout(this.lanProbeTimeoutTimer);
      this.lanProbeTimeoutTimer = -1;
    }
    const previousSocket = this.socket;
    if (previousSocket !== null) {
      try {
        previousSocket.off('open');
        previousSocket.off('message');
        previousSocket.off('close');
        previousSocket.off('error');
        previousSocket.close().catch((): boolean => false);
      } catch (_error) {
      }
    }
    try {
      probe.off('open');
      probe.off('message');
      probe.off('close');
      probe.off('error');
    } catch (_error) {
    }
    this.socket = probe;
    this.activeTransport = 'lan';
    this.connected = true;
    this.reconnectAttempt = 0;
    this.clearGatewayRetryTimer();
    this.attachPromotedLanSocket(probe);
    this.handlePayload(hello, 'lan');
    // The Bridge sends its initial snapshot immediately after `hello`. During
    // probe promotion that second frame can already be queued while the probe
    // listener is being replaced. Pull a fresh snapshot explicitly so stale
    // gateway state cannot survive a successful LAN-first handover.
    setTimeout((): void => {
      if (this.socket === probe && this.activeTransport === 'lan' && this.connected) {
        this.requestCodexSnapshot().catch((): boolean => false);
      }
    }, 80);
  }

  private attachPromotedLanSocket(socket: webSocket.WebSocket): void {
    socket.on('message', (error, value): void => {
      if (this.socket !== socket || error || typeof value !== 'string') {
        return;
      }
      this.handleMessage(value, 'lan');
    });
    socket.on('close', (): void => {
      if (this.socket !== socket) {
        return;
      }
      this.connected = false;
      this.listener?.onConnectionChanged(false, '局域网已断开，正在切换通道…');
      this.scheduleReconnect();
    });
    socket.on('error', (error): void => {
      if (this.socket === socket) {
        this.connected = false;
        this.listener?.onError(`局域网错误：${error.message}`);
      }
    });
  }

  private clearLanProbe(): void {
    if (this.lanProbeTimer >= 0) {
      clearTimeout(this.lanProbeTimer);
      this.lanProbeTimer = -1;
    }
    if (this.lanProbeTimeoutTimer >= 0) {
      clearTimeout(this.lanProbeTimeoutTimer);
      this.lanProbeTimeoutTimer = -1;
    }
    const probe = this.lanProbeSocket;
    this.lanProbeSocket = null;
    if (probe !== null && probe !== this.socket) {
      try {
        probe.off('open');
        probe.off('message');
        probe.off('close');
        probe.off('error');
        probe.close().catch((): boolean => false);
      } catch (_error) {
      }
    }
  }

  private scheduleGatewayRetry(): void {
    if (this.gatewayRetryTimer >= 0 || this.pendingGatewayMessages.size === 0) {
      return;
    }
    this.gatewayRetryTimer = setTimeout(() => {
      this.gatewayRetryTimer = -1;
      this.retryPendingGatewayMessages();
    }, 3000);
  }

  private retryPendingGatewayMessages(): void {
    const socket = this.socket;
    const config = this.currentConfig;
    if (this.pendingGatewayMessages.size === 0) {
      this.clearGatewayRetryTimer();
      return;
    }
    if (!this.connected || socket === null || config === null || this.activeTransport !== 'gateway') {
      return;
    }
    this.pendingGatewayMessages.forEach((wire: string): void => {
      socket.send(wire).catch((): boolean => false);
    });
    this.scheduleGatewayRetry();
  }

  private clearGatewayRetryTimer(): void {
    if (this.gatewayRetryTimer >= 0) {
      clearTimeout(this.gatewayRetryTimer);
      this.gatewayRetryTimer = -1;
    }
  }

  private clearPendingGatewayMessages(): void {
    this.pendingGatewayMessages.clear();
    this.clearGatewayRetryTimer();
  }

  private async closeSocket(): Promise<void> {
    this.clearGatewayRetryTimer();
    const socket = this.socket;
    this.socket = null;
    this.connected = false;
    if (socket !== null) {
      try {
        socket.off('open');
        socket.off('message');
        socket.off('close');
        socket.off('error');
        await socket.close();
      } catch (_error) {
      }
    }
  }

  private enqueueCodexRequest(message: CodexWireMessage): Promise<boolean> {
    const generation = this.codexRequestGeneration;
    const task = this.codexRequestChain.then(async (): Promise<boolean> => {
      if (generation !== this.codexRequestGeneration) {
        return false;
      }
      const elapsed = Date.now() - this.lastCodexRequestAt;
      const waitMs = 180 - elapsed;
      if (waitMs > 0) {
        await new Promise<void>((resolve: () => void) => {
          setTimeout(resolve, waitMs);
        });
      }
      if (generation !== this.codexRequestGeneration) {
        return false;
      }
      const sent = await this.sendObject(message);
      this.lastCodexRequestAt = Date.now();
      return sent;
    }, (): boolean => false);
    this.codexRequestChain = task.then((): boolean => true, (): boolean => false);
    return task;
  }

  private resetCodexSnapshotRequest(): void {
    if (this.codexSnapshotTimeoutTimer >= 0) {
      clearTimeout(this.codexSnapshotTimeoutTimer);
      this.codexSnapshotTimeoutTimer = -1;
    }
    this.codexSnapshotInFlight = false;
    this.codexSnapshotIncludesArchived = false;
    this.codexSnapshotNeedsArchived = false;
  }
}

export default new RemoteInputClient();
