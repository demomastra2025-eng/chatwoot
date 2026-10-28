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
      wrapper.findComponent({ name: 'CrmCustomFieldsSection' }).exists()
    ).toBe(true);
  });
});
