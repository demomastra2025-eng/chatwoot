import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, shallowMount } from '@vue/test-utils';

import CaptainToolsAPI from 'dashboard/api/captain/tools';
import Checkbox from 'dashboard/components-next/checkbox/Checkbox.vue';
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

beforeEach(() => {
  CaptainToolsAPI.get.mockResolvedValue({
    data: [
      { id: 'add_private_note', title: 'Заметка в диалоге' },
      { id: 'add_contact_note', title: 'Заметка в карточке' },
      { id: 'send_notification', title: 'Уведомление' },
      { id: 'cancel_response', title: 'Отмена' },
    ],
  });
});

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

const canonical = (enabled = true, tool_ids = ['send_notification']) => ({
  version: 1,
  scopes: {
    agent: { enabled, tool_ids },
    assistant: { enabled: false, tool_ids: [] },
  },
});
const mountCanonical = async (enabled = true, canEdit = false) => {
  const wrapper = shallowMount(AgentToolChips, {
    props: {
      assistant: {
        id: 12,
        config: {
          capabilities: canonical(enabled),
          tool_access: {
            agent: { enabled: true, tool_ids: ['add_contact_note'] },
          },
        },
      },
      instruction: '[@Private](tool://add_private_note)',
      canEdit,
    },
  });
  await flushPromises();
  return wrapper;
};
describe('canonical capabilities', () => {
  it('reads only the enabled canonical scope, never legacy grants or prompt mentions', async () => {
    const wrapper = await mountCanonical();
    expect(
      wrapper
        .findAll('[data-test="agent-tool-chip"]')
        .map(chip => chip.attributes('title'))
    ).toEqual(['send_notification']);
    expect(
      wrapper.find('[data-test="agent-tool-chip-not-mentioned"]').exists()
    ).toBe(false);
    expect(wrapper.emitted('update:capabilities')).toBeUndefined();
  });
  it('an inactive canonical scope has no active chips despite mentions and legacy bindings', async () => {
    const wrapper = await mountCanonical(false);
    expect(wrapper.find('[data-test="agent-tool-chips"]').exists()).toBe(false);
  });
  it('allows an explicit scope edit preserving the other scope', async () => {
    const wrapper = await mountCanonical(true, true);
    wrapper
      .findAllComponents(Checkbox)[0]
      .vm.$emit('update:modelValue', ['send_notification', 'add_private_note']);
    expect(wrapper.emitted('update:capabilities')[0]).toEqual([
      canonical(true, ['send_notification', 'add_private_note']),
    ]);
  });
  it('does not offer scope editing for unmigrated records', async () => {
    const wrapper = shallowMount(AgentToolChips, {
      props: { assistant: { id: 12, config: {} }, canEdit: true },
    });
    await flushPromises();
    expect(wrapper.find('[data-test="agent-bindings"]').exists()).toBe(false);
    expect(wrapper.emitted('update:capabilities')).toBeUndefined();
  });
});
