import { defineStore } from 'pinia';

import CrmFieldDefinitionsAPI from 'dashboard/api/crm/fieldDefinitions';
import CrmPipelinesAPI from 'dashboard/api/crm/pipelines';
import CrmTaskStatusesAPI from 'dashboard/api/crm/taskStatuses';
import CrmTaskTypesAPI from 'dashboard/api/crm/taskTypes';
import CrmTaskOutcomesAPI from 'dashboard/api/crm/taskOutcomes';
import { loadTaskCatalog, mutateTaskCatalog } from './taskCatalog';
import {
  extractCrmError,
  normalizePayload,
  removeRecord,
  upsertRecord,
} from './shared';

const pipelineLoadRequests = new WeakMap();
const pipelinePublicationStates = new WeakMap();

const pipelineAccountId = () =>
  String(CrmPipelinesAPI.accountIdFromRoute || '');

const publicationStateFor = (store, accountId) => {
  const current = pipelinePublicationStates.get(store);
  if (current?.accountId === accountId) return current;

  const next = {
    accountId,
    latestGeneration: 0,
    publishedGeneration: 0,
    includesInactiveStages: false,
  };
  pipelinePublicationStates.set(store, next);
  store.pipelines = [];
  return next;
};

const defaultUi = () => ({
  error: null,
  isLoadingFieldDefinitions: false,
  isLoadingPipelines: false,
  isLoadingTaskStatuses: false,
  isLoadingTaskTypes: false,
  isSavingTaskCatalog: false,
  taskCatalogError: null,
  isSaving: false,
});

const TERMINAL_STAGE_OUTCOMES = new Set(['won', 'lost']);

const stageSortWeight = stage =>
  TERMINAL_STAGE_OUTCOMES.has(String(stage?.outcome || '').toLowerCase())
    ? 1
    : 0;

const sortStages = stages =>
  [...(stages || [])].sort(
    (left, right) =>
      stageSortWeight(left) - stageSortWeight(right) ||
      Number(left.position ?? 0) - Number(right.position ?? 0) ||
      Number(left.id ?? 0) - Number(right.id ?? 0)
  );

const shiftStagePositionsForInsert = (pipelines, stage) =>
  pipelines.map(pipeline => {
    if (Number(pipeline.id) !== Number(stage.pipelineId)) return pipeline;

    return {
      ...pipeline,
      stages: (pipeline.stages || []).map(existingStage =>
        Number(existingStage.position) >= Number(stage.position)
          ? { ...existingStage, position: Number(existingStage.position) + 1 }
          : existingStage
      ),
    };
  });

const upsertStageInPipelines = (pipelines, stage) => {
  return pipelines.map(pipeline => {
    if (Number(pipeline.id) !== Number(stage.pipelineId)) {
      return pipeline;
    }

    const existingStage = (pipeline.stages || []).find(
      item => Number(item.id) === Number(stage.id)
    );
    const stageWithCounters = {
      ...stage,
      dealCount: stage.dealCount ?? existingStage?.dealCount ?? 0,
    };

    const nextStages = upsertRecord(
      pipeline.stages || [],
      stageWithCounters
    ).map(item => {
      if (!stage.default || Number(item.id) === Number(stage.id)) {
        return item;
      }

      return { ...item, default: false };
    });

    return {
      ...pipeline,
      stages: sortStages(nextStages),
    };
  });
};

const removeStageFromPipelines = (pipelines, stage) => {
  return pipelines.map(pipeline => {
    if (Number(pipeline.id) !== Number(stage.pipelineId)) {
      return pipeline;
    }

    return {
      ...pipeline,
      stages: sortStages(removeRecord(pipeline.stages || [], stage.id)),
    };
  });
};

const upsertPipelineInList = (pipelines, pipeline) => {
  const nextPipelines = upsertRecord(pipelines, pipeline).map(item => {
    if (!pipeline.default || Number(item.id) === Number(pipeline.id)) {
      return item;
    }

    return { ...item, default: false };
  });

  return nextPipelines.sort((left, right) => left.position - right.position);
};

const upsertTaskStatusInList = (taskStatuses, taskStatus) => {
  const nextTaskStatuses = upsertRecord(taskStatuses, taskStatus).map(item => {
    if (!taskStatus.default || Number(item.id) === Number(taskStatus.id)) {
      return item;
    }

    return { ...item, default: false };
  });

  return nextTaskStatuses.sort((left, right) => left.position - right.position);
};

export const useCrmReferencesStore = defineStore('crmReferences', {
  state: () => ({
    fieldDefinitions: {
      deal: [],
      task: [],
      appointment: [],
    },
    pipelines: [],
    taskStatuses: [],
    taskTypes: [],
    ui: defaultUi(),
  }),

  getters: {
    dealFieldDefinitions: state => state.fieldDefinitions.deal,
    taskFieldDefinitions: state => state.fieldDefinitions.task,
    appointmentFieldDefinitions: state => state.fieldDefinitions.appointment,
  },

  actions: {
    resetError() {
      this.ui.error = null;
    },

    async loadPipelines(params = {}) {
      const accountId = pipelineAccountId();
      const requestKey = JSON.stringify([accountId, params]);
      const requests = pipelineLoadRequests.get(this) || new Map();
      const existingRequest = requests.get(requestKey);
      if (existingRequest) return existingRequest;

      const publicationState = publicationStateFor(this, accountId);
      const requestGeneration = publicationState.latestGeneration + 1;
      publicationState.latestGeneration = requestGeneration;
      const includesInactiveStages = params.include_inactive_stages === true;

      this.ui.isLoadingPipelines = true;
      this.ui.error = null;

      const request = (async () => {
        const { data } = await CrmPipelinesAPI.get(params);
        const pipelines = normalizePayload(data);
        const currentState = pipelinePublicationStates.get(this);
        const accountIsCurrent = pipelineAccountId() === accountId;
        const stateIsCurrent = currentState?.accountId === accountId;
        if (!accountIsCurrent || !stateIsCurrent) return this.pipelines;

        const wouldDowngradeFullData =
          currentState.includesInactiveStages && !includesInactiveStages;
        const staleRequest =
          requestGeneration < currentState.latestGeneration &&
          !(includesInactiveStages && !currentState.includesInactiveStages);
        if (wouldDowngradeFullData || staleRequest) return this.pipelines;

        this.pipelines = pipelines;
        currentState.publishedGeneration = requestGeneration;
        currentState.includesInactiveStages = includesInactiveStages;
        return this.pipelines;
      })();
      requests.set(requestKey, request);
      pipelineLoadRequests.set(this, requests);

      try {
        return await request;
      } catch (error) {
        const currentState = pipelinePublicationStates.get(this);
        if (
          pipelineAccountId() === accountId &&
          currentState?.accountId === accountId &&
          requestGeneration === currentState.latestGeneration
        ) {
          this.ui.error = extractCrmError(error);
        }
        throw error;
      } finally {
        requests.delete(requestKey);
        if (!requests.size) {
          pipelineLoadRequests.delete(this);
          this.ui.isLoadingPipelines = false;
        }
      }
    },

    async savePipeline(payload) {
      this.ui.isSaving = true;
      this.ui.error = null;

      try {
        const response = payload.id
          ? await CrmPipelinesAPI.update(payload.id, payload)
          : await CrmPipelinesAPI.create(payload);

        const pipeline = normalizePayload(response.data);
        this.pipelines = upsertPipelineInList(this.pipelines, pipeline);
        return pipeline;
      } catch (error) {
        this.ui.error = extractCrmError(error);
        throw error;
      } finally {
        this.ui.isSaving = false;
      }
    },

    async deletePipeline(pipeline) {
      this.ui.isSaving = true;
      this.ui.error = null;

      try {
        await CrmPipelinesAPI.deletePipeline(pipeline.id);
        this.pipelines = removeRecord(this.pipelines, pipeline.id);
      } catch (error) {
        this.ui.error = extractCrmError(error);
        throw error;
      } finally {
        this.ui.isSaving = false;
      }
    },

    async saveStage(payload) {
      this.ui.isSaving = true;
      this.ui.error = null;

      try {
        const response = payload.id
          ? await CrmPipelinesAPI.updateStage(payload.id, payload)
          : await CrmPipelinesAPI.createStage(payload.pipelineId, payload);

        const stage = normalizePayload(response.data);
        if (
          !payload.id &&
          stage.position !== null &&
          stage.position !== undefined
        ) {
          this.pipelines = shiftStagePositionsForInsert(this.pipelines, stage);
        }
        this.pipelines = upsertStageInPipelines(this.pipelines, stage);
        return stage;
      } catch (error) {
        this.ui.error = extractCrmError(error);
        throw error;
      } finally {
        this.ui.isSaving = false;
      }
    },

    async deleteStage(stage) {
      this.ui.isSaving = true;
      this.ui.error = null;

      try {
        await CrmPipelinesAPI.deleteStage(stage.id);
        this.pipelines = removeStageFromPipelines(this.pipelines, stage);
      } catch (error) {
        this.ui.error = extractCrmError(error);
        throw error;
      } finally {
        this.ui.isSaving = false;
      }
    },

    async checkStageDeletion(stageId) {
      const { data } = await CrmPipelinesAPI.checkStageDeletion(stageId);
      return normalizePayload(data);
    },

    async reorderStages(pipelineId, stageIds) {
      this.ui.isSaving = true;
      this.ui.error = null;

      try {
        const response = await CrmPipelinesAPI.reorderStages(
          pipelineId,
          stageIds
        );
        const pipeline = normalizePayload(response.data);
        this.pipelines = upsertPipelineInList(this.pipelines, pipeline);
        return pipeline;
      } catch (error) {
        this.ui.error = extractCrmError(error);
        throw error;
      } finally {
        this.ui.isSaving = false;
      }
    },

    async batchUpdateStages(pipelineId, payload) {
      this.ui.isSaving = true;
      this.ui.error = null;

      try {
        const response = await CrmPipelinesAPI.batchUpdateStages(
          pipelineId,
          payload
        );
        const pipeline = normalizePayload(response.data);
        this.pipelines = upsertPipelineInList(this.pipelines, pipeline);
        return pipeline;
      } catch (error) {
        this.ui.error = extractCrmError(error);
        throw error;
      } finally {
        this.ui.isSaving = false;
      }
    },

    async loadTaskStatuses(params = {}) {
      this.ui.isLoadingTaskStatuses = true;
      this.ui.error = null;

      try {
        const { data } = await CrmTaskStatusesAPI.get(params);
        this.taskStatuses = normalizePayload(data);
        return this.taskStatuses;
      } catch (error) {
        this.ui.error = extractCrmError(error);
        throw error;
      } finally {
        this.ui.isLoadingTaskStatuses = false;
      }
    },

    loadTaskTypes() {
      return loadTaskCatalog(this);
    },

    saveTaskType(payload) {
      return mutateTaskCatalog(
        this,
        () =>
          payload.id
            ? CrmTaskTypesAPI.update(payload.id, payload)
            : CrmTaskTypesAPI.create(payload),
        upsertTaskStatusInList
      );
    },

    saveTaskOutcome(payload) {
      return mutateTaskCatalog(
        this,
        () =>
          payload.id
            ? CrmTaskOutcomesAPI.update(payload.id, payload)
            : CrmTaskOutcomesAPI.create(payload),
        (types, outcome) =>
          types.map(taskType =>
            Number(taskType.id) === Number(outcome.taskTypeId)
              ? {
                  ...taskType,
                  outcomes: upsertTaskStatusInList(
                    taskType.outcomes || [],
                    outcome
                  ),
                }
              : taskType
          )
      );
    },

    async saveTaskStatus(payload) {
      this.ui.isSaving = true;
      this.ui.error = null;

      try {
        const response = payload.id
          ? await CrmTaskStatusesAPI.update(payload.id, payload)
          : await CrmTaskStatusesAPI.create(payload);

        const taskStatus = normalizePayload(response.data);
        this.taskStatuses = upsertTaskStatusInList(
          this.taskStatuses,
          taskStatus
        );
        return taskStatus;
      } catch (error) {
        this.ui.error = extractCrmError(error);
        throw error;
      } finally {
        this.ui.isSaving = false;
      }
    },

    async deleteTaskStatus(taskStatus) {
      this.ui.isSaving = true;
      this.ui.error = null;

      try {
        await CrmTaskStatusesAPI.deleteTaskStatus(taskStatus.id);
        this.taskStatuses = removeRecord(this.taskStatuses, taskStatus.id);
      } catch (error) {
        this.ui.error = extractCrmError(error);
        throw error;
      } finally {
        this.ui.isSaving = false;
      }
    },

    async loadFieldDefinitions(entityKind) {
      this.ui.isLoadingFieldDefinitions = true;
      this.ui.error = null;

      try {
        const { data } = await CrmFieldDefinitionsAPI.get({
          entity_kind: entityKind,
        });
        this.fieldDefinitions[entityKind] = normalizePayload(data);
        return this.fieldDefinitions[entityKind];
      } catch (error) {
        this.ui.error = extractCrmError(error);
        throw error;
      } finally {
        this.ui.isLoadingFieldDefinitions = false;
      }
    },

    async saveFieldDefinition(payload) {
      this.ui.isSaving = true;
      this.ui.error = null;

      try {
        const response = payload.id
          ? await CrmFieldDefinitionsAPI.update(payload.id, payload)
          : await CrmFieldDefinitionsAPI.create(payload);

        const fieldDefinition = normalizePayload(response.data);
        const currentDefinitions =
          this.fieldDefinitions[fieldDefinition.entityKind];
        this.fieldDefinitions[fieldDefinition.entityKind] = upsertRecord(
          currentDefinitions,
          fieldDefinition
        ).sort((left, right) => left.position - right.position);
        return fieldDefinition;
      } catch (error) {
        this.ui.error = extractCrmError(error);
        throw error;
      } finally {
        this.ui.isSaving = false;
      }
    },

    async deleteFieldDefinition(fieldDefinition) {
      this.ui.isSaving = true;
      this.ui.error = null;

      try {
        await CrmFieldDefinitionsAPI.delete(fieldDefinition.id);
        this.fieldDefinitions[fieldDefinition.entityKind] = removeRecord(
          this.fieldDefinitions[fieldDefinition.entityKind],
          fieldDefinition.id
        );
      } catch (error) {
        this.ui.error = extractCrmError(error);
        throw error;
      } finally {
        this.ui.isSaving = false;
      }
    },
  },
});
