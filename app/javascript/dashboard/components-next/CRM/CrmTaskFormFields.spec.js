import { describe, expect, it, vi } from 'vitest';
import { shallowMount } from '@vue/test-utils';
import CrmTaskFormFields from './CrmTaskFormFields.vue';

const form = {
  activityType: 'task',
  allDay: false,
  assigneeId: 7,
  contextKind: 'personal',
  customAttributes: {},
  dealId: '',
  description: '',
  dueAt: '',
  originatingConversationDisplayId: '#12',
  originatingConversationId: 42,
  priority: 'medium',
  startAt: '',
  statusId: 1,
  title: '',
};

describe('shared task creation fields', () => {
  it('uses the resolved conversation display ID for the source action', () => {
    const wrapper = shallowMount(CrmTaskFormFields, {
      props: {
        accountId: 74,
        conversation: { id: 42, displayId: 12 },
        form: { ...form },
        updateFormActivityType: vi.fn(),
        updateAllDay: vi.fn(),
      },
      global: { mocks: { $t: key => key } },
    });
    expect(
      wrapper.findComponent({ name: 'CrmConversationLink' }).props()
    ).toMatchObject({ accountId: 74, displayId: 12 });
    expect(wrapper.text()).toContain('CRM.GENERAL.CONVERSATION_SOURCE');
  });

  it('shows the complete form and the linked conversation', () => {
    const wrapper = shallowMount(CrmTaskFormFields, {
      props: {
        form: { ...form },
        updateFormActivityType: vi.fn(),
        updateAllDay: vi.fn(),
      },
      global: {
        mocks: { $t: key => key },
        stubs: {
          SchedulingFormFieldGroup: { template: '<div><slot /></div>' },
        },
      },
    });
    const labels = wrapper
      .findAll('[label]')
      .map(field => field.attributes('label'));
    expect(labels).toEqual(
      expect.arrayContaining([
        'CRM.TASKS.FORM.TITLE',
        'CRM.TASKS.FORM.ACTIVITY_TYPE',
        'CRM.TASKS.FORM.ASSIGNEE',
        'CRM.TASKS.FORM.PRIORITY',
        'CRM.TASKS.FORM.STATUS',
        'CRM.TASKS.FORM.CONTEXT_KIND',
        'CRM.TASKS.FORM.DEAL',
        'CRM.TASKS.FORM.START_AT',
        'CRM.TASKS.FORM.DUE_AT',
        'CRM.TASKS.FORM.DESCRIPTION',
      ])
    );
    expect(wrapper.text()).toContain('CRM.GENERAL.LINKED_CONVERSATION');
    expect(
      wrapper.findComponent({ name: 'CrmConversationLink' }).props()
    ).toMatchObject({ accountId: null, displayId: '12' });
    expect(
      wrapper.findComponent({ name: 'CrmCustomFieldsSection' }).exists()
    ).toBe(true);
  });
});
