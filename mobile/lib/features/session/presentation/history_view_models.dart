import '../domain/session_models.dart';

class SessionHistoryEntryViewModel {
  const SessionHistoryEntryViewModel({
    required this.session,
    required this.resortLabel,
  });

  final LocalRideSession session;
  final String resortLabel;
}

class SessionHistorySeasonSection {
  const SessionHistorySeasonSection({
    required this.label,
    required this.items,
  });

  final String label;
  final List<SessionHistoryEntryViewModel> items;
}

List<SessionHistorySeasonSection> buildSessionHistorySections(
  List<SessionHistoryEntryViewModel> items,
) {
  final Map<String, List<SessionHistoryEntryViewModel>> grouped =
      <String, List<SessionHistoryEntryViewModel>>{};
  for (final SessionHistoryEntryViewModel item in items) {
    final String label = seasonLabelForDate(item.session.startedAt);
    grouped
        .putIfAbsent(label, () => <SessionHistoryEntryViewModel>[])
        .add(item);
  }

  final List<SessionHistorySeasonSection> sections = grouped.entries.map(
    (MapEntry<String, List<SessionHistoryEntryViewModel>> entry) {
      final List<SessionHistoryEntryViewModel> sortedItems =
          List<SessionHistoryEntryViewModel>.from(entry.value)
            ..sort(
              (SessionHistoryEntryViewModel a,
                      SessionHistoryEntryViewModel b) =>
                  b.session.startedAt.compareTo(a.session.startedAt),
            );
      return SessionHistorySeasonSection(
        label: entry.key,
        items: sortedItems,
      );
    },
  ).toList(growable: false);
  sections.sort(
    (SessionHistorySeasonSection a, SessionHistorySeasonSection b) =>
        b.label.compareTo(a.label),
  );
  return sections;
}

String seasonLabelForDate(DateTime date) {
  final int startYear = date.month >= 7 ? date.year : date.year - 1;
  final int endYear = startYear + 1;
  return '$startYear/$endYear';
}
