abstract interface class MonotonicClock {
  Duration now();
}

final class StopwatchMonotonicClock implements MonotonicClock {
  StopwatchMonotonicClock() : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;

  @override
  Duration now() => _stopwatch.elapsed;
}

final class CallbackMonotonicClock implements MonotonicClock {
  const CallbackMonotonicClock(this._read);

  final Duration Function() _read;

  @override
  Duration now() => _read();
}
