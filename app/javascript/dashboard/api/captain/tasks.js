/* global axios */
import ApiClient from '../ApiClient';

/**
 * A client for the Captain Tasks API.
 * @extends ApiClient
 */
class TasksAPI extends ApiClient {
  /**
   * Creates a new TasksAPI instance.
   */
  constructor() {
    super('captain/tasks', { accountScoped: true });
  }

  /**
   * Rewrites content with a specific operation.
   * @param {Object} options - The rewrite options.
   * @param {string} options.content - The content to rewrite.
   * @param {string} options.operation - The rewrite operation (fix_spelling_grammar, casual, professional, etc).
   * @param {string} [options.conversationId] - The conversation ID for context (required for 'improve').
   * @param {AbortSignal} [signal] - AbortSignal to cancel the request.
   * @returns {Promise} A promise that resolves with the rewritten content.
   */
  rewrite({ content, operation, conversationId }, signal) {
    return axios.post(
      `${this.url}/rewrite`,
      {
        content,
        operation,
        conversation_display_id: conversationId,
      },
      { signal }
    );
  }

  /**
   * Summarizes a conversation.
   * @param {string} conversationId - The conversation ID to summarize.
   * @param {AbortSignal} [signal] - AbortSignal to cancel the request.
   * @returns {Promise} A promise that resolves with the summary.
   */
  summarize(conversationId, signal) {
    return axios.post(
      `${this.url}/summarize`,
      {
        conversation_display_id: conversationId,
      },
      { signal }
    );
  }

  /**
   * Starts a background reply suggestion run for a conversation.
   * The backend answers 202 with a SuggestionState (status queued or running);
   * the draft arrives later through the cable `result` event or the status GET.
   * @param {string} conversationId - The conversation ID.
   * @param {AbortSignal} [signal] - AbortSignal to cancel the request.
   * @returns {Promise} A promise that resolves with the SuggestionState.
   */
  replySuggestion(conversationId, signal) {
    return axios.post(
      `${this.url}/reply_suggestion`,
      {
        conversation_display_id: conversationId,
      },
      { signal }
    );
  }

  /**
   * Reads the latest reply suggestion state of the current user.
   * Without `suggestionRequestId` it returns the newest unconsumed state of the
   * conversation (`{ suggestion: null }` when there is none). With it, that exact
   * state is returned (404 when it is not the user's or has expired).
   * @param {Object} options
   * @param {string|number} options.conversationId - The conversation display ID.
   * @param {string} [options.suggestionRequestId] - A specific run to read.
   * @param {AbortSignal} [signal] - AbortSignal to cancel the request.
   * @returns {Promise} A promise that resolves with `{ suggestion }`.
   */
  replySuggestionStatus({ conversationId, suggestionRequestId }, signal) {
    return axios.get(`${this.url}/reply_suggestion_status`, {
      params: {
        conversation_display_id: conversationId,
        suggestion_request_id: suggestionRequestId,
      },
      signal,
    });
  }

  /**
   * Cancels a queued or running reply suggestion.
   * @param {Object} options
   * @param {string|number} options.conversationId - The conversation display ID.
   * @param {string} options.suggestionRequestId - The run to cancel.
   * @returns {Promise}
   */
  cancelReplySuggestion({ conversationId, suggestionRequestId } = {}) {
    return axios.post(`${this.url}/cancel_reply_suggestion`, {
      conversation_display_id: conversationId,
      suggestion_request_id: suggestionRequestId,
    });
  }

  /**
   * Gets label suggestions for a conversation.
   * @param {string} conversationId - The conversation ID.
   * @param {AbortSignal} [signal] - AbortSignal to cancel the request.
   * @returns {Promise} A promise that resolves with label suggestions.
   */
  labelSuggestion(conversationId, signal) {
    return axios.post(
      `${this.url}/label_suggestion`,
      {
        conversation_display_id: conversationId,
      },
      { signal }
    );
  }

  /**
   * Sends a follow-up message to continue refining a previous task result.
   * @param {Object} options - The follow-up options.
   * @param {Object} options.followUpContext - The follow-up context from a previous task.
   * @param {string} options.message - The follow-up message/request from the user.
   * @param {string} [options.conversationId] - The conversation ID for Langfuse session tracking.
   * @param {AbortSignal} [signal] - AbortSignal to cancel the request.
   * @returns {Promise} A promise that resolves with the follow-up response and updated follow-up context.
   */
  followUp({ followUpContext, message, conversationId }, signal) {
    return axios.post(
      `${this.url}/follow_up`,
      {
        follow_up_context: followUpContext,
        message,
        conversation_display_id: conversationId,
      },
      { signal }
    );
  }

  /**
   * Records manager feedback on a Copilot suggestion
   * (applied, dismissed, sent, notice_dismissed).
   * `suggestionRequestId` ties the event to a background reply suggestion run;
   * applied, dismissed and notice_dismissed also mark that run as consumed.
   * @param {Object} options - Feedback payload.
   * @returns {Promise}
   */
  feedback({
    conversationId,
    requestId,
    suggestionRequestId,
    copilotAction,
    outcome,
    editedBeforeSend,
    followUpCount,
    generatedText,
    finalText,
    messageId,
  } = {}) {
    return axios.post(`${this.url}/feedback`, {
      conversation_display_id: conversationId,
      request_id: requestId,
      suggestion_request_id: suggestionRequestId,
      copilot_action: copilotAction,
      outcome,
      edited_before_send: editedBeforeSend,
      follow_up_count: followUpCount,
      generated_text: generatedText,
      final_text: finalText,
      message_id: messageId,
    });
  }

  /**
   * Approves and executes a pending action proposed during reply_suggestion.
   * @param {Object} options
   * @param {string} options.actionId - The pending action ID.
   * @param {string|number} [options.conversationId] - The conversation display ID.
   * @param {string} [options.digest] - Optional integrity digest of the proposal.
   * @returns {Promise}
   */
  approveAction({ actionId, conversationId, digest } = {}) {
    return axios.post(`${this.url}/approve_action`, {
      action_id: actionId,
      conversation_display_id: conversationId,
      ...(digest ? { digest } : {}),
    });
  }

  /**
   * Rejects a pending action proposed during reply_suggestion.
   * @param {Object} options
   * @param {string} options.actionId - The pending action ID.
   * @param {string|number} [options.conversationId] - The conversation display ID.
   * @returns {Promise}
   */
  rejectAction({ actionId, conversationId } = {}) {
    return axios.post(`${this.url}/reject_action`, {
      action_id: actionId,
      conversation_display_id: conversationId,
    });
  }
}

export default new TasksAPI();
