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
import {
  ACTIVE_APPOINTMENT_STATUS_VALUES,
  CALENDAR_STORAGE_KEY,
} from 'dashboard/routes/dashboard/scheduling/constants';
import { appointmentMatchesCustomFieldFilters } from 'dashboard/routes/dashboard/scheduling/customFieldFilters';
import { preserveCustomAttributeKeys } from 'dashboard/utils/preserveCustomAttributeKeys';

const LIST_PAGE_SIZE = 25;

const defaultPayload = () => ({
  range: { from: null, to: null },
  resources: [],
  workRules: [],
  breakRules: [],
  holidays: [],
  workdayOverrides: [],
  timeOffs: [],
  appointments: [],
  slots: [],
});

// Old web instances can return historical finance fields during a rolling deploy.
const RETIRED_APPOINTMENT_KEYS = [
  'paymentStatus',
  'prepaidAmount',
  'prepaidPaymentMethod',
  'settlementAmount',
  'settlementPaymentMethod',
  'compensationTypeSnapshot',
  'compensationValueSnapshot',
  'compensationPercentSnapshot',
  'payments',
  'expense',
];

const withoutHistoricalFinance = appointment => {
  const visible = { ...appointment };
  RETIRED_APPOINTMENT_KEYS.forEach(key => delete visible[key]);
  return visible;
};

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
  showInactiveAppointments
) => {
  if (showInactiveAppointments) return statusFilters;

  const activeStatusFilters = statusFilters.filter(status =>
    ACTIVE_APPOINTMENT_STATUS_VALUES.includes(status)
  );

  return activeStatusFilters.length
    ? activeStatusFilters
    : ACTIVE_APPOINTMENT_STATUS_VALUES;
};

export const useSchedulingCalendarStore = defineStore('schedulingCalendar', {
  state: () => ({
    activeRequestId: 0,
    anchorDate: new Date().toISOString(),
    customAttributeFilters: {},
    currentView: 'week',

    initialized: false,
    listPage: 1,
    listPerPage: LIST_PAGE_SIZE,
    listTotal: 0,
    payload: defaultPayload(),
    selectedResourceIds: [],
    showInactiveAppointments: false,
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
      formatCalendarTitle(state.currentView, state.anchorDate),
    currentRange: state =>
      buildCalendarRange(
        state.currentView,
        state.anchorDate,
        state.workspaceTimezone
      ),
    holidays: state => state.payload.holidays,
    listTotalPages: state =>
      Math.max(Math.ceil(state.listTotal / state.listPerPage), 1),
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
        this.showInactiveAppointments =
          parsed.showInactiveAppointments === true;
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
          showInactiveAppointments: this.showInactiveAppointments,
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

    setWorkspaceTimezone(timezone) {
      this.workspaceTimezone = timezone || 'Asia/Almaty';
    },

    setListPage(page) {
      this.listPage = Math.max(Number(page) || 1, 1);
    },

    resetListPagination() {
      this.listPage = 1;
      this.listTotal = 0;
    },

    invalidateRequests() {
      this.activeRequestId += 1;
      this.ui.isLoading = false;
    },

    resetForAccountChange() {
      this.activeRequestId += 1;
      this.customAttributeFilters = {};
      this.listPage = 1;
      this.listTotal = 0;
      this.payload = defaultPayload();
      this.selectedResourceIds = [];
      this.statusFilters = [];
      this.ui = {
        error: null,
        isLoading: true,
        lastLoadedAt: null,
      };
    },

    setLoadError(error) {
      this.ui.error = error;
      this.ui.isLoading = false;
    },

    shiftAnchor(direction) {
      this.anchorDate = shiftAnchorDate(
        this.currentView,
        this.anchorDate,
        direction,
        this.workspaceTimezone
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

    setShowInactiveAppointments(showInactiveAppointments) {
      this.showInactiveAppointments = Boolean(showInactiveAppointments);
      if (!this.showInactiveAppointments) {
        this.statusFilters = this.statusFilters.filter(status =>
          ACTIVE_APPOINTMENT_STATUS_VALUES.includes(status)
        );
      }
      this.persistPreferences();
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
      this.setShowInactiveAppointments(false);
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

        const paginateAppointments = options.paginateAppointments === true;
        if (paginateAppointments) {
          params.page = this.listPage;
          params.paginate_appointments = true;
          params.per_page = this.listPerPage;
        }

        if (this.selectedResourceIds.length) {
          params.resource_ids = this.selectedResourceIds.join(',');
        }

        const effectiveStatusFilters = effectiveAppointmentStatusFilters(
          this.statusFilters,
          this.showInactiveAppointments
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
        delete payload.payments;
        delete payload.expenses;
        payload.appointments = (payload.appointments || []).map(
          withoutHistoricalFinance
        );
        if (paginateAppointments) {
          const meta = camelcaseKeys(data?.meta || {});
          this.listTotal = Number(meta.count) || 0;
          const lastPage = Math.max(
            Math.ceil(this.listTotal / this.listPerPage),
            1
          );
          if (this.listPage > lastPage) {
            this.listPage = lastPage;
            return this.fetchCalendar(options);
          }
        }
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
        this.showInactiveAppointments
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
      const nextAppointment = withoutHistoricalFinance(
        preserveCustomAttributeKeys(
          appointment,
          camelcaseKeys(appointment, { deep: true })
        )
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

      this.payload = {
        ...this.payload,
        appointments: nextAppointments,
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
