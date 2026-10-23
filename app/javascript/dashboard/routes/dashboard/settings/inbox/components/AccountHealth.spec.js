import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';

import AccountHealth from './AccountHealth.vue';

const translations = vi.hoisted(() => ({}));

// Unknown keys come back as the key itself, like vue-i18n does.
vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) =>
      params ? `${key}:${params.count}` : (translations[key] ?? key),
  }),
}));

const mountComponent = props =>
  mount(AccountHealth, {
    props,
    global: {
      stubs: {
        ButtonV4: true,
        Icon: true,
      },
    },
  });

const openDeveloperDetails = async wrapper => {
  await wrapper
    .find('[data-testid="developer-details"] button')
    .trigger('click');
};

const recoveryData = {
  webhook_callback_recovery: {
    state: 'manual_recovery_required',
    last_error: 'Callback recovery is required',
  },
  coexistence_sync: {
    state: 'history_failed',
    last_error: 'History recovery is required',
  },
  meta_webhook_lifecycle: {
    counters: { security: 2, user_preferences: 1 },
    last_event_at: '2026-07-18T20:00:00Z',
  },
};

const healthData = {
  display_phone_number: '+7 700 000 00 00',
  verified_name: 'Clinic',
  name_status: 'APPROVED',
  quality_rating: 'GREEN',
  messaging_limit: 'TIER_1K',
  account_mode: 'LIVE',
  webhook_configuration: { application: 'https://example.test/hook' },
  expected_webhook_url: 'https://example.test/hook',
};

describe('AccountHealth', () => {
  it('shows safe recovery and lifecycle state when remote health is unavailable', async () => {
    const wrapper = mountComponent({ healthData: null, recoveryData });

    await openDeveloperDetails(wrapper);

    expect(
      wrapper.findAll('[data-testid="whatsapp-recovery-status"]')
    ).toHaveLength(3);
    expect(wrapper.text()).toContain('manual recovery required');
    expect(wrapper.text()).toContain('history failed');
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.ACCOUNT_HEALTH.RECOVERY.EVENTS:3'
    );
    expect(wrapper.text()).toContain('Callback recovery is required');
    expect(wrapper.text()).toContain('2026-07-18T20:00:00Z');
  });

  it('keeps recovery details and the webhook card in a collapsed developer block', async () => {
    const wrapper = mountComponent({ healthData, recoveryData });

    expect(wrapper.find('[data-testid="developer-details"]').exists()).toBe(
      true
    );
    expect(
      wrapper.find('[data-testid="whatsapp-recovery-status"]').exists()
    ).toBe(false);
    expect(wrapper.text()).not.toContain(
      'INBOX_MGMT.ACCOUNT_HEALTH.WEBHOOK.TITLE'
    );
    expect(wrapper.text()).not.toContain('Callback recovery is required');

    await openDeveloperDetails(wrapper);

    expect(wrapper.text()).toContain('INBOX_MGMT.ACCOUNT_HEALTH.WEBHOOK.TITLE');
    expect(wrapper.text()).toContain('Callback recovery is required');
  });

  it('shows no developer block when there is nothing technical to show', () => {
    const wrapper = mountComponent({
      healthData: { ...healthData, webhook_configuration: undefined },
      recoveryData: {},
    });

    expect(wrapper.find('[data-testid="developer-details"]').exists()).toBe(
      false
    );
  });

  it('translates quality, status and empty values instead of showing raw codes', () => {
    Object.assign(translations, {
      'INBOX_MGMT.ACCOUNT_HEALTH.VALUES.QUALITY.YELLOW': 'Среднее',
      'INBOX_MGMT.ACCOUNT_HEALTH.VALUES.STATUSES.UNKNOWN': 'Нет данных',
      'INBOX_MGMT.ACCOUNT_HEALTH.VALUES.NOT_AVAILABLE': 'Не указан',
    });
    const wrapper = mountComponent({
      healthData: {
        ...healthData,
        display_phone_number: '',
        name_status: undefined,
        quality_rating: 'YELLOW',
      },
      recoveryData: {},
    });

    expect(wrapper.text()).toContain('Среднее');
    expect(wrapper.text()).toContain('Нет данных');
    expect(wrapper.text()).toContain('Не указан');
    expect(wrapper.text()).not.toContain('YELLOW');
    expect(wrapper.text()).not.toContain('UNKNOWN');
    expect(wrapper.text()).not.toContain('N/A');
  });
});
