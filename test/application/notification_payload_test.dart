// FR-NOTIFY-04：点击通知要能定位到对应的提醒与去处。
//
// 写入端（NotificationService）与读取端（平台点击回调）原先各自拼、解同一段 JSON，
// 只靠约定对齐。这里验证共用契约的往返，以及读取端面对"看不懂的 payload"时的行为：
// 必须返回 null 让调用方忽略，而不是抛错——那会连同用户真实的点击一起丢掉。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';

void main() {
  const payload = NotificationPayload(
    notificationId: 'planner.notify.task_start.block-1',
    kind: NotificationKind.taskStart,
    entityId: 'task-1',
    route: '/tasks/task-1',
  );

  test('往返编解码保留全部字段', () {
    final decoded = NotificationPayload.decode(payload.encode());

    expect(decoded, isNotNull);
    expect(decoded!.notificationId, payload.notificationId);
    expect(decoded.kind, payload.kind);
    expect(decoded.entityId, payload.entityId);
    expect(decoded.route, payload.route);
  });

  test('四类通知都能往返', () {
    for (final kind in NotificationKind.values) {
      final encoded = NotificationPayload(
        notificationId: 'planner.notify.${kind.name}.1',
        kind: kind,
        entityId: 'entity-1',
        route: '/calendar',
      ).encode();

      expect(
        NotificationPayload.decode(encoded)?.kind,
        kind,
        reason: '类别 ${kind.name} 的往返失败',
      );
    }
  });

  test('冲突类提醒允许没有具体实体', () {
    final decoded = NotificationPayload.decode(
      const NotificationPayload(
        notificationId: 'planner.notify.conflict.pending',
        kind: NotificationKind.conflict,
        entityId: '',
        route: '/calendar',
      ).encode(),
    );

    expect(decoded?.entityId, isEmpty);
  });

  test('看不懂的 payload 返回 null 而不是抛错', () {
    // 旧版本留下的待发通知、或平台带回的空 payload，都不该让点击处理崩溃。
    expect(NotificationPayload.decode(null), isNull);
    expect(NotificationPayload.decode(''), isNull);
    expect(NotificationPayload.decode('not json'), isNull);
    expect(NotificationPayload.decode('[]'), isNull);
    // 结构版本不同：读取端必须拒绝，而不是猜着解析。
    expect(
      NotificationPayload.decode(
        '{"schema":99,"notificationId":"n","kind":"taskStart","route":"/tasks"}',
      ),
      isNull,
    );
    // 缺少去处就无法完成快捷入口，同样视为不可用。
    expect(
      NotificationPayload.decode(
        '{"schema":1,"notificationId":"n","kind":"taskStart","entityId":"t"}',
      ),
      isNull,
    );
    // 未知类别（更高版本新增）同样拒绝。
    expect(
      NotificationPayload.decode(
        '{"schema":1,"notificationId":"n","kind":"futureKind","route":"/tasks"}',
      ),
      isNull,
    );
    // 空 id 无法定位提醒。
    expect(
      NotificationPayload.decode(
        '{"schema":1,"notificationId":"","kind":"taskStart","route":"/tasks"}',
      ),
      isNull,
    );
  });
}
