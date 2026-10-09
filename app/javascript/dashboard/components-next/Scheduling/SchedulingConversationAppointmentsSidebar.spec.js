import { shallowMount, flushPromises } from '@vue/test-utils';
import { createPinia } from 'pinia';
import { reactive as makeReactive } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import SchedulingConversationAppointmentsSidebar from './SchedulingConversationAppointmentsSidebar.vue';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import SchedulingProviderCommandsAPI from 'dashboard/api/scheduling/providerCommands';

const existingAppointment = {
  id: 501,
  clientFirstName: 'Айша',
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

// Form times are the clinic wall clock (Asia/Almaty, UTC+5 all year), like
// the calendar grid; this is the instant they are saved as.
const clinicIso = wallClock => new Date(`${wallClock}:00+05:00`).toISOString();

const manualReviewCommand = {
  id: 55,
  operation: 'create_reception',
  status: 'provider_status_unknown',
  manual_cancellation_available: true,
  manual_cancellation_reception_code: 'created-1',
};

const patientActionCommand = (
  status = 'awaiting_patient_selection',
  attributes = {}
) => ({
  id: 66,
  appointment_id: 501,
  operation: 'create_reception',
  provider: 'medelement',
  company_cabinet_code: '501',
  status,
  patient_action: {
    can_confirm: true,
    candidate_count: 1,
    ...attributes.patient_action,
  },
  ...attributes,
});

const verifiedCancellationResponse = () => ({
  data: {
    payload: {
      id: 55,
      status: 'cancelled',
      manual_cancellation_resolution: {
        result: 'removed',
        reception_code: 'created-1',
      },
      appointment: { ...existingAppointment, status: 'cancelled' },
    },
  },
});

const deferredRequest = () => {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
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
  route: null,
  t: vi.fn(key => key),
}));

const configureMedelementResource = () => {
  mocks.resources[0].customAttributes = {
    medelement_cabinets: [{ company_cabinet_code: '501' }],
    medelement_specialist_code: 'specialist-1',
  };
};

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    locale: { value: 'ru' },
    t: mocks.t,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: mocks.alert,
}));

vi.mock('vue-router', async () => {
  const { reactive } = await import('vue');
  mocks.route = reactive({ params: { accountId: '1' } });
  return { useRoute: () => mocks.route };
});

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
    show: vi.fn(() =>
      Promise.resolve({
        data: {
          payload: {
            ...existingAppointment,
            custom_attributes: {
              medelement_provider_sync_status: 'succeeded',
              medelement_reception_code: 'reception-501',
            },
            external_ref: 'medelement:reception:reception-501',
            provider_confirmation_status: 'succeeded',
          },
        },
      })
    ),
    update: vi.fn(() =>
      Promise.resolve({
        data: { payload: { ...existingAppointment, client_name: 'Айша' } },
      })
    ),
    cancel: vi.fn(() =>
      Promise.resolve({
        data: {
          payload: {
            ...existingAppointment,
            medelement_provider_sync_status: 'pending',
          },
        },
      })
    ),
  },
}));

vi.mock('dashboard/api/scheduling/providerCommands', () => ({
  default: {
    confirm: vi.fn(),
    list: vi.fn(),
    reconcile: vi.fn(),
    resolveCancellation: vi.fn(),
    patientCandidates: vi.fn(),
    selectPatient: vi.fn(),
    confirmPatientCreation: vi.fn(),
    retry: vi.fn(),
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

const mountComponent = (
  currentChat = defaultCurrentChat(),
  patientProps = {}
) => {
  mocks.route = makeReactive({ params: { accountId: '1' } });
  return shallowMount(SchedulingConversationAppointmentsSidebar, {
    props: {
      currentChat,
      ...patientProps,
    },
    global: {
      plugins: [createPinia()],
      stubs: {
        RouterLink: {
          name: 'RouterLink',
          props: ['to'],
          template:
            '<a :data-contact-id="to.params.contactId" :data-account-id="to.params.accountId"><slot /></a>',
        },
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
};

describe('SchedulingConversationAppointmentsSidebar', () => {
  const patientContextProps = (id = 84) => ({
    patientContextEnabled: true,
    patientContextKey: '1:9:conversation:123',
    selectedPatient: {
      id,
      patient_contact_id: id,
      selectable_patient: true,
      first_name: `Patient ${id}`,
      last_name: 'Family',
      full_name: `Family Patient ${id}`,
      phone: '+77001234567',
      birth_date: '2017-01-02',
      gender: 'female',
    },
  });

  it('filters by the patient and preserves the original chat owner when creating', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({ data: { payload: [] } });
    const chat = defaultCurrentChat();
    const wrapper = mountComponent(chat, patientContextProps());
    await flushPromises();
    expect(SchedulingAppointmentsAPI.get).toHaveBeenCalledWith({
      patient_contact_ids: 84,
    });
    expect(wrapper.vm.createForm.clientFirstName).toBe('Patient 84');
    expect(wrapper.vm.buildCreatePayload()).toMatchObject({
      contact_id: 42,
      patient_contact_id: 84,
      conversation_display_id: 123,
      client_first_name: 'Patient 84',
      client_birth_date: '2017-01-02',
    });
    expect(chat.meta.sender.id).toBe(42);
    expect(chat.meta.sender.name).toBe('Айша');
  });

  it('omits patient_contact_id for the default owner rather than submitting null', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({ data: { payload: [] } });
    const wrapper = mountComponent(defaultCurrentChat(), {
      ...patientContextProps(),
      selectedPatient: {
        id: 42,
        first_name: 'Owner',
        patient_contact_id: null,
        selectable_patient: false,
      },
    });
    await flushPromises();
    expect(wrapper.vm.buildCreatePayload().contact_id).toBe(42);
    expect(wrapper.vm.buildCreatePayload()).not.toHaveProperty(
      'patient_contact_id'
    );
  });

  it('can explicitly use a verified original chat owner as the patient', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({ data: { payload: [] } });
    const props = patientContextProps(42);
    const wrapper = mountComponent(defaultCurrentChat(), props);
    await flushPromises();
    expect(wrapper.vm.buildCreatePayload()).toMatchObject({
      contact_id: 42,
      patient_contact_id: 42,
    });
    expect(wrapper.props('currentChat').meta.sender.id).toBe(42);
  });

  it('does not transfer a draft to another patient and restores it on return', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({ data: { payload: [] } });
    const wrapper = mountComponent(defaultCurrentChat(), patientContextProps());
    await flushPromises();
    wrapper.vm.createForm.clientFirstName = 'Draft for 84';
    wrapper.vm.createForm.clientIdentifier = '940720300129';
    await wrapper.setProps(patientContextProps(85));
    await flushPromises();
    expect(wrapper.vm.createForm.clientFirstName).toBe('Patient 85');
    expect(wrapper.vm.createForm.clientIdentifier).toBe('');
    expect(wrapper.vm.createForm.patientContactId).toBe(85);
    await wrapper.setProps(patientContextProps(84));
    await flushPromises();
    expect(wrapper.vm.createForm.clientFirstName).toBe('Draft for 84');
    expect(wrapper.vm.createForm.clientIdentifier).toBe('940720300129');
    expect(wrapper.vm.createForm.patientContactId).toBe(84);
  });

  it('ignores the previous patient list after selection changes in the same chat', async () => {
    const previous = deferredRequest();
    SchedulingAppointmentsAPI.get.mockReturnValueOnce(previous.promise);
    const wrapper = mountComponent(defaultCurrentChat(), patientContextProps());
    await flushPromises();
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            id: 502,
            patientContactId: 85,
          },
        ],
      },
    });
    await wrapper.setProps(patientContextProps(85));
    await flushPromises();
    previous.resolve({
      data: { payload: [{ ...existingAppointment, patientContactId: 84 }] },
    });
    await flushPromises();
    expect(wrapper.vm.appointments.map(item => item.id)).toEqual([502]);
  });

  it('does not apply a save response to the next selected patient', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({ data: { payload: [] } });
    const previous = deferredRequest();
    SchedulingAppointmentsAPI.create.mockReturnValueOnce(previous.promise);
    const wrapper = mountComponent(defaultCurrentChat(), patientContextProps());
    await flushPromises();
    const saving = wrapper.vm.saveCreateAppointment();
    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({
        contact_id: 42,
        patient_contact_id: 84,
      })
    );
    await wrapper.setProps(patientContextProps(85));
    await flushPromises();
    previous.resolve({
      data: { payload: { ...existingAppointment, patientContactId: 84 } },
    });
    await saving;
    expect(wrapper.vm.appointments).toEqual([]);
    expect(wrapper.vm.createForm.patientContactId).toBe(85);
    expect(wrapper.emitted('patientBound')).toBeUndefined();
  });

  it('keeps an existing appointment binding when preparing its update', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            patientContactId: 84,
          },
        ],
      },
    });
    const wrapper = mountComponent(defaultCurrentChat(), patientContextProps());
    await flushPromises();
    expect(
      wrapper.vm.buildAppointmentPayload(
        wrapper.vm.appointmentForms['appointment-501']
      )
    ).toMatchObject({
      contact_id: 42,
      patient_contact_id: 84,
      conversation_id: 123,
    });
  });

  it('offers failed conflict recovery only after a local command read and explicit patient confirmation', async () => {
    configureMedelementResource();
    const appointment = {
      ...existingAppointment,
      patientContactId: 84,
      providerConfirmationStatus: 'failed',
    };
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [appointment] },
    });
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: {
        payload: [
          patientActionCommand('failed', {
            last_error_code: 'patient_ref_conflict',
            patient_action: {
              type: 'patient_selection',
              can_confirm: true,
              requires_patient_card_confirmation: true,
              cancellable: false,
            },
          }),
        ],
      },
    });
    SchedulingProviderCommandsAPI.patientCandidates.mockResolvedValue({
      data: {
        payload: {
          candidates: [{ token: 'opaque-candidate' }],
        },
      },
    });
    SchedulingProviderCommandsAPI.selectPatient.mockResolvedValueOnce({
      data: {
        payload: {
          id: 66,
          appointment_id: 501,
          operation: 'create_reception',
          provider: 'medelement',
          company_cabinet_code: '501',
          status: 'succeeded',
          appointment: {
            ...appointment,
            patientContactId: 86,
            patientContextContactId: 86,
          },
        },
      },
    });
    const wrapper = mountComponent(defaultCurrentChat(), patientContextProps());
    await flushPromises();
    expect(SchedulingProviderCommandsAPI.selectPatient).not.toHaveBeenCalled();
    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);
    expect(SchedulingProviderCommandsAPI.selectPatient).not.toHaveBeenCalled();
    const entry = wrapper.vm.patientActions['appointment-501'];
    expect(entry.candidates).toEqual([{ token: 'opaque-candidate' }]);
    entry.selectedPatientToken = 'opaque-candidate';
    expect(wrapper.vm.canContinuePatientAction(entry)).toBe(true);
    await wrapper.vm.continuePatientAction(wrapper.vm.appointments[0]);
    expect(SchedulingProviderCommandsAPI.selectPatient).toHaveBeenCalledWith(
      66,
      {
        provider: 'medelement',
        token: 'opaque-candidate',
      }
    );
    expect(wrapper.emitted('patientBound')[0][0].patientContactId).toBe(86);
    expect(wrapper.props('currentChat').meta.sender.id).toBe(42);
  });

  it.each([
    ['candidates', 'patient'],
    ['candidates', 'chat'],
    ['candidates', 'account'],
    ['readback', 'patient'],
    ['readback', 'chat'],
    ['readback', 'account'],
  ])(
    'does not emit an old patient binding after %s finishes in another %s context',
    async (phase, changedScope) => {
      configureMedelementResource();
      const appointment = {
        ...existingAppointment,
        accountId: 1,
        patientContactId: 84,
      };
      SchedulingAppointmentsAPI.get.mockResolvedValue({
        data: { payload: [appointment] },
      });
      SchedulingProviderCommandsAPI.list.mockResolvedValue({
        data: { payload: [patientActionCommand()] },
      });
      SchedulingProviderCommandsAPI.patientCandidates.mockResolvedValue({
        data: { payload: { candidates: [{ token: 'candidate-token' }] } },
      });
      const wrapper = mountComponent(
        defaultCurrentChat(),
        patientContextProps()
      );
      await flushPromises();
      await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);
      const entry = wrapper.vm.patientActions['appointment-501'];
      entry.selectedPatientToken = 'candidate-token';
      const pending = deferredRequest();
      const boundAppointment = {
        ...appointment,
        patientContactId: 86,
        patientContextContactId: 86,
      };
      SchedulingProviderCommandsAPI.selectPatient.mockResolvedValueOnce({
        data: {
          payload: patientActionCommand(
            phase === 'candidates' ? 'awaiting_patient_selection' : 'succeeded',
            { appointment: boundAppointment }
          ),
        },
      });
      if (phase === 'candidates')
        SchedulingProviderCommandsAPI.patientCandidates.mockReturnValueOnce(
          pending.promise
        );
      else SchedulingAppointmentsAPI.show.mockReturnValueOnce(pending.promise);

      const continuing = wrapper.vm.continuePatientAction(
        wrapper.vm.appointments[0]
      );
      await flushPromises();
      if (phase === 'candidates')
        expect(
          SchedulingProviderCommandsAPI.patientCandidates
        ).toHaveBeenCalledTimes(2);
      else expect(SchedulingAppointmentsAPI.show).toHaveBeenCalledWith(501);

      const nextOwner = changedScope === 'chat' ? 77 : 42;
      SchedulingAppointmentsAPI.get.mockResolvedValue({
        data: {
          payload: [
            {
              ...existingAppointment,
              id: 502,
              accountId: changedScope === 'account' ? 2 : 1,
              contactId: nextOwner,
              patientContactId: 85,
            },
          ],
        },
      });
      SchedulingProviderCommandsAPI.list.mockResolvedValue({
        data: { payload: [] },
      });
      if (changedScope === 'account') mocks.route.params.accountId = '2';
      await wrapper.setProps({
        ...patientContextProps(85),
        patientContextKey:
          {
            account: '2:9:conversation:123',
            chat: '1:9:conversation:999',
          }[changedScope] || '1:9:conversation:123',
        ...(changedScope === 'chat'
          ? { currentChat: { id: 999, meta: { sender: { id: 77 } } } }
          : {}),
      });
      await flushPromises();

      pending.resolve({
        data: {
          payload:
            phase === 'candidates'
              ? { candidates: [{ token: 'late-candidate' }] }
              : boundAppointment,
        },
      });
      await continuing;
      await flushPromises();
      expect(wrapper.emitted('patientBound')).toBeUndefined();
      expect(wrapper.props('selectedPatient').id).toBe(85);
      expect(wrapper.vm.appointments.map(item => item.id)).toEqual([502]);
    }
  );

  it('links a separate patient card without replacing the chat contact', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            clientName: 'Relative Patient',
            patientContactId: 84,
            patientContactName: 'Relative',
          },
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();
    const link = wrapper.find('[data-testid="appointment-patient-card"]');
    expect(link.text()).toContain('Relative');
    expect(link.text()).toContain('#84');
    expect(link.attributes('data-contact-id')).toBe('84');
    expect(link.attributes('data-account-id')).toBe('1');
    expect(wrapper.vm.appointments[0].contactId).toBe(42);
    expect(wrapper.props('currentChat').meta.sender.id).toBe(42);
  });

  it('removes the old patient card when the conversation changes', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            patientContactId: 84,
            patientContactName: 'Relative',
          },
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();
    expect(
      wrapper.find('[data-testid="appointment-patient-card"]').exists()
    ).toBe(true);
    SchedulingAppointmentsAPI.get.mockResolvedValue({ data: { payload: [] } });
    await wrapper.setProps({
      currentChat: { id: 456, meta: { sender: { id: 99, name: 'Other' } } },
    });
    await flushPromises();
    expect(
      wrapper.find('[data-testid="appointment-patient-card"]').exists()
    ).toBe(false);
  });
  const openManualReview = async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            providerConfirmationStatus: 'provider_status_unknown',
          },
        ],
      },
    });
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: { payload: [manualReviewCommand] },
    });
    const wrapper = mountComponent();
    await flushPromises();
    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);
    return wrapper;
  };

  beforeEach(() => {
    mocks.resources.splice(0, mocks.resources.length, {
      active: true,
      id: 7,
      name: 'Дина',
      slotDurationMin: 30,
      specialty: 'Стилист',
    });
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
    mocks.t.mockClear();
    mocks.loadResources.mockClear();
    mocks.loadServices.mockClear();
    SchedulingAppointmentsAPI.create.mockClear();
    SchedulingAppointmentsAPI.get.mockClear();
    SchedulingAppointmentsAPI.show.mockClear();
    SchedulingAppointmentsAPI.update.mockClear();
    SchedulingAppointmentsAPI.cancel.mockClear();
    SchedulingProviderCommandsAPI.list.mockReset();
    SchedulingProviderCommandsAPI.confirm.mockReset();
    SchedulingProviderCommandsAPI.reconcile.mockReset();
    SchedulingProviderCommandsAPI.resolveCancellation.mockReset();
    SchedulingProviderCommandsAPI.patientCandidates.mockReset();
    SchedulingProviderCommandsAPI.selectPatient.mockReset();
    SchedulingProviderCommandsAPI.confirmPatientCreation.mockReset();
    SchedulingProviderCommandsAPI.retry.mockReset();
    SchedulingProviderCommandsAPI.resolveCancellation.mockResolvedValue(
      verifiedCancellationResponse()
    );
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: { payload: [] },
    });
    SchedulingProviderCommandsAPI.reconcile.mockResolvedValue({
      data: { payload: {} },
    });
    SchedulingProviderCommandsAPI.patientCandidates.mockResolvedValue({
      data: { payload: { candidates: [] } },
    });
    SchedulingProviderCommandsAPI.selectPatient.mockResolvedValue({
      data: {
        payload: {
          id: 66,
          appointment_id: 501,
          operation: 'create_reception',
          provider: 'medelement',
          company_cabinet_code: '501',
          status: 'succeeded',
        },
      },
    });
    SchedulingProviderCommandsAPI.confirmPatientCreation.mockResolvedValue({
      data: {
        payload: {
          id: 66,
          appointment_id: 501,
          operation: 'create_reception',
          provider: 'medelement',
          company_cabinet_code: '501',
          status: 'succeeded',
        },
      },
    });
    SchedulingProviderCommandsAPI.retry.mockResolvedValue({
      data: {
        payload: {
          id: 66,
          appointment_id: 501,
          operation: 'create_reception',
          provider: 'medelement',
          company_cabinet_code: '501',
          status: 'succeeded',
        },
      },
    });
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
    expect(html).not.toContain('appointment-status-dashed-rail');
    expect(
      wrapper.find('#scheduling-conversation-appointment-status').exists()
    ).toBe(true);
    expect(
      wrapper
        .find('#scheduling-conversation-appointment-client-first-name')
        .exists()
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
      iconClass: '',
      label: 'SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.completed',
      labelClass: '',
    });
    expect(
      wrapper.vm.statusOptions.find(option => option.value === 'confirmed')
    ).toMatchObject({
      iconClass: 'text-n-teal-11',
      label: 'SCHEDULING.DIALOGS.APPOINTMENT_STATUS_SHORT.confirmed',
      labelClass: 'text-n-teal-11',
    });
    expect(
      wrapper.vm.statusOptions.find(option => option.value === 'scheduled')
    ).toMatchObject({
      iconClass: 'text-n-amber-11',
      labelClass: 'text-n-amber-11',
    });
  });

  it('splits a two-part chat contact name when the surname field is empty', async () => {
    const currentChat = defaultCurrentChat();
    currentChat.meta.sender.name = 'Айжан Касымова';
    const wrapper = mountComponent(currentChat);
    await flushPromises();

    const header = wrapper.findComponent({ name: 'SidebarActionsHeader' });
    await header.vm.$emit('click', 'new_appointment');

    expect(wrapper.vm.createForm).toMatchObject({
      clientFirstName: 'Айжан',
      clientLastName: 'Касымова',
    });
  });

  it('renders appointment status as a colored icon before the title without a dashed status rail', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const html = wrapper.html();
    expect(html).toContain('i-lucide-badge-check');
    expect(html).toContain('text-n-teal-11');
    expect(html).not.toContain('appointment-status-dashed-rail');
    expect(html.indexOf('i-lucide-badge-check')).toBeLessThan(
      html.indexOf('Айша')
    );
    expect(
      wrapper.vm.statusOptions.find(option => option.value === 'completed')
    ).toMatchObject(
      expect.objectContaining({
        iconClass: '',
        labelClass: '',
      })
    );
  });

  it('opens an existing appointment as an edit form immediately', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    expect(
      wrapper
        .find('#scheduling-conversation-appointment-client-first-name-501')
        .exists()
    ).toBe(true);
    expect(wrapper.vm.openAppointmentKeys).toEqual(['appointment-501']);
    expect(wrapper.vm.appointmentForms['appointment-501']).toMatchObject({
      clientFirstName: 'Айша',
      resourceId: 7,
      serviceId: 9,
      status: 'confirmed',
    });
  });

  it('does not promote an unchanged legacy display name to structured identity', async () => {
    const legacyAppointment = {
      ...existingAppointment,
      clientFirstName: null,
      clientLastName: null,
      clientMiddleName: null,
      clientName: 'Касымова Айжан Ерлановна',
    };
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [legacyAppointment] },
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.vm.appointmentForms['appointment-501']).toMatchObject({
      clientFirstName: 'Касымова Айжан Ерлановна',
      clientLastName: '',
      clientMiddleName: '',
      clientNameStructured: false,
    });

    await wrapper.vm.saveAppointment(legacyAppointment);

    const payload = SchedulingAppointmentsAPI.update.mock.calls.at(-1)[1];
    expect(payload.client_name).toBe('Касымова Айжан Ерлановна');
    expect(payload).not.toHaveProperty('client_first_name');
    expect(payload).not.toHaveProperty('client_last_name');
    expect(payload).not.toHaveProperty('client_middle_name');
  });

  it('shows and edits appointment times on the clinic clock', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    // 10:00Z is 15:00 in the clinic, whatever the browser timezone is.
    expect(wrapper.vm.appointmentForms['appointment-501']).toMatchObject({
      endsAt: '2026-06-27T15:30',
      startsAt: '2026-06-27T15:00',
    });
    expect(wrapper.vm.appointmentMeta(existingAppointment)).toContain('15:00');
    expect(wrapper.vm.appointmentMeta(existingAppointment)).toContain('15:30');

    // The 30 minute service moves the end on the clinic clock, across
    // midnight too.
    const form = wrapper.vm.appointmentForms['appointment-501'];
    form.startsAt = '2026-06-27T23:45';
    wrapper.vm.updateFormEndFromDuration(form);
    expect(form.endsAt).toBe('2026-06-28T00:15');

    await wrapper.vm.saveAppointment(existingAppointment);
    const payload = SchedulingAppointmentsAPI.update.mock.calls.at(-1)[1];
    expect(payload).toMatchObject({
      ends_at: '2026-06-27T19:15:00.000Z',
      starts_at: '2026-06-27T18:45:00.000Z',
    });
  });

  it('updates an existing appointment from the inline edit form', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    Object.assign(wrapper.vm.appointmentForms['appointment-501'], {
      clientFirstName: 'Айша updated',
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
      client_first_name: 'Айша updated',
      client_last_name: null,
      client_middle_name: null,
      client_name: 'Айша updated',
      client_phone: 'test-phone-4567',
      contact_id: 42,
      conversation_id: 123,
      ends_at: clinicIso('2026-06-27T11:00'),
      resource_id: 7,
      service_amount: 7000,
      service_id: 9,
      service_ids: [9],
      source: 'conversation',
      starts_at: clinicIso('2026-06-27T10:30'),
      status: 'completed',
    });
    expect(mocks.dispatch).toHaveBeenCalledWith('fetchSidebarUnreadCounts');
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'
    );
  });

  it('hydrates and sends the selected MedElement cabinet when editing a local appointment', async () => {
    mocks.resources[0].customAttributes = {
      medelement_cabinets: [
        { company_cabinet_code: '501', cabinet_name: 'Главный' },
      ],
      medelement_specialist_code: 'specialist-1',
    };
    mocks.services[0].customAttributes = {
      medelement_nomenclature_code: 'service-9',
    };
    mocks.services[0].prices = [{ active: true, price: 5000, resourceId: 7 }];
    const localMedelementAppointment = {
      ...existingAppointment,
      clientLastName: 'Касымова',
      clientPhone: ['+7', '700', '000', '0001'].join(''),
      customAttributes: { medelementCabinetCode: '501' },
      source: 'conversation',
    };
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [localMedelementAppointment] },
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(
      wrapper.vm.appointmentForms['appointment-501'].medelementCabinetCode
    ).toBe('501');
    expect(
      wrapper
        .find('#scheduling-conversation-appointment-medelement-cabinet-501')
        .exists()
    ).toBe(true);

    await wrapper.vm.saveAppointment(localMedelementAppointment);

    expect(SchedulingAppointmentsAPI.update).toHaveBeenCalledWith(
      501,
      expect.objectContaining({
        custom_attributes: { medelement_cabinet_code: '501' },
      })
    );
  });

  it('keeps provider-owned MedElement appointments read-only', async () => {
    const providerAppointment = {
      ...existingAppointment,
      medelementCancellationMode: 'local_only',
      source: 'medelement',
    };
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [providerAppointment] },
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.vm.openAppointmentKeys).toEqual([]);
    expect(wrapper.find('section button').attributes('disabled')).toBeDefined();
    wrapper.vm.toggleAppointment(providerAppointment);
    await wrapper.vm.saveAppointment(providerAppointment);

    expect(wrapper.vm.openAppointmentKeys).toEqual([]);
    expect(SchedulingAppointmentsAPI.update).not.toHaveBeenCalled();

    SchedulingAppointmentsAPI.cancel.mockResolvedValueOnce({
      data: {
        payload: {
          ...providerAppointment,
          provider_confirmation_status: 'pending',
        },
      },
    });

    await wrapper.vm.cancelAppointment(providerAppointment);

    expect(SchedulingAppointmentsAPI.cancel).toHaveBeenCalledWith(501, {
      medelement_cancellation_mode: 'local_only',
    });
    expect(mocks.alert).toHaveBeenCalledWith('SCHEDULING.MEDELEMENT.QUEUED');
    expect(
      wrapper.vm.isProviderCancellationPending(wrapper.vm.appointments[0])
    ).toBe(true);
  });

  it('does not announce completed cancellation while MedElement is still pending', async () => {
    SchedulingAppointmentsAPI.cancel.mockResolvedValueOnce({
      data: {
        payload: {
          ...existingAppointment,
          status: 'cancelled',
          providerConfirmationStatus: 'pending',
        },
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.cancelAppointment(existingAppointment);

    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.CANCELLATION_PENDING'
    );
    expect(mocks.alert).not.toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL'
    );
  });

  it('holds a local confirmed slot while its MedElement removal is pending', async () => {
    SchedulingAppointmentsAPI.cancel.mockResolvedValueOnce({
      data: {
        payload: {
          ...existingAppointment,
          status: 'scheduled',
          customAttributes: { medelement_cancellation_command_id: 42 },
          providerConfirmationStatus: 'pending',
        },
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.cancelAppointment(existingAppointment);

    expect(wrapper.vm.appointments[0].status).toBe('scheduled');
    expect(wrapper.text()).toContain(
      'Awaiting MedElement cancellation confirmation'
    );
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.CANCELLATION_PENDING'
    );
    expect(mocks.alert).not.toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL'
    );
  });

  it('keeps an already cancelled unknown MedElement reception visibly in manual review', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            status: 'cancelled',
            providerConfirmationStatus: 'provider_status_unknown',
          },
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain(
      'MedElement cancellation is not confirmed'
    );
    expect(wrapper.find('.text-n-ruby-11').exists()).toBe(true);
  });

  it('shows a remote candidate for manual resolution without deleting an already cancelled booking', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            status: 'cancelled',
            providerConfirmationStatus: 'provider_status_unknown',
          },
        ],
      },
    });
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: {
        payload: [
          {
            id: 55,
            operation: 'create_reception',
            status: 'provider_status_unknown',
            cancellation_review_candidates: ['created-1'],
          },
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);

    expect(SchedulingProviderCommandsAPI.reconcile).not.toHaveBeenCalled();
    expect(SchedulingAppointmentsAPI.cancel).not.toHaveBeenCalled();
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.CANCELLATION_CANDIDATES'
    );
  });

  it('shows the exact reception and instructions before manual cancellation verification', async () => {
    const wrapper = await openManualReview();

    expect(wrapper.find('[role="status"]').text()).toContain('created-1');
    expect(wrapper.vm.cancellationReviews['appointment-501']).toEqual({
      commandId: 55,
      receptionCode: 'created-1',
    });
    expect(SchedulingProviderCommandsAPI.reconcile).not.toHaveBeenCalled();
    expect(
      SchedulingProviderCommandsAPI.resolveCancellation
    ).not.toHaveBeenCalled();
    expect(SchedulingAppointmentsAPI.cancel).not.toHaveBeenCalled();
    expect(wrapper.vm.appointments[0].status).toBe('confirmed');
  });

  it('updates the appointment and clears review only after verified provider removal', async () => {
    const wrapper = await openManualReview();
    await wrapper.vm.resolveManualCancellation(wrapper.vm.appointments[0]);

    expect(
      SchedulingProviderCommandsAPI.resolveCancellation
    ).toHaveBeenCalledWith(55, {
      provider: 'medelement',
      receptionCode: 'created-1',
    });
    expect(wrapper.vm.appointments[0].status).toBe('cancelled');
    expect(wrapper.vm.cancellationReviews['appointment-501']).toBeUndefined();
    expect(mocks.dispatch).toHaveBeenCalledWith('fetchSidebarUnreadCounts');
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.MANUAL_CANCELLATION_VERIFIED'
    );
    expect(SchedulingAppointmentsAPI.cancel).not.toHaveBeenCalled();
    expect(SchedulingProviderCommandsAPI.reconcile).not.toHaveBeenCalled();
  });

  it('keeps the slot and review when the remote reception is still active', async () => {
    const wrapper = await openManualReview();
    SchedulingProviderCommandsAPI.resolveCancellation.mockRejectedValueOnce({
      response: {
        status: 409,
        data: {
          code: 'MEDELEMENT_CANCELLATION_NOT_VERIFIED',
          error: 'Removal is not verified',
        },
      },
    });

    await wrapper.vm.resolveManualCancellation(wrapper.vm.appointments[0]);

    expect(wrapper.vm.appointments[0].status).toBe('confirmed');
    expect(wrapper.vm.cancellationReviews['appointment-501']).toBeDefined();
    expect(mocks.alert).toHaveBeenCalledWith('Removal is not verified');
    expect(mocks.alert).not.toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.MANUAL_CANCELLATION_VERIFIED'
    );
  });

  it('does not announce cancellation for an incomplete server response', async () => {
    const wrapper = await openManualReview();
    SchedulingProviderCommandsAPI.resolveCancellation.mockResolvedValueOnce({
      data: { payload: { id: 55, status: 'cancelled' } },
    });

    await wrapper.vm.resolveManualCancellation(wrapper.vm.appointments[0]);

    expect(wrapper.vm.appointments[0].status).toBe('confirmed');
    expect(wrapper.vm.cancellationReviews['appointment-501']).toBeDefined();
    expect(mocks.alert).not.toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.MANUAL_CANCELLATION_VERIFIED'
    );
  });

  it('sends one readback for duplicate clicks and blocks a parallel booking check', async () => {
    const wrapper = await openManualReview();
    const request = deferredRequest();
    SchedulingProviderCommandsAPI.resolveCancellation.mockReturnValueOnce(
      request.promise
    );
    const verification = wrapper.vm.resolveManualCancellation(
      wrapper.vm.appointments[0]
    );

    await wrapper.vm.resolveManualCancellation(wrapper.vm.appointments[0]);
    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);
    expect(
      SchedulingProviderCommandsAPI.resolveCancellation
    ).toHaveBeenCalledTimes(1);
    expect(SchedulingProviderCommandsAPI.list).toHaveBeenCalledTimes(1);

    request.resolve(verifiedCancellationResponse());
    await verification;
  });

  it('ignores late verification when switching away and back to the same chat', async () => {
    const wrapper = await openManualReview();
    const request = deferredRequest();
    SchedulingProviderCommandsAPI.resolveCancellation.mockReturnValueOnce(
      request.promise
    );
    const verification = wrapper.vm.resolveManualCancellation(
      wrapper.vm.appointments[0]
    );

    await wrapper.setProps({
      currentChat: { ...defaultCurrentChat(), id: 456 },
    });
    await wrapper.setProps({ currentChat: defaultCurrentChat() });
    await flushPromises();
    request.resolve(verifiedCancellationResponse());
    await verification;

    expect(wrapper.vm.appointments[0].status).toBe('confirmed');
    expect(wrapper.vm.cancellationReviews).toEqual({});
    expect(mocks.alert).not.toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.MANUAL_CANCELLATION_VERIFIED'
    );
    expect(mocks.dispatch).not.toHaveBeenCalled();
  });

  it('discards a command list received after the contact changes in the same chat', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    const request = deferredRequest();
    SchedulingProviderCommandsAPI.list.mockReturnValueOnce(request.promise);
    const checking = wrapper.vm.checkProviderBooking(
      wrapper.vm.appointments[0]
    );

    const currentChat = defaultCurrentChat();
    currentChat.meta.sender.id = 99;
    await wrapper.setProps({ currentChat });
    request.resolve({ data: { payload: [manualReviewCommand] } });
    await checking;

    expect(wrapper.vm.cancellationReviews).toEqual({});
    expect(SchedulingProviderCommandsAPI.reconcile).not.toHaveBeenCalled();
    expect(mocks.alert).not.toHaveBeenCalled();
  });

  it('can check the booking normally without resolving manual cancellation', async () => {
    const wrapper = await openManualReview();
    await wrapper.vm.checkReviewedBooking(wrapper.vm.appointments[0]);

    expect(SchedulingProviderCommandsAPI.reconcile).toHaveBeenCalledWith(55, {
      provider: 'medelement',
    });
    expect(
      SchedulingProviderCommandsAPI.resolveCancellation
    ).not.toHaveBeenCalled();
    expect(wrapper.vm.appointments[0].status).toBe('confirmed');
    expect(wrapper.vm.cancellationReviews['appointment-501']).toBeUndefined();
  });

  it('shows a red review label for a local booking with an unknown MedElement result', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            providerConfirmationStatus: 'provider_status_unknown',
          },
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain('Not confirmed in MedElement');
    expect(wrapper.find('.text-n-ruby-11').exists()).toBe(true);
  });

  it('starts a read-only provider check without cancelling the local appointment', async () => {
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            providerConfirmationStatus: 'provider_status_unknown',
          },
        ],
      },
    });
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: {
        payload: [
          {
            id: 55,
            operation: 'create_reception',
            status: 'provider_status_unknown',
          },
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);

    expect(SchedulingProviderCommandsAPI.list).toHaveBeenCalledWith({
      provider: 'medelement',
      appointmentId: 501,
      activeOnly: true,
    });
    expect(SchedulingProviderCommandsAPI.reconcile).toHaveBeenCalledWith(55, {
      provider: 'medelement',
    });
    expect(SchedulingAppointmentsAPI.cancel).not.toHaveBeenCalled();
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.CHECK_STARTED'
    );
  });

  it('requires an explicit patient choice before resuming a pending booking', async () => {
    configureMedelementResource();
    const candidateCommand = patientActionCommand();
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: { payload: [candidateCommand] },
    });
    SchedulingProviderCommandsAPI.patientCandidates.mockResolvedValue({
      data: {
        payload: {
          candidates: [
            {
              birthday: '1990-01-02',
              iin_masked: '9001******12',
              name: 'Алия',
              phone_masked: '+7 *** *** 1234',
              token: 'candidate-token',
            },
          ],
        },
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);
    wrapper.vm.appointmentForms['appointment-501'].serviceAmount = '7300';

    const action = wrapper.vm.patientActions['appointment-501'];
    expect(wrapper.text()).toContain(
      'SCHEDULING.MEDELEMENT.PATIENT_SELECTION_TITLE'
    );
    expect(action.candidates).toHaveLength(1);
    expect(action.selectedPatientToken).toBe('');
    expect(wrapper.vm.canContinuePatientAction(action)).toBe(false);
    expect(SchedulingProviderCommandsAPI.selectPatient).not.toHaveBeenCalled();
    expect(SchedulingProviderCommandsAPI.reconcile).not.toHaveBeenCalled();

    wrapper.vm.selectPatientCandidate(
      wrapper.vm.appointments[0],
      'candidate-token'
    );
    expect(wrapper.vm.canContinuePatientAction(action)).toBe(true);
    await wrapper.vm.continuePatientAction(wrapper.vm.appointments[0]);

    expect(SchedulingProviderCommandsAPI.selectPatient).toHaveBeenCalledWith(
      66,
      { provider: 'medelement', token: 'candidate-token' }
    );
    expect(wrapper.text()).toContain('SCHEDULING.MEDELEMENT.SUCCESS');
    expect(SchedulingAppointmentsAPI.show).toHaveBeenCalledWith(501);
    expect(wrapper.vm.appointments[0].providerConfirmationStatus).toBe(
      'succeeded'
    );
    expect(wrapper.vm.appointments[0].externalRef).toBe(
      'medelement:reception:reception-501'
    );
    expect(wrapper.vm.appointmentForms['appointment-501'].serviceAmount).toBe(
      '7300'
    );
  });

  it('rechecks a reopened pending appointment until its queued command needs a patient choice', async () => {
    configureMedelementResource();
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            customAttributes: { medelementCabinetCode: '501' },
            providerConfirmationStatus: 'pending',
            source: 'conversation',
          },
        ],
      },
    });
    SchedulingProviderCommandsAPI.list
      .mockResolvedValueOnce({
        data: {
          payload: [
            {
              ...patientActionCommand(),
              status: 'queued',
            },
          ],
        },
      })
      .mockResolvedValueOnce({
        data: { payload: [patientActionCommand()] },
      });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain('SCHEDULING.MEDELEMENT.RECONCILING');
    expect(SchedulingProviderCommandsAPI.list).toHaveBeenCalledTimes(1);
    expect(SchedulingProviderCommandsAPI.confirm).not.toHaveBeenCalled();
    expect(SchedulingProviderCommandsAPI.reconcile).not.toHaveBeenCalled();

    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);

    expect(wrapper.text()).toContain(
      'SCHEDULING.MEDELEMENT.PATIENT_SELECTION_TITLE'
    );
    expect(SchedulingProviderCommandsAPI.list).toHaveBeenCalledTimes(2);
    expect(SchedulingProviderCommandsAPI.selectPatient).not.toHaveBeenCalled();
  });

  it('keeps a newer patient-action lookup when an older queued lookup returns late', async () => {
    configureMedelementResource();
    const wrapper = mountComponent();
    await flushPromises();
    const appointment = wrapper.vm.appointments[0];
    appointment.providerConfirmationStatus = 'pending';
    const olderRequest = deferredRequest();
    const newerRequest = deferredRequest();
    SchedulingProviderCommandsAPI.list
      .mockReturnValueOnce(olderRequest.promise)
      .mockReturnValueOnce(newerRequest.promise);

    const olderLookup = wrapper.vm.refreshPendingPatientAction(appointment);
    const newerLookup = wrapper.vm.refreshPendingPatientAction(appointment);
    newerRequest.resolve({
      data: { payload: [patientActionCommand()] },
    });
    await newerLookup;
    olderRequest.resolve({
      data: {
        payload: [
          {
            ...patientActionCommand(),
            status: 'queued',
          },
        ],
      },
    });
    await olderLookup;

    expect(wrapper.vm.patientActions['appointment-501'].command.status).toBe(
      'awaiting_patient_selection'
    );
  });

  it('refreshes a cached pending status when no active command remains', async () => {
    configureMedelementResource();
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            providerConfirmationStatus: 'pending',
            source: 'conversation',
          },
        ],
      },
    });
    SchedulingAppointmentsAPI.show.mockResolvedValueOnce({
      data: {
        payload: {
          ...existingAppointment,
          provider_confirmation_status: 'pending',
        },
      },
    });
    const wrapper = mountComponent();
    await flushPromises();
    expect(
      wrapper.find('[data-testid="provider-patient-action-501"]').exists()
    ).toBe(true);

    SchedulingAppointmentsAPI.show.mockResolvedValueOnce({
      data: {
        payload: {
          ...existingAppointment,
          custom_attributes: {
            medelement_provider_sync_status: 'succeeded',
            medelement_reception_code: 'readback-reception',
          },
          external_ref: 'medelement:reception:readback-reception',
          provider_confirmation_status: 'succeeded',
        },
      },
    });
    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);

    expect(wrapper.vm.appointments[0].providerConfirmationStatus).toBe(
      'succeeded'
    );
    expect(wrapper.vm.appointments[0].externalRef).toBe(
      'medelement:reception:readback-reception'
    );
    expect(
      wrapper.find('[data-testid="provider-patient-action-501"]').exists()
    ).toBe(false);
    expect(SchedulingProviderCommandsAPI.reconcile).not.toHaveBeenCalled();
    expect(SchedulingProviderCommandsAPI.confirm).not.toHaveBeenCalled();
  });

  it('ignores an older pending readback after a newer success readback', async () => {
    configureMedelementResource();
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: {
        payload: [
          {
            ...existingAppointment,
            providerConfirmationStatus: 'pending',
            source: 'conversation',
          },
        ],
      },
    });
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: { payload: [] },
    });
    const olderReadback = deferredRequest();
    const newerReadback = deferredRequest();
    SchedulingAppointmentsAPI.show
      .mockReturnValueOnce(olderReadback.promise)
      .mockReturnValueOnce(newerReadback.promise);
    const wrapper = mountComponent();
    await flushPromises();
    expect(SchedulingAppointmentsAPI.show).toHaveBeenCalledTimes(1);

    const checking = wrapper.vm.checkProviderBooking(
      wrapper.vm.appointments[0]
    );
    await flushPromises();
    expect(SchedulingAppointmentsAPI.show).toHaveBeenCalledTimes(2);
    newerReadback.resolve({
      data: {
        payload: {
          ...existingAppointment,
          provider_confirmation_status: 'succeeded',
          external_ref: 'medelement:reception:newest',
        },
      },
    });
    await checking;
    olderReadback.resolve({
      data: {
        payload: {
          ...existingAppointment,
          provider_confirmation_status: 'pending',
        },
      },
    });
    await flushPromises();

    expect(wrapper.vm.appointments[0].providerConfirmationStatus).toBe(
      'succeeded'
    );
    expect(wrapper.vm.appointments[0].externalRef).toBe(
      'medelement:reception:newest'
    );
    expect(
      wrapper.find('[data-testid="provider-patient-action-501"]').exists()
    ).toBe(false);
  });

  it('handles an active reconciliation command before cached pending status', async () => {
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: {
        payload: [
          {
            ...manualReviewCommand,
            manual_cancellation_available: false,
            status: 'reconciliation_required',
          },
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();
    const appointment = {
      ...wrapper.vm.appointments[0],
      providerConfirmationStatus: 'pending',
    };
    wrapper.vm.appointments[0].providerConfirmationStatus = 'pending';

    await wrapper.vm.checkProviderBooking(appointment);

    expect(SchedulingProviderCommandsAPI.reconcile).toHaveBeenCalledWith(55, {
      provider: 'medelement',
    });
    expect(SchedulingAppointmentsAPI.show).not.toHaveBeenCalled();
  });

  it('blocks a patient continuation when the appointment form has a changed provider intent', async () => {
    configureMedelementResource();
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: { payload: [patientActionCommand()] },
    });
    SchedulingProviderCommandsAPI.patientCandidates.mockResolvedValue({
      data: { payload: { candidates: [{ token: 'candidate-token' }] } },
    });
    const wrapper = mountComponent();
    await flushPromises();
    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);
    const action = wrapper.vm.patientActions['appointment-501'];
    action.selectedPatientToken = 'candidate-token';
    expect(wrapper.vm.canContinuePatientAction(action)).toBe(true);
    wrapper.vm.appointmentForms['appointment-501'].clientPhone = '+77000000002';

    expect(wrapper.vm.canContinuePatientAction(action)).toBe(false);
    expect(wrapper.vm.patientActionDescription(action)).toBe(
      'SCHEDULING.MEDELEMENT.STALE_COMMAND_DESCRIPTION'
    );
    await wrapper.vm.continuePatientAction(wrapper.vm.appointments[0]);
    expect(SchedulingProviderCommandsAPI.selectPatient).not.toHaveBeenCalled();
  });

  it('prevents saving or cancelling while an explicit provider action is running', async () => {
    configureMedelementResource();
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: { payload: [patientActionCommand()] },
    });
    SchedulingProviderCommandsAPI.patientCandidates.mockResolvedValue({
      data: { payload: { candidates: [{ token: 'candidate-token' }] } },
    });
    const wrapper = mountComponent();
    await flushPromises();
    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);
    const action = wrapper.vm.patientActions['appointment-501'];
    action.selectedPatientToken = 'candidate-token';
    const request = deferredRequest();
    SchedulingProviderCommandsAPI.selectPatient.mockReturnValueOnce(
      request.promise
    );

    const continuation = wrapper.vm.continuePatientAction(
      wrapper.vm.appointments[0]
    );
    await wrapper.vm.saveAppointment(wrapper.vm.appointments[0]);
    await wrapper.vm.cancelAppointment(wrapper.vm.appointments[0]);

    expect(SchedulingProviderCommandsAPI.selectPatient).toHaveBeenCalledTimes(
      1
    );
    expect(SchedulingAppointmentsAPI.update).not.toHaveBeenCalled();
    expect(SchedulingAppointmentsAPI.cancel).not.toHaveBeenCalled();

    request.resolve({
      data: {
        payload: {
          ...patientActionCommand(),
          status: 'succeeded',
        },
      },
    });
    await continuation;
  });

  it('uses provider review labels for unknown commands and real error codes for failures', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    const appointment = wrapper.vm.appointments[0];

    expect(
      wrapper.vm.patientActionTitle({
        appointment,
        command: { status: 'provider_status_unknown' },
      })
    ).toBe('SCHEDULING.APPOINTMENT_STATUS.PROVIDER_REVIEW');
    expect(
      wrapper.vm.patientActionTitle({
        appointment: { ...appointment, status: 'cancelled' },
        command: { status: 'cancelled' },
      })
    ).toBe('SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_REVIEW');
    wrapper.vm.patientActionTitle({
      appointment,
      command: {
        lastErrorCode: 'provider_state_changed',
        status: 'failed',
      },
    });
    expect(mocks.t).toHaveBeenCalledWith('SCHEDULING.MEDELEMENT.FAILED', {
      code: 'provider_state_changed',
    });
  });

  it('blocks continuation when the active command no longer matches the appointment', async () => {
    configureMedelementResource();
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: {
        payload: [
          patientActionCommand('awaiting_patient_selection', {
            company_cabinet_code: 'another-cabinet',
          }),
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);

    const action = wrapper.vm.patientActions['appointment-501'];
    expect(action.intentMismatch).toBe(true);
    expect(wrapper.text()).toContain(
      'SCHEDULING.MEDELEMENT.STALE_COMMAND_DESCRIPTION'
    );
    expect(
      SchedulingProviderCommandsAPI.patientCandidates
    ).not.toHaveBeenCalled();
    await wrapper.vm.continuePatientAction(wrapper.vm.appointments[0]);
    expect(SchedulingProviderCommandsAPI.selectPatient).not.toHaveBeenCalled();
  });

  it('shows pending patient action after saving a local MedElement appointment', async () => {
    configureMedelementResource();
    mocks.services[0].customAttributes = {
      medelement_nomenclature_code: 'service-9',
    };
    mocks.services[0].prices = [{ active: true, price: 5000, resourceId: 7 }];
    const localAppointment = {
      ...existingAppointment,
      clientName: 'Айша Касымова',
      clientLastName: 'Касымова',
      clientPhone: '+77000000001',
      customAttributes: { medelementCabinetCode: '501' },
      source: 'conversation',
    };
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [localAppointment] },
    });
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: {
        payload: [
          patientActionCommand('awaiting_patient_creation', {
            patient_action: { can_confirm: true, missing_fields: [] },
          }),
        ],
      },
    });
    SchedulingAppointmentsAPI.update.mockResolvedValueOnce({
      data: { payload: localAppointment },
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.saveAppointment(localAppointment);
    await flushPromises();

    expect(SchedulingAppointmentsAPI.update).toHaveBeenCalledWith(
      localAppointment.id,
      expect.any(Object)
    );
    expect(SchedulingProviderCommandsAPI.list).toHaveBeenCalledWith({
      activeOnly: true,
      appointmentId: localAppointment.id,
      provider: 'medelement',
    });
    expect(wrapper.text()).toContain(
      'SCHEDULING.MEDELEMENT.PATIENT_CREATION_TITLE'
    );
    expect(wrapper.vm.patientActions['appointment-501'].command.status).toBe(
      'awaiting_patient_creation'
    );
    expect(
      SchedulingProviderCommandsAPI.confirmPatientCreation
    ).not.toHaveBeenCalled();
  });

  it('requires the provider confirmation flag before creating a patient', async () => {
    configureMedelementResource();
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: {
        payload: [
          patientActionCommand('awaiting_patient_creation', {
            patient_action: { can_confirm: false, missing_fields: [] },
          }),
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);

    const action = wrapper.vm.patientActions['appointment-501'];
    expect(wrapper.vm.canContinuePatientAction(action)).toBe(false);
    await wrapper.vm.continuePatientAction(wrapper.vm.appointments[0]);
    expect(
      SchedulingProviderCommandsAPI.confirmPatientCreation
    ).not.toHaveBeenCalled();

    action.command.patientAction.canConfirm = true;
    await wrapper.vm.continuePatientAction(wrapper.vm.appointments[0]);
    expect(
      SchedulingProviderCommandsAPI.confirmPatientCreation
    ).toHaveBeenCalledWith(66, { provider: 'medelement' });
  });

  it('waits for an explicit click before retrying a phone mismatch', async () => {
    configureMedelementResource();
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: { payload: [patientActionCommand('awaiting_phone_refresh')] },
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.checkProviderBooking(wrapper.vm.appointments[0]);
    expect(SchedulingProviderCommandsAPI.retry).not.toHaveBeenCalled();

    await wrapper.vm.continuePatientAction(wrapper.vm.appointments[0]);
    expect(SchedulingProviderCommandsAPI.retry).toHaveBeenCalledWith(66, {
      provider: 'medelement',
    });
  });

  it('does not show a patient action response after the chat changes', async () => {
    configureMedelementResource();
    const request = deferredRequest();
    SchedulingProviderCommandsAPI.list.mockReturnValueOnce(request.promise);
    const wrapper = mountComponent();
    await flushPromises();
    const checking = wrapper.vm.checkProviderBooking(
      wrapper.vm.appointments[0]
    );

    await wrapper.setProps({
      currentChat: { id: 999, meta: { sender: { id: 77 } } },
    });
    request.resolve({
      data: { payload: [patientActionCommand()] },
    });
    await checking;
    await flushPromises();

    expect(
      wrapper.find('[data-testid="provider-patient-action-501"]').exists()
    ).toBe(false);
    expect(
      SchedulingProviderCommandsAPI.patientCandidates
    ).not.toHaveBeenCalled();
  });

  it('does not show a patient action response after the account changes', async () => {
    configureMedelementResource();
    const request = deferredRequest();
    SchedulingProviderCommandsAPI.list.mockReturnValueOnce(request.promise);
    const wrapper = mountComponent();
    await flushPromises();
    const checking = wrapper.vm.checkProviderBooking(
      wrapper.vm.appointments[0]
    );

    mocks.route.params.accountId = '2';
    await flushPromises();
    request.resolve({
      data: { payload: [patientActionCommand()] },
    });
    await checking;

    expect(
      wrapper.find('[data-testid="provider-patient-action-501"]').exists()
    ).toBe(false);
    expect(
      SchedulingProviderCommandsAPI.patientCandidates
    ).not.toHaveBeenCalled();
  });

  it('discards a patient action lookup when the appointment snapshot changes', async () => {
    configureMedelementResource();
    const request = deferredRequest();
    SchedulingProviderCommandsAPI.list.mockReturnValueOnce(request.promise);
    const wrapper = mountComponent();
    await flushPromises();
    const checking = wrapper.vm.checkProviderBooking(
      wrapper.vm.appointments[0]
    );

    wrapper.vm.upsertAppointment({
      ...wrapper.vm.appointments[0],
      startsAt: '2026-06-27T11:00:00.000Z',
    });
    request.resolve({
      data: { payload: [patientActionCommand()] },
    });
    await checking;

    expect(
      wrapper.find('[data-testid="provider-patient-action-501"]').exists()
    ).toBe(false);
    expect(
      SchedulingProviderCommandsAPI.patientCandidates
    ).not.toHaveBeenCalled();
  });

  it('invalidates a delayed candidate response when a snake-case cabinet changes', async () => {
    configureMedelementResource();
    SchedulingProviderCommandsAPI.list.mockResolvedValue({
      data: { payload: [patientActionCommand()] },
    });
    const candidatesRequest = deferredRequest();
    SchedulingProviderCommandsAPI.patientCandidates.mockReturnValueOnce(
      candidatesRequest.promise
    );
    const wrapper = mountComponent();
    await flushPromises();
    const checking = wrapper.vm.checkProviderBooking(
      wrapper.vm.appointments[0]
    );
    await flushPromises();
    expect(wrapper.vm.patientActions['appointment-501']).toBeDefined();

    wrapper.vm.upsertAppointment({
      ...wrapper.vm.appointments[0],
      customAttributes: { medelement_cabinet_code: 'different-cabinet' },
    });
    candidatesRequest.resolve({
      data: { payload: { candidates: [{ token: 'late-candidate' }] } },
    });
    await checking;

    expect(wrapper.vm.patientActions['appointment-501']).toBeUndefined();
    expect(SchedulingProviderCommandsAPI.selectPatient).not.toHaveBeenCalled();
  });

  it('does not apply a save response after the conversation changes', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    const request = deferredRequest();
    SchedulingAppointmentsAPI.update.mockReturnValueOnce(request.promise);
    const saving = wrapper.vm.saveAppointment(wrapper.vm.appointments[0]);

    await wrapper.setProps({
      currentChat: { id: 456, meta: { sender: { id: 99, name: 'Other' } } },
    });
    await flushPromises();
    request.resolve({
      data: { payload: { ...existingAppointment, id: 777 } },
    });
    await saving;

    expect(wrapper.vm.appointments.map(item => item.id)).not.toContain(777);
    expect(mocks.alert).not.toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'
    );
  });

  it('does not apply a create response after the conversation changes', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    await wrapper.vm.startCreateAppointment({ scroll: false });
    Object.assign(wrapper.vm.createForm, {
      clientFirstName: 'Айша',
      clientLastName: 'Касымова',
      clientPhone: 'test-phone-4567',
      endsAt: '2026-06-27T10:30',
      resourceId: 7,
      serviceAmount: '5000',
      serviceId: 9,
      startsAt: '2026-06-27T10:00',
    });
    const request = deferredRequest();
    SchedulingAppointmentsAPI.create.mockReturnValueOnce(request.promise);
    const creating = wrapper.vm.saveCreateAppointment();

    await wrapper.setProps({
      currentChat: { id: 456, meta: { sender: { id: 99, name: 'Other' } } },
    });
    await flushPromises();
    request.resolve({
      data: { payload: { ...existingAppointment, id: 777 } },
    });
    await creating;

    expect(wrapper.vm.appointments.map(item => item.id)).not.toContain(777);
    expect(mocks.alert).not.toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'
    );
  });

  it('asks for manual review when an unknown booking has no reconcilable command', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.vm.checkProviderBooking(existingAppointment);

    expect(SchedulingProviderCommandsAPI.reconcile).not.toHaveBeenCalled();
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.CHECK_NOT_AVAILABLE'
    );
  });

  it('uses the cancellation endpoint instead of updating the record status', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    wrapper.vm.appointmentForms['appointment-501'].status = 'cancelled';

    await wrapper.vm.saveAppointment(existingAppointment);

    expect(SchedulingAppointmentsAPI.cancel).toHaveBeenCalledWith(501);
    expect(SchedulingAppointmentsAPI.update).not.toHaveBeenCalled();
  });

  it('uses the cabinet code as the edit option label when provider names are absent', async () => {
    mocks.resources.splice(0, mocks.resources.length, {
      id: 9,
      active: true,
      name: 'Doctor',
      customAttributes: {
        medelement_specialist_code: 'specialist-1',
        medelement_cabinets: [
          {
            company_cabinet_code: 'cabinet-1',
          },
        ],
      },
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(
      wrapper.vm.medelementCabinetOptionsForForm({ resourceId: 9 })
    ).toEqual([{ label: 'cabinet-1', value: 'cabinet-1' }]);
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
      clientFirstName: 'Айша updated',
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
      clientFirstName: 'Айша',
      clientLastName: 'Касымова',
      clientMiddleName: 'Ерлановна',
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
      client_first_name: 'Айша',
      client_last_name: 'Касымова',
      client_middle_name: 'Ерлановна',
      client_name: 'Айша Касымова Ерлановна',
      client_phone: 'test-phone-4567',
      contact_id: 42,
      conversation_display_id: 123,
      ends_at: clinicIso('2026-06-27T10:30'),
      resource_id: 7,
      service_amount: 5000,
      service_id: 9,
      service_ids: [9],
      source: 'conversation',
      starts_at: clinicIso('2026-06-27T10:00'),
      status: 'completed',
    });
    expect(mocks.dispatch).toHaveBeenCalledWith('fetchSidebarUnreadCounts');
    expect(mocks.alert).toHaveBeenCalledWith(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_SAVE'
    );
  });

  it('requires MedElement patient identity but allows an appointment without a service', async () => {
    mocks.resources[0].customAttributes = {
      medelement_cabinets: [
        { company_cabinet_code: 'cabinet-1', cabinet_name: 'Кабинет 1' },
      ],
      medelement_specialist_code: 'specialist-1',
    };
    mocks.services[0].customAttributes = {
      medelement_nomenclature_code: 'service-9',
    };
    mocks.services[0].prices = [{ active: true, price: 5000, resourceId: 7 }];
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper
      .findComponent({ name: 'SidebarActionsHeader' })
      .vm.$emit('click', 'new_appointment');

    expect(wrapper.vm.isCreateFormInvalid).toBe(true);
    await wrapper.vm.saveCreateAppointment();
    expect(SchedulingAppointmentsAPI.create).not.toHaveBeenCalled();

    Object.assign(wrapper.vm.createForm, {
      clientLastName: 'Касымова',
      clientPhone: ['+7', '700', '000', '0001'].join(''),
    });

    expect(wrapper.vm.createForm.medelementCabinetCode).toBe('cabinet-1');
    expect(wrapper.vm.isCreateFormInvalid).toBe(false);
  });

  it('requires a cabinet for a MedElement specialist and sends the selected cabinet', async () => {
    mocks.resources[0].customAttributes = {
      medelement_cabinets: [
        { company_cabinet_code: '501', cabinet_name: 'Главный' },
        {
          company_cabinet_code: '502',
          cabinet_name: 'Диагностика',
          cabinet_number: '2',
        },
      ],
      medelement_specialist_code: 'specialist-1',
    };
    const wrapper = mountComponent();
    await flushPromises();
    await wrapper
      .findComponent({ name: 'SidebarActionsHeader' })
      .vm.$emit('click', 'new_appointment');

    expect(
      wrapper
        .find('#scheduling-conversation-appointment-medelement-cabinet')
        .exists()
    ).toBe(true);
    expect(wrapper.vm.medelementCabinetOptions).toEqual([
      { label: 'Главный', value: '501' },
      { label: 'Диагностика · 2', value: '502' },
    ]);

    Object.assign(wrapper.vm.createForm, {
      clientLastName: 'Касымова',
      clientPhone: ['+7', '700', '000', '0001'].join(''),
    });
    expect(wrapper.vm.isCreateFormInvalid).toBe(true);

    wrapper.vm.createForm.medelementCabinetCode = '502';
    await wrapper.vm.saveCreateAppointment();

    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({
        custom_attributes: { medelement_cabinet_code: '502' },
      })
    );
  });

  it('uses explicit service links for the selected MedElement specialist', async () => {
    mocks.resources[0].customAttributes = {
      medelement_specialist_code: 'specialist-1',
    };
    mocks.services.splice(
      0,
      mocks.services.length,
      {
        active: true,
        customAttributes: { medelement_nomenclature_code: 'service-9' },
        id: 9,
        name: 'Консультация',
        prices: [{ active: true, price: 5000, resourceId: 7 }],
      },
      {
        active: true,
        customAttributes: { medelement_nomenclature_code: 'service-10' },
        id: 10,
        name: 'Другая услуга',
        prices: [{ active: true, price: 7000, resourceId: 8 }],
      },
      {
        active: true,
        customAttributes: { medelement_nomenclature_code: 'service-11' },
        id: 11,
        name: 'Услуга без персональной цены',
        prices: [],
      },
      {
        active: true,
        customAttributes: {},
        id: 12,
        name: 'Локальная услуга',
        prices: [],
      }
    );
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.vm.serviceOptionsForForm({ resourceId: 7 })).toEqual([
      { label: 'Консультация', value: 9, wrapLabel: true },
    ]);
  });

  it('shows the full mapped catalog when the MedElement specialist has no links', async () => {
    mocks.resources[0].customAttributes = {
      medelement_specialist_code: 'specialist-1',
    };
    mocks.services.splice(
      0,
      mocks.services.length,
      {
        active: true,
        customAttributes: { medelement_nomenclature_code: 'service-9' },
        id: 9,
        name: 'Консультация',
        prices: [],
      },
      {
        active: true,
        customAttributes: { medelement_nomenclature_code: 'service-10' },
        id: 10,
        name: 'Другая услуга',
        prices: [{ active: true, price: 7000, resourceId: 8 }],
      },
      {
        active: true,
        customAttributes: {},
        id: 11,
        name: 'Локальная услуга',
        prices: [],
      }
    );
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.vm.serviceOptionsForForm({ resourceId: 7 })).toEqual([
      { label: 'Консультация', value: 9, wrapLabel: true },
      { label: 'Другая услуга', value: 10, wrapLabel: true },
    ]);
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
      clientFirstName: 'Айша',
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
      client_first_name: 'Айша',
      client_last_name: null,
      client_middle_name: null,
      client_name: 'Айша',
      client_phone: 'test-phone-4567',
      contact_id: 42,
      conversation_display_id: 123,
      ends_at: clinicIso('2026-06-27T10:30'),
      resource_id: 7,
      service_amount: 3000,
      service_ids: [],
      service_name_snapshot: 'Осмотр',
      source: 'conversation',
      starts_at: clinicIso('2026-06-27T10:00'),
      status: 'scheduled',
    });
  });
  it('prefills a MedElement IIN, validates its length and sends it with the appointment', async () => {
    mocks.resources[0].customAttributes = {
      medelement_cabinets: [{ company_cabinet_code: '501' }],
      medelement_specialist_code: 'specialist-1',
    };
    const currentChat = defaultCurrentChat();
    currentChat.meta.sender.identifier = '940720300129';
    const wrapper = mountComponent(currentChat);
    await flushPromises();
    await wrapper
      .findComponent({ name: 'SidebarActionsHeader' })
      .vm.$emit('click', 'new_appointment');

    const iinField = wrapper.findComponent(
      '#scheduling-conversation-appointment-client-iin'
    );
    expect(iinField.exists()).toBe(true);
    expect(wrapper.vm.createForm.clientIdentifier).toBe('940720300129');

    Object.assign(wrapper.vm.createForm, {
      clientLastName: 'Хамзаулы',
      clientPhone: ['+7', '700', '000', '0001'].join(''),
      endsAt: '2026-06-27T10:30',
      startsAt: '2026-06-27T10:00',
    });
    await iinField.vm.$emit('update:modelValue', '123');
    expect(wrapper.vm.isCreateFormInvalid).toBe(true);
    await wrapper.vm.saveCreateAppointment();
    expect(SchedulingAppointmentsAPI.create).not.toHaveBeenCalled();

    await iinField.vm.$emit('update:modelValue', '940720300128');
    expect(wrapper.vm.isCreateFormInvalid).toBe(true);
    await wrapper.vm.saveCreateAppointment();
    expect(SchedulingAppointmentsAPI.create).not.toHaveBeenCalled();

    await iinField.vm.$emit('update:modelValue', '940720300129');
    expect(wrapper.vm.isCreateFormInvalid).toBe(false);
    SchedulingAppointmentsAPI.create.mockImplementationOnce(payload =>
      Promise.resolve({
        data: {
          payload: {
            ...existingAppointment,
            id: 778,
            clientIdentifier: payload.client_identifier,
          },
        },
      })
    );
    await wrapper.vm.saveCreateAppointment();
    expect(SchedulingAppointmentsAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({ client_identifier: '940720300129' })
    );
    expect(
      wrapper.vm.appointmentForms['appointment-778'].clientIdentifier
    ).toBe('940720300129');
  });

  it('shows and saves an IIN when editing a local MedElement appointment', async () => {
    mocks.resources[0].customAttributes = {
      medelement_cabinets: [{ company_cabinet_code: '501' }],
      medelement_specialist_code: 'specialist-1',
    };
    mocks.services[0].customAttributes = {
      medelement_nomenclature_code: 'service-9',
    };
    mocks.services[0].prices = [{ active: true, price: 5000, resourceId: 7 }];
    const appointment = {
      ...existingAppointment,
      clientFirstName: 'Асет',
      clientIdentifier: '940720300129',
      clientLastName: 'Хамзаулы',
      clientPhone: ['+7', '700', '000', '0001'].join(''),
      customAttributes: { medelementCabinetCode: '501' },
    };
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [appointment] },
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(
      wrapper
        .find('#scheduling-conversation-appointment-client-iin-501')
        .exists()
    ).toBe(true);
    expect(
      wrapper.vm.appointmentForms['appointment-501'].clientIdentifier
    ).toBe('940720300129');
    await wrapper.vm.saveAppointment(appointment);
    expect(SchedulingAppointmentsAPI.update).toHaveBeenCalledWith(
      501,
      expect.objectContaining({
        client_first_name: 'Асет',
        client_identifier: '940720300129',
        client_last_name: 'Хамзаулы',
      })
    );
  });

  it('leaves a linked MedElement patient bookable without a locally known IIN', async () => {
    mocks.resources[0].customAttributes = {
      medelement_cabinets: [{ company_cabinet_code: '501' }],
      medelement_specialist_code: 'specialist-1',
    };
    const currentChat = defaultCurrentChat();
    currentChat.meta.sender.custom_attributes = {
      medelement_patient_code: 'patient-1',
    };
    const wrapper = mountComponent(currentChat);
    await flushPromises();
    await wrapper
      .findComponent({ name: 'SidebarActionsHeader' })
      .vm.$emit('click', 'new_appointment');
    Object.assign(wrapper.vm.createForm, {
      clientLastName: 'Хамзаулы',
      clientPhone: ['+7', '700', '000', '0001'].join(''),
      endsAt: '2026-06-27T10:30',
      startsAt: '2026-06-27T10:00',
    });

    expect(wrapper.vm.isCreateFormInvalid).toBe(false);
    await wrapper.vm.saveCreateAppointment();
    expect(
      SchedulingAppointmentsAPI.create.mock.calls.at(-1)[0]
    ).toHaveProperty('client_identifier', null);
  });

  it('does not prefill another contact appointment with the current chat IIN', async () => {
    const currentChat = defaultCurrentChat();
    currentChat.meta.sender.identifier = '940720300129';
    const appointment = {
      ...existingAppointment,
      clientIdentifier: null,
      contactId: 999,
    };
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [appointment] },
    });

    const wrapper = mountComponent(currentChat);
    await flushPromises();
    expect(
      wrapper.vm.appointmentForms['appointment-501'].clientIdentifier
    ).toBe('');
  });

  it('ignores a stale appointment load after switching chats', async () => {
    const pending = [];
    const otherAppointment = {
      ...existingAppointment,
      id: 902,
      contactId: 77,
      conversationId: 999,
      clientName: 'Другой клиент',
    };
    SchedulingAppointmentsAPI.get.mockImplementation(params => {
      if (
        params.contact_ids === 42 ||
        params.conversation_display_ids === '123'
      ) {
        return new Promise(resolve => {
          pending.push(resolve);
        });
      }
      return Promise.resolve({ data: { payload: [otherAppointment] } });
    });

    const wrapper = mountComponent();
    await flushPromises();
    expect(pending).toHaveLength(2);

    await wrapper.setProps({
      currentChat: {
        id: 999,
        meta: { sender: { id: 77, name: 'Другой клиент' } },
      },
    });
    await flushPromises();
    expect(wrapper.vm.appointments.map(appointment => appointment.id)).toEqual([
      902,
    ]);

    pending.forEach(resolve =>
      resolve({
        data: {
          payload: [
            {
              ...existingAppointment,
              patientContactId: 84,
              patientContactName: 'Stale relative',
            },
          ],
        },
      })
    );
    await flushPromises();
    expect(wrapper.vm.appointments.map(appointment => appointment.id)).toEqual([
      902,
    ]);
    expect(
      wrapper.find('[data-testid="appointment-patient-card"]').exists()
    ).toBe(false);
    wrapper.unmount();
  });

  const prepareIinAppointment = async (appointment = {}, sender = {}) => {
    mocks.resources[0].customAttributes = {
      medelement_cabinets: [{ company_cabinet_code: '501' }],
      medelement_specialist_code: 'specialist-1',
    };
    mocks.services[0].customAttributes = {
      medelement_nomenclature_code: 'service-9',
    };
    mocks.services[0].prices = [{ active: true, price: 5000, resourceId: 7 }];
    const chat = defaultCurrentChat();
    Object.assign(chat.meta.sender, sender);
    SchedulingAppointmentsAPI.get.mockResolvedValue({
      data: { payload: [{ ...existingAppointment, ...appointment }] },
    });
    const wrapper = mountComponent(chat);
    await flushPromises();
    return wrapper;
  };

  it('clears an inferred contact IIN when entering another patient name', async () => {
    const wrapper = await prepareIinAppointment(
      {},
      { identifier: '940720300129' }
    );
    await wrapper.vm.startCreateAppointment({ scroll: false });
    expect(wrapper.vm.createForm.clientIdentifier).toBe('940720300129');
    wrapper.vm.updatePatientNamePart(
      wrapper.vm.createForm,
      'clientFirstName',
      'Другой'
    );
    expect(wrapper.vm.createForm.clientIdentifier).toBe('');
    expect(wrapper.vm.buildCreatePayload()).toHaveProperty(
      'client_identifier',
      null
    );
  });

  it('preserves an explicitly entered IIN while correcting patient name', async () => {
    const wrapper = await prepareIinAppointment(
      {},
      { identifier: '940720300129' }
    );
    await wrapper.vm.startCreateAppointment({ scroll: false });
    wrapper.vm.updatePatientIin(wrapper.vm.createForm, '940720300129');
    wrapper.vm.updatePatientNamePart(
      wrapper.vm.createForm,
      'clientLastName',
      'Исправленная'
    );
    expect(wrapper.vm.createForm.clientIdentifier).toBe('940720300129');
  });

  it('does not infer an editing patient IIN from the same contact or shared phone', async () => {
    const wrapper = await prepareIinAppointment(
      {
        clientFirstName: 'Родственник',
        clientIdentifier: null,
        clientLastName: 'Пациент',
      },
      { identifier: '940720300129' }
    );
    expect(
      wrapper.vm.appointmentForms['appointment-501'].clientIdentifier
    ).toBe('');
  });

  it('sends explicit null when clearing a stored appointment IIN', async () => {
    const wrapper = await prepareIinAppointment({
      clientIdentifier: '940720300129',
      clientLastName: 'Пациент',
      clientPhone: ['+7', '700', '000', '0001'].join(''),
      customAttributes: { medelementCabinetCode: '501' },
    });
    const field = wrapper.findComponent(
      '#scheduling-conversation-appointment-client-iin-501'
    );
    await field.vm.$emit('update:modelValue', '');
    await wrapper.vm.saveAppointment(wrapper.vm.appointments[0]);
    expect(
      SchedulingAppointmentsAPI.update.mock.calls.at(-1)[1]
    ).toHaveProperty('client_identifier', null);
  });

  it('shows an invalid stored identifier for correction without silently erasing it', async () => {
    const wrapper = await prepareIinAppointment({
      clientIdentifier: 'invalid-id',
    });
    const form = wrapper.vm.appointmentForms['appointment-501'];
    expect(form.clientIdentifier).toBe('invalid-id');
    expect(wrapper.vm.medelementIinError(form)).toBe(
      'SCHEDULING.CONTACT.IIN_ERROR_LENGTH'
    );
  });

  it('discards a previous chat load even after switching away and back', async () => {
    const pending = [deferredRequest(), deferredRequest()];
    SchedulingAppointmentsAPI.get
      .mockImplementationOnce(() => pending[0].promise)
      .mockImplementationOnce(() => pending[1].promise);
    const wrapper = mountComponent();
    await flushPromises();
    await wrapper.setProps({
      currentChat: { id: 999, meta: { sender: { id: 77 } } },
    });
    await flushPromises();
    await wrapper.setProps({ currentChat: defaultCurrentChat() });
    await flushPromises();
    pending.forEach(request =>
      request.resolve({
        data: { payload: [{ ...existingAppointment, clientName: 'Stale' }] },
      })
    );
    await flushPromises();
    expect(wrapper.vm.appointments[0].clientName).toBe('Айша');
    wrapper.unmount();
  });

  it('does not start an appointment load after unmounting during reference loading', async () => {
    const request = deferredRequest();
    mocks.loadResources.mockImplementationOnce(() => request.promise);
    const wrapper = mountComponent();
    await flushPromises();
    wrapper.unmount();
    request.resolve();
    await flushPromises();
    expect(SchedulingAppointmentsAPI.get).not.toHaveBeenCalled();
  });
});
