import pg from "pg";

// Connection settings come from .env
const pool = new pg.Pool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT),
  user: process.env.DB_USER,
  database: process.env.DB_NAME,
});

export async function connect() {
  const client = await pool.connect();
  console.log("Connected to", process.env.DB_NAME);
  return client;
}
