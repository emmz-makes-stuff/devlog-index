# api Specification

## Purpose

Serves beta's HTTP API.

## Requirements

### Requirement: Health check
The host SHALL answer `GET /health` with 200 when it can reach its database.

#### Scenario: Database down
- **WHEN** the database is unreachable
- **THEN** `/health` returns 503
