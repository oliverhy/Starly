import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { PairingConfig } from '../model/PairingConfig';

const STORE_NAME = 'starly_pairing';

class PairingStore {
  async load(context: common.UIAbilityContext): Promise<PairingConfig> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    const config = new PairingConfig();
    config.host = await store.get('host', '') as string;
    config.port = await store.get('port', 8765) as number;
    config.token = await store.get('token', '') as string;
    return config;
  }

  async save(context: common.UIAbilityContext, config: PairingConfig): Promise<void> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    await store.put('host', config.host.trim());
    await store.put('port', config.port);
    await store.put('token', config.token);
    await store.flush();
  }

  async clear(context: common.UIAbilityContext): Promise<void> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    await store.clear();
    await store.flush();
  }
}

export default new PairingStore();
