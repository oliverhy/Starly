import { describe, it, expect } from '@ohos/hypium';
import { PairingConfig, parsePairingUri } from '../main/ets/model/PairingConfig';

export default function localUnitTest() {
  describe('PairingConfig', () => {
    it('acceptsCompleteConfig', 0, () => {
      const config = new PairingConfig();
      config.host = '192.168.1.8';
      config.port = 8765;
      config.token = '1234567890abcdef';
      expect(config.isComplete()).assertTrue();
      expect(config.getWebSocketUrl()).assertContain('192.168.1.8:8765');
    });

    it('parsesPairingUri', 0, () => {
      const parsed = parsePairingUri(
        'starly://pair?host=192.168.1.8&port=8766&token=1234567890abcdef'
      );
      expect(parsed === null).assertFalse();
      expect(parsed?.host).assertEqual('192.168.1.8');
      expect(parsed?.port).assertEqual(8766);
    });

    it('rejectsMalformedPairingUri', 0, () => {
      expect(parsePairingUri('https://example.com') === null).assertTrue();
      expect(parsePairingUri('starly://pair?host=1.2.3.4') === null).assertTrue();
    });
  });
}
