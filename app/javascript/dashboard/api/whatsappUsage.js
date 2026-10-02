/* global axios */

const getMonthlyUsage = accountId =>
  axios.get(`/api/v1/accounts/${accountId}/whatsapp_usage`);

export default {
  getMonthlyUsage,
};
