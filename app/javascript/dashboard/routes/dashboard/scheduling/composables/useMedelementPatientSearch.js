import { computed, onBeforeUnmount, ref } from 'vue';
import { isValidPatientIin } from 'dashboard/stores/scheduling/iin';
import { isKazakhstanE164Phone } from 'dashboard/stores/scheduling/appointmentForm';

const cleanPatientSearchText = raw =>
  String(raw || '')
    .normalize('NFC')
    .replace(/\s+/gu, ' ')
    .replace(/[\p{Cc}\p{Cf}]/gu, '')
    .trim()
    .slice(0, 200)
    .trim();

export const patientSearchKind = raw => {
  const text = cleanPatientSearchText(raw);
  const digits = text.replace(/[\s-]/g, '');
  if (/^[\d\s-]+$/.test(text) && /^\d{12}$/.test(digits)) {
    return isValidPatientIin(digits) ? 'iin' : '';
  }
  if (/^[\d+()\-\s]+$/.test(text)) {
    return isKazakhstanE164Phone(text) ? 'phone' : '';
  }
  if (!/^\p{L}+(?: \p{L}+){0,2}$/u.test(text)) return '';
  const words = text.split(' ');
  return words.every(word => word.length >= 2) &&
    words.some(word => word.length >= 3)
    ? 'name'
    : '';
};

export const useMedelementPatientSearch = ({
  enabled,
  search,
  importPatient,
  onImported,
}) => {
  const patients = ref([]);
  const loading = ref(false);
  const error = ref(false);
  const importError = ref(false);
  const hint = ref('');
  const truncated = ref(false);
  const busyToken = ref('');
  const status = ref('hint');
  let timer;
  let controller;
  let generation = 0;
  let lastQuery = '';

  const clear = () => {
    generation += 1;
    clearTimeout(timer);
    controller?.abort();
    controller = null;
    patients.value = [];
    loading.value = false;
    error.value = false;
    importError.value = false;
    hint.value = '';
    truncated.value = false;
    lastQuery = '';
    status.value = 'hint';
  };

  const query = raw => {
    const text = cleanPatientSearchText(raw);
    if (!enabled.value || !patientSearchKind(text)) {
      clear();
      const digits = text.replace(/[\s-]/g, '');
      if (
        enabled.value &&
        /^[\d\s-]+$/.test(text) &&
        /^\d{12}$/.test(digits) &&
        !isValidPatientIin(digits)
      ) {
        hint.value = 'invalid_iin';
      }
      return;
    }
    if (text === lastQuery) return;
    lastQuery = text;
    generation += 1;
    const requestGeneration = generation;
    clearTimeout(timer);
    controller?.abort();
    controller = null;
    patients.value = [];
    error.value = false;
    importError.value = false;
    hint.value = '';
    truncated.value = false;
    loading.value = true;
    status.value = 'searching';
    timer = setTimeout(async () => {
      controller = new AbortController();
      try {
        const result = await search(text, controller.signal);
        if (requestGeneration !== generation) return;
        patients.value = result.patients || [];
        truncated.value = Boolean(result.truncated);
        if (result.reason) status.value = 'hint';
        else status.value = patients.value.length ? 'found' : 'empty';
      } catch (requestError) {
        if (
          requestGeneration === generation &&
          requestError?.code !== 'ERR_CANCELED'
        ) {
          error.value = true;
          status.value = 'error';
        }
      } finally {
        if (requestGeneration === generation) {
          loading.value = false;
          controller = null;
        }
      }
    }, 400);
  };

  const retry = () => {
    const text = lastQuery;
    lastQuery = '';
    if (text) query(text);
  };

  const select = async patient => {
    if (busyToken.value) return;
    busyToken.value = patient.token;
    error.value = false;
    importError.value = false;
    try {
      const contact = await importPatient(patient.token);
      onImported(contact);
      clear();
    } catch {
      importError.value = true;
      patients.value = [];
      status.value = 'error';
    } finally {
      busyToken.value = '';
    }
  };

  onBeforeUnmount(clear);
  return {
    patients,
    loading,
    error,
    importError,
    hint,
    truncated,
    busyToken,
    status,
    clear,
    query,
    retry,
    select,
    visible: computed(
      () =>
        loading.value ||
        error.value ||
        importError.value ||
        hint.value ||
        patients.value.length > 0 ||
        truncated.value
    ),
  };
};
