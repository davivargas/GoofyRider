from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.database import SessionLocal
from app.models.resort import Resort

SEED_RESORTS = [
    {
        "name": "Whistler Blackcomb",
        "country": "Canada",
        "region": "British Columbia",
        "city": "Whistler",
        "latitude": 50.1163,
        "longitude": -122.9574,
        "elevation_base_m": 675,
        "elevation_top_m": 2284,
    },
    {
        "name": "Big White",
        "country": "Canada",
        "region": "British Columbia",
        "city": "Kelowna",
        "latitude": 49.7213,
        "longitude": -118.9297,
        "elevation_base_m": 1508,
        "elevation_top_m": 2319,
    },
    {
        "name": "Sun Peaks",
        "country": "Canada",
        "region": "British Columbia",
        "city": "Sun Peaks",
        "latitude": 50.8849,
        "longitude": -119.8838,
        "elevation_base_m": 1255,
        "elevation_top_m": 2080,
    },
    {
        "name": "Revelstoke Mountain Resort",
        "country": "Canada",
        "region": "British Columbia",
        "city": "Revelstoke",
        "latitude": 50.9582,
        "longitude": -118.1638,
        "elevation_base_m": 512,
        "elevation_top_m": 2225,
    },
    {
        "name": "Fernie Alpine Resort",
        "country": "Canada",
        "region": "British Columbia",
        "city": "Fernie",
        "latitude": 49.5042,
        "longitude": -115.0855,
        "elevation_base_m": 1068,
        "elevation_top_m": 2148,
    },
    {
        "name": "Jackson Hole",
        "country": "United States",
        "region": "Wyoming",
        "city": "Teton Village",
        "latitude": 43.5875,
        "longitude": -110.8272,
        "elevation_base_m": 1924,
        "elevation_top_m": 3185,
    },
    {
        "name": "Mammoth Mountain",
        "country": "United States",
        "region": "California",
        "city": "Mammoth Lakes",
        "latitude": 37.6308,
        "longitude": -119.0326,
        "elevation_base_m": 2424,
        "elevation_top_m": 3369,
    },
    {
        "name": "Park City",
        "country": "United States",
        "region": "Utah",
        "city": "Park City",
        "latitude": 40.6514,
        "longitude": -111.5078,
        "elevation_base_m": 2070,
        "elevation_top_m": 3050,
    },
    {
        "name": "Vail",
        "country": "United States",
        "region": "Colorado",
        "city": "Vail",
        "latitude": 39.6061,
        "longitude": -106.3550,
        "elevation_base_m": 2457,
        "elevation_top_m": 3527,
    },
    {
        "name": "Aspen Snowmass",
        "country": "United States",
        "region": "Colorado",
        "city": "Snowmass Village",
        "latitude": 39.2096,
        "longitude": -106.9490,
        "elevation_base_m": 2473,
        "elevation_top_m": 3813,
    },
]


def seed_resorts(db: Session) -> tuple[int, int]:
    created_count = 0
    updated_count = 0

    for payload in SEED_RESORTS:
        existing_resort = db.scalar(
            select(Resort).where(
                Resort.name == payload["name"],
                Resort.country == payload["country"],
                Resort.region == payload["region"],
            )
        )

        if existing_resort is None:
            db.add(Resort(**payload))
            created_count += 1
            continue

        for field, value in payload.items():
            setattr(existing_resort, field, value)
        updated_count += 1

    db.commit()
    return created_count, updated_count


def main() -> None:
    with SessionLocal() as db:
        created_count, updated_count = seed_resorts(db)
    print(f"Seed complete. Created: {created_count}, Updated: {updated_count}")


if __name__ == "__main__":
    main()
