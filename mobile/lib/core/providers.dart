import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'logging/app_logger.dart';
import 'network/dio_client.dart';
import 'storage/drift_local_database.dart';
import 'storage/token_storage.dart';

final loggerProvider = Provider<AppLogger>((ref) => const AppLogger());

final tokenStorageProvider = Provider<TokenStorage>(
  (ref) => SecureTokenStorage(const FlutterSecureStorage()),
);

final baseDioProvider = Provider<Dio>((ref) => buildBaseDio());

final driftLocalDatabaseProvider = Provider<DriftLocalDatabase>(
  (ref) => throw UnimplementedError('driftLocalDatabaseProvider must be overridden at app bootstrap'),
);
