import axios from 'axios';
import { actions } from '../../labels';
import * as types from '../../../mutation-types';
import labelsList from './fixtures';
import { sortLabelsByDisplayTitle } from '../../../../helper/labels';

const commit = vi.fn();
global.axios = axios;
vi.mock('axios');

describe('#actions', () => {
  beforeEach(() => {
    commit.mockClear();
    window.history.pushState({}, '', '/');
    axios.get.mockReset();
    axios.post.mockReset();
    axios.patch.mockReset();
    axios.delete.mockReset();
  });

  afterEach(() => {
    window.history.pushState({}, '', '/');
  });

  describe('#get', () => {
    it('sends correct actions if API is success', async () => {
      const mockedGet = vi.fn(url => {
        if (url === '/api/v1/labels') {
          return Promise.resolve({ data: { payload: labelsList } });
        }
        if (url === '/api/v1/accounts//cache_keys') {
          return Promise.resolve({ data: { cache_keys: { labels: 0 } } });
        }
        // Return default value or throw an error for unexpected requests
        return Promise.reject(new Error('Unexpected request: ' + url));
      });

      axios.get = mockedGet;

      await actions.get({ commit });
      expect(commit.mock.calls).toEqual([
        [types.default.SET_LABEL_UI_FLAG, { isFetching: true }],
        [types.default.SET_LABELS, sortLabelsByDisplayTitle(labelsList)],
        [types.default.SET_LABEL_UI_FLAG, { isFetching: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.get.mockRejectedValue({ message: 'Incorrect header' });
      await actions.get({ commit });
      expect(commit.mock.calls).toEqual([
        [types.default.SET_LABEL_UI_FLAG, { isFetching: true }],
        [types.default.SET_LABEL_UI_FLAG, { isFetching: false }],
      ]);
    });

    it('does not commit stale labels when the route account changes before the response resolves', async () => {
      let resolveLabels;

      window.history.pushState({}, '', '/app/accounts/64/settings/labels');
      axios.get.mockImplementation(url => {
        if (url === '/api/v1/accounts/64/cache_keys') {
          return Promise.resolve({ data: { cache_keys: {} } });
        }
        if (url === '/api/v1/accounts/64/labels') {
          return new Promise(resolve => {
            resolveLabels = resolve;
          });
        }
        return Promise.reject(new Error('Unexpected request: ' + url));
      });

      const request = actions.get({ commit });
      await vi.waitFor(() =>
        expect(resolveLabels).toEqual(expect.any(Function))
      );
      window.history.pushState({}, '', '/app/accounts/6/settings/labels');

      resolveLabels({ data: { payload: labelsList } });
      await request;

      expect(commit.mock.calls).toEqual([
        [types.default.SET_LABEL_UI_FLAG, { isFetching: true }],
      ]);
    });
  });

  describe('#create', () => {
    it('sends correct actions if API is success', async () => {
      axios.post.mockResolvedValue({ data: labelsList[0] });
      await actions.create({ commit }, labelsList[0]);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_LABEL_UI_FLAG, { isCreating: true }],
        [types.default.ADD_LABEL, labelsList[0]],
        [types.default.SET_LABEL_UI_FLAG, { isCreating: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue({ message: 'Incorrect header' });
      await expect(actions.create({ commit })).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_LABEL_UI_FLAG, { isCreating: true }],
        [types.default.SET_LABEL_UI_FLAG, { isCreating: false }],
      ]);
    });
  });

  describe('#update', () => {
    it('sends correct actions if API is success', async () => {
      axios.patch.mockResolvedValue({ data: labelsList[0] });
      await actions.update({ commit }, labelsList[0]);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_LABEL_UI_FLAG, { isUpdating: true }],
        [types.default.EDIT_LABEL, labelsList[0]],
        [types.default.SET_LABEL_UI_FLAG, { isUpdating: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.patch.mockRejectedValue({ message: 'Incorrect header' });
      await expect(actions.update({ commit }, labelsList[0])).rejects.toThrow(
        Error
      );
      expect(commit.mock.calls).toEqual([
        [types.default.SET_LABEL_UI_FLAG, { isUpdating: true }],
        [types.default.SET_LABEL_UI_FLAG, { isUpdating: false }],
      ]);
    });
  });

  describe('#delete', () => {
    it('sends correct actions if API is success', async () => {
      axios.delete.mockResolvedValue({ data: labelsList[0] });
      await actions.delete({ commit }, labelsList[0].id);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_LABEL_UI_FLAG, { isDeleting: true }],
        [types.default.DELETE_LABEL, labelsList[0].id],
        [types.default.SET_LABEL_UI_FLAG, { isDeleting: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.delete.mockRejectedValue({ message: 'Incorrect header' });
      await expect(
        actions.delete({ commit }, labelsList[0].id)
      ).rejects.toThrow(Error);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_LABEL_UI_FLAG, { isDeleting: true }],
        [types.default.SET_LABEL_UI_FLAG, { isDeleting: false }],
      ]);
    });
  });
});
