import {
  buildCalendarRange,
  canCreateAppointmentConversation,
  deriveVisibleMinuteWindow,
  getServicePriceForResource,
  isAppointmentProviderOwned,
  resolveAppointmentConversationTarget,
  shiftAnchorDate,
} from './helpers';

describe('scheduling helpers', () => {
  it('identifies provider-owned Medelement appointments', () => {
    expect(isAppointmentProviderOwned({ source: 'medelement' })).toBe(true);
    expect(isAppointmentProviderOwned({ source: 'manual' })).toBe(false);
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
