module Crm::Tasks::ContextResolver
  private

  def resolve_context_kind(deal:)
    context_kind = if params.key?(:context_kind)
                     params[:context_kind].to_s.strip.downcase
                   else
                     task.context_kind.presence || inferred_context_kind(deal)
                   end

    validation_error!('context_kind', "must be one of: #{Crm::Task::CONTEXT_KINDS.join(', ')}") unless Crm::Task::CONTEXT_KINDS.include?(context_kind)
    validation_error!('deal_id', 'is required for sales tasks') if context_kind == 'sales' && deal.blank?

    context_kind
  end

  def inferred_context_kind(deal)
    deal.present? ? 'sales' : 'personal'
  end
end
