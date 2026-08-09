export class PairingConfig {
  mode: string = 'lan';
  host: string = '';
  port: number = 8765;
  token: string = '';
  gatewayUrl: string = '';
  gatewayToken: string = '';
  pairingId: string = '';
  deviceId: string = '';
  targetDeviceId: string = '';
  lastReceivedSeq: number = 0;
  gatewaySendCounter: number = 0;
  gatewayPeerCounter: number = 0;
  gatewayPeerCounters: Record<string, number> = {};
  gatewayPrivateKey: string = '';
  gatewayPublicKey: string = '';
  gatewayPeerPublicKeys: Record<string, string> = {};
  gatewaySessionToken: string = '';
  gatewayDeviceCredential: string = '';

  hasLan(): boolean {
    return this.host.trim().length > 0 && this.port > 0 && this.port <= 65535 &&
      this.token.length >= 16;
  }

  hasGateway(): boolean {
    const secureGateway = this.gatewayUrl.startsWith('wss://');
    const localTestGateway = this.gatewayUrl.startsWith('ws://127.0.0.1:') ||
      this.gatewayUrl.startsWith('ws://localhost:');
    return (secureGateway || localTestGateway) && this.pairingId.length > 0 &&
      this.deviceId.length > 0 &&
      (this.gatewayDeviceCredential.length >= 32 || this.gatewayToken.length >= 32);
  }

  isComplete(): boolean {
    if (this.mode === 'gateway') {
      return this.hasGateway();
    }
    if (this.mode === 'auto') {
      return this.hasLan() || this.hasGateway();
    }
    return this.hasLan();
  }

  getWebSocketUrl(transport: string = ''): string {
    const resolvedTransport = transport.length > 0 ? transport : this.mode;
    if (resolvedTransport === 'gateway') {
      return this.gatewayUrl;
    }
    const deviceQuery = this.deviceId.length > 0 ?
      `&deviceId=${encodeURIComponent(this.deviceId)}` : '';
    return `ws://${this.host.trim()}:${this.port}/?token=${encodeURIComponent(this.token)}` +
      deviceQuery;
  }
}

export class PublicPairingRequest {
  gatewayUrl: string = '';
  sessionId: string = '';
  secret: string = '';
  expiresAt: number = 0;

  isComplete(): boolean {
    return this.gatewayUrl.startsWith('wss://') && this.gatewayUrl.endsWith('/ws?pair=1') &&
      this.sessionId.length >= 16 && this.secret.length >= 32 && this.expiresAt * 1000 > Date.now();
  }
}

function newPhoneDeviceId(): string {
  const randomPart = Math.floor(Math.random() * 0x7fffffff).toString(16);
  return `phone-${Date.now().toString(16)}-${randomPart}`;
}

export function parsePairingUri(value: string): PairingConfig | null {
  const prefix = 'starly://pair?';
  if (!value.startsWith(prefix)) {
    return null;
  }
  const config = new PairingConfig();
  const pairs = value.substring(prefix.length).split('&');
  pairs.forEach((pair: string) => {
    const separator = pair.indexOf('=');
    if (separator <= 0) {
      return;
    }
    const key = pair.substring(0, separator);
    const rawValue = decodeURIComponent(pair.substring(separator + 1));
    if (key === 'host') {
      config.host = rawValue;
    } else if (key === 'port') {
      config.port = Number(rawValue);
    } else if (key === 'token') {
      config.token = rawValue;
    } else if (key === 'mode') {
      config.mode = rawValue;
    } else if (key === 'url') {
      config.gatewayUrl = rawValue;
    } else if (key === 'pairingId') {
      config.pairingId = rawValue;
    }
  });
  if (config.mode === 'gateway') {
    config.gatewayToken = config.token;
    config.token = '';
    config.deviceId = newPhoneDeviceId();
  }
  return config.isComplete() ? config : null;
}

export function parsePublicPairingUri(value: string): PublicPairingRequest | null {
  const prefix = 'starly://public-pair?';
  if (!value.startsWith(prefix)) {
    return null;
  }
  const request = new PublicPairingRequest();
  value.substring(prefix.length).split('&').forEach((pair: string): void => {
    const separator = pair.indexOf('=');
    if (separator <= 0) {
      return;
    }
    const key = pair.substring(0, separator);
    const rawValue = decodeURIComponent(pair.substring(separator + 1));
    if (key === 'url') {
      request.gatewayUrl = rawValue;
    } else if (key === 'session') {
      request.sessionId = rawValue;
    } else if (key === 'secret') {
      request.secret = rawValue;
    } else if (key === 'expires') {
      request.expiresAt = Number(rawValue);
    }
  });
  return request.isComplete() ? request : null;
}
