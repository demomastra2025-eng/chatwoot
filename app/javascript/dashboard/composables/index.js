import analyticsHelper from 'dashboard/helper/AnalyticsHelper/index';

export { useAlert } from './useAlert';

/**
 * Custom hook to track events
 */
export const useTrack = (...args) => {
  try {
    return analyticsHelper.track(...args);
  } catch (error) {
    // Ignore this, tracking is not mission critical
  }

  return null;
};
