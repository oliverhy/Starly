import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { PairingConfig } from '../model/PairingConfig';

const STORE_NAME = 'starly_pairing';

class PairingStore {
  async load(context: common.UIAbilityContext): Promise<PairingConfig> {
    const config = new PairingConfig();
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      config.host = await store.get('host', '') as string;
      config.port = await store.get('port', 8765) as number;
      config.token = await store.get('token', '') as string;
    } catch (_error) {
    }
    return config;
  }

  async save(context: common.UIAbilityContext, config: PairingConfig): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put('host', config.host.trim());
      await store.put('port', config.port);
      await store.put('token', config.token);
      await store.flush();
    } catch (error) {
      throw new Error(`保存配对信息失败：${JSON.stringify(error)}`);
    }
  }

  async clear(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.clear();
      await store.flush();
    } catch (error) {
      throw new Error(`清除配对信息失败：${JSON.stringify(error)}`);
    }
  }
}

export default new PairingStore();
