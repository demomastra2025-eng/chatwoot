import { describe, expect, it } from 'vitest';

import {
  buildMetaAdReferralRows,
  buildMetaAdReferralTooltipText,
  formatMetaAdReferralUrl,
  hasMetaAdReferral,
  metaAdReferralSourceLabel,
  sanitizeMetaAdReferralUrl,
} from './metaAdReferralHelper';

const labels = {
  AD_ID: 'ID рекламы',
  ATTRIBUTION_TYPE: 'Тип атрибуции',
  BODY: 'Текст объявления',
  CTWA_CLID: 'CTWA клик',
  FLOW_ID: 'Flow ID',
  HEADLINE: 'Заголовок',
  MEDIA_TYPE: 'Тип медиа',
  MESSAGE_ID: 'ID сообщения',
  POST_ID: 'ID поста',
  PRODUCT_ID: 'ID товара',
  PROVIDER_FACEBOOK: 'Messenger',
  PROVIDER_INSTAGRAM: 'Instagram',
  PROVIDER_META: 'Meta Ads',
  PROVIDER_WHATSAPP: 'WhatsApp',
  RECEIVED_AT: 'Получено',
  REF: 'Ref',
  REFERRAL_TYPE: 'Тип referral',
  SOURCE: 'Источник',
  SOURCE_ID: 'ID источника',
  SOURCE_TYPE: 'Тип источника',
  SOURCE_URL: 'URL источника',
  TITLE: 'Источник Meta Ads',
};

const t = key => labels[key.split('.').pop()] || key;

describe('metaAdReferralHelper', () => {
  it('builds useful rows for both snake_case and camelCase referral fields', () => {
    const referral = {
      provider: 'whatsapp',
      headline: 'Напишите нам',
      body: 'Для подробной информации напишите нам в Whatsapp',
      ctwa_clid: 'ctwa-1',
      adId: '120247627354820016',
      source_url: 'https://www.instagram.com/p/DaKpBgpMIJU/',
      media_type: 'image',
    };

    expect(hasMetaAdReferral(referral)).toBe(true);
    expect(metaAdReferralSourceLabel(referral, t)).toBe('Meta Ads → WhatsApp');
    expect(buildMetaAdReferralRows(referral, t)).toEqual(
      expect.arrayContaining([
        { key: 'headline', label: 'Заголовок', value: 'Напишите нам' },
        {
          key: 'body',
          label: 'Текст объявления',
          value: 'Для подробной информации напишите нам в Whatsapp',
        },
        { key: 'media_type', label: 'Тип медиа', value: 'image' },
        { key: 'ctwa_clid', label: 'CTWA клик', value: 'ctwa-1' },
        { key: 'ad_id', label: 'ID рекламы', value: '120247627354820016' },
        {
          key: 'source_url',
          label: 'URL источника',
          value: 'https://www.instagram.com/p/DaKpBgpMIJU/',
        },
      ])
    );
  });

  it('formats tooltip text and shortens display URLs', () => {
    const referral = {
      provider: 'instagram',
      headline: 'Premium consultation',
      sourceUrl: 'https://www.instagram.com/p/DaKpBgpMIJU/',
    };

    expect(buildMetaAdReferralTooltipText(referral, t)).toContain(
      'Источник Meta Ads: Meta Ads → Instagram'
    );
    expect(buildMetaAdReferralTooltipText(referral, t)).toContain(
      'Заголовок: Premium consultation'
    );
    expect(sanitizeMetaAdReferralUrl(referral.sourceUrl)).toBe(
      'https://www.instagram.com/p/DaKpBgpMIJU/'
    );
    expect(formatMetaAdReferralUrl(referral.sourceUrl)).toBe(
      'www.instagram.com/p/DaKpBgpMIJU'
    );
  });

  it('keeps numeric zero values and bounds tooltip detail length', () => {
    const longHeadline = 'x'.repeat(520);
    const referral = {
      provider: 'facebook',
      headline: longHeadline,
      adId: 0,
      source_id: 'fallback-source',
    };

    expect(buildMetaAdReferralRows(referral, t)).toEqual(
      expect.arrayContaining([
        { key: 'ad_id', label: 'ID рекламы', value: 0 },
        { key: 'source_id', label: 'ID источника', value: 'fallback-source' },
      ])
    );
    expect(buildMetaAdReferralTooltipText(referral, t)).toContain(
      `${'x'.repeat(497)}...`
    );
    expect(buildMetaAdReferralTooltipText(referral, t)).not.toContain(
      'x'.repeat(520)
    );
  });

  it('does not expose unsafe source URLs as clickable links', () => {
    const unsafeScriptUrl = `java${'script'}:alert(1)`;

    expect(sanitizeMetaAdReferralUrl(unsafeScriptUrl)).toBe('');
    expect(sanitizeMetaAdReferralUrl('data:text/html,<svg>')).toBe('');
    expect(sanitizeMetaAdReferralUrl('/relative/path')).toBe('');
    expect(formatMetaAdReferralUrl(unsafeScriptUrl)).toBe('');
  });
});
