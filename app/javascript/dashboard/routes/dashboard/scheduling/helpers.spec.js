import {
  appointmentCancellationAlertKey,
  appointmentPatientDialogRoute,
  buildCalendarRange,
  buildMedelementProviderCommandDetails,
  buildMedelementProviderCommandParams,
  buildTimeOffIntervals,
  calendarDayAnchor,
  calendarTodayAnchor,
  canCreateAppointmentConversation,
  deriveVisibleMinuteWindow,
  formatCalendarTitle,
  getServicePriceForResource,
  hasMedelementReceptionIdentity,
  isAppointmentProviderOwned,
  isMedelementCancellationLocalOnly,
  isMedelementLocalCancellation,
  isMedelementResource,
  providerBookingNeedsReview,
  providerBookingStatusKey,
  providerBookingStatusMessage,
  appointmentCancellationAlertMessage,
  providerCancellationPending,
  isServiceAvailableForResource,
  medelementCommandFailureMessage,
  medelementCabinetsForResource,
  resolveAppointmentMedelementCabinetCode,
  resolveAppointmentConversationTarget,
  servicesAvailableForResource,
  shiftAnchorDate,
  addMinutesToDateTimeInputValue,
  dateTimeInputDurationMinutes,
  formatSchedulingDateTime,
  fromDateTimeInputValue,
  minuteOfDayFromDate,
  toDateTimeInputValue,
} from './helpers';
import enScheduling from 'dashboard/i18n/locale/en/scheduling.json';
import kkScheduling from 'dashboard/i18n/locale/kk/scheduling.json';
import ruScheduling from 'dashboard/i18n/locale/ru/scheduling.json';

describe('appointment patient dialog route', () => {
  it('opens the original shared chat with the appointment patient selected', () => {
    expect(
      appointmentPatientDialogRoute(
        {
          contactId: 42,
          patientContactId: 84,
          conversationId: 12002,
          conversationDisplayId: 123,
        },
        74
      )
    ).toEqual({
      name: 'inbox_conversation',
      params: { accountId: 74, conversation_id: '123' },
      query: { patientContactId: '84', patientChatContactId: '42' },
    });
  });
  it('prefers the original shared thread display ID', () => {
    expect(
      appointmentPatientDialogRoute(
        {
          contactId: 42,
          patientContextContactId: 84,
          conversationId: 12002,
          conversationDisplayId: 123,
          appointmentCommunicationThreadId: 9001,
          appointmentCommunicationThreadDisplayId: 456,
        },
        74
      )?.params
    ).toEqual({ accountId: 74, communication_thread_id: '456' });
  });
  it('never treats a database ID as a public conversation ID', () => {
    expect(
      appointmentPatientDialogRoute(
        { contactId: 42, patientContactId: 84, conversationId: 12002 },
        74
      )
    ).toBeNull();
  });
});

describe.each([
  ['en', enScheduling],
  ['ru', ruScheduling],
  ['kk', kkScheduling],
])('%s copy for the local-only MedElement cancellation', (_locale, m) => {
  it('is present', () => {
    const copy = [
      m.SCHEDULING.APPOINTMENT_STATUS.MEDELEMENT_NOT_CANCELLED,
      m.SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL_LOCAL_ONLY,
      m.SCHEDULING.MEDELEMENT.LOCAL_CANCEL_CONFIRM_TITLE,
      m.SCHEDULING.MEDELEMENT.LOCAL_CANCEL_CONFIRM_DESCRIPTION,
      m.SCHEDULING.MEDELEMENT.LOCAL_CANCEL_HINT,
      m.SCHEDULING.ERRORS.MEDELEMENT_LOCAL_CANCELLATION_PROTECTED,
      m.SCHEDULING.ERRORS.MEDELEMENT_REMOVAL_DISABLED,
    ];

    copy.forEach(text => expect(text).toEqual(expect.any(String)));
  });
});

// Clinic clock helpers: with the workspace timezone the results must not
// depend on the process timezone (run with TZ=UTC and TZ=Europe/Berlin).
describe('scheduling helpers on the clinic clock (Asia/Almaty)', () => {
  const ALMATY = 'Asia/Almaty';

  it('shows an instant as the clinic wall clock in a date/time input', () => {
    expect(toDateTimeInputValue('2026-09-29T05:00:00.000Z', ALMATY)).toBe(
      '2026-09-29T10:00'
    );
    // 21:30Z is already the next day in Almaty.
    expect(toDateTimeInputValue('2026-03-28T21:30:00.000Z', ALMATY)).toBe(
      '2026-03-29T02:30'
    );
  });

  it('reads a typed clinic wall clock as the right instant', () => {
    expect(fromDateTimeInputValue('2026-09-29T10:00', ALMATY)).toBe(
      '2026-09-29T05:00:00.000Z'
    );
    // Inside the Berlin DST gap, but a normal time on the clinic clock.
    expect(fromDateTimeInputValue('2026-03-29T02:30', ALMATY)).toBe(
      '2026-03-28T21:30:00.000Z'
    );
    expect(fromDateTimeInputValue('', ALMATY)).toBeNull();
  });

  it('moves and measures date/time input values on the clinic clock', () => {
    expect(addMinutesToDateTimeInputValue('2026-09-29T23:40', 45, ALMATY)).toBe(
      '2026-09-30T00:25'
    );
    expect(
      dateTimeInputDurationMinutes(
        '2026-03-29T01:30',
        '2026-03-29T03:00',
        ALMATY
      )
    ).toBe(90);
  });

  it('reads the minute of day and formats date and time on the clinic clock', () => {
    expect(minuteOfDayFromDate('2026-09-29T05:15:00.000Z', ALMATY)).toBe(
      10 * 60 + 15
    );
    expect(
      formatSchedulingDateTime('2026-09-29T05:00:00.000Z', 'en', ALMATY)
    ).toContain('10:00');
    expect(formatSchedulingDateTime('', 'en', ALMATY)).toBe('—');
  });

  it('keeps the browser-local behaviour without a timezone', () => {
    const local = new Date(2026, 8, 29, 10, 0);

    expect(toDateTimeInputValue(local)).toBe('2026-09-29T10:00');
    expect(fromDateTimeInputValue('2026-09-29T10:00')).toBe(
      local.toISOString()
    );
    expect(minuteOfDayFromDate(local)).toBe(10 * 60);
  });
});

describe('scheduling helpers', () => {
  it('identifies provider-owned Medelement appointments', () => {
    expect(isAppointmentProviderOwned({ source: 'medelement' })).toBe(true);
    expect(isAppointmentProviderOwned({ source: 'manual' })).toBe(false);
  });

  it('does not offer another reception create for a linked or pending manual appointment', () => {
    expect(
      hasMedelementReceptionIdentity({
        source: 'manual',
        externalRef: 'medelement:reception:71',
      })
    ).toBe(true);
    expect(
      hasMedelementReceptionIdentity({
        source: 'manual',
        customAttributes: { medelement_reception_code: '71' },
      })
    ).toBe(true);
    expect(
      hasMedelementReceptionIdentity({ providerConfirmationStatus: 'pending' })
    ).toBe(true);
    expect(
      hasMedelementReceptionIdentity({ source: 'manual', status: 'scheduled' })
    ).toBe(false);
  });

  it('shows a red review state for an unknown booking or cancellation, not a confirmed booking', () => {
    expect(
      providerBookingNeedsReview({
        status: 'scheduled',
        providerConfirmationStatus: 'provider_status_unknown',
      })
    ).toBe(true);
    expect(
      providerBookingNeedsReview({
        status: 'confirmed',
        customAttributes: { medelement_provider_sync_status: 'failed' },
      })
    ).toBe(true);
    expect(
      providerBookingNeedsReview({
        status: 'scheduled',
        providerConfirmationStatus: 'succeeded',
      })
    ).toBe(false);
    expect(
      providerBookingNeedsReview({
        status: 'cancelled',
        providerConfirmationStatus: 'failed',
      })
    ).toBe(true);
    expect(
      providerBookingNeedsReview({
        status: 'no_show',
        providerConfirmationStatus: 'failed',
      })
    ).toBe(false);
  });

  it('keeps a provider removal pending or unknown without announcing completed cancellation', () => {
    const appointment = {
      source: 'manual',
      status: 'scheduled',
      customAttributes: { medelement_cancellation_command_id: 42 },
      providerConfirmationStatus: 'pending',
    };
    expect(providerCancellationPending(appointment)).toBe(true);
    expect(providerBookingStatusKey(appointment)).toBe(
      'SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_PENDING'
    );
    expect(appointmentCancellationAlertKey(appointment)).toBe(
      'SCHEDULING.APPOINTMENT_FORM.CANCELLATION_PENDING'
    );

    const unknown = {
      ...appointment,
      providerConfirmationStatus: 'provider_status_unknown',
    };
    expect(providerBookingStatusKey(unknown)).toBe(
      'SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_REVIEW'
    );
    expect(appointmentCancellationAlertKey(unknown)).toBe(
      'SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_REVIEW'
    );
    expect(appointmentCancellationAlertKey({ status: 'cancelled' })).toBe(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL'
    );
    expect(
      providerBookingStatusKey({
        status: 'cancelled',
        providerConfirmationStatus: 'pending',
      })
    ).toBe('SCHEDULING.APPOINTMENT_STATUS.CANCELLATION_PENDING');
  });

  it('marks an appointment cancelled only in OneLink while its MedElement reception is still active', () => {
    const t = key => key;
    const locallyCancelled = {
      source: 'medelement',
      status: 'cancelled',
      providerConfirmationStatus: 'failed',
      customAttributes: {
        medelement_local_cancellation: { reception_code: '71' },
      },
    };

    expect(isMedelementLocalCancellation(locallyCancelled)).toBe(true);
    expect(providerBookingStatusKey(locallyCancelled)).toBe(
      'SCHEDULING.APPOINTMENT_STATUS.MEDELEMENT_NOT_CANCELLED'
    );
    expect(providerBookingStatusMessage(locallyCancelled, t)).toBe(
      'SCHEDULING.APPOINTMENT_STATUS.MEDELEMENT_NOT_CANCELLED'
    );
    expect(appointmentCancellationAlertKey(locallyCancelled)).toBe(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL_LOCAL_ONLY'
    );
    expect(appointmentCancellationAlertMessage(locallyCancelled, t)).toBe(
      'SCHEDULING.APPOINTMENT_FORM.SUCCESS_CANCEL_LOCAL_ONLY'
    );

    const reopened = { ...locallyCancelled, status: 'scheduled' };
    expect(isMedelementLocalCancellation(reopened)).toBe(false);
    expect(
      isMedelementLocalCancellation({
        status: 'cancelled',
        customAttributes: {},
      })
    ).toBe(false);
  });

  it('tells whether cancelling stays in OneLink for the integration setting', () => {
    expect(
      isMedelementCancellationLocalOnly({
        medelementCancellationMode: 'local_only',
      })
    ).toBe(true);
    expect(
      isMedelementCancellationLocalOnly({
        medelementCancellationMode: 'provider_removal',
      })
    ).toBe(false);
    expect(isMedelementCancellationLocalOnly({ source: 'manual' })).toBe(false);
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
    const { from, to } = buildCalendarRange('week', new Date(2026, 2, 11, 8));

    expect([
      from.getFullYear(),
      from.getMonth(),
      from.getDate(),
      from.getHours(),
      from.getMinutes(),
    ]).toEqual([2026, 2, 9, 0, 0]);
    expect([
      to.getFullYear(),
      to.getMonth(),
      to.getDate(),
      to.getHours(),
      to.getMinutes(),
      to.getSeconds(),
      to.getMilliseconds(),
    ]).toEqual([2026, 2, 15, 23, 59, 59, 999]);
  });

  it('builds API day boundaries in the Workspace timezone', () => {
    const { from, to } = buildCalendarRange(
      'day',
      '2026-03-09T12:00:00.000Z',
      'Asia/Almaty'
    );

    expect(from.toISOString()).toBe('2026-03-08T19:00:00.000Z');
    expect(to.toISOString()).toBe('2026-03-09T18:59:59.999Z');
  });

  it('uses the Workspace calendar day when the UTC date is still the previous day', () => {
    // 20:30 UTC on Sunday is already 01:30 on Monday in Almaty.
    const { from, to } = buildCalendarRange(
      'week',
      '2026-03-08T20:30:00.000Z',
      'Asia/Almaty'
    );

    expect(from.toISOString()).toBe('2026-03-08T19:00:00.000Z');
    expect(to.toISOString()).toBe('2026-03-15T18:59:59.999Z');
  });

  it('keeps the browser-local range when no Workspace timezone is given', () => {
    const anchor = '2026-03-09T12:00:00.000Z';
    const { from } = buildCalendarRange('day', anchor);
    const anchorDate = new Date(anchor);

    // Browser-local midnight of the anchor day, in any process timezone.
    expect(from.toISOString()).toBe(
      new Date(
        anchorDate.getFullYear(),
        anchorDate.getMonth(),
        anchorDate.getDate()
      ).toISOString()
    );
  });

  it('shifts the anchor by Workspace calendar days and months', () => {
    expect(
      shiftAnchorDate(
        'day',
        '2026-03-08T20:30:00.000Z',
        1,
        'Asia/Almaty'
      ).toISOString()
    ).toBe('2026-03-09T20:30:00.000Z');
    expect(
      shiftAnchorDate(
        'month',
        '2026-01-30T19:30:00.000Z',
        1,
        'Asia/Almaty'
      ).toISOString()
    ).toBe('2026-02-27T19:30:00.000Z');
  });

  it('anchors a picked calendar day at Workspace noon', () => {
    expect(
      calendarDayAnchor(new Date(2026, 2, 9), 'Asia/Almaty').toISOString()
    ).toBe('2026-03-09T07:00:00.000Z');
    // Without a Workspace timezone: browser-local noon of the picked day.
    expect(calendarDayAnchor(new Date(2026, 2, 9)).toISOString()).toBe(
      new Date(2026, 2, 9, 12, 0).toISOString()
    );
  });

  it('uses the Workspace date for Today across a UTC date boundary', () => {
    const now = new Date('2026-03-09T20:00:00.000Z');
    const anchor = calendarTodayAnchor(now, 'Asia/Almaty');

    expect(anchor.toISOString()).toBe('2026-03-10T07:00:00.000Z');
    expect(
      buildCalendarRange('day', anchor, 'Asia/Almaty').from.toISOString()
    ).toBe('2026-03-09T19:00:00.000Z');
  });

  it('formats calendar titles in the Workspace timezone', () => {
    const anchor = '2026-09-03T19:00:00.000Z';

    expect(formatCalendarTitle('day', anchor, 'en', 'Asia/Almaty')).toContain(
      'September 4, 2026'
    );
    expect(formatCalendarTitle('month', anchor, 'en', 'Asia/Almaty')).toBe(
      'September 2026'
    );
    expect(formatCalendarTitle('week', anchor, 'en', 'Asia/Almaty')).toBe(
      'Aug 31 - Sep 6, 2026'
    );
  });

  it('uses the supplied Workspace timezone converter for time-off intervals', () => {
    const convertDate = vi.fn(value =>
      value === 'starts-at'
        ? new Date(2026, 2, 9, 10, 0)
        : new Date(2026, 2, 9, 11, 0)
    );
    const column = {
      date: new Date(2026, 2, 9),
      resourceId: 7,
    };

    expect(
      buildTimeOffIntervals(
        [{ resourceId: 7, startsAt: 'starts-at', endsAt: 'ends-at' }],
        column,
        convertDate
      )
    ).toEqual([{ startMinute: 600, endMinute: 660 }]);
    expect(convertDate).toHaveBeenCalledTimes(2);
  });

  it('keeps the time-off title on clipped intervals for calendar labels', () => {
    const column = { date: new Date(2026, 2, 9), resourceId: 7 };

    expect(
      buildTimeOffIntervals(
        [
          {
            endsAt: new Date(2026, 2, 9, 17, 0),
            resourceId: null,
            startsAt: new Date(2026, 2, 9, 16, 0),
            title: 'Training',
          },
        ],
        column
      )
    ).toEqual([{ endMinute: 1020, startMinute: 960, title: 'Training' }]);
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
          startsAt: '2026-03-09T06:30:00',
          endsAt: '2026-03-09T07:15:00',
        },
      ],
      columns: [
        {
          date: new Date(2026, 2, 9),
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

  it('shows the full mapped Medelement catalog when the specialist has no links', () => {
    const resource = {
      id: 15,
      customAttributes: { medelement_specialist_code: 'specialist-1' },
    };
    const linkedService = {
      id: 1,
      customAttributes: { medelement_nomenclature_code: 'service-1' },
      prices: [],
    };
    const otherSpecialistService = {
      id: 2,
      customAttributes: { medelement_nomenclature_code: 'service-2' },
      prices: [{ active: true, price: 9000, resourceId: 12 }],
    };
    const mappedWithoutPrices = {
      id: 3,
      customAttributes: { medelement_nomenclature_code: 'service-3' },
      prices: [],
    };
    const localService = {
      id: 4,
      customAttributes: {},
      prices: [],
    };

    expect(
      servicesAvailableForResource(
        [
          linkedService,
          otherSpecialistService,
          mappedWithoutPrices,
          localService,
        ],
        resource
      )
    ).toEqual([linkedService, otherSpecialistService, mappedWithoutPrices]);
  });

  it('uses only explicit links when the Medelement specialist has them', () => {
    const resource = {
      id: 15,
      customAttributes: { medelement_specialist_code: 'specialist-1' },
    };
    const linkedService = {
      id: 1,
      customAttributes: { medelement_nomenclature_code: 'service-1' },
      prices: [{ active: true, price: 0, resourceId: 15 }],
    };
    const unlinkedService = {
      id: 2,
      customAttributes: { medelement_nomenclature_code: 'service-2' },
      prices: [],
    };

    expect(isServiceAvailableForResource(linkedService, 15)).toBe(true);
    expect(
      servicesAvailableForResource([linkedService, unlinkedService], resource)
    ).toEqual([linkedService]);
  });

  it('keeps the full service list for a non-Medelement specialist', () => {
    const services = [
      { id: 1, prices: [] },
      { id: 2, prices: [] },
    ];

    expect(servicesAvailableForResource(services, { id: 15 })).toEqual(
      services
    );
  });

  it('turns a provider HTTP 401 into a clear authentication error', () => {
    expect(
      medelementCommandFailureMessage({
        lastErrorCode: 'provider_http_error',
        lastErrorStatus: 401,
        status: 'failed',
      })
    ).toEqual({ key: 'SCHEDULING.MEDELEMENT.AUTHENTICATION_FAILED' });
  });

  it('includes the HTTP status in other provider command failures', () => {
    expect(
      medelementCommandFailureMessage({
        lastErrorCode: 'provider_http_error',
        lastErrorStatus: 503,
        status: 'failed',
      })
    ).toEqual({
      key: 'SCHEDULING.MEDELEMENT.FAILED',
      params: { code: 'provider_http_error (HTTP 503)' },
    });
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
