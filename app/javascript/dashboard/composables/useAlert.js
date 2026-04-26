import { emitter } from 'shared/helpers/mitt';

/**
 * Emits a toast message event using a global emitter.
 * @param {string} message - The message to be displayed in the toast.
 * @param {Object|null} action - Optional callback function or object to execute.
 */
export const useAlert = (message, action = null) => {
  emitter.emit('newToastMessage', { message, action });
};
