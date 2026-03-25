'use client';

import { useEffect, useState, useCallback } from 'react';

interface Disk {
    drive: string;
    total_gb: number;
    free_gb: number;
    used_pct: number;
}

interface Service {
    name: string;
    display_name: string;
    status: string;
}

interface VeeamJob {
    job_name: string;
    status: string;
    end_time: string | null;
    size_gb: number | null;
}

interface Server {
    id: number;
    name: string;
    hostname: string;
    description: string | null;
    last_checkin: string | null;
    os_info: string | null;
    disks: Disk[];
    pending_updates: number | null;
    last_update_installed: string | null;
    services: Service[];
    veeam_last_job: VeeamJob | null;
    uptime_seconds: number | null;
}

interface BackupStatus {
    id: number;
    computer_name: string;
    plan_name: string;
    last_run_at: string | null;
    status: string | null;
    size_bytes: number | null;
}

function timeAgo(iso: string | null): string {
    if (!iso) return 'Never';
    const diff = Math.floor((Date.now() - new Date(iso).getTime()) / 1000);
    if (diff < 60) return `${diff}s ago`;
    if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
    return `${Math.floor(diff / 86400)}d ago`;
}

function fmtUptime(seconds: number | null): string {
    if (!seconds) return '—';
    const d = Math.floor(seconds / 86400);
    const h = Math.floor((seconds % 86400) / 3600);
    if (d > 0) return `${d}d ${h}h`;
    return `${h}h`;
}

function serverStatus(server: Server): 'online' | 'warning' | 'offline' {
    if (!server.last_checkin) return 'offline';
    const ageMin = (Date.now() - new Date(server.last_checkin).getTime()) / 60000;
    if (ageMin > 60) return 'offline';
    const hasIssue =
        (server.disks || []).some(d => d.used_pct > 85) ||
        (server.pending_updates ?? 0) > 20 ||
        (server.services || []).some(s => s.status !== 'Running') ||
        server.veeam_last_job?.status === 'Failed';
    return hasIssue ? 'warning' : 'online';
}

function StatusDot({ status }: { status: 'online' | 'warning' | 'offline' }) {
    const colors = { online: 'bg-green-500', warning: 'bg-amber-400', offline: 'bg-red-500' };
    return <span className={`inline-block w-2.5 h-2.5 rounded-full ${colors[status]}`} />;
}

function DiskBar({ disk }: { disk: Disk }) {
    const color = disk.used_pct > 90 ? 'bg-red-500' : disk.used_pct > 75 ? 'bg-amber-400' : 'bg-green-500';
    return (
        <div className="mb-2">
            <div className="flex justify-between text-xs text-gray-500 mb-0.5">
                <span className="font-medium">{disk.drive}</span>
                <span>{disk.used_pct.toFixed(0)}% used &mdash; {disk.free_gb.toFixed(1)} GB free</span>
            </div>
            <div className="h-1.5 bg-gray-100 rounded-full overflow-hidden">
                <div className={`h-full rounded-full ${color}`} style={{ width: `${Math.min(disk.used_pct, 100)}%` }} />
            </div>
        </div>
    );
}

function ServerCard({ server, backups }: { server: Server; backups: BackupStatus[] }) {
    const status = serverStatus(server);
    const stoppedServices = (server.services || []).filter(s => s.status !== 'Running');
    const serverBackups = backups.filter(b =>
        b.computer_name.toLowerCase().includes(server.hostname.toLowerCase().split('.')[0]) ||
        server.hostname.toLowerCase().includes(b.computer_name.toLowerCase())
    );

    const borderColor = { online: 'border-green-200', warning: 'border-amber-200', offline: 'border-red-300' }[status];
    const headerBg = { online: 'bg-green-50', warning: 'bg-amber-50', offline: 'bg-red-50' }[status];

    return (
        <div className={`bg-white rounded-lg border ${borderColor} shadow-sm overflow-hidden`}>
            <div className={`${headerBg} px-4 py-3 flex items-center justify-between`}>
                <div className="flex items-center gap-2.5">
                    <StatusDot status={status} />
                    <div>
                        <div className="font-semibold text-gray-800 text-sm">{server.name}</div>
                        <div className="text-xs text-gray-400">{server.hostname}</div>
                    </div>
                </div>
                <div className="text-right">
                    <div className="text-xs text-gray-400">Last seen</div>
                    <div className={`text-xs font-medium ${status === 'offline' ? 'text-red-600' : 'text-gray-600'}`}>
                        {timeAgo(server.last_checkin)}
                    </div>
                </div>
            </div>

            <div className="p-4 space-y-4 text-sm">
                {(server.os_info || server.uptime_seconds != null) && (
                    <div className="flex justify-between text-xs text-gray-500">
                        <span>{server.os_info || '—'}</span>
                        <span>Uptime: {fmtUptime(server.uptime_seconds)}</span>
                    </div>
                )}

                {(server.disks || []).length > 0 && (
                    <div>
                        <div className="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Disk Usage</div>
                        {server.disks.map(d => <DiskBar key={d.drive} disk={d} />)}
                    </div>
                )}

                <div>
                    <div className="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-1.5">Windows Updates</div>
                    <div className="flex items-center justify-between">
                        <span className={`text-xs font-medium px-2 py-0.5 rounded-full ${
                            (server.pending_updates ?? 0) > 20 ? 'bg-red-100 text-red-700' :
                            (server.pending_updates ?? 0) > 0 ? 'bg-amber-100 text-amber-700' :
                            server.pending_updates === 0 ? 'bg-green-100 text-green-700' :
                            'bg-gray-100 text-gray-500'
                        }`}>
                            {server.pending_updates === null ? 'Unknown' :
                             server.pending_updates === 0 ? 'Up to date' :
                             `${server.pending_updates} pending`}
                        </span>
                        {server.last_update_installed && (
                            <span className="text-xs text-gray-400">
                                Last: {new Date(server.last_update_installed).toLocaleDateString()}
                            </span>
                        )}
                    </div>
                </div>

                {server.veeam_last_job && (
                    <div>
                        <div className="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-1.5">Veeam Backup</div>
                        <div className="flex items-center justify-between">
                            <span className="text-xs text-gray-600 truncate max-w-[160px]">{server.veeam_last_job.job_name}</span>
                            <span className={`text-xs font-medium px-2 py-0.5 rounded-full ${
                                server.veeam_last_job.status === 'Success' ? 'bg-green-100 text-green-700' :
                                server.veeam_last_job.status === 'Warning' ? 'bg-amber-100 text-amber-700' :
                                'bg-red-100 text-red-700'
                            }`}>{server.veeam_last_job.status}</span>
                        </div>
                        {server.veeam_last_job.end_time && (
                            <div className="text-xs text-gray-400 mt-0.5">{timeAgo(server.veeam_last_job.end_time)}</div>
                        )}
                    </div>
                )}

                {serverBackups.length > 0 && (
                    <div>
                        <div className="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-1.5">MSP360 Backup</div>
                        {serverBackups.map(b => (
                            <div key={b.id} className="flex items-center justify-between mb-1">
                                <span className="text-xs text-gray-600 truncate max-w-[160px]">{b.plan_name}</span>
                                <div className="flex items-center gap-2">
                                    <span className="text-xs text-gray-400">{timeAgo(b.last_run_at)}</span>
                                    <span className={`text-xs font-medium px-2 py-0.5 rounded-full ${
                                        b.status === 'Success' ? 'bg-green-100 text-green-700' :
                                        b.status === 'Failed' ? 'bg-red-100 text-red-700' :
                                        'bg-amber-100 text-amber-700'
                                    }`}>{b.status || '?'}</span>
                                </div>
                            </div>
                        ))}
                    </div>
                )}

                {stoppedServices.length > 0 && (
                    <div>
                        <div className="text-xs font-semibold text-red-500 uppercase tracking-wider mb-1.5">Stopped Services</div>
                        {stoppedServices.map(s => (
                            <div key={s.name} className="text-xs text-red-700 bg-red-50 border border-red-100 px-2 py-1 rounded mb-1">
                                {s.display_name || s.name}
                            </div>
                        ))}
                    </div>
                )}
            </div>
        </div>
    );
}

export default function Dashboard() {
    const [servers, setServers] = useState<Server[]>([]);
    const [backups, setBackups] = useState<BackupStatus[]>([]);
    const [loading, setLoading] = useState(true);
    const [syncing, setSyncing] = useState(false);
    const [lastRefresh, setLastRefresh] = useState<Date | null>(null);

    const fetchData = useCallback(async () => {
        const [sRes, bRes] = await Promise.all([
            fetch('/api/servers'),
            fetch('/api/backup-status'),
        ]);
        if (sRes.ok) setServers(await sRes.json());
        if (bRes.ok) setBackups(await bRes.json());
        setLastRefresh(new Date());
        setLoading(false);
    }, []);

    useEffect(() => {
        fetchData();
        const interval = setInterval(fetchData, 60000);
        return () => clearInterval(interval);
    }, [fetchData]);

    const syncBackups = async () => {
        const adminKey = prompt('Admin key:');
        if (!adminKey) return;
        setSyncing(true);
        try {
            const res = await fetch('/api/sync-backups', {
                method: 'POST',
                headers: { 'x-admin-key': adminKey },
            });
            const data = await res.json();
            if (res.ok) { alert(`Synced ${data.synced} backup records.`); fetchData(); }
            else alert(`Error: ${data.message}`);
        } finally {
            setSyncing(false);
        }
    };

    const online = servers.filter(s => serverStatus(s) === 'online').length;
    const warning = servers.filter(s => serverStatus(s) === 'warning').length;
    const offline = servers.filter(s => serverStatus(s) === 'offline').length;

    return (
        <div className="min-h-screen bg-gray-50">
            <div className="bg-white border-b border-gray-200 px-6 py-4">
                <div className="max-w-7xl mx-auto flex items-center justify-between">
                    <div>
                        <h1 className="text-lg font-bold text-gray-800">VCTC Server Monitor</h1>
                        <p className="text-xs text-gray-400 mt-0.5">
                            {lastRefresh ? `Refreshed ${timeAgo(lastRefresh.toISOString())}` : 'Loading…'}
                        </p>
                    </div>
                    <div className="flex items-center gap-3">
                        <div className="flex items-center gap-2">
                            {online > 0 && <span className="flex items-center gap-1.5 text-green-700 bg-green-50 border border-green-200 px-2.5 py-1 rounded-full text-xs font-medium"><span className="w-2 h-2 rounded-full bg-green-500 inline-block" />{online} online</span>}
                            {warning > 0 && <span className="flex items-center gap-1.5 text-amber-700 bg-amber-50 border border-amber-200 px-2.5 py-1 rounded-full text-xs font-medium"><span className="w-2 h-2 rounded-full bg-amber-400 inline-block" />{warning} warning</span>}
                            {offline > 0 && <span className="flex items-center gap-1.5 text-red-700 bg-red-50 border border-red-200 px-2.5 py-1 rounded-full text-xs font-medium"><span className="w-2 h-2 rounded-full bg-red-500 inline-block" />{offline} offline</span>}
                        </div>
                        <button onClick={syncBackups} disabled={syncing} className="text-xs px-3 py-1.5 bg-blue-600 hover:bg-blue-700 text-white rounded-md font-medium disabled:opacity-50 transition-colors">
                            {syncing ? 'Syncing…' : 'Sync MSP360'}
                        </button>
                        <button onClick={fetchData} className="text-xs px-3 py-1.5 bg-gray-100 hover:bg-gray-200 text-gray-700 rounded-md font-medium transition-colors">
                            Refresh
                        </button>
                    </div>
                </div>
            </div>

            <div className="max-w-7xl mx-auto px-6 py-6">
                {loading ? (
                    <p className="text-center text-gray-400 py-20">Loading…</p>
                ) : servers.length === 0 ? (
                    <div className="text-center py-20 text-gray-400">
                        <p className="text-lg font-medium mb-2">No servers registered yet</p>
                        <p className="text-sm">POST to /api/servers with an admin key to register a server.</p>
                    </div>
                ) : (
                    <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
                        {servers.map(s => <ServerCard key={s.id} server={s} backups={backups} />)}
                    </div>
                )}
            </div>
        </div>
    );
}
