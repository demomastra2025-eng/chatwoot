import CacheEnabledApiClient from './CacheEnabledApiClient';

const wrapLabelPayload = data => {
  if (data?.label) return data;
  return { label: data };
};

class LabelsAPI extends CacheEnabledApiClient {
  constructor() {
    super('labels', { accountScoped: true });
  }

  create(data) {
    return super.create(wrapLabelPayload(data));
  }

  update(id, data) {
    return super.update(id, wrapLabelPayload(data));
  }

  // eslint-disable-next-line class-methods-use-this
  get cacheModelName() {
    return 'label';
  }
}

export default new LabelsAPI();
