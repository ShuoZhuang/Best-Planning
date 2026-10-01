import 'package:flutter/material.dart';
import 'package:personal_planner/app/router.dart';

final class PlannerApp extends StatelessWidget {
  const PlannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: '智能日程',
      debugShowCheckedModeBanner: false,
      routerConfig: plannerRouter,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff315b4c),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
    );
  }
}
