from unittest.mock import MagicMock

from app.services.session_service import SessionService


def test_reanalyze_stored_session_runs_analysis_with_overrides_and_commits() -> None:
    service = SessionService(
        ride_session_repository=MagicMock(),
        resort_repository=MagicMock(),
        session_point_repository=MagicMock(),
        session_override_repository=MagicMock(),
        session_analyzer=MagicMock(),
    )
    service._run_analysis = MagicMock()  # type: ignore[method-assign]
    ride_session = MagicMock()

    service.reanalyze_stored_session(ride_session)

    service._run_analysis.assert_called_once_with(ride_session, include_overrides=True)
    service._ride_session_repository.commit.assert_called_once()
