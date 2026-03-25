import type { NextApiRequest, NextApiResponse } from 'next';
import { getDb } from '@/lib/db';

export default function handler(req: NextApiRequest, res: NextApiResponse) {
    if (req.method !== 'GET') return res.status(405).json({ message: 'Method not allowed' });
    const db = getDb();
    const rows = db.prepare(`
        SELECT * FROM backup_status ORDER BY computer_name, plan_name
    `).all();
    return res.status(200).json(rows);
}
