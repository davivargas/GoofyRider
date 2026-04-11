import 'package:intl/intl.dart';

extension DateTimeFormatting on DateTime {
  String toDayLabel() {
    return DateFormat('MMM d, yyyy').format(toLocal());
  }

  String toTimeLabel() {
    return DateFormat('h:mm a').format(toLocal());
  }
}
