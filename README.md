# GoofyRider

GoofyRider is an Android-first snowboarding tracker that records runs,
speed, vertical descent, and session statistics. The goal is to provide
riders with a simple, reliable way to track their day on the mountain
while learning modern mobile and backend architecture.

This project is also designed as a portfolio-grade full-stack system
using a modern production-style architecture.

---

# Tech Stack

## Mobile

- Flutter (Dart)
- Riverpod -- state management
- go_router -- navigation
- Dio -- API client
- Drift (SQLite) -- local caching and offline support

## Backend

- FastAPI
- Pydantic v2
- SQLAlchemy 2.0
- Alembic -- database migrations

## Database

- PostgreSQL

## DevOps

- Docker / Docker Compose -- local development
- GitHub Actions -- CI
- Render -- deployment

---

# Architecture Overview

Mobile App (Flutter) │ ▼ REST API (FastAPI) │ ▼ PostgreSQL

Key design principles:

- Mobile-first architecture
- Offline-friendly design
- Clean separation between frontend and backend
- Simple deployable backend service
- Production-style development workflow

---

# Project Structure

goofyrider/

├── backend/ \# FastAPI backend\
│ ├── app/\
│ └── alembic/

├── mobile/ \# Flutter mobile application\
│ ├── lib/\
│ └── test/

├── docker-compose.yml\
├── .env.example\
└── README.md

---

# Local Development

## Requirements

- Docker
- Docker Compose
- Python 3.12+
- Flutter SDK

## Start the database

docker compose up -d

Verify containers:

docker compose ps

Stop services:

docker compose down

---

# Environment Variables

Create a `.env` file based on `.env.example`.

Example:

POSTGRES_DB=goofyrider POSTGRES_USER=goofyrider_user
POSTGRES_PASSWORD=goofyrider_password POSTGRES_HOST=localhost
POSTGRES_PORT=5432

DATABASE_URL=postgresql+psycopg://goofyrider_user:goofyrider_password@localhost:5432/goofyrider

---

# Current Status

Phase 0 -- Project initialization

Completed:

- Repository structure
- Docker local development environment
- PostgreSQL container

Next:

- FastAPI skeleton
- Database models
- Authentication
- Run tracking API
- Flutter UI

---

# Future Features

Planned functionality includes:

- GPS run tracking
- Speed and vertical descent statistics
- Session summaries
- Leaderboards
- Offline ride recording
- Resort statistics

---

# License

This project is for educational and portfolio purposes.
