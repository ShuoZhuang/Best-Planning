import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/application/day_exception_service.dart';
import 'package:personal_planner/application/extension_day_service.dart';
import 'package:personal_planner/application/extension_rejection_store.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/day_exception.dart';
import 'package:personal_planner/domain/repositories/day_exception_repository.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/scheduling/extension_day_policy.dart';

final _zones = TimeZoneDatabase();
const _zone = 'UTC';
final _date = DateTime(2026, 10, 17);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 17, 12);
}

ExtensionDayCandidate _candidate() => ExtensionDayCandidate(
  localDate: _date,
  originalSleepStartOffsetMinutes: 1410,
  temporarySleepStartOffsetMinutes: 1500,
  fixedWakeOffsetMinutes: 1890,
  addedPlaceableMinutes: 60,
  sleepLossMinutes: 90,
  triggeringTaskIds: const ['task'],
  stableKey: '2026-10-17|1500|1890|task',
);

PlanPreviewModel _model() => PlanPreviewModel(
  proposalId: 'proposal',
  changes: const [],
  issues: const [],
  isStale: false,
  extensionCandidates: [_candidate()],
);

void main() {
  testWidgets('页面拒绝经路由回调写入真实设置仓储的拒绝记忆', (tester) async {
    final settingsRepository = MemorySettingsRepository();
    final store = SettingsExtensionRejectionStore(settingsRepository);
    final settings = SettingsService(repository: settingsRepository);
    final dayService = DayExceptionService(
      repository: _NoopDayRepository(),
      settings: settings,
      clock: const _Clock(),
      zones: _zones,
      timeZoneId: _zone,
    );
    final extensionService = ExtensionDayService(
      settings: settings,
      dayExceptions: dayService,
      zones: _zones,
      clock: const _Clock(),
      rejectionStore: store,
    );
    final router = GoRouter(
      initialLocation: '/preview',
      routes: [
        GoRoute(
          path: '/preview',
          builder: (context, state) => PlanPreviewPage(
            model: _model(),
            autoAdjustStore: MemoryAutoAdjustStore(),
            onConfirm: (mode) async => ApplyPlanResult.stale(),
            onRejectExtension: () => extensionService.reject(
              inputHash: 'hash-a',
              candidates: [_candidate()],
            ),
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reject-extension-day')));
    await tester.pumpAndSettle();

    expect(
      await store.isRejected(
        ExtensionDayService.rejectionKey(
          inputHash: 'hash-a',
          candidate: _candidate(),
        ),
      ),
      isTrue,
    );
  });
}

/// 拒绝路径不需要读特殊日；仅提供接口实现。
final class _NoopDayRepository implements DayExceptionRepository {
  @override
  Future<DayException?> findConfirmed(DateTime localDate) async => null;

  @override
  Future<List<DayException>> listAffecting(DateTime localDate) async =>
      const [];

  @override
  Future<List<DayException>> listBetween(DateTime first, DateTime last) async =>
      const [];

  @override
  Future<void> save(DayException value) async {}

  @override
  Future<void> revoke(String id, DateTime revokedAtUtc) async {}
}
