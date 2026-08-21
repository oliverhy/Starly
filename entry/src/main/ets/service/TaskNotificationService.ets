import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';

class TaskNotificationService {
  private nextId: number = 1000;

  async ensureEnabled(context: common.UIAbilityContext): Promise<boolean> {
    try {
      if (await notificationManager.isNotificationEnabled()) {
        return true;
      }
      await notificationManager.requestEnableNotification(context);
      return await notificationManager.isNotificationEnabled();
    } catch (_error) {
      // A rejected permission prompt must not prevent the app from starting.
      return false;
    }
  }

  async publish(title: string, text: string, messageId: string,
    threadId: string = ''): Promise<void> {
    try {
      this.nextId += 1;
      const safeTitle = title.slice(0, 40);
      const safeText = text.slice(0, 120);
      const request: notificationManager.NotificationRequest = {
        id: this.nextId,
        appMessageId: messageId,
        notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        content: {
          notificationContentType:
            notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: safeTitle,
            text: safeText
          }
        }
      };
      if (threadId.length > 0) {
        request.wantAgent = await this.createTaskWantAgent(threadId, this.nextId);
      }
      await notificationManager.publish(request);
    } catch (_error) {
      // Notification permission can be disabled by the user. In-app state is
      // still authoritative, so notification failures must not break sync.
    }
  }

  private async createTaskWantAgent(threadId: string, requestCode: number): Promise<WantAgent> {
    return await wantAgent.getWantAgent({
      wants: [{
        bundleName: 'com.yinhe.starly',
        moduleName: 'entry',
        abilityName: 'EntryAbility',
        action: 'com.yinhe.starly.action.OPEN_CODEX_TASK',
        parameters: {
          starlyThreadId: threadId
        }
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: requestCode,
      actionFlags: [wantAgent.WantAgentFlags.ONE_TIME_FLAG]
    });
  }
}

export default new TaskNotificationService();
