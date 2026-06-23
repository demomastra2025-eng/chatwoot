import communicationThreadAPI from '../../inbox/communicationThread';
import ApiClient from '../../ApiClient';

describe('#CommunicationThreadAPI', () => {
  it('creates correct instance', () => {
    expect(communicationThreadAPI).toBeInstanceOf(ApiClient);
    expect(communicationThreadAPI).toHaveProperty('markMessageRead');
    expect(communicationThreadAPI).toHaveProperty('filter');
  });

  describe('API calls', () => {
    const originalAxios = window.axios;
    const axiosMock = {
      post: vi.fn(() => Promise.resolve()),
      get: vi.fn(() => Promise.resolve()),
    };

    beforeEach(() => {
      window.axios = axiosMock;
    });

    afterEach(() => {
      window.axios = originalAxios;
      vi.clearAllMocks();
    });

    it('#markMessageRead', () => {
      communicationThreadAPI.markMessageRead({ id: 7 });

      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/communication_threads/7/update_last_seen'
      );
    });

    it('#get communication threads', () => {
      communicationThreadAPI.get({
        inboxId: 1,
        status: 'open',
        assigneeType: 'all',
        page: 1,
        labels: [],
        teamId: 2,
        sortBy: 'last_activity_at_desc',
        crmPipelineId: 12,
        crmStageId: 34,
        labelsScope: 'any',
        teamScope: 'any',
      });

      expect(axiosMock.get).toHaveBeenCalledWith(
        '/api/v1/communication_threads',
        {
          params: {
            inbox_id: 1,
            status: 'open',
            assignee_type: 'all',
            page: 1,
            labels: [],
            team_id: 2,
            sort_by: 'last_activity_at_desc',
            crm_pipeline_id: 12,
            crm_stage_id: 34,
            labels_scope: 'any',
            team_scope: 'any',
          },
        }
      );
    });

    it('#meta communication threads', () => {
      communicationThreadAPI.meta({
        status: 'open',
        assigneeType: 'all',
        labelsScope: 'any',
        teamScope: 'any',
      });

      expect(axiosMock.get).toHaveBeenCalledWith(
        '/api/v1/communication_threads/meta',
        {
          params: {
            inbox_id: undefined,
            status: 'open',
            assignee_type: 'all',
            labels: undefined,
            team_id: undefined,
            sort_by: undefined,
            crm_pipeline_id: undefined,
            crm_stage_id: undefined,
            labels_scope: 'any',
            team_scope: 'any',
          },
        }
      );
    });

    it('#filter', () => {
      const payload = {
        page: 2,
        communicationThreadMode: true,
        crmPipelineId: 12,
        crmStageId: 34,
        labelsScope: 'any',
        teamScope: 'any',
        queryData: {
          payload: [
            {
              attribute_key: 'status',
              filter_operator: 'equal_to',
              values: ['open'],
              query_operator: null,
            },
          ],
        },
      };

      communicationThreadAPI.filter(payload);

      expect(axiosMock.post).toHaveBeenCalledWith(
        '/api/v1/communication_threads/filter',
        payload.queryData,
        {
          params: {
            page: payload.page,
            crm_pipeline_id: payload.crmPipelineId,
            crm_stage_id: payload.crmStageId,
            labels_scope: payload.labelsScope,
            team_scope: payload.teamScope,
          },
        }
      );
    });
  });
});
