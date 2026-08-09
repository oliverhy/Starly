import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME = 'starly_codex_ui_state';
const COMPUTER_STATES_KEY = 'computerStates';

export class CodexUiState {
  selectedThreadId: string = '';
  mainSection: string = 'voice';
  lastSeenMessageIds: Record<string, string> = {};
  unreadCounts: Record<string, number> = {};
  pinnedThreadIds: string[] = [];
  selectedModel: string = '';
  selectedEffort: string = 'medium';
  permissionMode: string = 'default';
  selectedServiceTier: string = '';
  deliveryMode: string = 'background';
  desktopSubmitMode: string = 'enter';
  cachedSnapshotJson: string = '';
  cachedThreadJson: string = '';
  cacheSavedAt: number = 0;
}

class CodexUiStateStore {
  async load(context: common.UIAbilityContext, computerKey: string): Promise<CodexUiState> {
    const state = new CodexUiState();
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const section = await store.get('mainSection', 'voice') as string;
      state.mainSection = section === 'codex' ? 'codex' : 'voice';
      const computerStates = this.parseStringRecord(
        await store.get(COMPUTER_STATES_KEY, '{}') as string);
      const serialized = computerStates[computerKey] ?? '';
      if (serialized.length > 0) {
        this.applySerializedState(state, serialized);
      } else {
        // Migrate the state written by builds that only supported one PC.
        state.selectedThreadId = await store.get('selectedThreadId', '') as string;
        state.lastSeenMessageIds = this.parseStringRecord(
          await store.get('lastSeenMessageIds', '{}') as string);
        state.unreadCounts = this.parseNumberRecord(
          await store.get('unreadCounts', '{}') as string);
      }
    } catch (_error) {
      // UI recovery is best effort and must never block pairing or reconnect.
    }
    return state;
  }

  async save(context: common.UIAbilityContext, computerKey: string,
    state: CodexUiState): Promise<void> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    const computerStates = this.parseStringRecord(
      await store.get(COMPUTER_STATES_KEY, '{}') as string);
    computerStates[computerKey] = JSON.stringify({
      selectedThreadId: state.selectedThreadId,
      lastSeenMessageIds: state.lastSeenMessageIds,
      unreadCounts: state.unreadCounts,
      pinnedThreadIds: state.pinnedThreadIds,
      selectedModel: state.selectedModel,
      selectedEffort: state.selectedEffort,
      permissionMode: state.permissionMode,
      selectedServiceTier: state.selectedServiceTier,
      deliveryMode: state.deliveryMode,
      desktopSubmitMode: state.desktopSubmitMode,
      cachedSnapshotJson: state.cachedSnapshotJson,
      cachedThreadJson: state.cachedThreadJson,
      cacheSavedAt: state.cacheSavedAt
    });
    await store.put(COMPUTER_STATES_KEY, JSON.stringify(computerStates));
    await store.put('mainSection', state.mainSection === 'codex' ? 'codex' : 'voice');
    await store.flush();
  }

  private applySerializedState(state: CodexUiState, value: string): void {
    try {
      const source = JSON.parse(value) as Record<string, Object>;
      state.selectedThreadId = String(source['selectedThreadId'] ?? '');
      state.lastSeenMessageIds = this.parseStringRecord(
        JSON.stringify(source['lastSeenMessageIds'] ?? {}));
      state.unreadCounts = this.parseNumberRecord(
        JSON.stringify(source['unreadCounts'] ?? {}));
      state.pinnedThreadIds = this.parseStringArray(source['pinnedThreadIds']);
      state.selectedModel = String(source['selectedModel'] ?? '');
      state.selectedEffort = String(source['selectedEffort'] ?? 'medium');
      state.permissionMode = String(source['permissionMode'] ?? 'default');
      state.selectedServiceTier = String(source['selectedServiceTier'] ?? '');
      state.deliveryMode = String(source['deliveryMode'] ?? 'background') === 'desktop' ?
        'desktop' : 'background';
      state.desktopSubmitMode = String(source['desktopSubmitMode'] ?? 'enter') === 'ctrl_enter' ?
        'ctrl_enter' : 'enter';
      state.cachedSnapshotJson = String(source['cachedSnapshotJson'] ?? '');
      state.cachedThreadJson = String(source['cachedThreadJson'] ?? '');
      state.cacheSavedAt = Number(source['cacheSavedAt'] ?? 0);
    } catch (_error) {
      // Keep the empty state when one computer entry is damaged.
    }
  }

  private parseStringRecord(value: string): Record<string, string> {
    try {
      return JSON.parse(value) as Record<string, string>;
    } catch (_error) {
      return {};
    }
  }

  private parseNumberRecord(value: string): Record<string, number> {
    try {
      const source = JSON.parse(value) as Record<string, number>;
      const result: Record<string, number> = {};
      Object.keys(source).forEach((key: string): void => {
        const count = Number(source[key]);
        if (Number.isFinite(count) && count > 0) {
          result[key] = Math.floor(count);
        }
      });
      return result;
    } catch (_error) {
      return {};
    }
  }

  private parseStringArray(value: Object | undefined): string[] {
    if (!Array.isArray(value)) {
      return [];
    }
    const result: string[] = [];
    value.forEach((item: Object): void => {
      const text = String(item).trim();
      if (text.length > 0 && !result.includes(text)) {
        result.push(text);
      }
    });
    return result;
  }
}

export default new CodexUiStateStore();
