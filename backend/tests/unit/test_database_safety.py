import pytest

from app.core.database_safety import assert_safe_test_database_name
from app.core.database_safety import is_safe_test_database_name


@pytest.mark.parametrize(
    ("database_name", "expected"),
    [
        ("goofyrider_test", True),
        ("test_goofyrider", True),
        ("GoofyRider-Test", True),
        ("test", True),
        ("goofyrider", False),
        ("production", False),
        ("contest", False),
        ("", False),
        (None, False),
    ],
)
def test_is_safe_test_database_name(
    database_name: str | None,
    expected: bool,
) -> None:
    assert is_safe_test_database_name(database_name) is expected


def test_assert_safe_test_database_name_rejects_non_test_name() -> None:
    with pytest.raises(
        ValueError,
        match="Refusing to run destructive QA database cleanup",
    ):
        assert_safe_test_database_name("goofyrider")


def test_assert_safe_test_database_name_allows_test_name() -> None:
    assert_safe_test_database_name("goofyrider_test")
