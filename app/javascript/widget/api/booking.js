import { API } from 'widget/helpers/axios';
import { buildSearchParamsWithLocale } from '../helpers/urlParamsHelper';

const getSearch = () => buildSearchParamsWithLocale(window.location.search);

export default {
  getConfig() {
    return API.get(`/api/v1/widget/booking${getSearch()}`);
  },
  getSlots(params = {}) {
    return API.get(`/api/v1/widget/booking/slots${getSearch()}`, { params });
  },
  createBooking(payload = {}) {
    return API.post(`/api/v1/widget/booking${getSearch()}`, {
      booking: payload,
    });
  },
};
