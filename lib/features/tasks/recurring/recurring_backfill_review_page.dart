import 'package:flutter/material.dart';
import 'package:personal_planner/data/repositories/drift_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';

/// 周期回填歧义的只读复核页（1.11.0 Task 6）。
///
/// 回填缺少块时间/时长非正时，链接器不会静默跳过，而是写
/// `recurringBackfillAmbiguous` outbox；这里把这些记录展示出来，供用户/开发复核。
class RecurringBackfillReviewPage extends StatefulWidget {
  const RecurringBackfillReviewPage({required this.repository, super.key});

  final DriftExecutionRepository repository;

  @override
  State<RecurringBackfillReviewPage> createState() =>
      _RecurringBackfillReviewPageState();
}

class _RecurringBackfillReviewPageState
    extends State<RecurringBackfillReviewPage> {
  late Future<List<ExecutionOutboxEntry>> _entries;

  @override
  void initState() {
    super.initState();
    _entries = _load();
  }

  Future<List<ExecutionOutboxEntry>> _load() async {
    final pending = await widget.repository.pendingOutbox(limit: 200);
    return [
      for (final entry in pending)
        if (entry.effectType == 'recurringBackfillAmbiguous') entry,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('周期回填复核')),
      body: FutureBuilder<List<ExecutionOutboxEntry>>(
        future: _entries,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snapshot.data!;
          if (rows.isEmpty) {
            return const Center(child: Text('没有待复核的回填歧义'));
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = rows[index];
              final payload = entry.payload;
              return ListTile(
                leading: const Icon(Icons.report_problem_outlined),
                title: Text('${payload['blockId'] ?? '未知块'}'),
                subtitle: Text(
                  '计划 ${payload['planVersionId'] ?? '-'} · '
                  '原因 ${payload['reason'] ?? '-'}',
                ),
              );
            },
          );
        },
      ),
    );
  }
}
