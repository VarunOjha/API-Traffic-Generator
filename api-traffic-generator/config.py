import os
from pydantic import BaseModel, Field

class Settings(BaseModel):
    base_url: str = Field(..., alias="BASE_URL")
    api_token: str | None = Field(default=None, alias="API_TOKEN")  # e.g., Bearer token
    connect_timeout: float = Field(default=3.0, alias="CONNECT_TIMEOUT")
    read_timeout: float = Field(default=10.0, alias="READ_TIMEOUT")
    log_level: str = Field(default="INFO", alias="LOG_LEVEL")

    # How long a scenario should run when looping (seconds)
    duration_seconds: int = Field(default=60, alias="DURATION_SECONDS")

    class Config:
        populate_by_name = True

def get_settings() -> Settings:
    return Settings(
        **{k: v for k, v in os.environ.items() if k in {
            "BASE_URL","API_TOKEN","CONNECT_TIMEOUT","READ_TIMEOUT","LOG_LEVEL","DURATION_SECONDS"
        }}
    )
