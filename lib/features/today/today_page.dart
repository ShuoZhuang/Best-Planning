import 'package:flutter/material.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';

final class TodayPage extends StatefulWidget {
  const TodayPage({required this.source, required this.day, super.key});

  final ScheduleViewSource source;
  final DateTime day;

  @override
  State<TodayPage> createState() => _TodayPageState();
}

final class _TodayPageState extends State<TodayPage> {
  late Stream<List<ScheduleViewItem>> _stream;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    _stream = widget.source.watch(
      widget.day,
      widget.day.add(const Duration(days: 1)),
    );
  }

  void _retry() => setState(_subscribe);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('今日安排', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 16),
          Expanded(
            child: StreamBuilder<List<ScheduleViewItem>>(
              stream: _stream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return _RecoverableError(onRetry: _retry);
                }
                if (!snapshot.hasData) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('正在加载今日安排'),
                      ],
                    ),
                  );
                }
                final items = [
                  ...snapshot.data!,
                ]..sort((a, b) => a.range.startUtc.compareTo(b.range.startUtc));
                if (items.isEmpty) {
                  return const Center(child: Text('今天暂无安排'));
                }
                return ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) =>
                      _ScheduleItemCard(item: items[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

final class _ScheduleItemCard extends StatelessWidget {
  const _ScheduleItemCard({required this.item});
  final ScheduleViewItem item;

  @override
  Widget build(BuildContext context) {
    final kind = item.kind;
    return Card(
      color: kind.color(Theme.of(context).colorScheme),
      child: ListTile(
        leading: Icon(kind.icon),
        title: Text(item.title),
        subtitle: Text(
          '${_time(item.range.startUtc)}–${_time(item.range.endUtc)}',
        ),
        trailing: Chip(label: Text(kind.label)),
      ),
    );
  }
}

final class _RecoverableError extends StatelessWidget {
  const _RecoverableError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_off_outlined, size: 40),
        const SizedBox(height: 8),
        const Text('暂时无法加载今日安排'),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}

String _time(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';
