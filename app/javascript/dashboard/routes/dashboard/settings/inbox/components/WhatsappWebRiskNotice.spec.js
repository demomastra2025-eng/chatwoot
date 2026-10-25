import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

import Banner from 'dashboard/components-next/banner/Banner.vue';
import en from 'dashboard/i18n/locale/en/inboxMgmt.json';
import kk from 'dashboard/i18n/locale/kk/inboxMgmt.json';
import ru from 'dashboard/i18n/locale/ru/inboxMgmt.json';
import WhatsappWebRiskNotice from './WhatsappWebRiskNotice.vue';

describe('WhatsappWebRiskNotice', () => {
  it('is a visible amber callout with the risk and the advice, and nothing to accept', () => {
    const wrapper = mount(WhatsappWebRiskNotice);
    const notice = wrapper.find('[data-testid="whatsapp-web-risk-notice"]');

    expect(notice.exists()).toBe(true);
    expect(wrapper.findComponent(Banner).props('color')).toBe('amber');
    expect(notice.attributes('role')).toBe('note');
    expect(notice.text()).toContain(
      'Unofficial channel: WhatsApp may block the number'
    );
    expect(notice.text()).toContain('we recommend the official WhatsApp');
    expect(wrapper.find('input').exists()).toBe(false);
    expect(wrapper.find('button').exists()).toBe(false);
  });

  it('says it in Russian plainly', () => {
    expect(ru.INBOX_MGMT.WHATSAPP_WEB_RISK).toEqual({
      TITLE:
        'Неофициальный канал: возможна блокировка номера со стороны WhatsApp',
      DESCRIPTION:
        'Для бизнеса рекомендуем официальный WhatsApp. Риск выше при массовых рассылках и сообщениях тем, кто не писал вам первым.',
    });
  });

  it.each([
    ['en', en],
    ['kk', kk],
  ])('has both texts in %s', (_, messages) => {
    const { TITLE, DESCRIPTION } = messages.INBOX_MGMT.WHATSAPP_WEB_RISK;

    expect(TITLE).toEqual(expect.any(String));
    expect(TITLE).not.toBe('');
    expect(DESCRIPTION).toEqual(expect.any(String));
    expect(DESCRIPTION).not.toBe('');
  });
});
