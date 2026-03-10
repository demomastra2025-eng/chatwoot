import { defineStore } from 'pinia';
import SchedulingAppointmentsAPI from 'dashboard/api/scheduling/appointments';
import SchedulingExpensesAPI from 'dashboard/api/scheduling/expenses';
import SchedulingPaymentsAPI from 'dashboard/api/scheduling/payments';
import { extractSchedulingError, normalizePayload } from './shared';
import { buildCalendarRange } from 'dashboard/routes/dashboard/scheduling/helpers';

const buildDefaultDateRange = () => {
  const { from, to } = buildCalendarRange('month', new Date());

  return {
    from: from.toISOString().slice(0, 10),
    to: to.toISOString().slice(0, 10),
  };
};

export const useSchedulingKassaStore = defineStore('schedulingKassa', {
  state: () => ({
    activeTab: 'income',
    appointmentCandidates: [],
    expenses: [],
    filters: {
      from: buildDefaultDateRange().from,
      paymentKinds: [],
      paymentMethods: [],
      resourceIds: [],
      status: ['unpaid'],
      to: buildDefaultDateRange().to,
    },
    payments: [],
    ui: {
      error: null,
      isLoading: false,
      isSaving: false,
    },
  }),

  getters: {
    appointmentMap: state => {
      return state.appointmentCandidates.reduce((result, appointment) => {
        result[appointment.id] = appointment;
        return result;
      }, {});
    },
    decoratedExpenses() {
      return this.expenses.map(expense => ({
        ...expense,
        appointment: this.appointmentMap[expense.appointmentId] || null,
      }));
    },
    decoratedPayments() {
      return this.payments.map(payment => ({
        ...payment,
        appointment: this.appointmentMap[payment.appointmentId] || null,
      }));
    },
    expenseTotals() {
      return this.expenses.reduce(
        (result, expense) => {
          const amount = Number(expense.amount || 0);
          result.total += amount;
          if (expense.status === 'paid') {
            result.paid += amount;
          } else {
            result.unpaid += amount;
          }
          return result;
        },
        { paid: 0, total: 0, unpaid: 0 }
      );
    },
    paymentTotal: state => {
      return state.payments.reduce((result, payment) => {
        return result + Number(payment.amount || 0);
      }, 0);
    },
  },

  actions: {
    setActiveTab(tab) {
      this.activeTab = tab;
    },

    updateFilters(patch) {
      this.filters = {
        ...this.filters,
        ...patch,
      };
    },

    buildQueryParams() {
      const params = {
        from: this.filters.from
          ? new Date(`${this.filters.from}T00:00:00`).toISOString()
          : undefined,
        to: this.filters.to
          ? new Date(`${this.filters.to}T23:59:59`).toISOString()
          : undefined,
      };

      if (this.filters.resourceIds.length) {
        params.resource_ids = this.filters.resourceIds.join(',');
      }

      if (this.filters.paymentKinds.length) {
        params.payment_kinds = this.filters.paymentKinds.join(',');
      }

      if (this.filters.paymentMethods.length) {
        params.payment_methods = this.filters.paymentMethods.join(',');
      }

      if (this.filters.status.length) {
        params.status = this.filters.status.join(',');
      }

      return params;
    },

    async loadAll() {
      this.ui.isLoading = true;
      this.ui.error = null;

      try {
        const params = this.buildQueryParams();
        const [paymentsResponse, expensesResponse, appointmentsResponse] =
          await Promise.all([
            SchedulingPaymentsAPI.get(params),
            SchedulingExpensesAPI.get(params),
            SchedulingAppointmentsAPI.get({
              from: params.from,
              payment_status: 'awaiting_payment,prepaid,paid',
              resource_ids: params.resource_ids,
              status: 'scheduled,confirmed,completed',
              to: params.to,
            }),
          ]);

        this.payments = normalizePayload(paymentsResponse.data);
        this.expenses = normalizePayload(expensesResponse.data);
        this.appointmentCandidates = normalizePayload(
          appointmentsResponse.data
        );
      } catch (error) {
        this.ui.error = extractSchedulingError(error);
        throw error;
      } finally {
        this.ui.isLoading = false;
      }
    },

    async addPayment({ amount, appointmentId, paymentMethod }) {
      this.ui.isSaving = true;
      this.ui.error = null;

      try {
        await SchedulingPaymentsAPI.addPayment(appointmentId, {
          amount: Number(amount),
          payment_method: paymentMethod,
        });
        await this.loadAll();
      } catch (error) {
        this.ui.error = extractSchedulingError(error);
        throw error;
      } finally {
        this.ui.isSaving = false;
      }
    },

    async cancelPayments(appointmentId) {
      this.ui.isSaving = true;
      this.ui.error = null;

      try {
        await SchedulingPaymentsAPI.cancelPayments(appointmentId);
        await this.loadAll();
      } catch (error) {
        this.ui.error = extractSchedulingError(error);
        throw error;
      } finally {
        this.ui.isSaving = false;
      }
    },

    async payExpense(expenseId) {
      this.ui.isSaving = true;
      this.ui.error = null;

      try {
        await SchedulingExpensesAPI.pay(expenseId);
        await this.loadAll();
      } catch (error) {
        this.ui.error = extractSchedulingError(error);
        throw error;
      } finally {
        this.ui.isSaving = false;
      }
    },

    async payAll() {
      this.ui.isSaving = true;
      this.ui.error = null;

      try {
        const params = this.buildQueryParams();
        await SchedulingExpensesAPI.payAll({
          from: params.from,
          resource_ids: params.resource_ids,
          to: params.to,
        });
        await this.loadAll();
      } catch (error) {
        this.ui.error = extractSchedulingError(error);
        throw error;
      } finally {
        this.ui.isSaving = false;
      }
    },
  },
});
