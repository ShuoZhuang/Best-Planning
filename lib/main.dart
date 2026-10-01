import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:personal_planner/app/planner_app.dart';

void main() {
  runApp(const ProviderScope(child: PlannerApp()));
}
