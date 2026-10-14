import { describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';

import AgentToolChips from './AgentToolChips.vue';

vi.mock('dashboard/api/captain/tools', () => ({
  default: {
    get: vi.fn().mockResolvedValue({
      data: [
        { id: 'add_private_note', title: 'Заметка в диалоге' },
        { id: 'add_contact_note', title: 'Заметка в карточке' },
        { id: 'send_notification', title: 'Уведомление' },
        { id: 'cancel_response', title: 'Отмена' },
      ],
    }),
  },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key, te: () => false }),
}));

describe('AgentToolChips', () => {
  it('shows mentioned notes and notification but excludes cancel_response', async () => {
    const wrapper = shallowMount(AgentToolChips, {
      props: {
        assistant: {
          id: 12,
          config: { tool_access: { agent: { enabled: true, tool_ids: [] } } },
        },
        instruction:
          '[@Private](tool://add_private_note) [@Contact](tool://add_contact_note) ' +
          '[@Notify](tool://send_notification) [@Cancel](tool://cancel_response)',
      },
    });
    await flushPromises();

    const ids = wrapper
      .findAll('[data-test="agent-tool-chip"]')
      .map(chip => chip.attributes('title'));
    expect(ids).toEqual([
      'add_private_note',
      'add_contact_note',
      'send_notification',
    ]);
  });
});
