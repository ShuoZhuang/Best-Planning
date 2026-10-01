sealed class AppResult<T> {
  const AppResult();

  R when<R>({
    required R Function(T value) success,
    required R Function(AppFailure failure) failure,
  });
}

final class Success<T> extends AppResult<T> {
  const Success(this.value);

  final T value;

  @override
  R when<R>({
    required R Function(T value) success,
    required R Function(AppFailure failure) failure,
  }) => success(value);
}

final class Failure<T> extends AppResult<T> {
  const Failure(this.error);

  final AppFailure error;

  @override
  R when<R>({
    required R Function(T value) success,
    required R Function(AppFailure failure) failure,
  }) => failure(error);
}

final class AppFailure {
  const AppFailure(this.code, {this.details = const {}});

  final String code;
  final Map<String, Object?> details;
}
