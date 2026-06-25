/* global axios */
import { DataManager } from '../helper/CacheHelper/DataManager';
import ApiClient from './ApiClient';

class CacheEnabledApiClient extends ApiClient {
  constructor(resource, options = {}) {
    super(resource, options);
    this.dataManager = new DataManager(this.accountIdFromRoute);
  }

  // eslint-disable-next-line class-methods-use-this
  get cacheModelName() {
    throw new Error('cacheModelName is not defined');
  }

  get(cache = false) {
    if (cache) {
      return this.getFromCache();
    }

    return this.getFromNetwork();
  }

  getFromNetwork(accountId = this.accountIdFromRoute) {
    return axios.get(this.urlForAccount(accountId));
  }

  urlForAccount(accountId) {
    let baseUrl = this.apiVersion;

    if (this.options.enterprise) {
      baseUrl = `/enterprise${baseUrl}`;
    }

    if (this.options.accountScoped && accountId) {
      baseUrl = `${baseUrl}/accounts/${accountId}`;
    }

    return `${baseUrl}/${this.resource}`;
  }

  getDataManager(accountId = this.accountIdFromRoute) {
    if (
      !this.dataManager ||
      String(this.dataManager.accountId) !== String(accountId)
    ) {
      this.dataManager = new DataManager(accountId);
    }

    return this.dataManager;
  }

  // eslint-disable-next-line class-methods-use-this
  extractDataFromResponse(response) {
    return response.data.payload;
  }

  // eslint-disable-next-line class-methods-use-this
  marshallData(dataToParse) {
    return { data: { payload: dataToParse } };
  }

  async getFromCache() {
    const accountId = this.accountIdFromRoute;
    const dataManager = this.getDataManager(accountId);
    try {
      // IDB is not supported in Firefox private mode: https://bugzilla.mozilla.org/show_bug.cgi?id=781982
      await dataManager.initDb();
    } catch {
      return this.getFromNetwork(accountId);
    }

    const { data } = await axios.get(
      `/api/v1/accounts/${accountId}/cache_keys`
    );
    const cacheKeyFromApi = data.cache_keys?.[this.cacheModelName];
    if (cacheKeyFromApi === undefined || cacheKeyFromApi === null) {
      return this.refetchAndCommit(null, accountId);
    }

    const isCacheValid = await this.validateCacheKey(
      cacheKeyFromApi,
      accountId
    );

    let localData = [];
    if (isCacheValid) {
      localData = await dataManager.get({
        modelName: this.cacheModelName,
      });
    }

    if (localData.length === 0) {
      return this.refetchAndCommit(cacheKeyFromApi, accountId);
    }

    return this.marshallData(localData);
  }

  async refetchAndCommit(newKey = null, accountId = this.accountIdFromRoute) {
    const response = await this.getFromNetwork(accountId);
    const dataManager = this.getDataManager(accountId);

    try {
      await dataManager.initDb();

      await dataManager.replace({
        modelName: this.cacheModelName,
        data: this.extractDataFromResponse(response),
      });

      await dataManager.setCacheKeys({
        [this.cacheModelName]: newKey,
      });
    } catch {
      // Ignore error
    }

    return response;
  }

  async validateCacheKey(cacheKeyFromApi, accountId = this.accountIdFromRoute) {
    const dataManager = this.getDataManager(accountId);
    if (!dataManager.db) {
      await dataManager.initDb();
    }

    const cachekey = await dataManager.getCacheKey(this.cacheModelName);
    return cacheKeyFromApi === cachekey;
  }
}

export default CacheEnabledApiClient;
