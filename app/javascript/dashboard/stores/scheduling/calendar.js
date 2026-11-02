import { defineStore } from 'pinia';
import camelcaseKeys from 'camelcase-keys';
import SchedulingCalendarAPI from 'dashboard/api/scheduling/calendar';
import {
  extractSchedulingError,
  normalizePayload,
} from 'dashboard/stores/scheduling/shared';
import { useCrmReferencesStore } from 'dashboard/stores/crm/references';
import {
  buildCalendarRange,
  calendarTodayAnchor,
  formatCalendarTitle,
  shiftAnchorDate,
} from 'dashboard/routes/dashboard/scheduling/helpers';
import {
  APPOINTMENT_STATUS_VALUES,
  CALENDAR_STORAGE_KEY,
} from 'dashboard/routes/dashboard/scheduling/constants';

const NON_CANCELLED_APPOINTMENT_STATUS_VALUES =
  APPOINTMENT_STATUS_VALUES.filter(status => status !== 'cancelled');
import { appointmentMatchesCustomFieldFilters } from 'dashboard/routes/dashboard/scheduling/customFieldFilters';
import { preserveCustomAttributeKeys } from 'dashboard/utils/preserveCustomAttributeKeys';

const defaultPayload = () => ({
  range: { from: null, to: null },
  resources: [],
  workRules: [],
  breakRules: [],
  holidays: [],
  workdayOverrides: [],
  timeOffs: [],
  appointments: [],
  payments: [],
  expenses: [],
  slots: [],
});

const appointmentIntersectsRange = (appointment, range) => {
  const startsAt = new Date(appointment.startsAt);
  const endsAt = new Date(appointment.endsAt);

  if (
    Number.isNaN(startsAt.getTime()) ||
    Number.isNaN(endsAt.getTime()) ||
    !range?.from ||
    !range?.to
  ) {
    return false;
  }

  return startsAt < range.to && endsAt > range.from;
};

const matchesNumericFilter = (selectedIds, value) => {
  if (!selectedIds.length) {
    return true;
  }

  return selectedIds.includes(Number(value));
};

const effectiveAppointmentStatusFilters = (
  statusFilters,
  hideCancelledAppointments
) => {
  if (!hideCancelledAppointments) return statusFilters;

  const nonCancelledStatusFilters = statusFilters.filter(
    status => status !== 'cancelled'
  );

  return nonCancelledStatusFilters.length
    ? nonCancelledStatusFilters
    : NON_CANCELLED_APPOINTMENT_STATUS_VALUES;
};

export const useSchedulingCalendarStore = defineStore('schedulingCalendar', {
  state: () => ({
    activeRequestId: 0,
    anchorDate: new Date().toISOString(),
    customAttributeFilters: {},
    currentView: 'week',
    currentPresentation: 'calendar',
    preferenceScope: null,

    initialized: false,
    payload: defaultPayload(),
    selectedResourceIds: [],
    hideCancelledAppointments: false,
    showInactiveAppointments: true,
    statusFilters: [],
    workspaceTimezone: null,
    ui: {
      error: null,
      isLoading: false,
      lastLoadedAt: null,
    },
  }),

  getters: {
    appointments: state => state.payload.appointments,
    breakRules: state => state.payload.breakRules,
    calendarTitle: state =>
      formatCalendarTitle(
        state.currentView,
        state.anchorDate,
        undefined,
        state.workspaceTimezone
      ),
    currentRange: state =>
      buildCalendarRange(
        state.currentView,
        state.anchorDate,
        state.workspaceTimezone
      ),
    expenses: state => state.payload.expenses,
    holidays: state => state.payload.holidays,
    payments: state => state.payload.payments,
    resources: state => state.payload.resources,
    slots: state => state.payload.slots,
    timeOffs: state => state.payload.timeOffs,
    visibleResources: state => {
      if (!state.selectedResourceIds.length) {
        return [];
      }

      return state.payload.resources.filter(resource =>
        state.selectedResourceIds.includes(resource.id)
      );
    },
    workRules: state => state.payload.workRules,
    workdayOverrides: state => state.payload.workdayOverrides,
  },

  actions: {
    enterCalendar({
      accountId,
      userId,
      mobile = false,
      date,
      now = new Date(),
    }) {
      const scope = accountId && userId ? `${accountId}:${userId}` : null;
      // A previous visit or actor's in-flight request must never populate this entry.
      this.activeRequestId += 1;
      this.payload = defaultPayload();
      this.ui = { error: null, isLoading: false, lastLoadedAt: null };
      if (scope !== this.preferenceScope) {
        this.statusFilters = [];
        this.customAttributeFilters = {};
      }
      this.preferenceScope = scope;
      this.initialized = false;
      this.currentView = mobile ? 'day' : 'week';
      this.currentPresentation = mobile ? 'list' : 'calendar';
      this.selectedResourceIds = [];
      this.hideCancelledAppointments = false;
      this.hydratePreferences();
      this.anchorDate = (
        date ? new Date(date) : calendarTodayAnchor(now, this.workspaceTimezone)
      ).toISOString();
    },

    hydratePreferences() {
      if (this.initialized || typeof window === 'undefined') return;

      try {
        // Unscoped legacy preferences cannot be attributed to this account/user.
        const rawPreferences = this.preferenceScope
          ? window.localStorage.getItem(
              `${CALENDAR_STORAGE_KEY}:${this.preferenceScope}`
            )
          : null;
        if (!rawPreferences) return;
        const parsed = JSON.parse(rawPreferences);
        if (['day', 'week', 'month'].includes(parsed.currentView)) {
          this.currentView = parsed.currentView;
        }
        if (['calendar', 'list'].includes(parsed.currentPresentation)) {
          this.currentPresentation = parsed.currentPresentation;
        }
        this.selectedResourceIds = Array.isArray(parsed.selectedResourceIds)
          ? [
              ...new Set(
                parsed.selectedResourceIds
                  .map(Number)
                  .filter(id => Number.isInteger(id) && id > 0)
              ),
            ]
          : [];
        this.hideCancelledAppointments =
          parsed.hideCancelledAppointments === true;
      } catch {
        // Malformed or unavailable local preferences do not prevent entry.
      } finally {
        this.initialized = true;
      }
    },

    persistPreferences() {
      if (typeof window === 'undefined' || !this.preferenceScope) return;
      try {
        window.localStorage.setItem(
          `${CALENDAR_STORAGE_KEY}:${this.preferenceScope}`,
          JSON.stringify({
            currentView: this.currentView,
            currentPresentation: this.currentPresentation,
            selectedResourceIds: this.selectedResourceIds,
            hideCancelledAppointments: this.hideCancelledAppointments,
          })
        );
      } catch {
        // Storage may be unavailable; the current in-memory selection still works.
      }
    },

    setPresentation(presentation) {
      this.currentPresentation = presentation;
      this.persistPreferences();
    },

    setView(view) {
      this.currentView = view;
      this.persistPreferences();
    },

    setAnchorDate(date) {
      this.anchorDate = date;
    },

    setWorkspaceTimezone(timezone) {
      this.workspaceTimezone = timezone || null;
    },

    shiftAnchor(direction) {
      this.anchorDate = shiftAnchorDate(
        this.currentView,
        this.anchorDate,
        direction,
        this.workspaceTimezone
      ).toISOString();
    },

    toggleResource(resourceId) {
      const normalizedId = Number(resourceId);

      if (this.selectedResourceIds.includes(normalizedId)) {
        this.selectedResourceIds = this.selectedResourceIds.filter(
          id => id !== normalizedId
        );
      } else {
        this.selectedResourceIds = [...this.selectedResourceIds, normalizedId];
      }

      this.persistPreferences();
    },

    setSelectedResources(resourceIds) {
      this.selectedResourceIds = resourceIds.map(Number);
      this.persistPreferences();
    },

    setStatusFilters(statuses) {
      this.statusFilters = [...statuses];
    },

    setHideCancelledAppointments(hideCancelledAppointments) {
      this.hideCancelledAppointments = Boolean(hideCancelledAppointments);
      if (this.hideCancelledAppointments) {
        this.statusFilters = this.statusFilters.filter(
          status => status !== 'cancelled'
        );
      }
      this.persistPreferences();
    },

    setShowInactiveAppointments(showInactiveAppointments) {
      this.showInactiveAppointments = Boolean(showInactiveAppointments);
      this.setHideCancelledAppointments(!showInactiveAppointments);
    },

    setCustomAttributeFilters(filters = {}) {
      this.customAttributeFilters = { ...(filters || {}) };
    },

    clearQuickFilters() {
      this.statusFilters = [];
    },

    resetFilters() {
      this.clearQuickFilters();
      this.setCustomAttributeFilters({});
      this.setHideCancelledAppointments(false);
    },

    async fetchCalendar(options = {}) {
      this.hydratePreferences();
      const requestId = this.activeRequestId + 1;
      this.activeRequestId = requestId;
      this.ui.isLoading = true;
      this.ui.error = null;

      try {
        const { from, to } = buildCalendarRange(
          this.currentView,
          this.anchorDate,
          this.workspaceTimezone
        );
        const includeSlots =
          options.includeSlots ?? ['day', 'week'].includes(this.currentView);

        const params = {
          from: from.toISOString(),
          include_slots: includeSlots,
          to: to.toISOString(),
          view: this.currentView,
        };

        if (this.selectedResourceIds.length) {
          params.resource_ids = this.selectedResourceIds.join(',');
        }

        const effectiveStatusFilters = effectiveAppointmentStatusFilters(
          this.statusFilters,
          this.hideCancelledAppointments
        );
        if (effectiveStatusFilters.length) {
          params.status = effectiveStatusFilters.join(',');
        }

        const customAttributeFilters =
          options.customAttributeFilters ?? this.customAttributeFilters;
        if (Object.keys(customAttributeFilters || {}).length) {
          params.custom_attribute_filters = customAttributeFilters;
        }

        const { data } = await SchedulingCalendarAPI.show(params);
        if (requestId !== this.activeRequestId) {
          return this.payload;
        }

        const payload = normalizePayload(data);
        this.payload = { ...defaultPayload(), ...payload };
        this.ui.lastLoadedAt = new Date().toISOString();
        return this.payload;
      } catch (error) {
        if (requestId !== this.activeRequestId) {
          return this.payload;
        }

        this.ui.error = extractSchedulingError(error);
        throw error;
      } finally {
        if (requestId === this.activeRequestId) {
          this.ui.isLoading = false;
        }
      }
    },

    async refresh(options = {}) {
      return this.fetchCalendar(options);
    },

    removeAppointment(appointmentId) {
      const normalizedId = Number(appointmentId);

      this.payload = {
        ...this.payload,
        appointments: this.payload.appointments.filter(
          item => Number(item.id) !== normalizedId
        ),
        expenses: this.payload.expenses.filter(
          item => Number(item.appointmentId) !== normalizedId
        ),
        payments: this.payload.payments.filter(
          item => Number(item.appointmentId) !== normalizedId
        ),
      };
    },

    appointmentMatchesActiveView(appointment) {
      const currentRange = buildCalendarRange(
        this.currentView,
        this.anchorDate,
        this.workspaceTimezone
      );
      const crmReferencesStore = useCrmReferencesStore();
      const matchesCustomFields = appointmentMatchesCustomFieldFilters(
        appointment,
        crmReferencesStore.appointmentFieldDefinitions,
        this.customAttributeFilters
      );
      const effectiveStatusFilters = effectiveAppointmentStatusFilters(
        this.statusFilters,
        this.hideCancelledAppointments
      );

      return (
        matchesNumericFilter(
          this.selectedResourceIds,
          appointment.resourceId
        ) &&
        (!effectiveStatusFilters.length ||
          effectiveStatusFilters.includes(appointment.status)) &&
        matchesCustomFields &&
        appointmentIntersectsRange(appointment, currentRange)
      );
    },

    upsertAppointment(appointment) {
      const nextAppointment = preserveCustomAttributeKeys(
        appointment,
        camelcaseKeys(appointment, { deep: true })
      );
      const nextAppointments = [...this.payload.appointments];
      const existingIndex = nextAppointments.findIndex(
        item => item.id === nextAppointment.id
      );

      if (existingIndex === -1) {
        nextAppointments.unshift(nextAppointment);
      } else {
        nextAppointments.splice(existingIndex, 1, nextAppointment);
      }

      nextAppointments.sort((left, right) => {
        return new Date(left.startsAt) - new Date(right.startsAt);
      });

      const appointmentPayments = nextAppointment.payments || [];
      this.payload = {
        ...this.payload,
        appointments: nextAppointments,
        expenses: nextAppointment.expense
          ? [
              nextAppointment.expense,
              ...this.payload.expenses.filter(
                item => item.appointmentId !== nextAppointment.id
              ),
            ]
          : this.payload.expenses.filter(
              item => item.appointmentId !== nextAppointment.id
            ),
        payments: [
          ...appointmentPayments,
          ...this.payload.payments.filter(
            item => item.appointmentId !== nextAppointment.id
          ),
        ].sort(
          (left, right) => new Date(right.createdAt) - new Date(left.createdAt)
        ),
      };
    },

    syncAppointment(appointment) {
      const normalizedAppointment = preserveCustomAttributeKeys(
        appointment,
        camelcaseKeys(appointment, { deep: true })
      );

      if (!this.appointmentMatchesActiveView(normalizedAppointment)) {
        this.removeAppointment(normalizedAppointment.id);
        return;
      }

      this.upsertAppointment(normalizedAppointment);
    },
  },
});
