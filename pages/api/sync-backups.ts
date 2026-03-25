import type { NextApiRequest, NextApiResponse } from 'next';
import { getDb } from '@/lib/db';

const ADMIN_KEY = process.env.ADMIN_API_KEY || '';
const MSP360_API = 'https://api.mspbackups.com';

async function getMsp360Token(): Promise<string> {
    const res = await fetch(`${MSP360_API}/api/Provider/Login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body: JSON.stringify({
            UserName: process.env.MSP360_USERNAME,
            Password: process.env.MSP360_PASSWORD,
        }),
    });
    if (!res.ok) throw new Error(`MSP360 login failed: ${res.status}`);
    const data = await res.json();
    return data.Ticket || data.ticket || data.token;
}

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
    if (req.method !== 'POST') return res.status(405).json({ message: 'Method not allowed' });

    const key = req.headers['x-admin-key'] || req.query.adminKey;
    if (!ADMIN_KEY || key !== ADMIN_KEY) return res.status(401).json({ message: 'Unauthorized' });

    try {
        const token = await getMsp360Token();

        const monRes = await fetch(`${MSP360_API}/api/Monitoring`, {
            headers: { 'Authorization': `Bearer ${token}`, 'Accept': 'application/json' },
        });
        if (!monRes.ok) throw new Error(`MSP360 monitoring fetch failed: ${monRes.status}`);
        const data = await monRes.json();

        const db = getDb();
        const upsert = db.prepare(`
            INSERT INTO backup_status (computer_name, plan_name, last_run_at, status, size_bytes, duration_seconds, synced_at)
            VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(computer_name, plan_name) DO UPDATE SET
                last_run_at = excluded.last_run_at,
                status = excluded.status,
                size_bytes = excluded.size_bytes,
                duration_seconds = excluded.duration_seconds,
                synced_at = excluded.synced_at
        `);

        let count = 0;
        const items = Array.isArray(data) ? data : (data.Data || data.data || []);
        for (const item of items) {
            upsert.run(
                item.ComputerName || item.computerName || item.HostName || '',
                item.PlanName || item.planName || item.Plan || 'Default',
                item.LastRunTime || item.lastRunTime || null,
                item.Status || item.status || null,
                item.TotalSize || item.totalSize || null,
                item.Duration || item.duration || null,
            );
            count++;
        }

        return res.status(200).json({ ok: true, synced: count });
    } catch (err: any) {
        console.error('[sync-backups]', err);
        return res.status(500).json({ message: err.message });
    }
}
