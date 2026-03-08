/* global axios */
import ApiClient from './ApiClient';

export const buildCompanyParams = (page, sort) => {
  let params = `page=${page}`;
  if (sort) {
    params = `${params}&sort=${sort}`;
  }
  return params;
};

export const buildSearchParams = (query, page, sort) => {
  let params = `q=${encodeURIComponent(query)}&page=${page}`;
  if (sort) {
    params = `${params}&sort=${sort}`;
  }
  return params;
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
    return axios.post(this.url, { company: data });
  }

  update(id, data) {
    return axios.patch(`${this.url}/${id}`, { company: data });
  }
}

export default new CompanyAPI();
