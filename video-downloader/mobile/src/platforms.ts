export type Platform = {
  name: string;
  color: string;
  hosts: string[];
};

export const PLATFORMS: Platform[] = [
  { name: 'YouTube', color: '#FF0033', hosts: ['youtube.com', 'youtu.be'] },
  { name: 'TikTok', color: '#111111', hosts: ['tiktok.com'] },
  { name: 'Instagram', color: '#D62976', hosts: ['instagram.com'] },
  { name: 'Facebook', color: '#1877F2', hosts: ['facebook.com', 'fb.watch', 'fb.com'] },
  { name: 'X / Twitter', color: '#000000', hosts: ['x.com', 'twitter.com'] },
];

/** Pull the first http(s) link out of pasted text (share sheets often add a caption around it). */
export function extractUrl(text: string): string | null {
  const match = text.match(/https?:\/\/[^\s"'<>]+/i);
  return match ? match[0] : null;
}

export function detectPlatform(url: string): Platform | null {
  const host = url.match(/^https?:\/\/([^/?#:]+)/i)?.[1]?.toLowerCase();
  if (!host) return null;
  return PLATFORMS.find((p) => p.hosts.some((h) => host === h || host.endsWith('.' + h))) ?? null;
}

export function formatDuration(seconds?: number | null): string {
  if (!seconds) return '';
  const s = Math.round(seconds);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const pad = (n: number) => String(n).padStart(2, '0');
  return h ? `${h}:${pad(m)}:${pad(s % 60)}` : `${m}:${pad(s % 60)}`;
}
