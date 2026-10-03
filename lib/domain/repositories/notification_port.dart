import 'dart:convert';

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

/// 通知类别。
enum NotificationKind { taskStart, calendarStart, deadline, conflict }

/// 通知 payload 的编解码契约（FR-NOTIFY-04）。
///
/// 写入端（`NotificationService`）与读取端（平台的点击回调）此前各自拼、解同一段
/// JSON：写入端在四处内联 `jsonEncode({...})`，读取端在自己的私有方法里按键名解析。
/// 两侧只靠约定对齐，因此改键名或结构不会产生编译错误，只会让"点击通知"再也定位
/// 不到对应的提醒与任务——与 W5 记录的偏好键/结构两端不一致属于同一类问题。
/// 现在两侧共用这一个契约，并有往返测试。
final class NotificationPayload {
  const NotificationPayload({
    required this.notificationId,
    required this.kind,
    required this.entityId,
    required this.route,
  });

  /// 当前结构版本。结构变更时提升；读取端据此拒绝自己看不懂的格式而不是猜着解析。
  static const int schema = 1;

  final String notificationId;
  final NotificationKind kind;

  /// 提醒指向的实体：任务或固定日程的 id。冲突类提醒可能没有具体实体，用空串表示。
  final String entityId;

  /// 点击通知后的去处（快捷入口）。由写入端决定，读取端不自行拼接路径——
  /// 路径规则属于界面装配，放在读取端会与路由表脱节。
  final String route;

  String encode() => jsonEncode({
    'schema': schema,
    'notificationId': notificationId,
    'kind': kind.name,
    'entityId': entityId,
    'route': route,
  });

  /// 解析平台回调带回的 payload。
  ///
  /// 返回 `null` 表示"这不是本应用发出的通知，或格式不是当前版本"。调用方应忽略它
  /// 而不是抛错：payload 可能来自旧版本留下的待发通知，为一条无法理解的提醒崩溃会
  /// 连带丢掉用户真实的那次点击。
  static NotificationPayload? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (value is! Map<String, Object?>) return null;
    if (value['schema'] != schema) return null;

    final id = value['notificationId'];
    final route = value['route'];
    if (id is! String || id.isEmpty) return null;
    if (route is! String || route.isEmpty) return null;

    NotificationKind? kind;
    for (final candidate in NotificationKind.values) {
      if (candidate.name == value['kind']) {
        kind = candidate;
        break;
      }
    }
    if (kind == null) return null;

    final entityId = value['entityId'];
    return NotificationPayload(
      notificationId: id,
      kind: kind,
      entityId: entityId is String ? entityId : '',
      route: route,
    );
  }
}

abstract interface class NotificationPort {
  Future<NotificationCapability> capability();

  Future<List<PendingNotification>> pendingNotifications();

  Future<void> scheduleOneShot(NotificationRequest request);

  Future<void> cancel(String id);

  /// 注册"用户点击了通知"的处理器（FR-NOTIFY-04 的快捷入口）。
  ///
  /// 交付解析好的 [NotificationPayload] 而不是原始字符串：读端与写端共用同一份契约，
  /// 上层拿到的是"点了哪条提醒、该去哪里"，不必再解析一遍。
  ///
  /// 重复注册以最后一次为准。平台的点击回调在初始化时一次性注册，处理器却在之后才
  /// 可能被替换，因此实现必须每次调用时读取当前处理器，而不是把处理器捕获进回调。
  void onTapped(void Function(NotificationPayload payload) handler);
}
