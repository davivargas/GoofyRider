import 'resort_models.dart';
import 'resort_repository.dart';

class SearchResorts {
  const SearchResorts(this._repository);

  final ResortRepository _repository;

  Future<ResortListResult> call({required String query, String? region}) {
    return _repository.searchResorts(query: query, region: region);
  }
}

class GetResortDetail {
  const GetResortDetail(this._repository);

  final ResortRepository _repository;

  Future<ResortSummary> call(String resortId) {
    return _repository.getResortDetail(resortId);
  }
}

class ToggleFavoriteResort {
  const ToggleFavoriteResort(this._repository);

  final ResortRepository _repository;

  Future<ResortSummary> call(ResortSummary resort) {
    return _repository.toggleFavoriteResort(resort);
  }
}

class ListFavoriteResorts {
  const ListFavoriteResorts(this._repository);

  final ResortRepository _repository;

  Future<List<ResortSummary>> call() {
    return _repository.listFavoriteResorts();
  }
}
