import { describe, expect, it, vi } from 'vitest';
import { mount } from '@vue/test-utils';

import AccountHealth from './AccountHealth.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key}:${params.count}` : key),
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

describe('AccountHealth', () => {
  it('shows safe recovery and lifecycle state when remote health is unavailable', () => {
    const wrapper = mountComponent({
      healthData: null,
      recoveryData: {
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
      },
    });

    expect(
      wrapper.findAll('[data-testid="whatsapp-recovery-status"]')
    ).toHaveLength(3);
    expect(wrapper.text()).toContain('manual recovery required');
    expect(wrapper.text()).toContain('history failed');
    expect(wrapper.text()).toContain(
      'INBOX MGMT.ACCOUNT HEALTH.RECOVERY.EVENTS:3'
    );
    expect(wrapper.text()).toContain('Callback recovery is required');
    expect(wrapper.text()).toContain('2026-07-18T20:00:00Z');
  });
});
