<script setup>
import { ref, computed } from 'vue';
import BarChart from 'shared/components/charts/BarChart.vue';

const props = defineProps({
  componentData: {
    type: Object,
    default: () => ({}),
  },
});

const searchQuery = ref('');
const onlyNeedsAttention = ref(false);
const showChart = ref(false);
const isRefreshing = ref(false);

const healthAccounts = computed(() => {
  return props.componentData.healthAccounts || [];
});

const healthSummary = computed(() => {
  return props.componentData.healthSummary || {
    total_accounts: 0,
    needs_attention: 0,
    whatsapp_healthy: 0,
    telephony_healthy: 0,
    git_sha: '93611c27',
    updated_at: '',
  };
});

const filteredAccounts = computed(() => {
  return healthAccounts.value.filter(account => {
    const query = searchQuery.value.toLowerCase().trim();
    const matchesSearch =
      !query ||
      account.name.toLowerCase().includes(query) ||
      account.id.toString().includes(query);

    if (onlyNeedsAttention.value) {
      return matchesSearch && account.needs_attention;
    }
    return matchesSearch;
  });
});

const prepareData = sourceData => {
  const labels = [];
  const data = [];
  (sourceData || []).forEach(item => {
    labels.push(item[0]);
    data.push(item[1]);
  });
  return {
    labels,
    datasets: [
      {
        type: 'bar',
        backgroundColor: 'rgb(31, 147, 255)',
        yAxisID: 'y',
        label: 'Обращения',
        data: data,
      },
    ],
  };
};

const chartData = computed(() => {
  return prepareData(props.componentData.chartData);
});

const getStatusBadge = status => {
  if (!status) return { text: '—', class: 'bg-slate-100 text-slate-500' };
  switch (status.state) {
    case 'healthy':
      return { text: status.label, class: 'bg-emerald-100 text-emerald-800 border-emerald-200' };
    case 'warning':
      return { text: status.label, class: 'bg-amber-100 text-amber-800 border-amber-200' };
    case 'error':
      return { text: status.label, class: 'bg-rose-100 text-rose-800 border-rose-200 font-bold' };
    default:
      return { text: status.label, class: 'bg-slate-100 text-slate-500 border-slate-200' };
  }
};

const refreshData = () => {
  isRefreshing.value = true;
  window.location.href = '/super_admin?refresh=true';
};
</script>

<template>
  <div class="w-full h-full p-6 bg-slate-50/50">
    <!-- Header -->
    <header class="mb-6 flex flex-wrap items-center justify-between gap-4">
      <div>
        <h1 class="text-2xl font-bold text-slate-900 tracking-tight">
          Матрица здоровья клиентов (OneLink Health Matrix)
        </h1>
        <p class="text-sm text-slate-500 mt-1">
          Диагностика WhatsApp, телефонии, шлюзов Janus и интеграции МИС МедЭлемент в реальном времени
        </p>
      </div>

      <div class="flex items-center gap-2">
        <span
          v-if="healthSummary.updated_at"
          class="text-xs text-slate-400 font-mono mr-1"
        >
          Обновлено: {{ healthSummary.updated_at }}
        </span>

        <button
          class="px-3.5 py-1.5 text-xs font-medium rounded-lg border border-slate-300 bg-white text-slate-700 hover:bg-slate-50 transition shadow-sm flex items-center gap-1.5"
          :disabled="isRefreshing"
          @click="refreshData"
        >
          <span :class="{ 'animate-spin': isRefreshing }">🔄</span>
          <span>Обновить</span>
        </button>

        <button
          class="px-3.5 py-1.5 text-xs font-medium rounded-lg border border-slate-300 bg-white text-slate-700 hover:bg-slate-50 transition shadow-sm"
          @click="showChart = !showChart"
        >
          {{ showChart ? 'Скрыть график обращений' : 'Показать график обращений' }}
        </button>
      </div>
    </header>

    <!-- KPI Summary Cards -->
    <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-6">
      <div class="bg-white p-5 rounded-xl border border-slate-200 shadow-sm flex flex-col justify-between">
        <span class="text-xs font-semibold text-slate-500 uppercase tracking-wider">Всего клиник</span>
        <div class="text-3xl font-extrabold text-slate-900 mt-2">
          {{ healthSummary.total_accounts }}
        </div>
        <span class="text-[11px] text-slate-400 mt-1">зарегистрировано в системе</span>
      </div>

      <div
        class="p-5 rounded-xl border shadow-sm flex flex-col justify-between cursor-pointer transition"
        :class="healthSummary.needs_attention > 0 ? 'bg-rose-50/80 border-rose-200 hover:bg-rose-100/70' : 'bg-white border-slate-200'"
        @click="onlyNeedsAttention = !onlyNeedsAttention"
      >
        <div class="flex items-center justify-between">
          <span class="text-xs font-semibold text-rose-700 uppercase tracking-wider">Требуют внимания</span>
          <span v-if="healthSummary.needs_attention > 0" class="inline-block w-2.5 h-2.5 rounded-full bg-rose-500 animate-ping" />
        </div>
        <div class="text-3xl font-extrabold text-rose-700 mt-2">
          {{ healthSummary.needs_attention }}
        </div>
        <span class="text-[11px] text-rose-600 mt-1 font-medium">
          {{ onlyNeedsAttention ? 'Фильтр активен (нажмите для сброса)' : 'Сбой WhatsApp, Janus или зависшие сообщения' }}
        </span>
      </div>

      <div class="bg-white p-5 rounded-xl border border-slate-200 shadow-sm flex flex-col justify-between">
        <span class="text-xs font-semibold text-slate-500 uppercase tracking-wider">WhatsApp в норме</span>
        <div class="text-3xl font-extrabold text-emerald-600 mt-2">
          {{ healthSummary.whatsapp_healthy }}
        </div>
        <span class="text-[11px] text-slate-400 mt-1">линии с действующей сессией</span>
      </div>

      <div class="bg-white p-5 rounded-xl border border-slate-200 shadow-sm flex flex-col justify-between">
        <span class="text-xs font-semibold text-slate-500 uppercase tracking-wider">Телефония OK</span>
        <div class="text-3xl font-extrabold text-blue-600 mt-2">
          {{ healthSummary.telephony_healthy }}
        </div>
        <span class="text-[11px] text-slate-400 mt-1">линии с привязкой и Janus</span>
      </div>
    </div>

    <!-- Filter & Search Toolbar -->
    <div class="bg-white p-4 rounded-xl border border-slate-200 shadow-sm mb-6 flex flex-wrap items-center justify-between gap-4">
      <div class="flex items-center gap-3 flex-1 min-w-[280px]">
        <div class="relative w-full max-w-md">
          <input
            v-model="searchQuery"
            type="text"
            placeholder="Поиск клиники по названию или ID..."
            class="w-full pl-3 pr-4 py-2 text-sm border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
          />
        </div>

        <button
          class="px-4 py-2 text-xs font-semibold rounded-lg border transition flex items-center gap-1.5"
          :class="onlyNeedsAttention ? 'bg-rose-600 text-white border-rose-600 shadow-sm' : 'bg-slate-100 text-slate-700 border-slate-200 hover:bg-slate-200'"
          @click="onlyNeedsAttention = !onlyNeedsAttention"
        >
          <span>⚠️</span>
          <span>{{ onlyNeedsAttention ? 'Показаны только с проблемами' : 'Фильтр: только с проблемами' }}</span>
        </button>
      </div>

      <div class="text-xs text-slate-500 font-medium">
        Отображается: {{ filteredAccounts.length }} из {{ healthAccounts.length }}
      </div>
    </div>

    <!-- Health Matrix Table -->
    <div class="bg-white rounded-xl border border-slate-200 shadow-sm overflow-hidden mb-8">
      <table class="w-full text-left text-sm">
        <thead class="bg-slate-100/75 text-slate-600 text-xs uppercase font-semibold border-b border-slate-200">
          <tr>
            <th class="px-5 py-3.5">ID / Клиника</th>
            <th class="px-4 py-3.5">WhatsApp</th>
            <th class="px-4 py-3.5">Телефония & Janus</th>
            <th class="px-4 py-3.5">МедЭлемент (МИС)</th>
            <th class="px-4 py-3.5">Зависшие сообщения</th>
            <th class="px-4 py-3.5 text-right">Действия</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-slate-100">
          <tr
            v-for="acc in filteredAccounts"
            :key="acc.id"
            class="hover:bg-slate-50/80 transition-colors"
            :class="acc.needs_attention ? 'bg-rose-50/20' : ''"
          >
            <!-- Clinic Info -->
            <td class="px-5 py-4">
              <div class="flex items-center gap-2">
                <span class="font-mono text-xs text-slate-400">#{{ acc.id }}</span>
                <a
                  :href="`/super_admin/accounts/${acc.id}`"
                  class="font-semibold text-slate-900 hover:text-indigo-600 hover:underline"
                >
                  {{ acc.name }}
                </a>
                <span
                  v-if="acc.status === 'suspended'"
                  class="text-[10px] uppercase font-bold px-1.5 py-0.5 rounded bg-slate-200 text-slate-700"
                >
                  Приостановлен
                </span>
              </div>
            </td>

            <!-- WhatsApp -->
            <td class="px-4 py-4">
              <span
                class="inline-flex items-center px-2.5 py-1 rounded-full text-xs font-medium border"
                :class="getStatusBadge(acc.whatsapp).class"
              >
                {{ getStatusBadge(acc.whatsapp).text }}
              </span>
            </td>

            <!-- Telephony & Janus -->
            <td class="px-4 py-4">
              <span
                class="inline-flex items-center px-2.5 py-1 rounded-full text-xs font-medium border"
                :class="getStatusBadge(acc.telephony).class"
              >
                {{ getStatusBadge(acc.telephony).text }}
              </span>
            </td>

            <!-- MedElement -->
            <td class="px-4 py-4">
              <span
                class="inline-flex items-center px-2.5 py-1 rounded-full text-xs font-medium border"
                :class="getStatusBadge(acc.medelement).class"
              >
                {{ getStatusBadge(acc.medelement).text }}
              </span>
            </td>

            <!-- Stuck Messages -->
            <td class="px-4 py-4">
              <span
                v-if="acc.failed_messages > 0"
                class="inline-flex items-center px-2.5 py-1 rounded-full text-xs font-bold bg-rose-100 text-rose-800 border border-rose-200"
              >
                ⚠️ {{ acc.failed_messages }} застрявших
              </span>
              <span v-else class="text-xs text-slate-400">0</span>
            </td>

            <!-- Action -->
            <td class="px-4 py-4 text-right">
              <a
                :href="`/super_admin/accounts/${acc.id}`"
                class="text-xs font-medium text-indigo-600 hover:text-indigo-800 hover:underline"
              >
                Настройки →
              </a>
            </td>
          </tr>

          <tr v-if="filteredAccounts.length === 0">
            <td colspan="6" class="px-5 py-12 text-center text-slate-400">
              <div class="text-lg">Клиник не найдено</div>
              <p class="text-xs mt-1">Попробуйте изменить поисковый запрос или сбросить фильтр проблем</p>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <!-- Collapsible Chart -->
    <div v-if="showChart" class="bg-white p-6 rounded-xl border border-slate-200 shadow-sm mb-6">
      <h2 class="text-base font-bold text-slate-900 mb-4">График обращений за 30 дней</h2>
      <BarChart
        class="w-full"
        :collection="chartData"
        style="max-height: 400px"
      />
    </div>
  </div>
</template>
