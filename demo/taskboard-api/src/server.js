const { connect } = require("./db");

console.log("Server listening on port 3000");
connect(process.env.DATABASE_URL || "postgres://app@localhost:5432/taskboard")
  .then((host) => console.log(`Connected to database at ${host}`))
  .catch((e) => { console.error(`Error: ${e.message}`); process.exitCode = 1; });
