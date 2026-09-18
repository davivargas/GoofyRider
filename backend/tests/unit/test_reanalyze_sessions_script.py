"""Script-level tests for app.scripts.reanalyze_sessions.main().

The repositories and service constructed inside main() are replaced with
fakes so these tests exercise only the script's own looping/counting logic:
- a session that fails every attempt must not spin the loop forever.
- --dry-run must page through every stale session, not just the first batch.
"""

from __future__ import annotations

from dataclasses import dataclass
from dataclasses import field
from types import SimpleNamespace
from typing import Any
import uuid

import pytest

from app.scripts import reanalyze_sessions
from app.services.exceptions import ServiceError


@dataclass
class _FakeSession:
    id: uuid.UUID = field(default_factory=uuid.uuid4)
    processed_by_version: str | None = None


class _FakeDb:
    def rollback(self) -> None:
        pass

    def close(self) -> None:
        pass


class _RepeatingFailureRepo:
    """A session that never gets `processed_by_version` set keeps reappearing."""

    def __init__(self, db: object) -> None:
        self._session = _FakeSession()
        self.calls = 0

    def list_needing_reanalysis(self, current_version: str, *, limit: int) -> list[_FakeSession]:
        self.calls += 1
        return [self._session]


class _AlwaysFailingService:
    def __init__(self, **kwargs: Any) -> None:
        pass

    def reanalyze_stored_session(self, ride_session: _FakeSession) -> None:
        raise ServiceError("boom")


class _PagingRepo:
    """Simulates paging forward through a fixed pool of stale sessions."""

    def __init__(self, db: object, *, total: int) -> None:
        self._sessions = [_FakeSession() for _ in range(total)]
        self._offset = 0

    def list_needing_reanalysis(self, current_version: str, *, limit: int) -> list[_FakeSession]:
        page = self._sessions[self._offset : self._offset + limit]
        self._offset += len(page)
        return page


class _UnusedService:
    def __init__(self, **kwargs: Any) -> None:
        pass


def _patch_common(monkeypatch: pytest.MonkeyPatch, *, repo_factory: Any, service_cls: type) -> None:
    monkeypatch.setattr(reanalyze_sessions, "get_session_local", lambda: lambda: _FakeDb())
    monkeypatch.setattr(
        reanalyze_sessions,
        "get_settings",
        lambda: SimpleNamespace(session_analyzer_version="analyzer@test"),
    )
    monkeypatch.setattr(reanalyze_sessions, "get_session_analyzer", lambda: object())
    monkeypatch.setattr(reanalyze_sessions, "ResortRepository", lambda db: object())
    monkeypatch.setattr(reanalyze_sessions, "SessionPointRepository", lambda db: object())
    monkeypatch.setattr(reanalyze_sessions, "SessionOverrideRepository", lambda db: object())
    monkeypatch.setattr(reanalyze_sessions, "ResortLiftRepository", lambda db: object())
    monkeypatch.setattr(reanalyze_sessions, "RideSessionRepository", repo_factory)
    monkeypatch.setattr(reanalyze_sessions, "SessionService", service_cls)


def test_main_stops_once_a_failing_session_has_been_attempted(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo_holder: dict[str, _RepeatingFailureRepo] = {}

    def _repo_factory(db: object) -> _RepeatingFailureRepo:
        repo = _RepeatingFailureRepo(db)
        repo_holder["repo"] = repo
        return repo

    _patch_common(monkeypatch, repo_factory=_repo_factory, service_cls=_AlwaysFailingService)
    monkeypatch.setattr("sys.argv", ["reanalyze_sessions"])

    reanalyze_sessions.main()

    out = capsys.readouterr().out
    assert "failed 1" in out
    # First batch: attempted and failed. Second batch: same session, already
    # attempted -> unattempted is empty -> loop stops. Never a third call.
    assert repo_holder["repo"].calls == 2


def test_dry_run_counts_every_stale_session_across_batches(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _patch_common(
        monkeypatch,
        repo_factory=lambda db: _PagingRepo(db, total=120),
        service_cls=_UnusedService,
    )
    monkeypatch.setattr("sys.argv", ["reanalyze_sessions", "--dry-run", "--batch-size", "50"])

    reanalyze_sessions.main()

    out = capsys.readouterr().out
    assert "Would re-analyze 120 session(s); failed 0" in out
