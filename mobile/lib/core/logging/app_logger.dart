import 'package:flutter/foundation.dart';

class AppLogger {
  const AppLogger();

  void info(String message, {Object? data}) {
    if (kDebugMode) {
      debugPrint('[INFO] $message ${data ?? ''}'.trim());
    }
  }

  void warning(String message, {Object? data}) {
    if (kDebugMode) {
      debugPrint('[WARN] $message ${data ?? ''}'.trim());
    }
  }

  void error(String message, {Object? error, StackTrace? stackTrace}) {
    if (kDebugMode) {
      debugPrint('[ERROR] $message ${error ?? ''}'.trim());
      if (stackTrace != null) {
        debugPrint(stackTrace.toString());
      }
    }
  }
}
