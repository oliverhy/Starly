import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { PairingConfig } from '../model/PairingConfig';

const DISCOVERY_PORT: number = 8766;
const PROTOCOL_VERSION: number = 1;
const DISCOVERY_WAIT_MS: number = 1400;
const PAIRING_WAIT_MS: number = 1100;

export class DiscoveredComputer {
  name: string = '';
  host: string = '';
  port: number = 8765;
  pairingPort: number = DISCOVERY_PORT;

  key(): string {
    return `${this.host}:${this.port}`;
  }
}

class PairingDiscoveryService {
  async discover(): Promise<DiscoveredComputer[]> {
    const udp = socket.constructUDPSocketInstance();
    const nonce = this.createNonce();
    const computers: DiscoveredComputer[] = [];
    const decoder = new util.TextDecoder('utf-8');
    const onMessage = (info: socket.SocketMessageInfo): void => {
      try {
        const text = decoder.decodeToString(new Uint8Array(info.message));
        const message = JSON.parse(text) as Record<string, Object>;
        if (String(message['type'] ?? '') !== 'starly_offer' ||
          Number(message['version'] ?? 0) !== PROTOCOL_VERSION ||
          String(message['nonce'] ?? '') !== nonce) {
          return;
        }
        const computer = new DiscoveredComputer();
        computer.name = String(message['computer'] ?? '电脑');
        computer.host = info.remoteInfo.address;
        computer.port = this.validPort(Number(message['port'] ?? 8765), 8765);
        computer.pairingPort = this.validPort(Number(message['pairingPort'] ?? DISCOVERY_PORT), DISCOVERY_PORT);
        const existing = computers.findIndex((item: DiscoveredComputer) => item.key() === computer.key());
        if (existing >= 0) {
          computers[existing] = computer;
        } else {
          computers.push(computer);
        }
      } catch (_error) {
      }
    };
    try {
      udp.on('message', onMessage);
      await udp.bind({ address: '0.0.0.0', port: 0, family: 1 });
      await udp.setExtraOptions({ broadcast: true, reuseAddress: true });
      const payload = JSON.stringify({
        type: 'starly_discover',
        version: PROTOCOL_VERSION,
        nonce: nonce
      });
      await udp.send({
        data: payload,
        address: { address: '255.255.255.255', port: DISCOVERY_PORT, family: 1 }
      });
      await this.wait(350);
      await udp.send({
        data: payload,
        address: { address: '255.255.255.255', port: DISCOVERY_PORT, family: 1 }
      });
      await this.wait(DISCOVERY_WAIT_MS);
      return computers;
    } finally {
      udp.off('message', onMessage);
      await this.closeSocket(udp);
    }
  }

  async pair(computer: DiscoveredComputer, code: string): Promise<PairingConfig> {
    const normalizedCode = code.replace(/\s/g, '');
    if (!/^\d{6}$/.test(normalizedCode)) {
      throw new Error('请输入电脑端显示的 6 位配对码');
    }
    const udp = socket.constructUDPSocketInstance();
    const nonce = this.createNonce();
    const decoder = new util.TextDecoder('utf-8');
    let pairedConfig: PairingConfig | null = null;
    let pairingError: string = '';
    const onMessage = (info: socket.SocketMessageInfo): void => {
      try {
        const text = decoder.decodeToString(new Uint8Array(info.message));
        const message = JSON.parse(text) as Record<string, Object>;
        if (Number(message['version'] ?? 0) !== PROTOCOL_VERSION ||
          String(message['nonce'] ?? '') !== nonce) {
          return;
        }
        const type = String(message['type'] ?? '');
        if (type === 'starly_pair_error') {
          pairingError = String(message['message'] ?? '配对失败');
          return;
        }
        if (type !== 'starly_paired') {
          return;
        }
        const config = new PairingConfig();
        config.host = info.remoteInfo.address;
        config.port = this.validPort(Number(message['port'] ?? computer.port), computer.port);
        config.token = String(message['token'] ?? '');
        if (config.isComplete()) {
          pairedConfig = config;
        }
      } catch (_error) {
      }
    };
    try {
      udp.on('message', onMessage);
      await udp.bind({ address: '0.0.0.0', port: 0, family: 1 });
      const payload = JSON.stringify({
        type: 'starly_pair',
        version: PROTOCOL_VERSION,
        nonce: nonce,
        code: normalizedCode
      });
      for (let attempt = 0; attempt < 2; attempt += 1) {
        await udp.send({
          data: payload,
          address: { address: computer.host, port: computer.pairingPort, family: 1 }
        });
        await this.wait(PAIRING_WAIT_MS);
        if (pairedConfig !== null || pairingError.length > 0) {
          break;
        }
      }
    } finally {
      udp.off('message', onMessage);
      await this.closeSocket(udp);
    }
    if (pairedConfig !== null) {
      return pairedConfig;
    }
    if (pairingError.length > 0) {
      throw new Error(pairingError);
    }
    throw new Error('电脑没有响应，请确认双方连接同一局域网且桥接程序正在运行');
  }

  private createNonce(): string {
    return `${Date.now()}-${Math.floor(Math.random() * 1000000000)}`;
  }

  private validPort(value: number, fallback: number): number {
    return Number.isInteger(value) && value > 0 && value <= 65535 ? value : fallback;
  }

  private wait(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, milliseconds);
    });
  }

  private async closeSocket(udp: socket.UDPSocket): Promise<void> {
    try {
      await udp.close();
    } catch (_error) {
    }
  }
}

export default new PairingDiscoveryService();
