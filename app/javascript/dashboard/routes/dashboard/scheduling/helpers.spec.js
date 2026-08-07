import {
  buildCalendarRange,
  buildMedelementProviderCommandDetails,
  buildMedelementProviderCommandParams,
  canCreateAppointmentConversation,
  deriveVisibleMinuteWindow,
  getServicePriceForResource,
  isAppointmentProviderOwned,
  isMedelementResource,
  medelementCabinetsForResource,
  resolveAppointmentMedelementCabinetCode,
  resolveAppointmentConversationTarget,
  shiftAnchorDate,
} from './helpers';

describe('scheduling helpers', () => {
  it('identifies provider-owned Medelement appointments', () => {
    expect(isAppointmentProviderOwned({ source: 'medelement' })).toBe(true);
    expect(isAppointmentProviderOwned({ source: 'manual' })).toBe(false);
  });

  it('normalizes Medelement cabinets from resource custom attributes', () => {
    const resource = {
      customAttributes: {
        medelement_cabinets: [
          {
            companyCabinetCode: 501,
            companyCabinetName: 'Main office',
          },
        ],
        medelement_specialist_code: 'doctor-1',
      },
    };

    expect(isMedelementResource(resource)).toBe(true);
    expect(medelementCabinetsForResource(resource)).toEqual([
      { code: '501', name: 'Main office', number: '' },
    ]);
  });

  it('uses the appointment cabinet and falls back to the only resource cabinet', () => {
    const resources = [
      {
        id: 9,
        customAttributes: {
          medelement_cabinets: [{ company_cabinet_code: '502' }],
        },
      },
    ];

    expect(
      resolveAppointmentMedelementCabinetCode(
        {
          customAttributes: { medelement_cabinet_code: '501' },
          resourceId: 9,
        },
        resources
      )
    ).toBe('501');
    expect(
      resolveAppointmentMedelementCabinetCode({ resourceId: 9 }, resources)
    ).toBe('502');
  });

  it('builds create, move, and remove Medelement provider command payloads', () => {
    const appointment = {
      endsAt: '2026-03-09T10:30:00.000Z',
      id: 17,
      startsAt: '2026-03-09T10:00:00.000Z',
    };

    expect(
      buildMedelementProviderCommandParams({
        appointment,
        companyCabinetCode: '501',
        operation: 'create_reception',
      })
    ).toEqual({
      appointment_id: 17,
      company_cabinet_code: '501',
      operation: 'create_reception',
      provider: 'medelement',
    });
    expect(
      buildMedelementProviderCommandParams({
        appointment,
        companyCabinetCode: '501',
        operation: 'move_reception',
        patch: {
          ends_at: '2026-03-09T11:30:00.000Z',
          starts_at: '2026-03-09T11:00:00.000Z',
        },
      })
    ).toEqual({
      appointment_id: 17,
      company_cabinet_code: '501',
      desired_ends_at: '2026-03-09T11:30:00.000Z',
      desired_starts_at: '2026-03-09T11:00:00.000Z',
      operation: 'move_reception',
      provider: 'medelement',
    });
    expect(
      buildMedelementProviderCommandParams({
        appointment,
        operation: 'remove_reception',
      })
    ).toEqual({
      appointment_id: 17,
      operation: 'remove_reception',
      provider: 'medelement',
    });
  });

  it('builds complete Medelement confirmation details including move before and after values', () => {
    expect(
      buildMedelementProviderCommandDetails({
        appointment: {
          clientName: 'Айжан Садыкова',
          durationMin: 45,
          endsAt: '2026-03-09T10:45:00.000Z',
          resourceName: 'Д-р Жумабеков',
          serviceAmount: 25000,
          serviceNameSnapshot: 'Первичный приём',
          startsAt: '2026-03-09T10:00:00.000Z',
        },
        params: {
          company_cabinet_code: 'CAB-7',
          desired_ends_at: '2026-03-10T12:45:00.000Z',
          desired_starts_at: '2026-03-10T12:00:00.000Z',
          operation: 'move_reception',
        },
      })
    ).toEqual({
      cabinetCode: 'CAB-7',
      currentEndsAt: '2026-03-09T10:45:00.000Z',
      currentStartsAt: '2026-03-09T10:00:00.000Z',
      desiredEndsAt: '2026-03-10T12:45:00.000Z',
      desiredStartsAt: '2026-03-10T12:00:00.000Z',
      durationMin: 45,
      operation: 'move_reception',
      patientName: 'Айжан Садыкова',
      price: 25000,
      serviceName: 'Первичный приём',
      specialistName: 'Д-р Жумабеков',
    });
  });

  it('builds a week range anchored to Monday', () => {
    const { from, to } = buildCalendarRange('week', '2026-03-11T08:00:00.000Z');

    expect(from.toISOString()).toBe('2026-03-09T00:00:00.000Z');
    expect(to.toISOString()).toBe('2026-03-15T23:59:59.999Z');
  });

  it('shifts list view by two weeks', () => {
    const nextDate = shiftAnchorDate('list', '2026-03-09T00:00:00.000Z', 1);

    expect(nextDate.toISOString()).toBe('2026-03-23T00:00:00.000Z');
  });

  it('shifts kanban view by two weeks', () => {
    const nextDate = shiftAnchorDate('kanban', '2026-03-09T00:00:00.000Z', 1);

    expect(nextDate.toISOString()).toBe('2026-03-23T00:00:00.000Z');
  });

  it('derives a visible minute window from rules and appointments', () => {
    const window = deriveVisibleMinuteWindow({
      appointments: [
        {
          startsAt: '2026-03-09T06:30:00.000Z',
          endsAt: '2026-03-09T07:15:00.000Z',
        },
      ],
      columns: [
        {
          date: new Date('2026-03-09T00:00:00.000Z'),
          resourceId: 10,
        },
      ],
      workRules: [
        {
          active: true,
          endMinute: 18 * 60,
          resourceId: 10,
          startMinute: 9 * 60,
          weekday: 1,
        },
      ],
      workdayOverrides: [],
    });

    expect(window).toEqual({
      endMinute: 1320,
      startMinute: 390,
    });
  });

  it('falls back to the default day timeline window when there is no data', () => {
    const window = deriveVisibleMinuteWindow({
      appointments: [],
      columns: [],
      workRules: [],
      workdayOverrides: [],
    });

    expect(window).toEqual({
      endMinute: 1320,
      startMinute: 420,
    });
  });

  it('prefers a resource-specific active price over the base price', () => {
    const price = getServicePriceForResource(
      {
        basePrice: 7000,
        prices: [
          { active: false, price: 9000, resourceId: 12 },
          { active: true, price: 12000, resourceId: 15 },
        ],
      },
      15
    );

    expect(price).toBe(12000);
  });

  it('uses the existing contact thread when an appointment has no explicit conversation link', () => {
    const target = resolveAppointmentConversationTarget({
      appointment_conversation_id: null,
      communication_thread_id: 9700,
      communication_thread_display_id: 1312,
      chat_conversation_id: 28708,
      chat_conversation_display_id: 2932,
    });

    expect(target).toEqual({
      communicationThreadDisplayId: '1312',
      communicationThreadId: '9700',
      conversationDisplayId: '2932',
      conversationId: 28708,
    });
  });

  it('keeps an explicit appointment conversation instead of an unrelated contact thread fallback', () => {
    const target = resolveAppointmentConversationTarget({
      appointmentConversationId: 42,
      communicationThreadId: 9700,
      communicationThreadDisplayId: 1312,
      chatConversationId: 28708,
      chatConversationDisplayId: 2932,
    });

    expect(target).toEqual({
      communicationThreadDisplayId: '',
      communicationThreadId: '',
      conversationDisplayId: '',
      conversationId: 42,
    });
  });

  it('requires the new API capability before creating a conversation for a Medelement appointment', () => {
    expect(
      canCreateAppointmentConversation({
        conversationCreationSupported: true,
        source: 'medelement',
      })
    ).toBe(false);
    expect(
      canCreateAppointmentConversation({
        conversationCreationSupported: true,
        externalConversationCreationSupported: true,
        source: 'medelement',
      })
    ).toBe(true);
  });

  it('preserves conversation creation for manual appointments', () => {
    expect(
      canCreateAppointmentConversation({
        conversationCreationSupported: true,
        source: 'manual',
      })
    ).toBe(true);
  });
});
