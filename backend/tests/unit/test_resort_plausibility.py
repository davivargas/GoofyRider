from app.services.resort_plausibility import check_coordinates
from app.services.resort_plausibility import check_country_code
from app.services.resort_plausibility import check_elevations
from app.services.resort_plausibility import check_name
from app.services.resort_plausibility import check_text

SQUARE = {
    "type": "Polygon",
    "coordinates": [
        [[-123.1, 49.3], [-123.0, 49.3], [-123.0, 49.4], [-123.1, 49.4], [-123.1, 49.3]]
    ],
}


def test_check_name() -> None:
    assert check_name("Grouse Mountain")
    assert not check_name(None)
    assert not check_name("   ")
    assert not check_name("x" * 121)


def test_check_text_and_country_code() -> None:
    assert check_text("North Vancouver") and not check_text("") and not check_text(None)
    assert (
        check_country_code("CA")
        and not check_country_code("Canada")
        and not check_country_code(None)
    )


def test_check_coordinates_ranges_and_boundary() -> None:
    assert check_coordinates(49.35, -123.05, None)
    assert check_coordinates(49.35, -123.05, SQUARE)
    assert not check_coordinates(49.5, -123.05, SQUARE)
    assert not check_coordinates(91.0, 0.0, None)
    assert not check_coordinates(None, -123.05, None)


def test_check_elevations_pair_rules() -> None:
    assert check_elevations(880, 1250, None)
    assert not check_elevations(1250, 880, None)
    assert not check_elevations(880, None, None)
    assert not check_elevations(-5, 1250, None)
    assert not check_elevations(880, 6001, None)


def test_check_elevations_against_lift_envelope_with_tolerance() -> None:
    envelope = (895, 1231)
    assert check_elevations(880, 1250, envelope)
    assert check_elevations(745, 1381, envelope)
    assert not check_elevations(744, 1250, envelope)
    assert not check_elevations(880, 1382, envelope)
