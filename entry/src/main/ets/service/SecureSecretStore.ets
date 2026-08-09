import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

const KEY_ALIAS = 'starly.pairing.secret.v1';
const AAD_TEXT = 'starly-pairing-secret-v1';

class ProtectedSecret {
  version: number = 1;
  nonce: string = '';
  ciphertext: string = '';
}

class SecureSecretStore {
  private encoder: util.TextEncoder = new util.TextEncoder();
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');
  private base64: util.Base64Helper = new util.Base64Helper();

  async protect(value: string): Promise<string> {
    if (value.length === 0) {
      return '';
    }
    await this.ensureKey();
    const nonce = (await cryptoFramework.createRandom().generateRandom(12)).data;
    const sealed = await this.crypt(
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT,
      nonce,
      this.encoder.encodeInto(value)
    );
    const protectedSecret = new ProtectedSecret();
    protectedSecret.nonce = this.base64.encodeToStringSync(nonce);
    protectedSecret.ciphertext = this.base64.encodeToStringSync(sealed);
    return JSON.stringify(protectedSecret);
  }

  async unprotect(serialized: string): Promise<string> {
    if (serialized.length === 0) {
      return '';
    }
    await this.ensureKey();
    let protectedSecret: ProtectedSecret;
    try {
      protectedSecret = JSON.parse(serialized) as ProtectedSecret;
    } catch (_error) {
      throw new Error('安全存储中的配对密钥格式无效');
    }
    if (protectedSecret.version !== 1) {
      throw new Error('不支持的配对密钥存储版本');
    }
    const nonce = this.base64.decodeSync(protectedSecret.nonce);
    const ciphertext = this.base64.decodeSync(protectedSecret.ciphertext);
    if (nonce.length !== 12 || ciphertext.length < 16) {
      throw new Error('安全存储中的配对密钥参数无效');
    }
    const clear = await this.crypt(
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT,
      nonce,
      ciphertext
    );
    return this.decoder.decodeWithStream(clear);
  }

  private async ensureKey(): Promise<void> {
    const emptyOptions: huks.HuksOptions = { properties: [] };
    if (await this.keyExists(emptyOptions)) {
      return;
    }
    const options: huks.HuksOptions = {
      properties: [
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
        { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
        {
          tag: huks.HuksTag.HUKS_TAG_PURPOSE,
          value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT |
            huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT
        },
        { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
        { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE }
      ]
    };
    try {
      await huks.generateKeyItem(KEY_ALIAS, options);
    } catch (error) {
      // A simultaneous save may have created the same alias after the existence check.
      if (!(await this.keyExists(emptyOptions))) {
        throw error as Error;
      }
    }
  }

  private async keyExists(options: huks.HuksOptions): Promise<boolean> {
    try {
      return await huks.isKeyItemExist(KEY_ALIAS, options);
    } catch (_error) {
      // Some HarmonyOS builds report a missing alias as BusinessError 12000011
      // instead of resolving false. Generation below remains authoritative;
      // genuine HUKS failures will surface from generateKeyItem.
      return false;
    }
  }

  private async crypt(purpose: huks.HuksKeyPurpose, nonce: Uint8Array,
    input: Uint8Array): Promise<Uint8Array> {
    const properties: Array<huks.HuksParam> = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce },
      { tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: this.encoder.encodeInto(AAD_TEXT) }
    ];
    let operationInput = input;
    if (purpose === huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT) {
      if (input.length < 16) {
        throw new Error('Invalid AES-GCM ciphertext');
      }
      const tagOffset = input.length - 16;
      operationInput = input.slice(0, tagOffset);
      properties.push({
        tag: huks.HuksTag.HUKS_TAG_AE_TAG,
        value: input.slice(tagOffset)
      });
    }
    const options: huks.HuksOptions = {
      properties: properties,
      inData: operationInput
    };
    const session = await huks.initSession(KEY_ALIAS, options);
    try {
      const result = await huks.finishSession(session.handle, options);
      return result.outData ?? new Uint8Array(0);
    } catch (error) {
      try {
        await huks.abortSession(session.handle, { properties: [] });
      } catch (_abortError) {
      }
      throw error as Error;
    }
  }

}

export default new SecureSecretStore();
