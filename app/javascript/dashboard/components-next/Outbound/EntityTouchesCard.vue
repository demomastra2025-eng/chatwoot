<script setup>
import { computed, watch, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';

import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TouchEditorDrawer from 'dashboard/components-next/Outbound/TouchEditorDrawer.vue';
import TouchesAPI from 'dashboard/api/touches';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';

const props = defineProps({
  conversationId: {
    type: [Number, String],
    default: '',
  },
  description: {
    type: String,
    default: '',
  },
  remindableId: {
    type: [Number, String],
    default: '',
  },
  remindableType: {
    type: String,
    required: true,
  },
  title: {
    type: String,
    default: '',
  },
});

const { t, locale } = useI18n();
const router = useRouter();
const { accountScopedRoute } = useAccount();

const touches = ref([]);
const enrollments = ref([]);
const isLoading = ref(false);
const cancellingEnrollmentId = ref(null);
const isEditorOpen = ref(false);
const editingTouch = ref(null);

const hasRemindable = computed(() => {
  return !!(props.remindableType && props.remindableId);
});

const upcomingTouches = computed(() => {
  return (touches.value || [])
    .filter(touch => ['draft', 'pending', 'processing'].includes(touch.status))
    .slice(0, 3);
});
const touchCounts = computed(() => {
  return (touches.value || []).reduce(
    (counts, touch) => {
      counts[touch.status] = (counts[touch.status] || 0) + 1;
      return counts;
    },
    {
      cancelled: 0,
      completed: 0,
      draft: 0,
      failed: 0,
      pending: 0,
      processing: 0,
    }
  );
});
const summaryItems = computed(() => [
  {
    key: 'open',
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.SUMMARY.OPEN'),
    value:
      touchCounts.value.draft +
      touchCounts.value.pending +
      touchCounts.value.processing,
  },
  {
    key: 'plans',
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.SUMMARY.PLANS'),
    value: enrollments.value.length,
  },
  {
    key: 'history',
    label: t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.SUMMARY.DONE'),
    value: touchCounts.value.completed,
  },
]);
const failedTouchCount = computed(() => touchCounts.value.failed || 0);

const cardTitle = computed(() => {
  return props.title || t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.TITLE');
});

const cardDescription = computed(() => {
  return (
    props.description || t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.DESCRIPTION')
  );
});

const formatDateTime = value => {
  if (!value) return '—';

  return new Intl.DateTimeFormat(locale.value, {
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    month: 'short',
  }).format(new Date(value));
};

const formatStatus = status => {
  switch (status) {
    case 'pending':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.PENDING');
    case 'processing':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.PROCESSING');
    case 'completed':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.COMPLETED');
    case 'cancelled':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.CANCELLED');
    case 'failed':
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.FAILED');
    case 'draft':
    default:
      return t('OUTBOUND_WORKSPACE.TOUCHES.STATUS.DRAFT');
  }
};

const preview = touch => {
  if (touch.body) return touch.body;
  if (touch.instructions) {
    return t('OUTBOUND_WORKSPACE.TOUCHES.AGENT_PREVIEW');
  }

  return t('OUTBOUND_WORKSPACE.TOUCHES.NO_CONTENT');
};

const statusBadgeClass = status => {
  return (
    {
      draft: 'bg-n-alpha-2 text-n-slate-11',
      pending: 'bg-n-brand/10 text-n-brand',
      processing: 'bg-n-amber-9/10 text-n-amber-11',
    }[status] || 'bg-n-alpha-2 text-n-slate-11'
  );
};

const openTouchesWorkspace = tab => {
  const routeName =
    tab === 'plans' ? 'outbound_touch_plans_index' : 'outbound_touches_index';

  router.push(
    accountScopedRoute(
      routeName,
      {},
      {
        ...(props.conversationId
          ? { conversation_id: props.conversationId }
          : {}),
        ...(props.remindableId ? { remindable_id: props.remindableId } : {}),
        ...(props.remindableType
          ? { remindable_type: props.remindableType }
          : {}),
      }
    )
  );
};

const openTouchEditor = touch => {
  editingTouch.value = touch || null;
  isEditorOpen.value = true;
};

async function fetchTouches() {
  if (!hasRemindable.value) {
    touches.value = [];
    enrollments.value = [];
    return;
  }

  isLoading.value = true;

  try {
    const params = {
      ...(props.conversationId
        ? { conversation_id: props.conversationId }
        : {}),
      remindable_id: props.remindableId,
      remindable_type: props.remindableType,
    };
    const [{ data: touchesData }, { data: enrollmentsData }] =
      await Promise.all([
        TouchesAPI.get(params),
        TouchesAPI.getEnrollments(params),
      ]);
    touches.value = touchesData.payload || [];
    enrollments.value = enrollmentsData.payload || [];
  } catch (error) {
    useAlert(
      error?.message || t('OUTBOUND_WORKSPACE.TOUCHES.ERRORS.LOAD_TOUCHES')
    );
  } finally {
    isLoading.value = false;
  }
}

async function cancelEnrollment(enrollment) {
  cancellingEnrollmentId.value = enrollment.id;
  try {
    await TouchesAPI.cancelEnrollment(enrollment.id, {
      reason: 'cancelled_from_entity_card',
    });
    useAlert(t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.PLAN_CANCELLED'));
    await fetchTouches();
  } catch (error) {
    useAlert(
      error?.message ||
        t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.PLAN_CANCEL_ERROR')
    );
  } finally {
    cancellingEnrollmentId.value = null;
  }
}

const handleTouchSaved = () => {
  editingTouch.value = null;
  fetchTouches();
};

watch(
  () => [props.conversationId, props.remindableId, props.remindableType],
  () => {
    fetchTouches();
  },
  { immediate: true }
);
</script>

<template>
  <div
    class="rounded-2xl bg-n-surface-1 p-4 outline outline-1 outline-n-container"
  >
    <div class="flex items-start justify-between gap-3">
      <div class="min-w-0">
        <p class="mb-1 text-sm font-semibold text-n-slate-12">
          {{ cardTitle }}
        </p>
        <p class="mb-0 text-sm text-n-slate-11">
          {{ cardDescription }}
        </p>
      </div>

      <div class="flex shrink-0 items-center gap-2">
        <Button
          size="sm"
          :label="$t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.CREATE')"
          @click="openTouchEditor()"
        />
        <Button
          size="sm"
          variant="outline"
          color="slate"
          :label="$t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.VIEW_ALL')"
          @click="openTouchesWorkspace()"
        />
        <Button
          size="sm"
          color="slate"
          variant="faded"
          :label="$t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.OPEN_PLANS')"
          @click="openTouchesWorkspace('plans')"
        />
      </div>
    </div>

    <div class="mt-4 grid gap-3 sm:grid-cols-3">
      <div
        v-for="item in summaryItems"
        :key="item.key"
        class="rounded-2xl bg-n-alpha-black2 px-4 py-3"
      >
        <p
          class="mb-1 text-xs font-medium uppercase tracking-[0.08em] text-n-slate-10"
        >
          {{ item.label }}
        </p>
        <p class="mb-0 text-lg font-semibold text-n-slate-12">
          {{ item.value }}
        </p>
      </div>
    </div>

    <div
      v-if="failedTouchCount"
      class="mt-4 flex items-center justify-between gap-3 rounded-2xl bg-n-ruby-2 px-4 py-3"
    >
      <div class="min-w-0">
        <p class="mb-1 text-sm font-medium text-n-ruby-12">
          {{
            $t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.FAILED_TITLE', {
              count: failedTouchCount,
            })
          }}
        </p>
        <p class="mb-0 text-xs leading-5 text-n-ruby-11">
          {{ $t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.FAILED_NOTE') }}
        </p>
      </div>
      <Button
        size="sm"
        ruby
        faded
        :label="$t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.OPEN_EXECUTION')"
        @click="openTouchesWorkspace('execution')"
      />
    </div>

    <div
      v-if="isLoading"
      class="flex items-center gap-2 py-4 text-sm text-n-slate-11"
    >
      <Spinner class="!h-4 !w-4" />
      <span>{{ $t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.LOADING') }}</span>
    </div>

    <div v-if="!isLoading && enrollments.length" class="mt-4 grid gap-3">
      <div
        v-for="enrollment in enrollments"
        :key="`enrollment-${enrollment.id}`"
        class="rounded-xl bg-n-brand/5 px-3 py-3 outline outline-1 outline-n-brand/20"
      >
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <p class="mb-1 truncate text-sm font-medium text-n-slate-12">
              {{
                $t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.PLAN_TITLE', {
                  name: enrollment.reminder_group_name,
                })
              }}
            </p>
            <p class="mb-1 text-xs text-n-slate-11">
              {{
                $t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.NEXT_TRIGGER', {
                  time: formatDateTime(enrollment.next_due_at),
                })
              }}
            </p>
            <p class="mb-0 text-xs text-n-brand">
              {{ $t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.WAITING_TRIGGER') }}
            </p>
          </div>
          <Button
            size="sm"
            color="slate"
            variant="faded"
            :is-loading="cancellingEnrollmentId === enrollment.id"
            :label="$t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.CANCEL_PLAN')"
            @click="cancelEnrollment(enrollment)"
          />
        </div>
      </div>
    </div>

    <div
      v-if="!isLoading && !enrollments.length && !upcomingTouches.length"
      class="grid gap-3 py-4 text-sm text-n-slate-11"
    >
      <p class="mb-0">
        {{ $t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.EMPTY') }}
      </p>
      <div class="flex flex-wrap items-center gap-2">
        <Button
          size="sm"
          :label="$t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.CREATE')"
          @click="openTouchEditor()"
        />
        <Button
          size="sm"
          slate
          variant="faded"
          :label="$t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.OPEN_PLANS')"
          @click="openTouchesWorkspace('plans')"
        />
      </div>
    </div>

    <div v-if="!isLoading && upcomingTouches.length" class="mt-4 grid gap-3">
      <div
        v-for="touch in upcomingTouches"
        :key="touch.id"
        class="rounded-xl bg-n-alpha-black2 px-3 py-3"
      >
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <p class="mb-1 truncate text-sm font-medium text-n-slate-12">
              {{ preview(touch) }}
            </p>
            <p class="mb-1 text-xs text-n-slate-11">
              {{ formatDateTime(touch.scheduled_at) }}
            </p>
            <p class="mb-0 text-xs text-n-slate-10">
              {{ $t('OUTBOUND_WORKSPACE.TOUCHES.ENTITY_CARD.OPEN_NEXT_STEP') }}
            </p>
          </div>

          <div class="flex shrink-0 items-center gap-2">
            <span
              class="inline-flex rounded-full px-2.5 py-1 text-xs font-medium"
              :class="statusBadgeClass(touch.status)"
            >
              {{ formatStatus(touch.status) }}
            </span>
            <Button
              size="sm"
              color="slate"
              variant="faded"
              :label="$t('OUTBOUND_WORKSPACE.TOUCH_EDITOR.EDIT')"
              @click="openTouchEditor(touch)"
            />
          </div>
        </div>
      </div>
    </div>

    <TouchEditorDrawer
      v-model="isEditorOpen"
      :conversation-id="conversationId"
      :remindable-id="remindableId"
      :remindable-type="remindableType"
      :touch="editingTouch"
      @saved="handleTouchSaved"
    />
  </div>
</template>
