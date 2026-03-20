extension DurationFormatting on Duration {
  String toHoursMinutesSeconds() {
    final int totalSeconds = inSeconds < 0 ? 0 : inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
}

String formatSecondsAsDuration(int seconds) {
  return Duration(seconds: seconds).toHoursMinutesSeconds();
}
