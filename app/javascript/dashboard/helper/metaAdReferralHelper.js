const hasReferralValue = value =>
  value !== undefined && value !== null && value !== '';

export const getMetaAdReferralValue = (
  referral,
  camelKey,
  snakeKey = camelKey
) => {
  const camelValue = referral?.[camelKey];
  if (hasReferralValue(camelValue)) return camelValue;

  const snakeValue = referral?.[snakeKey];
  return hasReferralValue(snakeValue) ? snakeValue : '';
};

const formatMetaAdReferralTooltipValue = value => {
  const stringValue = String(value);
  return stringValue.length > 500
    ? `${stringValue.slice(0, 497)}...`
    : stringValue;
};

export const hasMetaAdReferral = referral =>
  [
    getMetaAdReferralValue(referral, 'ctwaClid', 'ctwa_clid'),
    getMetaAdReferralValue(referral, 'adId', 'ad_id'),
    getMetaAdReferralValue(referral, 'sourceId', 'source_id'),
    getMetaAdReferralValue(referral, 'sourceUrl', 'source_url'),
    referral?.headline,
    referral?.body,
  ].some(hasReferralValue);

export const metaAdReferralProviderLabel = (referral, t) => {
  const provider = String(referral?.provider || '').toLowerCase();
  if (provider === 'whatsapp') {
    return t('CRM.DEALS.META_AD_REFERRAL.PROVIDER_WHATSAPP');
  }
  if (provider === 'instagram') {
    return t('CRM.DEALS.META_AD_REFERRAL.PROVIDER_INSTAGRAM');
  }
  if (provider === 'facebook') {
    return t('CRM.DEALS.META_AD_REFERRAL.PROVIDER_FACEBOOK');
  }
  return t('CRM.DEALS.META_AD_REFERRAL.PROVIDER_META');
};

export const metaAdReferralSourceLabel = (referral, t) => {
  const providerLabel = metaAdReferralProviderLabel(referral, t);
  const metaLabel = t('CRM.DEALS.META_AD_REFERRAL.PROVIDER_META');
  return providerLabel === metaLabel
    ? metaLabel
    : `${metaLabel} → ${providerLabel}`;
};

const META_AD_DETAIL_FIELDS = [
  ['headline', 'headline', 'HEADLINE'],
  ['body', 'body', 'BODY'],
  ['attributionType', 'attribution_type', 'ATTRIBUTION_TYPE'],
  ['source', 'source', 'SOURCE'],
  ['sourceType', 'source_type', 'SOURCE_TYPE'],
  ['mediaType', 'media_type', 'MEDIA_TYPE'],
  ['ctwaClid', 'ctwa_clid', 'CTWA_CLID'],
  ['adId', 'ad_id', 'AD_ID'],
  ['sourceId', 'source_id', 'SOURCE_ID'],
  ['sourceUrl', 'source_url', 'SOURCE_URL'],
  ['postId', 'post_id', 'POST_ID'],
  ['productId', 'product_id', 'PRODUCT_ID'],
  ['flowId', 'flow_id', 'FLOW_ID'],
  ['ref', 'ref', 'REF'],
  ['referralType', 'referral_type', 'REFERRAL_TYPE'],
  ['receivedAt', 'received_at', 'RECEIVED_AT'],
  ['messageId', 'message_id', 'MESSAGE_ID'],
];

const metaAdReferralFieldLabel = (labelKey, t) => {
  const labels = {
    AD_ID: t('CRM.DEALS.META_AD_REFERRAL.AD_ID'),
    ATTRIBUTION_TYPE: t('CRM.DEALS.META_AD_REFERRAL.ATTRIBUTION_TYPE'),
    BODY: t('CRM.DEALS.META_AD_REFERRAL.BODY'),
    CTWA_CLID: t('CRM.DEALS.META_AD_REFERRAL.CTWA_CLID'),
    FLOW_ID: t('CRM.DEALS.META_AD_REFERRAL.FLOW_ID'),
    HEADLINE: t('CRM.DEALS.META_AD_REFERRAL.HEADLINE'),
    MEDIA_TYPE: t('CRM.DEALS.META_AD_REFERRAL.MEDIA_TYPE'),
    MESSAGE_ID: t('CRM.DEALS.META_AD_REFERRAL.MESSAGE_ID'),
    POST_ID: t('CRM.DEALS.META_AD_REFERRAL.POST_ID'),
    PRODUCT_ID: t('CRM.DEALS.META_AD_REFERRAL.PRODUCT_ID'),
    RECEIVED_AT: t('CRM.DEALS.META_AD_REFERRAL.RECEIVED_AT'),
    REF: t('CRM.DEALS.META_AD_REFERRAL.REF'),
    REFERRAL_TYPE: t('CRM.DEALS.META_AD_REFERRAL.REFERRAL_TYPE'),
    SOURCE: t('CRM.DEALS.META_AD_REFERRAL.SOURCE'),
    SOURCE_ID: t('CRM.DEALS.META_AD_REFERRAL.SOURCE_ID'),
    SOURCE_TYPE: t('CRM.DEALS.META_AD_REFERRAL.SOURCE_TYPE'),
    SOURCE_URL: t('CRM.DEALS.META_AD_REFERRAL.SOURCE_URL'),
  };

  return labels[labelKey] || labelKey;
};

export const buildMetaAdReferralRows = (referral, t, options = {}) => {
  const hiddenFields = new Set(options.exclude || []);

  return META_AD_DETAIL_FIELDS.filter(
    ([, snakeKey]) => !hiddenFields.has(snakeKey)
  )
    .map(([camelKey, snakeKey, labelKey]) => ({
      key: snakeKey,
      label: metaAdReferralFieldLabel(labelKey, t),
      value: getMetaAdReferralValue(referral, camelKey, snakeKey),
    }))
    .filter(row => hasReferralValue(row.value));
};

export const buildMetaAdReferralTooltipText = (referral, t) => {
  if (!hasMetaAdReferral(referral)) return '';

  const rows = buildMetaAdReferralRows(referral, t);
  return [
    `${t('CRM.DEALS.META_AD_REFERRAL.TITLE')}: ${metaAdReferralSourceLabel(referral, t)}`,
    ...rows.map(
      row => `${row.label}: ${formatMetaAdReferralTooltipValue(row.value)}`
    ),
  ].join('\n');
};

export const sanitizeMetaAdReferralUrl = url => {
  if (!url) return '';

  try {
    const parsedUrl = new URL(String(url));
    return ['http:', 'https:'].includes(parsedUrl.protocol)
      ? parsedUrl.href
      : '';
  } catch {
    return '';
  }
};

export const formatMetaAdReferralUrl = url => {
  const safeUrl = sanitizeMetaAdReferralUrl(url);
  if (!safeUrl) return '';

  const parsedUrl = new URL(safeUrl);
  return [parsedUrl.hostname, parsedUrl.pathname]
    .filter(Boolean)
    .join('')
    .replace(/\/$/, '');
};
