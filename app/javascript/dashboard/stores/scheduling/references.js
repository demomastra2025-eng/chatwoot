import { defineStore } from 'pinia';
import SchedulingCabinetsAPI from 'dashboard/api/scheduling/cabinets';
import SchedulingExceptionsAPI from 'dashboard/api/scheduling/exceptions';
import SchedulingResourcesAPI from 'dashboard/api/scheduling/resources';
import SchedulingProductsAPI from 'dashboard/api/scheduling/products';
import SchedulingServicesAPI from 'dashboard/api/scheduling/services';
import {
  compactPayload,
  extractSchedulingError,
  isDeletedFromScheduling,
  normalizeMeta,
  normalizePayload,
  removeRecord,
  upsertRecord,
} from './shared';

export const useSchedulingReferencesStore = defineStore(
  'schedulingReferences',
  {
    state: () => ({
      breakRulesByResource: {},
      cabinets: [],
      holidays: [],
      resources: [],
      products: [],
      moyskladStatus: {
        connected: false,
        status: 'disabled',
        hookId: null,
        priceTypeName: 'Цена продажи',
        maskedToken: null,
        lastSyncedAt: null,
        lastSyncSummary: null,
        syncedProductsCount: 0,
      },
      services: [],
      timeOffs: [],
      ui: {
        error: null,
        isLoadingCabinets: false,
        isLoadingExceptions: false,
        isLoadingResources: false,
        isLoadingProducts: false,
        isLoadingServices: false,
        isSyncingMoysklad: false,
        isSaving: false,
      },
      workRulesByResource: {},
      workdayOverrides: [],
    }),

    getters: {
      activeResources: state =>
        state.resources.filter(
          resource => resource.active && !isDeletedFromScheduling(resource)
        ),
      activeServices: state => state.services.filter(service => service.active),
    },

    actions: {
      async loadResources(params = { include_inactive: true }) {
        this.ui.isLoadingResources = true;
        this.ui.error = null;

        try {
          const { data } = await SchedulingResourcesAPI.get(params);
          this.resources = normalizePayload(data);
          return this.resources;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isLoadingResources = false;
        }
      },

      async saveResource(resource) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          const payload = compactPayload(resource);
          if (
            resource.id &&
            Object.prototype.hasOwnProperty.call(resource, 'specialty')
          ) {
            payload.specialty = resource.specialty;
          }
          const response = payload.id
            ? await SchedulingResourcesAPI.update(payload.id, payload)
            : await SchedulingResourcesAPI.create(payload);
          const savedResource = normalizePayload(response.data);
          this.resources = upsertRecord(this.resources, savedResource);
          return savedResource;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },

      async deleteResource(resourceId) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          await SchedulingResourcesAPI.delete(resourceId);
          this.resources = this.resources.map(resource => {
            if (Number(resource.id) !== Number(resourceId)) {
              return resource;
            }

            return {
              ...resource,
              active: false,
              customAttributes: {
                ...(resource.customAttributes || {}),
                deleted_from_scheduling: true,
                deletedFromScheduling: true,
              },
            };
          });
        } finally {
          this.ui.isSaving = false;
        }
      },

      async loadWorkRules(resourceId) {
        const { data } = await SchedulingResourcesAPI.getWorkRules(resourceId);
        const payload = normalizePayload(data);
        this.workRulesByResource = {
          ...this.workRulesByResource,
          [resourceId]: payload,
        };
        return payload;
      },

      async saveWorkRules(resourceId, rules) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          const { data } = await SchedulingResourcesAPI.updateWorkRules(
            resourceId,
            rules
          );
          const payload = normalizePayload(data);
          this.workRulesByResource = {
            ...this.workRulesByResource,
            [resourceId]: payload,
          };
          return payload;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },

      async loadBreakRules(resourceId) {
        const { data } = await SchedulingResourcesAPI.getBreakRules(resourceId);
        const payload = normalizePayload(data);
        this.breakRulesByResource = {
          ...this.breakRulesByResource,
          [resourceId]: payload,
        };
        return payload;
      },

      async saveBreakRules(resourceId, rules) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          const { data } = await SchedulingResourcesAPI.updateBreakRules(
            resourceId,
            rules
          );
          const payload = normalizePayload(data);
          this.breakRulesByResource = {
            ...this.breakRulesByResource,
            [resourceId]: payload,
          };
          return payload;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },

      async loadProducts(params = { include_inactive: true }) {
        this.ui.isLoadingProducts = true;
        this.ui.error = null;

        try {
          const { data } = await SchedulingProductsAPI.get(params);
          this.products = normalizePayload(data);
          const meta = normalizeMeta(data);
          if (meta?.moysklad) {
            this.moyskladStatus = {
              ...this.moyskladStatus,
              ...meta.moysklad,
            };
          }
          return this.products;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isLoadingProducts = false;
        }
      },

      async saveProduct(product) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          const payload = compactPayload(product);
          const response = payload.id
            ? await SchedulingProductsAPI.update(payload.id, payload)
            : await SchedulingProductsAPI.create(payload);
          const savedProduct = normalizePayload(response.data);
          this.products = upsertRecord(this.products, savedProduct);
          return savedProduct;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },

      async deleteProduct(productId) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          await SchedulingProductsAPI.delete(productId);
          this.products = removeRecord(this.products, productId);
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },

      async loadMoyskladStatus() {
        try {
          const { data } = await SchedulingProductsAPI.getMoyskladStatus();
          const payload = normalizePayload(data);
          if (payload && typeof payload === 'object') {
            this.moyskladStatus = {
              ...this.moyskladStatus,
              ...payload,
            };
          }
          return this.moyskladStatus;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        }
      },

      async saveMoyskladConfig(config) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          const { data } = await SchedulingProductsAPI.saveMoyskladConfig(
            compactPayload(config)
          );
          const payload = normalizePayload(data);
          if (payload && typeof payload === 'object') {
            this.moyskladStatus = {
              ...this.moyskladStatus,
              ...payload,
            };
          }
          return this.moyskladStatus;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },

      async syncMoysklad(syncParams = {}) {
        this.ui.isSyncingMoysklad = true;
        this.ui.error = null;

        try {
          const { data } = await SchedulingProductsAPI.syncMoysklad(
            compactPayload(syncParams)
          );
          this.products = normalizePayload(data);
          const meta = normalizeMeta(data);
          if (meta?.moysklad) {
            this.moyskladStatus = {
              ...this.moyskladStatus,
              ...meta.moysklad,
            };
          }
          return {
            products: this.products,
            syncSummary: meta?.syncSummary || null,
            moysklad: this.moyskladStatus,
          };
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSyncingMoysklad = false;
        }
      },

      async loadServices(params = { include_inactive: true }) {
        this.ui.isLoadingServices = true;
        this.ui.error = null;

        try {
          const { data } = await SchedulingServicesAPI.get(params);
          this.services = normalizePayload(data);
          return this.services;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isLoadingServices = false;
        }
      },

      async loadCabinets(params = {}) {
        this.ui.isLoadingCabinets = true;
        this.ui.error = null;

        try {
          const { data } = await SchedulingCabinetsAPI.get(params);
          this.cabinets = normalizePayload(data);
          return this.cabinets;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isLoadingCabinets = false;
        }
      },

      async saveService(service) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          const payload = compactPayload(service);
          const response = payload.id
            ? await SchedulingServicesAPI.update(payload.id, payload)
            : await SchedulingServicesAPI.create(payload);
          const savedService = normalizePayload(response.data);
          this.services = upsertRecord(this.services, savedService);
          return savedService;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },

      async deleteService(serviceId) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          await SchedulingServicesAPI.delete(serviceId);
          this.services = removeRecord(this.services, serviceId);
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },

      async loadExceptions(params = {}) {
        this.ui.isLoadingExceptions = true;
        this.ui.error = null;

        try {
          const [holidaysResponse, overridesResponse, timeOffsResponse] =
            await Promise.all([
              SchedulingExceptionsAPI.getHolidays(params.holidays || {}),
              SchedulingExceptionsAPI.getWorkdayOverrides(
                params.workdayOverrides || {}
              ),
              SchedulingExceptionsAPI.getTimeOffs(params.timeOffs || {}),
            ]);

          this.holidays = normalizePayload(holidaysResponse.data);
          this.workdayOverrides = normalizePayload(overridesResponse.data);
          this.timeOffs = normalizePayload(timeOffsResponse.data);

          return {
            holidays: this.holidays,
            timeOffs: this.timeOffs,
            workdayOverrides: this.workdayOverrides,
          };
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isLoadingExceptions = false;
        }
      },

      async saveHoliday(holiday) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          const payload = compactPayload(holiday);
          const response = payload.id
            ? await SchedulingExceptionsAPI.updateHoliday(payload.id, payload)
            : await SchedulingExceptionsAPI.createHoliday(payload);
          const savedHoliday = normalizePayload(response.data);
          this.holidays = upsertRecord(this.holidays, savedHoliday).sort(
            (left, right) => new Date(left.date) - new Date(right.date)
          );
          return savedHoliday;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },

      async deleteHoliday(id) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          await SchedulingExceptionsAPI.deleteHoliday(id);
          this.holidays = removeRecord(this.holidays, id);
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },

      async saveWorkdayOverride(override) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          const payload = compactPayload(override);
          const response = payload.id
            ? await SchedulingExceptionsAPI.updateWorkdayOverride(
                payload.id,
                payload
              )
            : await SchedulingExceptionsAPI.createWorkdayOverride(payload);
          const savedOverride = normalizePayload(response.data);
          this.workdayOverrides = upsertRecord(
            this.workdayOverrides,
            savedOverride
          );
          return savedOverride;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },

      async deleteWorkdayOverride(id) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          await SchedulingExceptionsAPI.deleteWorkdayOverride(id);
          this.workdayOverrides = removeRecord(this.workdayOverrides, id);
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },

      async saveTimeOff(timeOff) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          const payload = compactPayload(timeOff);
          const response = payload.id
            ? await SchedulingExceptionsAPI.updateTimeOff(payload.id, payload)
            : await SchedulingExceptionsAPI.createTimeOff(payload);
          const savedTimeOff = normalizePayload(response.data);
          this.timeOffs = upsertRecord(this.timeOffs, savedTimeOff);
          return savedTimeOff;
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },

      async deleteTimeOff(id) {
        this.ui.isSaving = true;
        this.ui.error = null;

        try {
          await SchedulingExceptionsAPI.deleteTimeOff(id);
          this.timeOffs = removeRecord(this.timeOffs, id);
        } catch (error) {
          this.ui.error = extractSchedulingError(error);
          throw error;
        } finally {
          this.ui.isSaving = false;
        }
      },
    },
  }
);
