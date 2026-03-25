import type { NextApiRequest, NextApiResponse } from 'next';
import { getDb } from '@/lib/db';
import crypto from 'crypto';

const ADMIN_KEY = process.env.ADMIN_API_KEY || '';

function requireAdmin(req: NextApiRequest, res: NextApiResponse): boolean {
    const key = req.headers['x-admin-key'] || req.query.adminKey;
    if (!ADMIN_KEY || key !== ADMIN_KEY) {
        res.status(401).json({ message: 'Unauthorized' });
        return false;
    }
    return true;
}

export default function handler(req: NextApiRequest, res: NextApiResponse) {
    const db = getDb();

    if (req.method === 'GET') {
        const servers = db.prepare(`
            SELECT s.*,
                   c.checked_in_at AS last_checkin,
                   c.disks, c.pending_updates, c.services,
                   c.veeam_last_job, c.os_info, c.uptime_seconds,
                   c.last_update_installed
            FROM servers s
            LEFT JOIN checkins c ON c.id = (
                SELECT id FROM checkins WHERE server_id = s.id
                ORDER BY checked_in_at DESC LIMIT 1
            )
            WHERE s.active = 1
            ORDER BY s.name
        `).all();

        const parsed = servers.map((s: any) => ({
            ...s,
            disks: s.disks ? JSON.parse(s.disks) : [],
            services: s.services ? JSON.parse(s.services) : [],
            veeam_last_job: s.veeam_last_job ? JSON.parse(s.veeam_last_job) : null,
        }));

        return res.status(200).json(parsed);
    }

    if (req.method === 'POST') {
        if (!requireAdmin(req, res)) return;
        const { name, hostname, description } = req.body;
        if (!name || !hostname) return res.status(400).json({ message: 'name and hostname required' });
        const api_key = crypto.randomBytes(32).toString('hex');
        const result = db.prepare(
            `INSERT INTO servers (name, hostname, description, api_key) VALUES (?, ?, ?, ?)`
        ).run(name, hostname.toLowerCase(), description || null, api_key);
        return res.status(201).json({ id: result.lastInsertRowid, name, hostname, api_key });
    }

    if (req.method === 'DELETE') {
        if (!requireAdmin(req, res)) return;
        const { id } = req.body;
        if (!id) return res.status(400).json({ message: 'id required' });
        db.prepare(`UPDATE servers SET active = 0 WHERE id = ?`).run(id);
        return res.status(200).json({ ok: true });
    }

    res.status(405).json({ message: 'Method not allowed' });
}
