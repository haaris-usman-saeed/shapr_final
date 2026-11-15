# Connecting to PostgreSQL (Aurora wiki)

The API reads DB_HOST and DB_PORT from .env.
ECONNREFUSED means nothing is listening at that host and port.
Check that Postgres is running, and that DB_HOST and DB_PORT
point to where it actually runs.
