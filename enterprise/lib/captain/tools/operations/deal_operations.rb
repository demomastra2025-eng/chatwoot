class Captain::Tools::Operations::DealOperations < Captain::Tools::Operations::BaseOperation
  STAGE_ACTIONS = %w[next previous].freeze

  def add_current_deal_comment(body:)
    raise ArgumentError, 'A deal comment is required' if body.blank?
    raise ArgumentError, 'Current deal is not available' if current_deal.blank?
    raise ArgumentError, 'A user actor is required to create deal comments' unless actor.is_a?(User)

    current_deal.comments.create!(account: account, user: actor, body: body.to_s.strip)
  end

  def create_deal(title:, description: nil, amount: nil, amount_minor: nil, currency: nil, expected_close_on: nil,
                  win_probability: nil, custom_attributes: nil, pipeline_id: nil, pipeline_code: nil, stage_id: nil,
                  stage_name: nil, stage_code: nil)
    ensure_feature_enabled!('crm_deals', 'CRM deals are not enabled for this account')
    bootstrap_crm_defaults!

    target_stage = if stage_selector?(stage_id: stage_id, stage_name: stage_name, stage_code: stage_code)
                     resolve_stage(
                       stage_id: stage_id,
                       stage_name: stage_name,
                       stage_code: stage_code,
                       pipeline_id: pipeline_id,
                       pipeline_code: pipeline_code
                     )
                   end
    target_pipeline = target_stage&.pipeline || resolve_pipeline(pipeline_id: pipeline_id, pipeline_code: pipeline_code)

    create_params = {
      title: title,
      description: description,
      amount_minor: amount_minor_for_write(amount: amount, amount_minor: amount_minor),
      currency: currency,
      expected_close_on: expected_close_on,
      win_probability: win_probability,
      pipeline_id: target_pipeline&.id,
      stage_id: target_stage&.id,
      company_id: current_company&.id,
      originating_conversation_id: conversation&.id,
      primary_contact_id: current_contact&.id,
      custom_attributes: parsed_hash(custom_attributes, field_name: 'custom_attributes')
    }.compact

    with_idempotent_creation('create_deal', create_params) do
      ::Crm::Deals::UpsertService.new(
        account: account,
        params: create_params,
        actor: actor
      ).perform
    end
  end

  def transition_current_deal_stage(stage_id: nil, stage_name: nil, stage_code: nil, pipeline_id: nil, pipeline_code: nil,
                                    stage_action: nil)
    ensure_feature_enabled!('crm_deals', 'CRM deals are not enabled for this account')
    raise ArgumentError, 'Current deal is not available' if current_deal.blank?

    raise ArgumentError, 'stage_action cannot be combined with stage_id, stage_name, stage_code, pipeline_id, or pipeline_code' if stage_action.present? && explicit_stage_target?(stage_id: stage_id, stage_name: stage_name, stage_code: stage_code, pipeline_id: pipeline_id, pipeline_code: pipeline_code)

    stage = if stage_action.present?
              resolve_relative_stage(stage_action)
            else
              resolve_stage(
                stage_id: stage_id,
                stage_name: stage_name,
                stage_code: stage_code,
                pipeline_id: pipeline_id,
                pipeline_code: pipeline_code,
                fallback_pipeline: current_deal.pipeline,
                allow_pipeline_default: pipeline_selector?(pipeline_id: pipeline_id, pipeline_code: pipeline_code)
              )
            end

    transition_deal_to_stage(current_deal, stage)
  end

  def update_current_deal(title: nil, description: nil, amount: nil, amount_minor: nil, currency: nil,
                          expected_close_on: nil, win_probability: nil, custom_attributes: nil, pipeline_id: nil,
                          pipeline_code: nil, stage_id: nil, stage_name: nil, stage_code: nil)
    ensure_feature_enabled!('crm_deals', 'CRM deals are not enabled for this account')
    deal = current_deal
    raise ArgumentError, 'Current deal is not available' if deal.blank?

    target_stage = resolve_stage(
      stage_id: stage_id,
      stage_name: stage_name,
      stage_code: stage_code,
      pipeline_id: pipeline_id,
      pipeline_code: pipeline_code,
      fallback_pipeline: deal.pipeline,
      allow_pipeline_default: pipeline_selector?(pipeline_id: pipeline_id, pipeline_code: pipeline_code)
    ) if explicit_stage_target?(
      stage_id: stage_id,
      stage_name: stage_name,
      stage_code: stage_code,
      pipeline_id: pipeline_id,
      pipeline_code: pipeline_code
    )

    params = {
      lock_version: deal.lock_version
    }
    params[:title] = title if title.present?
    params[:description] = description unless description.nil?
    params[:amount_minor] = amount_minor_for_write(amount: amount, amount_minor: amount_minor) if !amount.nil? || !amount_minor.nil?
    params[:currency] = currency unless currency.nil?
    params[:expected_close_on] = expected_close_on unless expected_close_on.nil?
    params[:win_probability] = win_probability unless win_probability.nil?

    params[:custom_attributes] = parsed_hash(custom_attributes, field_name: 'custom_attributes') if custom_attributes.present?

    return deal if params.keys == [:lock_version] && target_stage.blank?

    ApplicationRecord.transaction do
      deal = update_deal_fields(deal, params) unless params.keys == [:lock_version]
      deal = transition_deal_to_stage(deal, target_stage) if target_stage.present?
      deal
    end
  end

  private

  def amount_minor_for_write(amount:, amount_minor:)
    return Crm::AmountFormatter.minor_from_major(amount) unless amount.nil?

    amount_minor
  end

  def resolve_pipeline(pipeline_id: nil, pipeline_code: nil, fallback_pipeline: nil)
    return account.crm_pipelines.active.find(pipeline_id) if pipeline_id.present?
    return account.crm_pipelines.active.find_by!(code: normalized_code(pipeline_code)) if pipeline_code.present?

    fallback_pipeline
  end

  def resolve_stage(stage_id:, stage_name:, stage_code:, pipeline_id: nil, pipeline_code: nil, fallback_pipeline: nil,
                    allow_pipeline_default: false)
    requested_pipeline = resolve_pipeline(pipeline_id: pipeline_id, pipeline_code: pipeline_code)
    target_pipeline = requested_pipeline || fallback_pipeline

    return resolve_stage_by_id(stage_id, target_pipeline: requested_pipeline) if stage_id.present?
    return resolve_stage_by_code(stage_code, target_pipeline: target_pipeline) if stage_code.present?
    return resolve_stage_by_name(stage_name, target_pipeline: target_pipeline) if stage_name.present?
    return first_active_stage_for_pipeline(requested_pipeline) if allow_pipeline_default && requested_pipeline.present?

    raise ArgumentError, 'One of stage_id, stage_name, stage_code, pipeline_id, pipeline_code, or stage_action is required'
  end

  def resolve_stage_by_id(stage_id, target_pipeline: nil)
    stage = account.crm_stages.active.find(stage_id)
    ensure_stage_pipeline_match!(stage, target_pipeline) if target_pipeline.present?
    stage
  end

  def resolve_stage_by_code(stage_code, target_pipeline: nil)
    scope = scoped_stage_lookup(target_pipeline)
    matches = scope.where(code: normalized_code(stage_code))
    unique_stage!(matches, field_name: 'stage_code', value: stage_code)
  end

  def resolve_stage_by_name(stage_name, target_pipeline: nil)
    scope = scoped_stage_lookup(target_pipeline)
    matches = scope.where('LOWER(crm_stages.name) = ?', stage_name.to_s.strip.downcase)
    unique_stage!(matches, field_name: 'stage_name', value: stage_name)
  end

  def scoped_stage_lookup(target_pipeline)
    scope = account.crm_stages.active
    target_pipeline.present? ? scope.where(pipeline_id: target_pipeline.id) : scope
  end

  def unique_stage!(matches, field_name:, value:)
    stages = matches.limit(2).to_a
    return stages.first if stages.one?
    raise ActiveRecord::RecordNotFound, "Couldn't find CRM stage with #{field_name}=#{value}" if stages.empty?

    raise ArgumentError,
          "#{field_name} is ambiguous across CRM pipelines; call list_deal_stages/list_deal_pipelines and pass stage_id or pipeline_id/pipeline_code"
  end

  def first_active_stage_for_pipeline(pipeline)
    pipeline.stages.active.where(outcome: 'open').ordered.first ||
      pipeline.stages.active.ordered.first ||
      raise(ArgumentError, 'Selected CRM pipeline has no active stages')
  end

  def update_deal_fields(deal, params)
    ::Crm::Deals::UpsertService.new(
      account: account,
      params: params,
      deal: deal,
      actor: actor
    ).perform
  end

  def ensure_stage_pipeline_match!(stage, pipeline)
    return if stage.pipeline_id == pipeline.id

    raise ArgumentError, 'stage_id must belong to the selected CRM pipeline'
  end

  def resolve_relative_stage(stage_action)
    normalized_action = stage_action.to_s.strip.downcase
    raise ArgumentError, 'stage_action must be next or previous' unless STAGE_ACTIONS.include?(normalized_action)

    stages = current_deal.pipeline.stages.active.ordered.to_a
    current_index = stages.index { |stage| stage.id == current_deal.stage_id }
    raise ArgumentError, 'Current deal stage is not active in its pipeline' if current_index.blank?

    target_stage = if normalized_action == 'next'
                     stages[current_index + 1]
                   elsif current_index.positive?
                     stages[current_index - 1]
                   end
    raise ArgumentError, "No #{normalized_action} CRM stage is available in the current pipeline" if target_stage.blank?

    target_stage
  end

  def transition_deal_to_stage(deal, stage)
    ::Crm::Deals::TransitionService.new(
      account: account,
      deal: deal,
      params: {
        stage_id: stage.id,
        lock_version: deal.lock_version
      },
      actor: actor
    ).perform
  end

  def stage_selector?(stage_id:, stage_name:, stage_code:)
    stage_id.present? || stage_name.present? || stage_code.present?
  end

  def pipeline_selector?(pipeline_id:, pipeline_code:)
    pipeline_id.present? || pipeline_code.present?
  end

  def explicit_stage_target?(stage_id:, stage_name:, stage_code:, pipeline_id:, pipeline_code:)
    stage_selector?(stage_id: stage_id, stage_name: stage_name, stage_code: stage_code) ||
      pipeline_selector?(pipeline_id: pipeline_id, pipeline_code: pipeline_code)
  end

  def normalized_code(value)
    ::Crm::CodeNormalizer.normalize(value)
  end
end
