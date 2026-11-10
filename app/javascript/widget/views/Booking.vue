<script>
import { useRouter } from 'vue-router';
import BookingAPI from '../api/booking';
import configMixin from '../mixins/configMixin';

export default {
  name: 'WidgetBooking',
  mixins: [configMixin],
  setup() {
    const router = useRouter();
    return { router };
  },
  data() {
    return {
      isLoadingConfig: true,
      isLoadingSlots: false,
      isSubmitting: false,
      step: 1,
      errorMessage: '',
      nearestDateSuggestion: null,
      config: {
        enabled: false,
        clinic_preset: 'default',
        clinic_title: '',
        specialist_label: 'Специалист',
        service_label: 'Услуга',
        confirm_cta: 'Подтвердить запись',
        notes_helper: '',
        show_visit_reason: false,
        visit_reasons: [],
        default_visit_reason: '',
        services: [],
        specialists: [],
        dates: [],
        field_flags: {},
        prefill: {},
        whatsapp_phone: null,
      },
      form: {
        service_id: '',
        resource_id: 'any',
        booking_date: '',
        slot_key: '',
        visit_reason: '',
        client_first_name: '',
        client_last_name: '',
        client_middle_name: '',
        client_phone: '',
        client_birth_date: '',
        client_iin: '',
        notes: '',
      },
      slots: [],
      selectedSlotObj: null,
      confirmedResult: null,
    };
  },
  computed: {
    filteredSpecialists() {
      const all = this.config.specialists || [];
      if (!this.form.service_id) return all;
      const selectedSvc = (this.config.services || []).find(
        s => String(s.id) === String(this.form.service_id)
      );
      if (!selectedSvc || !selectedSvc.resource_ids?.length) return all;
      return all.filter(sp =>
        selectedSvc.resource_ids.includes(String(sp.id))
      );
    },
    filteredDates() {
      const allDates = this.config.dates || [];
      if (!this.form.resource_id || this.form.resource_id === 'any') {
        return allDates;
      }
      const sp = (this.config.specialists || []).find(
        item => String(item.id) === String(this.form.resource_id)
      );
      if (!sp || !Array.isArray(sp.available_dates) || !sp.available_dates.length) {
        return allDates;
      }
      return allDates.filter(d => sp.available_dates.includes(d.id));
    },
    selectedServiceName() {
      const svc = (this.config.services || []).find(
        s => String(s.id) === String(this.form.service_id)
      );
      return svc ? svc.name : '';
    },
    selectedDateLabel() {
      const d = (this.config.dates || []).find(
        item => item.id === this.form.booking_date
      );
      return d ? d.label : this.form.booking_date;
    },
    brandColor() {
      return this.widgetColor || '#1f93ff';
    },
  },
  async mounted() {
    await this.loadBookingConfig();
  },
  methods: {
    async loadBookingConfig() {
      this.isLoadingConfig = true;
      this.errorMessage = '';
      try {
        const { data } = await BookingAPI.getConfig();
        this.config = { ...this.config, ...data };
        if (data.enabled) {
          this.form.booking_date = data.dates?.[0]?.id || '';
          this.form.visit_reason =
            data.prefill?.init_visit_reason || data.default_visit_reason || '';
          this.form.client_first_name = data.prefill?.init_first_name || '';
          this.form.client_last_name = data.prefill?.init_last_name || '';
          this.form.client_middle_name = data.prefill?.init_middle_name || '';
          this.form.client_phone = data.prefill?.init_phone || '';
          this.form.client_birth_date = data.prefill?.init_birth_date || '';
          this.form.client_iin = data.prefill?.init_iin || '';
          await this.fetchSlots();
        }
      } catch {
        this.errorMessage = 'Не удалось загрузить расписание врачей.';
      } finally {
        this.isLoadingConfig = false;
      }
    },
    async onSelectionChange() {
      if (
        this.form.resource_id !== 'any' &&
        !this.filteredSpecialists.some(
          sp => String(sp.id) === String(this.form.resource_id)
        )
      ) {
        this.form.resource_id = 'any';
      }
      await this.onSpecialistChange();
    },
    async onSpecialistChange() {
      const validDates = this.filteredDates;
      if (
        validDates.length &&
        !validDates.some(d => d.id === this.form.booking_date)
      ) {
        this.form.booking_date = validDates[0].id;
      }
      await this.fetchSlots();
    },
    async fetchSlots() {
      if (!this.form.booking_date) return;
      this.isLoadingSlots = true;
      this.errorMessage = '';
      this.nearestDateSuggestion = null;
      this.form.slot_key = '';
      this.selectedSlotObj = null;
      try {
        const { data } = await BookingAPI.getSlots({
          service_id: this.form.service_id || 'none',
          resource_id: this.form.resource_id || 'any',
          booking_date: this.form.booking_date,
        });
        if (data.booking_date && data.booking_date !== this.form.booking_date) {
          this.form.booking_date = data.booking_date;
        }
        this.slots = data.slots || [];
        if (!this.slots.length && data.nearest_date) {
          this.nearestDateSuggestion = {
            date: data.nearest_date,
            label: data.nearest_date_label || data.nearest_date,
          };
        }
      } catch {
        this.slots = [];
      } finally {
        this.isLoadingSlots = false;
      }
    },
    async applyNearestDate() {
      if (!this.nearestDateSuggestion?.date) return;
      this.form.booking_date = this.nearestDateSuggestion.date;
      await this.fetchSlots();
    },
    selectSlot(slot) {
      this.form.slot_key = slot.key;
      this.selectedSlotObj = slot;
      this.errorMessage = '';
      this.step = 2;
    },
    async submitBooking() {
      if (!this.form.slot_key) {
        this.errorMessage = 'Пожалуйста, выберите удобное время.';
        return;
      }
      this.isSubmitting = true;
      this.errorMessage = '';
      try {
        const { data } = await BookingAPI.createBooking(this.form);
        this.confirmedResult = data;
        this.step = 3;
      } catch (error) {
        const errData = error?.response?.data || {};
        this.errorMessage =
          errData.error || 'Не удалось создать запись. Проверьте данные.';
        if (errData.code === 'SLOT_TAKEN') {
          this.step = 1;
          await this.fetchSlots();
        }
      } finally {
        this.isSubmitting = false;
      }
    },
    openChat() {
      this.router.replace({ name: 'messages' });
    },
  },
};
</script>

<template>
  <div class="flex flex-1 flex-col overflow-y-auto px-4 py-3 text-n-slate-12">
    <div v-if="isLoadingConfig" class="flex flex-1 items-center justify-center py-12">
      <span class="text-sm text-n-slate-11">Загрузка расписания...</span>
    </div>

    <div
      v-else-if="!config.enabled"
      class="flex flex-1 flex-col items-center justify-center gap-3 py-10 text-center"
    >
      <p class="text-sm text-n-slate-11">
        Онлайн-запись временно недоступна. Напишите нам в чат, и мы подберём время.
      </p>
      <button
        type="button"
        class="rounded-xl px-4 py-2 text-sm font-medium text-white"
        :style="{ backgroundColor: brandColor }"
        @click="openChat"
      >
        Написать в чат
      </button>
    </div>

    <!-- STEP 1: Choose Specialist, Date & Time Slot -->
    <div v-else-if="step === 1" class="flex flex-col gap-3.5">
      <div class="rounded-xl border border-n-weak bg-n-solid-2 p-3.5 shadow-sm">
        <div class="mb-2.5 flex items-center justify-between">
          <h3 class="m-0 text-sm font-semibold text-n-slate-12">
            Онлайн-запись {{ config.clinic_title ? `• ${config.clinic_title}` : '' }}
          </h3>
          <span class="rounded-full bg-n-teal-9/10 px-2 py-0.5 text-[11px] font-medium text-n-teal-11">
            Свободные окна
          </span>
        </div>

        <div class="flex flex-col gap-2.5">
          <label class="flex flex-col gap-1 text-xs font-medium text-n-slate-11">
            <span>{{ config.specialist_label }}</span>
            <select
              v-model="form.resource_id"
              data-testid="widget-booking-specialist"
              class="w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-2 text-xs text-n-slate-12"
              @change="onSpecialistChange"
            >
              <option value="any">Любой свободный специалист</option>
              <option
                v-for="sp in filteredSpecialists"
                :key="sp.id"
                :value="sp.id"
              >
                {{ sp.name }}{{ sp.specialty ? ` — ${sp.specialty}` : '' }}
              </option>
            </select>
          </label>

          <label class="flex flex-col gap-1 text-xs font-medium text-n-slate-11">
            <span>Доступные даты приёма</span>
            <select
              v-model="form.booking_date"
              data-testid="widget-booking-date"
              class="w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-2 text-xs text-n-slate-12"
              @change="fetchSlots"
            >
              <option
                v-for="d in filteredDates"
                :key="d.id"
                :value="d.id"
              >
                {{ d.label }}
              </option>
            </select>
          </label>
        </div>
      </div>

      <div
        v-if="errorMessage"
        class="rounded-lg border border-n-ruby-6 bg-n-ruby-3 px-3 py-2 text-xs text-n-ruby-11"
      >
        {{ errorMessage }}
      </div>

      <div class="rounded-xl border border-n-weak bg-n-solid-2 p-3.5 shadow-sm">
        <p class="mb-2.5 text-xs font-semibold text-n-slate-12">
          Доступное время ({{ selectedDateLabel }}):
        </p>

        <div v-if="isLoadingSlots" class="py-6 text-center text-xs text-n-slate-11">
          Поиск свободного времени...
        </div>

        <div v-else-if="!slots.length" class="flex flex-col items-center gap-2 py-4 text-center">
          <p class="m-0 text-xs text-n-slate-11">
            На выбранную дату все окна уже заняты.
          </p>
          <button
            v-if="nearestDateSuggestion"
            type="button"
            data-testid="widget-booking-nearest-date"
            class="rounded-lg border border-n-weak bg-n-surface-1 px-3 py-1.5 text-xs font-medium text-n-slate-12 hover:bg-n-alpha-2"
            @click="applyNearestDate"
          >
            Перейти на ближайшую дату: {{ nearestDateSuggestion.label }}
          </button>
        </div>

        <div v-else class="grid grid-cols-2 gap-2">
          <button
            v-for="slot in slots"
            :key="slot.key"
            type="button"
            data-testid="widget-booking-slot-btn"
            class="flex flex-col items-start rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-2 text-left transition hover:border-n-brand"
            @click="selectSlot(slot)"
          >
            <span class="text-xs font-semibold text-n-slate-12">
              {{ slot.time_label }}
            </span>
            <span class="w-full truncate text-[11px] text-n-slate-11">
              {{ slot.resource_name }}
            </span>
          </button>
        </div>
      </div>
    </div>

    <!-- STEP 2: Patient Details -->
    <form
      v-else-if="step === 2"
      class="flex flex-col gap-3"
      @submit.prevent="submitBooking"
    >
      <div class="rounded-xl border border-n-weak bg-n-solid-2 p-3.5 shadow-sm">
        <div class="mb-3 flex items-center justify-between gap-2 border-b border-n-weak pb-2.5">
          <div class="min-w-0">
            <p class="m-0 truncate text-xs font-semibold text-n-slate-12">
              {{ selectedSlotObj?.resource_name }}
            </p>
            <p class="m-0 text-[11px] text-n-slate-11">
              {{ selectedDateLabel }} • {{ selectedSlotObj?.time_label }}
            </p>
          </div>
          <button
            type="button"
            class="shrink-0 rounded-md border border-n-weak px-2 py-1 text-[11px] text-n-slate-11 hover:text-n-slate-12"
            @click="step = 1"
          >
            Изменить
          </button>
        </div>

        <div
          v-if="errorMessage"
          class="mb-3 rounded-lg border border-n-ruby-6 bg-n-ruby-3 px-3 py-2 text-xs text-n-ruby-11"
        >
          {{ errorMessage }}
        </div>

        <div class="flex flex-col gap-2.5">
          <label
            v-if="config.show_visit_reason && config.visit_reasons.length"
            class="flex flex-col gap-1 text-xs font-medium text-n-slate-12"
          >
            <span>Повод обращения *</span>
            <select
              v-model="form.visit_reason"
              required
              data-testid="widget-booking-visit-reason"
              class="w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-2 text-xs text-n-slate-12"
            >
              <option
                v-for="reason in config.visit_reasons"
                :key="reason.id"
                :value="reason.id"
              >
                {{ reason.title }} — {{ reason.description }}
              </option>
            </select>
          </label>

          <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
            <label class="flex flex-col gap-1 text-xs font-medium text-n-slate-12">
              <span>Имя *</span>
              <input
                v-model="form.client_first_name"
                type="text"
                required
                data-testid="widget-booking-first-name"
                placeholder="Айгуль"
                class="w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-2 text-xs text-n-slate-12"
              />
            </label>

            <label class="flex flex-col gap-1 text-xs font-medium text-n-slate-12">
              <span>Фамилия {{ config.field_flags.require_last_name ? '*' : '' }}</span>
              <input
                v-model="form.client_last_name"
                type="text"
                :required="config.field_flags.require_last_name"
                data-testid="widget-booking-last-name"
                placeholder="Касымова"
                class="w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-2 text-xs text-n-slate-12"
              />
            </label>
          </div>

          <label class="flex flex-col gap-1 text-xs font-medium text-n-slate-12">
            <span>Телефон (WhatsApp) *</span>
            <input
              v-model="form.client_phone"
              type="tel"
              required
              data-testid="widget-booking-phone"
              placeholder="+7 701 000 00 00"
              class="w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-2 text-xs text-n-slate-12"
            />
          </label>

          <label
            v-if="config.field_flags.show_iin"
            class="flex flex-col gap-1 text-xs font-medium text-n-slate-12"
          >
            <span>ИИН (12 цифр) {{ config.field_flags.require_iin ? '*' : '' }}</span>
            <input
              v-model="form.client_iin"
              type="text"
              maxlength="12"
              :required="config.field_flags.require_iin"
              data-testid="widget-booking-iin"
              placeholder="900101300047"
              class="w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-2 text-xs text-n-slate-12"
            />
          </label>

          <label
            v-if="config.field_flags.show_birth_date"
            class="flex flex-col gap-1 text-xs font-medium text-n-slate-12"
          >
            <span>Дата рождения {{ config.field_flags.require_birth_date ? '*' : '' }}</span>
            <input
              v-model="form.client_birth_date"
              type="text"
              :required="config.field_flags.require_birth_date"
              data-testid="widget-booking-birth-date"
              placeholder="ДД.ММ.ГГГГ"
              class="w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-2 text-xs text-n-slate-12"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs font-medium text-n-slate-12">
            <span>Комментарий</span>
            <textarea
              v-model="form.notes"
              rows="2"
              data-testid="widget-booking-notes"
              :placeholder="config.notes_helper || 'Дополнительная информация для врача или регистратуры'"
              class="w-full rounded-lg border border-n-weak bg-n-surface-1 px-2.5 py-2 text-xs text-n-slate-12"
            />
          </label>
        </div>

        <button
          type="submit"
          data-testid="widget-booking-submit"
          :disabled="isSubmitting"
          class="mt-3.5 w-full rounded-xl px-4 py-2.5 text-xs font-semibold text-white shadow-sm disabled:opacity-60"
          :style="{ backgroundColor: brandColor }"
        >
          {{ isSubmitting ? 'Оформление записи...' : config.confirm_cta }}
        </button>
      </div>
    </form>

    <!-- STEP 3: Confirmed + Inbound-First WhatsApp Ticket Button -->
    <div
      v-else-if="step === 3 && confirmedResult"
      data-testid="widget-booking-success"
      class="flex flex-col gap-3 rounded-xl border border-n-weak bg-n-solid-2 p-4 text-center shadow-sm"
    >
      <div class="mx-auto flex h-10 w-10 items-center justify-center rounded-full bg-n-teal-9/15 text-lg text-n-teal-11">
        ✓
      </div>
      <h3 class="m-0 text-base font-semibold text-n-slate-12">
        Вы успешно записаны!
      </h3>
      <div class="rounded-lg bg-n-alpha-2 p-3 text-left text-xs text-n-slate-12">
        <p class="m-0 font-semibold">
          {{ confirmedResult.appointment.resource_name }}
        </p>
        <p class="m-0 mt-1 font-medium">
          📅 {{ confirmedResult.appointment.date_label }} • {{ confirmedResult.appointment.time_label }}
        </p>
        <p class="m-0 mt-0.5 text-n-slate-11">
          Пациент: {{ confirmedResult.appointment.client_name }} ({{ confirmedResult.appointment.client_phone }})
        </p>
      </div>

      <a
        v-if="confirmedResult.whatsapp_deeplink"
        :href="confirmedResult.whatsapp_deeplink"
        target="_blank"
        rel="noopener noreferrer"
        data-testid="widget-booking-whatsapp-deeplink"
        class="inline-flex w-full items-center justify-center gap-2 rounded-xl bg-[#25D366] px-4 py-2.5 text-xs font-semibold text-white no-underline shadow-sm"
      >
        <span>Получить талон и памятку в WhatsApp</span>
      </a>

      <button
        type="button"
        class="w-full rounded-xl border border-n-weak bg-n-surface-1 px-4 py-2 text-xs font-medium text-n-slate-12"
        @click="openChat"
      >
        Перейти в диалог с клиникой
      </button>
    </div>
  </div>
</template>
