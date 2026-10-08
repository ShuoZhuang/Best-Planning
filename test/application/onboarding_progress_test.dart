// M8 操作式引导：状态机（用户 2026-10-07 定案）。
//
// 规格：`docs/superpowers/specs/2026-10-08-m8-guided-onboarding.md`
//
// **这个文件守的核心是一句话**：
// **「退出」「跳过」「完成」是三个不同的状态，退出不得冒充完成。**
// 因此这里逐条钉住四个状态的读写、以及"某个动作**不该**改变状态"这件事——
// 后者比前者重要：一个"退出时误写已完成"的缺陷会让用户**再也看不到引导**，
// 而界面上不会有任何异常。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/onboarding_progress.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';

void main() {
  late MemorySettingsRepository settings;
  late OnboardingProgressStore store;

  setUp(() {
    settings = MemorySettingsRepository();
    store = OnboardingProgressStore(settings: settings);
  });

  test('M8 未开始时状态是 notStarted', () async {
    final progress = await store.load();
    expect(progress.state, OnboardingState.notStarted);
    expect(progress.step, isNull, reason: '没开始过就没有"进行到哪一步"');
  });

  test('M8 四个状态各自能写能读（往返一致）', () async {
    for (final state in OnboardingState.values) {
      await store.save(OnboardingProgress(state: state));
      final loaded = await store.load();
      expect(loaded.state, state, reason: '${state.name} 往返应当一致');
    }
  });

  test('M8 记下的步骤能读回来', () async {
    await store.save(
      const OnboardingProgress(
        state: OnboardingState.inProgress,
        step: 'confirmDefaults',
      ),
    );
    expect((await store.load()).step, 'confirmDefaults');
  });

  test('M8 值不认识时回落 notStarted（脏数据不能让应用打不开）', () async {
    // 手改过的值、或未来版本写下的新状态名。
    await settings.write(OnboardingProgressStore.stateKey, 'wat-not-a-state');
    expect((await store.load()).state, OnboardingState.notStarted);
  });

  // ── 核心：三个动作互不冒充 ───────────────────────────────────────────────

  test('M8 **退出**不写"已完成"：退出后仍是进行中', () async {
    await store.begin(step: 'createTask');
    expect((await store.load()).state, OnboardingState.inProgress);

    // "退出"＝什么都不做（关窗口/返回主界面）。因此这里**故意不调用任何 store 方法**，
    // 直接重新读——状态必须原样保留。
    final afterExit = await store.load();
    expect(
      afterExit.state,
      OnboardingState.inProgress,
      reason: '退出绝不能冒充完成，否则用户再也看不到引导',
    );
    expect(afterExit.step, 'createTask', reason: '"进行到哪一步"也要留着，才能继续');
  });

  test('M8 「暂时跳过」保持进行中（它只跳过这一次，不是放弃引导）', () async {
    await store.begin(step: 'createTask');
    await store.snooze();

    final progress = await store.load();
    expect(
      progress.state,
      OnboardingState.inProgress,
      reason: '「暂时跳过」只跳过本次，下次启动仍要问——不能变成 skipped 也不能变成 completed',
    );
    expect(progress.step, 'createTask', reason: '进度不能因为"暂时跳过"就丢');
  });

  test('M8 「跳过引导」记成已跳过', () async {
    await store.begin(step: 'createTask');
    await store.skip();
    expect((await store.load()).state, OnboardingState.skipped);
  });

  test('M8 「完成」记成已完成', () async {
    await store.begin(step: 'createTask');
    await store.complete();
    expect((await store.load()).state, OnboardingState.completed);
  });

  test('M8 「重新开始」只重置进度：状态回到进行中、步骤清空', () async {
    await store.save(
      const OnboardingProgress(
        state: OnboardingState.inProgress,
        step: 'reviewPlan',
      ),
    );
    await store.restart();

    final progress = await store.load();
    expect(progress.state, OnboardingState.inProgress);
    expect(progress.step, isNull, reason: '重新开始＝从第一步再来，不该沿用上次的步骤');
  });

  test('M8 「重新开始」只碰引导进度键，不碰任何别的设置', () async {
    // 规格 §1.2："「重新开始」**只重置引导进度**，不能删除已经创建的真实任务、
    // 课程或已确认计划。" 任务/课程不在 SettingsRepository 里，因此这里能验的是
    // **不越界**：引导自己的两个键以外，一个字节都不许动。
    await settings.write('规划规则', '用户改过的值');
    await settings.write('appearance.glass-mode', 'liquid');
    await store.begin(step: 'createTask');

    await store.restart();

    expect(await settings.read('规划规则'), '用户改过的值');
    expect(await settings.read('appearance.glass-mode'), 'liquid');
  });

  test('M8 「已跳过」与「已完成」都不会被当成"进行中"', () async {
    await store.skip();
    expect(await store.needsResumePrompt(), isFalse, reason: '跳过之后不再反复打扰');

    await store.complete();
    expect(await store.needsResumePrompt(), isFalse, reason: '完成之后更不该再问');
  });

  test('M8 进行中时启动**要**问"继续引导"', () async {
    await store.begin(step: 'createTask');
    expect(await store.needsResumePrompt(), isTrue);
  });

  test('M8 未开始时**不问**"继续引导"（没开始过就没什么可继续的）', () async {
    expect(
      await store.needsResumePrompt(),
      isFalse,
      reason: 'notStarted 应当直接进引导首页，而不是先问"要不要继续"',
    );
  });

  // ── 与既有 schema 键互不干扰 ────────────────────────────────────────────

  test('M8 schema 版本与引导状态是两个维度，互不影响', () async {
    // 关键默认值确认版本（既有键）抬高，不该把"引导已完成"抹掉——
    // 否则新增一个默认值就会让老用户被当成"从没引导过"。
    await store.complete();
    await settings.write('onboarding.schemaVersion', '99');

    expect(
      (await store.load()).state,
      OnboardingState.completed,
      reason: 'schema 抬高只表示"有新默认值要增量确认"，不表示"引导没做过"',
    );
  });

  test('M8 写引导状态不会碰 schema 键', () async {
    await settings.write('onboarding.schemaVersion', '7');
    await store.begin(step: 'createTask');
    await store.skip();
    expect(await settings.read('onboarding.schemaVersion'), '7');
  });
}
