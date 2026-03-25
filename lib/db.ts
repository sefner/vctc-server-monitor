import Database from 'better-sqlite3';
import path from 'path';

const DB_PATH = process.env.DB_PATH || path.join(process.cwd(), 'monitor.db');

let _db: Database.Database | null = null;

export function getDb(): Database.Database {
    if (!_db) {
        _db = new Database(DB_PATH);
        _db.pragma('journal_mode = WAL');
        _db.pragma('foreign_keys = ON');
        initSchema(_db);
    }
    return _db;
}

function initSchema(db: Database.Database) {
    db.exec(`
        CREATE TABLE IF NOT EXISTS servers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            hostname TEXT NOT NULL UNIQUE,
            description TEXT,
            api_key TEXT NOT NULL UNIQUE,
            active INTEGER DEFAULT 1,
            created_at TEXT DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS checkins (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            server_id INTEGER NOT NULL REFERENCES servers(id),
            checked_in_at TEXT DEFAULT (datetime('now')),
            os_info TEXT,
            disks TEXT,
            pending_updates INTEGER,
            last_update_installed TEXT,
            services TEXT,
            veeam_last_job TEXT,
            uptime_seconds INTEGER
        );

        CREATE TABLE IF NOT EXISTS backup_status (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            computer_name TEXT NOT NULL,
            plan_name TEXT NOT NULL,
            last_run_at TEXT,
            status TEXT,
            size_bytes INTEGER,
            duration_seconds INTEGER,
            synced_at TEXT DEFAULT (datetime('now')),
            UNIQUE(computer_name, plan_name)
        );

        CREATE TABLE IF NOT EXISTS alerts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            server_id INTEGER REFERENCES servers(id),
            type TEXT NOT NULL,
            message TEXT NOT NULL,
            severity TEXT DEFAULT 'warning',
            created_at TEXT DEFAULT (datetime('now')),
            resolved_at TEXT,
            notified INTEGER DEFAULT 0
        );
    `);
}
