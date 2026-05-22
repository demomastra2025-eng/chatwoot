const dayFormatter = new Intl.DateTimeFormat(undefined, { day: '2-digit' });
const monthFormatter = new Intl.DateTimeFormat(undefined, {
  month: 'long',
  year: 'numeric',
});
const dateTimeFormatter = new Intl.DateTimeFormat(undefined, {
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  month: 'short',
  year: 'numeric',
});

const statusStyles = {
  draft: 'bg-n-slate-3 text-n-slate-11',
  queue: 'bg-n-amber-3 text-n-amber-11',
  scheduled: 'bg-n-amber-3 text-n-amber-11',
  published: 'bg-n-teal-3 text-n-teal-11',
  error: 'bg-n-ruby-3 text-n-ruby-11',
};

export const providerOptions = [
  { id: 'instagram', label: 'Instagram', icon: 'i-ph-instagram-logo' },
  { id: 'threads', label: 'Threads', icon: 'i-lucide-at-sign' },
  { id: 'facebook', label: 'Facebook', icon: 'i-ph-facebook-logo' },
  { id: 'x', label: 'X', icon: 'i-ph-x-logo' },
  { id: 'linkedin', label: 'LinkedIn', icon: 'i-ph-linkedin-logo' },
  { id: 'tiktok', label: 'TikTok', icon: 'i-ph-music-notes' },
  { id: 'youtube', label: 'YouTube', icon: 'i-ph-youtube-logo' },
  { id: 'pinterest', label: 'Pinterest', icon: 'i-ph-pinterest-logo' },
];

export const startOfMonth = date =>
  new Date(date.getFullYear(), date.getMonth(), 1);

export const addMonths = (date, amount) =>
  new Date(date.getFullYear(), date.getMonth() + amount, 1);

export const monthRange = date => {
  const start = startOfMonth(date);
  const end = new Date(
    start.getFullYear(),
    start.getMonth() + 1,
    0,
    23,
    59,
    59
  );
  return { startDate: start.toISOString(), endDate: end.toISOString() };
};

export const formatMonth = date => monthFormatter.format(date);

export const formatDateTime = value => {
  if (!value) return '—';
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return value;
  return dateTimeFormatter.format(parsed);
};

export const postDateValue = post =>
  post.date ||
  post.publishDate ||
  post.publishDateTime ||
  post.createdAt ||
  post.updatedAt;

export const postTitle = post =>
  post.content ||
  post.text ||
  post.value?.[0]?.content ||
  post.posts?.[0]?.value?.[0]?.content ||
  post.id;

export const postStatus = post =>
  (post.status || post.state || post.type || 'unknown')
    .toString()
    .toLowerCase();

export const channelProvider = channel =>
  channel.provider ||
  channel.type ||
  channel.identifier ||
  channel.providerIdentifier ||
  channel.integration ||
  '';

export const channelName = channel =>
  channel.name ||
  channel.profile ||
  channel.nickname ||
  channel.identifier ||
  channelProvider(channel) ||
  channel.id;

export const channelAvatar = channel =>
  channel.picture || channel.avatar || channel.image || channel.profilePicture;

export const channelIdForPost = post =>
  post.integration?.id ||
  post.integrationId ||
  post.channelId ||
  post.account ||
  post.providerId;

export const channelForPost = (post, channels) =>
  channels.find(channel => channel.id === channelIdForPost(post)) ||
  post.integration ||
  null;

export const statusClass = status =>
  statusStyles[status] || 'bg-n-alpha-2 text-n-slate-11';

export const normalizeMedia = media => {
  if (!media) return null;
  const candidate = Array.isArray(media) ? media[0] : media;
  if (!candidate) return null;
  return {
    id: candidate.id,
    name:
      candidate.name ||
      candidate.originalName ||
      candidate.path ||
      candidate.id,
    path: candidate.path || candidate.url,
    thumbnail: candidate.thumbnail,
    alt: candidate.alt || '',
  };
};

export const buildCalendarDays = (anchorDate, posts = []) => {
  const start = startOfMonth(anchorDate);
  const firstDay = new Date(start);
  const mondayOffset = (firstDay.getDay() + 6) % 7;
  firstDay.setDate(firstDay.getDate() - mondayOffset);

  return Array.from({ length: 42 }, (_, index) => {
    const day = new Date(firstDay);
    day.setDate(firstDay.getDate() + index);
    const key = day.toISOString().slice(0, 10);
    return {
      key,
      day,
      label: dayFormatter.format(day),
      inMonth: day.getMonth() === anchorDate.getMonth(),
      posts: posts.filter(post => postDateValue(post)?.slice(0, 10) === key),
    };
  });
};

export const summarizePosts = posts =>
  posts.reduce(
    (summary, post) => {
      const status = postStatus(post);
      summary.total += 1;
      if (status === 'published') summary.published += 1;
      else if (status === 'draft') summary.draft += 1;
      else if (['queue', 'scheduled'].includes(status)) summary.scheduled += 1;
      else if (status === 'error') summary.error += 1;
      return summary;
    },
    { total: 0, scheduled: 0, published: 0, draft: 0, error: 0 }
  );

export const filterPosts = (posts, { query, status, channelId }) => {
  const normalizedQuery = query.trim().toLowerCase();
  return posts.filter(post => {
    const matchesSearch =
      !normalizedQuery ||
      postTitle(post).toLowerCase().includes(normalizedQuery);
    const matchesStatus = status === 'all' || postStatus(post) === status;
    const matchesChannel =
      channelId === 'all' || channelIdForPost(post) === channelId;
    return matchesSearch && matchesStatus && matchesChannel;
  });
};

export const flattenAnalytics = analytics => {
  if (!analytics) return [];
  const values = Array.isArray(analytics)
    ? analytics
    : Object.entries(analytics).map(([label, data]) => ({ label, data }));
  return values.map(item => ({
    label: item.label || item.name || item.metric || 'Metric',
    percentageChange: item.percentageChange,
    total:
      item.total ||
      item.value ||
      item.data?.at?.(-1)?.total ||
      (Array.isArray(item.data)
        ? item.data.reduce(
            (sum, point) => sum + Number(point.total || point.value || 0),
            0
          )
        : item.data),
    points: Array.isArray(item.data) ? item.data : [],
  }));
};
