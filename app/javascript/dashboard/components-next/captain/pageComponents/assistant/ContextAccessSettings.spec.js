import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { useI18n } from 'vue-i18n';

import CaptainContextFieldsAPI from 'dashboard/api/captain/contextFields';
import ContextAccessSettings from './ContextAccessSettings.vue';

vi.mock('vue-i18n');
vi.mock('dashboard/api/captain/contextFields', () => ({
  default: {
    get: vi.fn(),
  },
}));

const translations = {
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TITLE': 'Context access',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.DESCRIPTION':
    'Choose context fields.',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.HINT': 'Hint',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.LOADING':
    'Loading available fields...',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.EMPTY': 'No fields are available.',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.DISABLED_MESSAGE': 'Disabled',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.CONTACT.TITLE':
    'Contact fields',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.CONTACT.DESCRIPTION':
    'Contact description',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.CONVERSATION.TITLE':
    'Conversation fields',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.CONVERSATION.DESCRIPTION':
    'Conversation description',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.DEAL.TITLE': 'Deal fields',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.DEAL.DESCRIPTION':
    'Deal description',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.TASK.TITLE': 'Task fields',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.TASK.DESCRIPTION':
    'Task description',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.APPOINTMENT.TITLE':
    'Appointment fields',
  'CAPTAIN.ASSISTANTS.FORM.CONTEXT_ACCESS.TABLES.APPOINTMENT.DESCRIPTION':
    'Appointment description',
};

const mountComponent = props =>
  mount(ContextAccessSettings, {
    props: {
      assistantId: 12,
      modelValue: {},
      ...props,
    },
    global: {
      stubs: {
        Checkbox: {
          props: {
            modelValue: {
              type: Boolean,
              default: false,
            },
          },
          template: '<div class="checkbox-stub" />',
        },
        Switch: {
          props: {
            modelValue: {
              type: Boolean,
              default: false,
            },
          },
          template: '<div class="switch-stub" />',
        },
      },
    },
  });

describe('ContextAccessSettings', () => {
  beforeEach(() => {
    useI18n.mockReturnValue({
      t: vi.fn(key => translations[key] || key),
    });
  });

  it('hides optional CRM and scheduling tables when their fields are unavailable', async () => {
    CaptainContextFieldsAPI.get.mockResolvedValue({
      data: [
        {
          id: 'contact.name',
          title: 'Name',
          group_name: 'Contact',
          table_name: 'contact',
          field_type: 'field',
          field_key: 'name',
          description: 'contact.name',
          selected: true,
        },
        {
          id: 'conversation.status',
          title: 'Status',
          group_name: 'Conversation',
          table_name: 'conversation',
          field_type: 'field',
          field_key: 'status',
          description: 'conversation.status',
          selected: true,
        },
      ],
    });

    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain('Contact fields');
    expect(wrapper.text()).toContain('Conversation fields');
    expect(wrapper.text()).not.toContain('Deal fields');
    expect(wrapper.text()).not.toContain('Task fields');
    expect(wrapper.text()).not.toContain('Appointment fields');
    expect(wrapper.emitted('update:modelValue').at(-1)?.[0]).not.toHaveProperty(
      'appointment'
    );
  });

  it('shows CRM and scheduling tables as disabled by default when their fields are available', async () => {
    CaptainContextFieldsAPI.get.mockResolvedValue({
      data: [
        {
          id: 'contact.name',
          title: 'Name',
          group_name: 'Contact',
          table_name: 'contact',
          field_type: 'field',
          field_key: 'name',
          description: 'contact.name',
          selected: true,
        },
        {
          id: 'conversation.status',
          title: 'Status',
          group_name: 'Conversation',
          table_name: 'conversation',
          field_type: 'field',
          field_key: 'status',
          description: 'conversation.status',
          selected: true,
        },
        {
          id: 'deal.stage_name',
          title: 'Stage Name',
          group_name: 'Deal',
          table_name: 'deal',
          field_type: 'field',
          field_key: 'stage_name',
          description: 'deal.stage_name',
          selected: false,
        },
        {
          id: 'task.status_name',
          title: 'Status Name',
          group_name: 'Task',
          table_name: 'task',
          field_type: 'field',
          field_key: 'status_name',
          description: 'task.status_name',
          selected: false,
        },
        {
          id: 'appointment.status',
          title: 'Status',
          group_name: 'Appointment',
          table_name: 'appointment',
          field_type: 'field',
          field_key: 'status',
          description: 'appointment.status',
          selected: false,
        },
      ],
    });

    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain('Deal fields');
    expect(wrapper.text()).toContain('Task fields');
    expect(wrapper.text()).toContain('Appointment fields');
    expect(wrapper.text()).toContain('0 / 1');
    expect(wrapper.emitted('update:modelValue').at(-1)?.[0]).toMatchObject({
      deal: { enabled: false, field_ids: ['deal.stage_name'] },
      task: { enabled: false, field_ids: ['task.status_name'] },
      appointment: { enabled: false, field_ids: ['appointment.status'] },
    });
  });

  it('keeps optional tables visible when they are configured on the assistant', async () => {
    CaptainContextFieldsAPI.get.mockResolvedValue({ data: [] });

    const wrapper = mountComponent({
      modelValue: {
        task: {
          enabled: true,
          field_ids: [],
        },
      },
    });
    await flushPromises();

    expect(wrapper.text()).toContain('Task fields');
    expect(wrapper.text()).toContain('0 / 0');
  });
});
