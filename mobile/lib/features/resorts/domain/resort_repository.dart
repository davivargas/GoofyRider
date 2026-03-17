import 'resort_models.dart';

abstract class ResortRepository {
  Future<ResortListResult> searchResorts({
    required String query,
    String? region,
  });

  Future<ResortSummary> getResortDetail(String resortId);
  Future<ResortSummary> toggleFavoriteResort(ResortSummary resort);
  Future<List<ResortSummary>> listFavoriteResorts();
}
