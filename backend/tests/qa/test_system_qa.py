from fastapi.testclient import TestClient
import pytest

from app.core.config import get_settings
from app.main import create_app


def test_root_endpoint_returns_running_message(client: TestClient) -> None:
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"message": "GoofyRider API is running"}


def test_health_endpoint_returns_ok_status(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_docs_hidden_by_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("DEBUG", raising=False)
    get_settings.cache_clear()
    with TestClient(create_app()) as test_client:
        assert test_client.get("/docs").status_code == 404
        assert test_client.get("/openapi.json").status_code == 404


def test_docs_available_in_debug(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DEBUG", "true")
    get_settings.cache_clear()
    with TestClient(create_app()) as test_client:
        assert test_client.get("/docs").status_code == 200
        assert test_client.get("/openapi.json").status_code == 200
