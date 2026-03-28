import { defineStore } from 'pinia';

import CrmFieldDefinitionsAPI from 'dashboard/api/crm/fieldDefinitions';
import CrmPipelinesAPI from 'dashboard/api/crm/pipelines';
import CrmTaskStatusesAPI from 'dashboard/api/crm/taskStatuses';
import {
  extractCrmError,
  normalizePayload,
  removeRecord,
  upsertRecord,
} from './shared';

const defaultUi = () => ({
  error: null,
  isLoadingFieldDefinitions: false,
  isLoadingPipelines: false,
  isLoadingTaskStatuses: false,
  isSaving: false,
});

const upsertStageInPipelines = (pipelines, stage) => {
  return pipelines.map(pipeline => {
    if (Number(pipeline.id) !== Number(stage.pipelineId)) {
      return pipeline;
    }

    return {
      ...pipeline,
      stages: upsertRecord(pipeline.stages || [], stage).sort(
        (left, right) => left.position - right.position
      ),
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
      stages: removeRecord(pipeline.stages || [], stage.id).sort(
        (left, right) => left.position - right.position
      ),
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
    },
    pipelines: [],
    taskStatuses: [],
    ui: defaultUi(),
  }),

  getters: {
    dealFieldDefinitions: state => state.fieldDefinitions.deal,
    taskFieldDefinitions: state => state.fieldDefinitions.task,
  },

  actions: {
    resetError() {
      this.ui.error = null;
    },

    async loadPipelines(params = {}) {
      this.ui.isLoadingPipelines = true;
      this.ui.error = null;

      try {
        const { data } = await CrmPipelinesAPI.get(params);
        this.pipelines = normalizePayload(data);
        return this.pipelines;
      } catch (error) {
        this.ui.error = extractCrmError(error);
        throw error;
      } finally {
        this.ui.isLoadingPipelines = false;
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
