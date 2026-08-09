import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';

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

  async publish(title: string, text: string, messageId: string): Promise<void> {
    try {
      this.nextId += 1;
      const safeTitle = title.slice(0, 40);
      const safeText = text.slice(0, 120);
      await notificationManager.publish({
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
      });
    } catch (_error) {
      // Notification permission can be disabled by the user. In-app state is
      // still authoritative, so notification failures must not break sync.
    }
  }
}

export default new TaskNotificationService();
