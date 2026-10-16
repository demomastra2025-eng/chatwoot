// Pure logic of the «Сводка» page (app/javascript/superadmin_pages/views/dashboard/Index.vue).
// The server sends one row per clinic (SuperAdmin::HealthMatrixService); everything here only
// decides what to show, so it is covered by a plain unit spec.

// The state of a line as the service names it -> the tone of a DsStatusDot.
const STATUS_TONES = { healthy: 'good', warning: 'warn', error: 'bad' };

export const statusTone = state => STATUS_TONES[state] || 'neutral';

// «Поиск по названию или номеру» + the switch «только требующие внимания».
export const filterAccounts = (
  accounts,
  { query = '', onlyNeedsAttention = false } = {}
) => {
  const needle = String(query).toLowerCase().trim();
  return (accounts || []).filter(account => {
    const matches =
      !needle ||
      String(account.name || '')
        .toLowerCase()
        .includes(needle) ||
      String(account.id).includes(needle);
    return matches && (!onlyNeedsAttention || !!account.needs_attention);
  });
};

// «2026-09-16» -> «16.09». The server groups the conversations by calendar day and sends the day as a
// date string, so the label is cut from the string: no time zone is involved and no day can shift.
export const dayLabel = day => {
  const match = String(day).match(/^(\d{4})-(\d{2})-(\d{2})/);
  return match ? `${match[3]}.${match[2]}` : String(day);
};

// [[day, count], ...] -> the labels and the values of the chart
export const chartSeries = rows => {
  const pairs = Array.isArray(rows) ? rows : [];
  return {
    labels: pairs.map(([day]) => dayLabel(day)),
    values: pairs.map(([, count]) => Number(count) || 0),
  };
};
