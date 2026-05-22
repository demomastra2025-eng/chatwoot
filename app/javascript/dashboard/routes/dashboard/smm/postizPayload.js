export const normalizePostizDate = (date, fallbackDate = new Date()) => {
  const sourceDate = date || fallbackDate;
  const parsedDate =
    sourceDate instanceof Date ? sourceDate : new Date(sourceDate);

  if (Number.isNaN(parsedDate.getTime())) return date;

  return parsedDate.toISOString();
};

export const buildPostizPostPayload = (
  composer,
  fallbackDate = new Date()
) => ({
  type: composer.type,
  date: normalizePostizDate(composer.date, fallbackDate),
  shortLink: Boolean(composer.shortLink),
  tags: composer.tags || [],
  posts: [
    {
      integration: { id: composer.integrationId },
      value: [
        {
          content: composer.content,
          image: (composer.media || []).map(item => ({
            id: item.id,
            path: item.path,
            ...(item.alt ? { alt: item.alt } : {}),
            ...(item.thumbnail ? { thumbnail: item.thumbnail } : {}),
          })),
        },
      ],
      settings: composer.settings || {},
    },
  ],
});
