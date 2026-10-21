import * as Clipboard from 'expo-clipboard';
import { DownloadTask, File, Paths } from 'expo-file-system';
import { Asset, requestPermissionsAsync } from 'expo-media-library/next';
import * as Sharing from 'expo-sharing';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  FlatList,
  Image,
  KeyboardAvoidingView,
  Modal,
  Platform as RNPlatform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';

import {
  authHeaders,
  checkServer,
  downloadUrl,
  fetchInfo,
  HistoryItem,
  loadHistory,
  loadSettings,
  saveHistory,
  saveSettings,
  Settings,
  DEFAULT_SETTINGS,
  VideoInfo,
} from './src/api';
import { detectPlatform, extractUrl, formatDuration, PLATFORMS } from './src/platforms';

type Phase = 'idle' | 'loading' | 'ready' | 'preparing' | 'downloading' | 'done';

export default function App() {
  return (
    <SafeAreaProvider>
      <StatusBar style="light" />
      <Home />
    </SafeAreaProvider>
  );
}

function Home() {
  const [settings, setSettings] = useState<Settings>(DEFAULT_SETTINGS);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [link, setLink] = useState('');
  const [phase, setPhase] = useState<Phase>('idle');
  const [info, setInfo] = useState<VideoInfo | null>(null);
  const [quality, setQuality] = useState('best');
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [history, setHistory] = useState<HistoryItem[]>([]);
  const taskRef = useRef<DownloadTask | null>(null);

  useEffect(() => {
    loadSettings().then(setSettings);
    loadHistory().then(setHistory);
  }, []);

  const platform = detectPlatform(link.trim());
  const busy = phase === 'loading' || phase === 'preparing' || phase === 'downloading';

  function reset() {
    setInfo(null);
    setError(null);
    setPhase('idle');
    setProgress(0);
  }

  async function paste() {
    const text = await Clipboard.getStringAsync();
    const url = extractUrl(text);
    if (!url) {
      setError('No link found in the clipboard.');
      return;
    }
    setLink(url);
    reset();
    lookup(url);
  }

  async function lookup(raw = link) {
    const url = extractUrl(raw) ?? raw.trim();
    if (!detectPlatform(url)) {
      setError('Paste a link from YouTube, TikTok, Instagram, Facebook or X/Twitter.');
      return;
    }
    setLink(url);
    setError(null);
    setInfo(null);
    setPhase('loading');
    try {
      const data = await fetchInfo(settings, url);
      setInfo(data);
      setQuality(data.qualities[0]?.id ?? 'best');
      setPhase('ready');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setPhase('idle');
    }
  }

  async function download() {
    if (!info) return;
    setError(null);
    setProgress(0);
    setPhase('preparing');

    const ext = quality === 'audio' ? 'm4a' : 'mp4';
    const safeTitle = info.title.replace(/[^\p{L}\p{N} _-]+/gu, '').trim().slice(0, 60) || 'video';
    const dest = new File(Paths.document, `${safeTitle}-${Date.now()}.${ext}`);

    const task = new DownloadTask(downloadUrl(settings, info.url, quality), dest, {
      headers: authHeaders(settings),
      onProgress: ({ bytesWritten, totalBytes }) => {
        // the server first fetches the video itself, then the phone starts receiving bytes
        setPhase('downloading');
        setProgress(totalBytes > 0 ? bytesWritten / totalBytes : 0);
      },
    });
    taskRef.current = task;

    try {
      const file = await task.downloadAsync();
      if (!file) return; // paused / cancelled
      const saved = await saveToGallery(file.uri);
      const item: HistoryItem = {
        id: `${Date.now()}`,
        title: info.title,
        platform: info.platform,
        thumbnail: info.thumbnail,
        fileUri: file.uri,
        savedToGallery: saved,
        date: Date.now(),
      };
      const next = [item, ...history];
      setHistory(next);
      saveHistory(next);
      setProgress(1);
      setPhase('done');
      if (!saved) {
        Alert.alert('Downloaded', 'Gallery access was not granted. Use Share to save or send the file.');
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (/cancel/i.test(msg)) {
        setPhase('ready');
        return;
      }
      setError(
        /401/.test(msg)
          ? 'The server rejected the API key. Check Settings.'
          : /4\d\d|5\d\d/.test(msg)
            ? "The server couldn't download this video. It may be private, removed or too large."
            : `Download failed: ${msg}`,
      );
      setPhase('ready');
    } finally {
      taskRef.current?.release();
      taskRef.current = null;
    }
  }

  function cancel() {
    taskRef.current?.cancel();
  }

  async function share(uri: string) {
    if (!(await Sharing.isAvailableAsync())) {
      Alert.alert('Sharing is not available on this device');
      return;
    }
    if (!new File(uri).exists) {
      Alert.alert('File not found', 'This download was removed from the app storage.');
      return;
    }
    await Sharing.shareAsync(uri);
  }

  function removeHistory(item: HistoryItem) {
    try {
      const f = new File(item.fileUri);
      if (f.exists) f.delete();
    } catch {
      // already gone
    }
    const next = history.filter((h) => h.id !== item.id);
    setHistory(next);
    saveHistory(next);
  }

  return (
    <SafeAreaView style={styles.screen} edges={['top', 'left', 'right']}>
      <KeyboardAvoidingView
        style={{ flex: 1 }}
        behavior={RNPlatform.OS === 'ios' ? 'padding' : undefined}
      >
        <View style={styles.header}>
          <View>
            <Text style={styles.title}>SaveClip</Text>
            <Text style={styles.subtitle}>Paste a link. Get the video.</Text>
          </View>
          <Pressable onPress={() => setSettingsOpen(true)} style={styles.iconButton} hitSlop={10}>
            <Text style={styles.iconText}>⚙︎</Text>
          </Pressable>
        </View>

        <FlatList
          data={history}
          keyExtractor={(h) => h.id}
          contentContainerStyle={styles.content}
          keyboardShouldPersistTaps="handled"
          ListHeaderComponent={
            <View>
              <View style={styles.platformRow}>
                {PLATFORMS.map((p) => (
                  <View
                    key={p.name}
                    style={[
                      styles.platformChip,
                      platform?.name === p.name && { backgroundColor: p.color, borderColor: p.color },
                    ]}
                  >
                    <Text style={styles.platformChipText}>{p.name}</Text>
                  </View>
                ))}
              </View>

              <View style={styles.inputCard}>
                <TextInput
                  value={link}
                  onChangeText={(t) => {
                    setLink(t);
                    if (info) reset();
                  }}
                  placeholder="https://…"
                  placeholderTextColor="#6B7280"
                  autoCapitalize="none"
                  autoCorrect={false}
                  keyboardType="url"
                  returnKeyType="go"
                  onSubmitEditing={() => lookup()}
                  style={styles.input}
                  editable={!busy}
                />
                <View style={styles.inputActions}>
                  {link ? (
                    <Pressable
                      onPress={() => {
                        setLink('');
                        reset();
                      }}
                      style={[styles.button, styles.buttonGhost]}
                      disabled={busy}
                    >
                      <Text style={styles.buttonGhostText}>Clear</Text>
                    </Pressable>
                  ) : (
                    <Pressable onPress={paste} style={[styles.button, styles.buttonGhost]}>
                      <Text style={styles.buttonGhostText}>Paste link</Text>
                    </Pressable>
                  )}
                  <Pressable
                    onPress={() => lookup()}
                    style={[styles.button, styles.buttonPrimary, (busy || !link) && styles.disabled]}
                    disabled={busy || !link}
                  >
                    {phase === 'loading' ? (
                      <ActivityIndicator color="#fff" />
                    ) : (
                      <Text style={styles.buttonText}>Find video</Text>
                    )}
                  </Pressable>
                </View>
              </View>

              {error && <Text style={styles.error}>{error}</Text>}

              {info && (
                <View style={styles.resultCard}>
                  {info.thumbnail ? (
                    <Image source={{ uri: info.thumbnail }} style={styles.thumb} resizeMode="cover" />
                  ) : (
                    <View style={[styles.thumb, styles.thumbEmpty]} />
                  )}
                  <View style={styles.resultBody}>
                    <Text style={styles.resultTitle} numberOfLines={2}>
                      {info.title}
                    </Text>
                    <Text style={styles.resultMeta}>
                      {[info.platform, info.uploader, formatDuration(info.duration)]
                        .filter(Boolean)
                        .join(' · ')}
                    </Text>

                    <Text style={styles.label}>Quality</Text>
                    <View style={styles.qualityRow}>
                      {info.qualities.map((q) => (
                        <Pressable
                          key={q.id}
                          onPress={() => setQuality(q.id)}
                          disabled={busy}
                          style={[styles.qualityChip, quality === q.id && styles.qualityChipActive]}
                        >
                          <Text
                            style={[styles.qualityText, quality === q.id && styles.qualityTextActive]}
                          >
                            {q.label}
                          </Text>
                        </Pressable>
                      ))}
                    </View>

                    {phase === 'preparing' || phase === 'downloading' ? (
                      <View>
                        <View style={styles.progressTrack}>
                          {phase === 'downloading' ? (
                            <View
                              style={[styles.progressFill, { width: `${Math.round(progress * 100)}%` }]}
                            />
                          ) : (
                            <View style={[styles.progressFill, { width: '8%' }]} />
                          )}
                        </View>
                        <View style={styles.progressRow}>
                          <Text style={styles.resultMeta}>
                            {phase === 'preparing'
                              ? 'Preparing video on the server…'
                              : `Downloading ${Math.round(progress * 100)}%`}
                          </Text>
                          <Pressable onPress={cancel} hitSlop={10}>
                            <Text style={styles.link}>Cancel</Text>
                          </Pressable>
                        </View>
                      </View>
                    ) : phase === 'done' ? (
                      <View style={styles.inputActions}>
                        <Pressable
                          style={[styles.button, styles.buttonGhost]}
                          onPress={() => history[0] && share(history[0].fileUri)}
                        >
                          <Text style={styles.buttonGhostText}>Share</Text>
                        </Pressable>
                        <View style={[styles.button, styles.buttonDone]}>
                          <Text style={styles.buttonText}>
                            {history[0]?.savedToGallery ? '✓ Saved to gallery' : '✓ Downloaded'}
                          </Text>
                        </View>
                      </View>
                    ) : (
                      <Pressable style={[styles.button, styles.buttonPrimary]} onPress={download}>
                        <Text style={styles.buttonText}>Download</Text>
                      </Pressable>
                    )}
                  </View>
                </View>
              )}

              {history.length > 0 && <Text style={styles.sectionTitle}>Recent downloads</Text>}
            </View>
          }
          renderItem={({ item }) => (
            <View style={styles.historyRow}>
              {item.thumbnail ? (
                <Image source={{ uri: item.thumbnail }} style={styles.historyThumb} />
              ) : (
                <View style={[styles.historyThumb, styles.thumbEmpty]} />
              )}
              <View style={{ flex: 1 }}>
                <Text style={styles.historyTitle} numberOfLines={1}>
                  {item.title}
                </Text>
                <Text style={styles.resultMeta}>
                  {item.platform} · {new Date(item.date).toLocaleDateString()}
                </Text>
              </View>
              <Pressable onPress={() => share(item.fileUri)} hitSlop={8} style={styles.historyAction}>
                <Text style={styles.link}>Share</Text>
              </Pressable>
              <Pressable
                onPress={() =>
                  Alert.alert('Remove download?', 'Copies already saved to your gallery are kept.', [
                    { text: 'Cancel', style: 'cancel' },
                    { text: 'Remove', style: 'destructive', onPress: () => removeHistory(item) },
                  ])
                }
                hitSlop={8}
                style={styles.historyAction}
              >
                <Text style={styles.removeText}>✕</Text>
              </Pressable>
            </View>
          )}
          ListFooterComponent={
            <Text style={styles.footer}>
              Only download videos you own or have permission to save. Respect each platform's terms
              and creators' copyright.
            </Text>
          }
        />
      </KeyboardAvoidingView>

      <SettingsModal
        visible={settingsOpen}
        settings={settings}
        onClose={() => setSettingsOpen(false)}
        onSave={async (s) => {
          setSettings(s);
          await saveSettings(s);
          setSettingsOpen(false);
        }}
      />
    </SafeAreaView>
  );
}

async function saveToGallery(uri: string): Promise<boolean> {
  try {
    const perm = await requestPermissionsAsync(true);
    if (!perm.granted) return false;
    await Asset.create(uri);
    return true;
  } catch {
    return false;
  }
}

function SettingsModal(props: {
  visible: boolean;
  settings: Settings;
  onClose: () => void;
  onSave: (s: Settings) => void;
}) {
  const [serverUrl, setServerUrl] = useState(props.settings.serverUrl);
  const [apiKey, setApiKey] = useState(props.settings.apiKey);
  const [status, setStatus] = useState<'idle' | 'checking' | 'ok' | 'fail'>('idle');

  useEffect(() => {
    if (props.visible) {
      setServerUrl(props.settings.serverUrl);
      setApiKey(props.settings.apiKey);
      setStatus('idle');
    }
  }, [props.visible, props.settings]);

  async function test() {
    setStatus('checking');
    setStatus((await checkServer({ serverUrl, apiKey })) ? 'ok' : 'fail');
  }

  return (
    <Modal visible={props.visible} animationType="slide" transparent onRequestClose={props.onClose}>
      <View style={styles.modalBackdrop}>
        <ScrollView contentContainerStyle={styles.modalCard} keyboardShouldPersistTaps="handled">
          <Text style={styles.sectionTitle}>Settings</Text>

          <Text style={styles.label}>Server URL</Text>
          <TextInput
            value={serverUrl}
            onChangeText={setServerUrl}
            placeholder="http://192.168.1.10:8000"
            placeholderTextColor="#6B7280"
            autoCapitalize="none"
            autoCorrect={false}
            keyboardType="url"
            style={styles.input}
          />
          <Text style={styles.hint}>
            The address of the SaveClip server (see server/README). On the same Wi-Fi use your
            computer's local IP; otherwise use the URL of your hosted server.
          </Text>

          <Text style={styles.label}>API key (optional)</Text>
          <TextInput
            value={apiKey}
            onChangeText={setApiKey}
            placeholder="Only if the server sets DOWNLOADER_API_KEY"
            placeholderTextColor="#6B7280"
            autoCapitalize="none"
            autoCorrect={false}
            secureTextEntry
            style={styles.input}
          />

          <Pressable onPress={test} style={[styles.button, styles.buttonGhost, { marginTop: 16 }]}>
            {status === 'checking' ? (
              <ActivityIndicator color="#E5E7EB" />
            ) : (
              <Text style={styles.buttonGhostText}>Test connection</Text>
            )}
          </Pressable>
          {status === 'ok' && <Text style={styles.success}>Connected ✓</Text>}
          {status === 'fail' && <Text style={styles.error}>Can't reach the server at that URL.</Text>}

          <View style={[styles.inputActions, { marginTop: 20 }]}>
            <Pressable onPress={props.onClose} style={[styles.button, styles.buttonGhost]}>
              <Text style={styles.buttonGhostText}>Cancel</Text>
            </Pressable>
            <Pressable
              onPress={() => props.onSave({ serverUrl: serverUrl.trim(), apiKey: apiKey.trim() })}
              style={[styles.button, styles.buttonPrimary]}
            >
              <Text style={styles.buttonText}>Save</Text>
            </Pressable>
          </View>
        </ScrollView>
      </View>
    </Modal>
  );
}

const C = {
  bg: '#0B0F17',
  card: '#151B26',
  border: '#232B3A',
  text: '#F3F4F6',
  muted: '#9CA3AF',
  accent: '#7C5CFF',
  green: '#22C55E',
  red: '#F87171',
};

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: C.bg },
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: 20,
    paddingTop: 12,
    paddingBottom: 8,
  },
  title: { color: C.text, fontSize: 28, fontWeight: '800' },
  subtitle: { color: C.muted, fontSize: 14, marginTop: 2 },
  iconButton: {
    width: 40,
    height: 40,
    borderRadius: 20,
    backgroundColor: C.card,
    alignItems: 'center',
    justifyContent: 'center',
  },
  iconText: { color: C.text, fontSize: 20 },
  content: { padding: 20, paddingBottom: 48 },
  platformRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 16 },
  platformChip: {
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: 999,
    borderWidth: 1,
    borderColor: C.border,
  },
  platformChipText: { color: C.text, fontSize: 12, fontWeight: '600' },
  inputCard: { backgroundColor: C.card, borderRadius: 16, padding: 14, gap: 12 },
  input: {
    backgroundColor: C.bg,
    color: C.text,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: C.border,
    paddingHorizontal: 14,
    paddingVertical: 12,
    fontSize: 15,
  },
  inputActions: { flexDirection: 'row', gap: 10 },
  button: {
    flex: 1,
    height: 48,
    borderRadius: 12,
    alignItems: 'center',
    justifyContent: 'center',
  },
  buttonPrimary: { backgroundColor: C.accent },
  buttonDone: { backgroundColor: C.green },
  buttonGhost: { backgroundColor: 'transparent', borderWidth: 1, borderColor: C.border },
  buttonText: { color: '#fff', fontWeight: '700', fontSize: 15 },
  buttonGhostText: { color: C.text, fontWeight: '600', fontSize: 15 },
  disabled: { opacity: 0.5 },
  error: { color: C.red, marginTop: 12, fontSize: 14 },
  success: { color: C.green, marginTop: 10, fontSize: 14 },
  resultCard: { backgroundColor: C.card, borderRadius: 16, marginTop: 16, overflow: 'hidden' },
  thumb: { width: '100%', aspectRatio: 16 / 9, backgroundColor: '#000' },
  thumbEmpty: { backgroundColor: C.border },
  resultBody: { padding: 14, gap: 6 },
  resultTitle: { color: C.text, fontSize: 16, fontWeight: '700' },
  resultMeta: { color: C.muted, fontSize: 13 },
  label: { color: C.muted, fontSize: 12, fontWeight: '700', marginTop: 12, marginBottom: 6, textTransform: 'uppercase' },
  qualityRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 12 },
  qualityChip: {
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: C.border,
  },
  qualityChipActive: { backgroundColor: C.accent, borderColor: C.accent },
  qualityText: { color: C.text, fontSize: 13, fontWeight: '600' },
  qualityTextActive: { color: '#fff' },
  progressTrack: { height: 8, backgroundColor: C.bg, borderRadius: 4, overflow: 'hidden' },
  progressFill: { height: 8, backgroundColor: C.accent },
  progressRow: { flexDirection: 'row', justifyContent: 'space-between', marginTop: 8 },
  link: { color: C.accent, fontWeight: '700' },
  sectionTitle: { color: C.text, fontSize: 18, fontWeight: '700', marginTop: 24, marginBottom: 8 },
  historyRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: C.border,
  },
  historyThumb: { width: 64, height: 40, borderRadius: 6, backgroundColor: '#000' },
  historyTitle: { color: C.text, fontSize: 14, fontWeight: '600' },
  historyAction: { paddingHorizontal: 4 },
  removeText: { color: C.muted, fontSize: 16 },
  footer: { color: C.muted, fontSize: 12, textAlign: 'center', marginTop: 28, lineHeight: 18 },
  modalBackdrop: { flex: 1, backgroundColor: 'rgba(0,0,0,0.6)', justifyContent: 'flex-end' },
  modalCard: {
    backgroundColor: C.card,
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    padding: 20,
    paddingBottom: 40,
  },
  hint: { color: C.muted, fontSize: 12, marginTop: 6, lineHeight: 17 },
});
