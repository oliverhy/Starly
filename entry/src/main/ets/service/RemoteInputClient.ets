import { webSocket } from '@kit.NetworkKit';
import { PairingConfig } from '../model/PairingConfig';

export interface RemoteClientListener {
  onConnectionChanged(isConnected: boolean, message: string): void;
  onAcknowledged(message: string): void;
  onError(message: string): void;
}

class RemoteInputClient {
  private socket: webSocket.WebSocket | null = null;
  private listener: RemoteClientListener | null = null;
  private connected: boolean = false;

  setListener(listener: RemoteClientListener | null): void {
    this.listener = listener;
  }

  isConnected(): boolean {
    return this.connected;
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

  async disconnect(): Promise<void> {
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
      }
    } catch (_error) {
      this.listener?.onError('收到无法识别的电脑响应');
    }
  }
}

export default new RemoteInputClient();
