import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { PairingConfig } from '../model/PairingConfig';
import secureSecretStore from './SecureSecretStore';

const STORE_NAME = 'starly_pairing';

class PairingStore {
  private cachedToken: string = '';
  private cachedProtectedToken: string = '';
  private cachedGatewayToken: string = '';
  private cachedProtectedGatewayToken: string = '';
  private cachedPrivateKey: string = '';
  private cachedProtectedPrivateKey: string = '';
  private cachedSessionToken: string = '';
  private cachedProtectedSessionToken: string = '';
  private cachedDeviceCredential: string = '';
  private cachedProtectedDeviceCredential: string = '';

  async load(context: common.UIAbilityContext): Promise<PairingConfig> {
    const config = new PairingConfig();
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      config.mode = await store.get('mode', 'lan') as string;
      config.host = await store.get('host', '') as string;
      config.port = await store.get('port', 8765) as number;
      const protectedToken = await store.get('tokenProtected', '') as string;
      const legacyToken = await store.get('token', '') as string;
      if (protectedToken.length > 0) {
        config.token = await secureSecretStore.unprotect(protectedToken);
        this.cachedProtectedToken = protectedToken;
      } else if (legacyToken.length > 0) {
        config.token = legacyToken;
        this.cachedProtectedToken = await secureSecretStore.protect(legacyToken);
        await store.put('tokenProtected', this.cachedProtectedToken);
        await store.delete('token');
        await store.flush();
      }
      this.cachedToken = config.token;
      config.gatewayUrl = await store.get('gatewayUrl', '') as string;
      const protectedGatewayToken = await store.get('gatewayTokenProtected', '') as string;
      if (protectedGatewayToken.length > 0) {
        config.gatewayToken = await secureSecretStore.unprotect(protectedGatewayToken);
        this.cachedProtectedGatewayToken = protectedGatewayToken;
      }
      config.pairingId = await store.get('pairingId', '') as string;
      config.deviceId = await store.get('deviceId', '') as string;
      config.targetDeviceId = await store.get('targetDeviceId', '') as string;
      config.lastReceivedSeq = await store.get('lastReceivedSeq', 0) as number;
      config.gatewaySendCounter = await store.get('gatewaySendCounter', 0) as number;
      config.gatewayPeerCounter = await store.get('gatewayPeerCounter', 0) as number;
      const peerCountersJson = await store.get('gatewayPeerCounters', '{}') as string;
      try {
        config.gatewayPeerCounters = JSON.parse(peerCountersJson) as Record<string, number>;
      } catch (_error) {
        config.gatewayPeerCounters = {};
      }
      const protectedPrivateKey = await store.get('gatewayPrivateKeyProtected', '') as string;
      if (protectedPrivateKey.length > 0) {
        config.gatewayPrivateKey = await secureSecretStore.unprotect(protectedPrivateKey);
        this.cachedProtectedPrivateKey = protectedPrivateKey;
      }
      this.cachedPrivateKey = config.gatewayPrivateKey;
      config.gatewayPublicKey = await store.get('gatewayPublicKey', '') as string;
      const protectedSessionToken = await store.get('gatewaySessionTokenProtected', '') as string;
      if (protectedSessionToken.length > 0) {
        config.gatewaySessionToken = await secureSecretStore.unprotect(protectedSessionToken);
        this.cachedProtectedSessionToken = protectedSessionToken;
      }
      this.cachedSessionToken = config.gatewaySessionToken;
      const protectedDeviceCredential = await store.get(
        'gatewayDeviceCredentialProtected', '') as string;
      if (protectedDeviceCredential.length > 0) {
        config.gatewayDeviceCredential = await secureSecretStore.unprotect(
          protectedDeviceCredential);
        this.cachedProtectedDeviceCredential = protectedDeviceCredential;
      }
      this.cachedDeviceCredential = config.gatewayDeviceCredential;
      if (config.gatewayToken.length === 0 && config.mode === 'gateway' &&
        config.pairingId.length > 0 && config.gatewayDeviceCredential.length === 0 &&
        config.token.length >= 32) {
        config.gatewayToken = config.token;
        config.token = '';
        this.cachedGatewayToken = config.gatewayToken;
        this.cachedProtectedGatewayToken = await secureSecretStore.protect(config.gatewayToken);
        this.cachedToken = '';
        this.cachedProtectedToken = await secureSecretStore.protect('');
        await store.put('gatewayTokenProtected', this.cachedProtectedGatewayToken);
        await store.put('tokenProtected', this.cachedProtectedToken);
        await store.flush();
      } else {
        this.cachedGatewayToken = config.gatewayToken;
      }
      const peerKeysJson = await store.get('gatewayPeerPublicKeys', '{}') as string;
      try {
        config.gatewayPeerPublicKeys = JSON.parse(peerKeysJson) as Record<string, string>;
      } catch (_error) {
        config.gatewayPeerPublicKeys = {};
      }
    } catch (error) {
      throw new Error(`读取配对信息失败：${JSON.stringify(error)}`);
    }
    return config;
  }

  async save(context: common.UIAbilityContext, config: PairingConfig): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put('mode', config.mode);
      await store.put('host', config.host.trim());
      await store.put('port', config.port);
      let protectedToken = this.cachedProtectedToken;
      if (config.token !== this.cachedToken || protectedToken.length === 0) {
        protectedToken = await secureSecretStore.protect(config.token);
      }
      await store.put('tokenProtected', protectedToken);
      await store.delete('token');
      await store.put('gatewayUrl', config.gatewayUrl);
      let protectedGatewayToken = this.cachedProtectedGatewayToken;
      if (config.gatewayToken !== this.cachedGatewayToken ||
        (config.gatewayToken.length > 0 && protectedGatewayToken.length === 0)) {
        protectedGatewayToken = await secureSecretStore.protect(config.gatewayToken);
      }
      await store.put('gatewayTokenProtected', protectedGatewayToken);
      await store.put('pairingId', config.pairingId);
      await store.put('deviceId', config.deviceId);
      await store.put('targetDeviceId', config.targetDeviceId);
      await store.put('lastReceivedSeq', config.lastReceivedSeq);
      await store.put('gatewaySendCounter', config.gatewaySendCounter);
      await store.put('gatewayPeerCounter', config.gatewayPeerCounter);
      await store.put('gatewayPeerCounters', JSON.stringify(config.gatewayPeerCounters));
      let protectedPrivateKey = this.cachedProtectedPrivateKey;
      if (config.gatewayPrivateKey !== this.cachedPrivateKey || protectedPrivateKey.length === 0) {
        protectedPrivateKey = await secureSecretStore.protect(config.gatewayPrivateKey);
      }
      await store.put('gatewayPrivateKeyProtected', protectedPrivateKey);
      await store.put('gatewayPublicKey', config.gatewayPublicKey);
      await store.put('gatewayPeerPublicKeys', JSON.stringify(config.gatewayPeerPublicKeys));
      let protectedSessionToken = this.cachedProtectedSessionToken;
      if (config.gatewaySessionToken !== this.cachedSessionToken ||
        (config.gatewaySessionToken.length > 0 && protectedSessionToken.length === 0)) {
        protectedSessionToken = await secureSecretStore.protect(config.gatewaySessionToken);
      }
      await store.put('gatewaySessionTokenProtected', protectedSessionToken);
      let protectedDeviceCredential = this.cachedProtectedDeviceCredential;
      if (config.gatewayDeviceCredential !== this.cachedDeviceCredential ||
        (config.gatewayDeviceCredential.length > 0 && protectedDeviceCredential.length === 0)) {
        protectedDeviceCredential = await secureSecretStore.protect(
          config.gatewayDeviceCredential);
      }
      await store.put('gatewayDeviceCredentialProtected', protectedDeviceCredential);
      await store.flush();
      this.cachedToken = config.token;
      this.cachedProtectedToken = protectedToken;
      this.cachedGatewayToken = config.gatewayToken;
      this.cachedProtectedGatewayToken = protectedGatewayToken;
      this.cachedPrivateKey = config.gatewayPrivateKey;
      this.cachedProtectedPrivateKey = protectedPrivateKey;
      this.cachedSessionToken = config.gatewaySessionToken;
      this.cachedProtectedSessionToken = protectedSessionToken;
      this.cachedDeviceCredential = config.gatewayDeviceCredential;
      this.cachedProtectedDeviceCredential = protectedDeviceCredential;
    } catch (error) {
      throw new Error(`保存配对信息失败：${JSON.stringify(error)}`);
    }
  }

  async clear(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.clear();
      await store.flush();
      this.cachedToken = '';
      this.cachedProtectedToken = '';
      this.cachedGatewayToken = '';
      this.cachedProtectedGatewayToken = '';
      this.cachedPrivateKey = '';
      this.cachedProtectedPrivateKey = '';
      this.cachedSessionToken = '';
      this.cachedProtectedSessionToken = '';
      this.cachedDeviceCredential = '';
      this.cachedProtectedDeviceCredential = '';
    } catch (error) {
      throw new Error(`清除配对信息失败：${JSON.stringify(error)}`);
    }
  }
}

export default new PairingStore();
