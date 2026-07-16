export class CodexQuota {
  remainingPercent: number = 0;
  usedPercent: number = 0;
  resetAt: number = 0;
  windowMinutes: number = 0;
  secondaryRemainingPercent: number = -1;
  secondaryResetAt: number = 0;
  plan: string = '';
  credits: string = '';
  resetCredits: number = 0;
  lifetimeTokens: number = 0;
}

export class CodexTask {
  id: string = '';
  title: string = '';
  preview: string = '';
  status: string = 'notLoaded';
  cwd: string = '';
  updatedAt: number = 0;
}

export class CodexMessage {
  id: string = '';
  role: string = '';
  text: string = '';
  images: string[] = [];
  timestamp: number = 0;
  turnId: string = '';
  deliveryState: string = '';
}

export class CodexSnapshot {
  available: boolean = false;
  error: string = '';
  quota: CodexQuota = new CodexQuota();
  threads: CodexTask[] = [];
}

export class CodexThreadDetail extends CodexTask {
  messages: CodexMessage[] = [];
  activeTurnId: string = '';
  hasMoreBefore: boolean = false;
  updateMode: string = 'latest';
}

export function isCodexTerminalStatus(status: string): boolean {
  return status === 'idle' || status === 'systemError';
}

export function resolveCodexDisplayStatus(status: string, isPending: boolean): string {
  if (isPending && !isCodexTerminalStatus(status)) {
    return 'active';
  }
  return status;
}

export function normalizeCodexDetailStatus(status: string, activeTurnId: string): string {
  if (activeTurnId.length > 0) {
    return 'active';
  }
  // A detail without an active turn is authoritative. Older bridge builds
  // could leave a stale in-memory "active" status after the rollout completed.
  return status === 'active' ? 'idle' : status;
}

function recordValue(value: Object | undefined): Record<string, Object> {
  return (value ?? {}) as Record<string, Object>;
}

function numeric(value: Object | undefined): number {
  return Number(value ?? 0);
}

export function parseCodexTask(value: Object): CodexTask {
  const source = recordValue(value);
  const task = new CodexTask();
  task.id = String(source['id'] ?? '');
  task.title = String(source['title'] ?? 'Codex 任务');
  task.preview = String(source['preview'] ?? '');
  task.status = String(source['status'] ?? 'notLoaded');
  task.cwd = String(source['cwd'] ?? '');
  task.updatedAt = numeric(source['updatedAt']);
  return task;
}

export function parseCodexSnapshot(message: Record<string, Object>): CodexSnapshot {
  const snapshot = new CodexSnapshot();
  snapshot.available = Boolean(message['available'] ?? false);
  snapshot.error = String(message['error'] ?? '');
  const quotaSource = recordValue(message['quota']);
  snapshot.quota.remainingPercent = numeric(quotaSource['remainingPercent']);
  snapshot.quota.usedPercent = numeric(quotaSource['usedPercent']);
  snapshot.quota.resetAt = numeric(quotaSource['resetAt']);
  snapshot.quota.windowMinutes = numeric(quotaSource['windowMinutes']);
  snapshot.quota.secondaryRemainingPercent = numeric(quotaSource['secondaryRemainingPercent']);
  snapshot.quota.secondaryResetAt = numeric(quotaSource['secondaryResetAt']);
  snapshot.quota.plan = String(quotaSource['plan'] ?? '');
  snapshot.quota.credits = String(quotaSource['credits'] ?? '');
  snapshot.quota.resetCredits = numeric(quotaSource['resetCredits']);
  snapshot.quota.lifetimeTokens = numeric(quotaSource['lifetimeTokens']);
  const rawThreads = (message['threads'] ?? []) as Object[];
  snapshot.threads = rawThreads.map((value: Object): CodexTask => parseCodexTask(value));
  return snapshot;
}

export function parseCodexThread(value: Object): CodexThreadDetail {
  const source = recordValue(value);
  const basic = parseCodexTask(value);
  const detail = new CodexThreadDetail();
  detail.id = basic.id;
  detail.title = basic.title;
  detail.preview = basic.preview;
  detail.status = basic.status;
  detail.cwd = basic.cwd;
  detail.updatedAt = basic.updatedAt;
  detail.activeTurnId = String(source['activeTurnId'] ?? '');
  detail.hasMoreBefore = Boolean(source['hasMoreBefore'] ?? false);
  detail.updateMode = String(source['updateMode'] ?? 'latest');
  const rawMessages = (source['messages'] ?? []) as Object[];
  detail.messages = rawMessages.map((item: Object, index: number): CodexMessage => {
    const raw = recordValue(item);
    const message = new CodexMessage();
    message.id = String(raw['id'] ?? '');
    message.role = String(raw['role'] ?? '');
    message.text = String(raw['text'] ?? '');
    message.images = (raw['images'] ?? []) as string[];
    message.timestamp = numeric(raw['timestamp']);
    message.turnId = String(raw['turnId'] ?? '');
    message.deliveryState = String(raw['deliveryState'] ?? '');
    if (message.id.length === 0) {
      message.id = `${message.role}-${message.turnId}-${message.timestamp}-${index}`;
    }
    return message;
  });
  return detail;
}
