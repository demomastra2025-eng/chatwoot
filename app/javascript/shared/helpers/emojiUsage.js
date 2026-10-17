import { LocalStorage } from 'shared/helpers/localStorage';

export const FREQUENT_EMOJIS_STORAGE_KEY = 'cw_frequent_emojis_v1';
export const FREQUENT_REACTIONS_STORAGE_KEY = 'cw_frequent_reactions_v1';

export const DEFAULT_QUICK_REACTIONS = [
  '👍',
  '❤️',
  '🔥',
  '🎉',
  '🙏',
  '😂',
  '✅',
  '👀',
];

export const DEFAULT_FREQUENT_EMOJIS = [
  { emoji: '👍', name: 'thumbs up', slug: 'thumbs_up' },
  { emoji: '❤️', name: 'red heart', slug: 'red_heart' },
  { emoji: '🔥', name: 'fire', slug: 'fire' },
  { emoji: '🎉', name: 'party popper', slug: 'party_popper' },
  { emoji: '🙏', name: 'folded hands', slug: 'folded_hands' },
  {
    emoji: '😂',
    name: 'face with tears of joy',
    slug: 'face_with_tears_of_joy',
  },
  {
    emoji: '😊',
    name: 'smiling face with smiling eyes',
    slug: 'smiling_face_with_smiling_eyes',
  },
  {
    emoji: '🥰',
    name: 'smiling face with hearts',
    slug: 'smiling_face_with_hearts',
  },
  { emoji: '🤝', name: 'handshake', slug: 'handshake' },
  { emoji: '✅', name: 'check mark button', slug: 'check_mark_button' },
  { emoji: '✨', name: 'sparkles', slug: 'sparkles' },
  { emoji: '🙌', name: 'raising hands', slug: 'raising_hands' },
  {
    emoji: '😍',
    name: 'smiling face with heart-eyes',
    slug: 'smiling_face_with_heart_eyes',
  },
  { emoji: '🤔', name: 'thinking face', slug: 'thinking_face' },
  { emoji: '👀', name: 'eyes', slug: 'eyes' },
  { emoji: '💯', name: 'hundred points', slug: 'hundred_points' },
];

const MAX_STORED_ENTRIES = 48;

function readUsageMap(storageKey) {
  try {
    const raw = LocalStorage.get(storageKey);
    return raw && typeof raw === 'object' ? { ...raw } : {};
  } catch {
    return {};
  }
}

function writeUsageMap(storageKey, map) {
  try {
    LocalStorage.set(storageKey, map);
  } catch {
    // Ignore storage quota errors
  }
}

function computeScore(entry, now = Date.now()) {
  const count = Number(entry?.count || 0);
  const lastUsedAt = Number(entry?.lastUsedAt || 0);
  const ageHours = Math.max(0, (now - lastUsedAt) / (1000 * 60 * 60));
  const recencyBoost = Math.max(0.25, 1 / (1 + ageHours / 72));
  return count * (1 + recencyBoost);
}

function recordUsage(storageKey, emoji) {
  const value = String(emoji || '').trim();
  if (!value) return;

  const now = Date.now();
  const map = readUsageMap(storageKey);
  const existing = map[value] || { count: 0, lastUsedAt: 0 };
  map[value] = {
    count: Number(existing.count || 0) + 1,
    lastUsedAt: now,
  };

  const keys = Object.keys(map);
  if (keys.length > MAX_STORED_ENTRIES) {
    const sorted = keys.sort(
      (a, b) => computeScore(map[b], now) - computeScore(map[a], now)
    );
    sorted.slice(MAX_STORED_ENTRIES).forEach(k => {
      delete map[k];
    });
  }

  writeUsageMap(storageKey, map);
}

export function recordEmojiUsage(emoji) {
  recordUsage(FREQUENT_EMOJIS_STORAGE_KEY, emoji);
}

export function recordReactionUsage(emoji) {
  recordUsage(FREQUENT_REACTIONS_STORAGE_KEY, emoji);
  recordUsage(FREQUENT_EMOJIS_STORAGE_KEY, emoji);
}

export function getSortedStoredEmojis(storageKey) {
  const map = readUsageMap(storageKey);
  const now = Date.now();
  return Object.keys(map).sort(
    (a, b) => computeScore(map[b], now) - computeScore(map[a], now)
  );
}

export function getQuickReactions(limit = 6) {
  const stored = getSortedStoredEmojis(FREQUENT_REACTIONS_STORAGE_KEY);
  const result = [];
  const seen = new Set();

  [...stored, ...DEFAULT_QUICK_REACTIONS].forEach(emoji => {
    if (!emoji || seen.has(emoji) || result.length >= limit) return;
    seen.add(emoji);
    result.push(emoji);
  });

  return result;
}

export function getFrequentEmojiItems(allEmojiCatalog = [], limit = 16) {
  const storedEmojis = getSortedStoredEmojis(FREQUENT_EMOJIS_STORAGE_KEY);
  const reactionEmojis = getSortedStoredEmojis(FREQUENT_REACTIONS_STORAGE_KEY);
  const byEmoji = new Map();

  allEmojiCatalog.forEach(item => {
    if (item?.emoji && !byEmoji.has(item.emoji)) {
      byEmoji.set(item.emoji, item);
    }
  });
  DEFAULT_FREQUENT_EMOJIS.forEach(item => {
    if (!byEmoji.has(item.emoji)) {
      byEmoji.set(item.emoji, item);
    }
  });

  const result = [];
  const seen = new Set();

  const candidates = [
    ...storedEmojis,
    ...reactionEmojis,
    ...DEFAULT_FREQUENT_EMOJIS.map(item => item.emoji),
  ];

  candidates.forEach(emoji => {
    if (!emoji || seen.has(emoji) || result.length >= limit) return;
    seen.add(emoji);
    result.push(
      byEmoji.get(emoji) || {
        emoji,
        name: emoji,
        slug: emoji,
      }
    );
  });

  return result;
}
