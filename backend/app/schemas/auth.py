from typing import Annotated

from pydantic import BaseModel
from pydantic import EmailStr
from pydantic import StringConstraints
from pydantic import field_validator


NormalizedEmail = Annotated[
    EmailStr,
    StringConstraints(max_length=255, strip_whitespace=True),
]
Password = Annotated[str, StringConstraints(min_length=8, max_length=128)]
LoginPassword = Annotated[str, StringConstraints(min_length=1, max_length=128)]
DisplayName = Annotated[str, StringConstraints(min_length=1, max_length=100, strip_whitespace=True)]
NonEmptyToken = Annotated[str, StringConstraints(min_length=1, strip_whitespace=True)]


class RegisterRequest(BaseModel):
    email: NormalizedEmail
    password: Password
    display_name: DisplayName

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: EmailStr) -> str:
        return str(value).lower()


class LoginRequest(BaseModel):
    email: NormalizedEmail
    password: LoginPassword

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: EmailStr) -> str:
        return str(value).lower()


class RefreshTokenRequest(BaseModel):
    refresh_token: NonEmptyToken


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
