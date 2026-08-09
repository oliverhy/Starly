import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { PairingConfig } from '../model/PairingConfig';

export class EncryptedGatewayPayload {
  type: string = 'e2ee';
  version: number = 1;
  senderDeviceId: string = '';
  counter: number = 0;
  timestamp: number = 0;
  nonce: string = '';
  ciphertext: string = '';
  tag: string = '';
}

class GatewayCryptoService {
  private encoder: util.TextEncoder = new util.TextEncoder();
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');
  private base64: util.Base64Helper = new util.Base64Helper();

  async ensureIdentity(config: PairingConfig): Promise<void> {
    if (config.gatewayPrivateKey.length > 0 && config.gatewayPublicKey.length > 0) {
      return;
    }
    const pair = await cryptoFramework.createAsyKeyGenerator('X25519').generateKeyPair();
    config.gatewayPrivateKey = this.base64.encodeToStringSync(pair.priKey.getEncoded().data);
    config.gatewayPublicKey = this.base64.encodeToStringSync(pair.pubKey.getEncoded().data);
  }

  updatePeerPublicKey(config: PairingConfig, deviceId: string, publicKey: string): void {
    if (deviceId.length > 0 && publicKey.length > 0) {
      config.gatewayPeerPublicKeys[deviceId] = publicKey;
    }
  }

  async encrypt(payload: Object, config: PairingConfig,
    targetDeviceId: string): Promise<EncryptedGatewayPayload> {
    const key = await this.deriveKey(config, targetDeviceId);
    config.gatewaySendCounter += 1;
    const timestamp = Math.floor(Date.now() / 1000);
    const random = cryptoFramework.createRandom();
    const nonce = (await random.generateRandom(12)).data;
    const aad = this.encode(this.aad(config.pairingId, config.deviceId,
      config.gatewaySendCounter, timestamp));
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: nonce },
      aad: { data: aad },
      authTag: { data: new Uint8Array(16) }
    };
    const symKey = await cryptoFramework.createSymKeyGenerator('AES256')
      .convertKey({ data: key });
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, params);
    const sealed = (await cipher.doFinal({ data: this.encode(JSON.stringify(payload)) })).data;
    if (sealed.length < 16) {
      throw new Error('端到端加密结果无效');
    }
    const result = new EncryptedGatewayPayload();
    result.version = 2;
    result.senderDeviceId = config.deviceId;
    result.counter = config.gatewaySendCounter;
    result.timestamp = timestamp;
    result.nonce = this.base64.encodeToStringSync(nonce);
    result.ciphertext = this.base64.encodeToStringSync(sealed.slice(0, sealed.length - 16));
    result.tag = this.base64.encodeToStringSync(sealed.slice(sealed.length - 16));
    return result;
  }

  async decrypt(value: Record<string, Object>, config: PairingConfig): Promise<Record<string, Object>> {
    if (String(value['type'] ?? '') !== 'e2ee' || Number(value['version'] ?? 0) !== 2) {
      throw new Error('Gateway 返回了未加密消息');
    }
    const sender = String(value['senderDeviceId'] ?? '');
    const counter = Number(value['counter'] ?? 0);
    const timestamp = Number(value['timestamp'] ?? 0);
    const knownCounter = config.gatewayPeerCounters[sender] ??
      (Object.keys(config.gatewayPeerCounters).length === 0 ? config.gatewayPeerCounter : 0);
    if (sender.length === 0 || counter <= knownCounter) {
      throw new Error('已拒绝重复的加密消息');
    }
    if (Math.abs(Math.floor(Date.now() / 1000) - timestamp) > 48 * 60 * 60) {
      throw new Error('已拒绝过期的加密消息');
    }
    const nonce = this.base64.decodeSync(String(value['nonce'] ?? ''));
    const ciphertext = this.base64.decodeSync(String(value['ciphertext'] ?? ''));
    const tag = this.base64.decodeSync(String(value['tag'] ?? ''));
    if (nonce.length !== 12 || tag.length !== 16) {
      throw new Error('加密消息参数无效');
    }
    const key = await this.deriveKey(config, sender);
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: nonce },
      aad: { data: this.encode(this.aad(config.pairingId, sender, counter, timestamp)) },
      authTag: { data: tag }
    };
    const symKey = await cryptoFramework.createSymKeyGenerator('AES256')
      .convertKey({ data: key });
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
    const clear = (await cipher.doFinal({ data: ciphertext })).data;
    const decoded = JSON.parse(this.decoder.decodeWithStream(clear)) as Record<string, Object>;
    config.gatewayPeerCounter = counter;
    config.gatewayPeerCounters[sender] = counter;
    return decoded;
  }

  private async deriveKey(config: PairingConfig, peerDeviceId: string): Promise<Uint8Array> {
    await this.ensureIdentity(config);
    const peerPublicKey = config.gatewayPeerPublicKeys[peerDeviceId] ?? '';
    if (peerPublicKey.length === 0) {
      throw new Error(`缺少设备 ${peerDeviceId} 的 X25519 公钥`);
    }
    const generator = cryptoFramework.createAsyKeyGenerator('X25519');
    const ownPair = await generator.convertKey(
      { data: this.base64.decodeSync(config.gatewayPublicKey) },
      { data: this.base64.decodeSync(config.gatewayPrivateKey) });
    const peerPair = await generator.convertKey(
      { data: this.base64.decodeSync(peerPublicKey) }, null);
    const agreement = cryptoFramework.createKeyAgreement('X25519');
    const shared = (await agreement.generateSecret(ownPair.priKey, peerPair.pubKey)).data;
    const prefix = this.encode(`starly-e2ee-v2\u0000${config.pairingId}\u0000`);
    const material = new Uint8Array(prefix.length + shared.length);
    material.set(prefix, 0);
    material.set(shared, prefix.length);
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: material });
    return (await md.digest()).data;
  }

  private aad(pairingId: string, sender: string, counter: number, timestamp: number): string {
    return `starly|${pairingId}|${sender}|${counter}|${timestamp}`;
  }

  private encode(value: string): Uint8Array {
    return this.encoder.encodeInto(value);
  }
}

export default new GatewayCryptoService();
