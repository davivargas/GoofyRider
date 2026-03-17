from datetime import UTC
from datetime import datetime

from fastapi.testclient import TestClient

from app.core.dependencies import get_open_meteo_weather_provider
from app.main import app
from app.services.weather_service import WeatherSnapshotData


class StubWeatherProvider:
    def fetch(self, latitude: float, longitude: float) -> WeatherSnapshotData:
        return WeatherSnapshotData(
            observed_at=datetime.now(UTC),
            temp_c=-3.2,
            wind_kph=14.5,
            snowfall_cm_24h=12.0,
            conditions_text="Snow",
            today_high_c=-1.0,
            today_low_c=-8.0,
            snowfall_next_24h_cm=6.0,
            weather_code_text="Snow",
        )


def test_weather_endpoint_returns_resort_weather(
    client: TestClient,
    create_resort,
) -> None:
    resort = create_resort(name="Whistler", country="Canada", region="British Columbia")

    app.dependency_overrides[get_open_meteo_weather_provider] = lambda: StubWeatherProvider()
    try:
        response = client.get(f"/v1/weather/resorts/{resort.id}")
    finally:
        app.dependency_overrides.pop(get_open_meteo_weather_provider, None)

    assert response.status_code == 200
    payload = response.json()
    assert payload["resort_id"] == str(resort.id)
    assert payload["current"]["conditions_text"] == "Snow"
    assert payload["forecast_summary"]["weather_code_text"] == "Snow"


def test_weather_endpoint_missing_resort_returns_404(client: TestClient) -> None:
    app.dependency_overrides[get_open_meteo_weather_provider] = lambda: StubWeatherProvider()
    try:
        response = client.get("/v1/weather/resorts/00000000-0000-0000-0000-000000000001")
    finally:
        app.dependency_overrides.pop(get_open_meteo_weather_provider, None)

    assert response.status_code == 404
    assert response.json()["detail"] == "Resort not found."
