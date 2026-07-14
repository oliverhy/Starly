export class PairingConfig {
  host: string = '';
  port: number = 8765;
  token: string = '';

  isComplete(): boolean {
    return this.host.trim().length > 0 && this.port > 0 && this.port <= 65535 && this.token.length >= 16;
  }

  getWebSocketUrl(): string {
    return `ws://${this.host.trim()}:${this.port}/?token=${encodeURIComponent(this.token)}`;
  }
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
    }
  });
  return config.isComplete() ? config : null;
}
