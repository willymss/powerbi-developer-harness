import AsyncStorage from '@react-native-async-storage/async-storage';

export type Quality = { id: string; label: string };

export type VideoInfo = {
  url: string;
  platform: string;
  id?: string;
  title: string;
  uploader?: string | null;
  duration?: number | null;
  thumbnail?: string | null;
  qualities: Quality[];
};

export type Settings = { serverUrl: string; apiKey: string };

const SETTINGS_KEY = 'settings.v1';

// Set EXPO_PUBLIC_API_URL in mobile/.env to change the default server for every build.
export const DEFAULT_SETTINGS: Settings = {
  serverUrl: process.env.EXPO_PUBLIC_API_URL ?? 'http://192.168.1.10:8000',
  apiKey: process.env.EXPO_PUBLIC_API_KEY ?? '',
};

export async function loadSettings(): Promise<Settings> {
  try {
    const raw = await AsyncStorage.getItem(SETTINGS_KEY);
    return raw ? { ...DEFAULT_SETTINGS, ...JSON.parse(raw) } : DEFAULT_SETTINGS;
  } catch {
    return DEFAULT_SETTINGS;
  }
}

export async function saveSettings(settings: Settings): Promise<void> {
  await AsyncStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
}

export function authHeaders(settings: Settings): Record<string, string> {
  return settings.apiKey ? { 'X-API-Key': settings.apiKey } : {};
}

function base(settings: Settings): string {
  return settings.serverUrl.trim().replace(/\/+$/, '');
}

async function errorMessage(res: Response): Promise<string> {
  try {
    const body = await res.json();
    if (typeof body.detail === 'string') return body.detail;
  } catch {
    // not JSON
  }
  return `Server error (${res.status})`;
}

export async function fetchInfo(settings: Settings, url: string): Promise<VideoInfo> {
  let res: Response;
  try {
    res = await fetch(`${base(settings)}/api/info`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders(settings) },
      body: JSON.stringify({ url }),
    });
  } catch {
    throw new Error(`Can't reach the server at ${settings.serverUrl}. Check Settings.`);
  }
  if (!res.ok) throw new Error(await errorMessage(res));
  return res.json();
}

export function downloadUrl(settings: Settings, url: string, quality: string): string {
  const params = `url=${encodeURIComponent(url)}&quality=${encodeURIComponent(quality)}`;
  return `${base(settings)}/api/download?${params}`;
}

export async function checkServer(settings: Settings): Promise<boolean> {
  try {
    const res = await fetch(`${base(settings)}/api/health`);
    return res.ok;
  } catch {
    return false;
  }
}

/* ---------- download history ---------- */

export type HistoryItem = {
  id: string;
  title: string;
  platform: string;
  thumbnail?: string | null;
  fileUri: string;
  savedToGallery: boolean;
  date: number;
};

const HISTORY_KEY = 'history.v1';

export async function loadHistory(): Promise<HistoryItem[]> {
  try {
    const raw = await AsyncStorage.getItem(HISTORY_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

export async function saveHistory(items: HistoryItem[]): Promise<void> {
  await AsyncStorage.setItem(HISTORY_KEY, JSON.stringify(items.slice(0, 50)));
}
