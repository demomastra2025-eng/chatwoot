import { shallowMount, flushPromises } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import SchedulingConversationAppointmentsSidebar from './SchedulingConversationAppointmentsSidebar.vue';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';

const existingAppointment = {
  id: 501,
  clientName: 'Айша',
  contactId: 42,
  conversationId: 123,
  endsAt: '2026-06-27T10:30:00.000Z',
  resourceId: 7,
  serviceAmount: 5000,
  serviceId: 9,
  serviceNameSnapshot: 'Консультация',
  startsAt: '2026-06-27T10:00:00.000Z',
  status: 'confirmed',
};

const mocks = vi.hoisted(() => ({
  alert: vi.fn(),
  dispatch: vi.fn(),
  loadResources: vi.fn(() => Promise.resolve()),
  loadServices: vi.fn(() => Promise.resolve()),
  resources: [
    {
      active: true,
      id: 7,
      name: 'Дина',
      slotDurationMin: 30,
      specialty: 'Стилист',
    },
  ],
  services: [
    {
      active: true,
      basePrice: 5000,
      durationMin: 30,
      id: 9,
      name: 'Консультация',
      prices: [],
    },
  ],
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: { value: 'ru' },
    t: key => key,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: mocks.alert,
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: mocks.dispatch }),
}));

vi.mock('dashboard/api/scheduling/appointments', () => ({
  default: {
    create: vi.fn(() =>
      Promise.resolve({
        data: { payload: { ...existingAppointment, id: 777 } },
      })
    ),
    get: vi.fn(() =>
      Promise.resolve({ data: { payload: [existingAppointment] } })
    ),
    update: vi.fn(() =>
      Promise.resolve({
        data: { payload: { ...existingAppointment, client_name: 'Айша' } },
      })
    ),
  },
}));

vi.mock('dashboard/stores/scheduling/references', () => ({
  useSchedulingReferencesStore: () => ({
    activeResources: mocks.resources,
    activeServices: mocks.services,
    loadResources: mocks.loadResources,
    loadServices: mocks.loadServices,
    resources: mocks.resources,
    services: mocks.services,
  }),
}));

const defaultCurrentChat = () => ({
  id: 123,
  meta: {
    sender: {
      id: 42,
      name: 'Айша',
      phone_number: 'test-phone-4567',
    },
  },
});

const mountComponent = (currentChat = defaultCurrentChat()) =>
  shallowMount(SchedulingConversationAppointmentsSidebar, {
    props: {
      currentChat,
    },
    global: {
      stubs: {
        SidebarActionsHeader: {
          name: 'SidebarActionsHeader',
          props: ['buttons'],
          emits: ['click', 'close'],
          template:
            '<button type="button" @click="$emit(\'click\', buttons[0].key)" />',
        },
        Spinner: true,
      },
    },
  });

describe('SchedulingConversationAppointmentsSidebar', () => {
  beforeEach(() => {
    mocks.services.splice(0, mocks.services.length, {
      active: true,
      basePrice: 5000,
      durationMin: 30,
      id: 9,
      name: 'Консультация',
      prices: [],
    });
    mocks.alert.mockClear();
    mocks.dispatch.mockClear();
    mocks.loadResources.mockClear();
    mocks.loadServices.mockClear();
    SchedulingAppointmentsAPI.create.mockClear();
    SchedulingAppointmentsAPI.get.mockClear();
    SchedulingAppointmentsAPI.update.mockClear();
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [existingAppointment] },
    });
  });

  it('opens the new appointment form inline from the header plus button', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const header = wrapper.findComponent({ name: 'SidebarActionsHeader' });
    expect(header.props('buttons')).toEqual([
      expect.objectContaining({
        icon: 'i-lucide-plus',
        key: 'new_appointment',
      }),
    ]);

    await header.vm.$emit('click', 'new_appointment');

    const html = wrapper.html();
    expect(html).toContain('i-lucide-calendar-plus');
    expect(html).toContain('text-n-amber-11');
    expect(html).toContain('appointment-status-dashed-rail');
    expect(html).toContain('rounded-full');
    expect(
      wrapper.find('#scheduling-conversation-appointment-status').exists()
    ).toBe(true);
    expect(
      wrapper.find('#scheduling-conversation-appointment-client-name').exists()
    ).toBe(true);
    expect(wrapper.vm.createForm.status).toBe('scheduled');
    expect(
      wrapper.vm.statusOptions.find(option => option.value === 'scheduled')
    ).toMatchObject({
      label: 'SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.scheduled',
    });
    expect(
      wrapper.vm.statusOptions.find(option => option.value === 'completed')
    ).toMatchObject({
      label: 'SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.completed',
    });
    expect(
      wrapper.vm.statusOptions.find(option => option.value === 'confirmed')
    ).toMatchObject({
      iconClass: 'text-n-blue-11',
      label: 'SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.confirmed',
      labelClass: 'text-n-blue-11',
    });
    expect(
      wrapper.vm.statusOptions.find(option => option.value === 'scheduled')
    ).toMatchObject({
      iconClass: 'text-n-amber-11',
      labelClass: 'text-n-amber-11',
    });
  });

  it('renders appointment status as a colored icon before the title with a dashed status rail', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const html = wrapper.html();
    expect(html).toContain('i-lucide-badge-check');
    expect(html).toContain('text-n-blue-11');
    expect(html).toContain('appointment-status-dashed-rail');
    expect(html).toContain('rounded-full');
    expect(html.indexOf('appointment-status-dashed-rail')).toBeLessThan(
      html.indexOf('i-lucide-badge-check')
    );
    expect(html.indexOf('i-lucide-badge-check')).toBeLessThan(
      html.indexOf('Айша')
    );
  });

  it('opens an existing appointment as an edit form immediately', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    expect(
      wrapper
        .find('#scheduling-conversation-appointment-client-name-501')
        .exists()
    ).toBe(true);
    expect(wrapper.vm.openAppointmentKeys).toEqual(['appointment-501']);
    expect(wrapper.vm.appointmentForms['appointment-501']).toMatchObject({
      clientName: 'Айша',
      resourceId: 7,
      serviceId: 9,
      status: 'confirmed',
    });
  });

  it('updates an existing appointment from the inline edit form', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    Object.assign(wrapper.vm.appointmentForms['appointment-501'], {
      clientName: 'Айша updated',
      clientPhone: 'test-phone-4567',
      endsAt: '2026-06-27T11:00',
      resourceId: 7,
      serviceAmount: '7000',
      serviceId: 9,
      startsAt: '2026-06-27T10:30',
      status: 'completed',
    });

    await wrapper.vm.saveAppointment(existingAppointment);

    expect(SchedulingAppointmentsAPI.update).toHaveBeenCalledWith(501, {
      appointment_type: 'primary',
      client_name: 'Айша updated',
      client_phone: 'test-phone-4567',
      contact_id: 42,
      conversation_id: 123,
      ends_at: new Date('2026-06-27T11:00').toISOString(),
      resource_id: 7,
      service_amount: 7000,
      service_id: 9,
      service_ids: [9],
      source: 'conversation',
      starts_at: new Date('2026-06-27T10:30').toISOString(),
      status: 'completed',
    });
    expect(mocks.dispatch).toHaveBeenCalledWith('fetchSidebarUnreadCounts');
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'
    );
  });

  it('updates an existing appointment without stale service ids when no active services exist', async () => {
    mocks.services.splice(0, mocks.services.length, {
      active: false,
      basePrice: 5000,
      durationMin: 30,
      id: 9,
      name: 'Консультация',
      prices: [],
    });
    const wrapper = mountComponent();
    await flushPromises();

    Object.assign(wrapper.vm.appointmentForms['appointment-501'], {
      serviceAmount: '7000',
    });

    await wrapper.vm.saveAppointment(existingAppointment);

    expect(wrapper.vm.hasServiceOptions).toBe(false);
    expect(SchedulingAppointmentsAPI.update).toHaveBeenCalledWith(
      501,
      expect.objectContaining({
        service_amount: 7000,
        service_ids: [],
        service_name_snapshot: 'Консультация',
      })
    );
    expect(
      SchedulingAppointmentsAPI.update.mock.calls.at(-1)[1]
    ).not.toHaveProperty('service_id');
  });

  it('updates a dialog appointment by conversation display id when the record is not linked to a database conversation id', async () => {
    const threadAppointment = {
      ...existingAppointment,
      conversationDisplayId: null,
      conversationId: null,
    };
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [threadAppointment] },
    });
    const wrapper = mountComponent({
      active_reply_channel: { conversation_id: 659 },
      conversation_ids: [659],
      id: 22,
      is_communication_thread: true,
      meta: {
        sender: {
          id: 42,
          name: 'Айша',
          phone_number: 'test-phone-4567',
        },
      },
    });
    await flushPromises();

    Object.assign(wrapper.vm.appointmentForms['appointment-501'], {
      clientName: 'Айша updated',
      endsAt: '2026-06-27T11:00',
      resourceId: 7,
      serviceAmount: '7000',
      startsAt: '2026-06-27T10:30',
    });

    await wrapper.vm.saveAppointment(threadAppointment);

    const payload = SchedulingAppointmentsAPI.update.mock.calls.at(-1)[1];
    expect(payload).toMatchObject({ conversation_display_id: 659 });
    expect(payload).not.toHaveProperty('conversation_id');
  });

  it('creates an appointment from the inline form with dialog context', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper
      .findComponent({ name: 'SidebarActionsHeader' })
      .vm.$emit('click', 'new_appointment');

    Object.assign(wrapper.vm.createForm, {
      clientName: 'Айша',
      clientPhone: 'test-phone-4567',
      endsAt: '2026-06-27T10:30',
      resourceId: 7,
      serviceAmount: '5000',
      serviceId: 9,
      startsAt: '2026-06-27T10:00',
      status: 'completed',
    });

    await wrapper.vm.saveCreateAppointment();

    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledWith({
      appointment_type: 'primary',
      client_name: 'Айша',
      client_phone: 'test-phone-4567',
      contact_id: 42,
      conversation_display_id: 123,
      ends_at: new Date('2026-06-27T10:30').toISOString(),
      resource_id: 7,
      service_amount: 5000,
      service_id: 9,
      service_ids: [9],
      source: 'conversation',
      starts_at: new Date('2026-06-27T10:00').toISOString(),
      status: 'completed',
    });
    expect(mocks.dispatch).toHaveBeenCalledWith('fetchSidebarUnreadCounts');
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'
    );
  });

  it('uses a free service name field when there are no configured services', async () => {
    mocks.services.splice(0, mocks.services.length);
    SchedulingAppointmentsAPI.get.mockResolvedValue({ data: { payload: [] } });
    const wrapper = mountComponent();
    await flushPromises();

    expect(
      wrapper.find('#scheduling-conversation-appointment-service').exists()
    ).toBe(true);
    expect(wrapper.vm.hasServiceOptions).toBe(false);

    Object.assign(wrapper.vm.createForm, {
      clientName: 'Айша',
      clientPhone: 'test-phone-4567',
      endsAt: '2026-06-27T10:30',
      resourceId: 7,
      serviceAmount: '3000',
      serviceNameSnapshot: 'Осмотр',
      startsAt: '2026-06-27T10:00',
    });

    await wrapper.vm.saveCreateAppointment();

    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledWith({
      appointment_type: 'primary',
      client_name: 'Айша',
      client_phone: 'test-phone-4567',
      contact_id: 42,
      conversation_display_id: 123,
      ends_at: new Date('2026-06-27T10:30').toISOString(),
      resource_id: 7,
      service_amount: 3000,
      service_ids: [],
      service_name_snapshot: 'Осмотр',
      source: 'conversation',
      starts_at: new Date('2026-06-27T10:00').toISOString(),
      status: 'scheduled',
    });
  });
});
