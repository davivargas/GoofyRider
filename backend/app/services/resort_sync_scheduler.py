import asyncio
import logging
from collections.abc import Callable

from app.scripts.import_resorts import import_resorts
from app.services.exceptions import ServiceUnavailableError
from app.services.exceptions import ValidationError

logger = logging.getLogger(__name__)


class ResortSyncScheduler:
    def __init__(
        self,
        enabled: bool,
        interval_days: int,
        import_resorts_fn: Callable[[], tuple[int, int, int]] = import_resorts,
        interval_seconds_override: float | None = None,
    ) -> None:
        self._enabled = enabled
        self._interval_days = interval_days
        self._interval_seconds = (
            interval_seconds_override
            if interval_seconds_override is not None
            else float(interval_days * 24 * 60 * 60)
        )
        self._import_resorts = import_resorts_fn
        self._stop_event = asyncio.Event()
        self._task: asyncio.Task[None] | None = None

    def start(self) -> None:
        if not self._enabled:
            logger.info("Resort sync scheduler disabled by configuration.")
            return

        if self._task is not None and not self._task.done():
            return

        logger.info(
            "Resort sync scheduler started. Next sync runs every %s day(s).",
            self._interval_days,
        )
        self._stop_event.clear()
        self._task = asyncio.create_task(self._run_loop(), name="resort-sync-scheduler")

    async def stop(self) -> None:
        if self._task is None:
            return

        self._stop_event.set()
        await self._task
        self._task = None

    async def _run_loop(self) -> None:
        while not self._stop_event.is_set():
            try:
                await asyncio.wait_for(self._stop_event.wait(), timeout=self._interval_seconds)
                return
            except TimeoutError:
                await self.run_sync_once()

    async def run_sync_once(self) -> None:
        logger.info("Running scheduled resort sync from SkiAPI.")
        try:
            created_count, updated_count, deactivated_count = await asyncio.to_thread(
                self._import_resorts
            )
        except (ServiceUnavailableError, ValidationError, ValueError) as exc:
            logger.warning("Scheduled resort sync failed: %s", exc)
            return
        except Exception:
            logger.exception("Scheduled resort sync failed unexpectedly.")
            return

        logger.info(
            "Scheduled resort sync complete. Created: %s, Updated: %s, Deactivated: %s",
            created_count,
            updated_count,
            deactivated_count,
        )
