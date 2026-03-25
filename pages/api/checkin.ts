import type { NextApiRequest, NextApiResponse } from 'next';
import { getDb } from '@/lib/db';

export default function handler(req: NextApiRequest, res: NextApiResponse) {
    if (req.method !== 'POST') return res.status(405).json({ message: 'Method not allowed' });

    const apiKey = req.headers['x-api-key'];
    if (!apiKey) return res.status(401).json({ message: 'Missing x-api-key header' });

    const db = getDb();
    const server = db.prepare(`SELECT * FROM servers WHERE api_key = ? AND active = 1`).get(apiKey) as any;
    if (!server) return res.status(401).json({ message: 'Invalid API key' });

    const {
        os_info,
        disks,                // [{ drive, total_gb, free_gb, used_pct }]
        pending_updates,
        last_update_installed,
        services,             // [{ name, display_name, status }]
        cloudberry_jobs,      // [{ plan_name, status, date_start_utc, duration_seconds, total_size_bytes, error_message }]
        uptime_seconds,
    } = req.body;

    db.prepare(`
        INSERT INTO checkins (server_id, os_info, disks, pending_updates, last_update_installed,
                              services, veeam_last_job, uptime_seconds)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
        server.id,
        os_info || null,
        disks ? JSON.stringify(disks) : null,
        pending_updates ?? null,
        last_update_installed || null,
        services ? JSON.stringify(services) : null,
        cloudberry_jobs ? JSON.stringify(cloudberry_jobs) : null,
        uptime_seconds ?? null,
    );

    // Keep only last 100 checkins per server
    db.prepare(`
        DELETE FROM checkins WHERE server_id = ? AND id NOT IN (
            SELECT id FROM checkins WHERE server_id = ? ORDER BY checked_in_at DESC LIMIT 100
        )
    `).run(server.id, server.id);

    return res.status(200).json({ ok: true, server_name: server.name });
}
