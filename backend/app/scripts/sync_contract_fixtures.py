"""Copy the shared contract fixtures to the mobile test tree. Run from backend/."""

from pathlib import Path
import shutil

_BACKEND = Path(__file__).resolve().parents[2]
SOURCE = _BACKEND / "tests" / "fixtures" / "contracts"
TARGET = _BACKEND.parent / "mobile" / "test" / "fixtures" / "contracts"


def main() -> None:
    TARGET.mkdir(parents=True, exist_ok=True)
    for path in sorted(SOURCE.glob("*.json")):
        shutil.copyfile(path, TARGET / path.name)
        print(f"copied {path.name}")


if __name__ == "__main__":
    main()
