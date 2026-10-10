import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/local/local_store.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// The origin [LocalCodePushHttpClient] answers for. Never resolved on the
/// network: every request is handled in this process.
final localHostedUri = Uri.parse('http://shorebird.local');

/// An [http.Client] that implements the code push API in-process against a
/// [LocalStore], so the stock [CodePushClient] works with no server at all.
///
/// Uploads use the resumable protocol (`PUT` with `Content-Range`), which
/// writes straight into the store's files directory. Artifact download URLs
/// are `file://` URIs.
class LocalCodePushHttpClient extends http.BaseClient {
  /// Creates a client backed by [store].
  LocalCodePushHttpClient(this.store);

  /// The store holding apps, releases and patches.
  final LocalStore store;

  static final _routes =
      <
        (
          String,
          RegExp,
          _Response Function(
            LocalCodePushHttpClient,
            _LocalRequest,
            List<String>,
          ),
        )
      >[
        ('GET', RegExp(r'^/api/v1/users/me$'), (c, r, m) => c._currentUser()),
        (
          'GET',
          RegExp(r'^/api/v1/plan$'),
          (c, r, m) => _json({'level': 'local'}),
        ),
        ('GET', RegExp(r'^/api/v1/organizations$'), (c, r, m) => c._orgs()),
        ('GET', RegExp(r'^/api/v1/apps$'), (c, r, m) => c._getApps()),
        ('POST', RegExp(r'^/api/v1/apps$'), (c, r, m) => c._createApp(r)),
        (
          'GET',
          RegExp(r'^/api/v1/apps/([^/]+)$'),
          (c, r, m) => c._getApp(m[0]),
        ),
        (
          'PATCH',
          RegExp(r'^/api/v1/apps/([^/]+)$'),
          (c, r, m) => c._updateApp(m[0], r),
        ),
        (
          'DELETE',
          RegExp(r'^/api/v1/apps/([^/]+)$'),
          (c, r, m) => c._deleteApp(m[0]),
        ),
        (
          'GET',
          RegExp(r'^/api/v1/apps/([^/]+)/channels$'),
          (c, r, m) => c._getChannels(m[0]),
        ),
        (
          'POST',
          RegExp(r'^/api/v1/apps/([^/]+)/channels$'),
          (c, r, m) => c._createChannel(m[0], r),
        ),
        (
          'DELETE',
          RegExp(r'^/api/v1/apps/([^/]+)/channels/(\d+)$'),
          (c, r, m) => c._deleteChannel(m[0], int.parse(m[1])),
        ),
        (
          'GET',
          RegExp(r'^/api/v1/apps/([^/]+)/releases$'),
          (c, r, m) => c._getReleases(m[0], r),
        ),
        (
          'POST',
          RegExp(r'^/api/v1/apps/([^/]+)/releases$'),
          (c, r, m) => c._createRelease(m[0], r),
        ),
        (
          'PATCH',
          RegExp(r'^/api/v1/apps/([^/]+)/releases/(\d+)$'),
          (c, r, m) => c._updateRelease(m[0], int.parse(m[1]), r),
        ),
        (
          'GET',
          RegExp(r'^/api/v1/apps/([^/]+)/releases/(\d+)/artifacts$'),
          (c, r, m) => c._getReleaseArtifacts(int.parse(m[1]), r),
        ),
        (
          'POST',
          RegExp(r'^/api/v1/apps/([^/]+)/releases/(\d+)/artifacts$'),
          (c, r, m) => c._createReleaseArtifact(m[0], int.parse(m[1]), r),
        ),
        (
          'GET',
          RegExp(r'^/api/v1/apps/([^/]+)/releases/(\d+)/patches$'),
          (c, r, m) => c._getPatches(int.parse(m[1])),
        ),
        (
          'POST',
          RegExp(
            r'^/api/v1/apps/([^/]+)/releases/(\d+)/patches/(\d+)/rollback$',
          ),
          (c, r, m) => c._setRolledBack(int.parse(m[2]), rolledBack: true),
        ),
        (
          'POST',
          RegExp(
            r'^/api/v1/apps/([^/]+)/releases/(\d+)/patches/(\d+)/rollforward$',
          ),
          (c, r, m) => c._setRolledBack(int.parse(m[2]), rolledBack: false),
        ),
        (
          'POST',
          RegExp(r'^/api/v1/apps/([^/]+)/patches$'),
          (c, r, m) => c._createPatch(m[0], r),
        ),
        (
          'POST',
          RegExp(r'^/api/v1/apps/([^/]+)/patches/promote$'),
          (c, r, m) => c._promotePatch(m[0], r),
        ),
        (
          'POST',
          RegExp(r'^/api/v1/apps/([^/]+)/patches/(\d+)/artifacts$'),
          (c, r, m) => c._createPatchArtifact(m[0], int.parse(m[1]), r),
        ),
        (
          'PUT',
          RegExp(r'^/upload/(release_artifacts|patch_artifacts)/(\d+)$'),
          (c, r, m) => c._upload(m[0], int.parse(m[1]), r),
        ),
      ];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = await _LocalRequest.from(request);
    for (final (method, pattern, handler) in _routes) {
      if (method != request.method) continue;
      final match = pattern.firstMatch(request.url.path);
      if (match == null) continue;
      final groups = [
        for (var i = 1; i <= match.groupCount; i++) match.group(i)!,
      ];
      final _Response response;
      try {
        response = handler(this, req, groups);
      } on _HttpError catch (e) {
        return _error(e.status, e.message).toStreamed(request);
      }
      return response.toStreamed(request);
    }
    return _error(
      HttpStatus.notFound,
      'Not supported in local mode: ${request.method} ${request.url.path}',
    ).toStreamed(request);
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();

  _Response _currentUser() => _json(
    PrivateUser(
      id: 1,
      email: 'local@${Platform.localHostname}',
      displayName: 'Local',
      jwtIssuer: 'local',
      hasActiveSubscription: true,
    ).toJson(),
  );

  _Response _orgs() => _json(
    GetOrganizationsResponse(
      organizations: [
        OrganizationMembership(
          organization: Organization(
            id: 1,
            name: 'Local',
            organizationType: OrganizationType.personal,
            createdAt: DateTime.utc(2024),
            updatedAt: DateTime.utc(2024),
          ),
          role: Role.owner,
        ),
      ],
    ).toJson(),
  );

  Map<String, dynamic> _app(String appId) =>
      store.find('apps', (a) => a['app_id'] == appId) ??
      (throw _HttpError(HttpStatus.notFound, 'App $appId not found.'));

  AppMetadata _appMetadata(Map<String, dynamic> app) {
    final appId = app['app_id'] as String;
    final releases = store
        .where('releases', (r) => r['app_id'] == appId)
        .toList();
    final latestRelease = releases.lastOrNull;
    final latestPatch = latestRelease == null
        ? null
        : store
              .where('patches', (pa) => pa['release_id'] == latestRelease['id'])
              .lastOrNull;
    return AppMetadata.fromJson({
      ...app,
      'latest_release_version': latestRelease?['version'],
      'latest_patch_number': latestPatch?['number'],
    });
  }

  _Response _getApps() => _json(
    GetAppsResponse(
      apps: store.rows('apps').map(_appMetadata).toList(),
    ).toJson(),
  );

  _Response _getApp(String appId) => _json(_appMetadata(_app(appId)).toJson());

  _Response _createApp(_LocalRequest r) {
    final body = CreateAppRequest.fromJson(r.json);
    final now = _now();
    final app = {
      'app_id': _uuid(),
      'display_name': body.displayName,
      'created_at': now,
      'updated_at': now,
    };
    store
      ..insertRaw('apps', app)
      ..save();
    return _json(
      App(id: app['app_id']!, displayName: body.displayName).toJson(),
    );
  }

  _Response _updateApp(String appId, _LocalRequest r) {
    _app(appId)
      ..['display_name'] = r.json['name']
      ..['updated_at'] = _now();
    store.save();
    return _empty();
  }

  _Response _deleteApp(String appId) {
    _app(appId);
    final releaseIds = store
        .where('releases', (r) => r['app_id'] == appId)
        .map((r) => r['id'])
        .toSet();
    final patchIds = store
        .where('patches', (pa) => releaseIds.contains(pa['release_id']))
        .map((pa) => pa['id'])
        .toSet();
    store
      ..delete('apps', (a) => a['app_id'] == appId)
      ..delete('channels', (c) => c['app_id'] == appId)
      ..delete('releases', (r) => r['app_id'] == appId)
      ..delete('release_artifacts', (a) => releaseIds.contains(a['release_id']))
      ..delete('patches', (pa) => patchIds.contains(pa['id']))
      ..delete('patch_artifacts', (a) => patchIds.contains(a['patch_id']))
      ..save();
    return _empty();
  }

  _Response _getChannels(String appId) => _json([
    for (final c in store.where('channels', (c) => c['app_id'] == appId))
      Channel.fromJson(c).toJson(),
  ]);

  _Response _createChannel(String appId, _LocalRequest r) {
    _app(appId);
    final name = r.json['channel'] as String;
    final existing = store.find(
      'channels',
      (c) => c['app_id'] == appId && c['name'] == name,
    );
    final channel =
        existing ?? store.insert('channels', {'app_id': appId, 'name': name});
    store.save();
    return _json(Channel.fromJson(channel).toJson());
  }

  _Response _deleteChannel(String appId, int channelId) {
    store
      ..delete('channels', (c) => c['id'] == channelId)
      ..save();
    return _empty();
  }

  Map<String, dynamic> _release(int releaseId) =>
      store.find('releases', (r) => r['id'] == releaseId) ??
      (throw _HttpError(HttpStatus.notFound, 'Release $releaseId not found.'));

  _Response _getReleases(String appId, _LocalRequest r) {
    final sideloadableOnly = r.query['sideloadable'] == 'true';
    final releases = <Release>[];
    final rows = store.where('releases', (rel) => rel['app_id'] == appId);
    for (final row in rows) {
      var release = Release.fromJson(row);
      if (sideloadableOnly) {
        final sideloadable = store
            .where(
              'release_artifacts',
              (a) => a['release_id'] == row['id'] && a['can_sideload'] == true,
            )
            .map((a) => a['platform'] as String)
            .toSet();
        final statuses = {
          for (final entry in release.platformStatuses.entries)
            if (sideloadable.contains(entry.key.name)) entry.key: entry.value,
        };
        if (statuses.isEmpty) continue;
        release = Release.fromJson({
          ...row,
          'platform_statuses': {
            for (final e in statuses.entries) e.key.name: e.value.toJson(),
          },
        });
      }
      releases.add(release);
    }
    return _json(GetReleasesResponse(releases: releases).toJson());
  }

  _Response _createRelease(String appId, _LocalRequest r) {
    _app(appId);
    final version = r.json['version'] as String;
    final existing = store.find(
      'releases',
      (rel) => rel['app_id'] == appId && rel['version'] == version,
    );
    if (existing != null) {
      throw _HttpError(
        HttpStatus.conflict,
        'Release $version already exists for app $appId.',
      );
    }
    final now = _now();
    final release = store.insert('releases', {
      'app_id': appId,
      'version': version,
      'flutter_revision': r.json['flutter_revision'],
      'flutter_version': r.json['flutter_version'],
      'display_name': r.json['display_name'],
      'platform_statuses': <String, dynamic>{},
      'created_at': now,
      'updated_at': now,
    });
    store.save();
    return _json(
      CreateReleaseResponse(release: Release.fromJson(release)).toJson(),
    );
  }

  _Response _updateRelease(String appId, int releaseId, _LocalRequest r) {
    final body = UpdateReleaseRequest.fromJson(r.json);
    final release = _release(releaseId);
    if (body.status != null && body.platform != null) {
      (release['platform_statuses']
          as Map<String, dynamic>)[body.platform!.name] = body.status!
          .toJson();
    }
    if (body.notes != null) release['notes'] = body.notes;
    release['updated_at'] = _now();
    store.save();
    return _empty();
  }

  _Response _getReleaseArtifacts(int releaseId, _LocalRequest r) {
    final arch = r.query['arch'];
    final platform = r.query['platform'];
    final artifacts = store
        .where(
          'release_artifacts',
          (a) =>
              a['release_id'] == releaseId &&
              a['uploaded'] == true &&
              (arch == null || a['arch'] == arch) &&
              (platform == null || a['platform'] == platform),
        )
        .map(ReleaseArtifact.fromJson)
        .toList();
    return _json(GetReleaseArtifactsResponse(artifacts: artifacts).toJson());
  }

  _Response _createReleaseArtifact(
    String appId,
    int releaseId,
    _LocalRequest r,
  ) {
    _release(releaseId);
    final body = CreateReleaseArtifactRequest.fromJson({
      ...r.fields,
      'size': int.parse(r.fields['size']!),
      if (r.fields['can_sideload'] != null)
        'can_sideload': r.fields['can_sideload'] == 'true',
    });
    // Re-running a release replaces the previous upload of the same artifact.
    store.delete(
      'release_artifacts',
      (a) =>
          a['release_id'] == releaseId &&
          a['arch'] == body.arch &&
          a['platform'] == body.platform.name,
    );
    final key = p.join(
      appId,
      'releases',
      '$releaseId',
      body.platform.name,
      body.arch,
      body.filename,
    );
    final path = store.pathFor(key);
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync([]);
    final artifact = store.insert('release_artifacts', {
      'release_id': releaseId,
      'arch': body.arch,
      'platform': body.platform.name,
      'hash': body.hash,
      'size': body.size,
      'url': Uri.file(path).toString(),
      'podfile_lock_hash': body.podfileLockHash,
      'can_sideload': body.canSideload ?? false,
      'path': path,
      'uploaded': body.size == 0,
    });
    store.save();
    return _json(
      CreateReleaseArtifactResponse(
        id: artifact['id'] as int,
        releaseId: releaseId,
        arch: body.arch,
        platform: body.platform,
        hash: body.hash,
        size: body.size,
        url: _uploadUrl('release_artifacts', artifact['id'] as int),
        uploadMethod: ArtifactUploadMethod.resumable,
      ).toJson(),
    );
  }

  _Response _getPatches(int releaseId) {
    final patches = [
      for (final patch in store.where(
        'patches',
        (pa) => pa['release_id'] == releaseId,
      ))
        ReleasePatch(
          id: patch['id'] as int,
          number: patch['number'] as int,
          channel: patch['channel'] as String?,
          isRolledBack: patch['is_rolled_back'] as bool,
          notes: patch['notes'] as String?,
          artifacts: store
              .where(
                'patch_artifacts',
                (a) => a['patch_id'] == patch['id'] && a['uploaded'] == true,
              )
              .map(PatchArtifact.fromJson)
              .toList(),
        ),
    ];
    return _json(GetReleasePatchesResponse(patches: patches).toJson());
  }

  _Response _setRolledBack(int patchId, {required bool rolledBack}) {
    final patch =
        store.find('patches', (pa) => pa['id'] == patchId) ??
        (throw _HttpError(HttpStatus.notFound, 'Patch $patchId not found.'));
    if (patch['is_rolled_back'] == rolledBack) {
      return const _Response(HttpStatus.notModified, null);
    }
    patch['is_rolled_back'] = rolledBack;
    store.save();
    return _empty();
  }

  _Response _createPatch(String appId, _LocalRequest r) {
    final body = CreatePatchRequest.fromJson(r.json);
    _release(body.releaseId);
    final numbers = store
        .where('patches', (pa) => pa['release_id'] == body.releaseId)
        .map((pa) => pa['number'] as int);
    final patch = store.insert('patches', {
      'app_id': appId,
      'release_id': body.releaseId,
      'number': numbers.fold(0, max) + 1,
      'channel': null,
      'is_rolled_back': false,
      'notes': null,
      'metadata': body.metadata,
      'created_at': _now(),
    });
    store.save();
    return _json(
      Patch(id: patch['id'] as int, number: patch['number'] as int).toJson(),
    );
  }

  _Response _promotePatch(String appId, _LocalRequest r) {
    final body = PromotePatchRequest.fromJson(r.json);
    final channel =
        store.find('channels', (c) => c['id'] == body.channelId) ??
        (throw _HttpError(HttpStatus.notFound, 'Channel not found.'));
    final patch =
        store.find('patches', (pa) => pa['id'] == body.patchId) ??
        (throw _HttpError(HttpStatus.notFound, 'Patch not found.'));
    patch['channel'] = channel['name'];
    store.save();
    return _empty();
  }

  _Response _createPatchArtifact(String appId, int patchId, _LocalRequest r) {
    final patch =
        store.find('patches', (pa) => pa['id'] == patchId) ??
        (throw _HttpError(HttpStatus.notFound, 'Patch $patchId not found.'));
    final f = r.fields;
    final platform = ReleasePlatform.fromJson(f['platform']!);
    final arch = f['arch']!;
    final size = int.parse(f['size']!);
    final key = p.join(
      appId,
      'patches',
      '${patch['release_id']}',
      '${patch['number']}',
      platform.name,
      arch,
    );
    final path = store.pathFor(key);
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync([]);
    final artifact = store.insert('patch_artifacts', {
      'patch_id': patchId,
      'arch': arch,
      'platform': platform.name,
      'hash': f['hash'],
      'hash_signature': f['hash_signature'],
      'podfile_lock_hash': f['podfile_lock_hash'],
      'size': size,
      'created_at': _now(),
      'path': path,
      'uploaded': size == 0,
    });
    store.save();
    return _json(
      CreatePatchArtifactResponse(
        id: artifact['id'] as int,
        patchId: patchId,
        arch: arch,
        platform: platform,
        hash: f['hash']!,
        size: size,
        url: _uploadUrl('patch_artifacts', artifact['id'] as int),
        uploadMethod: ArtifactUploadMethod.resumable,
      ).toJson(),
    );
  }

  String _uploadUrl(String table, int id) =>
      localHostedUri.replace(path: '/upload/$table/$id').toString();

  /// Writes one chunk of a resumable upload, mirroring the GCS protocol the
  /// client speaks: 308 with a `range` header until the last byte arrives.
  _Response _upload(String table, int id, _LocalRequest r) {
    final artifact =
        store.find(table, (a) => a['id'] == id) ??
        (throw _HttpError(HttpStatus.notFound, 'Upload $id not found.'));
    final file = File(artifact['path'] as String);
    final range = RegExp(
      r'bytes (\d+)-(\d+)/(\d+)',
    ).firstMatch(r.headers['content-range'] ?? '');
    if (range == null) {
      // A `bytes */total` status query: report how much we have.
      final have = file.lengthSync();
      return have >= (artifact['size'] as int)
          ? _empty()
          : _Response(HttpStatus.permanentRedirect, null, {
              if (have > 0) 'range': 'bytes=0-${have - 1}',
            });
    }
    final start = int.parse(range.group(1)!);
    final end = int.parse(range.group(2)!);
    final total = int.parse(range.group(3)!);
    file.openSync(mode: FileMode.append)
      ..truncateSync(start)
      ..setPositionSync(start)
      ..writeFromSync(r.bodyBytes)
      ..closeSync();
    if (end + 1 >= total) {
      artifact['uploaded'] = true;
      store.save();
      return _empty();
    }
    return _Response(HttpStatus.permanentRedirect, null, {
      'range': 'bytes=0-$end',
    });
  }

  static String _uuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return [
      hex.substring(0, 8),
      hex.substring(8, 12),
      hex.substring(12, 16),
      hex.substring(16, 20),
      hex.substring(20),
    ].join('-');
  }
}

class _HttpError implements Exception {
  _HttpError(this.status, this.message);
  final int status;
  final String message;
}

_Response _json(Object body) => _Response(HttpStatus.ok, body);

_Response _empty() => const _Response(HttpStatus.ok, null);

_Response _error(int status, String message) =>
    _Response(status, {'code': 'local_error', 'message': message});

class _Response {
  const _Response(this.status, this.body, [this.headers = const {}]);
  final int status;
  final Object? body;
  final Map<String, String> headers;

  http.StreamedResponse toStreamed(http.BaseRequest request) {
    final bytes = body == null ? <int>[] : utf8.encode(json.encode(body));
    return http.StreamedResponse(
      Stream.value(bytes),
      status,
      contentLength: bytes.length,
      request: request,
      headers: {'content-type': 'application/json', ...headers},
    );
  }
}

class _LocalRequest {
  _LocalRequest(this.bodyBytes, this.fields, this.headers, this.query);

  static Future<_LocalRequest> from(http.BaseRequest request) async {
    if (request is http.MultipartRequest) {
      return _LocalRequest(
        const [],
        request.fields,
        request.headers,
        request.url.queryParameters,
      );
    }
    final bytes = await request.finalize().toBytes();
    return _LocalRequest(
      bytes,
      const {},
      request.headers,
      request.url.queryParameters,
    );
  }

  final List<int> bodyBytes;
  final Map<String, String> fields;
  final Map<String, String> headers;
  final Map<String, String> query;

  Map<String, dynamic> get json => bodyBytes.isEmpty
      ? const {}
      : jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
}
