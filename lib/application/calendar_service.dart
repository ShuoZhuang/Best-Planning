import 'dart:collection';

import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/calendar_event_edit.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';

// `EventEditScope` 本轮移到了领域层（`calendar_event_edit.dart`），
// 因为 `CalendarEditTarget` 是领域模型、必须带上它。这里转发一下，
// 既有 `import '.../calendar_service.dart'` 的调用点因此一个字都不用改。
export 'package:personal_planner/domain/models/calendar_event_edit.dart'
    show
        CalendarEditTarget,
        CalendarEventEditDraft,
        CalendarMutationResult,
        CalendarMutationStatus,
        EventEditScope,
        RecurrenceEditDraft;

final class EventDraft {
  const EventDraft({
    required this.title,
    required this.startAtUtc,
    required this.endAtUtc,
    // 必填：此前默认 'Asia/Shanghai'，而唯一的构造方 `EventEditorForm` 并没有传它，
    // 于是界面上保存的日程一律被标记为东八区——与需求 §13"以本机当前时区保存和展示"相悖，
    // 且只在别的时区表现为结果错误，不报错（R11）。
    required this.timeZoneId,
    this.recurrenceRuleId,
    this.exceptionOfId,
    this.locked = true,
    this.areaId,
    this.projectId,
    this.notes = '',
    this.editScope = EventEditScope.singleOccurrence,
    this.recurrenceWeekdays = const {},
    this.recurrenceValidUntilLocalDate,
    this.recurrenceIntervalWeeks = 1,
    this.kind = CalendarEventKind.fixed,
  });

  final String title;
  final DateTime startAtUtc;
  final DateTime endAtUtc;
  final String timeZoneId;
  final String? recurrenceRuleId;
  final String? exceptionOfId;
  final bool locked;
  final String? areaId;

  /// 所属项目（可选）。`calendar_events.project_id` 一直存在，但此前没有任何写入路径，
  /// 因此固定日程在界面上无法归属项目。
  final String? projectId;
  final EventEditScope editScope;
  final Set<int> recurrenceWeekdays;
  final DateTime? recurrenceValidUntilLocalDate;
  final int recurrenceIntervalWeeks;

  /// 固定日程还是保护时间（1.8.0，规范 §9.1）。
  ///
  /// 带默认值 `fixed`：既有的两个编辑入口（固定日程编辑器、日视图改写）都不需要改，
  /// 而保护时间编辑器显式传 `protected`。两种事项共用这一条保存路径正是规范要求的
  /// "复用固定日程及重复规则，不另建平行时间模型"——另建一套就意味着第二套展开、
  /// 第二套例外、第二套冲突检测。
  final CalendarEventKind kind;

  /// 备注（1.8.0，规范 §9.2 把它列为保护时间编辑器的字段之一）。
  ///
  /// **为什么需要往 `EventDraft` 里加**：`CalendarEvent.notes` 与
  /// `calendar_events.notes` 一直都在，课表导入还用它装教师名——但**没有任何编辑器
  /// 能写它**，因为保存路径从 `EventDraft` 构造事件时就丢掉了这一项。
  /// 于是"备注"是一列只读不可写的字段：导入的课有备注，手建的永远没有。
  final String notes;
}

final class EventSaveResult {
  EventSaveResult.success(this.event) : fieldErrors = const <String, String>{};
  EventSaveResult.invalid(Map<String, String> errors)
    : event = null,
      fieldErrors = UnmodifiableMapView(errors);

  final CalendarEvent? event;
  final Map<String, String> fieldErrors;
  bool get isSuccess => event != null;
}

final class CalendarService {
  CalendarService({
    required CalendarRepository repository,
    RecurringCalendarRepository? recurringRepository,
    CalendarEventDeletion? deletion,
    required Clock clock,
    required IdGenerator idGenerator,
    required TimeZoneDatabase zones,
    void Function(ScheduleInputChange change)? onScheduleInputChanged,
  }) : this._(
         repository,
         recurringRepository,
         deletion,
         clock,
         idGenerator,
         zones,
         onScheduleInputChanged,
       );

  CalendarService._(
    this._repository,
    this._recurringRepository,
    this._deletion,
    this._clock,
    this._idGenerator,
    this._zones,
    this._onScheduleInputChanged,
  );

  final CalendarRepository _repository;
  final RecurringCalendarRepository? _recurringRepository;
  final CalendarEventDeletion? _deletion;
  final Clock _clock;
  final IdGenerator _idGenerator;
  final TimeZoneDatabase _zones;

  /// 固定日程的**创建／删除／改写**会改变排程输入——固定日程占用的时间是排程的硬约束，因此
  /// 每次成功写入各记一条 `replan:` 事件（FR-STAT-06 的"重排原因"）。
  ///
  /// 与 `TaskService.onScheduleInputChanged` **同一口径、同一装配点**：用回调而不是直接依赖统计
  /// 模块（日历服务不该知道统计存在），未装配时只是不留原因，不影响任何行为。原因码用人类可读
  /// 的话而不是枚举名，因为统计页把它**直接显示给用户**。
  ///
  /// **为什么现在才接**：这条路径此前登记为"未覆盖"（§13.0 W9 的 (a)）——任务侧的四类变化那时
  /// 已有发出者，而固定日程的增删改同样会改变排程，却因为写入方在日历服务里而漏掉。只覆盖一半
  /// 会让统计里的"重排原因"**看起来像一份完整分布**，实际却整整缺了日历这一类。
  ///
  /// **只记成功的写入**（与任务侧一致：改不动就没有重排）。唯一无法区分的情形是幂等删除——端口
  /// 的 `deleteEvent` 不返回"是否真的删掉了"，因此拿一个已过期的 id 来删也会记一条原因。这里选择
  /// 宁可多记一次意图，也不改动端口签名（它在 5 个测试替身里被实现，改签名会一次牵动 5 个文件）。
  final void Function(ScheduleInputChange change)? _onScheduleInputChanged;

  /// 改写整个系列（FR-CAL-02 的"整个系列"编辑一半）。所有各次一起换到新时间。
  ///
  /// 与 [replaceOccurrence] 同路：锚点与规则都在仓储侧读写（它才摸得到规则行），本服务只转发。
  ///
  /// **deprecated 包装器**（课程与保护时间管理修复计划 Task 2 Step 4）：内部构造完整草稿并转到
  /// [updateEvent]。等 Task 8 把全部调用方迁到 `updateEvent` 之后再删——一次提交就让整个仓库
  /// 编译不过，会把"有没有回归"和"还没改完"混在一起。
  @Deprecated(
    'Use updateEvent with CalendarEditTarget(scope: entireSeries) instead.',
  )
  Future<bool> replaceSeries({
    required String anchorId,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
  }) async {
    final result = await updateEvent(
      target: CalendarEditTarget(
        anchorId: anchorId,
        scope: EventEditScope.entireSeries,
      ),
      event: CalendarEventEditDraft(
        title: _titleCache[anchorId] ?? _fallbackTitle,
        startAtUtc: newStartUtc,
        endAtUtc: newEndUtc,
        timeZoneId: _fallbackTimeZoneId,
      ),
    );
    return result.isSuccess;
  }

  @Deprecated(
    'Use updateEvent with CalendarEditTarget(scope: followingOccurrences).',
  )
  Future<bool> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
  }) async {
    final result = await updateEvent(
      target: CalendarEditTarget(
        anchorId: anchorId,
        scope: EventEditScope.followingOccurrences,
        occurrenceStartUtc: occurrenceStartUtc,
      ),
      event: CalendarEventEditDraft(
        title: _titleCache[anchorId] ?? _fallbackTitle,
        startAtUtc: newStartUtc,
        endAtUtc: newEndUtc,
        timeZoneId: _fallbackTimeZoneId,
      ),
    );
    return result.isSuccess;
  }

  /// 兼容期用的兜底标题与时区。
  ///
  /// 旧接口只给"新起止"，**没有标题也没有时区**——而完整草稿两者都是必填。
  /// 这里刻意选一个**明显不是真实值**的标题，而不是空串：空标题会让草稿判为非法，
  /// 于是旧调用点在迁移期直接失效（那是"一次提交让仓库编译不过"的另一种形态）。
  /// Task 8 迁完之后这些包装器会被删除。
  static const String _fallbackTitle = '未命名事项';
  static const String _fallbackTimeZoneId = 'UTC';

  /// 旧接口把标题写在调用点，这里用一个进程内缓存把它捡回来。
  ///
  /// **为什么需要**：`replaceSeries` 的旧签名里根本没有标题，而"改系列"必须写出一个标题。
  /// 与其猜一个（那会把用户起过的名字抹掉），不如让调用方在迁移期显式登记一次。
  final Map<String, String> _titleCache = {};

  /// 在调用 deprecated 包装器之前登记这条事项的标题。
  ///
  /// 迁移期专用：Task 8 之后调用方直接传 [CalendarEventEditDraft]，这个方法随之删除。
  @Deprecated('Only for the deprecated replace* wrappers during migration.')
  void rememberTitleForLegacyWrappers(String anchorId, String title) {
    _titleCache[anchorId] = title;
  }

  Future<bool> deleteFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
  }) async {
    final deletion = _deletion;
    if (deletion == null) return false;
    await deletion.deleteFollowingOccurrences(
      anchorId: anchorId,
      occurrenceStartUtc: occurrenceStartUtc,
      updatedAtUtc: _clock.nowUtc(),
    );
    await _reportChange(anchorId: anchorId, action: '本次及以后删除');
    return true;
  }

  /// **统一的日历改写入口**（课程与保护时间管理修复计划 Task 2 Step 3）。
  ///
  /// 按 [target] 的范围分派到对应端口，并把三类失败如实区分开：
  ///
  /// | 情况 | 结果 | 数据 |
  /// | --- | --- | --- |
  /// | 草稿非法 | `invalid` ＋ 字段错误 | 零写入 |
  /// | 缺 `occurrenceStartUtc` 的"这一次／此次以后" | `invalid` | 零写入 |
  /// | 端口未装配 | `unsupported` | 零写入 |
  /// | 写入成功但**重排原因回调抛错** | `savedWithWarning` | **已保存** |
  ///
  /// **为什么最后一行必须与"保存失败"分开**：把已经落库的改动报成失败，用户会再改一次，
  /// 而那会写第二遍。计划 §5 的失败表对此有明确要求。
  Future<CalendarMutationResult> updateEvent({
    required CalendarEditTarget target,
    required CalendarEventEditDraft event,
    RecurrenceEditDraft? recurrence,
  }) async {
    if (!event.isValid) {
      return CalendarMutationResult.invalid(event.fieldErrors);
    }
    if (recurrence != null && !recurrence.isValid) {
      return CalendarMutationResult.invalid(recurrence.fieldErrors);
    }
    // "这一次／此次及以后"必须有真实发生时间。**不猜**：猜一个日期出来会让例外
    // 落在用户没看着的那一天上，而界面上什么都不会提示。
    final needsOccurrence =
        target.scope == EventEditScope.singleOccurrence ||
        target.scope == EventEditScope.followingOccurrences;
    if (needsOccurrence && target.occurrenceStartUtc == null) {
      return CalendarMutationResult.invalid(const {
        'occurrenceStartUtc': '缺少要修改的那一次课的时间',
      });
    }
    final deletion = _deletion;
    if (deletion == null) {
      return CalendarMutationResult.failed(
        CalendarMutationStatus.unsupported,
        '日历写入服务未装配，暂无法修改「${event.title}」',
      );
    }

    final updatedAtUtc = _clock.nowUtc();

    // **乐观并发**（计划 Task 7 Step 4）：页面数据在别处被改过时返回 `stale`，
    // **零写入**。判定放在写入之前——一旦开始写就无从"什么都没改"。
    //
    // 判定发生在服务层而不是仓储：仓储没有时钟，也没有"用户打开页面那一刻"的概念，
    // 而这里收到的 `expectedUpdatedAtUtc` 正是那一刻读到的值（Task 3/6 的读模型带出来）。
    final expected = target.expectedUpdatedAtUtc;
    if (expected != null) {
      final current = await _currentUpdatedAtOf(target.anchorId);
      if (current == null) {
        return CalendarMutationResult.failed(
          CalendarMutationStatus.missing,
          '「${event.title}」已删除，请重新打开',
        );
      }
      if (current.microsecondsSinceEpoch != expected.microsecondsSinceEpoch) {
        return CalendarMutationResult.failed(
          CalendarMutationStatus.stale,
          '「${event.title}」在别处已被修改，请重新打开后再编辑',
        );
      }
    }

    try {
      switch (target.scope) {
        case EventEditScope.singleOccurrence:
          await deletion.replaceOccurrence(
            anchorId: target.anchorId,
            occurrenceStartUtc: target.occurrenceStartUtc!,
            event: event,
            exceptionId: _idGenerator.next(),
            updatedAtUtc: updatedAtUtc,
          );
        case EventEditScope.followingOccurrences:
          await deletion.replaceFollowingOccurrences(
            anchorId: target.anchorId,
            occurrenceStartUtc: target.occurrenceStartUtc!,
            event: event,
            recurrence: recurrence,
            newRuleId: _idGenerator.next(),
            newEventId: _idGenerator.next(),
            updatedAtUtc: updatedAtUtc,
          );
        case EventEditScope.entireSeries:
          await deletion.replaceSeries(
            anchorId: target.anchorId,
            event: event,
            recurrence: recurrence,
            updatedAtUtc: updatedAtUtc,
            // **未来的正常例外跟着改名**（Task 7 Step 3）：不传这个界线，
            // 用户会看到"周一叫新名字、周三那一次还叫旧名字"——而两处是同一条规则。
            updateExceptionsFromUtc: updatedAtUtc,
          );
      }
    } on Object catch (error) {
      // **事务失败要如实说**：计划 §5 的文案是"保存失败，原内容未改变"，
      // 而不是把异常 toString 摊给用户。
      return CalendarMutationResult.failed(
        CalendarMutationStatus.failed,
        '保存「${event.title}」失败，原内容未改变：$error',
      );
    }

    final action = switch (target.scope) {
      EventEditScope.singleOccurrence => '单次改写',
      EventEditScope.followingOccurrences => '本次及以后改写',
      EventEditScope.entireSeries => '系列改写',
    };
    try {
      await _reportChange(anchorId: target.anchorId, action: action);
    } on Object catch (error) {
      // **数据已经落库了**。这一步只是记一条重排原因，它失败不该让用户以为
      // 自己的修改没保存——那会导致重复修改。
      return CalendarMutationResult.savedWithWarning('内容已保存，但变更记录失败：$error');
    }
    return CalendarMutationResult.saved();
  }

  /// 读某个锚点当前的 `updated_at_utc`；不存在返回 `null`。
  ///
  /// **用 `occurrencesBetween` 而不是往端口加一个"按 id 读锚点"**：把锚点行取出来的
  /// 既有路径就是展开查询，而它顺带保证"页面看到的"与"这里判定的"是**同一份数据**。
  ///
  /// 窗口往前取一年、往后取十年：系列常常已经开始了，而展开查询按窗口裁剪——
  /// 只从"现在"往后读会让**已经开始过的**系列找不到锚点，于是合法编辑被判成"已删除"。
  Future<DateTime?> _currentUpdatedAtOf(String anchorId) async {
    final now = _clock.nowUtc();
    final occurrences = await _repository.occurrencesBetween(
      now.subtract(const Duration(days: 365)),
      now.add(const Duration(days: 3650)),
    );
    for (final occurrence in occurrences) {
      if (occurrence.eventId == anchorId) return occurrence.updatedAtUtc;
    }
    return null;
  }

  /// 读某个时间窗内的日程占用（1.8.0）。
  ///
  /// **为什么不给调用方一个 `CalendarRepository`**：`CourseManagementService` 需要读
  /// "改课程时间会撞上谁"，而它已经持有 `CalendarService` 来**写**。再塞一个读端口进去，
  /// 就会出现两个来源可能指向不同实现的可能——那是"同一份数据在两处读"的经典缺陷。
  /// 这里读与写共用同一个 `_repository`。
  ///
  /// **它不做任何过滤**：调用方（冲突预览）自己按 `logicalCourseId`、`kind`、事件 id
  /// 去区分"这是我自己还是别人"。
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) => _repository.occurrencesBetween(startUtc, endUtc);

  /// 调整固定日程的所属领域（`null` 取消归属）。端口未装配时返回 false。
  ///
  /// 领域是整条日程的属性：重复日程已写下的例外行各自带着自己的归属（改写时从锚点复制），
  /// 这里改锚点，因此"以后新出现的那几次"跟随新归属，历史例外保持原样。
  Future<bool> setEventArea({
    required String eventId,
    required String? areaId,
  }) async {
    final deletion = _deletion;
    if (deletion == null) return false;
    await deletion.setEventArea(
      eventId: eventId,
      areaId: areaId,
      updatedAtUtc: _clock.nowUtc(),
    );
    _onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '固定日程归属调整',
        kind: DomainChangeKind.fixedEventChanged,
      ),
    );
    return true;
  }

  /// 改写重复日程里的某一次（FR-CAL-02 的"修改单次实例"）。
  ///
  /// 与 [deleteOccurrence] 同路：判定"是不是重复日程"与例外的时区都在仓储侧（它才摸得到规则
  /// 行）。未装配该端口时返回 `false`，而不是假装改掉了。
  ///
  /// **deprecated 包装器**：见 [replaceSeries] 的说明。
  @Deprecated(
    'Use updateEvent with CalendarEditTarget(scope: singleOccurrence) instead.',
  )
  Future<bool> replaceOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required String title,
  }) async {
    final result = await updateEvent(
      target: CalendarEditTarget(
        anchorId: anchorId,
        scope: EventEditScope.singleOccurrence,
        occurrenceStartUtc: occurrenceStartUtc,
      ),
      event: CalendarEventEditDraft(
        title: title,
        startAtUtc: newStartUtc,
        endAtUtc: newEndUtc,
        timeZoneId: _timeZoneOf(anchorId),
      ),
    );
    return result.isSuccess;
  }

  /// 兼容期用的时区兜底：按锚点登记过的时区，没有则用 [timeZoneId] 的默认值。
  String _timeZoneOf(String anchorId) =>
      _timeZoneCache[anchorId] ?? _fallbackTimeZoneId;

  final Map<String, String> _timeZoneCache = {};

  /// 迁移期专用：登记某个锚点事项自己的时区。
  @Deprecated('Only for the deprecated replace* wrappers during migration.')
  void rememberTimeZoneForLegacyWrappers(String anchorId, String timeZoneId) {
    _timeZoneCache[anchorId] = timeZoneId;
  }

  /// 只删除重复日程里的**某一次**（FR-CAL-02 的"修改单次实例"的删除一半）。
  ///
  /// 实现细节在仓储侧：写入一行**起止相同的零长度例外**（约定见 `DriftCalendarRepository`
  /// 的读取端与 §13.0 的 R4 行），锚点不带规则时退化为删除该行本身。
  /// 未装配重复日程端口时返回 `false`，而不是假装删掉了。
  Future<bool> deleteOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required String title,
  }) async {
    final deletion = _deletion;
    if (deletion == null) return false;
    await deletion.deleteOccurrence(
      anchorId: anchorId,
      occurrenceStartUtc: occurrenceStartUtc,
      title: title,
      exceptionId: _idGenerator.next(),
      updatedAtUtc: _clock.nowUtc(),
    );
    await _reportChange(anchorId: anchorId, action: '单次删除');
    return true;
  }

  /// 删除一条固定日程（FR-CAL-01）。未装配删除端口时返回 false，而不是假装删掉了。
  ///
  /// 返回 `bool`：界面据此显示"已删除／未装配"。**幂等**语义让"记录已不在"也算成功——调用方
  /// 拿到的 id 可能来自一次已过期的视图。
  ///
  /// **端口抛错时返回 `false` 而不是把异常抛给界面**（课程与保护时间管理修复计划 Task 6）：
  /// 删除是用户点一下就要看到结果的动作，而界面已经有一条"这次删除没有成功，请重试"的
  /// 提示路径。让异常穿透只会变成一次未捕获错误，用户看到的是空白或崩溃，
  /// 而实际结果是**什么都没删**——那正是这条返回值要如实说明的事。
  Future<bool> deleteEvent(String eventId) async {
    final deletion = _deletion;
    if (deletion == null) return false;
    // **先问清要删的是哪一类**（1.8.0，规范 §9.3）：这一句必须发生在删除**之前**，
    // 删掉之后就没有任何地方能回答它了。
    final wasProtected = await _isProtectedEvent(eventId);
    try {
      await deletion.deleteEvent(eventId);
    } on Object {
      // 数据库异常、外键约束、并发删除……对用户都是同一件事：**这次删除没成功**。
      // 具体原因留在诊断日志里（仓储层会记），界面只负责如实说"没成功"。
      return false;
    }
    _onScheduleInputChanged?.call(
      ScheduleInputChange(
        label: wasProtected ? '保护时间删除' : '固定日程删除',
        kind: DomainChangeKind.fixedEventChanged,
      ),
    );
    return true;
  }

  /// 记一条"排程输入变了"的原因，文案按**被改的那一条是哪一类**选择。
  ///
  /// **为什么要有这个函数**：六条写入路径原先各自内联了一句
  /// `const ScheduleInputChange(label: '固定日程…')`。保护时间的删除与改写走的是**同样
  /// 这六条方法**，于是"删一条保护时间"在统计页的"重排原因"里显示成"固定日程删除"——
  /// 一件用户没做过的事。上一轮我只改了最显眼的 `save` 与 `deleteEvent` 两处，
  /// **剩下五条照旧**：这正是"只修看得见的那一条"的典型残余形态。
  ///
  /// 把"问哪一类 + 拼文案"收到一处，是因为这两件事必须**永远同时**发生：
  /// 分开写就总会有人只改一半。
  ///
  /// 一律用 `fixedEventChanged` 这一类别：`affectsSchedule` 只对 `taskNotesChanged`
  /// 返回 false，因此保护时间的删除与改写**和固定日程一样**应当触发重排。
  Future<void> _reportChange({
    required String anchorId,
    required String action,
  }) async {
    final wasProtected = await _isProtectedEvent(anchorId);
    _onScheduleInputChanged?.call(
      ScheduleInputChange(
        label: wasProtected ? '保护时间$action' : '固定日程$action',
        kind: DomainChangeKind.fixedEventChanged,
      ),
    );
  }

  /// [eventId] 是不是一条保护时间（规范 §9.1 的 `kind`）。
  ///
  /// 用"读到它本身"来判断，而不是新加一个只返回 `kind` 的仓储方法：读取路径已经有
  /// `occurrencesBetween`，加一条平行查询就意味着**第二套"什么算这条事件"的判据**——
  /// 而那个判据要与展开器、例外、时区都保持一致，正是最容易漂的地方。
  ///
  /// **读不到时返回 `false`**（按固定日程记账）：读不到通常意味着它已经被删掉、
  /// 或者落在查询窗口之外，两者都不该让原因文案变成一句不可信的话。
  Future<bool> _isProtectedEvent(String eventId) async {
    try {
      final occurrences = await _repository.occurrencesBetween(
        DateTime.utc(1970),
        DateTime.utc(2200),
      );
      for (final occurrence in occurrences) {
        if (occurrence.eventId == eventId) {
          return occurrence.kind == CalendarEventKind.protected;
        }
      }
    } on Object {
      // 读不到就不猜：宁可按固定日程记账，也不写一句没有依据的文案。
      return false;
    }
    return false;
  }

  Future<EventSaveResult> save(EventDraft draft) async {
    final errors = <String, String>{};
    if (draft.title.trim().isEmpty) errors['title'] = '请输入日程标题';
    if (!draft.startAtUtc.isUtc || !draft.endAtUtc.isUtc) {
      errors['time'] = '日程时间必须转换为 UTC';
    } else if (!draft.endAtUtc.isAfter(draft.startAtUtc)) {
      errors['time'] = '结束时间必须晚于开始时间';
    }
    if (draft.timeZoneId.trim().isEmpty) errors['timeZoneId'] = '请选择时区';
    if (draft.recurrenceWeekdays.any((day) => day < 1 || day > 7)) {
      errors['recurrence'] = '重复星期无效';
    }
    if (draft.recurrenceWeekdays.isNotEmpty && _recurringRepository == null) {
      errors['recurrence'] = '当前日历存储不支持重复日程';
    }
    if (draft.recurrenceWeekdays.isNotEmpty &&
        draft.startAtUtc.isUtc &&
        draft.timeZoneId.trim().isNotEmpty) {
      final localStart = _zones.toLocal(draft.startAtUtc, draft.timeZoneId);
      final firstLocalDate = DateTime(
        localStart.year,
        localStart.month,
        localStart.day,
      );
      final validUntil = draft.recurrenceValidUntilLocalDate;
      if (draft.recurrenceIntervalWeeks < 1 ||
          draft.recurrenceIntervalWeeks > 52) {
        errors['recurrence'] = '重复间隔必须在 1 到 52 周之间';
      } else if (validUntil != null &&
          _dateOnly(validUntil).isBefore(firstLocalDate)) {
        errors['recurrence'] = '重复结束日期不能早于开始日期';
      }
    }
    if (errors.isNotEmpty) return EventSaveResult.invalid(errors);

    final now = _clock.nowUtc();
    final recurring = draft.recurrenceWeekdays.isNotEmpty;
    final ruleId = recurring ? _idGenerator.next() : null;
    final event = CalendarEvent(
      id: _idGenerator.next(),
      title: draft.title,
      startAtUtc: draft.startAtUtc,
      endAtUtc: draft.endAtUtc,
      timeZoneId: draft.timeZoneId,
      recurrenceRuleId: ruleId ?? draft.recurrenceRuleId,
      exceptionOfId: draft.exceptionOfId,
      locked: draft.locked,
      areaId: draft.areaId,
      projectId: draft.projectId,
      notes: draft.notes,
      kind: draft.kind,
      updatedAtUtc: now,
    );
    if (recurring) {
      final localStart = _zones.toLocal(draft.startAtUtc, draft.timeZoneId);
      final rule = RecurrenceRule(
        id: ruleId!,
        weekdays: draft.recurrenceWeekdays,
        localStartMinute: localStart.hour * 60 + localStart.minute,
        durationMinutes: draft.endAtUtc.difference(draft.startAtUtc).inMinutes,
        intervalWeeks: draft.recurrenceIntervalWeeks,
        validFromLocalDate: DateTime(
          localStart.year,
          localStart.month,
          localStart.day,
        ),
        validUntilLocalDate: draft.recurrenceValidUntilLocalDate == null
            ? null
            : _dateOnly(draft.recurrenceValidUntilLocalDate!),
        timeZoneId: draft.timeZoneId,
      );
      await _recurringRepository!.saveRecurring(event, rule);
    } else {
      await _repository.save(event);
    }
    _onScheduleInputChanged?.call(
      ScheduleInputChange(
        // 保护时间不是固定日程（§9.1：它不作为"固定日程投入"统计），因此原因文案
        // 必须分开——这句话直接显示在统计页的"重排原因"里。
        label: draft.kind == CalendarEventKind.protected ? '保护时间创建' : '固定日程创建',
        kind: DomainChangeKind.fixedEventCreated,
      ),
    );
    return EventSaveResult.success(event);
  }
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
