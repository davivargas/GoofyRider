import asyncio

from app.services.exceptions import ValidationError
from app.services.resort_sync_scheduler import ResortSyncScheduler


def test_run_sync_once_catches_validation_errors() -> None:
    def failing_import() -> tuple[int, int, int]:
        raise ValidationError("invalid payload")

    scheduler = ResortSyncScheduler(
        enabled=True,
        interval_days=7,
        import_resorts_fn=failing_import,
        interval_seconds_override=0.01,
    )

    asyncio.run(scheduler.run_sync_once())


def test_scheduler_runs_periodic_sync() -> None:
    sync_calls: list[int] = []

    def fake_import() -> tuple[int, int, int]:
        sync_calls.append(1)
        return 0, 0, 0

    scheduler = ResortSyncScheduler(
        enabled=True,
        interval_days=7,
        import_resorts_fn=fake_import,
        interval_seconds_override=0.01,
    )

    async def _run() -> None:
        scheduler.start()
        await asyncio.sleep(0.035)
        await scheduler.stop()

    asyncio.run(_run())

    assert len(sync_calls) >= 1


def test_scheduler_disabled_does_not_run_sync() -> None:
    sync_calls: list[int] = []

    def fake_import() -> tuple[int, int, int]:
        sync_calls.append(1)
        return 0, 0, 0

    scheduler = ResortSyncScheduler(
        enabled=False,
        interval_days=7,
        import_resorts_fn=fake_import,
        interval_seconds_override=0.01,
    )

    async def _run() -> None:
        scheduler.start()
        await asyncio.sleep(0.03)
        await scheduler.stop()

    asyncio.run(_run())

    assert sync_calls == []
