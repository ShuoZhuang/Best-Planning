import 'package:flutter/material.dart';
import 'package:personal_planner/application/task_service.dart';

final class QuickAddForm extends StatefulWidget {
  const QuickAddForm({required this.service, super.key});

  final TaskService service;

  @override
  State<QuickAddForm> createState() => _QuickAddFormState();
}

final class _QuickAddFormState extends State<QuickAddForm> {
  final _titleController = TextEditingController();
  final _durationController = TextEditingController();
  Map<String, String> _errors = const {};
  String? _status;

  @override
  void dispose() {
    _titleController.dispose();
    _durationController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final minutes = int.tryParse(_durationController.text.trim()) ?? 0;
    final result = await widget.service.quickAdd(
      _titleController.text,
      minutes,
    );
    if (!mounted) return;
    setState(() {
      _errors = result.fieldErrors;
      _status = result.isSuccess ? '已加入收集箱' : null;
      if (result.isSuccess) {
        _titleController.clear();
        _durationController.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('quick-add-title'),
          controller: _titleController,
          autofocus: true,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: '任务标题',
            errorText: _errors['title'],
          ),
        ),
        TextField(
          key: const Key('quick-add-duration'),
          controller: _durationController,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: '预计时长（分钟）',
            errorText: _errors['estimatedMinutes'],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.add),
          label: const Text('加入收集箱'),
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_status!),
          ),
      ],
    );
  }
}
