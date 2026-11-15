// Connects to the database named in DATABASE_URL. Plain TCP, so the demo needs no packages.
const net = require("node:net");

function connect(databaseUrl) {
  const url = new URL(databaseUrl);
  return new Promise((resolve, reject) => {
    const socket = net.connect(Number(url.port || 5432), url.hostname);
    socket.once("connect", () => { socket.end(); resolve(url.host); });
    socket.once("error", (e) => reject(new Error(`connect ${e.code} ${e.address}:${e.port}`)));
  });
}

module.exports = { connect };
