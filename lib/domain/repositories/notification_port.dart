final class NotificationRequest {
  const NotificationRequest({
    required this.id,
    required this.scheduledAtUtc,
    required this.title,
    required this.body,
    required this.payload,
  });

  final String id;
  final DateTime scheduledAtUtc;
  final String title;
  final String body;
  final String payload;

  bool get repeats => false;
}

final class PendingNotification {
  const PendingNotification({required this.id, required this.payload});

  final String id;
  final String payload;
}

final class NotificationCapability {
  const NotificationCapability({
    required this.canSchedule,
    required this.canCancelReliably,
    this.diagnostic,
  });

  const NotificationCapability.available()
    : canSchedule = true,
      canCancelReliably = true,
      diagnostic = null;

  final bool canSchedule;
  final bool canCancelReliably;
  final String? diagnostic;
}

abstract interface class NotificationPort {
  Future<NotificationCapability> capability();

  Future<List<PendingNotification>> pendingNotifications();

  Future<void> scheduleOneShot(NotificationRequest request);

  Future<void> cancel(String id);
}
