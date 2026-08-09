import { webSocket } from '@kit.NetworkKit';
import { PairingConfig, PublicPairingRequest } from '../model/PairingConfig';
import gatewayCryptoService from './GatewayCryptoService';

class PublicPairingJoinMessage {
  type: string = 'gateway_pairing_join';
  sessionId: string = '';
  secret: string = '';
  code: string = '';
  deviceId: string = '';
  devicePublicKey: string = '';
  displayName: string = 'HarmonyOS Phone';
}

export type PublicPairingStatusCallback = (message: string, verificationCode: string) => void;

class PublicPairingService {
  async pair(request: PublicPairingRequest | null, manualCode: string,
    configuredGatewayUrl: string, statusCallback: PublicPairingStatusCallback): Promise<PairingConfig> {
    const pairUrl = request?.gatewayUrl ?? this.pairUrl(configuredGatewayUrl);
    if (!pairUrl.startsWith('wss://') || !pairUrl.endsWith('/ws?pair=1')) {
      throw new Error('请先扫描电脑二维码，或配置有效的公网 Gateway 地址');
    }
    const normalizedCode = manualCode.toUpperCase().replace('-', '').trim();
    if (request === null && normalizedCode.length !== 8) {
      throw new Error('请输入电脑端显示的 8 位公网配对码');
    }
    const config = new PairingConfig();
    config.mode = 'gateway';
    config.gatewayUrl = pairUrl.split('?', 1)[0];
    config.deviceId = `phone-${Date.now().toString(16)}-${Math.floor(
      Math.random() * 0x7fffffff).toString(16)}`;
    await gatewayCryptoService.ensureIdentity(config);

    return await new Promise<PairingConfig>((resolve, reject): void => {
      const socket = webSocket.createWebSocket();
      let settled = false;
      const timeoutId = setTimeout((): void => {
        if (!settled) {
          settled = true;
          socket.close().catch((): boolean => false);
          reject(new Error('公网配对已超时，请在电脑端重新生成配对码'));
        }
      }, 130000);
      const finish = (result: PairingConfig | null, errorMessage: string = ''): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timeoutId);
        socket.close().catch((): boolean => false);
        if (result !== null) {
          resolve(result);
        } else {
          reject(new Error(errorMessage || '公网配对失败'));
        }
      };
      socket.on('open', (error, _value): void => {
        if (error) {
          finish(null, `连接配对服务失败：${error.message}`);
          return;
        }
        const join = new PublicPairingJoinMessage();
        join.sessionId = request?.sessionId ?? '';
        join.secret = request?.secret ?? '';
        join.code = normalizedCode;
        join.deviceId = config.deviceId;
        join.devicePublicKey = config.gatewayPublicKey;
        socket.send(JSON.stringify(join)).catch((): boolean => false);
      });
      socket.on('message', (error, value): void => {
        if (error || typeof value !== 'string') {
          return;
        }
        try {
          const message = JSON.parse(value) as Record<string, Object>;
          const type = String(message['type'] ?? '');
          if (type === 'gateway_pairing_waiting') {
            statusCallback('正在等待电脑端允许…',
              String(message['verificationCode'] ?? ''));
            return;
          }
          if (type === 'gateway_pairing_complete') {
            config.pairingId = String(message['pairingId'] ?? '');
            config.deviceId = String(message['deviceId'] ?? config.deviceId);
            config.gatewayDeviceCredential = String(message['deviceCredential'] ?? '');
            config.targetDeviceId = String(message['targetDeviceId'] ?? '');
            const targetPublicKey = String(message['targetPublicKey'] ?? '');
            if (config.targetDeviceId.length > 0 && targetPublicKey.length > 0) {
              config.gatewayPeerPublicKeys[config.targetDeviceId] = targetPublicKey;
            }
            if (!config.isComplete()) {
              finish(null, 'Gateway 返回的设备凭证不完整');
              return;
            }
            finish(config);
            return;
          }
          if (type === 'gateway_pairing_rejected' || type === 'gateway_pairing_error') {
            finish(null, String(message['message'] ?? '电脑端拒绝了配对'));
          }
        } catch (_error) {
          finish(null, 'Gateway 返回了无效的配对消息');
        }
      });
      socket.on('error', (error): void => {
        finish(null, `公网配对网络错误：${error.message}`);
      });
      socket.connect(pairUrl).catch((error: Error): void => {
        finish(null, `无法连接公网配对服务：${error.message}`);
      });
    });
  }

  private pairUrl(gatewayUrl: string): string {
    const trimmed = gatewayUrl.trim().split('?', 1)[0].replace(/\/$/, '');
    return trimmed.endsWith('/ws') ? `${trimmed}?pair=1` : `${trimmed}/ws?pair=1`;
  }
}

export default new PublicPairingService();
