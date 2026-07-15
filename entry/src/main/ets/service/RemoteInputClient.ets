import { webSocket } from '@kit.NetworkKit';
import { PairingConfig } from '../model/PairingConfig';
import { CodexSnapshot, CodexThreadDetail, parseCodexSnapshot, parseCodexThread } from '../model/CodexModels';

class CodexWireMessage {
  type: string = '';
  id: string = '';
  threadId: string = '';
  turnId: string = '';
  text: string = '';
  submitMode: string = 'enter';
}

export interface RemoteClientListener {
  onConnectionChanged(isConnected: boolean, message: string): void;
  onAcknowledged(message: string): void;
  onError(message: string): void;
  onCodexSnapshot(snapshot: CodexSnapshot): void;
  onCodexThread(detail: CodexThreadDetail): void;
  onCodexEvent(event: string, threadId: string): void;
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

  setListener(listener: RemoteClientListener | null): void {
    this.listener = listener;
  }

  async connect(config: PairingConfig): Promise<boolean> {
    await this.disconnect();
    if (!config.isComplete()) {
      this.listener?.onError('配对信息不完整');
      return false;
    }
    const socket = webSocket.createWebSocket();
    this.socket = socket;
    socket.on('open', (error, _value) => {
      if (error) {
        this.listener?.onError(`连接失败：${error.message}`);
        return;
      }
      this.connected = true;
      this.listener?.onConnectionChanged(true, '电脑已连接');
    });
    socket.on('message', (error, value) => {
      if (error || typeof value !== 'string') {
        return;
      }
      this.handleMessage(value);
    });
    socket.on('close', (_error, _value) => {
      this.connected = false;
      this.listener?.onConnectionChanged(false, '连接已断开');
    });
    socket.on('error', (error) => {
      this.connected = false;
      this.listener?.onError(`网络错误：${error.message}`);
    });
    try {
      return await socket.connect(config.getWebSocketUrl());
    } catch (error) {
      this.connected = false;
      this.listener?.onError(`无法连接电脑：${JSON.stringify(error)}`);
      return false;
    }
  }

  async sendText(text: string, submitMode: string): Promise<boolean> {
    if (!this.connected || this.socket === null) {
      this.listener?.onError('电脑未连接');
      return false;
    }
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      this.listener?.onError('没有可发送的文字');
      return false;
    }
    const message = JSON.stringify({
      type: 'input',
      id: `${Date.now()}`,
      text: trimmed,
      submitMode: submitMode
    });
    try {
      return await this.socket.send(message);
    } catch (error) {
      this.listener?.onError(`发送失败：${JSON.stringify(error)}`);
      return false;
    }
  }

  async sendEnter(): Promise<boolean> {
    if (!this.connected || this.socket === null) {
      this.listener?.onError('电脑未连接');
      return false;
    }
    try {
      return await this.socket.send(JSON.stringify({ type: 'enter', id: `${Date.now()}` }));
    } catch (error) {
      this.listener?.onError(`发送失败：${JSON.stringify(error)}`);
      return false;
    }
  }

  async requestCodexSnapshot(): Promise<boolean> {
    const message = new CodexWireMessage();
    message.type = 'codex_snapshot_request';
    message.id = `${Date.now()}`;
    return await this.enqueueCodexRequest(message);
  }

  async requestCodexThread(threadId: string): Promise<boolean> {
    const message = new CodexWireMessage();
    message.type = 'codex_thread_request';
    message.id = `${Date.now()}`;
    message.threadId = threadId;
    return await this.enqueueCodexRequest(message);
  }

  async sendToCodex(threadId: string, text: string, submitMode: string): Promise<boolean> {
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      this.listener?.onError('请输入要发送给 Codex 的内容');
      return false;
    }
    const message = new CodexWireMessage();
    message.type = 'codex_send';
    message.id = `${Date.now()}`;
    message.threadId = threadId;
    message.text = trimmed;
    message.submitMode = submitMode;
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

  async disconnect(): Promise<void> {
    this.codexRequestGeneration += 1;
    this.codexRequestChain = Promise.resolve(true);
    this.lastCodexRequestAt = 0;
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

  private handleMessage(raw: string): void {
    try {
      const message = JSON.parse(raw) as Record<string, Object>;
      const type = String(message['type'] ?? '');
      if (type === 'ack') {
        this.listener?.onAcknowledged(String(message['message'] ?? '电脑已执行'));
      } else if (type === 'error') {
        this.listener?.onError(String(message['message'] ?? '电脑执行失败'));
      } else if (type === 'hello') {
        this.listener?.onConnectionChanged(true, String(message['computer'] ?? '电脑已连接'));
      } else if (type === 'codex_snapshot') {
        this.listener?.onCodexSnapshot(parseCodexSnapshot(message));
      } else if (type === 'codex_thread') {
        this.listener?.onCodexThread(parseCodexThread(message['thread'] ?? new CodexThreadDetail()));
      } else if (type === 'codex_event') {
        const params = (message['params'] ?? {}) as Record<string, Object>;
        this.listener?.onCodexEvent(
          String(message['event'] ?? ''), String(params['threadId'] ?? ''));
      }
    } catch (_error) {
      this.listener?.onError('收到无法识别的电脑响应');
    }
  }

  private async sendObject(message: CodexWireMessage): Promise<boolean> {
    if (!this.connected || this.socket === null) {
      this.listener?.onError('电脑未连接');
      return false;
    }
    try {
      return await this.socket.send(JSON.stringify(message));
    } catch (error) {
      this.listener?.onError(`发送失败：${JSON.stringify(error)}`);
      return false;
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
}

export default new RemoteInputClient();
