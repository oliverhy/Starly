type NotificationTaskListener = (threadId: string) => void;

class NotificationNavigationService {
  private pendingThreadId: string = '';
  private listener: NotificationTaskListener | null = null;

  setListener(listener: NotificationTaskListener | null): void {
    this.listener = listener;
    if (listener === null || this.pendingThreadId.length === 0) {
      return;
    }
    const threadId = this.pendingThreadId;
    this.pendingThreadId = '';
    listener(threadId);
  }

  openCodexTask(threadId: string): void {
    const normalized = threadId.trim();
    if (normalized.length === 0) {
      return;
    }
    if (this.listener !== null) {
      this.listener(normalized);
      return;
    }
    this.pendingThreadId = normalized;
  }
}

export default new NotificationNavigationService();
