<script setup>
// Sample page for design variant A. Demo data only; not part of the app.
import { ref } from 'vue';
import {
  DsCard,
  DsChartFrame,
  DsMeter,
  DsSegmented,
  DsStatGroup,
  DsState,
  DsStatusDot,
  DsTable,
} from 'dashboard/components-next/ds';

const days = Array.from({ length: 14 }, (_, index) =>
  new Date(2026, 8, 22 + index).toLocaleDateString('ru-RU', {
    day: 'numeric',
    month: 'short',
  })
);
const answered = [
  212, 198, 240, 225, 230, 118, 96, 251, 260, 244, 238, 255, 121, 102,
];
const missed = [18, 22, 15, 20, 17, 9, 7, 19, 16, 21, 14, 18, 8, 6];

const period = ref(14);
const periods = [
  { value: 7, label: '7 дней' },
  { value: 14, label: '14 дней' },
  { value: 30, label: '30 дней' },
];

const stats = [
  {
    key: 'accounts',
    label: 'Аккаунтов активно',
    value: '48',
    note: '+2 за месяц',
  },
  {
    key: 'calls',
    label: 'Звонков за 14 дней',
    value: '2 944',
    note: 'на 6% больше прошлых',
  },
  { key: 'missed', label: 'Пропущенных', value: '4,7%', note: 'было 6,1%' },
  {
    key: 'storage',
    label: 'Занято места',
    value: '412 ГБ',
    note: 'из 600 ГБ по тарифам',
  },
];

const attention = [
  { account: 'Intermedical', text: 'Хранилище 88% от тарифа', status: 'warn' },
  {
    account: 'Oasis Academy',
    text: 'Телефон не зарегистрирован 3 ч',
    status: 'bad',
  },
  { account: 'МО «Әлия»', text: 'Пропущенных 5,8% за неделю', status: 'warn' },
  { account: 'MRT Comfort', text: 'Все проверки пройдены', status: 'good' },
];

const columns = [
  { key: 'name', label: 'Аккаунт' },
  { key: 'calls', label: 'Звонков', numeric: true },
  { key: 'missed', label: 'Пропущено', numeric: true },
  { key: 'storage', label: 'Хранилище' },
  { key: 'status', label: 'Состояние' },
];
const accounts = [
  {
    id: 1,
    name: 'SEZIM | Байтурсынова 4/1',
    calls: '1 840',
    missed: '3,1%',
    storage: 42,
    status: 'good',
  },
  {
    id: 2,
    name: 'МО «Әлия»',
    calls: '1 215',
    missed: '5,8%',
    storage: 71,
    status: 'warn',
  },
  {
    id: 3,
    name: 'Intermedical',
    calls: '960',
    missed: '2,2%',
    storage: 88,
    status: 'warn',
  },
  {
    id: 4,
    name: 'MRT Comfort',
    calls: '402',
    missed: '1,4%',
    storage: 19,
    status: 'good',
  },
  {
    id: 5,
    name: 'Oasis Academy',
    calls: '277',
    missed: '7,9%',
    storage: 97,
    status: 'bad',
  },
];

const funnelStages = [
  'Новые обращения',
  'В работе',
  'Записаны',
  'Пришли на приём',
  'Оплачено',
];
const funnel = [
  { key: 'clients', label: 'Клиенты', values: [420, 318, 207, 164, 121] },
];

const navigation = ['Обзор', 'Аккаунты', 'Телефония', 'Хранилище', 'Журнал'];

// The same content as plain ERB markup with the super admin .ds-* classes.
const erbStats = [
  { label: 'Аккаунтов', value: '48', note: '+2 за месяц' },
  { label: 'Ошибок за сутки', value: '3', note: 'было 5' },
  { label: 'Релиз', value: 'E', note: '5 октября' },
];
const erbRows = [
  {
    name: 'Intermedical',
    calls: '960',
    storage: 88,
    meter: 'ds-meter--warn',
    status: 'ds-status--warn',
    word: 'Внимание',
  },
  {
    name: 'Oasis Academy',
    calls: '277',
    storage: 97,
    meter: 'ds-meter--bad',
    status: 'ds-status--bad',
    word: 'Ошибка',
  },
  {
    name: 'MRT Comfort',
    calls: '402',
    storage: 19,
    meter: '',
    status: 'ds-status--good',
    word: 'В норме',
  },
];
</script>

<template>
  <!-- Demo page: fixed Russian sample texts, not app UI -->
  <!-- eslint-disable vue/no-bare-strings-in-template, @intlify/vue-i18n/no-raw-text -->
  <div
    class="grid min-h-screen grid-cols-[200px_minmax(0,1fr)] bg-n-background text-sm text-n-slate-12"
  >
    <aside
      class="border-0 border-e border-solid border-n-weak px-3.5 py-[18px]"
    >
      <div class="px-2 pb-4 pt-1 font-semibold tracking-[-0.01em]">OneLink</div>
      <a
        v-for="(item, index) in navigation"
        :key="item"
        href="#"
        class="block rounded-ds-control px-2.5 py-[7px] no-underline"
        :class="
          index === 0 ? 'bg-n-slate-3 text-n-slate-12' : 'text-n-slate-11'
        "
      >
        {{ item }}
      </a>
      <div
        class="px-2.5 pb-1 pt-3.5 text-[11px] uppercase tracking-[0.06em] text-n-slate-11"
      >
        Система
      </div>
      <a
        href="#"
        class="block rounded-ds-control px-2.5 py-[7px] text-n-slate-11 no-underline"
      >
        Настройки
      </a>
    </aside>

    <main class="flex min-w-0 flex-col gap-3.5 px-[26px] pb-8 pt-[22px]">
      <div class="mb-1.5 flex flex-wrap items-center gap-3.5">
        <h1 class="m-0 text-xl font-semibold tracking-[-0.02em]">Обзор</h1>
        <DsSegmented
          v-model="period"
          :options="periods"
          label="Период"
          class="ms-auto"
        />
      </div>

      <DsStatGroup :items="stats" />

      <div class="grid gap-3.5 lg:grid-cols-[minmax(0,1.9fr)_minmax(0,1fr)]">
        <DsChartFrame
          title="Звонки"
          subtitle="принятые по дням"
          :labels="days"
          :series="[{ key: 'answered', label: 'Принятые', values: answered }]"
          :secondary="{ key: 'missed', label: 'Пропущенные', values: missed }"
          category-label="День"
        />
        <DsCard title="Требуют внимания">
          <ul class="reset-base m-0 list-none p-0">
            <li
              v-for="item in attention"
              :key="item.account"
              class="grid grid-cols-[minmax(0,1fr)_auto] gap-x-2.5 gap-y-0.5 border-0 border-t border-solid border-n-weak py-2.5 first:border-t-0 first:pt-0.5"
            >
              <span class="font-medium">{{ item.account }}</span>
              <DsStatusDot
                :status="item.status"
                class="row-span-2 self-center"
              />
              <span class="text-ds-caption text-n-slate-11">{{
                item.text
              }}</span>
            </li>
          </ul>
        </DsCard>
      </div>

      <DsCard title="Аккаунты" subtitle="здоровье за неделю" :padded="false">
        <DsTable :columns="columns" :rows="accounts" caption="Аккаунты">
          <template #cell-storage="{ value }">
            <DsMeter
              :value="value"
              tone="auto"
              class="w-36"
              label="Хранилище"
            />
          </template>
          <template #cell-status="{ value }">
            <DsStatusDot :status="value" />
          </template>
        </DsTable>
      </DsCard>

      <DsChartFrame
        kind="bars"
        title="Отчёт: путь клиента"
        subtitle="МО «Әлия», 14 дней"
        :labels="funnelStages"
        :series="funnel"
      />

      <div class="grid gap-3.5 md:grid-cols-3">
        <DsCard title="Пусто"><DsState state="empty" compact /></DsCard>
        <DsCard title="Загрузка"><DsState state="loading" compact /></DsCard>
        <DsCard title="Ошибка"><DsState state="error" compact /></DsCard>
      </div>

      <section class="ds-card">
        <header class="ds-card__header">
          <h3 class="ds-card__title">Суперадминка: классы .ds-* для ERB</h3>
          <span class="ds-card__subtitle">
            та же разметка в светлой и тёмной теме
          </span>
        </header>
        <div class="ds-card__body flex flex-col gap-3.5">
          <div>
            <nav class="ds-segmented" aria-label="Период">
              <a
                v-for="option in periods"
                :key="option.value"
                href="#"
                :aria-current="option.value === 14 ? 'page' : undefined"
              >
                {{ option.label }}
              </a>
            </nav>
          </div>
          <dl class="ds-stat-group">
            <div v-for="stat in erbStats" :key="stat.label" class="ds-stat">
              <dt class="ds-stat__label">{{ stat.label }}</dt>
              <dd class="ds-stat__value">{{ stat.value }}</dd>
              <dd class="ds-stat__note">{{ stat.note }}</dd>
            </div>
          </dl>
          <table class="ds-table">
            <thead>
              <tr>
                <th>Аккаунт</th>
                <th class="ds-num">Звонков</th>
                <th>Хранилище</th>
                <th>Состояние</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="row in erbRows" :key="row.name">
                <td>{{ row.name }}</td>
                <td class="ds-num">{{ row.calls }}</td>
                <td>
                  <span class="ds-meter" :class="row.meter">
                    <span
                      class="ds-meter__fill"
                      :style="{ width: `${row.storage}%` }"
                    />
                  </span>
                </td>
                <td>
                  <span class="ds-status" :class="row.status">
                    {{ row.word }}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </main>
  </div>
</template>
