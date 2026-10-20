import axios from 'axios';
import { actions } from '../../teams/actions';
import {
  SET_TEAM_UI_FLAG,
  CLEAR_TEAMS,
  SET_TEAMS,
  SET_TEAM_ITEM,
  EDIT_TEAM,
  DELETE_TEAM,
} from '../../teams/types';
import teamsList from './fixtures';

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
    it('clears teams without calling the removed teams API', async () => {
      await actions.get({ commit });
      expect(commit.mock.calls).toEqual([
        [CLEAR_TEAMS],
        [SET_TEAMS, []],
      ]);
    });
  });

  describe('#create', () => {
    it('sends correct actions if API is success', async () => {
      axios.post.mockResolvedValue({ data: teamsList[1] });
      await actions.create({ commit }, teamsList[1]);

      expect(commit.mock.calls).toEqual([
        [SET_TEAM_UI_FLAG, { isCreating: true }],
        [SET_TEAM_ITEM, teamsList[1]],
        [SET_TEAM_UI_FLAG, { isCreating: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue({ message: 'Incorrect header' });
      await expect(actions.create({ commit })).rejects.toEqual({
        message: 'Incorrect header',
      });

      expect(commit.mock.calls).toEqual([
        [SET_TEAM_UI_FLAG, { isCreating: true }],
        [SET_TEAM_UI_FLAG, { isCreating: false }],
      ]);
    });
  });

  describe('#update', () => {
    it('sends correct actions if API is success', async () => {
      axios.patch.mockResolvedValue({ data: teamsList[1] });
      await actions.update({ commit }, teamsList[1]);

      expect(commit.mock.calls).toEqual([
        [SET_TEAM_UI_FLAG, { isUpdating: true }],
        [EDIT_TEAM, teamsList[1]],
        [SET_TEAM_UI_FLAG, { isUpdating: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.patch.mockRejectedValue({ message: 'Incorrect header' });
      await expect(actions.update({ commit }, teamsList[1])).rejects.toEqual({
        message: 'Incorrect header',
      });
      expect(commit.mock.calls).toEqual([
        [SET_TEAM_UI_FLAG, { isUpdating: true }],
        [SET_TEAM_UI_FLAG, { isUpdating: false }],
      ]);
    });
  });

  describe('#delete', () => {
    it('sends correct actions if API is success', async () => {
      axios.delete.mockResolvedValue();
      await actions.delete({ commit }, 1);
      expect(commit.mock.calls).toEqual([
        [SET_TEAM_UI_FLAG, { isDeleting: true }],
        [DELETE_TEAM, 1],
        [SET_TEAM_UI_FLAG, { isDeleting: false }],
      ]);
    });
    it('sends correct actions if API is error', async () => {
      axios.delete.mockRejectedValue({ message: 'Incorrect header' });
      await expect(actions.delete({ commit }, 1)).rejects.toEqual({
        message: 'Incorrect header',
      });
      expect(commit.mock.calls).toEqual([
        [SET_TEAM_UI_FLAG, { isDeleting: true }],
        [SET_TEAM_UI_FLAG, { isDeleting: false }],
      ]);
    });
  });
});
