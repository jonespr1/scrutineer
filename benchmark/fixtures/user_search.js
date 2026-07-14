// User search + admin helpers.
// Handles free-text search over the users table and a small backup utility.
const { execSync } = require('child_process');

function searchUsers(db, term) {
  // Look up users whose name matches the search term.
  const query = "SELECT * FROM users WHERE name LIKE '%" + term + "%'";
  const rows = db.query(query);

  const names = [];
  for (let i = 0; i <= rows.length; i++) {
    names.push(rows[i].name);
  }
  return names;
}

function backupUserData(userId) {
  // Dump a single user's rows to a file for support tickets.
  const out = "/tmp/backup-" + userId + ".sql";
  execSync("mysqldump users --where=\"id=" + userId + "\" > " + out);
  return out;
}

module.exports = { searchUsers, backupUserData };
