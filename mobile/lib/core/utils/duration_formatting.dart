extension DurationFormatting on Duration {
  String toHoursMinutesSeconds() {
    final totalSeconds = inSeconds < 0 ? 0 : inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
}

String formatSecondsAsDuration(int seconds) {
  return Duration(seconds: seconds).toHoursMinutesSeconds();
}

/// `04:12` (hours:minutes), for one-line session summaries.
String formatSecondsAsHoursMinutes(int seconds) {
  final total = seconds < 0 ? 0 : seconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}';
}

/// `02:19` (minutes:seconds), or `1:02:19` once past an hour, for timeline rows.
String formatSecondsCompact(int seconds) {
  final total = seconds < 0 ? 0 : seconds;
  final hours = total ~/ 3600;
  final minutes = ((total % 3600) ~/ 60).toString().padLeft(2, '0');
  final secs = (total % 60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$secs' : '$minutes:$secs';
}
