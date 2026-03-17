from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase
from sqlalchemy.orm import sessionmaker

from app.core.config import get_database_url
from app.core.config import get_sqlalchemy_echo


class Base(DeclarativeBase):
    pass


DATABASE_URL = get_database_url()

engine = create_engine(
    DATABASE_URL,
    echo=get_sqlalchemy_echo(),
)

SessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=engine,
)
