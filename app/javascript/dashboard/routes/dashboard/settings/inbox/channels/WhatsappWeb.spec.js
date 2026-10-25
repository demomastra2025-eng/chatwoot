import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import WhatsappWebRiskNotice from '../components/WhatsappWebRiskNotice.vue';
import WhatsappWeb from './WhatsappWeb.vue';

// The form redirects through the app router, which is not under test.
vi.mock('../../../../index', () => ({ default: { replace: vi.fn() } }));

const mountForm = () =>
  mount(WhatsappWeb, {
    global: {
      mocks: {
        $store: {
          getters: { 'inboxes/getUIFlags': { isCreating: false } },
          dispatch: vi.fn(),
        },
        $route: { name: 'settings_inboxes_page_channel', params: {} },
      },
      stubs: { PageHeader: true },
    },
  });

describe('WhatsApp Web connect step', () => {
  it('warns about the unofficial channel before the number is connected', () => {
    const wrapper = mountForm();
    const notice = wrapper.find('[data-testid="whatsapp-web-risk-notice"]');

    expect(wrapper.findComponent(WhatsappWebRiskNotice).exists()).toBe(true);
    expect(notice.text()).toContain(
      'Unofficial channel: WhatsApp may block the number'
    );
  });

  it('keeps it a plain notice: no checkbox, and the number field stays the only input', () => {
    const wrapper = mountForm();
    const inputs = wrapper.findAll('input');

    expect(inputs).toHaveLength(1);
    expect(inputs[0].attributes('type')).toBe('tel');
    expect(wrapper.find('input[type="checkbox"]').exists()).toBe(false);
  });
});
