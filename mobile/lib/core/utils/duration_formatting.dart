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
