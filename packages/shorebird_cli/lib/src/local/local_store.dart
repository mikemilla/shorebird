import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A JSON-file database holding everything a hosted code push server would:
/// apps, channels, releases, patches and their artifacts.
///
/// Rows are plain JSON maps using the same snake_case keys as the code push
/// protocol, so they can be handed to the protocol's `fromJson` constructors.
/// Artifact bytes live as files under [filesDirectory].
class LocalStore {
  /// Opens (or creates) the store rooted at [root].
  LocalStore(this.root) {
    root.createSync(recursive: true);
    filesDirectory.createSync(recursive: true);
    _load();
  }

  /// The directory holding the database and artifact files.
  final Directory root;

  /// Where artifact bytes are written.
  Directory get filesDirectory => Directory(p.join(root.path, 'files'));

  File get _dbFile => File(p.join(root.path, 'db.json'));

  late Map<String, dynamic> _db;

  static const _tables = [
    'apps',
    'channels',
    'releases',
    'release_artifacts',
    'patches',
    'patch_artifacts',
  ];

  void _load() {
    _db = _dbFile.existsSync()
        ? json.decode(_dbFile.readAsStringSync()) as Map<String, dynamic>
        : <String, dynamic>{};
    for (final table in _tables) {
      _db.putIfAbsent(table, () => <dynamic>[]);
    }
    _db.putIfAbsent('next_ids', () => <String, dynamic>{});
  }

  /// Persists the database. Written to a temp file first so an interrupted
  /// write never leaves a truncated database behind.
  void save() {
    File('${_dbFile.path}.tmp')
      ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_db))
      ..renameSync(_dbFile.path);
  }

  /// All rows of [table].
  List<Map<String, dynamic>> rows(String table) =>
      (_db[table] as List).cast<Map<String, dynamic>>();

  /// Rows of [table] matching [where].
  Iterable<Map<String, dynamic>> where(
    String table,
    bool Function(Map<String, dynamic> row) where,
  ) => rows(table).where(where);

  /// The first row of [table] matching [where], or null.
  Map<String, dynamic>? find(
    String table,
    bool Function(Map<String, dynamic> row) where,
  ) {
    for (final row in rows(table)) {
      if (where(row)) return row;
    }
    return null;
  }

  /// Appends [row] to [table], assigning it the next integer id.
  Map<String, dynamic> insert(String table, Map<String, dynamic> row) {
    final ids = _db['next_ids'] as Map<String, dynamic>;
    final id = (ids[table] as int? ?? 0) + 1;
    ids[table] = id;
    final inserted = {'id': id, ...row};
    (_db[table] as List).add(inserted);
    return inserted;
  }

  /// Appends [row] to [table] as-is (for tables keyed by something other than
  /// an integer id, like apps).
  void insertRaw(String table, Map<String, dynamic> row) =>
      (_db[table] as List).add(row);

  /// Removes rows of [table] matching [where].
  void delete(String table, bool Function(Map<String, dynamic> row) where) =>
      (_db[table] as List).removeWhere(
        (row) => where(row as Map<String, dynamic>),
      );

  /// The absolute path for an artifact file stored under [key].
  String pathFor(String key) => p.join(filesDirectory.path, key);
}
