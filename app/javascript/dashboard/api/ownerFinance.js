/* global axios */

const BASE_PATH = '/api/v1/owner_finance';

export default {
  getDashboard({ year, month } = {}) {
    return axios.get(`${BASE_PATH}/dashboard`, {
      params: { year, month },
    });
  },

  createAccount(account) {
    return axios.post(`${BASE_PATH}/accounts`, { account });
  },

  updateAccount(id, account) {
    return axios.patch(`${BASE_PATH}/accounts/${id}`, { account });
  },

  deleteAccount(id) {
    return axios.delete(`${BASE_PATH}/accounts/${id}`);
  },

  createDeadline(deadline) {
    return axios.post(`${BASE_PATH}/deadlines`, { deadline });
  },

  updateDeadline(id, deadline) {
    return axios.patch(`${BASE_PATH}/deadlines/${id}`, { deadline });
  },

  deleteDeadline(id) {
    return axios.delete(`${BASE_PATH}/deadlines/${id}`);
  },

  completeDeadline(id) {
    return axios.post(`${BASE_PATH}/deadlines/${id}/complete`);
  },

  runDeadlineReminders() {
    return axios.post(`${BASE_PATH}/deadlines/run_reminders`);
  },

  createTransaction(transaction, { learnVendor = false } = {}) {
    return axios.post(`${BASE_PATH}/transactions`, {
      transaction,
      learn_vendor: learnVendor,
    });
  },

  updateTransaction(id, transaction, options = {}) {
    const payload = { transaction };
    if (typeof options.learnVendor === 'boolean') {
      payload.learn_vendor = options.learnVendor;
    }
    return axios.patch(`${BASE_PATH}/transactions/${id}`, payload);
  },

  deleteTransaction(id) {
    return axios.delete(`${BASE_PATH}/transactions/${id}`);
  },

  hidePersonalTransaction(id, { hideMerchantAlways = false } = {}) {
    return axios.post(`${BASE_PATH}/transactions/${id}/hide_personal`, {
      hide_merchant_always: hideMerchantAlways,
    });
  },

  importStatement(file, { accountRecordId = null } = {}) {
    const formData = new FormData();
    formData.append('file', file);
    if (accountRecordId) {
      formData.append('account_record_id', String(accountRecordId));
    }
    return axios.post(`${BASE_PATH}/statements/import`, formData, {
      headers: { 'Content-Type': 'multipart/form-data' },
    });
  },

  createContract(contract) {
    return axios.post(`${BASE_PATH}/contracts`, { contract });
  },

  updateContract(id, contract) {
    return axios.patch(`${BASE_PATH}/contracts/${id}`, { contract });
  },

  deleteContract(id) {
    return axios.delete(`${BASE_PATH}/contracts/${id}`);
  },

  createObligation(obligation) {
    return axios.post(`${BASE_PATH}/obligations`, { obligation });
  },

  updateObligation(id, obligation) {
    return axios.patch(`${BASE_PATH}/obligations/${id}`, { obligation });
  },

  deleteObligation(id) {
    return axios.delete(`${BASE_PATH}/obligations/${id}`);
  },

  syncOnecFresh({ daysBack = 45 } = {}) {
    return axios.post(`${BASE_PATH}/onec_sync`, { days_back: daysBack });
  },
};
