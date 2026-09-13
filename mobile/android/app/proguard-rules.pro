# Flutter's gradle plugin and the Play Services aars ship their own consumer
# keep rules; manifest-declared components are kept by AGP defaults. Add a
# targeted -keep here only for a class that is actually reached by reflection.
-dontwarn io.flutter.embedding.**
