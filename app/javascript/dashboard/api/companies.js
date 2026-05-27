/* global axios */
import ApiClient from './ApiClient';

const encodeParam = value => encodeURIComponent(value);

const buildParams = params =>
  Object.entries(params)
    .filter(
      ([key, value]) => value !== undefined && (value !== '' || key === 'q')
    )
    .map(([key, value]) => `${key}=${encodeParam(value)}`)
    .join('&');

const buildCompanyParams = (page = 1, sort = '') => buildParams({ page, sort });

const buildSearchParams = (query = '', page = 1, sort = '') =>
  buildParams({ q: query, page, sort });

const wrapCompanyPayload = data => {
  if (data instanceof FormData || data?.company) return data;
  return { company: data };
};

class CompanyAPI extends ApiClient {
  constructor() {
    super('companies', { accountScoped: true });
  }

  get(params = {}) {
    const { page = 1, sort = 'name' } = params;
    const requestURL = `${this.url}?${buildCompanyParams(page, sort)}`;
    return axios.get(requestURL);
  }

  search(query = '', page = 1, sort = 'name') {
    const requestURL = `${this.url}/search?${buildSearchParams(query, page, sort)}`;
    return axios.get(requestURL);
  }

  show(id) {
    return axios.get(`${this.url}/${id}`);
  }

  create(data) {
    return axios.post(this.url, wrapCompanyPayload(data));
  }

  update(id, data) {
    return axios.patch(`${this.url}/${id}`, wrapCompanyPayload(data));
  }

  listContacts(id, page = 1) {
    return axios.get(`${this.url}/${id}/contacts?${buildParams({ page })}`);
  }

  listNotes(id) {
    return axios.get(`${this.url}/${id}/notes`);
  }

  listConversations(id) {
    return axios.get(`${this.url}/${id}/conversations`);
  }

  searchContacts(id, query = '', page = 1) {
    const requestURL = `${this.url}/${id}/contacts/search?${buildParams({ q: query, page })}`;
    return axios.get(requestURL);
  }

  createContact(id, payload) {
    return axios.post(`${this.url}/${id}/contacts`, payload);
  }

  removeContact(id, contactId) {
    return axios.delete(`${this.url}/${id}/contacts/${contactId}`);
  }

  destroyCustomAttributes(id, customAttributes) {
    return axios.post(`${this.url}/${id}/destroy_custom_attributes`, {
      custom_attributes: customAttributes,
    });
  }

  destroyAvatar(id) {
    return axios.delete(`${this.url}/${id}/avatar`);
  }
}

export {
  buildCompanyParams,
  buildParams,
  buildSearchParams,
  wrapCompanyPayload,
};
export default new CompanyAPI();
