import 'package:uuid/uuid.dart';

typedef EntityId = String;
typedef Minutes = int;

abstract interface class IdGenerator {
  EntityId next();
}

final class UuidIdGenerator implements IdGenerator {
  UuidIdGenerator({Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final Uuid _uuid;

  @override
  EntityId next() => _uuid.v4();
}
