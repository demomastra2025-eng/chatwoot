class Captain::Tools::Operations::DealOperations < Captain::Tools::Operations::BaseOperation
  def add_current_deal_comment(body:)
    raise ArgumentError, 'A deal comment is required' if body.blank?
    raise ArgumentError, 'Current deal is not available' if current_deal.blank?
    raise ArgumentError, 'A user actor is required to create deal comments' unless actor.is_a?(User)

    current_deal.comments.create!(account: account, user: actor, body: body.to_s.strip)
  end

  def create_deal(title:, description: nil, amount_minor: nil, currency: nil, expected_close_on: nil, win_probability: nil, custom_attributes: nil)
    ensure_feature_enabled!('crm_deals', 'CRM deals are not enabled for this account')
    bootstrap_crm_defaults!

    create_params = {
      title: title,
      description: description,
      amount_minor: amount_minor,
      currency: currency,
      expected_close_on: expected_close_on,
      win_probability: win_probability,
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

  def transition_current_deal_stage(stage_id: nil, stage_name: nil, stage_code: nil)
    ensure_feature_enabled!('crm_deals', 'CRM deals are not enabled for this account')
    raise ArgumentError, 'Current deal is not available' if current_deal.blank?

    stage = resolve_stage(stage_id: stage_id, stage_name: stage_name, stage_code: stage_code)

    ::Crm::Deals::TransitionService.new(
      account: account,
      deal: current_deal,
      params: {
        stage_id: stage.id,
        lock_version: current_deal.lock_version
      },
      actor: actor
    ).perform
  end

  def update_current_deal(title: nil, description: nil, amount_minor: nil, currency: nil, expected_close_on: nil, win_probability: nil, custom_attributes: nil)
    ensure_feature_enabled!('crm_deals', 'CRM deals are not enabled for this account')
    raise ArgumentError, 'Current deal is not available' if current_deal.blank?

    params = {
      lock_version: current_deal.lock_version
    }
    params[:title] = title if title.present?
    params[:description] = description if !description.nil?
    params[:amount_minor] = amount_minor if !amount_minor.nil?
    params[:currency] = currency if !currency.nil?
    params[:expected_close_on] = expected_close_on if !expected_close_on.nil?
    params[:win_probability] = win_probability if !win_probability.nil?

    if custom_attributes.present?
      params[:custom_attributes] = parsed_hash(custom_attributes, field_name: 'custom_attributes')
    end

    ::Crm::Deals::UpsertService.new(
      account: account,
      params: params,
      deal: current_deal,
      actor: actor
    ).perform
  end

  private

  def resolve_stage(stage_id:, stage_name:, stage_code:)
    return account.crm_stages.find(stage_id) if stage_id.present?
    return account.crm_stages.find_by!(code: stage_code.to_s.strip) if stage_code.present?
    return account.crm_stages.find_by!(name: stage_name.to_s.strip) if stage_name.present?

    raise ArgumentError, 'One of stage_id, stage_name, or stage_code is required'
  end
end
