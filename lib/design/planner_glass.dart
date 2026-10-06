import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/design/planner_theme.dart';

final class PlannerBackdrop extends StatefulWidget {
  const PlannerBackdrop({required this.child, super.key});

  final Widget child;

  @override
  State<PlannerBackdrop> createState() => _PlannerBackdropState();
}

final class _PlannerBackdropState extends State<PlannerBackdrop> {
  final _pointer = ValueNotifier<Offset?>(null);

  @override
  void dispose() {
    _pointer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glass = PlannerGlassTheme.of(context);
    final materialKey = Key('app-material-${glass.mode.storedValue}');
    if (glass.mode == PlannerMaterialMode.off) {
      return ColoredBox(
        key: materialKey,
        color: PlannerPalette.canvas,
        child: widget.child,
      );
    }
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final backdrop = DecoratedBox(
      key: materialKey,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff0a1727), Color(0xff0c1522), Color(0xff09131f)],
          stops: [0, 0.54, 1],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.88, -0.82),
                  radius: switch (glass.mode) {
                    PlannerMaterialMode.liquid => 1.08,
                    PlannerMaterialMode.aggressive => 0.92,
                    _ => 0.78,
                  },
                  colors: [glass.ambientPrimary, Colors.transparent],
                  stops: const [0, 1],
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.94, 0.76),
                  radius: switch (glass.mode) {
                    PlannerMaterialMode.liquid => 1.04,
                    PlannerMaterialMode.aggressive => 0.90,
                    _ => 0.72,
                  },
                  colors: [glass.ambientSecondary, Colors.transparent],
                  stops: const [0, 1],
                ),
              ),
            ),
          ),
          if (glass.mode == PlannerMaterialMode.liquid)
            ValueListenableBuilder<Offset?>(
              valueListenable: _pointer,
              builder: (context, position, _) => AnimatedPositioned(
                key: const Key('app-pointer-highlight'),
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 80),
                curve: Curves.easeOut,
                left: (reduceMotion ? 140 : position?.dx ?? 140) - 280,
                top: (reduceMotion ? 110 : position?.dy ?? 110) - 280,
                width: 560,
                height: 560,
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          colors: [
                            Colors.white.withValues(alpha: 0.16),
                            PlannerPalette.accent.withValues(alpha: 0.12),
                            Colors.transparent,
                          ],
                          stops: const [0, 0.3, 1],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          BackdropGroup(child: widget.child),
        ],
      ),
    );
    if (glass.mode != PlannerMaterialMode.liquid || reduceMotion) {
      return backdrop;
    }
    return MouseRegion(
      opaque: false,
      onHover: (event) => _pointer.value = event.localPosition,
      onExit: (_) => _pointer.value = null,
      child: backdrop,
    );
  }
}

final class PlannerGlassSurface extends StatelessWidget {
  const PlannerGlassSurface({
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.padding,
    super.key,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final glass = PlannerGlassTheme.of(context);
    final content = Padding(padding: padding ?? EdgeInsets.zero, child: child);
    if (glass.mode == PlannerMaterialMode.off) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: PlannerPalette.surface,
          border: Border.all(color: PlannerPalette.outline),
          borderRadius: borderRadius,
        ),
        child: content,
      );
    }
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: glass.shadow,
            blurRadius: glass.shadowBlur,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter.grouped(
          filter: ImageFilter.blur(
            sigmaX: glass.blurSigma,
            sigmaY: glass.blurSigma,
          ),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [glass.surfaceHighlight, glass.surface],
                    ),
                    border: Border.all(color: glass.border),
                    borderRadius: borderRadius,
                  ),
                ),
              ),
              if (glass.mode == PlannerMaterialMode.liquid) ...[
                Positioned.fill(
                  child: IgnorePointer(
                    child: Padding(
                      padding: const EdgeInsets.all(1.5),
                      child: DecoratedBox(
                        key: const Key('liquid-refraction-edge'),
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0x2effffff)),
                          borderRadius: borderRadius,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              content,
            ],
          ),
        ),
      ),
    );
    return surface;
  }
}

final class PlannerGlassChrome extends StatelessWidget {
  const PlannerGlassChrome({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final glass = PlannerGlassTheme.of(context);
    if (glass.mode == PlannerMaterialMode.off) {
      return ColoredBox(
        key: const Key('glass-chrome-off-fill'),
        color: glass.chrome,
        child: child,
      );
    }
    return ClipRect(
      child: BackdropFilter.grouped(
        filter: ImageFilter.blur(
          sigmaX: glass.chromeBlurSigma,
          sigmaY: glass.chromeBlurSigma,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: glass.mode == PlannerMaterialMode.liquid
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0x7d29435e), Color(0x65101b2a)],
                  )
                : null,
            color: glass.mode == PlannerMaterialMode.liquid
                ? null
                : glass.chrome,
            border: Border(bottom: BorderSide(color: glass.border)),
            boxShadow: glass.mode == PlannerMaterialMode.liquid
                ? const [
                    BoxShadow(
                      color: Color(0x1fffffff),
                      blurRadius: 1,
                      offset: Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}
