import re

_TEST_DATABASE_TOKEN_PATTERN = re.compile(r"(^|[_-])test([_-]|$)")


def is_safe_test_database_name(database_name: str | None) -> bool:
    if database_name is None:
        return False

    normalized = database_name.strip().lower()
    if not normalized:
        return False

    return _TEST_DATABASE_TOKEN_PATTERN.search(normalized) is not None


def assert_safe_test_database_name(database_name: str | None) -> None:
    if is_safe_test_database_name(database_name):
        return

    display_name = database_name.strip() if database_name else "<unknown>"
    raise ValueError(
        "Refusing to run destructive QA database cleanup against "
        f"{display_name!r}. Point tests/qa at a dedicated test database "
        "whose name includes 'test' as a standalone token, such as "
        "'goofyrider_test'."
    )
