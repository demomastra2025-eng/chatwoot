# frozen_string_literal: true

class Captain::ShadowTraining::RunJob < ApplicationJob
  PHASE_LEASE = 15.minutes
  queue_as :low

  def perform(run_id, resume: false)
    @run = Captain::ShadowTraining::Run.find_by(id: run_id)
    return unless @run

    judge = Captain::ShadowTraining::LocalJudge.new
    return unless claim(judge, resume: resume)
    return update_owned!(status: 'pending_input', error_code: 'comparison_input_too_large') unless judge.representable?(@run)

    return unless judge_ready?(judge)

    run_pipeline(judge)
  rescue Captain::ShadowTraining::LocalJudge::Unavailable => e
    update_owned!(status: 'awaiting_comparison', error_code: e.message)
  rescue Captain::Runtime::DecisionRouter::UnavailableError
    update_owned!(status: 'pending_routing', error_code: 'routing_unavailable')
  rescue Captain::ShadowTraining::Eligibility::Revoked
    update_owned!(status: 'skipped', error_code: 'no_longer_eligible')
  rescue StandardError => e
    update_owned!(status: 'failed', error_code: e.class.name)
  end

  private

  def run_pipeline(judge)
    Captain::ShadowTraining::Eligibility.ensure_run!(@run)
    return unless select_agent

    Captain::ShadowTraining::Eligibility.ensure_run!(@run)
    return unless @run.shadow_reply || generate

    Captain::ShadowTraining::Eligibility.ensure_run!(@run)
    complete(judge.compare(@run))
  end

  def permitted?
    Captain::ShadowTraining::Eligibility.ensure_run!(@run)
    true
  rescue Captain::ShadowTraining::Eligibility::Revoked
    false
  end

  def judge_ready?(judge)
    return true if @run.shadow_reply || judge.ready?

    update_owned!(status: 'awaiting_comparison', error_code: 'local_judge_not_ready')
    false
  end

  def claim(judge, resume:)
    @run.with_lock do
      recover_stale_phase!
      return false unless claimable?(resume)
      return @run.update!(status: 'skipped', error_code: 'no_longer_eligible') && false unless permitted?
      return @run.update!(status: 'awaiting_comparison', error_code: 'local_judge_not_configured') && false unless judge.configured?

      @execution_token = SecureRandom.uuid
      @run.update!(status: @run.shadow_reply.nil? ? 'generating' : 'comparing', error_code: nil,
                   execution_token: @execution_token, phase_started_at: Time.current)
    end
    true
  end

  def claimable?(resume)
    @run.status.in?(%w[queued awaiting_comparison]) || (resume && @run.status == 'pending_routing')
  end

  def generate
    text = Captain::ShadowTraining::Generator.new(@run).call
    update_owned!(shadow_reply: text, status: 'comparing', phase_started_at: Time.current)
  end

  def select_agent
    if @run.shadow_reply
      graph = Captain::AgentGraph.new(Captain::ChannelScope.for_conversation(@run.conversation))
      return true if graph.find(@run.assistant_id)

      update_owned!(status: 'pending_routing', error_code: 'routing_configuration_changed')
      return false
    end

    actor, reason = Captain::ShadowTraining::Routing.select(@run)
    if actor.nil?
      update_owned!(status: 'pending_routing', error_code: reason || 'routing_agent_unavailable')
      return false
    end

    update_owned!(assistant: actor)
  end

  def complete(comparison)
    @run.with_lock do
      return unless owns_phase?
      return @run.update!(status: 'skipped', error_code: 'no_longer_eligible') unless permitted?

      create_candidates(comparison) if comparison.fetch('verdict') == 'discrepancy'
      @run.update!(status: 'completed', comparison: comparison, error_code: nil)
    end
  end

  def owns_phase?
    @execution_token.present? && @run.execution_token == @execution_token
  end

  def update_owned!(**attributes)
    return false unless @run

    @run.with_lock do
      return false unless owns_phase?

      @run.update!(**attributes)
    end
    true
  rescue ActiveRecord::RecordNotFound
    false
  end

  def recover_stale_phase!
    return unless @run.status.in?(%w[generating comparing])
    return if @run.phase_started_at && @run.phase_started_at > PHASE_LEASE.ago

    status = @run.shadow_reply.nil? ? 'interrupted_pending_review' : 'awaiting_comparison'
    @run.update!(status: status, execution_token: nil, error_code: 'interrupted_worker')
  end

  def create_candidates(comparison)
    common = { 'mode' => @run.snapshot.fetch('mode'), 'limitations' => @run.snapshot.fetch('limitations'),
               'review_required' => true, 'operator_is_ground_truth' => false }
    @run.candidates.create!(account_id: @run.account_id, kind: 'regression', proposal: common.merge(
      'discrepancies' => comparison.fetch('discrepancies'), 'expected_behavior_status' => 'requires_fact_review',
      'input_source' => 'run.snapshot', 'human_reply_source' => 'run.human_reply'
    ))
    faq = comparison.fetch('faq_candidates').first
    @run.candidates.create!(account_id: @run.account_id, kind: 'faq', proposal: common.merge(faq)) if faq
  end
end
