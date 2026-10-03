// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $AreasTable extends Areas with TableInfo<$AreasTable, Area> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AreasTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _colorMeta = const VerificationMeta('color');
  @override
  late final GeneratedColumn<int> color = GeneratedColumn<int>(
    'color',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isLifeMeta = const VerificationMeta('isLife');
  @override
  late final GeneratedColumn<bool> isLife = GeneratedColumn<bool>(
    'is_life',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_life" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtUtcMeta = const VerificationMeta(
    'createdAtUtc',
  );
  @override
  late final GeneratedColumn<int> createdAtUtc = GeneratedColumn<int>(
    'created_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  static const VerificationMeta _updatedAtUtcMeta = const VerificationMeta(
    'updatedAtUtc',
  );
  @override
  late final GeneratedColumn<int> updatedAtUtc = GeneratedColumn<int>(
    'updated_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    color,
    sortOrder,
    isLife,
    createdAtUtc,
    updatedAtUtc,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'areas';
  @override
  VerificationContext validateIntegrity(
    Insertable<Area> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('color')) {
      context.handle(
        _colorMeta,
        color.isAcceptableOrUnknown(data['color']!, _colorMeta),
      );
    } else if (isInserting) {
      context.missing(_colorMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    } else if (isInserting) {
      context.missing(_sortOrderMeta);
    }
    if (data.containsKey('is_life')) {
      context.handle(
        _isLifeMeta,
        isLife.isAcceptableOrUnknown(data['is_life']!, _isLifeMeta),
      );
    }
    if (data.containsKey('created_at_utc')) {
      context.handle(
        _createdAtUtcMeta,
        createdAtUtc.isAcceptableOrUnknown(
          data['created_at_utc']!,
          _createdAtUtcMeta,
        ),
      );
    }
    if (data.containsKey('updated_at_utc')) {
      context.handle(
        _updatedAtUtcMeta,
        updatedAtUtc.isAcceptableOrUnknown(
          data['updated_at_utc']!,
          _updatedAtUtcMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Area map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Area(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      color: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      isLife: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_life'],
      )!,
      createdAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_utc'],
      )!,
      updatedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_utc'],
      )!,
    );
  }

  @override
  $AreasTable createAlias(String alias) {
    return $AreasTable(attachedDatabase, alias);
  }
}

class Area extends DataClass implements Insertable<Area> {
  final String id;
  final String name;
  final int color;
  final int sortOrder;

  /// Marks an area as belonging to life rather than work, which the life-quota
  /// soft constraint and the calendar life category both read.
  final bool isLife;
  final int createdAtUtc;
  final int updatedAtUtc;
  const Area({
    required this.id,
    required this.name,
    required this.color,
    required this.sortOrder,
    required this.isLife,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['color'] = Variable<int>(color);
    map['sort_order'] = Variable<int>(sortOrder);
    map['is_life'] = Variable<bool>(isLife);
    map['created_at_utc'] = Variable<int>(createdAtUtc);
    map['updated_at_utc'] = Variable<int>(updatedAtUtc);
    return map;
  }

  AreasCompanion toCompanion(bool nullToAbsent) {
    return AreasCompanion(
      id: Value(id),
      name: Value(name),
      color: Value(color),
      sortOrder: Value(sortOrder),
      isLife: Value(isLife),
      createdAtUtc: Value(createdAtUtc),
      updatedAtUtc: Value(updatedAtUtc),
    );
  }

  factory Area.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Area(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      color: serializer.fromJson<int>(json['color']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      isLife: serializer.fromJson<bool>(json['isLife']),
      createdAtUtc: serializer.fromJson<int>(json['createdAtUtc']),
      updatedAtUtc: serializer.fromJson<int>(json['updatedAtUtc']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'color': serializer.toJson<int>(color),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'isLife': serializer.toJson<bool>(isLife),
      'createdAtUtc': serializer.toJson<int>(createdAtUtc),
      'updatedAtUtc': serializer.toJson<int>(updatedAtUtc),
    };
  }

  Area copyWith({
    String? id,
    String? name,
    int? color,
    int? sortOrder,
    bool? isLife,
    int? createdAtUtc,
    int? updatedAtUtc,
  }) => Area(
    id: id ?? this.id,
    name: name ?? this.name,
    color: color ?? this.color,
    sortOrder: sortOrder ?? this.sortOrder,
    isLife: isLife ?? this.isLife,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
  Area copyWithCompanion(AreasCompanion data) {
    return Area(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      color: data.color.present ? data.color.value : this.color,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      isLife: data.isLife.present ? data.isLife.value : this.isLife,
      createdAtUtc: data.createdAtUtc.present
          ? data.createdAtUtc.value
          : this.createdAtUtc,
      updatedAtUtc: data.updatedAtUtc.present
          ? data.updatedAtUtc.value
          : this.updatedAtUtc,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Area(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('color: $color, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('isLife: $isLife, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    color,
    sortOrder,
    isLife,
    createdAtUtc,
    updatedAtUtc,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Area &&
          other.id == this.id &&
          other.name == this.name &&
          other.color == this.color &&
          other.sortOrder == this.sortOrder &&
          other.isLife == this.isLife &&
          other.createdAtUtc == this.createdAtUtc &&
          other.updatedAtUtc == this.updatedAtUtc);
}

class AreasCompanion extends UpdateCompanion<Area> {
  final Value<String> id;
  final Value<String> name;
  final Value<int> color;
  final Value<int> sortOrder;
  final Value<bool> isLife;
  final Value<int> createdAtUtc;
  final Value<int> updatedAtUtc;
  final Value<int> rowid;
  const AreasCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.color = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.isLife = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AreasCompanion.insert({
    required String id,
    required String name,
    required int color,
    required int sortOrder,
    this.isLife = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       color = Value(color),
       sortOrder = Value(sortOrder);
  static Insertable<Area> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<int>? color,
    Expression<int>? sortOrder,
    Expression<bool>? isLife,
    Expression<int>? createdAtUtc,
    Expression<int>? updatedAtUtc,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (color != null) 'color': color,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (isLife != null) 'is_life': isLife,
      if (createdAtUtc != null) 'created_at_utc': createdAtUtc,
      if (updatedAtUtc != null) 'updated_at_utc': updatedAtUtc,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AreasCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<int>? color,
    Value<int>? sortOrder,
    Value<bool>? isLife,
    Value<int>? createdAtUtc,
    Value<int>? updatedAtUtc,
    Value<int>? rowid,
  }) {
    return AreasCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      sortOrder: sortOrder ?? this.sortOrder,
      isLife: isLife ?? this.isLife,
      createdAtUtc: createdAtUtc ?? this.createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (color.present) {
      map['color'] = Variable<int>(color.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (isLife.present) {
      map['is_life'] = Variable<bool>(isLife.value);
    }
    if (createdAtUtc.present) {
      map['created_at_utc'] = Variable<int>(createdAtUtc.value);
    }
    if (updatedAtUtc.present) {
      map['updated_at_utc'] = Variable<int>(updatedAtUtc.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AreasCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('color: $color, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('isLife: $isLife, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ProjectsTable extends Projects with TableInfo<$ProjectsTable, Project> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProjectsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _areaIdMeta = const VerificationMeta('areaId');
  @override
  late final GeneratedColumn<String> areaId = GeneratedColumn<String>(
    'area_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES areas (id)',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _archivedAtUtcMeta = const VerificationMeta(
    'archivedAtUtc',
  );
  @override
  late final GeneratedColumn<int> archivedAtUtc = GeneratedColumn<int>(
    'archived_at_utc',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtUtcMeta = const VerificationMeta(
    'createdAtUtc',
  );
  @override
  late final GeneratedColumn<int> createdAtUtc = GeneratedColumn<int>(
    'created_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  static const VerificationMeta _updatedAtUtcMeta = const VerificationMeta(
    'updatedAtUtc',
  );
  @override
  late final GeneratedColumn<int> updatedAtUtc = GeneratedColumn<int>(
    'updated_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    areaId,
    name,
    archivedAtUtc,
    createdAtUtc,
    updatedAtUtc,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'projects';
  @override
  VerificationContext validateIntegrity(
    Insertable<Project> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('area_id')) {
      context.handle(
        _areaIdMeta,
        areaId.isAcceptableOrUnknown(data['area_id']!, _areaIdMeta),
      );
    } else if (isInserting) {
      context.missing(_areaIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('archived_at_utc')) {
      context.handle(
        _archivedAtUtcMeta,
        archivedAtUtc.isAcceptableOrUnknown(
          data['archived_at_utc']!,
          _archivedAtUtcMeta,
        ),
      );
    }
    if (data.containsKey('created_at_utc')) {
      context.handle(
        _createdAtUtcMeta,
        createdAtUtc.isAcceptableOrUnknown(
          data['created_at_utc']!,
          _createdAtUtcMeta,
        ),
      );
    }
    if (data.containsKey('updated_at_utc')) {
      context.handle(
        _updatedAtUtcMeta,
        updatedAtUtc.isAcceptableOrUnknown(
          data['updated_at_utc']!,
          _updatedAtUtcMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Project map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Project(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      areaId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}area_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      archivedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}archived_at_utc'],
      ),
      createdAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_utc'],
      )!,
      updatedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_utc'],
      )!,
    );
  }

  @override
  $ProjectsTable createAlias(String alias) {
    return $ProjectsTable(attachedDatabase, alias);
  }
}

class Project extends DataClass implements Insertable<Project> {
  final String id;
  final String areaId;
  final String name;
  final int? archivedAtUtc;
  final int createdAtUtc;
  final int updatedAtUtc;
  const Project({
    required this.id,
    required this.areaId,
    required this.name,
    this.archivedAtUtc,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['area_id'] = Variable<String>(areaId);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || archivedAtUtc != null) {
      map['archived_at_utc'] = Variable<int>(archivedAtUtc);
    }
    map['created_at_utc'] = Variable<int>(createdAtUtc);
    map['updated_at_utc'] = Variable<int>(updatedAtUtc);
    return map;
  }

  ProjectsCompanion toCompanion(bool nullToAbsent) {
    return ProjectsCompanion(
      id: Value(id),
      areaId: Value(areaId),
      name: Value(name),
      archivedAtUtc: archivedAtUtc == null && nullToAbsent
          ? const Value.absent()
          : Value(archivedAtUtc),
      createdAtUtc: Value(createdAtUtc),
      updatedAtUtc: Value(updatedAtUtc),
    );
  }

  factory Project.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Project(
      id: serializer.fromJson<String>(json['id']),
      areaId: serializer.fromJson<String>(json['areaId']),
      name: serializer.fromJson<String>(json['name']),
      archivedAtUtc: serializer.fromJson<int?>(json['archivedAtUtc']),
      createdAtUtc: serializer.fromJson<int>(json['createdAtUtc']),
      updatedAtUtc: serializer.fromJson<int>(json['updatedAtUtc']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'areaId': serializer.toJson<String>(areaId),
      'name': serializer.toJson<String>(name),
      'archivedAtUtc': serializer.toJson<int?>(archivedAtUtc),
      'createdAtUtc': serializer.toJson<int>(createdAtUtc),
      'updatedAtUtc': serializer.toJson<int>(updatedAtUtc),
    };
  }

  Project copyWith({
    String? id,
    String? areaId,
    String? name,
    Value<int?> archivedAtUtc = const Value.absent(),
    int? createdAtUtc,
    int? updatedAtUtc,
  }) => Project(
    id: id ?? this.id,
    areaId: areaId ?? this.areaId,
    name: name ?? this.name,
    archivedAtUtc: archivedAtUtc.present
        ? archivedAtUtc.value
        : this.archivedAtUtc,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
  Project copyWithCompanion(ProjectsCompanion data) {
    return Project(
      id: data.id.present ? data.id.value : this.id,
      areaId: data.areaId.present ? data.areaId.value : this.areaId,
      name: data.name.present ? data.name.value : this.name,
      archivedAtUtc: data.archivedAtUtc.present
          ? data.archivedAtUtc.value
          : this.archivedAtUtc,
      createdAtUtc: data.createdAtUtc.present
          ? data.createdAtUtc.value
          : this.createdAtUtc,
      updatedAtUtc: data.updatedAtUtc.present
          ? data.updatedAtUtc.value
          : this.updatedAtUtc,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Project(')
          ..write('id: $id, ')
          ..write('areaId: $areaId, ')
          ..write('name: $name, ')
          ..write('archivedAtUtc: $archivedAtUtc, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, areaId, name, archivedAtUtc, createdAtUtc, updatedAtUtc);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Project &&
          other.id == this.id &&
          other.areaId == this.areaId &&
          other.name == this.name &&
          other.archivedAtUtc == this.archivedAtUtc &&
          other.createdAtUtc == this.createdAtUtc &&
          other.updatedAtUtc == this.updatedAtUtc);
}

class ProjectsCompanion extends UpdateCompanion<Project> {
  final Value<String> id;
  final Value<String> areaId;
  final Value<String> name;
  final Value<int?> archivedAtUtc;
  final Value<int> createdAtUtc;
  final Value<int> updatedAtUtc;
  final Value<int> rowid;
  const ProjectsCompanion({
    this.id = const Value.absent(),
    this.areaId = const Value.absent(),
    this.name = const Value.absent(),
    this.archivedAtUtc = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProjectsCompanion.insert({
    required String id,
    required String areaId,
    required String name,
    this.archivedAtUtc = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       areaId = Value(areaId),
       name = Value(name);
  static Insertable<Project> custom({
    Expression<String>? id,
    Expression<String>? areaId,
    Expression<String>? name,
    Expression<int>? archivedAtUtc,
    Expression<int>? createdAtUtc,
    Expression<int>? updatedAtUtc,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (areaId != null) 'area_id': areaId,
      if (name != null) 'name': name,
      if (archivedAtUtc != null) 'archived_at_utc': archivedAtUtc,
      if (createdAtUtc != null) 'created_at_utc': createdAtUtc,
      if (updatedAtUtc != null) 'updated_at_utc': updatedAtUtc,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProjectsCompanion copyWith({
    Value<String>? id,
    Value<String>? areaId,
    Value<String>? name,
    Value<int?>? archivedAtUtc,
    Value<int>? createdAtUtc,
    Value<int>? updatedAtUtc,
    Value<int>? rowid,
  }) {
    return ProjectsCompanion(
      id: id ?? this.id,
      areaId: areaId ?? this.areaId,
      name: name ?? this.name,
      archivedAtUtc: archivedAtUtc ?? this.archivedAtUtc,
      createdAtUtc: createdAtUtc ?? this.createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (areaId.present) {
      map['area_id'] = Variable<String>(areaId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (archivedAtUtc.present) {
      map['archived_at_utc'] = Variable<int>(archivedAtUtc.value);
    }
    if (createdAtUtc.present) {
      map['created_at_utc'] = Variable<int>(createdAtUtc.value);
    }
    if (updatedAtUtc.present) {
      map['updated_at_utc'] = Variable<int>(updatedAtUtc.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProjectsCompanion(')
          ..write('id: $id, ')
          ..write('areaId: $areaId, ')
          ..write('name: $name, ')
          ..write('archivedAtUtc: $archivedAtUtc, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TasksTable extends Tasks with TableInfo<$TasksTable, Task> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TasksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _projectIdMeta = const VerificationMeta(
    'projectId',
  );
  @override
  late final GeneratedColumn<String> projectId = GeneratedColumn<String>(
    'project_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES projects (id)',
    ),
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _priorityMeta = const VerificationMeta(
    'priority',
  );
  @override
  late final GeneratedColumn<String> priority = GeneratedColumn<String>(
    'priority',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _estimatedMinutesMeta = const VerificationMeta(
    'estimatedMinutes',
  );
  @override
  late final GeneratedColumn<int> estimatedMinutes = GeneratedColumn<int>(
    'estimated_minutes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remainingMinutesMeta = const VerificationMeta(
    'remainingMinutes',
  );
  @override
  late final GeneratedColumn<int> remainingMinutes = GeneratedColumn<int>(
    'remaining_minutes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dueAtUtcMeta = const VerificationMeta(
    'dueAtUtc',
  );
  @override
  late final GeneratedColumn<int> dueAtUtc = GeneratedColumn<int>(
    'due_at_utc',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _energyLevelMeta = const VerificationMeta(
    'energyLevel',
  );
  @override
  late final GeneratedColumn<String> energyLevel = GeneratedColumn<String>(
    'energy_level',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _splitModeMeta = const VerificationMeta(
    'splitMode',
  );
  @override
  late final GeneratedColumn<String> splitMode = GeneratedColumn<String>(
    'split_mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _minChunkMinutesMeta = const VerificationMeta(
    'minChunkMinutes',
  );
  @override
  late final GeneratedColumn<int> minChunkMinutes = GeneratedColumn<int>(
    'min_chunk_minutes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _maxChunkMinutesMeta = const VerificationMeta(
    'maxChunkMinutes',
  );
  @override
  late final GeneratedColumn<int> maxChunkMinutes = GeneratedColumn<int>(
    'max_chunk_minutes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _preferredStartMinuteMeta =
      const VerificationMeta('preferredStartMinute');
  @override
  late final GeneratedColumn<int> preferredStartMinute = GeneratedColumn<int>(
    'preferred_start_minute',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _preferredEndMinuteMeta =
      const VerificationMeta('preferredEndMinute');
  @override
  late final GeneratedColumn<int> preferredEndMinute = GeneratedColumn<int>(
    'preferred_end_minute',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtUtcMeta = const VerificationMeta(
    'createdAtUtc',
  );
  @override
  late final GeneratedColumn<int> createdAtUtc = GeneratedColumn<int>(
    'created_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtUtcMeta = const VerificationMeta(
    'updatedAtUtc',
  );
  @override
  late final GeneratedColumn<int> updatedAtUtc = GeneratedColumn<int>(
    'updated_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    projectId,
    title,
    notes,
    priority,
    estimatedMinutes,
    remainingMinutes,
    dueAtUtc,
    energyLevel,
    splitMode,
    minChunkMinutes,
    maxChunkMinutes,
    preferredStartMinute,
    preferredEndMinute,
    status,
    createdAtUtc,
    updatedAtUtc,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tasks';
  @override
  VerificationContext validateIntegrity(
    Insertable<Task> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('project_id')) {
      context.handle(
        _projectIdMeta,
        projectId.isAcceptableOrUnknown(data['project_id']!, _projectIdMeta),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    if (data.containsKey('priority')) {
      context.handle(
        _priorityMeta,
        priority.isAcceptableOrUnknown(data['priority']!, _priorityMeta),
      );
    } else if (isInserting) {
      context.missing(_priorityMeta);
    }
    if (data.containsKey('estimated_minutes')) {
      context.handle(
        _estimatedMinutesMeta,
        estimatedMinutes.isAcceptableOrUnknown(
          data['estimated_minutes']!,
          _estimatedMinutesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_estimatedMinutesMeta);
    }
    if (data.containsKey('remaining_minutes')) {
      context.handle(
        _remainingMinutesMeta,
        remainingMinutes.isAcceptableOrUnknown(
          data['remaining_minutes']!,
          _remainingMinutesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_remainingMinutesMeta);
    }
    if (data.containsKey('due_at_utc')) {
      context.handle(
        _dueAtUtcMeta,
        dueAtUtc.isAcceptableOrUnknown(data['due_at_utc']!, _dueAtUtcMeta),
      );
    }
    if (data.containsKey('energy_level')) {
      context.handle(
        _energyLevelMeta,
        energyLevel.isAcceptableOrUnknown(
          data['energy_level']!,
          _energyLevelMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_energyLevelMeta);
    }
    if (data.containsKey('split_mode')) {
      context.handle(
        _splitModeMeta,
        splitMode.isAcceptableOrUnknown(data['split_mode']!, _splitModeMeta),
      );
    } else if (isInserting) {
      context.missing(_splitModeMeta);
    }
    if (data.containsKey('min_chunk_minutes')) {
      context.handle(
        _minChunkMinutesMeta,
        minChunkMinutes.isAcceptableOrUnknown(
          data['min_chunk_minutes']!,
          _minChunkMinutesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_minChunkMinutesMeta);
    }
    if (data.containsKey('max_chunk_minutes')) {
      context.handle(
        _maxChunkMinutesMeta,
        maxChunkMinutes.isAcceptableOrUnknown(
          data['max_chunk_minutes']!,
          _maxChunkMinutesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_maxChunkMinutesMeta);
    }
    if (data.containsKey('preferred_start_minute')) {
      context.handle(
        _preferredStartMinuteMeta,
        preferredStartMinute.isAcceptableOrUnknown(
          data['preferred_start_minute']!,
          _preferredStartMinuteMeta,
        ),
      );
    }
    if (data.containsKey('preferred_end_minute')) {
      context.handle(
        _preferredEndMinuteMeta,
        preferredEndMinute.isAcceptableOrUnknown(
          data['preferred_end_minute']!,
          _preferredEndMinuteMeta,
        ),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('created_at_utc')) {
      context.handle(
        _createdAtUtcMeta,
        createdAtUtc.isAcceptableOrUnknown(
          data['created_at_utc']!,
          _createdAtUtcMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_createdAtUtcMeta);
    }
    if (data.containsKey('updated_at_utc')) {
      context.handle(
        _updatedAtUtcMeta,
        updatedAtUtc.isAcceptableOrUnknown(
          data['updated_at_utc']!,
          _updatedAtUtcMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtUtcMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Task map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Task(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      projectId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}project_id'],
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      )!,
      priority: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}priority'],
      )!,
      estimatedMinutes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}estimated_minutes'],
      )!,
      remainingMinutes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}remaining_minutes'],
      )!,
      dueAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}due_at_utc'],
      ),
      energyLevel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}energy_level'],
      )!,
      splitMode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}split_mode'],
      )!,
      minChunkMinutes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}min_chunk_minutes'],
      )!,
      maxChunkMinutes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}max_chunk_minutes'],
      )!,
      preferredStartMinute: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}preferred_start_minute'],
      ),
      preferredEndMinute: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}preferred_end_minute'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      createdAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_utc'],
      )!,
      updatedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_utc'],
      )!,
    );
  }

  @override
  $TasksTable createAlias(String alias) {
    return $TasksTable(attachedDatabase, alias);
  }
}

class Task extends DataClass implements Insertable<Task> {
  final String id;
  final String? projectId;
  final String title;
  final String notes;
  final String priority;
  final int estimatedMinutes;
  final int remainingMinutes;
  final int? dueAtUtc;
  final String energyLevel;
  final String splitMode;
  final int minChunkMinutes;
  final int maxChunkMinutes;

  /// Optional preferred local-time window, expressed as minutes from local
  /// midnight on the task's day. Null means the task has no preference.
  final int? preferredStartMinute;
  final int? preferredEndMinute;
  final String status;
  final int createdAtUtc;
  final int updatedAtUtc;
  const Task({
    required this.id,
    this.projectId,
    required this.title,
    required this.notes,
    required this.priority,
    required this.estimatedMinutes,
    required this.remainingMinutes,
    this.dueAtUtc,
    required this.energyLevel,
    required this.splitMode,
    required this.minChunkMinutes,
    required this.maxChunkMinutes,
    this.preferredStartMinute,
    this.preferredEndMinute,
    required this.status,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || projectId != null) {
      map['project_id'] = Variable<String>(projectId);
    }
    map['title'] = Variable<String>(title);
    map['notes'] = Variable<String>(notes);
    map['priority'] = Variable<String>(priority);
    map['estimated_minutes'] = Variable<int>(estimatedMinutes);
    map['remaining_minutes'] = Variable<int>(remainingMinutes);
    if (!nullToAbsent || dueAtUtc != null) {
      map['due_at_utc'] = Variable<int>(dueAtUtc);
    }
    map['energy_level'] = Variable<String>(energyLevel);
    map['split_mode'] = Variable<String>(splitMode);
    map['min_chunk_minutes'] = Variable<int>(minChunkMinutes);
    map['max_chunk_minutes'] = Variable<int>(maxChunkMinutes);
    if (!nullToAbsent || preferredStartMinute != null) {
      map['preferred_start_minute'] = Variable<int>(preferredStartMinute);
    }
    if (!nullToAbsent || preferredEndMinute != null) {
      map['preferred_end_minute'] = Variable<int>(preferredEndMinute);
    }
    map['status'] = Variable<String>(status);
    map['created_at_utc'] = Variable<int>(createdAtUtc);
    map['updated_at_utc'] = Variable<int>(updatedAtUtc);
    return map;
  }

  TasksCompanion toCompanion(bool nullToAbsent) {
    return TasksCompanion(
      id: Value(id),
      projectId: projectId == null && nullToAbsent
          ? const Value.absent()
          : Value(projectId),
      title: Value(title),
      notes: Value(notes),
      priority: Value(priority),
      estimatedMinutes: Value(estimatedMinutes),
      remainingMinutes: Value(remainingMinutes),
      dueAtUtc: dueAtUtc == null && nullToAbsent
          ? const Value.absent()
          : Value(dueAtUtc),
      energyLevel: Value(energyLevel),
      splitMode: Value(splitMode),
      minChunkMinutes: Value(minChunkMinutes),
      maxChunkMinutes: Value(maxChunkMinutes),
      preferredStartMinute: preferredStartMinute == null && nullToAbsent
          ? const Value.absent()
          : Value(preferredStartMinute),
      preferredEndMinute: preferredEndMinute == null && nullToAbsent
          ? const Value.absent()
          : Value(preferredEndMinute),
      status: Value(status),
      createdAtUtc: Value(createdAtUtc),
      updatedAtUtc: Value(updatedAtUtc),
    );
  }

  factory Task.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Task(
      id: serializer.fromJson<String>(json['id']),
      projectId: serializer.fromJson<String?>(json['projectId']),
      title: serializer.fromJson<String>(json['title']),
      notes: serializer.fromJson<String>(json['notes']),
      priority: serializer.fromJson<String>(json['priority']),
      estimatedMinutes: serializer.fromJson<int>(json['estimatedMinutes']),
      remainingMinutes: serializer.fromJson<int>(json['remainingMinutes']),
      dueAtUtc: serializer.fromJson<int?>(json['dueAtUtc']),
      energyLevel: serializer.fromJson<String>(json['energyLevel']),
      splitMode: serializer.fromJson<String>(json['splitMode']),
      minChunkMinutes: serializer.fromJson<int>(json['minChunkMinutes']),
      maxChunkMinutes: serializer.fromJson<int>(json['maxChunkMinutes']),
      preferredStartMinute: serializer.fromJson<int?>(
        json['preferredStartMinute'],
      ),
      preferredEndMinute: serializer.fromJson<int?>(json['preferredEndMinute']),
      status: serializer.fromJson<String>(json['status']),
      createdAtUtc: serializer.fromJson<int>(json['createdAtUtc']),
      updatedAtUtc: serializer.fromJson<int>(json['updatedAtUtc']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'projectId': serializer.toJson<String?>(projectId),
      'title': serializer.toJson<String>(title),
      'notes': serializer.toJson<String>(notes),
      'priority': serializer.toJson<String>(priority),
      'estimatedMinutes': serializer.toJson<int>(estimatedMinutes),
      'remainingMinutes': serializer.toJson<int>(remainingMinutes),
      'dueAtUtc': serializer.toJson<int?>(dueAtUtc),
      'energyLevel': serializer.toJson<String>(energyLevel),
      'splitMode': serializer.toJson<String>(splitMode),
      'minChunkMinutes': serializer.toJson<int>(minChunkMinutes),
      'maxChunkMinutes': serializer.toJson<int>(maxChunkMinutes),
      'preferredStartMinute': serializer.toJson<int?>(preferredStartMinute),
      'preferredEndMinute': serializer.toJson<int?>(preferredEndMinute),
      'status': serializer.toJson<String>(status),
      'createdAtUtc': serializer.toJson<int>(createdAtUtc),
      'updatedAtUtc': serializer.toJson<int>(updatedAtUtc),
    };
  }

  Task copyWith({
    String? id,
    Value<String?> projectId = const Value.absent(),
    String? title,
    String? notes,
    String? priority,
    int? estimatedMinutes,
    int? remainingMinutes,
    Value<int?> dueAtUtc = const Value.absent(),
    String? energyLevel,
    String? splitMode,
    int? minChunkMinutes,
    int? maxChunkMinutes,
    Value<int?> preferredStartMinute = const Value.absent(),
    Value<int?> preferredEndMinute = const Value.absent(),
    String? status,
    int? createdAtUtc,
    int? updatedAtUtc,
  }) => Task(
    id: id ?? this.id,
    projectId: projectId.present ? projectId.value : this.projectId,
    title: title ?? this.title,
    notes: notes ?? this.notes,
    priority: priority ?? this.priority,
    estimatedMinutes: estimatedMinutes ?? this.estimatedMinutes,
    remainingMinutes: remainingMinutes ?? this.remainingMinutes,
    dueAtUtc: dueAtUtc.present ? dueAtUtc.value : this.dueAtUtc,
    energyLevel: energyLevel ?? this.energyLevel,
    splitMode: splitMode ?? this.splitMode,
    minChunkMinutes: minChunkMinutes ?? this.minChunkMinutes,
    maxChunkMinutes: maxChunkMinutes ?? this.maxChunkMinutes,
    preferredStartMinute: preferredStartMinute.present
        ? preferredStartMinute.value
        : this.preferredStartMinute,
    preferredEndMinute: preferredEndMinute.present
        ? preferredEndMinute.value
        : this.preferredEndMinute,
    status: status ?? this.status,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
  Task copyWithCompanion(TasksCompanion data) {
    return Task(
      id: data.id.present ? data.id.value : this.id,
      projectId: data.projectId.present ? data.projectId.value : this.projectId,
      title: data.title.present ? data.title.value : this.title,
      notes: data.notes.present ? data.notes.value : this.notes,
      priority: data.priority.present ? data.priority.value : this.priority,
      estimatedMinutes: data.estimatedMinutes.present
          ? data.estimatedMinutes.value
          : this.estimatedMinutes,
      remainingMinutes: data.remainingMinutes.present
          ? data.remainingMinutes.value
          : this.remainingMinutes,
      dueAtUtc: data.dueAtUtc.present ? data.dueAtUtc.value : this.dueAtUtc,
      energyLevel: data.energyLevel.present
          ? data.energyLevel.value
          : this.energyLevel,
      splitMode: data.splitMode.present ? data.splitMode.value : this.splitMode,
      minChunkMinutes: data.minChunkMinutes.present
          ? data.minChunkMinutes.value
          : this.minChunkMinutes,
      maxChunkMinutes: data.maxChunkMinutes.present
          ? data.maxChunkMinutes.value
          : this.maxChunkMinutes,
      preferredStartMinute: data.preferredStartMinute.present
          ? data.preferredStartMinute.value
          : this.preferredStartMinute,
      preferredEndMinute: data.preferredEndMinute.present
          ? data.preferredEndMinute.value
          : this.preferredEndMinute,
      status: data.status.present ? data.status.value : this.status,
      createdAtUtc: data.createdAtUtc.present
          ? data.createdAtUtc.value
          : this.createdAtUtc,
      updatedAtUtc: data.updatedAtUtc.present
          ? data.updatedAtUtc.value
          : this.updatedAtUtc,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Task(')
          ..write('id: $id, ')
          ..write('projectId: $projectId, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('priority: $priority, ')
          ..write('estimatedMinutes: $estimatedMinutes, ')
          ..write('remainingMinutes: $remainingMinutes, ')
          ..write('dueAtUtc: $dueAtUtc, ')
          ..write('energyLevel: $energyLevel, ')
          ..write('splitMode: $splitMode, ')
          ..write('minChunkMinutes: $minChunkMinutes, ')
          ..write('maxChunkMinutes: $maxChunkMinutes, ')
          ..write('preferredStartMinute: $preferredStartMinute, ')
          ..write('preferredEndMinute: $preferredEndMinute, ')
          ..write('status: $status, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    projectId,
    title,
    notes,
    priority,
    estimatedMinutes,
    remainingMinutes,
    dueAtUtc,
    energyLevel,
    splitMode,
    minChunkMinutes,
    maxChunkMinutes,
    preferredStartMinute,
    preferredEndMinute,
    status,
    createdAtUtc,
    updatedAtUtc,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Task &&
          other.id == this.id &&
          other.projectId == this.projectId &&
          other.title == this.title &&
          other.notes == this.notes &&
          other.priority == this.priority &&
          other.estimatedMinutes == this.estimatedMinutes &&
          other.remainingMinutes == this.remainingMinutes &&
          other.dueAtUtc == this.dueAtUtc &&
          other.energyLevel == this.energyLevel &&
          other.splitMode == this.splitMode &&
          other.minChunkMinutes == this.minChunkMinutes &&
          other.maxChunkMinutes == this.maxChunkMinutes &&
          other.preferredStartMinute == this.preferredStartMinute &&
          other.preferredEndMinute == this.preferredEndMinute &&
          other.status == this.status &&
          other.createdAtUtc == this.createdAtUtc &&
          other.updatedAtUtc == this.updatedAtUtc);
}

class TasksCompanion extends UpdateCompanion<Task> {
  final Value<String> id;
  final Value<String?> projectId;
  final Value<String> title;
  final Value<String> notes;
  final Value<String> priority;
  final Value<int> estimatedMinutes;
  final Value<int> remainingMinutes;
  final Value<int?> dueAtUtc;
  final Value<String> energyLevel;
  final Value<String> splitMode;
  final Value<int> minChunkMinutes;
  final Value<int> maxChunkMinutes;
  final Value<int?> preferredStartMinute;
  final Value<int?> preferredEndMinute;
  final Value<String> status;
  final Value<int> createdAtUtc;
  final Value<int> updatedAtUtc;
  final Value<int> rowid;
  const TasksCompanion({
    this.id = const Value.absent(),
    this.projectId = const Value.absent(),
    this.title = const Value.absent(),
    this.notes = const Value.absent(),
    this.priority = const Value.absent(),
    this.estimatedMinutes = const Value.absent(),
    this.remainingMinutes = const Value.absent(),
    this.dueAtUtc = const Value.absent(),
    this.energyLevel = const Value.absent(),
    this.splitMode = const Value.absent(),
    this.minChunkMinutes = const Value.absent(),
    this.maxChunkMinutes = const Value.absent(),
    this.preferredStartMinute = const Value.absent(),
    this.preferredEndMinute = const Value.absent(),
    this.status = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TasksCompanion.insert({
    required String id,
    this.projectId = const Value.absent(),
    required String title,
    this.notes = const Value.absent(),
    required String priority,
    required int estimatedMinutes,
    required int remainingMinutes,
    this.dueAtUtc = const Value.absent(),
    required String energyLevel,
    required String splitMode,
    required int minChunkMinutes,
    required int maxChunkMinutes,
    this.preferredStartMinute = const Value.absent(),
    this.preferredEndMinute = const Value.absent(),
    required String status,
    required int createdAtUtc,
    required int updatedAtUtc,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       priority = Value(priority),
       estimatedMinutes = Value(estimatedMinutes),
       remainingMinutes = Value(remainingMinutes),
       energyLevel = Value(energyLevel),
       splitMode = Value(splitMode),
       minChunkMinutes = Value(minChunkMinutes),
       maxChunkMinutes = Value(maxChunkMinutes),
       status = Value(status),
       createdAtUtc = Value(createdAtUtc),
       updatedAtUtc = Value(updatedAtUtc);
  static Insertable<Task> custom({
    Expression<String>? id,
    Expression<String>? projectId,
    Expression<String>? title,
    Expression<String>? notes,
    Expression<String>? priority,
    Expression<int>? estimatedMinutes,
    Expression<int>? remainingMinutes,
    Expression<int>? dueAtUtc,
    Expression<String>? energyLevel,
    Expression<String>? splitMode,
    Expression<int>? minChunkMinutes,
    Expression<int>? maxChunkMinutes,
    Expression<int>? preferredStartMinute,
    Expression<int>? preferredEndMinute,
    Expression<String>? status,
    Expression<int>? createdAtUtc,
    Expression<int>? updatedAtUtc,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (projectId != null) 'project_id': projectId,
      if (title != null) 'title': title,
      if (notes != null) 'notes': notes,
      if (priority != null) 'priority': priority,
      if (estimatedMinutes != null) 'estimated_minutes': estimatedMinutes,
      if (remainingMinutes != null) 'remaining_minutes': remainingMinutes,
      if (dueAtUtc != null) 'due_at_utc': dueAtUtc,
      if (energyLevel != null) 'energy_level': energyLevel,
      if (splitMode != null) 'split_mode': splitMode,
      if (minChunkMinutes != null) 'min_chunk_minutes': minChunkMinutes,
      if (maxChunkMinutes != null) 'max_chunk_minutes': maxChunkMinutes,
      if (preferredStartMinute != null)
        'preferred_start_minute': preferredStartMinute,
      if (preferredEndMinute != null)
        'preferred_end_minute': preferredEndMinute,
      if (status != null) 'status': status,
      if (createdAtUtc != null) 'created_at_utc': createdAtUtc,
      if (updatedAtUtc != null) 'updated_at_utc': updatedAtUtc,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TasksCompanion copyWith({
    Value<String>? id,
    Value<String?>? projectId,
    Value<String>? title,
    Value<String>? notes,
    Value<String>? priority,
    Value<int>? estimatedMinutes,
    Value<int>? remainingMinutes,
    Value<int?>? dueAtUtc,
    Value<String>? energyLevel,
    Value<String>? splitMode,
    Value<int>? minChunkMinutes,
    Value<int>? maxChunkMinutes,
    Value<int?>? preferredStartMinute,
    Value<int?>? preferredEndMinute,
    Value<String>? status,
    Value<int>? createdAtUtc,
    Value<int>? updatedAtUtc,
    Value<int>? rowid,
  }) {
    return TasksCompanion(
      id: id ?? this.id,
      projectId: projectId ?? this.projectId,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      priority: priority ?? this.priority,
      estimatedMinutes: estimatedMinutes ?? this.estimatedMinutes,
      remainingMinutes: remainingMinutes ?? this.remainingMinutes,
      dueAtUtc: dueAtUtc ?? this.dueAtUtc,
      energyLevel: energyLevel ?? this.energyLevel,
      splitMode: splitMode ?? this.splitMode,
      minChunkMinutes: minChunkMinutes ?? this.minChunkMinutes,
      maxChunkMinutes: maxChunkMinutes ?? this.maxChunkMinutes,
      preferredStartMinute: preferredStartMinute ?? this.preferredStartMinute,
      preferredEndMinute: preferredEndMinute ?? this.preferredEndMinute,
      status: status ?? this.status,
      createdAtUtc: createdAtUtc ?? this.createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (projectId.present) {
      map['project_id'] = Variable<String>(projectId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (priority.present) {
      map['priority'] = Variable<String>(priority.value);
    }
    if (estimatedMinutes.present) {
      map['estimated_minutes'] = Variable<int>(estimatedMinutes.value);
    }
    if (remainingMinutes.present) {
      map['remaining_minutes'] = Variable<int>(remainingMinutes.value);
    }
    if (dueAtUtc.present) {
      map['due_at_utc'] = Variable<int>(dueAtUtc.value);
    }
    if (energyLevel.present) {
      map['energy_level'] = Variable<String>(energyLevel.value);
    }
    if (splitMode.present) {
      map['split_mode'] = Variable<String>(splitMode.value);
    }
    if (minChunkMinutes.present) {
      map['min_chunk_minutes'] = Variable<int>(minChunkMinutes.value);
    }
    if (maxChunkMinutes.present) {
      map['max_chunk_minutes'] = Variable<int>(maxChunkMinutes.value);
    }
    if (preferredStartMinute.present) {
      map['preferred_start_minute'] = Variable<int>(preferredStartMinute.value);
    }
    if (preferredEndMinute.present) {
      map['preferred_end_minute'] = Variable<int>(preferredEndMinute.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (createdAtUtc.present) {
      map['created_at_utc'] = Variable<int>(createdAtUtc.value);
    }
    if (updatedAtUtc.present) {
      map['updated_at_utc'] = Variable<int>(updatedAtUtc.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TasksCompanion(')
          ..write('id: $id, ')
          ..write('projectId: $projectId, ')
          ..write('title: $title, ')
          ..write('notes: $notes, ')
          ..write('priority: $priority, ')
          ..write('estimatedMinutes: $estimatedMinutes, ')
          ..write('remainingMinutes: $remainingMinutes, ')
          ..write('dueAtUtc: $dueAtUtc, ')
          ..write('energyLevel: $energyLevel, ')
          ..write('splitMode: $splitMode, ')
          ..write('minChunkMinutes: $minChunkMinutes, ')
          ..write('maxChunkMinutes: $maxChunkMinutes, ')
          ..write('preferredStartMinute: $preferredStartMinute, ')
          ..write('preferredEndMinute: $preferredEndMinute, ')
          ..write('status: $status, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TagsTable extends Tags with TableInfo<$TagsTable, Tag> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TagsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtUtcMeta = const VerificationMeta(
    'createdAtUtc',
  );
  @override
  late final GeneratedColumn<int> createdAtUtc = GeneratedColumn<int>(
    'created_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  static const VerificationMeta _updatedAtUtcMeta = const VerificationMeta(
    'updatedAtUtc',
  );
  @override
  late final GeneratedColumn<int> updatedAtUtc = GeneratedColumn<int>(
    'updated_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  @override
  List<GeneratedColumn> get $columns => [id, name, createdAtUtc, updatedAtUtc];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tags';
  @override
  VerificationContext validateIntegrity(
    Insertable<Tag> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('created_at_utc')) {
      context.handle(
        _createdAtUtcMeta,
        createdAtUtc.isAcceptableOrUnknown(
          data['created_at_utc']!,
          _createdAtUtcMeta,
        ),
      );
    }
    if (data.containsKey('updated_at_utc')) {
      context.handle(
        _updatedAtUtcMeta,
        updatedAtUtc.isAcceptableOrUnknown(
          data['updated_at_utc']!,
          _updatedAtUtcMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Tag map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Tag(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      createdAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_utc'],
      )!,
      updatedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_utc'],
      )!,
    );
  }

  @override
  $TagsTable createAlias(String alias) {
    return $TagsTable(attachedDatabase, alias);
  }
}

class Tag extends DataClass implements Insertable<Tag> {
  final String id;
  final String name;
  final int createdAtUtc;
  final int updatedAtUtc;
  const Tag({
    required this.id,
    required this.name,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['created_at_utc'] = Variable<int>(createdAtUtc);
    map['updated_at_utc'] = Variable<int>(updatedAtUtc);
    return map;
  }

  TagsCompanion toCompanion(bool nullToAbsent) {
    return TagsCompanion(
      id: Value(id),
      name: Value(name),
      createdAtUtc: Value(createdAtUtc),
      updatedAtUtc: Value(updatedAtUtc),
    );
  }

  factory Tag.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Tag(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      createdAtUtc: serializer.fromJson<int>(json['createdAtUtc']),
      updatedAtUtc: serializer.fromJson<int>(json['updatedAtUtc']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'createdAtUtc': serializer.toJson<int>(createdAtUtc),
      'updatedAtUtc': serializer.toJson<int>(updatedAtUtc),
    };
  }

  Tag copyWith({
    String? id,
    String? name,
    int? createdAtUtc,
    int? updatedAtUtc,
  }) => Tag(
    id: id ?? this.id,
    name: name ?? this.name,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
  Tag copyWithCompanion(TagsCompanion data) {
    return Tag(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      createdAtUtc: data.createdAtUtc.present
          ? data.createdAtUtc.value
          : this.createdAtUtc,
      updatedAtUtc: data.updatedAtUtc.present
          ? data.updatedAtUtc.value
          : this.updatedAtUtc,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Tag(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, createdAtUtc, updatedAtUtc);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Tag &&
          other.id == this.id &&
          other.name == this.name &&
          other.createdAtUtc == this.createdAtUtc &&
          other.updatedAtUtc == this.updatedAtUtc);
}

class TagsCompanion extends UpdateCompanion<Tag> {
  final Value<String> id;
  final Value<String> name;
  final Value<int> createdAtUtc;
  final Value<int> updatedAtUtc;
  final Value<int> rowid;
  const TagsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TagsCompanion.insert({
    required String id,
    required String name,
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name);
  static Insertable<Tag> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<int>? createdAtUtc,
    Expression<int>? updatedAtUtc,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (createdAtUtc != null) 'created_at_utc': createdAtUtc,
      if (updatedAtUtc != null) 'updated_at_utc': updatedAtUtc,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TagsCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<int>? createdAtUtc,
    Value<int>? updatedAtUtc,
    Value<int>? rowid,
  }) {
    return TagsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAtUtc: createdAtUtc ?? this.createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (createdAtUtc.present) {
      map['created_at_utc'] = Variable<int>(createdAtUtc.value);
    }
    if (updatedAtUtc.present) {
      map['updated_at_utc'] = Variable<int>(updatedAtUtc.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TagsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TaskTagsTable extends TaskTags with TableInfo<$TaskTagsTable, TaskTag> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TaskTagsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _taskIdMeta = const VerificationMeta('taskId');
  @override
  late final GeneratedColumn<String> taskId = GeneratedColumn<String>(
    'task_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES tasks (id)',
    ),
  );
  static const VerificationMeta _tagIdMeta = const VerificationMeta('tagId');
  @override
  late final GeneratedColumn<String> tagId = GeneratedColumn<String>(
    'tag_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES tags (id)',
    ),
  );
  static const VerificationMeta _createdAtUtcMeta = const VerificationMeta(
    'createdAtUtc',
  );
  @override
  late final GeneratedColumn<int> createdAtUtc = GeneratedColumn<int>(
    'created_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  @override
  List<GeneratedColumn> get $columns => [taskId, tagId, createdAtUtc];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'task_tags';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskTag> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('task_id')) {
      context.handle(
        _taskIdMeta,
        taskId.isAcceptableOrUnknown(data['task_id']!, _taskIdMeta),
      );
    } else if (isInserting) {
      context.missing(_taskIdMeta);
    }
    if (data.containsKey('tag_id')) {
      context.handle(
        _tagIdMeta,
        tagId.isAcceptableOrUnknown(data['tag_id']!, _tagIdMeta),
      );
    } else if (isInserting) {
      context.missing(_tagIdMeta);
    }
    if (data.containsKey('created_at_utc')) {
      context.handle(
        _createdAtUtcMeta,
        createdAtUtc.isAcceptableOrUnknown(
          data['created_at_utc']!,
          _createdAtUtcMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {taskId, tagId};
  @override
  TaskTag map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskTag(
      taskId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}task_id'],
      )!,
      tagId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tag_id'],
      )!,
      createdAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_utc'],
      )!,
    );
  }

  @override
  $TaskTagsTable createAlias(String alias) {
    return $TaskTagsTable(attachedDatabase, alias);
  }
}

class TaskTag extends DataClass implements Insertable<TaskTag> {
  final String taskId;
  final String tagId;
  final int createdAtUtc;
  const TaskTag({
    required this.taskId,
    required this.tagId,
    required this.createdAtUtc,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['task_id'] = Variable<String>(taskId);
    map['tag_id'] = Variable<String>(tagId);
    map['created_at_utc'] = Variable<int>(createdAtUtc);
    return map;
  }

  TaskTagsCompanion toCompanion(bool nullToAbsent) {
    return TaskTagsCompanion(
      taskId: Value(taskId),
      tagId: Value(tagId),
      createdAtUtc: Value(createdAtUtc),
    );
  }

  factory TaskTag.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskTag(
      taskId: serializer.fromJson<String>(json['taskId']),
      tagId: serializer.fromJson<String>(json['tagId']),
      createdAtUtc: serializer.fromJson<int>(json['createdAtUtc']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'taskId': serializer.toJson<String>(taskId),
      'tagId': serializer.toJson<String>(tagId),
      'createdAtUtc': serializer.toJson<int>(createdAtUtc),
    };
  }

  TaskTag copyWith({String? taskId, String? tagId, int? createdAtUtc}) =>
      TaskTag(
        taskId: taskId ?? this.taskId,
        tagId: tagId ?? this.tagId,
        createdAtUtc: createdAtUtc ?? this.createdAtUtc,
      );
  TaskTag copyWithCompanion(TaskTagsCompanion data) {
    return TaskTag(
      taskId: data.taskId.present ? data.taskId.value : this.taskId,
      tagId: data.tagId.present ? data.tagId.value : this.tagId,
      createdAtUtc: data.createdAtUtc.present
          ? data.createdAtUtc.value
          : this.createdAtUtc,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskTag(')
          ..write('taskId: $taskId, ')
          ..write('tagId: $tagId, ')
          ..write('createdAtUtc: $createdAtUtc')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(taskId, tagId, createdAtUtc);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskTag &&
          other.taskId == this.taskId &&
          other.tagId == this.tagId &&
          other.createdAtUtc == this.createdAtUtc);
}

class TaskTagsCompanion extends UpdateCompanion<TaskTag> {
  final Value<String> taskId;
  final Value<String> tagId;
  final Value<int> createdAtUtc;
  final Value<int> rowid;
  const TaskTagsCompanion({
    this.taskId = const Value.absent(),
    this.tagId = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TaskTagsCompanion.insert({
    required String taskId,
    required String tagId,
    this.createdAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : taskId = Value(taskId),
       tagId = Value(tagId);
  static Insertable<TaskTag> custom({
    Expression<String>? taskId,
    Expression<String>? tagId,
    Expression<int>? createdAtUtc,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (taskId != null) 'task_id': taskId,
      if (tagId != null) 'tag_id': tagId,
      if (createdAtUtc != null) 'created_at_utc': createdAtUtc,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TaskTagsCompanion copyWith({
    Value<String>? taskId,
    Value<String>? tagId,
    Value<int>? createdAtUtc,
    Value<int>? rowid,
  }) {
    return TaskTagsCompanion(
      taskId: taskId ?? this.taskId,
      tagId: tagId ?? this.tagId,
      createdAtUtc: createdAtUtc ?? this.createdAtUtc,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (taskId.present) {
      map['task_id'] = Variable<String>(taskId.value);
    }
    if (tagId.present) {
      map['tag_id'] = Variable<String>(tagId.value);
    }
    if (createdAtUtc.present) {
      map['created_at_utc'] = Variable<int>(createdAtUtc.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TaskTagsCompanion(')
          ..write('taskId: $taskId, ')
          ..write('tagId: $tagId, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RecurrenceRulesTable extends RecurrenceRules
    with TableInfo<$RecurrenceRulesTable, RecurrenceRule> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecurrenceRulesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _weekdaysMaskMeta = const VerificationMeta(
    'weekdaysMask',
  );
  @override
  late final GeneratedColumn<int> weekdaysMask = GeneratedColumn<int>(
    'weekdays_mask',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _localStartMinuteMeta = const VerificationMeta(
    'localStartMinute',
  );
  @override
  late final GeneratedColumn<int> localStartMinute = GeneratedColumn<int>(
    'local_start_minute',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _durationMinutesMeta = const VerificationMeta(
    'durationMinutes',
  );
  @override
  late final GeneratedColumn<int> durationMinutes = GeneratedColumn<int>(
    'duration_minutes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _validFromLocalDateMeta =
      const VerificationMeta('validFromLocalDate');
  @override
  late final GeneratedColumn<String> validFromLocalDate =
      GeneratedColumn<String>(
        'valid_from_local_date',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _validUntilLocalDateMeta =
      const VerificationMeta('validUntilLocalDate');
  @override
  late final GeneratedColumn<String> validUntilLocalDate =
      GeneratedColumn<String>(
        'valid_until_local_date',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _timeZoneIdMeta = const VerificationMeta(
    'timeZoneId',
  );
  @override
  late final GeneratedColumn<String> timeZoneId = GeneratedColumn<String>(
    'time_zone_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtUtcMeta = const VerificationMeta(
    'createdAtUtc',
  );
  @override
  late final GeneratedColumn<int> createdAtUtc = GeneratedColumn<int>(
    'created_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  static const VerificationMeta _updatedAtUtcMeta = const VerificationMeta(
    'updatedAtUtc',
  );
  @override
  late final GeneratedColumn<int> updatedAtUtc = GeneratedColumn<int>(
    'updated_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    weekdaysMask,
    localStartMinute,
    durationMinutes,
    validFromLocalDate,
    validUntilLocalDate,
    timeZoneId,
    createdAtUtc,
    updatedAtUtc,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'recurrence_rules';
  @override
  VerificationContext validateIntegrity(
    Insertable<RecurrenceRule> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('weekdays_mask')) {
      context.handle(
        _weekdaysMaskMeta,
        weekdaysMask.isAcceptableOrUnknown(
          data['weekdays_mask']!,
          _weekdaysMaskMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_weekdaysMaskMeta);
    }
    if (data.containsKey('local_start_minute')) {
      context.handle(
        _localStartMinuteMeta,
        localStartMinute.isAcceptableOrUnknown(
          data['local_start_minute']!,
          _localStartMinuteMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_localStartMinuteMeta);
    }
    if (data.containsKey('duration_minutes')) {
      context.handle(
        _durationMinutesMeta,
        durationMinutes.isAcceptableOrUnknown(
          data['duration_minutes']!,
          _durationMinutesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_durationMinutesMeta);
    }
    if (data.containsKey('valid_from_local_date')) {
      context.handle(
        _validFromLocalDateMeta,
        validFromLocalDate.isAcceptableOrUnknown(
          data['valid_from_local_date']!,
          _validFromLocalDateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_validFromLocalDateMeta);
    }
    if (data.containsKey('valid_until_local_date')) {
      context.handle(
        _validUntilLocalDateMeta,
        validUntilLocalDate.isAcceptableOrUnknown(
          data['valid_until_local_date']!,
          _validUntilLocalDateMeta,
        ),
      );
    }
    if (data.containsKey('time_zone_id')) {
      context.handle(
        _timeZoneIdMeta,
        timeZoneId.isAcceptableOrUnknown(
          data['time_zone_id']!,
          _timeZoneIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_timeZoneIdMeta);
    }
    if (data.containsKey('created_at_utc')) {
      context.handle(
        _createdAtUtcMeta,
        createdAtUtc.isAcceptableOrUnknown(
          data['created_at_utc']!,
          _createdAtUtcMeta,
        ),
      );
    }
    if (data.containsKey('updated_at_utc')) {
      context.handle(
        _updatedAtUtcMeta,
        updatedAtUtc.isAcceptableOrUnknown(
          data['updated_at_utc']!,
          _updatedAtUtcMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RecurrenceRule map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RecurrenceRule(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      weekdaysMask: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}weekdays_mask'],
      )!,
      localStartMinute: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}local_start_minute'],
      )!,
      durationMinutes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_minutes'],
      )!,
      validFromLocalDate: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}valid_from_local_date'],
      )!,
      validUntilLocalDate: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}valid_until_local_date'],
      ),
      timeZoneId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}time_zone_id'],
      )!,
      createdAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_utc'],
      )!,
      updatedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_utc'],
      )!,
    );
  }

  @override
  $RecurrenceRulesTable createAlias(String alias) {
    return $RecurrenceRulesTable(attachedDatabase, alias);
  }
}

class RecurrenceRule extends DataClass implements Insertable<RecurrenceRule> {
  final String id;
  final int weekdaysMask;
  final int localStartMinute;
  final int durationMinutes;
  final String validFromLocalDate;
  final String? validUntilLocalDate;
  final String timeZoneId;
  final int createdAtUtc;
  final int updatedAtUtc;
  const RecurrenceRule({
    required this.id,
    required this.weekdaysMask,
    required this.localStartMinute,
    required this.durationMinutes,
    required this.validFromLocalDate,
    this.validUntilLocalDate,
    required this.timeZoneId,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['weekdays_mask'] = Variable<int>(weekdaysMask);
    map['local_start_minute'] = Variable<int>(localStartMinute);
    map['duration_minutes'] = Variable<int>(durationMinutes);
    map['valid_from_local_date'] = Variable<String>(validFromLocalDate);
    if (!nullToAbsent || validUntilLocalDate != null) {
      map['valid_until_local_date'] = Variable<String>(validUntilLocalDate);
    }
    map['time_zone_id'] = Variable<String>(timeZoneId);
    map['created_at_utc'] = Variable<int>(createdAtUtc);
    map['updated_at_utc'] = Variable<int>(updatedAtUtc);
    return map;
  }

  RecurrenceRulesCompanion toCompanion(bool nullToAbsent) {
    return RecurrenceRulesCompanion(
      id: Value(id),
      weekdaysMask: Value(weekdaysMask),
      localStartMinute: Value(localStartMinute),
      durationMinutes: Value(durationMinutes),
      validFromLocalDate: Value(validFromLocalDate),
      validUntilLocalDate: validUntilLocalDate == null && nullToAbsent
          ? const Value.absent()
          : Value(validUntilLocalDate),
      timeZoneId: Value(timeZoneId),
      createdAtUtc: Value(createdAtUtc),
      updatedAtUtc: Value(updatedAtUtc),
    );
  }

  factory RecurrenceRule.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RecurrenceRule(
      id: serializer.fromJson<String>(json['id']),
      weekdaysMask: serializer.fromJson<int>(json['weekdaysMask']),
      localStartMinute: serializer.fromJson<int>(json['localStartMinute']),
      durationMinutes: serializer.fromJson<int>(json['durationMinutes']),
      validFromLocalDate: serializer.fromJson<String>(
        json['validFromLocalDate'],
      ),
      validUntilLocalDate: serializer.fromJson<String?>(
        json['validUntilLocalDate'],
      ),
      timeZoneId: serializer.fromJson<String>(json['timeZoneId']),
      createdAtUtc: serializer.fromJson<int>(json['createdAtUtc']),
      updatedAtUtc: serializer.fromJson<int>(json['updatedAtUtc']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'weekdaysMask': serializer.toJson<int>(weekdaysMask),
      'localStartMinute': serializer.toJson<int>(localStartMinute),
      'durationMinutes': serializer.toJson<int>(durationMinutes),
      'validFromLocalDate': serializer.toJson<String>(validFromLocalDate),
      'validUntilLocalDate': serializer.toJson<String?>(validUntilLocalDate),
      'timeZoneId': serializer.toJson<String>(timeZoneId),
      'createdAtUtc': serializer.toJson<int>(createdAtUtc),
      'updatedAtUtc': serializer.toJson<int>(updatedAtUtc),
    };
  }

  RecurrenceRule copyWith({
    String? id,
    int? weekdaysMask,
    int? localStartMinute,
    int? durationMinutes,
    String? validFromLocalDate,
    Value<String?> validUntilLocalDate = const Value.absent(),
    String? timeZoneId,
    int? createdAtUtc,
    int? updatedAtUtc,
  }) => RecurrenceRule(
    id: id ?? this.id,
    weekdaysMask: weekdaysMask ?? this.weekdaysMask,
    localStartMinute: localStartMinute ?? this.localStartMinute,
    durationMinutes: durationMinutes ?? this.durationMinutes,
    validFromLocalDate: validFromLocalDate ?? this.validFromLocalDate,
    validUntilLocalDate: validUntilLocalDate.present
        ? validUntilLocalDate.value
        : this.validUntilLocalDate,
    timeZoneId: timeZoneId ?? this.timeZoneId,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
  RecurrenceRule copyWithCompanion(RecurrenceRulesCompanion data) {
    return RecurrenceRule(
      id: data.id.present ? data.id.value : this.id,
      weekdaysMask: data.weekdaysMask.present
          ? data.weekdaysMask.value
          : this.weekdaysMask,
      localStartMinute: data.localStartMinute.present
          ? data.localStartMinute.value
          : this.localStartMinute,
      durationMinutes: data.durationMinutes.present
          ? data.durationMinutes.value
          : this.durationMinutes,
      validFromLocalDate: data.validFromLocalDate.present
          ? data.validFromLocalDate.value
          : this.validFromLocalDate,
      validUntilLocalDate: data.validUntilLocalDate.present
          ? data.validUntilLocalDate.value
          : this.validUntilLocalDate,
      timeZoneId: data.timeZoneId.present
          ? data.timeZoneId.value
          : this.timeZoneId,
      createdAtUtc: data.createdAtUtc.present
          ? data.createdAtUtc.value
          : this.createdAtUtc,
      updatedAtUtc: data.updatedAtUtc.present
          ? data.updatedAtUtc.value
          : this.updatedAtUtc,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RecurrenceRule(')
          ..write('id: $id, ')
          ..write('weekdaysMask: $weekdaysMask, ')
          ..write('localStartMinute: $localStartMinute, ')
          ..write('durationMinutes: $durationMinutes, ')
          ..write('validFromLocalDate: $validFromLocalDate, ')
          ..write('validUntilLocalDate: $validUntilLocalDate, ')
          ..write('timeZoneId: $timeZoneId, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    weekdaysMask,
    localStartMinute,
    durationMinutes,
    validFromLocalDate,
    validUntilLocalDate,
    timeZoneId,
    createdAtUtc,
    updatedAtUtc,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecurrenceRule &&
          other.id == this.id &&
          other.weekdaysMask == this.weekdaysMask &&
          other.localStartMinute == this.localStartMinute &&
          other.durationMinutes == this.durationMinutes &&
          other.validFromLocalDate == this.validFromLocalDate &&
          other.validUntilLocalDate == this.validUntilLocalDate &&
          other.timeZoneId == this.timeZoneId &&
          other.createdAtUtc == this.createdAtUtc &&
          other.updatedAtUtc == this.updatedAtUtc);
}

class RecurrenceRulesCompanion extends UpdateCompanion<RecurrenceRule> {
  final Value<String> id;
  final Value<int> weekdaysMask;
  final Value<int> localStartMinute;
  final Value<int> durationMinutes;
  final Value<String> validFromLocalDate;
  final Value<String?> validUntilLocalDate;
  final Value<String> timeZoneId;
  final Value<int> createdAtUtc;
  final Value<int> updatedAtUtc;
  final Value<int> rowid;
  const RecurrenceRulesCompanion({
    this.id = const Value.absent(),
    this.weekdaysMask = const Value.absent(),
    this.localStartMinute = const Value.absent(),
    this.durationMinutes = const Value.absent(),
    this.validFromLocalDate = const Value.absent(),
    this.validUntilLocalDate = const Value.absent(),
    this.timeZoneId = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RecurrenceRulesCompanion.insert({
    required String id,
    required int weekdaysMask,
    required int localStartMinute,
    required int durationMinutes,
    required String validFromLocalDate,
    this.validUntilLocalDate = const Value.absent(),
    required String timeZoneId,
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       weekdaysMask = Value(weekdaysMask),
       localStartMinute = Value(localStartMinute),
       durationMinutes = Value(durationMinutes),
       validFromLocalDate = Value(validFromLocalDate),
       timeZoneId = Value(timeZoneId);
  static Insertable<RecurrenceRule> custom({
    Expression<String>? id,
    Expression<int>? weekdaysMask,
    Expression<int>? localStartMinute,
    Expression<int>? durationMinutes,
    Expression<String>? validFromLocalDate,
    Expression<String>? validUntilLocalDate,
    Expression<String>? timeZoneId,
    Expression<int>? createdAtUtc,
    Expression<int>? updatedAtUtc,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (weekdaysMask != null) 'weekdays_mask': weekdaysMask,
      if (localStartMinute != null) 'local_start_minute': localStartMinute,
      if (durationMinutes != null) 'duration_minutes': durationMinutes,
      if (validFromLocalDate != null)
        'valid_from_local_date': validFromLocalDate,
      if (validUntilLocalDate != null)
        'valid_until_local_date': validUntilLocalDate,
      if (timeZoneId != null) 'time_zone_id': timeZoneId,
      if (createdAtUtc != null) 'created_at_utc': createdAtUtc,
      if (updatedAtUtc != null) 'updated_at_utc': updatedAtUtc,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RecurrenceRulesCompanion copyWith({
    Value<String>? id,
    Value<int>? weekdaysMask,
    Value<int>? localStartMinute,
    Value<int>? durationMinutes,
    Value<String>? validFromLocalDate,
    Value<String?>? validUntilLocalDate,
    Value<String>? timeZoneId,
    Value<int>? createdAtUtc,
    Value<int>? updatedAtUtc,
    Value<int>? rowid,
  }) {
    return RecurrenceRulesCompanion(
      id: id ?? this.id,
      weekdaysMask: weekdaysMask ?? this.weekdaysMask,
      localStartMinute: localStartMinute ?? this.localStartMinute,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      validFromLocalDate: validFromLocalDate ?? this.validFromLocalDate,
      validUntilLocalDate: validUntilLocalDate ?? this.validUntilLocalDate,
      timeZoneId: timeZoneId ?? this.timeZoneId,
      createdAtUtc: createdAtUtc ?? this.createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (weekdaysMask.present) {
      map['weekdays_mask'] = Variable<int>(weekdaysMask.value);
    }
    if (localStartMinute.present) {
      map['local_start_minute'] = Variable<int>(localStartMinute.value);
    }
    if (durationMinutes.present) {
      map['duration_minutes'] = Variable<int>(durationMinutes.value);
    }
    if (validFromLocalDate.present) {
      map['valid_from_local_date'] = Variable<String>(validFromLocalDate.value);
    }
    if (validUntilLocalDate.present) {
      map['valid_until_local_date'] = Variable<String>(
        validUntilLocalDate.value,
      );
    }
    if (timeZoneId.present) {
      map['time_zone_id'] = Variable<String>(timeZoneId.value);
    }
    if (createdAtUtc.present) {
      map['created_at_utc'] = Variable<int>(createdAtUtc.value);
    }
    if (updatedAtUtc.present) {
      map['updated_at_utc'] = Variable<int>(updatedAtUtc.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecurrenceRulesCompanion(')
          ..write('id: $id, ')
          ..write('weekdaysMask: $weekdaysMask, ')
          ..write('localStartMinute: $localStartMinute, ')
          ..write('durationMinutes: $durationMinutes, ')
          ..write('validFromLocalDate: $validFromLocalDate, ')
          ..write('validUntilLocalDate: $validUntilLocalDate, ')
          ..write('timeZoneId: $timeZoneId, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CalendarEventsTable extends CalendarEvents
    with TableInfo<$CalendarEventsTable, CalendarEvent> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CalendarEventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startAtUtcMeta = const VerificationMeta(
    'startAtUtc',
  );
  @override
  late final GeneratedColumn<int> startAtUtc = GeneratedColumn<int>(
    'start_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endAtUtcMeta = const VerificationMeta(
    'endAtUtc',
  );
  @override
  late final GeneratedColumn<int> endAtUtc = GeneratedColumn<int>(
    'end_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _timeZoneIdMeta = const VerificationMeta(
    'timeZoneId',
  );
  @override
  late final GeneratedColumn<String> timeZoneId = GeneratedColumn<String>(
    'time_zone_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recurrenceRuleIdMeta = const VerificationMeta(
    'recurrenceRuleId',
  );
  @override
  late final GeneratedColumn<String> recurrenceRuleId = GeneratedColumn<String>(
    'recurrence_rule_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES recurrence_rules (id)',
    ),
  );
  static const VerificationMeta _exceptionOfIdMeta = const VerificationMeta(
    'exceptionOfId',
  );
  @override
  late final GeneratedColumn<String> exceptionOfId = GeneratedColumn<String>(
    'exception_of_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES calendar_events (id)',
    ),
  );
  static const VerificationMeta _lockedMeta = const VerificationMeta('locked');
  @override
  late final GeneratedColumn<bool> locked = GeneratedColumn<bool>(
    'locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("locked" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _areaIdMeta = const VerificationMeta('areaId');
  @override
  late final GeneratedColumn<String> areaId = GeneratedColumn<String>(
    'area_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES areas (id)',
    ),
  );
  static const VerificationMeta _createdAtUtcMeta = const VerificationMeta(
    'createdAtUtc',
  );
  @override
  late final GeneratedColumn<int> createdAtUtc = GeneratedColumn<int>(
    'created_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  static const VerificationMeta _updatedAtUtcMeta = const VerificationMeta(
    'updatedAtUtc',
  );
  @override
  late final GeneratedColumn<int> updatedAtUtc = GeneratedColumn<int>(
    'updated_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    startAtUtc,
    endAtUtc,
    timeZoneId,
    recurrenceRuleId,
    exceptionOfId,
    locked,
    areaId,
    createdAtUtc,
    updatedAtUtc,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'calendar_events';
  @override
  VerificationContext validateIntegrity(
    Insertable<CalendarEvent> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('start_at_utc')) {
      context.handle(
        _startAtUtcMeta,
        startAtUtc.isAcceptableOrUnknown(
          data['start_at_utc']!,
          _startAtUtcMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_startAtUtcMeta);
    }
    if (data.containsKey('end_at_utc')) {
      context.handle(
        _endAtUtcMeta,
        endAtUtc.isAcceptableOrUnknown(data['end_at_utc']!, _endAtUtcMeta),
      );
    } else if (isInserting) {
      context.missing(_endAtUtcMeta);
    }
    if (data.containsKey('time_zone_id')) {
      context.handle(
        _timeZoneIdMeta,
        timeZoneId.isAcceptableOrUnknown(
          data['time_zone_id']!,
          _timeZoneIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_timeZoneIdMeta);
    }
    if (data.containsKey('recurrence_rule_id')) {
      context.handle(
        _recurrenceRuleIdMeta,
        recurrenceRuleId.isAcceptableOrUnknown(
          data['recurrence_rule_id']!,
          _recurrenceRuleIdMeta,
        ),
      );
    }
    if (data.containsKey('exception_of_id')) {
      context.handle(
        _exceptionOfIdMeta,
        exceptionOfId.isAcceptableOrUnknown(
          data['exception_of_id']!,
          _exceptionOfIdMeta,
        ),
      );
    }
    if (data.containsKey('locked')) {
      context.handle(
        _lockedMeta,
        locked.isAcceptableOrUnknown(data['locked']!, _lockedMeta),
      );
    }
    if (data.containsKey('area_id')) {
      context.handle(
        _areaIdMeta,
        areaId.isAcceptableOrUnknown(data['area_id']!, _areaIdMeta),
      );
    }
    if (data.containsKey('created_at_utc')) {
      context.handle(
        _createdAtUtcMeta,
        createdAtUtc.isAcceptableOrUnknown(
          data['created_at_utc']!,
          _createdAtUtcMeta,
        ),
      );
    }
    if (data.containsKey('updated_at_utc')) {
      context.handle(
        _updatedAtUtcMeta,
        updatedAtUtc.isAcceptableOrUnknown(
          data['updated_at_utc']!,
          _updatedAtUtcMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtUtcMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CalendarEvent map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CalendarEvent(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      startAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}start_at_utc'],
      )!,
      endAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}end_at_utc'],
      )!,
      timeZoneId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}time_zone_id'],
      )!,
      recurrenceRuleId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}recurrence_rule_id'],
      ),
      exceptionOfId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}exception_of_id'],
      ),
      locked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}locked'],
      )!,
      areaId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}area_id'],
      ),
      createdAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_utc'],
      )!,
      updatedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_utc'],
      )!,
    );
  }

  @override
  $CalendarEventsTable createAlias(String alias) {
    return $CalendarEventsTable(attachedDatabase, alias);
  }
}

class CalendarEvent extends DataClass implements Insertable<CalendarEvent> {
  final String id;
  final String title;
  final int startAtUtc;
  final int endAtUtc;
  final String timeZoneId;
  final String? recurrenceRuleId;
  final String? exceptionOfId;
  final bool locked;
  final String? areaId;
  final int createdAtUtc;
  final int updatedAtUtc;
  const CalendarEvent({
    required this.id,
    required this.title,
    required this.startAtUtc,
    required this.endAtUtc,
    required this.timeZoneId,
    this.recurrenceRuleId,
    this.exceptionOfId,
    required this.locked,
    this.areaId,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['start_at_utc'] = Variable<int>(startAtUtc);
    map['end_at_utc'] = Variable<int>(endAtUtc);
    map['time_zone_id'] = Variable<String>(timeZoneId);
    if (!nullToAbsent || recurrenceRuleId != null) {
      map['recurrence_rule_id'] = Variable<String>(recurrenceRuleId);
    }
    if (!nullToAbsent || exceptionOfId != null) {
      map['exception_of_id'] = Variable<String>(exceptionOfId);
    }
    map['locked'] = Variable<bool>(locked);
    if (!nullToAbsent || areaId != null) {
      map['area_id'] = Variable<String>(areaId);
    }
    map['created_at_utc'] = Variable<int>(createdAtUtc);
    map['updated_at_utc'] = Variable<int>(updatedAtUtc);
    return map;
  }

  CalendarEventsCompanion toCompanion(bool nullToAbsent) {
    return CalendarEventsCompanion(
      id: Value(id),
      title: Value(title),
      startAtUtc: Value(startAtUtc),
      endAtUtc: Value(endAtUtc),
      timeZoneId: Value(timeZoneId),
      recurrenceRuleId: recurrenceRuleId == null && nullToAbsent
          ? const Value.absent()
          : Value(recurrenceRuleId),
      exceptionOfId: exceptionOfId == null && nullToAbsent
          ? const Value.absent()
          : Value(exceptionOfId),
      locked: Value(locked),
      areaId: areaId == null && nullToAbsent
          ? const Value.absent()
          : Value(areaId),
      createdAtUtc: Value(createdAtUtc),
      updatedAtUtc: Value(updatedAtUtc),
    );
  }

  factory CalendarEvent.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CalendarEvent(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      startAtUtc: serializer.fromJson<int>(json['startAtUtc']),
      endAtUtc: serializer.fromJson<int>(json['endAtUtc']),
      timeZoneId: serializer.fromJson<String>(json['timeZoneId']),
      recurrenceRuleId: serializer.fromJson<String?>(json['recurrenceRuleId']),
      exceptionOfId: serializer.fromJson<String?>(json['exceptionOfId']),
      locked: serializer.fromJson<bool>(json['locked']),
      areaId: serializer.fromJson<String?>(json['areaId']),
      createdAtUtc: serializer.fromJson<int>(json['createdAtUtc']),
      updatedAtUtc: serializer.fromJson<int>(json['updatedAtUtc']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'startAtUtc': serializer.toJson<int>(startAtUtc),
      'endAtUtc': serializer.toJson<int>(endAtUtc),
      'timeZoneId': serializer.toJson<String>(timeZoneId),
      'recurrenceRuleId': serializer.toJson<String?>(recurrenceRuleId),
      'exceptionOfId': serializer.toJson<String?>(exceptionOfId),
      'locked': serializer.toJson<bool>(locked),
      'areaId': serializer.toJson<String?>(areaId),
      'createdAtUtc': serializer.toJson<int>(createdAtUtc),
      'updatedAtUtc': serializer.toJson<int>(updatedAtUtc),
    };
  }

  CalendarEvent copyWith({
    String? id,
    String? title,
    int? startAtUtc,
    int? endAtUtc,
    String? timeZoneId,
    Value<String?> recurrenceRuleId = const Value.absent(),
    Value<String?> exceptionOfId = const Value.absent(),
    bool? locked,
    Value<String?> areaId = const Value.absent(),
    int? createdAtUtc,
    int? updatedAtUtc,
  }) => CalendarEvent(
    id: id ?? this.id,
    title: title ?? this.title,
    startAtUtc: startAtUtc ?? this.startAtUtc,
    endAtUtc: endAtUtc ?? this.endAtUtc,
    timeZoneId: timeZoneId ?? this.timeZoneId,
    recurrenceRuleId: recurrenceRuleId.present
        ? recurrenceRuleId.value
        : this.recurrenceRuleId,
    exceptionOfId: exceptionOfId.present
        ? exceptionOfId.value
        : this.exceptionOfId,
    locked: locked ?? this.locked,
    areaId: areaId.present ? areaId.value : this.areaId,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
  CalendarEvent copyWithCompanion(CalendarEventsCompanion data) {
    return CalendarEvent(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      startAtUtc: data.startAtUtc.present
          ? data.startAtUtc.value
          : this.startAtUtc,
      endAtUtc: data.endAtUtc.present ? data.endAtUtc.value : this.endAtUtc,
      timeZoneId: data.timeZoneId.present
          ? data.timeZoneId.value
          : this.timeZoneId,
      recurrenceRuleId: data.recurrenceRuleId.present
          ? data.recurrenceRuleId.value
          : this.recurrenceRuleId,
      exceptionOfId: data.exceptionOfId.present
          ? data.exceptionOfId.value
          : this.exceptionOfId,
      locked: data.locked.present ? data.locked.value : this.locked,
      areaId: data.areaId.present ? data.areaId.value : this.areaId,
      createdAtUtc: data.createdAtUtc.present
          ? data.createdAtUtc.value
          : this.createdAtUtc,
      updatedAtUtc: data.updatedAtUtc.present
          ? data.updatedAtUtc.value
          : this.updatedAtUtc,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CalendarEvent(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('startAtUtc: $startAtUtc, ')
          ..write('endAtUtc: $endAtUtc, ')
          ..write('timeZoneId: $timeZoneId, ')
          ..write('recurrenceRuleId: $recurrenceRuleId, ')
          ..write('exceptionOfId: $exceptionOfId, ')
          ..write('locked: $locked, ')
          ..write('areaId: $areaId, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    startAtUtc,
    endAtUtc,
    timeZoneId,
    recurrenceRuleId,
    exceptionOfId,
    locked,
    areaId,
    createdAtUtc,
    updatedAtUtc,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CalendarEvent &&
          other.id == this.id &&
          other.title == this.title &&
          other.startAtUtc == this.startAtUtc &&
          other.endAtUtc == this.endAtUtc &&
          other.timeZoneId == this.timeZoneId &&
          other.recurrenceRuleId == this.recurrenceRuleId &&
          other.exceptionOfId == this.exceptionOfId &&
          other.locked == this.locked &&
          other.areaId == this.areaId &&
          other.createdAtUtc == this.createdAtUtc &&
          other.updatedAtUtc == this.updatedAtUtc);
}

class CalendarEventsCompanion extends UpdateCompanion<CalendarEvent> {
  final Value<String> id;
  final Value<String> title;
  final Value<int> startAtUtc;
  final Value<int> endAtUtc;
  final Value<String> timeZoneId;
  final Value<String?> recurrenceRuleId;
  final Value<String?> exceptionOfId;
  final Value<bool> locked;
  final Value<String?> areaId;
  final Value<int> createdAtUtc;
  final Value<int> updatedAtUtc;
  final Value<int> rowid;
  const CalendarEventsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.startAtUtc = const Value.absent(),
    this.endAtUtc = const Value.absent(),
    this.timeZoneId = const Value.absent(),
    this.recurrenceRuleId = const Value.absent(),
    this.exceptionOfId = const Value.absent(),
    this.locked = const Value.absent(),
    this.areaId = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CalendarEventsCompanion.insert({
    required String id,
    required String title,
    required int startAtUtc,
    required int endAtUtc,
    required String timeZoneId,
    this.recurrenceRuleId = const Value.absent(),
    this.exceptionOfId = const Value.absent(),
    this.locked = const Value.absent(),
    this.areaId = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    required int updatedAtUtc,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       startAtUtc = Value(startAtUtc),
       endAtUtc = Value(endAtUtc),
       timeZoneId = Value(timeZoneId),
       updatedAtUtc = Value(updatedAtUtc);
  static Insertable<CalendarEvent> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<int>? startAtUtc,
    Expression<int>? endAtUtc,
    Expression<String>? timeZoneId,
    Expression<String>? recurrenceRuleId,
    Expression<String>? exceptionOfId,
    Expression<bool>? locked,
    Expression<String>? areaId,
    Expression<int>? createdAtUtc,
    Expression<int>? updatedAtUtc,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (startAtUtc != null) 'start_at_utc': startAtUtc,
      if (endAtUtc != null) 'end_at_utc': endAtUtc,
      if (timeZoneId != null) 'time_zone_id': timeZoneId,
      if (recurrenceRuleId != null) 'recurrence_rule_id': recurrenceRuleId,
      if (exceptionOfId != null) 'exception_of_id': exceptionOfId,
      if (locked != null) 'locked': locked,
      if (areaId != null) 'area_id': areaId,
      if (createdAtUtc != null) 'created_at_utc': createdAtUtc,
      if (updatedAtUtc != null) 'updated_at_utc': updatedAtUtc,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CalendarEventsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<int>? startAtUtc,
    Value<int>? endAtUtc,
    Value<String>? timeZoneId,
    Value<String?>? recurrenceRuleId,
    Value<String?>? exceptionOfId,
    Value<bool>? locked,
    Value<String?>? areaId,
    Value<int>? createdAtUtc,
    Value<int>? updatedAtUtc,
    Value<int>? rowid,
  }) {
    return CalendarEventsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      startAtUtc: startAtUtc ?? this.startAtUtc,
      endAtUtc: endAtUtc ?? this.endAtUtc,
      timeZoneId: timeZoneId ?? this.timeZoneId,
      recurrenceRuleId: recurrenceRuleId ?? this.recurrenceRuleId,
      exceptionOfId: exceptionOfId ?? this.exceptionOfId,
      locked: locked ?? this.locked,
      areaId: areaId ?? this.areaId,
      createdAtUtc: createdAtUtc ?? this.createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (startAtUtc.present) {
      map['start_at_utc'] = Variable<int>(startAtUtc.value);
    }
    if (endAtUtc.present) {
      map['end_at_utc'] = Variable<int>(endAtUtc.value);
    }
    if (timeZoneId.present) {
      map['time_zone_id'] = Variable<String>(timeZoneId.value);
    }
    if (recurrenceRuleId.present) {
      map['recurrence_rule_id'] = Variable<String>(recurrenceRuleId.value);
    }
    if (exceptionOfId.present) {
      map['exception_of_id'] = Variable<String>(exceptionOfId.value);
    }
    if (locked.present) {
      map['locked'] = Variable<bool>(locked.value);
    }
    if (areaId.present) {
      map['area_id'] = Variable<String>(areaId.value);
    }
    if (createdAtUtc.present) {
      map['created_at_utc'] = Variable<int>(createdAtUtc.value);
    }
    if (updatedAtUtc.present) {
      map['updated_at_utc'] = Variable<int>(updatedAtUtc.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CalendarEventsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('startAtUtc: $startAtUtc, ')
          ..write('endAtUtc: $endAtUtc, ')
          ..write('timeZoneId: $timeZoneId, ')
          ..write('recurrenceRuleId: $recurrenceRuleId, ')
          ..write('exceptionOfId: $exceptionOfId, ')
          ..write('locked: $locked, ')
          ..write('areaId: $areaId, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $EnergyWindowsTable extends EnergyWindows
    with TableInfo<$EnergyWindowsTable, EnergyWindow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $EnergyWindowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dayKindMeta = const VerificationMeta(
    'dayKind',
  );
  @override
  late final GeneratedColumn<String> dayKind = GeneratedColumn<String>(
    'day_kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startMinuteMeta = const VerificationMeta(
    'startMinute',
  );
  @override
  late final GeneratedColumn<int> startMinute = GeneratedColumn<int>(
    'start_minute',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endMinuteMeta = const VerificationMeta(
    'endMinute',
  );
  @override
  late final GeneratedColumn<int> endMinute = GeneratedColumn<int>(
    'end_minute',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _energyLevelMeta = const VerificationMeta(
    'energyLevel',
  );
  @override
  late final GeneratedColumn<String> energyLevel = GeneratedColumn<String>(
    'energy_level',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtUtcMeta = const VerificationMeta(
    'createdAtUtc',
  );
  @override
  late final GeneratedColumn<int> createdAtUtc = GeneratedColumn<int>(
    'created_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  static const VerificationMeta _updatedAtUtcMeta = const VerificationMeta(
    'updatedAtUtc',
  );
  @override
  late final GeneratedColumn<int> updatedAtUtc = GeneratedColumn<int>(
    'updated_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    dayKind,
    startMinute,
    endMinute,
    energyLevel,
    source,
    createdAtUtc,
    updatedAtUtc,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'energy_windows';
  @override
  VerificationContext validateIntegrity(
    Insertable<EnergyWindow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('day_kind')) {
      context.handle(
        _dayKindMeta,
        dayKind.isAcceptableOrUnknown(data['day_kind']!, _dayKindMeta),
      );
    } else if (isInserting) {
      context.missing(_dayKindMeta);
    }
    if (data.containsKey('start_minute')) {
      context.handle(
        _startMinuteMeta,
        startMinute.isAcceptableOrUnknown(
          data['start_minute']!,
          _startMinuteMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_startMinuteMeta);
    }
    if (data.containsKey('end_minute')) {
      context.handle(
        _endMinuteMeta,
        endMinute.isAcceptableOrUnknown(data['end_minute']!, _endMinuteMeta),
      );
    } else if (isInserting) {
      context.missing(_endMinuteMeta);
    }
    if (data.containsKey('energy_level')) {
      context.handle(
        _energyLevelMeta,
        energyLevel.isAcceptableOrUnknown(
          data['energy_level']!,
          _energyLevelMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_energyLevelMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('created_at_utc')) {
      context.handle(
        _createdAtUtcMeta,
        createdAtUtc.isAcceptableOrUnknown(
          data['created_at_utc']!,
          _createdAtUtcMeta,
        ),
      );
    }
    if (data.containsKey('updated_at_utc')) {
      context.handle(
        _updatedAtUtcMeta,
        updatedAtUtc.isAcceptableOrUnknown(
          data['updated_at_utc']!,
          _updatedAtUtcMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  EnergyWindow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return EnergyWindow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      dayKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}day_kind'],
      )!,
      startMinute: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}start_minute'],
      )!,
      endMinute: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}end_minute'],
      )!,
      energyLevel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}energy_level'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      createdAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_utc'],
      )!,
      updatedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_utc'],
      )!,
    );
  }

  @override
  $EnergyWindowsTable createAlias(String alias) {
    return $EnergyWindowsTable(attachedDatabase, alias);
  }
}

class EnergyWindow extends DataClass implements Insertable<EnergyWindow> {
  final String id;
  final String dayKind;
  final int startMinute;
  final int endMinute;
  final String energyLevel;
  final String source;
  final int createdAtUtc;
  final int updatedAtUtc;
  const EnergyWindow({
    required this.id,
    required this.dayKind,
    required this.startMinute,
    required this.endMinute,
    required this.energyLevel,
    required this.source,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['day_kind'] = Variable<String>(dayKind);
    map['start_minute'] = Variable<int>(startMinute);
    map['end_minute'] = Variable<int>(endMinute);
    map['energy_level'] = Variable<String>(energyLevel);
    map['source'] = Variable<String>(source);
    map['created_at_utc'] = Variable<int>(createdAtUtc);
    map['updated_at_utc'] = Variable<int>(updatedAtUtc);
    return map;
  }

  EnergyWindowsCompanion toCompanion(bool nullToAbsent) {
    return EnergyWindowsCompanion(
      id: Value(id),
      dayKind: Value(dayKind),
      startMinute: Value(startMinute),
      endMinute: Value(endMinute),
      energyLevel: Value(energyLevel),
      source: Value(source),
      createdAtUtc: Value(createdAtUtc),
      updatedAtUtc: Value(updatedAtUtc),
    );
  }

  factory EnergyWindow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EnergyWindow(
      id: serializer.fromJson<String>(json['id']),
      dayKind: serializer.fromJson<String>(json['dayKind']),
      startMinute: serializer.fromJson<int>(json['startMinute']),
      endMinute: serializer.fromJson<int>(json['endMinute']),
      energyLevel: serializer.fromJson<String>(json['energyLevel']),
      source: serializer.fromJson<String>(json['source']),
      createdAtUtc: serializer.fromJson<int>(json['createdAtUtc']),
      updatedAtUtc: serializer.fromJson<int>(json['updatedAtUtc']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'dayKind': serializer.toJson<String>(dayKind),
      'startMinute': serializer.toJson<int>(startMinute),
      'endMinute': serializer.toJson<int>(endMinute),
      'energyLevel': serializer.toJson<String>(energyLevel),
      'source': serializer.toJson<String>(source),
      'createdAtUtc': serializer.toJson<int>(createdAtUtc),
      'updatedAtUtc': serializer.toJson<int>(updatedAtUtc),
    };
  }

  EnergyWindow copyWith({
    String? id,
    String? dayKind,
    int? startMinute,
    int? endMinute,
    String? energyLevel,
    String? source,
    int? createdAtUtc,
    int? updatedAtUtc,
  }) => EnergyWindow(
    id: id ?? this.id,
    dayKind: dayKind ?? this.dayKind,
    startMinute: startMinute ?? this.startMinute,
    endMinute: endMinute ?? this.endMinute,
    energyLevel: energyLevel ?? this.energyLevel,
    source: source ?? this.source,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
  EnergyWindow copyWithCompanion(EnergyWindowsCompanion data) {
    return EnergyWindow(
      id: data.id.present ? data.id.value : this.id,
      dayKind: data.dayKind.present ? data.dayKind.value : this.dayKind,
      startMinute: data.startMinute.present
          ? data.startMinute.value
          : this.startMinute,
      endMinute: data.endMinute.present ? data.endMinute.value : this.endMinute,
      energyLevel: data.energyLevel.present
          ? data.energyLevel.value
          : this.energyLevel,
      source: data.source.present ? data.source.value : this.source,
      createdAtUtc: data.createdAtUtc.present
          ? data.createdAtUtc.value
          : this.createdAtUtc,
      updatedAtUtc: data.updatedAtUtc.present
          ? data.updatedAtUtc.value
          : this.updatedAtUtc,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EnergyWindow(')
          ..write('id: $id, ')
          ..write('dayKind: $dayKind, ')
          ..write('startMinute: $startMinute, ')
          ..write('endMinute: $endMinute, ')
          ..write('energyLevel: $energyLevel, ')
          ..write('source: $source, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    dayKind,
    startMinute,
    endMinute,
    energyLevel,
    source,
    createdAtUtc,
    updatedAtUtc,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EnergyWindow &&
          other.id == this.id &&
          other.dayKind == this.dayKind &&
          other.startMinute == this.startMinute &&
          other.endMinute == this.endMinute &&
          other.energyLevel == this.energyLevel &&
          other.source == this.source &&
          other.createdAtUtc == this.createdAtUtc &&
          other.updatedAtUtc == this.updatedAtUtc);
}

class EnergyWindowsCompanion extends UpdateCompanion<EnergyWindow> {
  final Value<String> id;
  final Value<String> dayKind;
  final Value<int> startMinute;
  final Value<int> endMinute;
  final Value<String> energyLevel;
  final Value<String> source;
  final Value<int> createdAtUtc;
  final Value<int> updatedAtUtc;
  final Value<int> rowid;
  const EnergyWindowsCompanion({
    this.id = const Value.absent(),
    this.dayKind = const Value.absent(),
    this.startMinute = const Value.absent(),
    this.endMinute = const Value.absent(),
    this.energyLevel = const Value.absent(),
    this.source = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  EnergyWindowsCompanion.insert({
    required String id,
    required String dayKind,
    required int startMinute,
    required int endMinute,
    required String energyLevel,
    required String source,
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       dayKind = Value(dayKind),
       startMinute = Value(startMinute),
       endMinute = Value(endMinute),
       energyLevel = Value(energyLevel),
       source = Value(source);
  static Insertable<EnergyWindow> custom({
    Expression<String>? id,
    Expression<String>? dayKind,
    Expression<int>? startMinute,
    Expression<int>? endMinute,
    Expression<String>? energyLevel,
    Expression<String>? source,
    Expression<int>? createdAtUtc,
    Expression<int>? updatedAtUtc,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (dayKind != null) 'day_kind': dayKind,
      if (startMinute != null) 'start_minute': startMinute,
      if (endMinute != null) 'end_minute': endMinute,
      if (energyLevel != null) 'energy_level': energyLevel,
      if (source != null) 'source': source,
      if (createdAtUtc != null) 'created_at_utc': createdAtUtc,
      if (updatedAtUtc != null) 'updated_at_utc': updatedAtUtc,
      if (rowid != null) 'rowid': rowid,
    });
  }

  EnergyWindowsCompanion copyWith({
    Value<String>? id,
    Value<String>? dayKind,
    Value<int>? startMinute,
    Value<int>? endMinute,
    Value<String>? energyLevel,
    Value<String>? source,
    Value<int>? createdAtUtc,
    Value<int>? updatedAtUtc,
    Value<int>? rowid,
  }) {
    return EnergyWindowsCompanion(
      id: id ?? this.id,
      dayKind: dayKind ?? this.dayKind,
      startMinute: startMinute ?? this.startMinute,
      endMinute: endMinute ?? this.endMinute,
      energyLevel: energyLevel ?? this.energyLevel,
      source: source ?? this.source,
      createdAtUtc: createdAtUtc ?? this.createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (dayKind.present) {
      map['day_kind'] = Variable<String>(dayKind.value);
    }
    if (startMinute.present) {
      map['start_minute'] = Variable<int>(startMinute.value);
    }
    if (endMinute.present) {
      map['end_minute'] = Variable<int>(endMinute.value);
    }
    if (energyLevel.present) {
      map['energy_level'] = Variable<String>(energyLevel.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (createdAtUtc.present) {
      map['created_at_utc'] = Variable<int>(createdAtUtc.value);
    }
    if (updatedAtUtc.present) {
      map['updated_at_utc'] = Variable<int>(updatedAtUtc.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EnergyWindowsCompanion(')
          ..write('id: $id, ')
          ..write('dayKind: $dayKind, ')
          ..write('startMinute: $startMinute, ')
          ..write('endMinute: $endMinute, ')
          ..write('energyLevel: $energyLevel, ')
          ..write('source: $source, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SettingsTable extends Settings with TableInfo<$SettingsTable, Setting> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _jsonValueMeta = const VerificationMeta(
    'jsonValue',
  );
  @override
  late final GeneratedColumn<String> jsonValue = GeneratedColumn<String>(
    'json_value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtUtcMeta = const VerificationMeta(
    'createdAtUtc',
  );
  @override
  late final GeneratedColumn<int> createdAtUtc = GeneratedColumn<int>(
    'created_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  static const VerificationMeta _updatedAtUtcMeta = const VerificationMeta(
    'updatedAtUtc',
  );
  @override
  late final GeneratedColumn<int> updatedAtUtc = GeneratedColumn<int>(
    'updated_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    key,
    jsonValue,
    createdAtUtc,
    updatedAtUtc,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<Setting> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('json_value')) {
      context.handle(
        _jsonValueMeta,
        jsonValue.isAcceptableOrUnknown(data['json_value']!, _jsonValueMeta),
      );
    } else if (isInserting) {
      context.missing(_jsonValueMeta);
    }
    if (data.containsKey('created_at_utc')) {
      context.handle(
        _createdAtUtcMeta,
        createdAtUtc.isAcceptableOrUnknown(
          data['created_at_utc']!,
          _createdAtUtcMeta,
        ),
      );
    }
    if (data.containsKey('updated_at_utc')) {
      context.handle(
        _updatedAtUtcMeta,
        updatedAtUtc.isAcceptableOrUnknown(
          data['updated_at_utc']!,
          _updatedAtUtcMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtUtcMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  Setting map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Setting(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      jsonValue: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}json_value'],
      )!,
      createdAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_utc'],
      )!,
      updatedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_utc'],
      )!,
    );
  }

  @override
  $SettingsTable createAlias(String alias) {
    return $SettingsTable(attachedDatabase, alias);
  }
}

class Setting extends DataClass implements Insertable<Setting> {
  final String key;
  final String jsonValue;
  final int createdAtUtc;
  final int updatedAtUtc;
  const Setting({
    required this.key,
    required this.jsonValue,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['json_value'] = Variable<String>(jsonValue);
    map['created_at_utc'] = Variable<int>(createdAtUtc);
    map['updated_at_utc'] = Variable<int>(updatedAtUtc);
    return map;
  }

  SettingsCompanion toCompanion(bool nullToAbsent) {
    return SettingsCompanion(
      key: Value(key),
      jsonValue: Value(jsonValue),
      createdAtUtc: Value(createdAtUtc),
      updatedAtUtc: Value(updatedAtUtc),
    );
  }

  factory Setting.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Setting(
      key: serializer.fromJson<String>(json['key']),
      jsonValue: serializer.fromJson<String>(json['jsonValue']),
      createdAtUtc: serializer.fromJson<int>(json['createdAtUtc']),
      updatedAtUtc: serializer.fromJson<int>(json['updatedAtUtc']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'jsonValue': serializer.toJson<String>(jsonValue),
      'createdAtUtc': serializer.toJson<int>(createdAtUtc),
      'updatedAtUtc': serializer.toJson<int>(updatedAtUtc),
    };
  }

  Setting copyWith({
    String? key,
    String? jsonValue,
    int? createdAtUtc,
    int? updatedAtUtc,
  }) => Setting(
    key: key ?? this.key,
    jsonValue: jsonValue ?? this.jsonValue,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
  Setting copyWithCompanion(SettingsCompanion data) {
    return Setting(
      key: data.key.present ? data.key.value : this.key,
      jsonValue: data.jsonValue.present ? data.jsonValue.value : this.jsonValue,
      createdAtUtc: data.createdAtUtc.present
          ? data.createdAtUtc.value
          : this.createdAtUtc,
      updatedAtUtc: data.updatedAtUtc.present
          ? data.updatedAtUtc.value
          : this.updatedAtUtc,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Setting(')
          ..write('key: $key, ')
          ..write('jsonValue: $jsonValue, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, jsonValue, createdAtUtc, updatedAtUtc);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Setting &&
          other.key == this.key &&
          other.jsonValue == this.jsonValue &&
          other.createdAtUtc == this.createdAtUtc &&
          other.updatedAtUtc == this.updatedAtUtc);
}

class SettingsCompanion extends UpdateCompanion<Setting> {
  final Value<String> key;
  final Value<String> jsonValue;
  final Value<int> createdAtUtc;
  final Value<int> updatedAtUtc;
  final Value<int> rowid;
  const SettingsCompanion({
    this.key = const Value.absent(),
    this.jsonValue = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SettingsCompanion.insert({
    required String key,
    required String jsonValue,
    this.createdAtUtc = const Value.absent(),
    required int updatedAtUtc,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       jsonValue = Value(jsonValue),
       updatedAtUtc = Value(updatedAtUtc);
  static Insertable<Setting> custom({
    Expression<String>? key,
    Expression<String>? jsonValue,
    Expression<int>? createdAtUtc,
    Expression<int>? updatedAtUtc,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (jsonValue != null) 'json_value': jsonValue,
      if (createdAtUtc != null) 'created_at_utc': createdAtUtc,
      if (updatedAtUtc != null) 'updated_at_utc': updatedAtUtc,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? jsonValue,
    Value<int>? createdAtUtc,
    Value<int>? updatedAtUtc,
    Value<int>? rowid,
  }) {
    return SettingsCompanion(
      key: key ?? this.key,
      jsonValue: jsonValue ?? this.jsonValue,
      createdAtUtc: createdAtUtc ?? this.createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (jsonValue.present) {
      map['json_value'] = Variable<String>(jsonValue.value);
    }
    if (createdAtUtc.present) {
      map['created_at_utc'] = Variable<int>(createdAtUtc.value);
    }
    if (updatedAtUtc.present) {
      map['updated_at_utc'] = Variable<int>(updatedAtUtc.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SettingsCompanion(')
          ..write('key: $key, ')
          ..write('jsonValue: $jsonValue, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PlanVersionsTable extends PlanVersions
    with TableInfo<$PlanVersionsTable, PlanVersion> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlanVersionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtUtcMeta = const VerificationMeta(
    'createdAtUtc',
  );
  @override
  late final GeneratedColumn<int> createdAtUtc = GeneratedColumn<int>(
    'created_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _inputHashMeta = const VerificationMeta(
    'inputHash',
  );
  @override
  late final GeneratedColumn<String> inputHash = GeneratedColumn<String>(
    'input_hash',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _algorithmVersionMeta = const VerificationMeta(
    'algorithmVersion',
  );
  @override
  late final GeneratedColumn<String> algorithmVersion = GeneratedColumn<String>(
    'algorithm_version',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _summaryJsonMeta = const VerificationMeta(
    'summaryJson',
  );
  @override
  late final GeneratedColumn<String> summaryJson = GeneratedColumn<String>(
    'summary_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    createdAtUtc,
    inputHash,
    algorithmVersion,
    status,
    summaryJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'plan_versions';
  @override
  VerificationContext validateIntegrity(
    Insertable<PlanVersion> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at_utc')) {
      context.handle(
        _createdAtUtcMeta,
        createdAtUtc.isAcceptableOrUnknown(
          data['created_at_utc']!,
          _createdAtUtcMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_createdAtUtcMeta);
    }
    if (data.containsKey('input_hash')) {
      context.handle(
        _inputHashMeta,
        inputHash.isAcceptableOrUnknown(data['input_hash']!, _inputHashMeta),
      );
    } else if (isInserting) {
      context.missing(_inputHashMeta);
    }
    if (data.containsKey('algorithm_version')) {
      context.handle(
        _algorithmVersionMeta,
        algorithmVersion.isAcceptableOrUnknown(
          data['algorithm_version']!,
          _algorithmVersionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_algorithmVersionMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('summary_json')) {
      context.handle(
        _summaryJsonMeta,
        summaryJson.isAcceptableOrUnknown(
          data['summary_json']!,
          _summaryJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_summaryJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlanVersion map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlanVersion(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      createdAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_utc'],
      )!,
      inputHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}input_hash'],
      )!,
      algorithmVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}algorithm_version'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      summaryJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary_json'],
      )!,
    );
  }

  @override
  $PlanVersionsTable createAlias(String alias) {
    return $PlanVersionsTable(attachedDatabase, alias);
  }
}

class PlanVersion extends DataClass implements Insertable<PlanVersion> {
  final String id;
  final int createdAtUtc;
  final String inputHash;
  final String algorithmVersion;
  final String status;
  final String summaryJson;
  const PlanVersion({
    required this.id,
    required this.createdAtUtc,
    required this.inputHash,
    required this.algorithmVersion,
    required this.status,
    required this.summaryJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['created_at_utc'] = Variable<int>(createdAtUtc);
    map['input_hash'] = Variable<String>(inputHash);
    map['algorithm_version'] = Variable<String>(algorithmVersion);
    map['status'] = Variable<String>(status);
    map['summary_json'] = Variable<String>(summaryJson);
    return map;
  }

  PlanVersionsCompanion toCompanion(bool nullToAbsent) {
    return PlanVersionsCompanion(
      id: Value(id),
      createdAtUtc: Value(createdAtUtc),
      inputHash: Value(inputHash),
      algorithmVersion: Value(algorithmVersion),
      status: Value(status),
      summaryJson: Value(summaryJson),
    );
  }

  factory PlanVersion.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlanVersion(
      id: serializer.fromJson<String>(json['id']),
      createdAtUtc: serializer.fromJson<int>(json['createdAtUtc']),
      inputHash: serializer.fromJson<String>(json['inputHash']),
      algorithmVersion: serializer.fromJson<String>(json['algorithmVersion']),
      status: serializer.fromJson<String>(json['status']),
      summaryJson: serializer.fromJson<String>(json['summaryJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'createdAtUtc': serializer.toJson<int>(createdAtUtc),
      'inputHash': serializer.toJson<String>(inputHash),
      'algorithmVersion': serializer.toJson<String>(algorithmVersion),
      'status': serializer.toJson<String>(status),
      'summaryJson': serializer.toJson<String>(summaryJson),
    };
  }

  PlanVersion copyWith({
    String? id,
    int? createdAtUtc,
    String? inputHash,
    String? algorithmVersion,
    String? status,
    String? summaryJson,
  }) => PlanVersion(
    id: id ?? this.id,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    inputHash: inputHash ?? this.inputHash,
    algorithmVersion: algorithmVersion ?? this.algorithmVersion,
    status: status ?? this.status,
    summaryJson: summaryJson ?? this.summaryJson,
  );
  PlanVersion copyWithCompanion(PlanVersionsCompanion data) {
    return PlanVersion(
      id: data.id.present ? data.id.value : this.id,
      createdAtUtc: data.createdAtUtc.present
          ? data.createdAtUtc.value
          : this.createdAtUtc,
      inputHash: data.inputHash.present ? data.inputHash.value : this.inputHash,
      algorithmVersion: data.algorithmVersion.present
          ? data.algorithmVersion.value
          : this.algorithmVersion,
      status: data.status.present ? data.status.value : this.status,
      summaryJson: data.summaryJson.present
          ? data.summaryJson.value
          : this.summaryJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlanVersion(')
          ..write('id: $id, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('inputHash: $inputHash, ')
          ..write('algorithmVersion: $algorithmVersion, ')
          ..write('status: $status, ')
          ..write('summaryJson: $summaryJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    createdAtUtc,
    inputHash,
    algorithmVersion,
    status,
    summaryJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlanVersion &&
          other.id == this.id &&
          other.createdAtUtc == this.createdAtUtc &&
          other.inputHash == this.inputHash &&
          other.algorithmVersion == this.algorithmVersion &&
          other.status == this.status &&
          other.summaryJson == this.summaryJson);
}

class PlanVersionsCompanion extends UpdateCompanion<PlanVersion> {
  final Value<String> id;
  final Value<int> createdAtUtc;
  final Value<String> inputHash;
  final Value<String> algorithmVersion;
  final Value<String> status;
  final Value<String> summaryJson;
  final Value<int> rowid;
  const PlanVersionsCompanion({
    this.id = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    this.inputHash = const Value.absent(),
    this.algorithmVersion = const Value.absent(),
    this.status = const Value.absent(),
    this.summaryJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlanVersionsCompanion.insert({
    required String id,
    required int createdAtUtc,
    required String inputHash,
    required String algorithmVersion,
    required String status,
    required String summaryJson,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       createdAtUtc = Value(createdAtUtc),
       inputHash = Value(inputHash),
       algorithmVersion = Value(algorithmVersion),
       status = Value(status),
       summaryJson = Value(summaryJson);
  static Insertable<PlanVersion> custom({
    Expression<String>? id,
    Expression<int>? createdAtUtc,
    Expression<String>? inputHash,
    Expression<String>? algorithmVersion,
    Expression<String>? status,
    Expression<String>? summaryJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAtUtc != null) 'created_at_utc': createdAtUtc,
      if (inputHash != null) 'input_hash': inputHash,
      if (algorithmVersion != null) 'algorithm_version': algorithmVersion,
      if (status != null) 'status': status,
      if (summaryJson != null) 'summary_json': summaryJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlanVersionsCompanion copyWith({
    Value<String>? id,
    Value<int>? createdAtUtc,
    Value<String>? inputHash,
    Value<String>? algorithmVersion,
    Value<String>? status,
    Value<String>? summaryJson,
    Value<int>? rowid,
  }) {
    return PlanVersionsCompanion(
      id: id ?? this.id,
      createdAtUtc: createdAtUtc ?? this.createdAtUtc,
      inputHash: inputHash ?? this.inputHash,
      algorithmVersion: algorithmVersion ?? this.algorithmVersion,
      status: status ?? this.status,
      summaryJson: summaryJson ?? this.summaryJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (createdAtUtc.present) {
      map['created_at_utc'] = Variable<int>(createdAtUtc.value);
    }
    if (inputHash.present) {
      map['input_hash'] = Variable<String>(inputHash.value);
    }
    if (algorithmVersion.present) {
      map['algorithm_version'] = Variable<String>(algorithmVersion.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (summaryJson.present) {
      map['summary_json'] = Variable<String>(summaryJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlanVersionsCompanion(')
          ..write('id: $id, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('inputHash: $inputHash, ')
          ..write('algorithmVersion: $algorithmVersion, ')
          ..write('status: $status, ')
          ..write('summaryJson: $summaryJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ScheduleBlocksTable extends ScheduleBlocks
    with TableInfo<$ScheduleBlocksTable, ScheduleBlock> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ScheduleBlocksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _planVersionIdMeta = const VerificationMeta(
    'planVersionId',
  );
  @override
  late final GeneratedColumn<String> planVersionId = GeneratedColumn<String>(
    'plan_version_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES plan_versions (id)',
    ),
  );
  static const VerificationMeta _taskIdMeta = const VerificationMeta('taskId');
  @override
  late final GeneratedColumn<String> taskId = GeneratedColumn<String>(
    'task_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES tasks (id)',
    ),
  );
  static const VerificationMeta _startAtUtcMeta = const VerificationMeta(
    'startAtUtc',
  );
  @override
  late final GeneratedColumn<int> startAtUtc = GeneratedColumn<int>(
    'start_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endAtUtcMeta = const VerificationMeta(
    'endAtUtc',
  );
  @override
  late final GeneratedColumn<int> endAtUtc = GeneratedColumn<int>(
    'end_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lockedMeta = const VerificationMeta('locked');
  @override
  late final GeneratedColumn<bool> locked = GeneratedColumn<bool>(
    'locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("locked" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _explanationCodeMeta = const VerificationMeta(
    'explanationCode',
  );
  @override
  late final GeneratedColumn<String> explanationCode = GeneratedColumn<String>(
    'explanation_code',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtUtcMeta = const VerificationMeta(
    'createdAtUtc',
  );
  @override
  late final GeneratedColumn<int> createdAtUtc = GeneratedColumn<int>(
    'created_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  static const VerificationMeta _updatedAtUtcMeta = const VerificationMeta(
    'updatedAtUtc',
  );
  @override
  late final GeneratedColumn<int> updatedAtUtc = GeneratedColumn<int>(
    'updated_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    planVersionId,
    taskId,
    startAtUtc,
    endAtUtc,
    locked,
    explanationCode,
    createdAtUtc,
    updatedAtUtc,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'schedule_blocks';
  @override
  VerificationContext validateIntegrity(
    Insertable<ScheduleBlock> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('plan_version_id')) {
      context.handle(
        _planVersionIdMeta,
        planVersionId.isAcceptableOrUnknown(
          data['plan_version_id']!,
          _planVersionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_planVersionIdMeta);
    }
    if (data.containsKey('task_id')) {
      context.handle(
        _taskIdMeta,
        taskId.isAcceptableOrUnknown(data['task_id']!, _taskIdMeta),
      );
    } else if (isInserting) {
      context.missing(_taskIdMeta);
    }
    if (data.containsKey('start_at_utc')) {
      context.handle(
        _startAtUtcMeta,
        startAtUtc.isAcceptableOrUnknown(
          data['start_at_utc']!,
          _startAtUtcMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_startAtUtcMeta);
    }
    if (data.containsKey('end_at_utc')) {
      context.handle(
        _endAtUtcMeta,
        endAtUtc.isAcceptableOrUnknown(data['end_at_utc']!, _endAtUtcMeta),
      );
    } else if (isInserting) {
      context.missing(_endAtUtcMeta);
    }
    if (data.containsKey('locked')) {
      context.handle(
        _lockedMeta,
        locked.isAcceptableOrUnknown(data['locked']!, _lockedMeta),
      );
    }
    if (data.containsKey('explanation_code')) {
      context.handle(
        _explanationCodeMeta,
        explanationCode.isAcceptableOrUnknown(
          data['explanation_code']!,
          _explanationCodeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_explanationCodeMeta);
    }
    if (data.containsKey('created_at_utc')) {
      context.handle(
        _createdAtUtcMeta,
        createdAtUtc.isAcceptableOrUnknown(
          data['created_at_utc']!,
          _createdAtUtcMeta,
        ),
      );
    }
    if (data.containsKey('updated_at_utc')) {
      context.handle(
        _updatedAtUtcMeta,
        updatedAtUtc.isAcceptableOrUnknown(
          data['updated_at_utc']!,
          _updatedAtUtcMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ScheduleBlock map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ScheduleBlock(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      planVersionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}plan_version_id'],
      )!,
      taskId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}task_id'],
      )!,
      startAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}start_at_utc'],
      )!,
      endAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}end_at_utc'],
      )!,
      locked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}locked'],
      )!,
      explanationCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}explanation_code'],
      )!,
      createdAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_utc'],
      )!,
      updatedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_utc'],
      )!,
    );
  }

  @override
  $ScheduleBlocksTable createAlias(String alias) {
    return $ScheduleBlocksTable(attachedDatabase, alias);
  }
}

class ScheduleBlock extends DataClass implements Insertable<ScheduleBlock> {
  final String id;
  final String planVersionId;
  final String taskId;
  final int startAtUtc;
  final int endAtUtc;
  final bool locked;
  final String explanationCode;
  final int createdAtUtc;
  final int updatedAtUtc;
  const ScheduleBlock({
    required this.id,
    required this.planVersionId,
    required this.taskId,
    required this.startAtUtc,
    required this.endAtUtc,
    required this.locked,
    required this.explanationCode,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['plan_version_id'] = Variable<String>(planVersionId);
    map['task_id'] = Variable<String>(taskId);
    map['start_at_utc'] = Variable<int>(startAtUtc);
    map['end_at_utc'] = Variable<int>(endAtUtc);
    map['locked'] = Variable<bool>(locked);
    map['explanation_code'] = Variable<String>(explanationCode);
    map['created_at_utc'] = Variable<int>(createdAtUtc);
    map['updated_at_utc'] = Variable<int>(updatedAtUtc);
    return map;
  }

  ScheduleBlocksCompanion toCompanion(bool nullToAbsent) {
    return ScheduleBlocksCompanion(
      id: Value(id),
      planVersionId: Value(planVersionId),
      taskId: Value(taskId),
      startAtUtc: Value(startAtUtc),
      endAtUtc: Value(endAtUtc),
      locked: Value(locked),
      explanationCode: Value(explanationCode),
      createdAtUtc: Value(createdAtUtc),
      updatedAtUtc: Value(updatedAtUtc),
    );
  }

  factory ScheduleBlock.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ScheduleBlock(
      id: serializer.fromJson<String>(json['id']),
      planVersionId: serializer.fromJson<String>(json['planVersionId']),
      taskId: serializer.fromJson<String>(json['taskId']),
      startAtUtc: serializer.fromJson<int>(json['startAtUtc']),
      endAtUtc: serializer.fromJson<int>(json['endAtUtc']),
      locked: serializer.fromJson<bool>(json['locked']),
      explanationCode: serializer.fromJson<String>(json['explanationCode']),
      createdAtUtc: serializer.fromJson<int>(json['createdAtUtc']),
      updatedAtUtc: serializer.fromJson<int>(json['updatedAtUtc']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'planVersionId': serializer.toJson<String>(planVersionId),
      'taskId': serializer.toJson<String>(taskId),
      'startAtUtc': serializer.toJson<int>(startAtUtc),
      'endAtUtc': serializer.toJson<int>(endAtUtc),
      'locked': serializer.toJson<bool>(locked),
      'explanationCode': serializer.toJson<String>(explanationCode),
      'createdAtUtc': serializer.toJson<int>(createdAtUtc),
      'updatedAtUtc': serializer.toJson<int>(updatedAtUtc),
    };
  }

  ScheduleBlock copyWith({
    String? id,
    String? planVersionId,
    String? taskId,
    int? startAtUtc,
    int? endAtUtc,
    bool? locked,
    String? explanationCode,
    int? createdAtUtc,
    int? updatedAtUtc,
  }) => ScheduleBlock(
    id: id ?? this.id,
    planVersionId: planVersionId ?? this.planVersionId,
    taskId: taskId ?? this.taskId,
    startAtUtc: startAtUtc ?? this.startAtUtc,
    endAtUtc: endAtUtc ?? this.endAtUtc,
    locked: locked ?? this.locked,
    explanationCode: explanationCode ?? this.explanationCode,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
  ScheduleBlock copyWithCompanion(ScheduleBlocksCompanion data) {
    return ScheduleBlock(
      id: data.id.present ? data.id.value : this.id,
      planVersionId: data.planVersionId.present
          ? data.planVersionId.value
          : this.planVersionId,
      taskId: data.taskId.present ? data.taskId.value : this.taskId,
      startAtUtc: data.startAtUtc.present
          ? data.startAtUtc.value
          : this.startAtUtc,
      endAtUtc: data.endAtUtc.present ? data.endAtUtc.value : this.endAtUtc,
      locked: data.locked.present ? data.locked.value : this.locked,
      explanationCode: data.explanationCode.present
          ? data.explanationCode.value
          : this.explanationCode,
      createdAtUtc: data.createdAtUtc.present
          ? data.createdAtUtc.value
          : this.createdAtUtc,
      updatedAtUtc: data.updatedAtUtc.present
          ? data.updatedAtUtc.value
          : this.updatedAtUtc,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ScheduleBlock(')
          ..write('id: $id, ')
          ..write('planVersionId: $planVersionId, ')
          ..write('taskId: $taskId, ')
          ..write('startAtUtc: $startAtUtc, ')
          ..write('endAtUtc: $endAtUtc, ')
          ..write('locked: $locked, ')
          ..write('explanationCode: $explanationCode, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    planVersionId,
    taskId,
    startAtUtc,
    endAtUtc,
    locked,
    explanationCode,
    createdAtUtc,
    updatedAtUtc,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ScheduleBlock &&
          other.id == this.id &&
          other.planVersionId == this.planVersionId &&
          other.taskId == this.taskId &&
          other.startAtUtc == this.startAtUtc &&
          other.endAtUtc == this.endAtUtc &&
          other.locked == this.locked &&
          other.explanationCode == this.explanationCode &&
          other.createdAtUtc == this.createdAtUtc &&
          other.updatedAtUtc == this.updatedAtUtc);
}

class ScheduleBlocksCompanion extends UpdateCompanion<ScheduleBlock> {
  final Value<String> id;
  final Value<String> planVersionId;
  final Value<String> taskId;
  final Value<int> startAtUtc;
  final Value<int> endAtUtc;
  final Value<bool> locked;
  final Value<String> explanationCode;
  final Value<int> createdAtUtc;
  final Value<int> updatedAtUtc;
  final Value<int> rowid;
  const ScheduleBlocksCompanion({
    this.id = const Value.absent(),
    this.planVersionId = const Value.absent(),
    this.taskId = const Value.absent(),
    this.startAtUtc = const Value.absent(),
    this.endAtUtc = const Value.absent(),
    this.locked = const Value.absent(),
    this.explanationCode = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ScheduleBlocksCompanion.insert({
    required String id,
    required String planVersionId,
    required String taskId,
    required int startAtUtc,
    required int endAtUtc,
    this.locked = const Value.absent(),
    required String explanationCode,
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       planVersionId = Value(planVersionId),
       taskId = Value(taskId),
       startAtUtc = Value(startAtUtc),
       endAtUtc = Value(endAtUtc),
       explanationCode = Value(explanationCode);
  static Insertable<ScheduleBlock> custom({
    Expression<String>? id,
    Expression<String>? planVersionId,
    Expression<String>? taskId,
    Expression<int>? startAtUtc,
    Expression<int>? endAtUtc,
    Expression<bool>? locked,
    Expression<String>? explanationCode,
    Expression<int>? createdAtUtc,
    Expression<int>? updatedAtUtc,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (planVersionId != null) 'plan_version_id': planVersionId,
      if (taskId != null) 'task_id': taskId,
      if (startAtUtc != null) 'start_at_utc': startAtUtc,
      if (endAtUtc != null) 'end_at_utc': endAtUtc,
      if (locked != null) 'locked': locked,
      if (explanationCode != null) 'explanation_code': explanationCode,
      if (createdAtUtc != null) 'created_at_utc': createdAtUtc,
      if (updatedAtUtc != null) 'updated_at_utc': updatedAtUtc,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ScheduleBlocksCompanion copyWith({
    Value<String>? id,
    Value<String>? planVersionId,
    Value<String>? taskId,
    Value<int>? startAtUtc,
    Value<int>? endAtUtc,
    Value<bool>? locked,
    Value<String>? explanationCode,
    Value<int>? createdAtUtc,
    Value<int>? updatedAtUtc,
    Value<int>? rowid,
  }) {
    return ScheduleBlocksCompanion(
      id: id ?? this.id,
      planVersionId: planVersionId ?? this.planVersionId,
      taskId: taskId ?? this.taskId,
      startAtUtc: startAtUtc ?? this.startAtUtc,
      endAtUtc: endAtUtc ?? this.endAtUtc,
      locked: locked ?? this.locked,
      explanationCode: explanationCode ?? this.explanationCode,
      createdAtUtc: createdAtUtc ?? this.createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (planVersionId.present) {
      map['plan_version_id'] = Variable<String>(planVersionId.value);
    }
    if (taskId.present) {
      map['task_id'] = Variable<String>(taskId.value);
    }
    if (startAtUtc.present) {
      map['start_at_utc'] = Variable<int>(startAtUtc.value);
    }
    if (endAtUtc.present) {
      map['end_at_utc'] = Variable<int>(endAtUtc.value);
    }
    if (locked.present) {
      map['locked'] = Variable<bool>(locked.value);
    }
    if (explanationCode.present) {
      map['explanation_code'] = Variable<String>(explanationCode.value);
    }
    if (createdAtUtc.present) {
      map['created_at_utc'] = Variable<int>(createdAtUtc.value);
    }
    if (updatedAtUtc.present) {
      map['updated_at_utc'] = Variable<int>(updatedAtUtc.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ScheduleBlocksCompanion(')
          ..write('id: $id, ')
          ..write('planVersionId: $planVersionId, ')
          ..write('taskId: $taskId, ')
          ..write('startAtUtc: $startAtUtc, ')
          ..write('endAtUtc: $endAtUtc, ')
          ..write('locked: $locked, ')
          ..write('explanationCode: $explanationCode, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TimeEntriesTable extends TimeEntries
    with TableInfo<$TimeEntriesTable, TimeEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TimeEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _taskIdMeta = const VerificationMeta('taskId');
  @override
  late final GeneratedColumn<String> taskId = GeneratedColumn<String>(
    'task_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES tasks (id)',
    ),
  );
  static const VerificationMeta _startedAtUtcMeta = const VerificationMeta(
    'startedAtUtc',
  );
  @override
  late final GeneratedColumn<int> startedAtUtc = GeneratedColumn<int>(
    'started_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endedAtUtcMeta = const VerificationMeta(
    'endedAtUtc',
  );
  @override
  late final GeneratedColumn<int> endedAtUtc = GeneratedColumn<int>(
    'ended_at_utc',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pausedMinutesMeta = const VerificationMeta(
    'pausedMinutes',
  );
  @override
  late final GeneratedColumn<int> pausedMinutes = GeneratedColumn<int>(
    'paused_minutes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recoveryStateMeta = const VerificationMeta(
    'recoveryState',
  );
  @override
  late final GeneratedColumn<String> recoveryState = GeneratedColumn<String>(
    'recovery_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtUtcMeta = const VerificationMeta(
    'createdAtUtc',
  );
  @override
  late final GeneratedColumn<int> createdAtUtc = GeneratedColumn<int>(
    'created_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  static const VerificationMeta _updatedAtUtcMeta = const VerificationMeta(
    'updatedAtUtc',
  );
  @override
  late final GeneratedColumn<int> updatedAtUtc = GeneratedColumn<int>(
    'updated_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(unsetTimestamp),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    taskId,
    startedAtUtc,
    endedAtUtc,
    pausedMinutes,
    source,
    recoveryState,
    createdAtUtc,
    updatedAtUtc,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'time_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<TimeEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('task_id')) {
      context.handle(
        _taskIdMeta,
        taskId.isAcceptableOrUnknown(data['task_id']!, _taskIdMeta),
      );
    } else if (isInserting) {
      context.missing(_taskIdMeta);
    }
    if (data.containsKey('started_at_utc')) {
      context.handle(
        _startedAtUtcMeta,
        startedAtUtc.isAcceptableOrUnknown(
          data['started_at_utc']!,
          _startedAtUtcMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_startedAtUtcMeta);
    }
    if (data.containsKey('ended_at_utc')) {
      context.handle(
        _endedAtUtcMeta,
        endedAtUtc.isAcceptableOrUnknown(
          data['ended_at_utc']!,
          _endedAtUtcMeta,
        ),
      );
    }
    if (data.containsKey('paused_minutes')) {
      context.handle(
        _pausedMinutesMeta,
        pausedMinutes.isAcceptableOrUnknown(
          data['paused_minutes']!,
          _pausedMinutesMeta,
        ),
      );
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('recovery_state')) {
      context.handle(
        _recoveryStateMeta,
        recoveryState.isAcceptableOrUnknown(
          data['recovery_state']!,
          _recoveryStateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_recoveryStateMeta);
    }
    if (data.containsKey('created_at_utc')) {
      context.handle(
        _createdAtUtcMeta,
        createdAtUtc.isAcceptableOrUnknown(
          data['created_at_utc']!,
          _createdAtUtcMeta,
        ),
      );
    }
    if (data.containsKey('updated_at_utc')) {
      context.handle(
        _updatedAtUtcMeta,
        updatedAtUtc.isAcceptableOrUnknown(
          data['updated_at_utc']!,
          _updatedAtUtcMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TimeEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TimeEntry(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      taskId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}task_id'],
      )!,
      startedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}started_at_utc'],
      )!,
      endedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}ended_at_utc'],
      ),
      pausedMinutes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}paused_minutes'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      recoveryState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}recovery_state'],
      )!,
      createdAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at_utc'],
      )!,
      updatedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_utc'],
      )!,
    );
  }

  @override
  $TimeEntriesTable createAlias(String alias) {
    return $TimeEntriesTable(attachedDatabase, alias);
  }
}

class TimeEntry extends DataClass implements Insertable<TimeEntry> {
  final String id;
  final String taskId;
  final int startedAtUtc;
  final int? endedAtUtc;
  final int pausedMinutes;
  final String source;
  final String recoveryState;
  final int createdAtUtc;
  final int updatedAtUtc;
  const TimeEntry({
    required this.id,
    required this.taskId,
    required this.startedAtUtc,
    this.endedAtUtc,
    required this.pausedMinutes,
    required this.source,
    required this.recoveryState,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['task_id'] = Variable<String>(taskId);
    map['started_at_utc'] = Variable<int>(startedAtUtc);
    if (!nullToAbsent || endedAtUtc != null) {
      map['ended_at_utc'] = Variable<int>(endedAtUtc);
    }
    map['paused_minutes'] = Variable<int>(pausedMinutes);
    map['source'] = Variable<String>(source);
    map['recovery_state'] = Variable<String>(recoveryState);
    map['created_at_utc'] = Variable<int>(createdAtUtc);
    map['updated_at_utc'] = Variable<int>(updatedAtUtc);
    return map;
  }

  TimeEntriesCompanion toCompanion(bool nullToAbsent) {
    return TimeEntriesCompanion(
      id: Value(id),
      taskId: Value(taskId),
      startedAtUtc: Value(startedAtUtc),
      endedAtUtc: endedAtUtc == null && nullToAbsent
          ? const Value.absent()
          : Value(endedAtUtc),
      pausedMinutes: Value(pausedMinutes),
      source: Value(source),
      recoveryState: Value(recoveryState),
      createdAtUtc: Value(createdAtUtc),
      updatedAtUtc: Value(updatedAtUtc),
    );
  }

  factory TimeEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TimeEntry(
      id: serializer.fromJson<String>(json['id']),
      taskId: serializer.fromJson<String>(json['taskId']),
      startedAtUtc: serializer.fromJson<int>(json['startedAtUtc']),
      endedAtUtc: serializer.fromJson<int?>(json['endedAtUtc']),
      pausedMinutes: serializer.fromJson<int>(json['pausedMinutes']),
      source: serializer.fromJson<String>(json['source']),
      recoveryState: serializer.fromJson<String>(json['recoveryState']),
      createdAtUtc: serializer.fromJson<int>(json['createdAtUtc']),
      updatedAtUtc: serializer.fromJson<int>(json['updatedAtUtc']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'taskId': serializer.toJson<String>(taskId),
      'startedAtUtc': serializer.toJson<int>(startedAtUtc),
      'endedAtUtc': serializer.toJson<int?>(endedAtUtc),
      'pausedMinutes': serializer.toJson<int>(pausedMinutes),
      'source': serializer.toJson<String>(source),
      'recoveryState': serializer.toJson<String>(recoveryState),
      'createdAtUtc': serializer.toJson<int>(createdAtUtc),
      'updatedAtUtc': serializer.toJson<int>(updatedAtUtc),
    };
  }

  TimeEntry copyWith({
    String? id,
    String? taskId,
    int? startedAtUtc,
    Value<int?> endedAtUtc = const Value.absent(),
    int? pausedMinutes,
    String? source,
    String? recoveryState,
    int? createdAtUtc,
    int? updatedAtUtc,
  }) => TimeEntry(
    id: id ?? this.id,
    taskId: taskId ?? this.taskId,
    startedAtUtc: startedAtUtc ?? this.startedAtUtc,
    endedAtUtc: endedAtUtc.present ? endedAtUtc.value : this.endedAtUtc,
    pausedMinutes: pausedMinutes ?? this.pausedMinutes,
    source: source ?? this.source,
    recoveryState: recoveryState ?? this.recoveryState,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
  TimeEntry copyWithCompanion(TimeEntriesCompanion data) {
    return TimeEntry(
      id: data.id.present ? data.id.value : this.id,
      taskId: data.taskId.present ? data.taskId.value : this.taskId,
      startedAtUtc: data.startedAtUtc.present
          ? data.startedAtUtc.value
          : this.startedAtUtc,
      endedAtUtc: data.endedAtUtc.present
          ? data.endedAtUtc.value
          : this.endedAtUtc,
      pausedMinutes: data.pausedMinutes.present
          ? data.pausedMinutes.value
          : this.pausedMinutes,
      source: data.source.present ? data.source.value : this.source,
      recoveryState: data.recoveryState.present
          ? data.recoveryState.value
          : this.recoveryState,
      createdAtUtc: data.createdAtUtc.present
          ? data.createdAtUtc.value
          : this.createdAtUtc,
      updatedAtUtc: data.updatedAtUtc.present
          ? data.updatedAtUtc.value
          : this.updatedAtUtc,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TimeEntry(')
          ..write('id: $id, ')
          ..write('taskId: $taskId, ')
          ..write('startedAtUtc: $startedAtUtc, ')
          ..write('endedAtUtc: $endedAtUtc, ')
          ..write('pausedMinutes: $pausedMinutes, ')
          ..write('source: $source, ')
          ..write('recoveryState: $recoveryState, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    taskId,
    startedAtUtc,
    endedAtUtc,
    pausedMinutes,
    source,
    recoveryState,
    createdAtUtc,
    updatedAtUtc,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TimeEntry &&
          other.id == this.id &&
          other.taskId == this.taskId &&
          other.startedAtUtc == this.startedAtUtc &&
          other.endedAtUtc == this.endedAtUtc &&
          other.pausedMinutes == this.pausedMinutes &&
          other.source == this.source &&
          other.recoveryState == this.recoveryState &&
          other.createdAtUtc == this.createdAtUtc &&
          other.updatedAtUtc == this.updatedAtUtc);
}

class TimeEntriesCompanion extends UpdateCompanion<TimeEntry> {
  final Value<String> id;
  final Value<String> taskId;
  final Value<int> startedAtUtc;
  final Value<int?> endedAtUtc;
  final Value<int> pausedMinutes;
  final Value<String> source;
  final Value<String> recoveryState;
  final Value<int> createdAtUtc;
  final Value<int> updatedAtUtc;
  final Value<int> rowid;
  const TimeEntriesCompanion({
    this.id = const Value.absent(),
    this.taskId = const Value.absent(),
    this.startedAtUtc = const Value.absent(),
    this.endedAtUtc = const Value.absent(),
    this.pausedMinutes = const Value.absent(),
    this.source = const Value.absent(),
    this.recoveryState = const Value.absent(),
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TimeEntriesCompanion.insert({
    required String id,
    required String taskId,
    required int startedAtUtc,
    this.endedAtUtc = const Value.absent(),
    this.pausedMinutes = const Value.absent(),
    required String source,
    required String recoveryState,
    this.createdAtUtc = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       taskId = Value(taskId),
       startedAtUtc = Value(startedAtUtc),
       source = Value(source),
       recoveryState = Value(recoveryState);
  static Insertable<TimeEntry> custom({
    Expression<String>? id,
    Expression<String>? taskId,
    Expression<int>? startedAtUtc,
    Expression<int>? endedAtUtc,
    Expression<int>? pausedMinutes,
    Expression<String>? source,
    Expression<String>? recoveryState,
    Expression<int>? createdAtUtc,
    Expression<int>? updatedAtUtc,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (taskId != null) 'task_id': taskId,
      if (startedAtUtc != null) 'started_at_utc': startedAtUtc,
      if (endedAtUtc != null) 'ended_at_utc': endedAtUtc,
      if (pausedMinutes != null) 'paused_minutes': pausedMinutes,
      if (source != null) 'source': source,
      if (recoveryState != null) 'recovery_state': recoveryState,
      if (createdAtUtc != null) 'created_at_utc': createdAtUtc,
      if (updatedAtUtc != null) 'updated_at_utc': updatedAtUtc,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TimeEntriesCompanion copyWith({
    Value<String>? id,
    Value<String>? taskId,
    Value<int>? startedAtUtc,
    Value<int?>? endedAtUtc,
    Value<int>? pausedMinutes,
    Value<String>? source,
    Value<String>? recoveryState,
    Value<int>? createdAtUtc,
    Value<int>? updatedAtUtc,
    Value<int>? rowid,
  }) {
    return TimeEntriesCompanion(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      startedAtUtc: startedAtUtc ?? this.startedAtUtc,
      endedAtUtc: endedAtUtc ?? this.endedAtUtc,
      pausedMinutes: pausedMinutes ?? this.pausedMinutes,
      source: source ?? this.source,
      recoveryState: recoveryState ?? this.recoveryState,
      createdAtUtc: createdAtUtc ?? this.createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (taskId.present) {
      map['task_id'] = Variable<String>(taskId.value);
    }
    if (startedAtUtc.present) {
      map['started_at_utc'] = Variable<int>(startedAtUtc.value);
    }
    if (endedAtUtc.present) {
      map['ended_at_utc'] = Variable<int>(endedAtUtc.value);
    }
    if (pausedMinutes.present) {
      map['paused_minutes'] = Variable<int>(pausedMinutes.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (recoveryState.present) {
      map['recovery_state'] = Variable<String>(recoveryState.value);
    }
    if (createdAtUtc.present) {
      map['created_at_utc'] = Variable<int>(createdAtUtc.value);
    }
    if (updatedAtUtc.present) {
      map['updated_at_utc'] = Variable<int>(updatedAtUtc.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TimeEntriesCompanion(')
          ..write('id: $id, ')
          ..write('taskId: $taskId, ')
          ..write('startedAtUtc: $startedAtUtc, ')
          ..write('endedAtUtc: $endedAtUtc, ')
          ..write('pausedMinutes: $pausedMinutes, ')
          ..write('source: $source, ')
          ..write('recoveryState: $recoveryState, ')
          ..write('createdAtUtc: $createdAtUtc, ')
          ..write('updatedAtUtc: $updatedAtUtc, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TaskCorrectionsTable extends TaskCorrections
    with TableInfo<$TaskCorrectionsTable, TaskCorrection> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TaskCorrectionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _taskIdMeta = const VerificationMeta('taskId');
  @override
  late final GeneratedColumn<String> taskId = GeneratedColumn<String>(
    'task_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES tasks (id)',
    ),
  );
  static const VerificationMeta _previousMinutesMeta = const VerificationMeta(
    'previousMinutes',
  );
  @override
  late final GeneratedColumn<int> previousMinutes = GeneratedColumn<int>(
    'previous_minutes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _correctedMinutesMeta = const VerificationMeta(
    'correctedMinutes',
  );
  @override
  late final GeneratedColumn<int> correctedMinutes = GeneratedColumn<int>(
    'corrected_minutes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _correctedAtUtcMeta = const VerificationMeta(
    'correctedAtUtc',
  );
  @override
  late final GeneratedColumn<int> correctedAtUtc = GeneratedColumn<int>(
    'corrected_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    taskId,
    previousMinutes,
    correctedMinutes,
    correctedAtUtc,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'task_corrections';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskCorrection> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('task_id')) {
      context.handle(
        _taskIdMeta,
        taskId.isAcceptableOrUnknown(data['task_id']!, _taskIdMeta),
      );
    } else if (isInserting) {
      context.missing(_taskIdMeta);
    }
    if (data.containsKey('previous_minutes')) {
      context.handle(
        _previousMinutesMeta,
        previousMinutes.isAcceptableOrUnknown(
          data['previous_minutes']!,
          _previousMinutesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_previousMinutesMeta);
    }
    if (data.containsKey('corrected_minutes')) {
      context.handle(
        _correctedMinutesMeta,
        correctedMinutes.isAcceptableOrUnknown(
          data['corrected_minutes']!,
          _correctedMinutesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_correctedMinutesMeta);
    }
    if (data.containsKey('corrected_at_utc')) {
      context.handle(
        _correctedAtUtcMeta,
        correctedAtUtc.isAcceptableOrUnknown(
          data['corrected_at_utc']!,
          _correctedAtUtcMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_correctedAtUtcMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TaskCorrection map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskCorrection(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      taskId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}task_id'],
      )!,
      previousMinutes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}previous_minutes'],
      )!,
      correctedMinutes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}corrected_minutes'],
      )!,
      correctedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}corrected_at_utc'],
      )!,
    );
  }

  @override
  $TaskCorrectionsTable createAlias(String alias) {
    return $TaskCorrectionsTable(attachedDatabase, alias);
  }
}

class TaskCorrection extends DataClass implements Insertable<TaskCorrection> {
  final String id;
  final String taskId;
  final int previousMinutes;
  final int correctedMinutes;
  final int correctedAtUtc;
  const TaskCorrection({
    required this.id,
    required this.taskId,
    required this.previousMinutes,
    required this.correctedMinutes,
    required this.correctedAtUtc,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['task_id'] = Variable<String>(taskId);
    map['previous_minutes'] = Variable<int>(previousMinutes);
    map['corrected_minutes'] = Variable<int>(correctedMinutes);
    map['corrected_at_utc'] = Variable<int>(correctedAtUtc);
    return map;
  }

  TaskCorrectionsCompanion toCompanion(bool nullToAbsent) {
    return TaskCorrectionsCompanion(
      id: Value(id),
      taskId: Value(taskId),
      previousMinutes: Value(previousMinutes),
      correctedMinutes: Value(correctedMinutes),
      correctedAtUtc: Value(correctedAtUtc),
    );
  }

  factory TaskCorrection.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskCorrection(
      id: serializer.fromJson<String>(json['id']),
      taskId: serializer.fromJson<String>(json['taskId']),
      previousMinutes: serializer.fromJson<int>(json['previousMinutes']),
      correctedMinutes: serializer.fromJson<int>(json['correctedMinutes']),
      correctedAtUtc: serializer.fromJson<int>(json['correctedAtUtc']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'taskId': serializer.toJson<String>(taskId),
      'previousMinutes': serializer.toJson<int>(previousMinutes),
      'correctedMinutes': serializer.toJson<int>(correctedMinutes),
      'correctedAtUtc': serializer.toJson<int>(correctedAtUtc),
    };
  }

  TaskCorrection copyWith({
    String? id,
    String? taskId,
    int? previousMinutes,
    int? correctedMinutes,
    int? correctedAtUtc,
  }) => TaskCorrection(
    id: id ?? this.id,
    taskId: taskId ?? this.taskId,
    previousMinutes: previousMinutes ?? this.previousMinutes,
    correctedMinutes: correctedMinutes ?? this.correctedMinutes,
    correctedAtUtc: correctedAtUtc ?? this.correctedAtUtc,
  );
  TaskCorrection copyWithCompanion(TaskCorrectionsCompanion data) {
    return TaskCorrection(
      id: data.id.present ? data.id.value : this.id,
      taskId: data.taskId.present ? data.taskId.value : this.taskId,
      previousMinutes: data.previousMinutes.present
          ? data.previousMinutes.value
          : this.previousMinutes,
      correctedMinutes: data.correctedMinutes.present
          ? data.correctedMinutes.value
          : this.correctedMinutes,
      correctedAtUtc: data.correctedAtUtc.present
          ? data.correctedAtUtc.value
          : this.correctedAtUtc,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskCorrection(')
          ..write('id: $id, ')
          ..write('taskId: $taskId, ')
          ..write('previousMinutes: $previousMinutes, ')
          ..write('correctedMinutes: $correctedMinutes, ')
          ..write('correctedAtUtc: $correctedAtUtc')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    taskId,
    previousMinutes,
    correctedMinutes,
    correctedAtUtc,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskCorrection &&
          other.id == this.id &&
          other.taskId == this.taskId &&
          other.previousMinutes == this.previousMinutes &&
          other.correctedMinutes == this.correctedMinutes &&
          other.correctedAtUtc == this.correctedAtUtc);
}

class TaskCorrectionsCompanion extends UpdateCompanion<TaskCorrection> {
  final Value<String> id;
  final Value<String> taskId;
  final Value<int> previousMinutes;
  final Value<int> correctedMinutes;
  final Value<int> correctedAtUtc;
  final Value<int> rowid;
  const TaskCorrectionsCompanion({
    this.id = const Value.absent(),
    this.taskId = const Value.absent(),
    this.previousMinutes = const Value.absent(),
    this.correctedMinutes = const Value.absent(),
    this.correctedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TaskCorrectionsCompanion.insert({
    required String id,
    required String taskId,
    required int previousMinutes,
    required int correctedMinutes,
    required int correctedAtUtc,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       taskId = Value(taskId),
       previousMinutes = Value(previousMinutes),
       correctedMinutes = Value(correctedMinutes),
       correctedAtUtc = Value(correctedAtUtc);
  static Insertable<TaskCorrection> custom({
    Expression<String>? id,
    Expression<String>? taskId,
    Expression<int>? previousMinutes,
    Expression<int>? correctedMinutes,
    Expression<int>? correctedAtUtc,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (taskId != null) 'task_id': taskId,
      if (previousMinutes != null) 'previous_minutes': previousMinutes,
      if (correctedMinutes != null) 'corrected_minutes': correctedMinutes,
      if (correctedAtUtc != null) 'corrected_at_utc': correctedAtUtc,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TaskCorrectionsCompanion copyWith({
    Value<String>? id,
    Value<String>? taskId,
    Value<int>? previousMinutes,
    Value<int>? correctedMinutes,
    Value<int>? correctedAtUtc,
    Value<int>? rowid,
  }) {
    return TaskCorrectionsCompanion(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      previousMinutes: previousMinutes ?? this.previousMinutes,
      correctedMinutes: correctedMinutes ?? this.correctedMinutes,
      correctedAtUtc: correctedAtUtc ?? this.correctedAtUtc,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (taskId.present) {
      map['task_id'] = Variable<String>(taskId.value);
    }
    if (previousMinutes.present) {
      map['previous_minutes'] = Variable<int>(previousMinutes.value);
    }
    if (correctedMinutes.present) {
      map['corrected_minutes'] = Variable<int>(correctedMinutes.value);
    }
    if (correctedAtUtc.present) {
      map['corrected_at_utc'] = Variable<int>(correctedAtUtc.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TaskCorrectionsCompanion(')
          ..write('id: $id, ')
          ..write('taskId: $taskId, ')
          ..write('previousMinutes: $previousMinutes, ')
          ..write('correctedMinutes: $correctedMinutes, ')
          ..write('correctedAtUtc: $correctedAtUtc, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PreferenceEvidenceTable extends PreferenceEvidence
    with TableInfo<$PreferenceEvidenceTable, PreferenceEvidenceData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PreferenceEvidenceTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subjectKeyMeta = const VerificationMeta(
    'subjectKey',
  );
  @override
  late final GeneratedColumn<String> subjectKey = GeneratedColumn<String>(
    'subject_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _observedAtUtcMeta = const VerificationMeta(
    'observedAtUtc',
  );
  @override
  late final GeneratedColumn<int> observedAtUtc = GeneratedColumn<int>(
    'observed_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _numericValueMeta = const VerificationMeta(
    'numericValue',
  );
  @override
  late final GeneratedColumn<double> numericValue = GeneratedColumn<double>(
    'numeric_value',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _specialDayMeta = const VerificationMeta(
    'specialDay',
  );
  @override
  late final GeneratedColumn<bool> specialDay = GeneratedColumn<bool>(
    'special_day',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("special_day" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _metadataJsonMeta = const VerificationMeta(
    'metadataJson',
  );
  @override
  late final GeneratedColumn<String> metadataJson = GeneratedColumn<String>(
    'metadata_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    subjectKey,
    observedAtUtc,
    numericValue,
    specialDay,
    metadataJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'preference_evidence';
  @override
  VerificationContext validateIntegrity(
    Insertable<PreferenceEvidenceData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('subject_key')) {
      context.handle(
        _subjectKeyMeta,
        subjectKey.isAcceptableOrUnknown(data['subject_key']!, _subjectKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_subjectKeyMeta);
    }
    if (data.containsKey('observed_at_utc')) {
      context.handle(
        _observedAtUtcMeta,
        observedAtUtc.isAcceptableOrUnknown(
          data['observed_at_utc']!,
          _observedAtUtcMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_observedAtUtcMeta);
    }
    if (data.containsKey('numeric_value')) {
      context.handle(
        _numericValueMeta,
        numericValue.isAcceptableOrUnknown(
          data['numeric_value']!,
          _numericValueMeta,
        ),
      );
    }
    if (data.containsKey('special_day')) {
      context.handle(
        _specialDayMeta,
        specialDay.isAcceptableOrUnknown(data['special_day']!, _specialDayMeta),
      );
    }
    if (data.containsKey('metadata_json')) {
      context.handle(
        _metadataJsonMeta,
        metadataJson.isAcceptableOrUnknown(
          data['metadata_json']!,
          _metadataJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_metadataJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PreferenceEvidenceData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PreferenceEvidenceData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      subjectKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject_key'],
      )!,
      observedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}observed_at_utc'],
      )!,
      numericValue: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}numeric_value'],
      ),
      specialDay: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}special_day'],
      )!,
      metadataJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}metadata_json'],
      )!,
    );
  }

  @override
  $PreferenceEvidenceTable createAlias(String alias) {
    return $PreferenceEvidenceTable(attachedDatabase, alias);
  }
}

class PreferenceEvidenceData extends DataClass
    implements Insertable<PreferenceEvidenceData> {
  final String id;
  final String kind;
  final String subjectKey;
  final int observedAtUtc;
  final double? numericValue;
  final bool specialDay;
  final String metadataJson;
  const PreferenceEvidenceData({
    required this.id,
    required this.kind,
    required this.subjectKey,
    required this.observedAtUtc,
    this.numericValue,
    required this.specialDay,
    required this.metadataJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['kind'] = Variable<String>(kind);
    map['subject_key'] = Variable<String>(subjectKey);
    map['observed_at_utc'] = Variable<int>(observedAtUtc);
    if (!nullToAbsent || numericValue != null) {
      map['numeric_value'] = Variable<double>(numericValue);
    }
    map['special_day'] = Variable<bool>(specialDay);
    map['metadata_json'] = Variable<String>(metadataJson);
    return map;
  }

  PreferenceEvidenceCompanion toCompanion(bool nullToAbsent) {
    return PreferenceEvidenceCompanion(
      id: Value(id),
      kind: Value(kind),
      subjectKey: Value(subjectKey),
      observedAtUtc: Value(observedAtUtc),
      numericValue: numericValue == null && nullToAbsent
          ? const Value.absent()
          : Value(numericValue),
      specialDay: Value(specialDay),
      metadataJson: Value(metadataJson),
    );
  }

  factory PreferenceEvidenceData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PreferenceEvidenceData(
      id: serializer.fromJson<String>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      subjectKey: serializer.fromJson<String>(json['subjectKey']),
      observedAtUtc: serializer.fromJson<int>(json['observedAtUtc']),
      numericValue: serializer.fromJson<double?>(json['numericValue']),
      specialDay: serializer.fromJson<bool>(json['specialDay']),
      metadataJson: serializer.fromJson<String>(json['metadataJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'kind': serializer.toJson<String>(kind),
      'subjectKey': serializer.toJson<String>(subjectKey),
      'observedAtUtc': serializer.toJson<int>(observedAtUtc),
      'numericValue': serializer.toJson<double?>(numericValue),
      'specialDay': serializer.toJson<bool>(specialDay),
      'metadataJson': serializer.toJson<String>(metadataJson),
    };
  }

  PreferenceEvidenceData copyWith({
    String? id,
    String? kind,
    String? subjectKey,
    int? observedAtUtc,
    Value<double?> numericValue = const Value.absent(),
    bool? specialDay,
    String? metadataJson,
  }) => PreferenceEvidenceData(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    subjectKey: subjectKey ?? this.subjectKey,
    observedAtUtc: observedAtUtc ?? this.observedAtUtc,
    numericValue: numericValue.present ? numericValue.value : this.numericValue,
    specialDay: specialDay ?? this.specialDay,
    metadataJson: metadataJson ?? this.metadataJson,
  );
  PreferenceEvidenceData copyWithCompanion(PreferenceEvidenceCompanion data) {
    return PreferenceEvidenceData(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      subjectKey: data.subjectKey.present
          ? data.subjectKey.value
          : this.subjectKey,
      observedAtUtc: data.observedAtUtc.present
          ? data.observedAtUtc.value
          : this.observedAtUtc,
      numericValue: data.numericValue.present
          ? data.numericValue.value
          : this.numericValue,
      specialDay: data.specialDay.present
          ? data.specialDay.value
          : this.specialDay,
      metadataJson: data.metadataJson.present
          ? data.metadataJson.value
          : this.metadataJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PreferenceEvidenceData(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('subjectKey: $subjectKey, ')
          ..write('observedAtUtc: $observedAtUtc, ')
          ..write('numericValue: $numericValue, ')
          ..write('specialDay: $specialDay, ')
          ..write('metadataJson: $metadataJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    subjectKey,
    observedAtUtc,
    numericValue,
    specialDay,
    metadataJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PreferenceEvidenceData &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.subjectKey == this.subjectKey &&
          other.observedAtUtc == this.observedAtUtc &&
          other.numericValue == this.numericValue &&
          other.specialDay == this.specialDay &&
          other.metadataJson == this.metadataJson);
}

class PreferenceEvidenceCompanion
    extends UpdateCompanion<PreferenceEvidenceData> {
  final Value<String> id;
  final Value<String> kind;
  final Value<String> subjectKey;
  final Value<int> observedAtUtc;
  final Value<double?> numericValue;
  final Value<bool> specialDay;
  final Value<String> metadataJson;
  final Value<int> rowid;
  const PreferenceEvidenceCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.subjectKey = const Value.absent(),
    this.observedAtUtc = const Value.absent(),
    this.numericValue = const Value.absent(),
    this.specialDay = const Value.absent(),
    this.metadataJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PreferenceEvidenceCompanion.insert({
    required String id,
    required String kind,
    required String subjectKey,
    required int observedAtUtc,
    this.numericValue = const Value.absent(),
    this.specialDay = const Value.absent(),
    required String metadataJson,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       kind = Value(kind),
       subjectKey = Value(subjectKey),
       observedAtUtc = Value(observedAtUtc),
       metadataJson = Value(metadataJson);
  static Insertable<PreferenceEvidenceData> custom({
    Expression<String>? id,
    Expression<String>? kind,
    Expression<String>? subjectKey,
    Expression<int>? observedAtUtc,
    Expression<double>? numericValue,
    Expression<bool>? specialDay,
    Expression<String>? metadataJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (subjectKey != null) 'subject_key': subjectKey,
      if (observedAtUtc != null) 'observed_at_utc': observedAtUtc,
      if (numericValue != null) 'numeric_value': numericValue,
      if (specialDay != null) 'special_day': specialDay,
      if (metadataJson != null) 'metadata_json': metadataJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PreferenceEvidenceCompanion copyWith({
    Value<String>? id,
    Value<String>? kind,
    Value<String>? subjectKey,
    Value<int>? observedAtUtc,
    Value<double?>? numericValue,
    Value<bool>? specialDay,
    Value<String>? metadataJson,
    Value<int>? rowid,
  }) {
    return PreferenceEvidenceCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      subjectKey: subjectKey ?? this.subjectKey,
      observedAtUtc: observedAtUtc ?? this.observedAtUtc,
      numericValue: numericValue ?? this.numericValue,
      specialDay: specialDay ?? this.specialDay,
      metadataJson: metadataJson ?? this.metadataJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (subjectKey.present) {
      map['subject_key'] = Variable<String>(subjectKey.value);
    }
    if (observedAtUtc.present) {
      map['observed_at_utc'] = Variable<int>(observedAtUtc.value);
    }
    if (numericValue.present) {
      map['numeric_value'] = Variable<double>(numericValue.value);
    }
    if (specialDay.present) {
      map['special_day'] = Variable<bool>(specialDay.value);
    }
    if (metadataJson.present) {
      map['metadata_json'] = Variable<String>(metadataJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PreferenceEvidenceCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('subjectKey: $subjectKey, ')
          ..write('observedAtUtc: $observedAtUtc, ')
          ..write('numericValue: $numericValue, ')
          ..write('specialDay: $specialDay, ')
          ..write('metadataJson: $metadataJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PreferenceRulesTable extends PreferenceRules
    with TableInfo<$PreferenceRulesTable, PreferenceRule> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PreferenceRulesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subjectKeyMeta = const VerificationMeta(
    'subjectKey',
  );
  @override
  late final GeneratedColumn<String> subjectKey = GeneratedColumn<String>(
    'subject_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueJsonMeta = const VerificationMeta(
    'valueJson',
  );
  @override
  late final GeneratedColumn<String> valueJson = GeneratedColumn<String>(
    'value_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _confidenceMeta = const VerificationMeta(
    'confidence',
  );
  @override
  late final GeneratedColumn<double> confidence = GeneratedColumn<double>(
    'confidence',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtUtcMeta = const VerificationMeta(
    'updatedAtUtc',
  );
  @override
  late final GeneratedColumn<int> updatedAtUtc = GeneratedColumn<int>(
    'updated_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    subjectKey,
    valueJson,
    confidence,
    status,
    source,
    updatedAtUtc,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'preference_rules';
  @override
  VerificationContext validateIntegrity(
    Insertable<PreferenceRule> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('subject_key')) {
      context.handle(
        _subjectKeyMeta,
        subjectKey.isAcceptableOrUnknown(data['subject_key']!, _subjectKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_subjectKeyMeta);
    }
    if (data.containsKey('value_json')) {
      context.handle(
        _valueJsonMeta,
        valueJson.isAcceptableOrUnknown(data['value_json']!, _valueJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_valueJsonMeta);
    }
    if (data.containsKey('confidence')) {
      context.handle(
        _confidenceMeta,
        confidence.isAcceptableOrUnknown(data['confidence']!, _confidenceMeta),
      );
    } else if (isInserting) {
      context.missing(_confidenceMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('updated_at_utc')) {
      context.handle(
        _updatedAtUtcMeta,
        updatedAtUtc.isAcceptableOrUnknown(
          data['updated_at_utc']!,
          _updatedAtUtcMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtUtcMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PreferenceRule map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PreferenceRule(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      subjectKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject_key'],
      )!,
      valueJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value_json'],
      )!,
      confidence: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}confidence'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      updatedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_utc'],
      )!,
    );
  }

  @override
  $PreferenceRulesTable createAlias(String alias) {
    return $PreferenceRulesTable(attachedDatabase, alias);
  }
}

class PreferenceRule extends DataClass implements Insertable<PreferenceRule> {
  final String id;
  final String kind;
  final String subjectKey;
  final String valueJson;
  final double confidence;
  final String status;
  final String source;
  final int updatedAtUtc;
  const PreferenceRule({
    required this.id,
    required this.kind,
    required this.subjectKey,
    required this.valueJson,
    required this.confidence,
    required this.status,
    required this.source,
    required this.updatedAtUtc,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['kind'] = Variable<String>(kind);
    map['subject_key'] = Variable<String>(subjectKey);
    map['value_json'] = Variable<String>(valueJson);
    map['confidence'] = Variable<double>(confidence);
    map['status'] = Variable<String>(status);
    map['source'] = Variable<String>(source);
    map['updated_at_utc'] = Variable<int>(updatedAtUtc);
    return map;
  }

  PreferenceRulesCompanion toCompanion(bool nullToAbsent) {
    return PreferenceRulesCompanion(
      id: Value(id),
      kind: Value(kind),
      subjectKey: Value(subjectKey),
      valueJson: Value(valueJson),
      confidence: Value(confidence),
      status: Value(status),
      source: Value(source),
      updatedAtUtc: Value(updatedAtUtc),
    );
  }

  factory PreferenceRule.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PreferenceRule(
      id: serializer.fromJson<String>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      subjectKey: serializer.fromJson<String>(json['subjectKey']),
      valueJson: serializer.fromJson<String>(json['valueJson']),
      confidence: serializer.fromJson<double>(json['confidence']),
      status: serializer.fromJson<String>(json['status']),
      source: serializer.fromJson<String>(json['source']),
      updatedAtUtc: serializer.fromJson<int>(json['updatedAtUtc']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'kind': serializer.toJson<String>(kind),
      'subjectKey': serializer.toJson<String>(subjectKey),
      'valueJson': serializer.toJson<String>(valueJson),
      'confidence': serializer.toJson<double>(confidence),
      'status': serializer.toJson<String>(status),
      'source': serializer.toJson<String>(source),
      'updatedAtUtc': serializer.toJson<int>(updatedAtUtc),
    };
  }

  PreferenceRule copyWith({
    String? id,
    String? kind,
    String? subjectKey,
    String? valueJson,
    double? confidence,
    String? status,
    String? source,
    int? updatedAtUtc,
  }) => PreferenceRule(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    subjectKey: subjectKey ?? this.subjectKey,
    valueJson: valueJson ?? this.valueJson,
    confidence: confidence ?? this.confidence,
    status: status ?? this.status,
    source: source ?? this.source,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
  PreferenceRule copyWithCompanion(PreferenceRulesCompanion data) {
    return PreferenceRule(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      subjectKey: data.subjectKey.present
          ? data.subjectKey.value
          : this.subjectKey,
      valueJson: data.valueJson.present ? data.valueJson.value : this.valueJson,
      confidence: data.confidence.present
          ? data.confidence.value
          : this.confidence,
      status: data.status.present ? data.status.value : this.status,
      source: data.source.present ? data.source.value : this.source,
      updatedAtUtc: data.updatedAtUtc.present
          ? data.updatedAtUtc.value
          : this.updatedAtUtc,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PreferenceRule(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('subjectKey: $subjectKey, ')
          ..write('valueJson: $valueJson, ')
          ..write('confidence: $confidence, ')
          ..write('status: $status, ')
          ..write('source: $source, ')
          ..write('updatedAtUtc: $updatedAtUtc')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    subjectKey,
    valueJson,
    confidence,
    status,
    source,
    updatedAtUtc,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PreferenceRule &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.subjectKey == this.subjectKey &&
          other.valueJson == this.valueJson &&
          other.confidence == this.confidence &&
          other.status == this.status &&
          other.source == this.source &&
          other.updatedAtUtc == this.updatedAtUtc);
}

class PreferenceRulesCompanion extends UpdateCompanion<PreferenceRule> {
  final Value<String> id;
  final Value<String> kind;
  final Value<String> subjectKey;
  final Value<String> valueJson;
  final Value<double> confidence;
  final Value<String> status;
  final Value<String> source;
  final Value<int> updatedAtUtc;
  final Value<int> rowid;
  const PreferenceRulesCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.subjectKey = const Value.absent(),
    this.valueJson = const Value.absent(),
    this.confidence = const Value.absent(),
    this.status = const Value.absent(),
    this.source = const Value.absent(),
    this.updatedAtUtc = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PreferenceRulesCompanion.insert({
    required String id,
    required String kind,
    required String subjectKey,
    required String valueJson,
    required double confidence,
    required String status,
    required String source,
    required int updatedAtUtc,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       kind = Value(kind),
       subjectKey = Value(subjectKey),
       valueJson = Value(valueJson),
       confidence = Value(confidence),
       status = Value(status),
       source = Value(source),
       updatedAtUtc = Value(updatedAtUtc);
  static Insertable<PreferenceRule> custom({
    Expression<String>? id,
    Expression<String>? kind,
    Expression<String>? subjectKey,
    Expression<String>? valueJson,
    Expression<double>? confidence,
    Expression<String>? status,
    Expression<String>? source,
    Expression<int>? updatedAtUtc,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (subjectKey != null) 'subject_key': subjectKey,
      if (valueJson != null) 'value_json': valueJson,
      if (confidence != null) 'confidence': confidence,
      if (status != null) 'status': status,
      if (source != null) 'source': source,
      if (updatedAtUtc != null) 'updated_at_utc': updatedAtUtc,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PreferenceRulesCompanion copyWith({
    Value<String>? id,
    Value<String>? kind,
    Value<String>? subjectKey,
    Value<String>? valueJson,
    Value<double>? confidence,
    Value<String>? status,
    Value<String>? source,
    Value<int>? updatedAtUtc,
    Value<int>? rowid,
  }) {
    return PreferenceRulesCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      subjectKey: subjectKey ?? this.subjectKey,
      valueJson: valueJson ?? this.valueJson,
      confidence: confidence ?? this.confidence,
      status: status ?? this.status,
      source: source ?? this.source,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (subjectKey.present) {
      map['subject_key'] = Variable<String>(subjectKey.value);
    }
    if (valueJson.present) {
      map['value_json'] = Variable<String>(valueJson.value);
    }
    if (confidence.present) {
      map['confidence'] = Variable<double>(confidence.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (updatedAtUtc.present) {
      map['updated_at_utc'] = Variable<int>(updatedAtUtc.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PreferenceRulesCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('subjectKey: $subjectKey, ')
          ..write('valueJson: $valueJson, ')
          ..write('confidence: $confidence, ')
          ..write('status: $status, ')
          ..write('source: $source, ')
          ..write('updatedAtUtc: $updatedAtUtc, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ChangeLogTable extends ChangeLog
    with TableInfo<$ChangeLogTable, ChangeLogData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChangeLogTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityTypeMeta = const VerificationMeta(
    'entityType',
  );
  @override
  late final GeneratedColumn<String> entityType = GeneratedColumn<String>(
    'entity_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityIdMeta = const VerificationMeta(
    'entityId',
  );
  @override
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
    'entity_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _operationMeta = const VerificationMeta(
    'operation',
  );
  @override
  late final GeneratedColumn<String> operation = GeneratedColumn<String>(
    'operation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _changedAtUtcMeta = const VerificationMeta(
    'changedAtUtc',
  );
  @override
  late final GeneratedColumn<int> changedAtUtc = GeneratedColumn<int>(
    'changed_at_utc',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _revisionMeta = const VerificationMeta(
    'revision',
  );
  @override
  late final GeneratedColumn<int> revision = GeneratedColumn<int>(
    'revision',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    entityType,
    entityId,
    operation,
    changedAtUtc,
    revision,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'change_log';
  @override
  VerificationContext validateIntegrity(
    Insertable<ChangeLogData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('entity_type')) {
      context.handle(
        _entityTypeMeta,
        entityType.isAcceptableOrUnknown(data['entity_type']!, _entityTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_entityTypeMeta);
    }
    if (data.containsKey('entity_id')) {
      context.handle(
        _entityIdMeta,
        entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta),
      );
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('operation')) {
      context.handle(
        _operationMeta,
        operation.isAcceptableOrUnknown(data['operation']!, _operationMeta),
      );
    } else if (isInserting) {
      context.missing(_operationMeta);
    }
    if (data.containsKey('changed_at_utc')) {
      context.handle(
        _changedAtUtcMeta,
        changedAtUtc.isAcceptableOrUnknown(
          data['changed_at_utc']!,
          _changedAtUtcMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_changedAtUtcMeta);
    }
    if (data.containsKey('revision')) {
      context.handle(
        _revisionMeta,
        revision.isAcceptableOrUnknown(data['revision']!, _revisionMeta),
      );
    } else if (isInserting) {
      context.missing(_revisionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ChangeLogData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChangeLogData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      entityType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_type'],
      )!,
      entityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_id'],
      )!,
      operation: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}operation'],
      )!,
      changedAtUtc: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}changed_at_utc'],
      )!,
      revision: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}revision'],
      )!,
    );
  }

  @override
  $ChangeLogTable createAlias(String alias) {
    return $ChangeLogTable(attachedDatabase, alias);
  }
}

class ChangeLogData extends DataClass implements Insertable<ChangeLogData> {
  final String id;
  final String entityType;
  final String entityId;
  final String operation;
  final int changedAtUtc;
  final int revision;
  const ChangeLogData({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.changedAtUtc,
    required this.revision,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['entity_type'] = Variable<String>(entityType);
    map['entity_id'] = Variable<String>(entityId);
    map['operation'] = Variable<String>(operation);
    map['changed_at_utc'] = Variable<int>(changedAtUtc);
    map['revision'] = Variable<int>(revision);
    return map;
  }

  ChangeLogCompanion toCompanion(bool nullToAbsent) {
    return ChangeLogCompanion(
      id: Value(id),
      entityType: Value(entityType),
      entityId: Value(entityId),
      operation: Value(operation),
      changedAtUtc: Value(changedAtUtc),
      revision: Value(revision),
    );
  }

  factory ChangeLogData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChangeLogData(
      id: serializer.fromJson<String>(json['id']),
      entityType: serializer.fromJson<String>(json['entityType']),
      entityId: serializer.fromJson<String>(json['entityId']),
      operation: serializer.fromJson<String>(json['operation']),
      changedAtUtc: serializer.fromJson<int>(json['changedAtUtc']),
      revision: serializer.fromJson<int>(json['revision']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'entityType': serializer.toJson<String>(entityType),
      'entityId': serializer.toJson<String>(entityId),
      'operation': serializer.toJson<String>(operation),
      'changedAtUtc': serializer.toJson<int>(changedAtUtc),
      'revision': serializer.toJson<int>(revision),
    };
  }

  ChangeLogData copyWith({
    String? id,
    String? entityType,
    String? entityId,
    String? operation,
    int? changedAtUtc,
    int? revision,
  }) => ChangeLogData(
    id: id ?? this.id,
    entityType: entityType ?? this.entityType,
    entityId: entityId ?? this.entityId,
    operation: operation ?? this.operation,
    changedAtUtc: changedAtUtc ?? this.changedAtUtc,
    revision: revision ?? this.revision,
  );
  ChangeLogData copyWithCompanion(ChangeLogCompanion data) {
    return ChangeLogData(
      id: data.id.present ? data.id.value : this.id,
      entityType: data.entityType.present
          ? data.entityType.value
          : this.entityType,
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      operation: data.operation.present ? data.operation.value : this.operation,
      changedAtUtc: data.changedAtUtc.present
          ? data.changedAtUtc.value
          : this.changedAtUtc,
      revision: data.revision.present ? data.revision.value : this.revision,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChangeLogData(')
          ..write('id: $id, ')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('operation: $operation, ')
          ..write('changedAtUtc: $changedAtUtc, ')
          ..write('revision: $revision')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, entityType, entityId, operation, changedAtUtc, revision);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChangeLogData &&
          other.id == this.id &&
          other.entityType == this.entityType &&
          other.entityId == this.entityId &&
          other.operation == this.operation &&
          other.changedAtUtc == this.changedAtUtc &&
          other.revision == this.revision);
}

class ChangeLogCompanion extends UpdateCompanion<ChangeLogData> {
  final Value<String> id;
  final Value<String> entityType;
  final Value<String> entityId;
  final Value<String> operation;
  final Value<int> changedAtUtc;
  final Value<int> revision;
  final Value<int> rowid;
  const ChangeLogCompanion({
    this.id = const Value.absent(),
    this.entityType = const Value.absent(),
    this.entityId = const Value.absent(),
    this.operation = const Value.absent(),
    this.changedAtUtc = const Value.absent(),
    this.revision = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ChangeLogCompanion.insert({
    required String id,
    required String entityType,
    required String entityId,
    required String operation,
    required int changedAtUtc,
    required int revision,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       entityType = Value(entityType),
       entityId = Value(entityId),
       operation = Value(operation),
       changedAtUtc = Value(changedAtUtc),
       revision = Value(revision);
  static Insertable<ChangeLogData> custom({
    Expression<String>? id,
    Expression<String>? entityType,
    Expression<String>? entityId,
    Expression<String>? operation,
    Expression<int>? changedAtUtc,
    Expression<int>? revision,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (entityType != null) 'entity_type': entityType,
      if (entityId != null) 'entity_id': entityId,
      if (operation != null) 'operation': operation,
      if (changedAtUtc != null) 'changed_at_utc': changedAtUtc,
      if (revision != null) 'revision': revision,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ChangeLogCompanion copyWith({
    Value<String>? id,
    Value<String>? entityType,
    Value<String>? entityId,
    Value<String>? operation,
    Value<int>? changedAtUtc,
    Value<int>? revision,
    Value<int>? rowid,
  }) {
    return ChangeLogCompanion(
      id: id ?? this.id,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      operation: operation ?? this.operation,
      changedAtUtc: changedAtUtc ?? this.changedAtUtc,
      revision: revision ?? this.revision,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (entityType.present) {
      map['entity_type'] = Variable<String>(entityType.value);
    }
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (operation.present) {
      map['operation'] = Variable<String>(operation.value);
    }
    if (changedAtUtc.present) {
      map['changed_at_utc'] = Variable<int>(changedAtUtc.value);
    }
    if (revision.present) {
      map['revision'] = Variable<int>(revision.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChangeLogCompanion(')
          ..write('id: $id, ')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('operation: $operation, ')
          ..write('changedAtUtc: $changedAtUtc, ')
          ..write('revision: $revision, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $AreasTable areas = $AreasTable(this);
  late final $ProjectsTable projects = $ProjectsTable(this);
  late final $TasksTable tasks = $TasksTable(this);
  late final $TagsTable tags = $TagsTable(this);
  late final $TaskTagsTable taskTags = $TaskTagsTable(this);
  late final $RecurrenceRulesTable recurrenceRules = $RecurrenceRulesTable(
    this,
  );
  late final $CalendarEventsTable calendarEvents = $CalendarEventsTable(this);
  late final $EnergyWindowsTable energyWindows = $EnergyWindowsTable(this);
  late final $SettingsTable settings = $SettingsTable(this);
  late final $PlanVersionsTable planVersions = $PlanVersionsTable(this);
  late final $ScheduleBlocksTable scheduleBlocks = $ScheduleBlocksTable(this);
  late final $TimeEntriesTable timeEntries = $TimeEntriesTable(this);
  late final $TaskCorrectionsTable taskCorrections = $TaskCorrectionsTable(
    this,
  );
  late final $PreferenceEvidenceTable preferenceEvidence =
      $PreferenceEvidenceTable(this);
  late final $PreferenceRulesTable preferenceRules = $PreferenceRulesTable(
    this,
  );
  late final $ChangeLogTable changeLog = $ChangeLogTable(this);
  late final TaskDao taskDao = TaskDao(this as AppDatabase);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    areas,
    projects,
    tasks,
    tags,
    taskTags,
    recurrenceRules,
    calendarEvents,
    energyWindows,
    settings,
    planVersions,
    scheduleBlocks,
    timeEntries,
    taskCorrections,
    preferenceEvidence,
    preferenceRules,
    changeLog,
  ];
}

typedef $$AreasTableCreateCompanionBuilder = AreasCompanion Function({
  required String id,
  required String name,
  required int color,
  required int sortOrder,
  Value<bool> isLife,
  Value<int> createdAtUtc,
  Value<int> updatedAtUtc,
  Value<int> rowid,
});
typedef $$AreasTableUpdateCompanionBuilder = AreasCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<int> color,
  Value<int> sortOrder,
  Value<bool> isLife,
  Value<int> createdAtUtc,
  Value<int> updatedAtUtc,
  Value<int> rowid,
});

final class $$AreasTableReferences
    extends BaseReferences<_$AppDatabase, $AreasTable, Area> {
  $$AreasTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$ProjectsTable, List<Project>> _projectsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.projects,
    aliasName: 'areas__id__projects__area_id',
  );

  $$ProjectsTableProcessedTableManager get projectsRefs {
    final manager = $$ProjectsTableTableManager(
      $_db,
      $_db.projects,
    ).filter((f) => f.areaId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_projectsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$CalendarEventsTable, List<CalendarEvent>>
  _calendarEventsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.calendarEvents,
    aliasName: 'areas__id__calendar_events__area_id',
  );

  $$CalendarEventsTableProcessedTableManager get calendarEventsRefs {
    final manager = $$CalendarEventsTableTableManager(
      $_db,
      $_db.calendarEvents,
    ).filter((f) => f.areaId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_calendarEventsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$AreasTableFilterComposer extends Composer<_$AppDatabase, $AreasTable> {
  $$AreasTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isLife => $composableBuilder(
    column: $table.isLife,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> projectsRefs(
    Expression<bool> Function($$ProjectsTableFilterComposer f) f,
  ) {
    final $$ProjectsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.projects,
      getReferencedColumn: (t) => t.areaId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProjectsTableFilterComposer(
            $db: $db,
            $table: $db.projects,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> calendarEventsRefs(
    Expression<bool> Function($$CalendarEventsTableFilterComposer f) f,
  ) {
    final $$CalendarEventsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.areaId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableFilterComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$AreasTableOrderingComposer
    extends Composer<_$AppDatabase, $AreasTable> {
  $$AreasTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isLife => $composableBuilder(
    column: $table.isLife,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AreasTableAnnotationComposer
    extends Composer<_$AppDatabase, $AreasTable> {
  $$AreasTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get color =>
      $composableBuilder(column: $table.color, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<bool> get isLife =>
      $composableBuilder(column: $table.isLife, builder: (column) => column);

  GeneratedColumn<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => column,
  );

  Expression<T> projectsRefs<T extends Object>(
    Expression<T> Function($$ProjectsTableAnnotationComposer a) f,
  ) {
    final $$ProjectsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.projects,
      getReferencedColumn: (t) => t.areaId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProjectsTableAnnotationComposer(
            $db: $db,
            $table: $db.projects,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> calendarEventsRefs<T extends Object>(
    Expression<T> Function($$CalendarEventsTableAnnotationComposer a) f,
  ) {
    final $$CalendarEventsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.areaId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableAnnotationComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$AreasTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AreasTable,
          Area,
          $$AreasTableFilterComposer,
          $$AreasTableOrderingComposer,
          $$AreasTableAnnotationComposer,
          $$AreasTableCreateCompanionBuilder,
          $$AreasTableUpdateCompanionBuilder,
          (Area, $$AreasTableReferences),
          Area,
          PrefetchHooks Function({bool projectsRefs, bool calendarEventsRefs})
        > {
  $$AreasTableTableManager(_$AppDatabase db, $AreasTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AreasTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AreasTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AreasTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> color = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<bool> isLife = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AreasCompanion(
                id: id,
                name: name,
                color: color,
                sortOrder: sortOrder,
                isLife: isLife,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required int color,
                required int sortOrder,
                Value<bool> isLife = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AreasCompanion.insert(
                id: id,
                name: name,
                color: color,
                sortOrder: sortOrder,
                isLife: isLife,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AreasTable, Area>(table),
                  $$AreasTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({projectsRefs = false, calendarEventsRefs = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (projectsRefs) db.projects,
                    if (calendarEventsRefs) db.calendarEvents,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (projectsRefs)
                        await $_getPrefetchedData<Area, $AreasTable, Project>(
                          currentTable: table,
                          referencedTable: $$AreasTableReferences
                              ._projectsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AreasTableReferences(
                                db,
                                table,
                                p0,
                              ).projectsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.areaId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (calendarEventsRefs)
                        await $_getPrefetchedData<
                          Area,
                          $AreasTable,
                          CalendarEvent
                        >(
                          currentTable: table,
                          referencedTable: $$AreasTableReferences
                              ._calendarEventsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AreasTableReferences(
                                db,
                                table,
                                p0,
                              ).calendarEventsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.areaId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$AreasTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AreasTable,
      Area,
      $$AreasTableFilterComposer,
      $$AreasTableOrderingComposer,
      $$AreasTableAnnotationComposer,
      $$AreasTableCreateCompanionBuilder,
      $$AreasTableUpdateCompanionBuilder,
      (Area, $$AreasTableReferences),
      Area,
      PrefetchHooks Function({bool projectsRefs, bool calendarEventsRefs})
    >;
typedef $$ProjectsTableCreateCompanionBuilder = ProjectsCompanion Function({
  required String id,
  required String areaId,
  required String name,
  Value<int?> archivedAtUtc,
  Value<int> createdAtUtc,
  Value<int> updatedAtUtc,
  Value<int> rowid,
});
typedef $$ProjectsTableUpdateCompanionBuilder = ProjectsCompanion Function({
  Value<String> id,
  Value<String> areaId,
  Value<String> name,
  Value<int?> archivedAtUtc,
  Value<int> createdAtUtc,
  Value<int> updatedAtUtc,
  Value<int> rowid,
});

final class $$ProjectsTableReferences
    extends BaseReferences<_$AppDatabase, $ProjectsTable, Project> {
  $$ProjectsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $AreasTable _areaIdTable(_$AppDatabase db) =>
      db.areas.createAlias('projects__area_id__areas__id');

  $$AreasTableProcessedTableManager get areaId {
    final $_column = $_itemColumn<String>('area_id')!;

    final manager = $$AreasTableTableManager(
      $_db,
      $_db.areas,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_areaIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$TasksTable, List<Task>> _tasksRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.tasks,
    aliasName: 'projects__id__tasks__project_id',
  );

  $$TasksTableProcessedTableManager get tasksRefs {
    final manager = $$TasksTableTableManager(
      $_db,
      $_db.tasks,
    ).filter((f) => f.projectId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_tasksRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ProjectsTableFilterComposer
    extends Composer<_$AppDatabase, $ProjectsTable> {
  $$ProjectsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get archivedAtUtc => $composableBuilder(
    column: $table.archivedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  $$AreasTableFilterComposer get areaId {
    final $$AreasTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.areaId,
      referencedTable: $db.areas,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AreasTableFilterComposer(
            $db: $db,
            $table: $db.areas,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> tasksRefs(
    Expression<bool> Function($$TasksTableFilterComposer f) f,
  ) {
    final $$TasksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.projectId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableFilterComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ProjectsTableOrderingComposer
    extends Composer<_$AppDatabase, $ProjectsTable> {
  $$ProjectsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get archivedAtUtc => $composableBuilder(
    column: $table.archivedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  $$AreasTableOrderingComposer get areaId {
    final $$AreasTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.areaId,
      referencedTable: $db.areas,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AreasTableOrderingComposer(
            $db: $db,
            $table: $db.areas,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProjectsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProjectsTable> {
  $$ProjectsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get archivedAtUtc => $composableBuilder(
    column: $table.archivedAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => column,
  );

  $$AreasTableAnnotationComposer get areaId {
    final $$AreasTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.areaId,
      referencedTable: $db.areas,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AreasTableAnnotationComposer(
            $db: $db,
            $table: $db.areas,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> tasksRefs<T extends Object>(
    Expression<T> Function($$TasksTableAnnotationComposer a) f,
  ) {
    final $$TasksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.projectId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableAnnotationComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ProjectsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProjectsTable,
          Project,
          $$ProjectsTableFilterComposer,
          $$ProjectsTableOrderingComposer,
          $$ProjectsTableAnnotationComposer,
          $$ProjectsTableCreateCompanionBuilder,
          $$ProjectsTableUpdateCompanionBuilder,
          (Project, $$ProjectsTableReferences),
          Project,
          PrefetchHooks Function({bool areaId, bool tasksRefs})
        > {
  $$ProjectsTableTableManager(_$AppDatabase db, $ProjectsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProjectsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProjectsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProjectsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> areaId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int?> archivedAtUtc = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProjectsCompanion(
                id: id,
                areaId: areaId,
                name: name,
                archivedAtUtc: archivedAtUtc,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String areaId,
                required String name,
                Value<int?> archivedAtUtc = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProjectsCompanion.insert(
                id: id,
                areaId: areaId,
                name: name,
                archivedAtUtc: archivedAtUtc,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ProjectsTable, Project>(table),
                  $$ProjectsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({areaId = false, tasksRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (tasksRefs) db.tasks],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (areaId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.areaId,
                        referencedTable: $$ProjectsTableReferences._areaIdTable(
                          db,
                        ),
                        referencedColumn: $$ProjectsTableReferences
                            ._areaIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (tasksRefs)
                    await $_getPrefetchedData<Project, $ProjectsTable, Task>(
                      currentTable: table,
                      referencedTable: $$ProjectsTableReferences
                          ._tasksRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$ProjectsTableReferences(db, table, p0).tasksRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.projectId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$ProjectsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProjectsTable,
      Project,
      $$ProjectsTableFilterComposer,
      $$ProjectsTableOrderingComposer,
      $$ProjectsTableAnnotationComposer,
      $$ProjectsTableCreateCompanionBuilder,
      $$ProjectsTableUpdateCompanionBuilder,
      (Project, $$ProjectsTableReferences),
      Project,
      PrefetchHooks Function({bool areaId, bool tasksRefs})
    >;
typedef $$TasksTableCreateCompanionBuilder = TasksCompanion Function({
  required String id,
  Value<String?> projectId,
  required String title,
  Value<String> notes,
  required String priority,
  required int estimatedMinutes,
  required int remainingMinutes,
  Value<int?> dueAtUtc,
  required String energyLevel,
  required String splitMode,
  required int minChunkMinutes,
  required int maxChunkMinutes,
  Value<int?> preferredStartMinute,
  Value<int?> preferredEndMinute,
  required String status,
  required int createdAtUtc,
  required int updatedAtUtc,
  Value<int> rowid,
});
typedef $$TasksTableUpdateCompanionBuilder = TasksCompanion Function({
  Value<String> id,
  Value<String?> projectId,
  Value<String> title,
  Value<String> notes,
  Value<String> priority,
  Value<int> estimatedMinutes,
  Value<int> remainingMinutes,
  Value<int?> dueAtUtc,
  Value<String> energyLevel,
  Value<String> splitMode,
  Value<int> minChunkMinutes,
  Value<int> maxChunkMinutes,
  Value<int?> preferredStartMinute,
  Value<int?> preferredEndMinute,
  Value<String> status,
  Value<int> createdAtUtc,
  Value<int> updatedAtUtc,
  Value<int> rowid,
});

final class $$TasksTableReferences
    extends BaseReferences<_$AppDatabase, $TasksTable, Task> {
  $$TasksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ProjectsTable _projectIdTable(_$AppDatabase db) =>
      db.projects.createAlias('tasks__project_id__projects__id');

  $$ProjectsTableProcessedTableManager? get projectId {
    final $_column = $_itemColumn<String>('project_id');
    if ($_column == null) return null;
    final manager = $$ProjectsTableTableManager(
      $_db,
      $_db.projects,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_projectIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$TaskTagsTable, List<TaskTag>> _taskTagsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.taskTags,
    aliasName: 'tasks__id__task_tags__task_id',
  );

  $$TaskTagsTableProcessedTableManager get taskTagsRefs {
    final manager = $$TaskTagsTableTableManager(
      $_db,
      $_db.taskTags,
    ).filter((f) => f.taskId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_taskTagsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ScheduleBlocksTable, List<ScheduleBlock>>
  _scheduleBlocksRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.scheduleBlocks,
    aliasName: 'tasks__id__schedule_blocks__task_id',
  );

  $$ScheduleBlocksTableProcessedTableManager get scheduleBlocksRefs {
    final manager = $$ScheduleBlocksTableTableManager(
      $_db,
      $_db.scheduleBlocks,
    ).filter((f) => f.taskId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_scheduleBlocksRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$TimeEntriesTable, List<TimeEntry>>
  _timeEntriesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.timeEntries,
    aliasName: 'tasks__id__time_entries__task_id',
  );

  $$TimeEntriesTableProcessedTableManager get timeEntriesRefs {
    final manager = $$TimeEntriesTableTableManager(
      $_db,
      $_db.timeEntries,
    ).filter((f) => f.taskId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_timeEntriesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$TaskCorrectionsTable, List<TaskCorrection>>
  _taskCorrectionsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.taskCorrections,
    aliasName: 'tasks__id__task_corrections__task_id',
  );

  $$TaskCorrectionsTableProcessedTableManager get taskCorrectionsRefs {
    final manager = $$TaskCorrectionsTableTableManager(
      $_db,
      $_db.taskCorrections,
    ).filter((f) => f.taskId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _taskCorrectionsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$TasksTableFilterComposer extends Composer<_$AppDatabase, $TasksTable> {
  $$TasksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get priority => $composableBuilder(
    column: $table.priority,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get estimatedMinutes => $composableBuilder(
    column: $table.estimatedMinutes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get remainingMinutes => $composableBuilder(
    column: $table.remainingMinutes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get dueAtUtc => $composableBuilder(
    column: $table.dueAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get energyLevel => $composableBuilder(
    column: $table.energyLevel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get splitMode => $composableBuilder(
    column: $table.splitMode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get minChunkMinutes => $composableBuilder(
    column: $table.minChunkMinutes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get maxChunkMinutes => $composableBuilder(
    column: $table.maxChunkMinutes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get preferredStartMinute => $composableBuilder(
    column: $table.preferredStartMinute,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get preferredEndMinute => $composableBuilder(
    column: $table.preferredEndMinute,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  $$ProjectsTableFilterComposer get projectId {
    final $$ProjectsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.projectId,
      referencedTable: $db.projects,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProjectsTableFilterComposer(
            $db: $db,
            $table: $db.projects,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> taskTagsRefs(
    Expression<bool> Function($$TaskTagsTableFilterComposer f) f,
  ) {
    final $$TaskTagsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.taskTags,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TaskTagsTableFilterComposer(
            $db: $db,
            $table: $db.taskTags,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> scheduleBlocksRefs(
    Expression<bool> Function($$ScheduleBlocksTableFilterComposer f) f,
  ) {
    final $$ScheduleBlocksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scheduleBlocks,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScheduleBlocksTableFilterComposer(
            $db: $db,
            $table: $db.scheduleBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> timeEntriesRefs(
    Expression<bool> Function($$TimeEntriesTableFilterComposer f) f,
  ) {
    final $$TimeEntriesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.timeEntries,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TimeEntriesTableFilterComposer(
            $db: $db,
            $table: $db.timeEntries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> taskCorrectionsRefs(
    Expression<bool> Function($$TaskCorrectionsTableFilterComposer f) f,
  ) {
    final $$TaskCorrectionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.taskCorrections,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TaskCorrectionsTableFilterComposer(
            $db: $db,
            $table: $db.taskCorrections,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$TasksTableOrderingComposer
    extends Composer<_$AppDatabase, $TasksTable> {
  $$TasksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get priority => $composableBuilder(
    column: $table.priority,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get estimatedMinutes => $composableBuilder(
    column: $table.estimatedMinutes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get remainingMinutes => $composableBuilder(
    column: $table.remainingMinutes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get dueAtUtc => $composableBuilder(
    column: $table.dueAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get energyLevel => $composableBuilder(
    column: $table.energyLevel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get splitMode => $composableBuilder(
    column: $table.splitMode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get minChunkMinutes => $composableBuilder(
    column: $table.minChunkMinutes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get maxChunkMinutes => $composableBuilder(
    column: $table.maxChunkMinutes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get preferredStartMinute => $composableBuilder(
    column: $table.preferredStartMinute,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get preferredEndMinute => $composableBuilder(
    column: $table.preferredEndMinute,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  $$ProjectsTableOrderingComposer get projectId {
    final $$ProjectsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.projectId,
      referencedTable: $db.projects,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProjectsTableOrderingComposer(
            $db: $db,
            $table: $db.projects,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TasksTableAnnotationComposer
    extends Composer<_$AppDatabase, $TasksTable> {
  $$TasksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<String> get priority =>
      $composableBuilder(column: $table.priority, builder: (column) => column);

  GeneratedColumn<int> get estimatedMinutes => $composableBuilder(
    column: $table.estimatedMinutes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get remainingMinutes => $composableBuilder(
    column: $table.remainingMinutes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get dueAtUtc =>
      $composableBuilder(column: $table.dueAtUtc, builder: (column) => column);

  GeneratedColumn<String> get energyLevel => $composableBuilder(
    column: $table.energyLevel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get splitMode =>
      $composableBuilder(column: $table.splitMode, builder: (column) => column);

  GeneratedColumn<int> get minChunkMinutes => $composableBuilder(
    column: $table.minChunkMinutes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get maxChunkMinutes => $composableBuilder(
    column: $table.maxChunkMinutes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get preferredStartMinute => $composableBuilder(
    column: $table.preferredStartMinute,
    builder: (column) => column,
  );

  GeneratedColumn<int> get preferredEndMinute => $composableBuilder(
    column: $table.preferredEndMinute,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => column,
  );

  $$ProjectsTableAnnotationComposer get projectId {
    final $$ProjectsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.projectId,
      referencedTable: $db.projects,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProjectsTableAnnotationComposer(
            $db: $db,
            $table: $db.projects,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> taskTagsRefs<T extends Object>(
    Expression<T> Function($$TaskTagsTableAnnotationComposer a) f,
  ) {
    final $$TaskTagsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.taskTags,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TaskTagsTableAnnotationComposer(
            $db: $db,
            $table: $db.taskTags,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> scheduleBlocksRefs<T extends Object>(
    Expression<T> Function($$ScheduleBlocksTableAnnotationComposer a) f,
  ) {
    final $$ScheduleBlocksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scheduleBlocks,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScheduleBlocksTableAnnotationComposer(
            $db: $db,
            $table: $db.scheduleBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> timeEntriesRefs<T extends Object>(
    Expression<T> Function($$TimeEntriesTableAnnotationComposer a) f,
  ) {
    final $$TimeEntriesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.timeEntries,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TimeEntriesTableAnnotationComposer(
            $db: $db,
            $table: $db.timeEntries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> taskCorrectionsRefs<T extends Object>(
    Expression<T> Function($$TaskCorrectionsTableAnnotationComposer a) f,
  ) {
    final $$TaskCorrectionsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.taskCorrections,
      getReferencedColumn: (t) => t.taskId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TaskCorrectionsTableAnnotationComposer(
            $db: $db,
            $table: $db.taskCorrections,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$TasksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TasksTable,
          Task,
          $$TasksTableFilterComposer,
          $$TasksTableOrderingComposer,
          $$TasksTableAnnotationComposer,
          $$TasksTableCreateCompanionBuilder,
          $$TasksTableUpdateCompanionBuilder,
          (Task, $$TasksTableReferences),
          Task,
          PrefetchHooks Function({
            bool projectId,
            bool taskTagsRefs,
            bool scheduleBlocksRefs,
            bool timeEntriesRefs,
            bool taskCorrectionsRefs,
          })
        > {
  $$TasksTableTableManager(_$AppDatabase db, $TasksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TasksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TasksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TasksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String?> projectId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> notes = const Value.absent(),
                Value<String> priority = const Value.absent(),
                Value<int> estimatedMinutes = const Value.absent(),
                Value<int> remainingMinutes = const Value.absent(),
                Value<int?> dueAtUtc = const Value.absent(),
                Value<String> energyLevel = const Value.absent(),
                Value<String> splitMode = const Value.absent(),
                Value<int> minChunkMinutes = const Value.absent(),
                Value<int> maxChunkMinutes = const Value.absent(),
                Value<int?> preferredStartMinute = const Value.absent(),
                Value<int?> preferredEndMinute = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TasksCompanion(
                id: id,
                projectId: projectId,
                title: title,
                notes: notes,
                priority: priority,
                estimatedMinutes: estimatedMinutes,
                remainingMinutes: remainingMinutes,
                dueAtUtc: dueAtUtc,
                energyLevel: energyLevel,
                splitMode: splitMode,
                minChunkMinutes: minChunkMinutes,
                maxChunkMinutes: maxChunkMinutes,
                preferredStartMinute: preferredStartMinute,
                preferredEndMinute: preferredEndMinute,
                status: status,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String?> projectId = const Value.absent(),
                required String title,
                Value<String> notes = const Value.absent(),
                required String priority,
                required int estimatedMinutes,
                required int remainingMinutes,
                Value<int?> dueAtUtc = const Value.absent(),
                required String energyLevel,
                required String splitMode,
                required int minChunkMinutes,
                required int maxChunkMinutes,
                Value<int?> preferredStartMinute = const Value.absent(),
                Value<int?> preferredEndMinute = const Value.absent(),
                required String status,
                required int createdAtUtc,
                required int updatedAtUtc,
                Value<int> rowid = const Value.absent(),
              }) => TasksCompanion.insert(
                id: id,
                projectId: projectId,
                title: title,
                notes: notes,
                priority: priority,
                estimatedMinutes: estimatedMinutes,
                remainingMinutes: remainingMinutes,
                dueAtUtc: dueAtUtc,
                energyLevel: energyLevel,
                splitMode: splitMode,
                minChunkMinutes: minChunkMinutes,
                maxChunkMinutes: maxChunkMinutes,
                preferredStartMinute: preferredStartMinute,
                preferredEndMinute: preferredEndMinute,
                status: status,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TasksTable, Task>(table),
                  $$TasksTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                projectId = false,
                taskTagsRefs = false,
                scheduleBlocksRefs = false,
                timeEntriesRefs = false,
                taskCorrectionsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (taskTagsRefs) db.taskTags,
                    if (scheduleBlocksRefs) db.scheduleBlocks,
                    if (timeEntriesRefs) db.timeEntries,
                    if (taskCorrectionsRefs) db.taskCorrections,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (projectId) {
                          state = state.withJoin(
                            currentTable: table,
                            currentColumn: table.projectId,
                            referencedTable: $$TasksTableReferences
                                ._projectIdTable(db),
                            referencedColumn: $$TasksTableReferences
                                ._projectIdTable(db)
                                .id,
                          ) as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (taskTagsRefs)
                        await $_getPrefetchedData<Task, $TasksTable, TaskTag>(
                          currentTable: table,
                          referencedTable: $$TasksTableReferences
                              ._taskTagsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$TasksTableReferences(
                                db,
                                table,
                                p0,
                              ).taskTagsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.taskId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (scheduleBlocksRefs)
                        await $_getPrefetchedData<
                          Task,
                          $TasksTable,
                          ScheduleBlock
                        >(
                          currentTable: table,
                          referencedTable: $$TasksTableReferences
                              ._scheduleBlocksRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$TasksTableReferences(
                                db,
                                table,
                                p0,
                              ).scheduleBlocksRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.taskId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (timeEntriesRefs)
                        await $_getPrefetchedData<Task, $TasksTable, TimeEntry>(
                          currentTable: table,
                          referencedTable: $$TasksTableReferences
                              ._timeEntriesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$TasksTableReferences(
                                db,
                                table,
                                p0,
                              ).timeEntriesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.taskId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (taskCorrectionsRefs)
                        await $_getPrefetchedData<
                          Task,
                          $TasksTable,
                          TaskCorrection
                        >(
                          currentTable: table,
                          referencedTable: $$TasksTableReferences
                              ._taskCorrectionsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$TasksTableReferences(
                                db,
                                table,
                                p0,
                              ).taskCorrectionsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.taskId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$TasksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TasksTable,
      Task,
      $$TasksTableFilterComposer,
      $$TasksTableOrderingComposer,
      $$TasksTableAnnotationComposer,
      $$TasksTableCreateCompanionBuilder,
      $$TasksTableUpdateCompanionBuilder,
      (Task, $$TasksTableReferences),
      Task,
      PrefetchHooks Function({
        bool projectId,
        bool taskTagsRefs,
        bool scheduleBlocksRefs,
        bool timeEntriesRefs,
        bool taskCorrectionsRefs,
      })
    >;
typedef $$TagsTableCreateCompanionBuilder = TagsCompanion Function({
  required String id,
  required String name,
  Value<int> createdAtUtc,
  Value<int> updatedAtUtc,
  Value<int> rowid,
});
typedef $$TagsTableUpdateCompanionBuilder = TagsCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<int> createdAtUtc,
  Value<int> updatedAtUtc,
  Value<int> rowid,
});

final class $$TagsTableReferences
    extends BaseReferences<_$AppDatabase, $TagsTable, Tag> {
  $$TagsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$TaskTagsTable, List<TaskTag>> _taskTagsRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.taskTags,
    aliasName: 'tags__id__task_tags__tag_id',
  );

  $$TaskTagsTableProcessedTableManager get taskTagsRefs {
    final manager = $$TaskTagsTableTableManager(
      $_db,
      $_db.taskTags,
    ).filter((f) => f.tagId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_taskTagsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$TagsTableFilterComposer extends Composer<_$AppDatabase, $TagsTable> {
  $$TagsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> taskTagsRefs(
    Expression<bool> Function($$TaskTagsTableFilterComposer f) f,
  ) {
    final $$TaskTagsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.taskTags,
      getReferencedColumn: (t) => t.tagId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TaskTagsTableFilterComposer(
            $db: $db,
            $table: $db.taskTags,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$TagsTableOrderingComposer extends Composer<_$AppDatabase, $TagsTable> {
  $$TagsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TagsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TagsTable> {
  $$TagsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => column,
  );

  Expression<T> taskTagsRefs<T extends Object>(
    Expression<T> Function($$TaskTagsTableAnnotationComposer a) f,
  ) {
    final $$TaskTagsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.taskTags,
      getReferencedColumn: (t) => t.tagId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TaskTagsTableAnnotationComposer(
            $db: $db,
            $table: $db.taskTags,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$TagsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TagsTable,
          Tag,
          $$TagsTableFilterComposer,
          $$TagsTableOrderingComposer,
          $$TagsTableAnnotationComposer,
          $$TagsTableCreateCompanionBuilder,
          $$TagsTableUpdateCompanionBuilder,
          (Tag, $$TagsTableReferences),
          Tag,
          PrefetchHooks Function({bool taskTagsRefs})
        > {
  $$TagsTableTableManager(_$AppDatabase db, $TagsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TagsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TagsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TagsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TagsCompanion(
                id: id,
                name: name,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TagsCompanion.insert(
                id: id,
                name: name,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TagsTable, Tag>(table),
                  $$TagsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({taskTagsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (taskTagsRefs) db.taskTags],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (taskTagsRefs)
                    await $_getPrefetchedData<Tag, $TagsTable, TaskTag>(
                      currentTable: table,
                      referencedTable: $$TagsTableReferences._taskTagsRefsTable(
                        db,
                      ),
                      managerFromTypedResult: (p0) =>
                          $$TagsTableReferences(db, table, p0).taskTagsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.tagId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$TagsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TagsTable,
      Tag,
      $$TagsTableFilterComposer,
      $$TagsTableOrderingComposer,
      $$TagsTableAnnotationComposer,
      $$TagsTableCreateCompanionBuilder,
      $$TagsTableUpdateCompanionBuilder,
      (Tag, $$TagsTableReferences),
      Tag,
      PrefetchHooks Function({bool taskTagsRefs})
    >;
typedef $$TaskTagsTableCreateCompanionBuilder = TaskTagsCompanion Function({
  required String taskId,
  required String tagId,
  Value<int> createdAtUtc,
  Value<int> rowid,
});
typedef $$TaskTagsTableUpdateCompanionBuilder = TaskTagsCompanion Function({
  Value<String> taskId,
  Value<String> tagId,
  Value<int> createdAtUtc,
  Value<int> rowid,
});

final class $$TaskTagsTableReferences
    extends BaseReferences<_$AppDatabase, $TaskTagsTable, TaskTag> {
  $$TaskTagsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $TasksTable _taskIdTable(_$AppDatabase db) =>
      db.tasks.createAlias('task_tags__task_id__tasks__id');

  $$TasksTableProcessedTableManager get taskId {
    final $_column = $_itemColumn<String>('task_id')!;

    final manager = $$TasksTableTableManager(
      $_db,
      $_db.tasks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_taskIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $TagsTable _tagIdTable(_$AppDatabase db) =>
      db.tags.createAlias('task_tags__tag_id__tags__id');

  $$TagsTableProcessedTableManager get tagId {
    final $_column = $_itemColumn<String>('tag_id')!;

    final manager = $$TagsTableTableManager(
      $_db,
      $_db.tags,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_tagIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$TaskTagsTableFilterComposer
    extends Composer<_$AppDatabase, $TaskTagsTable> {
  $$TaskTagsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  $$TasksTableFilterComposer get taskId {
    final $$TasksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableFilterComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$TagsTableFilterComposer get tagId {
    final $$TagsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.tagId,
      referencedTable: $db.tags,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TagsTableFilterComposer(
            $db: $db,
            $table: $db.tags,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TaskTagsTableOrderingComposer
    extends Composer<_$AppDatabase, $TaskTagsTable> {
  $$TaskTagsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  $$TasksTableOrderingComposer get taskId {
    final $$TasksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableOrderingComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$TagsTableOrderingComposer get tagId {
    final $$TagsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.tagId,
      referencedTable: $db.tags,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TagsTableOrderingComposer(
            $db: $db,
            $table: $db.tags,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TaskTagsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TaskTagsTable> {
  $$TaskTagsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => column,
  );

  $$TasksTableAnnotationComposer get taskId {
    final $$TasksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableAnnotationComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$TagsTableAnnotationComposer get tagId {
    final $$TagsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.tagId,
      referencedTable: $db.tags,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TagsTableAnnotationComposer(
            $db: $db,
            $table: $db.tags,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TaskTagsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TaskTagsTable,
          TaskTag,
          $$TaskTagsTableFilterComposer,
          $$TaskTagsTableOrderingComposer,
          $$TaskTagsTableAnnotationComposer,
          $$TaskTagsTableCreateCompanionBuilder,
          $$TaskTagsTableUpdateCompanionBuilder,
          (TaskTag, $$TaskTagsTableReferences),
          TaskTag,
          PrefetchHooks Function({bool taskId, bool tagId})
        > {
  $$TaskTagsTableTableManager(_$AppDatabase db, $TaskTagsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TaskTagsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TaskTagsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TaskTagsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> taskId = const Value.absent(),
                Value<String> tagId = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TaskTagsCompanion(
                taskId: taskId,
                tagId: tagId,
                createdAtUtc: createdAtUtc,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String taskId,
                required String tagId,
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TaskTagsCompanion.insert(
                taskId: taskId,
                tagId: tagId,
                createdAtUtc: createdAtUtc,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TaskTagsTable, TaskTag>(table),
                  $$TaskTagsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({taskId = false, tagId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (taskId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.taskId,
                        referencedTable: $$TaskTagsTableReferences._taskIdTable(
                          db,
                        ),
                        referencedColumn: $$TaskTagsTableReferences
                            ._taskIdTable(db)
                            .id,
                      ) as T;
                    }
                    if (tagId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.tagId,
                        referencedTable: $$TaskTagsTableReferences._tagIdTable(
                          db,
                        ),
                        referencedColumn: $$TaskTagsTableReferences
                            ._tagIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$TaskTagsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TaskTagsTable,
      TaskTag,
      $$TaskTagsTableFilterComposer,
      $$TaskTagsTableOrderingComposer,
      $$TaskTagsTableAnnotationComposer,
      $$TaskTagsTableCreateCompanionBuilder,
      $$TaskTagsTableUpdateCompanionBuilder,
      (TaskTag, $$TaskTagsTableReferences),
      TaskTag,
      PrefetchHooks Function({bool taskId, bool tagId})
    >;
typedef $$RecurrenceRulesTableCreateCompanionBuilder =
    RecurrenceRulesCompanion Function({
      required String id,
      required int weekdaysMask,
      required int localStartMinute,
      required int durationMinutes,
      required String validFromLocalDate,
      Value<String?> validUntilLocalDate,
      required String timeZoneId,
      Value<int> createdAtUtc,
      Value<int> updatedAtUtc,
      Value<int> rowid,
    });
typedef $$RecurrenceRulesTableUpdateCompanionBuilder =
    RecurrenceRulesCompanion Function({
      Value<String> id,
      Value<int> weekdaysMask,
      Value<int> localStartMinute,
      Value<int> durationMinutes,
      Value<String> validFromLocalDate,
      Value<String?> validUntilLocalDate,
      Value<String> timeZoneId,
      Value<int> createdAtUtc,
      Value<int> updatedAtUtc,
      Value<int> rowid,
    });

final class $$RecurrenceRulesTableReferences
    extends
        BaseReferences<_$AppDatabase, $RecurrenceRulesTable, RecurrenceRule> {
  $$RecurrenceRulesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<$CalendarEventsTable, List<CalendarEvent>>
  _calendarEventsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.calendarEvents,
    aliasName: 'recurrence_rules__id__calendar_events__recurrence_rule_id',
  );

  $$CalendarEventsTableProcessedTableManager get calendarEventsRefs {
    final manager = $$CalendarEventsTableTableManager($_db, $_db.calendarEvents)
        .filter(
          (f) => f.recurrenceRuleId.id.sqlEquals($_itemColumn<String>('id')!),
        );

    final cache = $_typedResult.readTableOrNull(_calendarEventsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$RecurrenceRulesTableFilterComposer
    extends Composer<_$AppDatabase, $RecurrenceRulesTable> {
  $$RecurrenceRulesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get weekdaysMask => $composableBuilder(
    column: $table.weekdaysMask,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get localStartMinute => $composableBuilder(
    column: $table.localStartMinute,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMinutes => $composableBuilder(
    column: $table.durationMinutes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get validFromLocalDate => $composableBuilder(
    column: $table.validFromLocalDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get validUntilLocalDate => $composableBuilder(
    column: $table.validUntilLocalDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get timeZoneId => $composableBuilder(
    column: $table.timeZoneId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> calendarEventsRefs(
    Expression<bool> Function($$CalendarEventsTableFilterComposer f) f,
  ) {
    final $$CalendarEventsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.recurrenceRuleId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableFilterComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$RecurrenceRulesTableOrderingComposer
    extends Composer<_$AppDatabase, $RecurrenceRulesTable> {
  $$RecurrenceRulesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get weekdaysMask => $composableBuilder(
    column: $table.weekdaysMask,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get localStartMinute => $composableBuilder(
    column: $table.localStartMinute,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMinutes => $composableBuilder(
    column: $table.durationMinutes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get validFromLocalDate => $composableBuilder(
    column: $table.validFromLocalDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get validUntilLocalDate => $composableBuilder(
    column: $table.validUntilLocalDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get timeZoneId => $composableBuilder(
    column: $table.timeZoneId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RecurrenceRulesTableAnnotationComposer
    extends Composer<_$AppDatabase, $RecurrenceRulesTable> {
  $$RecurrenceRulesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get weekdaysMask => $composableBuilder(
    column: $table.weekdaysMask,
    builder: (column) => column,
  );

  GeneratedColumn<int> get localStartMinute => $composableBuilder(
    column: $table.localStartMinute,
    builder: (column) => column,
  );

  GeneratedColumn<int> get durationMinutes => $composableBuilder(
    column: $table.durationMinutes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get validFromLocalDate => $composableBuilder(
    column: $table.validFromLocalDate,
    builder: (column) => column,
  );

  GeneratedColumn<String> get validUntilLocalDate => $composableBuilder(
    column: $table.validUntilLocalDate,
    builder: (column) => column,
  );

  GeneratedColumn<String> get timeZoneId => $composableBuilder(
    column: $table.timeZoneId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => column,
  );

  Expression<T> calendarEventsRefs<T extends Object>(
    Expression<T> Function($$CalendarEventsTableAnnotationComposer a) f,
  ) {
    final $$CalendarEventsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.recurrenceRuleId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableAnnotationComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$RecurrenceRulesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RecurrenceRulesTable,
          RecurrenceRule,
          $$RecurrenceRulesTableFilterComposer,
          $$RecurrenceRulesTableOrderingComposer,
          $$RecurrenceRulesTableAnnotationComposer,
          $$RecurrenceRulesTableCreateCompanionBuilder,
          $$RecurrenceRulesTableUpdateCompanionBuilder,
          (RecurrenceRule, $$RecurrenceRulesTableReferences),
          RecurrenceRule,
          PrefetchHooks Function({bool calendarEventsRefs})
        > {
  $$RecurrenceRulesTableTableManager(
    _$AppDatabase db,
    $RecurrenceRulesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecurrenceRulesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RecurrenceRulesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RecurrenceRulesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> weekdaysMask = const Value.absent(),
                Value<int> localStartMinute = const Value.absent(),
                Value<int> durationMinutes = const Value.absent(),
                Value<String> validFromLocalDate = const Value.absent(),
                Value<String?> validUntilLocalDate = const Value.absent(),
                Value<String> timeZoneId = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RecurrenceRulesCompanion(
                id: id,
                weekdaysMask: weekdaysMask,
                localStartMinute: localStartMinute,
                durationMinutes: durationMinutes,
                validFromLocalDate: validFromLocalDate,
                validUntilLocalDate: validUntilLocalDate,
                timeZoneId: timeZoneId,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int weekdaysMask,
                required int localStartMinute,
                required int durationMinutes,
                required String validFromLocalDate,
                Value<String?> validUntilLocalDate = const Value.absent(),
                required String timeZoneId,
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RecurrenceRulesCompanion.insert(
                id: id,
                weekdaysMask: weekdaysMask,
                localStartMinute: localStartMinute,
                durationMinutes: durationMinutes,
                validFromLocalDate: validFromLocalDate,
                validUntilLocalDate: validUntilLocalDate,
                timeZoneId: timeZoneId,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RecurrenceRulesTable, RecurrenceRule>(table),
                  $$RecurrenceRulesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({calendarEventsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (calendarEventsRefs) db.calendarEvents,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (calendarEventsRefs)
                    await $_getPrefetchedData<
                      RecurrenceRule,
                      $RecurrenceRulesTable,
                      CalendarEvent
                    >(
                      currentTable: table,
                      referencedTable: $$RecurrenceRulesTableReferences
                          ._calendarEventsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$RecurrenceRulesTableReferences(
                            db,
                            table,
                            p0,
                          ).calendarEventsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where(
                            (e) => e.recurrenceRuleId == item.id,
                          ),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$RecurrenceRulesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RecurrenceRulesTable,
      RecurrenceRule,
      $$RecurrenceRulesTableFilterComposer,
      $$RecurrenceRulesTableOrderingComposer,
      $$RecurrenceRulesTableAnnotationComposer,
      $$RecurrenceRulesTableCreateCompanionBuilder,
      $$RecurrenceRulesTableUpdateCompanionBuilder,
      (RecurrenceRule, $$RecurrenceRulesTableReferences),
      RecurrenceRule,
      PrefetchHooks Function({bool calendarEventsRefs})
    >;
typedef $$CalendarEventsTableCreateCompanionBuilder =
    CalendarEventsCompanion Function({
      required String id,
      required String title,
      required int startAtUtc,
      required int endAtUtc,
      required String timeZoneId,
      Value<String?> recurrenceRuleId,
      Value<String?> exceptionOfId,
      Value<bool> locked,
      Value<String?> areaId,
      Value<int> createdAtUtc,
      required int updatedAtUtc,
      Value<int> rowid,
    });
typedef $$CalendarEventsTableUpdateCompanionBuilder =
    CalendarEventsCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<int> startAtUtc,
      Value<int> endAtUtc,
      Value<String> timeZoneId,
      Value<String?> recurrenceRuleId,
      Value<String?> exceptionOfId,
      Value<bool> locked,
      Value<String?> areaId,
      Value<int> createdAtUtc,
      Value<int> updatedAtUtc,
      Value<int> rowid,
    });

final class $$CalendarEventsTableReferences
    extends BaseReferences<_$AppDatabase, $CalendarEventsTable, CalendarEvent> {
  $$CalendarEventsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $RecurrenceRulesTable _recurrenceRuleIdTable(_$AppDatabase db) => db
      .recurrenceRules
      .createAlias('calendar_events__recurrence_rule_id__recurrence_rules__id');

  $$RecurrenceRulesTableProcessedTableManager? get recurrenceRuleId {
    final $_column = $_itemColumn<String>('recurrence_rule_id');
    if ($_column == null) return null;
    final manager = $$RecurrenceRulesTableTableManager(
      $_db,
      $_db.recurrenceRules,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_recurrenceRuleIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $CalendarEventsTable _exceptionOfIdTable(_$AppDatabase db) => db
      .calendarEvents
      .createAlias('calendar_events__exception_of_id__calendar_events__id');

  $$CalendarEventsTableProcessedTableManager? get exceptionOfId {
    final $_column = $_itemColumn<String>('exception_of_id');
    if ($_column == null) return null;
    final manager = $$CalendarEventsTableTableManager(
      $_db,
      $_db.calendarEvents,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_exceptionOfIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $AreasTable _areaIdTable(_$AppDatabase db) =>
      db.areas.createAlias('calendar_events__area_id__areas__id');

  $$AreasTableProcessedTableManager? get areaId {
    final $_column = $_itemColumn<String>('area_id');
    if ($_column == null) return null;
    final manager = $$AreasTableTableManager(
      $_db,
      $_db.areas,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_areaIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CalendarEventsTableFilterComposer
    extends Composer<_$AppDatabase, $CalendarEventsTable> {
  $$CalendarEventsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startAtUtc => $composableBuilder(
    column: $table.startAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get endAtUtc => $composableBuilder(
    column: $table.endAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get timeZoneId => $composableBuilder(
    column: $table.timeZoneId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get locked => $composableBuilder(
    column: $table.locked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  $$RecurrenceRulesTableFilterComposer get recurrenceRuleId {
    final $$RecurrenceRulesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.recurrenceRuleId,
      referencedTable: $db.recurrenceRules,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RecurrenceRulesTableFilterComposer(
            $db: $db,
            $table: $db.recurrenceRules,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$CalendarEventsTableFilterComposer get exceptionOfId {
    final $$CalendarEventsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.exceptionOfId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableFilterComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$AreasTableFilterComposer get areaId {
    final $$AreasTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.areaId,
      referencedTable: $db.areas,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AreasTableFilterComposer(
            $db: $db,
            $table: $db.areas,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CalendarEventsTableOrderingComposer
    extends Composer<_$AppDatabase, $CalendarEventsTable> {
  $$CalendarEventsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startAtUtc => $composableBuilder(
    column: $table.startAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get endAtUtc => $composableBuilder(
    column: $table.endAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get timeZoneId => $composableBuilder(
    column: $table.timeZoneId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get locked => $composableBuilder(
    column: $table.locked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  $$RecurrenceRulesTableOrderingComposer get recurrenceRuleId {
    final $$RecurrenceRulesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.recurrenceRuleId,
      referencedTable: $db.recurrenceRules,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RecurrenceRulesTableOrderingComposer(
            $db: $db,
            $table: $db.recurrenceRules,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$CalendarEventsTableOrderingComposer get exceptionOfId {
    final $$CalendarEventsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.exceptionOfId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableOrderingComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$AreasTableOrderingComposer get areaId {
    final $$AreasTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.areaId,
      referencedTable: $db.areas,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AreasTableOrderingComposer(
            $db: $db,
            $table: $db.areas,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CalendarEventsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CalendarEventsTable> {
  $$CalendarEventsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<int> get startAtUtc => $composableBuilder(
    column: $table.startAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get endAtUtc =>
      $composableBuilder(column: $table.endAtUtc, builder: (column) => column);

  GeneratedColumn<String> get timeZoneId => $composableBuilder(
    column: $table.timeZoneId,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get locked =>
      $composableBuilder(column: $table.locked, builder: (column) => column);

  GeneratedColumn<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => column,
  );

  $$RecurrenceRulesTableAnnotationComposer get recurrenceRuleId {
    final $$RecurrenceRulesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.recurrenceRuleId,
      referencedTable: $db.recurrenceRules,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$RecurrenceRulesTableAnnotationComposer(
            $db: $db,
            $table: $db.recurrenceRules,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$CalendarEventsTableAnnotationComposer get exceptionOfId {
    final $$CalendarEventsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.exceptionOfId,
      referencedTable: $db.calendarEvents,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CalendarEventsTableAnnotationComposer(
            $db: $db,
            $table: $db.calendarEvents,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$AreasTableAnnotationComposer get areaId {
    final $$AreasTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.areaId,
      referencedTable: $db.areas,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AreasTableAnnotationComposer(
            $db: $db,
            $table: $db.areas,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CalendarEventsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CalendarEventsTable,
          CalendarEvent,
          $$CalendarEventsTableFilterComposer,
          $$CalendarEventsTableOrderingComposer,
          $$CalendarEventsTableAnnotationComposer,
          $$CalendarEventsTableCreateCompanionBuilder,
          $$CalendarEventsTableUpdateCompanionBuilder,
          (CalendarEvent, $$CalendarEventsTableReferences),
          CalendarEvent,
          PrefetchHooks Function({
            bool recurrenceRuleId,
            bool exceptionOfId,
            bool areaId,
          })
        > {
  $$CalendarEventsTableTableManager(
    _$AppDatabase db,
    $CalendarEventsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CalendarEventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CalendarEventsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CalendarEventsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<int> startAtUtc = const Value.absent(),
                Value<int> endAtUtc = const Value.absent(),
                Value<String> timeZoneId = const Value.absent(),
                Value<String?> recurrenceRuleId = const Value.absent(),
                Value<String?> exceptionOfId = const Value.absent(),
                Value<bool> locked = const Value.absent(),
                Value<String?> areaId = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CalendarEventsCompanion(
                id: id,
                title: title,
                startAtUtc: startAtUtc,
                endAtUtc: endAtUtc,
                timeZoneId: timeZoneId,
                recurrenceRuleId: recurrenceRuleId,
                exceptionOfId: exceptionOfId,
                locked: locked,
                areaId: areaId,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required int startAtUtc,
                required int endAtUtc,
                required String timeZoneId,
                Value<String?> recurrenceRuleId = const Value.absent(),
                Value<String?> exceptionOfId = const Value.absent(),
                Value<bool> locked = const Value.absent(),
                Value<String?> areaId = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                required int updatedAtUtc,
                Value<int> rowid = const Value.absent(),
              }) => CalendarEventsCompanion.insert(
                id: id,
                title: title,
                startAtUtc: startAtUtc,
                endAtUtc: endAtUtc,
                timeZoneId: timeZoneId,
                recurrenceRuleId: recurrenceRuleId,
                exceptionOfId: exceptionOfId,
                locked: locked,
                areaId: areaId,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CalendarEventsTable, CalendarEvent>(table),
                  $$CalendarEventsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                recurrenceRuleId = false,
                exceptionOfId = false,
                areaId = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (recurrenceRuleId) {
                          state = state.withJoin(
                            currentTable: table,
                            currentColumn: table.recurrenceRuleId,
                            referencedTable: $$CalendarEventsTableReferences
                                ._recurrenceRuleIdTable(db),
                            referencedColumn: $$CalendarEventsTableReferences
                                ._recurrenceRuleIdTable(db)
                                .id,
                          ) as T;
                        }
                        if (exceptionOfId) {
                          state = state.withJoin(
                            currentTable: table,
                            currentColumn: table.exceptionOfId,
                            referencedTable: $$CalendarEventsTableReferences
                                ._exceptionOfIdTable(db),
                            referencedColumn: $$CalendarEventsTableReferences
                                ._exceptionOfIdTable(db)
                                .id,
                          ) as T;
                        }
                        if (areaId) {
                          state = state.withJoin(
                            currentTable: table,
                            currentColumn: table.areaId,
                            referencedTable: $$CalendarEventsTableReferences
                                ._areaIdTable(db),
                            referencedColumn: $$CalendarEventsTableReferences
                                ._areaIdTable(db)
                                .id,
                          ) as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [];
                  },
                );
              },
        ),
      );
}

typedef $$CalendarEventsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CalendarEventsTable,
      CalendarEvent,
      $$CalendarEventsTableFilterComposer,
      $$CalendarEventsTableOrderingComposer,
      $$CalendarEventsTableAnnotationComposer,
      $$CalendarEventsTableCreateCompanionBuilder,
      $$CalendarEventsTableUpdateCompanionBuilder,
      (CalendarEvent, $$CalendarEventsTableReferences),
      CalendarEvent,
      PrefetchHooks Function({
        bool recurrenceRuleId,
        bool exceptionOfId,
        bool areaId,
      })
    >;
typedef $$EnergyWindowsTableCreateCompanionBuilder =
    EnergyWindowsCompanion Function({
      required String id,
      required String dayKind,
      required int startMinute,
      required int endMinute,
      required String energyLevel,
      required String source,
      Value<int> createdAtUtc,
      Value<int> updatedAtUtc,
      Value<int> rowid,
    });
typedef $$EnergyWindowsTableUpdateCompanionBuilder =
    EnergyWindowsCompanion Function({
      Value<String> id,
      Value<String> dayKind,
      Value<int> startMinute,
      Value<int> endMinute,
      Value<String> energyLevel,
      Value<String> source,
      Value<int> createdAtUtc,
      Value<int> updatedAtUtc,
      Value<int> rowid,
    });

class $$EnergyWindowsTableFilterComposer
    extends Composer<_$AppDatabase, $EnergyWindowsTable> {
  $$EnergyWindowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dayKind => $composableBuilder(
    column: $table.dayKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startMinute => $composableBuilder(
    column: $table.startMinute,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get endMinute => $composableBuilder(
    column: $table.endMinute,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get energyLevel => $composableBuilder(
    column: $table.energyLevel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnFilters(column),
  );
}

class $$EnergyWindowsTableOrderingComposer
    extends Composer<_$AppDatabase, $EnergyWindowsTable> {
  $$EnergyWindowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dayKind => $composableBuilder(
    column: $table.dayKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startMinute => $composableBuilder(
    column: $table.startMinute,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get endMinute => $composableBuilder(
    column: $table.endMinute,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get energyLevel => $composableBuilder(
    column: $table.energyLevel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$EnergyWindowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $EnergyWindowsTable> {
  $$EnergyWindowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get dayKind =>
      $composableBuilder(column: $table.dayKind, builder: (column) => column);

  GeneratedColumn<int> get startMinute => $composableBuilder(
    column: $table.startMinute,
    builder: (column) => column,
  );

  GeneratedColumn<int> get endMinute =>
      $composableBuilder(column: $table.endMinute, builder: (column) => column);

  GeneratedColumn<String> get energyLevel => $composableBuilder(
    column: $table.energyLevel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => column,
  );
}

class $$EnergyWindowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $EnergyWindowsTable,
          EnergyWindow,
          $$EnergyWindowsTableFilterComposer,
          $$EnergyWindowsTableOrderingComposer,
          $$EnergyWindowsTableAnnotationComposer,
          $$EnergyWindowsTableCreateCompanionBuilder,
          $$EnergyWindowsTableUpdateCompanionBuilder,
          (
            EnergyWindow,
            BaseReferences<_$AppDatabase, $EnergyWindowsTable, EnergyWindow>,
          ),
          EnergyWindow,
          PrefetchHooks Function()
        > {
  $$EnergyWindowsTableTableManager(_$AppDatabase db, $EnergyWindowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$EnergyWindowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$EnergyWindowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$EnergyWindowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> dayKind = const Value.absent(),
                Value<int> startMinute = const Value.absent(),
                Value<int> endMinute = const Value.absent(),
                Value<String> energyLevel = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EnergyWindowsCompanion(
                id: id,
                dayKind: dayKind,
                startMinute: startMinute,
                endMinute: endMinute,
                energyLevel: energyLevel,
                source: source,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String dayKind,
                required int startMinute,
                required int endMinute,
                required String energyLevel,
                required String source,
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EnergyWindowsCompanion.insert(
                id: id,
                dayKind: dayKind,
                startMinute: startMinute,
                endMinute: endMinute,
                energyLevel: energyLevel,
                source: source,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$EnergyWindowsTable, EnergyWindow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $EnergyWindowsTable,
                    EnergyWindow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$EnergyWindowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $EnergyWindowsTable,
      EnergyWindow,
      $$EnergyWindowsTableFilterComposer,
      $$EnergyWindowsTableOrderingComposer,
      $$EnergyWindowsTableAnnotationComposer,
      $$EnergyWindowsTableCreateCompanionBuilder,
      $$EnergyWindowsTableUpdateCompanionBuilder,
      (
        EnergyWindow,
        BaseReferences<_$AppDatabase, $EnergyWindowsTable, EnergyWindow>,
      ),
      EnergyWindow,
      PrefetchHooks Function()
    >;
typedef $$SettingsTableCreateCompanionBuilder = SettingsCompanion Function({
  required String key,
  required String jsonValue,
  Value<int> createdAtUtc,
  required int updatedAtUtc,
  Value<int> rowid,
});
typedef $$SettingsTableUpdateCompanionBuilder = SettingsCompanion Function({
  Value<String> key,
  Value<String> jsonValue,
  Value<int> createdAtUtc,
  Value<int> updatedAtUtc,
  Value<int> rowid,
});

class $$SettingsTableFilterComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get jsonValue => $composableBuilder(
    column: $table.jsonValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get jsonValue => $composableBuilder(
    column: $table.jsonValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get jsonValue =>
      $composableBuilder(column: $table.jsonValue, builder: (column) => column);

  GeneratedColumn<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => column,
  );
}

class $$SettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SettingsTable,
          Setting,
          $$SettingsTableFilterComposer,
          $$SettingsTableOrderingComposer,
          $$SettingsTableAnnotationComposer,
          $$SettingsTableCreateCompanionBuilder,
          $$SettingsTableUpdateCompanionBuilder,
          (Setting, BaseReferences<_$AppDatabase, $SettingsTable, Setting>),
          Setting,
          PrefetchHooks Function()
        > {
  $$SettingsTableTableManager(_$AppDatabase db, $SettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> jsonValue = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SettingsCompanion(
                key: key,
                jsonValue: jsonValue,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String key,
                required String jsonValue,
                Value<int> createdAtUtc = const Value.absent(),
                required int updatedAtUtc,
                Value<int> rowid = const Value.absent(),
              }) => SettingsCompanion.insert(
                key: key,
                jsonValue: jsonValue,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SettingsTable, Setting>(table),
                  BaseReferences<_$AppDatabase, $SettingsTable, Setting>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SettingsTable,
      Setting,
      $$SettingsTableFilterComposer,
      $$SettingsTableOrderingComposer,
      $$SettingsTableAnnotationComposer,
      $$SettingsTableCreateCompanionBuilder,
      $$SettingsTableUpdateCompanionBuilder,
      (Setting, BaseReferences<_$AppDatabase, $SettingsTable, Setting>),
      Setting,
      PrefetchHooks Function()
    >;
typedef $$PlanVersionsTableCreateCompanionBuilder =
    PlanVersionsCompanion Function({
      required String id,
      required int createdAtUtc,
      required String inputHash,
      required String algorithmVersion,
      required String status,
      required String summaryJson,
      Value<int> rowid,
    });
typedef $$PlanVersionsTableUpdateCompanionBuilder =
    PlanVersionsCompanion Function({
      Value<String> id,
      Value<int> createdAtUtc,
      Value<String> inputHash,
      Value<String> algorithmVersion,
      Value<String> status,
      Value<String> summaryJson,
      Value<int> rowid,
    });

final class $$PlanVersionsTableReferences
    extends BaseReferences<_$AppDatabase, $PlanVersionsTable, PlanVersion> {
  $$PlanVersionsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$ScheduleBlocksTable, List<ScheduleBlock>>
  _scheduleBlocksRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.scheduleBlocks,
    aliasName: 'plan_versions__id__schedule_blocks__plan_version_id',
  );

  $$ScheduleBlocksTableProcessedTableManager get scheduleBlocksRefs {
    final manager = $$ScheduleBlocksTableTableManager(
      $_db,
      $_db.scheduleBlocks,
    ).filter((f) => f.planVersionId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_scheduleBlocksRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$PlanVersionsTableFilterComposer
    extends Composer<_$AppDatabase, $PlanVersionsTable> {
  $$PlanVersionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get inputHash => $composableBuilder(
    column: $table.inputHash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get algorithmVersion => $composableBuilder(
    column: $table.algorithmVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summaryJson => $composableBuilder(
    column: $table.summaryJson,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> scheduleBlocksRefs(
    Expression<bool> Function($$ScheduleBlocksTableFilterComposer f) f,
  ) {
    final $$ScheduleBlocksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scheduleBlocks,
      getReferencedColumn: (t) => t.planVersionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScheduleBlocksTableFilterComposer(
            $db: $db,
            $table: $db.scheduleBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PlanVersionsTableOrderingComposer
    extends Composer<_$AppDatabase, $PlanVersionsTable> {
  $$PlanVersionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get inputHash => $composableBuilder(
    column: $table.inputHash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get algorithmVersion => $composableBuilder(
    column: $table.algorithmVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summaryJson => $composableBuilder(
    column: $table.summaryJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PlanVersionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PlanVersionsTable> {
  $$PlanVersionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<String> get inputHash =>
      $composableBuilder(column: $table.inputHash, builder: (column) => column);

  GeneratedColumn<String> get algorithmVersion => $composableBuilder(
    column: $table.algorithmVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get summaryJson => $composableBuilder(
    column: $table.summaryJson,
    builder: (column) => column,
  );

  Expression<T> scheduleBlocksRefs<T extends Object>(
    Expression<T> Function($$ScheduleBlocksTableAnnotationComposer a) f,
  ) {
    final $$ScheduleBlocksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scheduleBlocks,
      getReferencedColumn: (t) => t.planVersionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScheduleBlocksTableAnnotationComposer(
            $db: $db,
            $table: $db.scheduleBlocks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PlanVersionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PlanVersionsTable,
          PlanVersion,
          $$PlanVersionsTableFilterComposer,
          $$PlanVersionsTableOrderingComposer,
          $$PlanVersionsTableAnnotationComposer,
          $$PlanVersionsTableCreateCompanionBuilder,
          $$PlanVersionsTableUpdateCompanionBuilder,
          (PlanVersion, $$PlanVersionsTableReferences),
          PlanVersion,
          PrefetchHooks Function({bool scheduleBlocksRefs})
        > {
  $$PlanVersionsTableTableManager(_$AppDatabase db, $PlanVersionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlanVersionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlanVersionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlanVersionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                Value<String> inputHash = const Value.absent(),
                Value<String> algorithmVersion = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> summaryJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlanVersionsCompanion(
                id: id,
                createdAtUtc: createdAtUtc,
                inputHash: inputHash,
                algorithmVersion: algorithmVersion,
                status: status,
                summaryJson: summaryJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int createdAtUtc,
                required String inputHash,
                required String algorithmVersion,
                required String status,
                required String summaryJson,
                Value<int> rowid = const Value.absent(),
              }) => PlanVersionsCompanion.insert(
                id: id,
                createdAtUtc: createdAtUtc,
                inputHash: inputHash,
                algorithmVersion: algorithmVersion,
                status: status,
                summaryJson: summaryJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PlanVersionsTable, PlanVersion>(table),
                  $$PlanVersionsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({scheduleBlocksRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (scheduleBlocksRefs) db.scheduleBlocks,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (scheduleBlocksRefs)
                    await $_getPrefetchedData<
                      PlanVersion,
                      $PlanVersionsTable,
                      ScheduleBlock
                    >(
                      currentTable: table,
                      referencedTable: $$PlanVersionsTableReferences
                          ._scheduleBlocksRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$PlanVersionsTableReferences(
                            db,
                            table,
                            p0,
                          ).scheduleBlocksRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where(
                            (e) => e.planVersionId == item.id,
                          ),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$PlanVersionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PlanVersionsTable,
      PlanVersion,
      $$PlanVersionsTableFilterComposer,
      $$PlanVersionsTableOrderingComposer,
      $$PlanVersionsTableAnnotationComposer,
      $$PlanVersionsTableCreateCompanionBuilder,
      $$PlanVersionsTableUpdateCompanionBuilder,
      (PlanVersion, $$PlanVersionsTableReferences),
      PlanVersion,
      PrefetchHooks Function({bool scheduleBlocksRefs})
    >;
typedef $$ScheduleBlocksTableCreateCompanionBuilder =
    ScheduleBlocksCompanion Function({
      required String id,
      required String planVersionId,
      required String taskId,
      required int startAtUtc,
      required int endAtUtc,
      Value<bool> locked,
      required String explanationCode,
      Value<int> createdAtUtc,
      Value<int> updatedAtUtc,
      Value<int> rowid,
    });
typedef $$ScheduleBlocksTableUpdateCompanionBuilder =
    ScheduleBlocksCompanion Function({
      Value<String> id,
      Value<String> planVersionId,
      Value<String> taskId,
      Value<int> startAtUtc,
      Value<int> endAtUtc,
      Value<bool> locked,
      Value<String> explanationCode,
      Value<int> createdAtUtc,
      Value<int> updatedAtUtc,
      Value<int> rowid,
    });

final class $$ScheduleBlocksTableReferences
    extends BaseReferences<_$AppDatabase, $ScheduleBlocksTable, ScheduleBlock> {
  $$ScheduleBlocksTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $PlanVersionsTable _planVersionIdTable(_$AppDatabase db) => db
      .planVersions
      .createAlias('schedule_blocks__plan_version_id__plan_versions__id');

  $$PlanVersionsTableProcessedTableManager get planVersionId {
    final $_column = $_itemColumn<String>('plan_version_id')!;

    final manager = $$PlanVersionsTableTableManager(
      $_db,
      $_db.planVersions,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_planVersionIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $TasksTable _taskIdTable(_$AppDatabase db) =>
      db.tasks.createAlias('schedule_blocks__task_id__tasks__id');

  $$TasksTableProcessedTableManager get taskId {
    final $_column = $_itemColumn<String>('task_id')!;

    final manager = $$TasksTableTableManager(
      $_db,
      $_db.tasks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_taskIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ScheduleBlocksTableFilterComposer
    extends Composer<_$AppDatabase, $ScheduleBlocksTable> {
  $$ScheduleBlocksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startAtUtc => $composableBuilder(
    column: $table.startAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get endAtUtc => $composableBuilder(
    column: $table.endAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get locked => $composableBuilder(
    column: $table.locked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get explanationCode => $composableBuilder(
    column: $table.explanationCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  $$PlanVersionsTableFilterComposer get planVersionId {
    final $$PlanVersionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.planVersionId,
      referencedTable: $db.planVersions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanVersionsTableFilterComposer(
            $db: $db,
            $table: $db.planVersions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$TasksTableFilterComposer get taskId {
    final $$TasksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableFilterComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScheduleBlocksTableOrderingComposer
    extends Composer<_$AppDatabase, $ScheduleBlocksTable> {
  $$ScheduleBlocksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startAtUtc => $composableBuilder(
    column: $table.startAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get endAtUtc => $composableBuilder(
    column: $table.endAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get locked => $composableBuilder(
    column: $table.locked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get explanationCode => $composableBuilder(
    column: $table.explanationCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  $$PlanVersionsTableOrderingComposer get planVersionId {
    final $$PlanVersionsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.planVersionId,
      referencedTable: $db.planVersions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanVersionsTableOrderingComposer(
            $db: $db,
            $table: $db.planVersions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$TasksTableOrderingComposer get taskId {
    final $$TasksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableOrderingComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScheduleBlocksTableAnnotationComposer
    extends Composer<_$AppDatabase, $ScheduleBlocksTable> {
  $$ScheduleBlocksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get startAtUtc => $composableBuilder(
    column: $table.startAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get endAtUtc =>
      $composableBuilder(column: $table.endAtUtc, builder: (column) => column);

  GeneratedColumn<bool> get locked =>
      $composableBuilder(column: $table.locked, builder: (column) => column);

  GeneratedColumn<String> get explanationCode => $composableBuilder(
    column: $table.explanationCode,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => column,
  );

  $$PlanVersionsTableAnnotationComposer get planVersionId {
    final $$PlanVersionsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.planVersionId,
      referencedTable: $db.planVersions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlanVersionsTableAnnotationComposer(
            $db: $db,
            $table: $db.planVersions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$TasksTableAnnotationComposer get taskId {
    final $$TasksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableAnnotationComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScheduleBlocksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ScheduleBlocksTable,
          ScheduleBlock,
          $$ScheduleBlocksTableFilterComposer,
          $$ScheduleBlocksTableOrderingComposer,
          $$ScheduleBlocksTableAnnotationComposer,
          $$ScheduleBlocksTableCreateCompanionBuilder,
          $$ScheduleBlocksTableUpdateCompanionBuilder,
          (ScheduleBlock, $$ScheduleBlocksTableReferences),
          ScheduleBlock,
          PrefetchHooks Function({bool planVersionId, bool taskId})
        > {
  $$ScheduleBlocksTableTableManager(
    _$AppDatabase db,
    $ScheduleBlocksTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ScheduleBlocksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ScheduleBlocksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ScheduleBlocksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> planVersionId = const Value.absent(),
                Value<String> taskId = const Value.absent(),
                Value<int> startAtUtc = const Value.absent(),
                Value<int> endAtUtc = const Value.absent(),
                Value<bool> locked = const Value.absent(),
                Value<String> explanationCode = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ScheduleBlocksCompanion(
                id: id,
                planVersionId: planVersionId,
                taskId: taskId,
                startAtUtc: startAtUtc,
                endAtUtc: endAtUtc,
                locked: locked,
                explanationCode: explanationCode,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String planVersionId,
                required String taskId,
                required int startAtUtc,
                required int endAtUtc,
                Value<bool> locked = const Value.absent(),
                required String explanationCode,
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ScheduleBlocksCompanion.insert(
                id: id,
                planVersionId: planVersionId,
                taskId: taskId,
                startAtUtc: startAtUtc,
                endAtUtc: endAtUtc,
                locked: locked,
                explanationCode: explanationCode,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ScheduleBlocksTable, ScheduleBlock>(table),
                  $$ScheduleBlocksTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({planVersionId = false, taskId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (planVersionId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.planVersionId,
                        referencedTable: $$ScheduleBlocksTableReferences
                            ._planVersionIdTable(db),
                        referencedColumn: $$ScheduleBlocksTableReferences
                            ._planVersionIdTable(db)
                            .id,
                      ) as T;
                    }
                    if (taskId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.taskId,
                        referencedTable: $$ScheduleBlocksTableReferences
                            ._taskIdTable(db),
                        referencedColumn: $$ScheduleBlocksTableReferences
                            ._taskIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ScheduleBlocksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ScheduleBlocksTable,
      ScheduleBlock,
      $$ScheduleBlocksTableFilterComposer,
      $$ScheduleBlocksTableOrderingComposer,
      $$ScheduleBlocksTableAnnotationComposer,
      $$ScheduleBlocksTableCreateCompanionBuilder,
      $$ScheduleBlocksTableUpdateCompanionBuilder,
      (ScheduleBlock, $$ScheduleBlocksTableReferences),
      ScheduleBlock,
      PrefetchHooks Function({bool planVersionId, bool taskId})
    >;
typedef $$TimeEntriesTableCreateCompanionBuilder =
    TimeEntriesCompanion Function({
      required String id,
      required String taskId,
      required int startedAtUtc,
      Value<int?> endedAtUtc,
      Value<int> pausedMinutes,
      required String source,
      required String recoveryState,
      Value<int> createdAtUtc,
      Value<int> updatedAtUtc,
      Value<int> rowid,
    });
typedef $$TimeEntriesTableUpdateCompanionBuilder =
    TimeEntriesCompanion Function({
      Value<String> id,
      Value<String> taskId,
      Value<int> startedAtUtc,
      Value<int?> endedAtUtc,
      Value<int> pausedMinutes,
      Value<String> source,
      Value<String> recoveryState,
      Value<int> createdAtUtc,
      Value<int> updatedAtUtc,
      Value<int> rowid,
    });

final class $$TimeEntriesTableReferences
    extends BaseReferences<_$AppDatabase, $TimeEntriesTable, TimeEntry> {
  $$TimeEntriesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $TasksTable _taskIdTable(_$AppDatabase db) =>
      db.tasks.createAlias('time_entries__task_id__tasks__id');

  $$TasksTableProcessedTableManager get taskId {
    final $_column = $_itemColumn<String>('task_id')!;

    final manager = $$TasksTableTableManager(
      $_db,
      $_db.tasks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_taskIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$TimeEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $TimeEntriesTable> {
  $$TimeEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startedAtUtc => $composableBuilder(
    column: $table.startedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get endedAtUtc => $composableBuilder(
    column: $table.endedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pausedMinutes => $composableBuilder(
    column: $table.pausedMinutes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recoveryState => $composableBuilder(
    column: $table.recoveryState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  $$TasksTableFilterComposer get taskId {
    final $$TasksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableFilterComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TimeEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $TimeEntriesTable> {
  $$TimeEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startedAtUtc => $composableBuilder(
    column: $table.startedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get endedAtUtc => $composableBuilder(
    column: $table.endedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pausedMinutes => $composableBuilder(
    column: $table.pausedMinutes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recoveryState => $composableBuilder(
    column: $table.recoveryState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  $$TasksTableOrderingComposer get taskId {
    final $$TasksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableOrderingComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TimeEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $TimeEntriesTable> {
  $$TimeEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get startedAtUtc => $composableBuilder(
    column: $table.startedAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get endedAtUtc => $composableBuilder(
    column: $table.endedAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get pausedMinutes => $composableBuilder(
    column: $table.pausedMinutes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get recoveryState => $composableBuilder(
    column: $table.recoveryState,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAtUtc => $composableBuilder(
    column: $table.createdAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => column,
  );

  $$TasksTableAnnotationComposer get taskId {
    final $$TasksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableAnnotationComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TimeEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TimeEntriesTable,
          TimeEntry,
          $$TimeEntriesTableFilterComposer,
          $$TimeEntriesTableOrderingComposer,
          $$TimeEntriesTableAnnotationComposer,
          $$TimeEntriesTableCreateCompanionBuilder,
          $$TimeEntriesTableUpdateCompanionBuilder,
          (TimeEntry, $$TimeEntriesTableReferences),
          TimeEntry,
          PrefetchHooks Function({bool taskId})
        > {
  $$TimeEntriesTableTableManager(_$AppDatabase db, $TimeEntriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TimeEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TimeEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TimeEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> taskId = const Value.absent(),
                Value<int> startedAtUtc = const Value.absent(),
                Value<int?> endedAtUtc = const Value.absent(),
                Value<int> pausedMinutes = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String> recoveryState = const Value.absent(),
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TimeEntriesCompanion(
                id: id,
                taskId: taskId,
                startedAtUtc: startedAtUtc,
                endedAtUtc: endedAtUtc,
                pausedMinutes: pausedMinutes,
                source: source,
                recoveryState: recoveryState,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String taskId,
                required int startedAtUtc,
                Value<int?> endedAtUtc = const Value.absent(),
                Value<int> pausedMinutes = const Value.absent(),
                required String source,
                required String recoveryState,
                Value<int> createdAtUtc = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TimeEntriesCompanion.insert(
                id: id,
                taskId: taskId,
                startedAtUtc: startedAtUtc,
                endedAtUtc: endedAtUtc,
                pausedMinutes: pausedMinutes,
                source: source,
                recoveryState: recoveryState,
                createdAtUtc: createdAtUtc,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TimeEntriesTable, TimeEntry>(table),
                  $$TimeEntriesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({taskId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (taskId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.taskId,
                        referencedTable: $$TimeEntriesTableReferences
                            ._taskIdTable(db),
                        referencedColumn: $$TimeEntriesTableReferences
                            ._taskIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$TimeEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TimeEntriesTable,
      TimeEntry,
      $$TimeEntriesTableFilterComposer,
      $$TimeEntriesTableOrderingComposer,
      $$TimeEntriesTableAnnotationComposer,
      $$TimeEntriesTableCreateCompanionBuilder,
      $$TimeEntriesTableUpdateCompanionBuilder,
      (TimeEntry, $$TimeEntriesTableReferences),
      TimeEntry,
      PrefetchHooks Function({bool taskId})
    >;
typedef $$TaskCorrectionsTableCreateCompanionBuilder =
    TaskCorrectionsCompanion Function({
      required String id,
      required String taskId,
      required int previousMinutes,
      required int correctedMinutes,
      required int correctedAtUtc,
      Value<int> rowid,
    });
typedef $$TaskCorrectionsTableUpdateCompanionBuilder =
    TaskCorrectionsCompanion Function({
      Value<String> id,
      Value<String> taskId,
      Value<int> previousMinutes,
      Value<int> correctedMinutes,
      Value<int> correctedAtUtc,
      Value<int> rowid,
    });

final class $$TaskCorrectionsTableReferences
    extends
        BaseReferences<_$AppDatabase, $TaskCorrectionsTable, TaskCorrection> {
  $$TaskCorrectionsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $TasksTable _taskIdTable(_$AppDatabase db) =>
      db.tasks.createAlias('task_corrections__task_id__tasks__id');

  $$TasksTableProcessedTableManager get taskId {
    final $_column = $_itemColumn<String>('task_id')!;

    final manager = $$TasksTableTableManager(
      $_db,
      $_db.tasks,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_taskIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$TaskCorrectionsTableFilterComposer
    extends Composer<_$AppDatabase, $TaskCorrectionsTable> {
  $$TaskCorrectionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get previousMinutes => $composableBuilder(
    column: $table.previousMinutes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get correctedMinutes => $composableBuilder(
    column: $table.correctedMinutes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get correctedAtUtc => $composableBuilder(
    column: $table.correctedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  $$TasksTableFilterComposer get taskId {
    final $$TasksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableFilterComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TaskCorrectionsTableOrderingComposer
    extends Composer<_$AppDatabase, $TaskCorrectionsTable> {
  $$TaskCorrectionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get previousMinutes => $composableBuilder(
    column: $table.previousMinutes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get correctedMinutes => $composableBuilder(
    column: $table.correctedMinutes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get correctedAtUtc => $composableBuilder(
    column: $table.correctedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  $$TasksTableOrderingComposer get taskId {
    final $$TasksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableOrderingComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TaskCorrectionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TaskCorrectionsTable> {
  $$TaskCorrectionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get previousMinutes => $composableBuilder(
    column: $table.previousMinutes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get correctedMinutes => $composableBuilder(
    column: $table.correctedMinutes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get correctedAtUtc => $composableBuilder(
    column: $table.correctedAtUtc,
    builder: (column) => column,
  );

  $$TasksTableAnnotationComposer get taskId {
    final $$TasksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.taskId,
      referencedTable: $db.tasks,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TasksTableAnnotationComposer(
            $db: $db,
            $table: $db.tasks,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$TaskCorrectionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TaskCorrectionsTable,
          TaskCorrection,
          $$TaskCorrectionsTableFilterComposer,
          $$TaskCorrectionsTableOrderingComposer,
          $$TaskCorrectionsTableAnnotationComposer,
          $$TaskCorrectionsTableCreateCompanionBuilder,
          $$TaskCorrectionsTableUpdateCompanionBuilder,
          (TaskCorrection, $$TaskCorrectionsTableReferences),
          TaskCorrection,
          PrefetchHooks Function({bool taskId})
        > {
  $$TaskCorrectionsTableTableManager(
    _$AppDatabase db,
    $TaskCorrectionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TaskCorrectionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TaskCorrectionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TaskCorrectionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> taskId = const Value.absent(),
                Value<int> previousMinutes = const Value.absent(),
                Value<int> correctedMinutes = const Value.absent(),
                Value<int> correctedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TaskCorrectionsCompanion(
                id: id,
                taskId: taskId,
                previousMinutes: previousMinutes,
                correctedMinutes: correctedMinutes,
                correctedAtUtc: correctedAtUtc,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String taskId,
                required int previousMinutes,
                required int correctedMinutes,
                required int correctedAtUtc,
                Value<int> rowid = const Value.absent(),
              }) => TaskCorrectionsCompanion.insert(
                id: id,
                taskId: taskId,
                previousMinutes: previousMinutes,
                correctedMinutes: correctedMinutes,
                correctedAtUtc: correctedAtUtc,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TaskCorrectionsTable, TaskCorrection>(table),
                  $$TaskCorrectionsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({taskId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (taskId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.taskId,
                        referencedTable: $$TaskCorrectionsTableReferences
                            ._taskIdTable(db),
                        referencedColumn: $$TaskCorrectionsTableReferences
                            ._taskIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$TaskCorrectionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TaskCorrectionsTable,
      TaskCorrection,
      $$TaskCorrectionsTableFilterComposer,
      $$TaskCorrectionsTableOrderingComposer,
      $$TaskCorrectionsTableAnnotationComposer,
      $$TaskCorrectionsTableCreateCompanionBuilder,
      $$TaskCorrectionsTableUpdateCompanionBuilder,
      (TaskCorrection, $$TaskCorrectionsTableReferences),
      TaskCorrection,
      PrefetchHooks Function({bool taskId})
    >;
typedef $$PreferenceEvidenceTableCreateCompanionBuilder =
    PreferenceEvidenceCompanion Function({
      required String id,
      required String kind,
      required String subjectKey,
      required int observedAtUtc,
      Value<double?> numericValue,
      Value<bool> specialDay,
      required String metadataJson,
      Value<int> rowid,
    });
typedef $$PreferenceEvidenceTableUpdateCompanionBuilder =
    PreferenceEvidenceCompanion Function({
      Value<String> id,
      Value<String> kind,
      Value<String> subjectKey,
      Value<int> observedAtUtc,
      Value<double?> numericValue,
      Value<bool> specialDay,
      Value<String> metadataJson,
      Value<int> rowid,
    });

class $$PreferenceEvidenceTableFilterComposer
    extends Composer<_$AppDatabase, $PreferenceEvidenceTable> {
  $$PreferenceEvidenceTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subjectKey => $composableBuilder(
    column: $table.subjectKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get observedAtUtc => $composableBuilder(
    column: $table.observedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get numericValue => $composableBuilder(
    column: $table.numericValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get specialDay => $composableBuilder(
    column: $table.specialDay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get metadataJson => $composableBuilder(
    column: $table.metadataJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PreferenceEvidenceTableOrderingComposer
    extends Composer<_$AppDatabase, $PreferenceEvidenceTable> {
  $$PreferenceEvidenceTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subjectKey => $composableBuilder(
    column: $table.subjectKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get observedAtUtc => $composableBuilder(
    column: $table.observedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get numericValue => $composableBuilder(
    column: $table.numericValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get specialDay => $composableBuilder(
    column: $table.specialDay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metadataJson => $composableBuilder(
    column: $table.metadataJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PreferenceEvidenceTableAnnotationComposer
    extends Composer<_$AppDatabase, $PreferenceEvidenceTable> {
  $$PreferenceEvidenceTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get subjectKey => $composableBuilder(
    column: $table.subjectKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get observedAtUtc => $composableBuilder(
    column: $table.observedAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<double> get numericValue => $composableBuilder(
    column: $table.numericValue,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get specialDay => $composableBuilder(
    column: $table.specialDay,
    builder: (column) => column,
  );

  GeneratedColumn<String> get metadataJson => $composableBuilder(
    column: $table.metadataJson,
    builder: (column) => column,
  );
}

class $$PreferenceEvidenceTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PreferenceEvidenceTable,
          PreferenceEvidenceData,
          $$PreferenceEvidenceTableFilterComposer,
          $$PreferenceEvidenceTableOrderingComposer,
          $$PreferenceEvidenceTableAnnotationComposer,
          $$PreferenceEvidenceTableCreateCompanionBuilder,
          $$PreferenceEvidenceTableUpdateCompanionBuilder,
          (
            PreferenceEvidenceData,
            BaseReferences<
              _$AppDatabase,
              $PreferenceEvidenceTable,
              PreferenceEvidenceData
            >,
          ),
          PreferenceEvidenceData,
          PrefetchHooks Function()
        > {
  $$PreferenceEvidenceTableTableManager(
    _$AppDatabase db,
    $PreferenceEvidenceTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PreferenceEvidenceTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PreferenceEvidenceTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PreferenceEvidenceTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> subjectKey = const Value.absent(),
                Value<int> observedAtUtc = const Value.absent(),
                Value<double?> numericValue = const Value.absent(),
                Value<bool> specialDay = const Value.absent(),
                Value<String> metadataJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PreferenceEvidenceCompanion(
                id: id,
                kind: kind,
                subjectKey: subjectKey,
                observedAtUtc: observedAtUtc,
                numericValue: numericValue,
                specialDay: specialDay,
                metadataJson: metadataJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String kind,
                required String subjectKey,
                required int observedAtUtc,
                Value<double?> numericValue = const Value.absent(),
                Value<bool> specialDay = const Value.absent(),
                required String metadataJson,
                Value<int> rowid = const Value.absent(),
              }) => PreferenceEvidenceCompanion.insert(
                id: id,
                kind: kind,
                subjectKey: subjectKey,
                observedAtUtc: observedAtUtc,
                numericValue: numericValue,
                specialDay: specialDay,
                metadataJson: metadataJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PreferenceEvidenceTable, PreferenceEvidenceData>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $PreferenceEvidenceTable,
                    PreferenceEvidenceData
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PreferenceEvidenceTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PreferenceEvidenceTable,
      PreferenceEvidenceData,
      $$PreferenceEvidenceTableFilterComposer,
      $$PreferenceEvidenceTableOrderingComposer,
      $$PreferenceEvidenceTableAnnotationComposer,
      $$PreferenceEvidenceTableCreateCompanionBuilder,
      $$PreferenceEvidenceTableUpdateCompanionBuilder,
      (
        PreferenceEvidenceData,
        BaseReferences<
          _$AppDatabase,
          $PreferenceEvidenceTable,
          PreferenceEvidenceData
        >,
      ),
      PreferenceEvidenceData,
      PrefetchHooks Function()
    >;
typedef $$PreferenceRulesTableCreateCompanionBuilder =
    PreferenceRulesCompanion Function({
      required String id,
      required String kind,
      required String subjectKey,
      required String valueJson,
      required double confidence,
      required String status,
      required String source,
      required int updatedAtUtc,
      Value<int> rowid,
    });
typedef $$PreferenceRulesTableUpdateCompanionBuilder =
    PreferenceRulesCompanion Function({
      Value<String> id,
      Value<String> kind,
      Value<String> subjectKey,
      Value<String> valueJson,
      Value<double> confidence,
      Value<String> status,
      Value<String> source,
      Value<int> updatedAtUtc,
      Value<int> rowid,
    });

class $$PreferenceRulesTableFilterComposer
    extends Composer<_$AppDatabase, $PreferenceRulesTable> {
  $$PreferenceRulesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subjectKey => $composableBuilder(
    column: $table.subjectKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get valueJson => $composableBuilder(
    column: $table.valueJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PreferenceRulesTableOrderingComposer
    extends Composer<_$AppDatabase, $PreferenceRulesTable> {
  $$PreferenceRulesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subjectKey => $composableBuilder(
    column: $table.subjectKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get valueJson => $composableBuilder(
    column: $table.valueJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PreferenceRulesTableAnnotationComposer
    extends Composer<_$AppDatabase, $PreferenceRulesTable> {
  $$PreferenceRulesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get subjectKey => $composableBuilder(
    column: $table.subjectKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get valueJson =>
      $composableBuilder(column: $table.valueJson, builder: (column) => column);

  GeneratedColumn<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<int> get updatedAtUtc => $composableBuilder(
    column: $table.updatedAtUtc,
    builder: (column) => column,
  );
}

class $$PreferenceRulesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PreferenceRulesTable,
          PreferenceRule,
          $$PreferenceRulesTableFilterComposer,
          $$PreferenceRulesTableOrderingComposer,
          $$PreferenceRulesTableAnnotationComposer,
          $$PreferenceRulesTableCreateCompanionBuilder,
          $$PreferenceRulesTableUpdateCompanionBuilder,
          (
            PreferenceRule,
            BaseReferences<
              _$AppDatabase,
              $PreferenceRulesTable,
              PreferenceRule
            >,
          ),
          PreferenceRule,
          PrefetchHooks Function()
        > {
  $$PreferenceRulesTableTableManager(
    _$AppDatabase db,
    $PreferenceRulesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PreferenceRulesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PreferenceRulesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PreferenceRulesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> subjectKey = const Value.absent(),
                Value<String> valueJson = const Value.absent(),
                Value<double> confidence = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<int> updatedAtUtc = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PreferenceRulesCompanion(
                id: id,
                kind: kind,
                subjectKey: subjectKey,
                valueJson: valueJson,
                confidence: confidence,
                status: status,
                source: source,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String kind,
                required String subjectKey,
                required String valueJson,
                required double confidence,
                required String status,
                required String source,
                required int updatedAtUtc,
                Value<int> rowid = const Value.absent(),
              }) => PreferenceRulesCompanion.insert(
                id: id,
                kind: kind,
                subjectKey: subjectKey,
                valueJson: valueJson,
                confidence: confidence,
                status: status,
                source: source,
                updatedAtUtc: updatedAtUtc,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PreferenceRulesTable, PreferenceRule>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $PreferenceRulesTable,
                    PreferenceRule
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PreferenceRulesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PreferenceRulesTable,
      PreferenceRule,
      $$PreferenceRulesTableFilterComposer,
      $$PreferenceRulesTableOrderingComposer,
      $$PreferenceRulesTableAnnotationComposer,
      $$PreferenceRulesTableCreateCompanionBuilder,
      $$PreferenceRulesTableUpdateCompanionBuilder,
      (
        PreferenceRule,
        BaseReferences<_$AppDatabase, $PreferenceRulesTable, PreferenceRule>,
      ),
      PreferenceRule,
      PrefetchHooks Function()
    >;
typedef $$ChangeLogTableCreateCompanionBuilder = ChangeLogCompanion Function({
  required String id,
  required String entityType,
  required String entityId,
  required String operation,
  required int changedAtUtc,
  required int revision,
  Value<int> rowid,
});
typedef $$ChangeLogTableUpdateCompanionBuilder = ChangeLogCompanion Function({
  Value<String> id,
  Value<String> entityType,
  Value<String> entityId,
  Value<String> operation,
  Value<int> changedAtUtc,
  Value<int> revision,
  Value<int> rowid,
});

class $$ChangeLogTableFilterComposer
    extends Composer<_$AppDatabase, $ChangeLogTable> {
  $$ChangeLogTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get operation => $composableBuilder(
    column: $table.operation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get changedAtUtc => $composableBuilder(
    column: $table.changedAtUtc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get revision => $composableBuilder(
    column: $table.revision,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ChangeLogTableOrderingComposer
    extends Composer<_$AppDatabase, $ChangeLogTable> {
  $$ChangeLogTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get operation => $composableBuilder(
    column: $table.operation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get changedAtUtc => $composableBuilder(
    column: $table.changedAtUtc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get revision => $composableBuilder(
    column: $table.revision,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ChangeLogTableAnnotationComposer
    extends Composer<_$AppDatabase, $ChangeLogTable> {
  $$ChangeLogTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<String> get operation =>
      $composableBuilder(column: $table.operation, builder: (column) => column);

  GeneratedColumn<int> get changedAtUtc => $composableBuilder(
    column: $table.changedAtUtc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get revision =>
      $composableBuilder(column: $table.revision, builder: (column) => column);
}

class $$ChangeLogTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ChangeLogTable,
          ChangeLogData,
          $$ChangeLogTableFilterComposer,
          $$ChangeLogTableOrderingComposer,
          $$ChangeLogTableAnnotationComposer,
          $$ChangeLogTableCreateCompanionBuilder,
          $$ChangeLogTableUpdateCompanionBuilder,
          (
            ChangeLogData,
            BaseReferences<_$AppDatabase, $ChangeLogTable, ChangeLogData>,
          ),
          ChangeLogData,
          PrefetchHooks Function()
        > {
  $$ChangeLogTableTableManager(_$AppDatabase db, $ChangeLogTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChangeLogTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChangeLogTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChangeLogTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> entityType = const Value.absent(),
                Value<String> entityId = const Value.absent(),
                Value<String> operation = const Value.absent(),
                Value<int> changedAtUtc = const Value.absent(),
                Value<int> revision = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ChangeLogCompanion(
                id: id,
                entityType: entityType,
                entityId: entityId,
                operation: operation,
                changedAtUtc: changedAtUtc,
                revision: revision,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String entityType,
                required String entityId,
                required String operation,
                required int changedAtUtc,
                required int revision,
                Value<int> rowid = const Value.absent(),
              }) => ChangeLogCompanion.insert(
                id: id,
                entityType: entityType,
                entityId: entityId,
                operation: operation,
                changedAtUtc: changedAtUtc,
                revision: revision,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ChangeLogTable, ChangeLogData>(table),
                  BaseReferences<_$AppDatabase, $ChangeLogTable, ChangeLogData>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ChangeLogTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ChangeLogTable,
      ChangeLogData,
      $$ChangeLogTableFilterComposer,
      $$ChangeLogTableOrderingComposer,
      $$ChangeLogTableAnnotationComposer,
      $$ChangeLogTableCreateCompanionBuilder,
      $$ChangeLogTableUpdateCompanionBuilder,
      (
        ChangeLogData,
        BaseReferences<_$AppDatabase, $ChangeLogTable, ChangeLogData>,
      ),
      ChangeLogData,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$AreasTableTableManager get areas =>
      $$AreasTableTableManager(_db, _db.areas);
  $$ProjectsTableTableManager get projects =>
      $$ProjectsTableTableManager(_db, _db.projects);
  $$TasksTableTableManager get tasks =>
      $$TasksTableTableManager(_db, _db.tasks);
  $$TagsTableTableManager get tags => $$TagsTableTableManager(_db, _db.tags);
  $$TaskTagsTableTableManager get taskTags =>
      $$TaskTagsTableTableManager(_db, _db.taskTags);
  $$RecurrenceRulesTableTableManager get recurrenceRules =>
      $$RecurrenceRulesTableTableManager(_db, _db.recurrenceRules);
  $$CalendarEventsTableTableManager get calendarEvents =>
      $$CalendarEventsTableTableManager(_db, _db.calendarEvents);
  $$EnergyWindowsTableTableManager get energyWindows =>
      $$EnergyWindowsTableTableManager(_db, _db.energyWindows);
  $$SettingsTableTableManager get settings =>
      $$SettingsTableTableManager(_db, _db.settings);
  $$PlanVersionsTableTableManager get planVersions =>
      $$PlanVersionsTableTableManager(_db, _db.planVersions);
  $$ScheduleBlocksTableTableManager get scheduleBlocks =>
      $$ScheduleBlocksTableTableManager(_db, _db.scheduleBlocks);
  $$TimeEntriesTableTableManager get timeEntries =>
      $$TimeEntriesTableTableManager(_db, _db.timeEntries);
  $$TaskCorrectionsTableTableManager get taskCorrections =>
      $$TaskCorrectionsTableTableManager(_db, _db.taskCorrections);
  $$PreferenceEvidenceTableTableManager get preferenceEvidence =>
      $$PreferenceEvidenceTableTableManager(_db, _db.preferenceEvidence);
  $$PreferenceRulesTableTableManager get preferenceRules =>
      $$PreferenceRulesTableTableManager(_db, _db.preferenceRules);
  $$ChangeLogTableTableManager get changeLog =>
      $$ChangeLogTableTableManager(_db, _db.changeLog);
}
