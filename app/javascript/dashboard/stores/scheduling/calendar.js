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
  formatCalendarTitle,
  shiftAnchorDate,
} from 'dashboard/routes/dashboard/scheduling/helpers';
import { CALENDAR_STORAGE_KEY } from 'dashboard/routes/dashboard/scheduling/constants';
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

export const useSchedulingCalendarStore = defineStore('schedulingCalendar', {
  state: () => ({
    activeRequestId: 0,
    anchorDate: new Date().toISOString(),
    customAttributeFilters: {},
    currentView: 'week',
    initialized: false,
    paymentStatusFilters: [],
    payload: defaultPayload(),
    selectedResourceIds: [],
    statusFilters: [],
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
      formatCalendarTitle(state.currentView, state.anchorDate),
    currentRange: state =>
      buildCalendarRange(state.currentView, state.anchorDate),
    expenses: state => state.payload.expenses,
    holidays: state => state.payload.holidays,
    payments: state => state.payload.payments,
    resources: state => state.payload.resources,
    slots: state => state.payload.slots,
    timeOffs: state => state.payload.timeOffs,
    visibleResources: state => {
      if (!state.selectedResourceIds.length) {
        return state.payload.resources;
      }

      return state.payload.resources.filter(resource =>
        state.selectedResourceIds.includes(resource.id)
      );
    },
    workRules: state => state.payload.workRules,
    workdayOverrides: state => state.payload.workdayOverrides,
  },

  actions: {
    hydratePreferences() {
      if (this.initialized || typeof window === 'undefined') return;

      const rawPreferences = window.localStorage.getItem(CALENDAR_STORAGE_KEY);
      if (!rawPreferences) {
        this.initialized = true;
        return;
      }

      try {
        const parsed = JSON.parse(rawPreferences);
        this.anchorDate = parsed.anchorDate || this.anchorDate;
        this.currentView = parsed.currentView || this.currentView;
        this.selectedResourceIds = Array.isArray(parsed.selectedResourceIds)
          ? parsed.selectedResourceIds.map(Number)
          : [];
      } catch {
        // Ignore malformed local preferences and continue with defaults.
      } finally {
        this.initialized = true;
      }
    },

    persistPreferences() {
      if (typeof window === 'undefined') return;

      window.localStorage.setItem(
        CALENDAR_STORAGE_KEY,
        JSON.stringify({
          anchorDate: this.anchorDate,
          currentView: this.currentView,
          selectedResourceIds: this.selectedResourceIds,
        })
      );
    },

    setView(view) {
      this.currentView = view;
      this.persistPreferences();
    },

    setAnchorDate(date) {
      this.anchorDate = date;
      this.persistPreferences();
    },

    shiftAnchor(direction) {
      this.anchorDate = shiftAnchorDate(
        this.currentView,
        this.anchorDate,
        direction
      ).toISOString();
      this.persistPreferences();
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

    setPaymentStatusFilters(statuses) {
      this.paymentStatusFilters = [...statuses];
    },

    setCustomAttributeFilters(filters = {}) {
      this.customAttributeFilters = { ...(filters || {}) };
    },

    clearQuickFilters() {
      this.statusFilters = [];
      this.paymentStatusFilters = [];
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
          this.anchorDate
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

        if (this.statusFilters.length) {
          params.status = this.statusFilters.join(',');
        }

        if (this.paymentStatusFilters.length) {
          params.payment_status = this.paymentStatusFilters.join(',');
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
        this.anchorDate
      );
      const crmReferencesStore = useCrmReferencesStore();
      const matchesCustomFields = appointmentMatchesCustomFieldFilters(
        appointment,
        crmReferencesStore.appointmentFieldDefinitions,
        this.customAttributeFilters
      );

      return (
        matchesNumericFilter(
          this.selectedResourceIds,
          appointment.resourceId
        ) &&
        (!this.statusFilters.length ||
          this.statusFilters.includes(appointment.status)) &&
        (!this.paymentStatusFilters.length ||
          this.paymentStatusFilters.includes(appointment.paymentStatus)) &&
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
