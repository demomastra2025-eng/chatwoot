import ContextFieldsAPI from 'dashboard/api/contextFields';

const cachedContextFieldsByUrl = new Map();
const contextFieldsRequestsByUrl = new Map();

export const loadContextFieldCatalog = async () => {
  const requestUrl = ContextFieldsAPI.url;

  if (cachedContextFieldsByUrl.has(requestUrl)) {
    return cachedContextFieldsByUrl.get(requestUrl);
  }

  if (!contextFieldsRequestsByUrl.has(requestUrl)) {
    contextFieldsRequestsByUrl.set(
      requestUrl,
      ContextFieldsAPI.get()
        .then(({ data }) => data || [])
        .then(data => {
          cachedContextFieldsByUrl.set(requestUrl, data);
          return data;
        })
        .finally(() => {
          contextFieldsRequestsByUrl.delete(requestUrl);
        })
    );
  }

  return contextFieldsRequestsByUrl.get(requestUrl);
};
